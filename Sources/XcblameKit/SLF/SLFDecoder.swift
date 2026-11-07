import Foundation

/// Decodes an inflated SLF token stream into a `RawLog` (DESIGN §5.4).
///
/// Strategy: every instance is matched slot by slot against the `ClassSchemaTable` row for its class, format version
/// and layout. On a type mismatch the decoder switches to another row that agrees on the slots already read and
/// accepts the current token. If none does, it aligns: it skips the fewest unexpected values (or drops the fewest
/// slots) after which the next tokens match the row again, keeping every slot it can type-match, and warns
/// `schemaDrift`. When nothing aligns it resynchronises at the next section instance. Counted arrays keep depth
/// exact. Unknown classes are opaque and warned about once per name. A truncated stream yields the partial tree.
public struct SLFDecoder {
    /// Instances nested deeper than this are skipped (real logs nest about 5 levels).
    static let maxDepth = 64
    /// A leading format version outside this range is rejected (never used in arithmetic).
    static let versionRange: ClosedRange<UInt64> = 0...10_000
    /// At most this many unexpected values are skipped to realign a closed row; open-tail classes allow more.
    static let maxExtras = 8
    static let maxTailExtras = 64
    /// Arrays nested deeper than this are skipped by structure, iteratively (no recursion on hostile input).
    static let maxArrayDepth = 128

    struct Cursor {
        var tokenizer: SLFTokenizer
        var classNames: [String] = []
        var lookahead: SLFToken?

        /// Next non-classDef token; classDefs extend the class table as they pass.
        mutating func peek() -> SLFToken? {
            if let lookahead { return lookahead }
            while let token = tokenizer.next() {
                if token.kind == .classDef {
                    classNames.append(tokenizer.string(token))
                    continue
                }
                lookahead = token
                return token
            }
            return nil
        }

        mutating func take() -> SLFToken? {
            let token = peek()
            lookahead = nil
            return token
        }

        func className(_ ref: UInt64) -> String {
            guard ref >= 1, ref <= UInt64(classNames.count) else { return "#\(ref)" }
            return classNames[Int(ref - 1)]
        }
    }

    var cursor: Cursor
    let table: ClassSchemaTable
    var version: Int?
    var layout: RawLog.Layout = .commandLine
    var depth = 0
    var arrayDepth = 0
    /// The input ended while a structure was still open.
    var endedEarly = false
    /// Probing decoders (lookahead copies) record nothing.
    var quiet = false
    /// Inside a probe, records never probe again: alignment runs once per record, so recovery stays linear in the
    /// input times the nesting depth instead of doubling per level (DESIGN §4.3 rule 4).
    var probing = false
    var warningOrder: [String] = []
    var warningTable: [String: (warning: DecodeWarning, count: Int)] = [:]

    init(bytes: [UInt8], table: ClassSchemaTable) {
        cursor = Cursor(tokenizer: SLFTokenizer(bytes: bytes))
        self.table = table
    }

    /// Decodes a whole inflated log. Never throws: problems become `decodeWarnings` on the returned log.
    public static func decode(bytes: [UInt8], table: ClassSchemaTable = .v1) -> RawLog {
        var decoder = SLFDecoder(bytes: bytes, table: table)
        return decoder.decodeLog()
    }

    mutating func decodeLog() -> RawLog {
        if let first = cursor.peek(), first.kind == .int {
            _ = cursor.take()
            if Self.versionRange.contains(first.value) {
                version = Int(first.value)
            } else {
                warn(.schemaDrift, key: "version", "format version \(first.value) out of range; ignored", offset: 0)
            }
        } else if cursor.peek() != nil {
            warn(.schemaDrift, key: "version", "log does not start with the format version int", offset: 0)
        }
        if let rootRef = cursor.peek(), rootRef.kind == .classRef {
            layout = cursor.className(rootRef.value) == "IDECommandLineBuildLog" ? .commandLine : .ide
        }
        var root = RawSection()
        if let token = cursor.peek() {
            let value = decodeValue(follow: [])
            if case let .object(.section(section)) = value {
                root = section
            } else {
                warn(.schemaDrift, key: "root", "root token is not a section instance", offset: token.offset)
            }
        }
        var trailing = 0
        let trailingOffset = cursor.peek()?.offset
        while cursor.take() != nil { trailing += 1 }
        if trailing > 0 {
            warn(.schemaDrift, key: "trailing", "\(trailing) tokens after the root section", offset: trailingOffset)
        }
        if let error = cursor.tokenizer.error {
            warn(.truncated, key: "token",
                 "tokenizer stopped (\(error.reason.rawValue)); partial tree returned", offset: error.offset)
        } else if endedEarly {
            warn(.truncated, key: "eof", "log ended inside an open record; partial tree returned",
                 offset: cursor.tokenizer.bytes.count)
        }
        return RawLog(formatVersion: version, layout: layout, root: root, decodeWarnings: collectedWarnings())
    }

    // MARK: - Values

    /// `follow`: kinds expected right after this value (at most a few), used to align extras; empty = anything.
    mutating func decodeValue(follow: [SLFKindSet]) -> SLFValue {
        guard let token = cursor.peek() else {
            endedEarly = true
            return .null
        }
        switch token.kind {
        case .int: _ = cursor.take(); return .int(token.value)
        case .double: _ = cursor.take(); return .double(token.doubleValue)
        case .string: _ = cursor.take(); return .string(token.payloadRange)
        case .json: _ = cursor.take(); return .json(token.payloadRange)
        case .null, .classDef: _ = cursor.take(); return .null
        case .array:
            guard arrayDepth < Self.maxArrayDepth else {
                warn(.schemaDrift, key: "array-depth", "arrays nested deeper than \(Self.maxArrayDepth) skipped",
                     offset: token.offset)
                skipStructurally()
                return .null
            }
            _ = cursor.take()
            arrayDepth += 1
            defer { arrayDepth -= 1 }
            return .array(decodeArray(count: token.value, follow: follow))
        case .classRef:
            return .object(decodeObject(follow: follow))
        }
    }

    mutating func decodeArray(count: UInt64, follow: [SLFKindSet]) -> [SLFValue] {
        var elements: [SLFValue] = []
        elements.reserveCapacity(Int(min(count, 4096)))
        var index: UInt64 = 0
        while index < count {
            guard let token = cursor.peek() else {
                endedEarly = true
                break
            }
            index += 1
            elements.append(decodeValue(follow: index < count ? [SLFKindSet(token.kind)] : follow))
        }
        return elements
    }

    // MARK: - Instances

    mutating func decodeObject(follow: [SLFKindSet]) -> SLFObject {
        guard let ref = cursor.take() else { return .opaque }
        let name = cursor.className(ref.value)
        let schema = table.schema(for: name, version: version, layout: layout)
        if !schema.known {
            warn(.unknownClass, key: "class|" + name, "unknown class \(name) (\(schema.family?.rawValue ?? "opaque"))",
                 offset: ref.offset)
        }
        guard let family = schema.family, var row = schema.rows.first, depth < Self.maxDepth else {
            skipExtras(follow: follow, limit: Self.maxTailExtras, className: name)
            return .opaque
        }
        depth += 1
        defer { depth -= 1 }
        var record = SLFRecord()
        var k = 0
        rowLoop: while true {
            while k < row.slots.count {
                guard let token = cursor.peek() else {
                    endedEarly = true
                    break rowLoop
                }
                let slot = row.slots[k]
                if slot.accepts.accepts(token.kind) {
                    record[slot.name] = decodeValue(follow: Self.follow(row, from: k + 1, then: follow))
                    k += 1
                    continue
                }
                if let alt = schema.rows.first(where: { $0.id != row.id && $0.sharesPrefix(with: row, count: k)
                    && $0.slots.count > k && $0.slots[k].accepts.accepts(token.kind) }) {
                    row = alt
                    continue
                }
                let rest = Self.follow(row, from: k, then: follow)
                if !probing, let skip = extrasBeforeMatch(rest, limit: Self.maxExtras) {
                    warn(.schemaDrift, key: "extra|\(name)|\(row.id)|\(slot.name)",
                         "\(name) [\(row.id)]: \(skip) unexpected value(s) before slot \(slot.name)", offset: token.offset)
                    for _ in 0..<skip { _ = decodeValue(follow: []) }
                    continue
                }
                if let drop = (1...3).first(where: { k + $0 < row.slots.count
                    && shallowMatch(Self.follow(row, from: k + $0, then: follow)) }) {
                    let dropped = row.slots[k..<(k + drop)].map(\.name)
                    warn(.schemaDrift, key: "missing|\(name)|\(row.id)|\(slot.name)",
                         "\(name) [\(row.id)]: slot \(slot.name) and \(drop - 1) more missing", offset: token.offset,
                         affectsTiming: dropped.contains { Self.timingSlots.contains($0) })
                    k += drop
                    continue
                }
                warn(.resync, key: "\(name)|\(row.id)|\(slot.name)",
                     "\(name) [\(row.id)]: no row matches at slot \(slot.name); skipped to the next section",
                     offset: token.offset, affectsTiming: true)
                resync(row: row, from: k, record: &record, follow: follow)
                break rowLoop
            }
            // End of row: the next token must fit what follows this instance.
            guard let token = cursor.peek(), let next = follow.first, !next.accepts(token.kind) else { break }
            let used = row.slots.count
            if let alt = schema.rows.first(where: { $0.slots.count > used && $0.sharesPrefix(with: row, count: used)
                && $0.slots[used].accepts.accepts(token.kind) }) {
                row = alt
                continue
            }
            skipExtras(follow: follow, limit: schema.openTail ? Self.maxTailExtras : Self.maxExtras,
                       className: name)
            break
        }
        return makeObject(family: family, record: record)
    }

    /// Kinds of `row.slots[from...]`, then `follow`, at most 4.
    static func follow(_ row: SLFSchemaRow, from: Int, then follow: [SLFKindSet]) -> [SLFKindSet] {
        var out: [SLFKindSet] = []
        var i = from
        while i < row.slots.count, out.count < 4 {
            out.append(row.slots[i].accepts)
            i += 1
        }
        for kinds in follow where out.count < 4 { out.append(kinds) }
        return out
    }

    /// Skips values after an instance's known fields until the next token fits `follow`.
    mutating func skipExtras(follow: [SLFKindSet], limit: Int, className: String) {
        guard let token = cursor.peek(), let next = follow.first, !next.accepts(token.kind) else { return }
        let count = probing ? nil : extrasBeforeMatch(follow, limit: limit)
        warn(count == nil ? .resync : .schemaDrift, key: "tail|\(className)",
             "\(className): \(count.map(String.init) ?? "unaligned") extra value(s) after known fields skipped",
             offset: token.offset, affectsTiming: count == nil)
        guard let count else {
            var none = SLFRecord()
            resync(row: nil, from: 0, record: &none, follow: follow)
            return
        }
        for _ in 0..<count { _ = decodeValue(follow: []) }
    }

    /// Fewest values (1...limit) to skip so the following tokens match `target`; nil when none.
    mutating func extrasBeforeMatch(_ target: [SLFKindSet], limit: Int) -> Int? {
        guard !target.isEmpty else { return nil }
        var probe = self
        probe.quiet = true
        probe.probing = true
        for skip in 1...max(limit, 1) {
            guard probe.cursor.peek() != nil else { return nil }
            _ = probe.decodeValue(follow: [])
            if probe.shallowMatch(target) { return skip }
        }
        return nil
    }

    /// Consumes one value by structure only (an array by its count, an instance by its first row's slot count),
    /// iteratively, for arrays nested beyond `maxArrayDepth`.
    mutating func skipStructurally() {
        var pending: UInt64 = 1
        func add(_ n: UInt64) {
            let (sum, overflow) = pending.addingReportingOverflow(n)
            pending = overflow ? .max : sum  // saturates; the input runs out long before
        }
        while pending > 0, let token = cursor.take() {
            pending -= 1
            switch token.kind {
            case .array:
                add(token.value)
            case .classRef:
                let schema = table.schema(for: cursor.className(token.value), version: version, layout: layout)
                add(UInt64(schema.rows.first?.slots.count ?? 0))
            default: break
            }
        }
    }

    /// True when upcoming tokens fit `target`, checked up to the first array or instance (or the end of input).
    mutating func shallowMatch(_ target: [SLFKindSet]) -> Bool {
        var probe = cursor
        for kinds in target {
            guard let token = probe.take() else { return true }
            guard kinds.accepts(token.kind) else { return false }
            if token.kind == .array || token.kind == .classRef { return true }
        }
        return true
    }

    /// Resynchronises after a record nothing realigns (DESIGN §5.4). Walks the values at this record's own level only:
    /// an array or nested instance is consumed whole by the normal decoder (counted arrays keep depth exact), so a
    /// nested child is never seen here and never promoted. Each value that type-matches a remaining slot of `row`
    /// fills it, in order. Stops at a section instance at this level (the next sibling), when the row is full, at a
    /// token that fits `follow` but no remaining slot, or at the end of input.
    mutating func resync(row: SLFSchemaRow?, from start: Int, record: inout SLFRecord, follow: [SLFKindSet]) {
        var k = start
        while let token = cursor.peek() {
            if token.kind == .classRef,
               table.schema(for: cursor.className(token.value), version: version, layout: layout).family == .section {
                return
            }
            if let row, let j = (k..<max(k, row.slots.count)).first(where: { row.slots[$0].accepts.accepts(token.kind) }) {
                record[row.slots[j].name] = decodeValue(follow: Self.follow(row, from: j + 1, then: follow))
                k = j + 1
                if k >= row.slots.count { return }
                continue
            }
            if let next = follow.first, next.accepts(token.kind) { return }
            _ = decodeValue(follow: [])
        }
    }

    // MARK: - Warnings

    /// Slots whose loss makes a section's timing unknown (V14).
    static let timingSlots: Set<SLFSlotName> = [.start, .end]

    /// Records one warning per key; repeats bump a count shown in the detail.
    mutating func warn(_ kind: DecodeWarning.Kind, key: String, _ detail: String, offset: Int?,
                       affectsTiming: Bool = false) {
        guard !quiet else { return }
        let fullKey = kind.rawValue + "|" + key
        if let existing = warningTable[fullKey] {
            warningTable[fullKey] = (existing.warning, existing.count + 1)
            return
        }
        warningOrder.append(fullKey)
        warningTable[fullKey] = (DecodeWarning(kind: kind, detail: detail, offset: offset, affectsTiming: affectsTiming), 1)
    }

    func collectedWarnings() -> [DecodeWarning] {
        warningOrder.compactMap { key in
            guard var entry = warningTable[key] else { return nil }
            if entry.count > 1 { entry.warning.detail += " (x\(entry.count))" }
            return entry.warning
        }
    }
}
