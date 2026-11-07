import Foundation

/// Turns a reader's `RawLog` into a `BuildModel` (DESIGN §5.5, §5.6, §5.10).
///
/// Executed-task rule (structural, never by title): walking down from the root, a task is the OUTERMOST section that
/// (a) sits in a task-capable domain (`com.apple.dt.IDE.BuildLogSection`, no domain, or an unknown domain, which also
/// warns) and (b) has a rule name, i.e. a non-empty first token of `commandDetails` (falling back to `signature`).
/// Everything below a task is a sub-span: kept in `subspans` for attribution, never summed, so batch SwiftCompile
/// parents with per-file children count once. Container domains (`Xcode.IDEActivityLogDomainType.*`: the root and
/// `Building ...`/`Cleaning ...`) are walked through; sections without a rule name (Xcode 27's extra parents) are
/// walked through; `com.apple.dt.IDE.LogSection` (`Prepare packages`) and
/// `com.apple.dt.IDE.BuildLogTimingSummarySection` never yield tasks; `com.apple.dt.IDE.timing.aggregate` rows feed
/// `timingSummary` only.
public enum BuildModelBuilder {
    public static let buildLogSectionDomain = "com.apple.dt.IDE.BuildLogSection"
    public static let timingAggregateDomain = "com.apple.dt.IDE.timing.aggregate"
    public static let timingSummaryDomain = "com.apple.dt.IDE.BuildLogTimingSummarySection"
    public static let logSectionDomain = "com.apple.dt.IDE.LogSection"
    public static let containerDomainPrefix = "Xcode.IDEActivityLogDomainType."
    /// More unclassified task time than this marks the model `degraded: classification`.
    public static let unclassifiedThreshold = 0.05
    /// Unknown attachments keep at most this many bytes of raw JSON.
    public static let keptAttachmentLimit = 4096
    /// Seconds from 1970-01-01 to 2001-01-01.
    public static let appleEpochOffset = 978_307_200.0

    public static func build(_ raw: RawLog, reader: ReaderKind, kindTable: KindTable = .v1) -> BuildModel {
        let split = splitActions(raw, kindTable: kindTable)
        var model = buildModel(split.build, reader: reader, kindTable: kindTable)
        if !split.excluded.isEmpty { model.excludedActions = split.excluded.map(\.note) }
        return model
    }

    /// One action (or a whole single-action log) -> model.
    static func buildModel(_ raw: RawLog, reader: ReaderKind, kindTable: KindTable) -> BuildModel {
        var state = State(kindTable: kindTable)
        state.visit(raw.root, eligible: true)
        state.attributeTargets()

        var taskTime = 0.0
        var otherTime = 0.0
        var otherRules: [String: Double] = [:]
        for task in state.tasks where task.hasTiming && task.duration.isFinite && task.duration > 0 {
            taskTime += task.duration
            if task.kind == .other {
                otherTime += task.duration
                otherRules[task.ruleName, default: 0] += task.duration
            }
        }
        let share = taskTime > 0 ? otherTime / taskTime : 0
        var degradations: [Degradation] = []
        if share > unclassifiedThreshold {
            let top = otherRules.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(5).map { String(format: "%@ %.2fs", $0.key, $0.value) }
            degradations.append(Degradation(
                kind: .classification,
                detail: String(format: "%.1f%% of task time unclassified (", share * 100) + top.joined(separator: ", ") + ")"))
        }
        degradations += readerDegradations(raw.decodeWarnings + state.warnings)

        var sessionStart = raw.root.start
        var sessionEnd = raw.root.end
        var sessionTimingMissing = false
        if raw.root.timingMissing
            || !(sessionStart.isFinite && sessionEnd.isFinite && sessionEnd >= sessionStart && sessionEnd > 0) {
            let timed = state.tasks.filter(\.hasTiming)
            sessionStart = timed.map(\.start).min() ?? 0
            sessionEnd = timed.map(\.end).max() ?? sessionStart
            sessionTimingMissing = timed.isEmpty
        }

        var model = BuildModel(
            readerKind: reader, formatVersion: raw.formatVersion, layout: raw.layout,
            sessionStart: sessionStart, sessionEnd: sessionEnd,
            tasks: state.tasks, targets: state.targets, diagnostics: state.collector.diagnostics,
            decodeWarnings: raw.decodeWarnings + state.warnings, degradations: degradations,
            unclassifiedShare: share,
            timingSummary: state.timingRows.isEmpty ? nil : TimingSummary(rows: state.timingRows),
            buildAttachments: state.buildAttachments, kindTableVersion: kindTable.version)
        if sessionTimingMissing { model.sessionTimingMissing = true }
        return model
    }

    /// Reader warnings that make the analysis partial (DESIGN §4.3 rule 1, §5.2, §5.4): a truncated input, and any
    /// schema drift or resync (values may have been skipped).
    static func readerDegradations(_ warnings: [DecodeWarning]) -> [Degradation] {
        var result: [Degradation] = []
        if let cut = warnings.first(where: { $0.kind == .truncated }) {
            result.append(Degradation(kind: .truncated, detail: "input truncated, analysis covers only what was read ("
                + cut.detail + ")"))
        }
        let drift = warnings.filter { $0.kind == .schemaDrift || $0.kind == .resync }
        if let first = drift.first {
            let timing = drift.filter(\.affectsTiming).count
            result.append(Degradation(kind: .schemaDrift, detail: "\(drift.count) schema drift warning(s), "
                + "\(timing) on timing fields; first: \(first.detail)"))
        }
        return result
    }

    // MARK: - Pure helpers (internal for tests)

    enum DomainRole { case container, task, timingAggregate, nonTask, unknown }

    static func role(of domain: String?) -> DomainRole {
        guard let domain else { return .task }
        switch domain {
        case buildLogSectionDomain: return .task
        case timingAggregateDomain: return .timingAggregate
        case timingSummaryDomain, logSectionDomain: return .nonTask
        default: return domain.hasPrefix(containerDomainPrefix) ? .container : .unknown
        }
    }

    /// Splits one line on unescaped spaces/tabs, unescaping `\x` to `x`. Stops after `limit` tokens.
    static func escapedTokens(_ line: Substring, limit: Int = .max) -> [String] {
        var tokens: [String] = []
        var current = ""
        var escaped = false
        for ch in line {
            if tokens.count >= limit { break }
            if escaped {
                current.append(ch)
                escaped = false
            } else if ch == "\\" {
                escaped = true
            } else if ch == " " || ch == "\t" {
                if !current.isEmpty { tokens.append(current); current = "" }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty, tokens.count < limit { tokens.append(current) }
        return tokens
    }

    static func firstLine(_ text: String) -> Substring {
        text.prefix { !$0.isNewline }
    }

    /// First token of the command text, backslash-escaped spaces unescaped (`SwiftDriver\ Compilation` ->
    /// `SwiftDriver Compilation`). A line starting with whitespace has no rule name.
    static func ruleName(of section: RawSection) -> String? {
        let text = section.commandDetails.flatMap { $0.isEmpty ? nil : $0 } ?? section.signature
        guard let text, let first = text.first, !first.isWhitespace else { return nil }
        return escapedTokens(firstLine(text), limit: 1).first
    }

    /// A rule name from `signature` alone (no `commandDetails`) makes a task only when the signature also carries the
    /// `(in target ...)` suffix: a section whose command slot was lost to drift is walked through, not guessed.
    static func hasTaskEvidence(_ section: RawSection) -> Bool {
        if let details = section.commandDetails, !details.isEmpty { return true }
        guard let signature = section.signature else { return false }
        return targetSuffix(in: firstLine(signature)) != nil
    }

    /// `(in target 'X' from project 'Y')` or `(in target 'X' from project 'Y' at path '/p')`, last occurrence.
    static func targetSuffix(in line: Substring) -> (name: String, project: String, path: String?)? {
        guard let open = line.range(of: "(in target '", options: .backwards) else { return nil }
        let rest = line[open.upperBound...]
        guard let from = rest.range(of: "' from project '") else { return nil }
        let name = rest[..<from.lowerBound]
        let afterProject = rest[from.upperBound...]
        guard let quote = afterProject.firstIndex(of: "'"), !name.isEmpty else { return nil }
        let project = afterProject[..<quote]
        let tail = afterProject[quote...]
        if tail.hasPrefix("')") { return (String(name), String(project), nil) }
        let pathMarker = "' at path '"
        guard tail.hasPrefix(pathMarker), let close = tail.range(of: "')", options: .backwards),
              close.lowerBound >= tail.index(tail.startIndex, offsetBy: pathMarker.count) else { return nil }
        let path = tail[tail.index(tail.startIndex, offsetBy: pathMarker.count)..<close.lowerBound]
        return (String(name), String(project), String(path))
    }

    /// Last `/<Target>.build/` or `/<Target>-t.build/` segment of the first path argument after the rule name.
    static func pathTargetName(in line: Substring) -> String? {
        for token in escapedTokens(line).dropFirst() where token.contains("/") {
            let components = token.split(separator: "/")
            // The final component is the file itself; only directories count.
            guard let dir = components.dropLast().last(where: { $0.hasSuffix(".build") && $0.count > 6 }) else {
                continue
            }
            var name = dir.dropLast(6)
            if name.hasSuffix("-t"), name.count > 2 { name = name.dropLast(2) }
            return String(name)
        }
        return nil
    }

    /// Kind from the invoked tool (first token of a command or output line), for rule names the table lacks.
    static func toolKind(commandDetails: String?, emittedOutput: String?) -> TaskKind? {
        let tools: [String: TaskKind] = [
            "swift-frontend": .swiftCompile, "swiftc": .swiftCompile,
            "clang": .clangCompile, "clang++": .clangCompile,
            "ld": .link, "ld64": .link, "libtool": .link,
            "actool": .assets, "ibtool": .resources, "codesign": .codesign,
            "sh": .script, "bash": .script, "zsh": .script,
        ]
        let maxLines = 64
        for (text, skipFirst) in [(commandDetails, true), (emittedOutput, false)] {
            guard let text else { continue }
            var lines = text.split(whereSeparator: \.isNewline).prefix(maxLines)
            if skipFirst { lines = lines.dropFirst() }
            for line in lines {
                let trimmed = line.drop { $0.isWhitespace }
                guard let tool = escapedTokens(trimmed, limit: 1).first else { continue }
                let base = tool.split(separator: "/").last.map(String.init) ?? tool
                if let kind = tools[base] { return kind }
            }
        }
        return nil
    }

    static func decodeMetrics(_ data: Data) -> TaskMetrics? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func number(_ key: String) -> NSNumber? { obj[key] as? NSNumber }
        let wcStart = number("wcStartTime")?.doubleValue
        let wcDuration = number("wcDuration")?.doubleValue
        let utime = number("utime")?.doubleValue
        let stime = number("stime")?.doubleValue
        let rss = number("maxRSS")?.int64Value
        let placeholder = rss == 0 && utime != nil && utime == stime && stime == wcDuration
        return TaskMetrics(
            start: wcStart.map { $0 / 1_000_000 + appleEpochOffset },
            duration: wcDuration.map { $0 / 1_000_000 },
            userCPU: placeholder ? nil : utime.map { $0 / 1_000_000 },
            systemCPU: placeholder ? nil : stime.map { $0 / 1_000_000 },
            maxRSS: placeholder ? nil : rss,
            isPlaceholder: placeholder)
    }

    static func decodeBacktrace(_ data: Data) -> Backtrace? {
        BacktraceAttachment.decode(data)  // v0.5 lane B: keeps frame kind and identifiers (SLF/BacktraceAttachment.swift)
    }

    /// Hex signature slot -> task key: drop the 1-byte prefix, decode the rest as UTF-8 (with replacement).
    static func taskKey(fromSignatureHex hex: String) -> String? {
        let digits = Array(hex.utf8)
        guard digits.count >= 4, digits.count % 2 == 0 else { return nil }
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 97...102: return c - 87
            case 65...70: return c - 55
            default: return nil
            }
        }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(digits.count / 2)
        var i = 2  // skip the prefix byte
        while i + 1 < digits.count {
            guard let hi = nibble(digits[i]), let lo = nibble(digits[i + 1]) else { return nil }
            bytes.append(hi << 4 | lo)
            i += 2
        }
        guard nibble(digits[0]) != nil, nibble(digits[1]) != nil else { return nil }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `SwiftCompile (87 tasks) | 109.343 seconds` -> row. Manual split, no regex backtracking.
    static func parseTimingRow(_ text: String) -> TimingSummary.Row? {
        let line = firstLine(text)
        guard let bar = line.range(of: " | ", options: .backwards) else { return nil }
        let left = line[..<bar.lowerBound]
        var right = line[bar.upperBound...]
        for unit in [" seconds", " second"] where right.hasSuffix(unit) {
            right = right.dropLast(unit.count)
            break
        }
        guard let seconds = Double(right), seconds.isFinite, left.hasSuffix(")"),
              let open = left.range(of: " (", options: .backwards) else { return nil }
        let inner = left[open.upperBound..<left.index(before: left.endIndex)].split(separator: " ")
        // At most 18 digits, so sums over rows cannot overflow in practice (V5 also adds with saturation).
        guard inner.count == 2, inner[1] == "tasks" || inner[1] == "task", inner[0].count <= 18,
              let count = Int(inner[0]),
              open.lowerBound > left.startIndex else { return nil }
        return TimingSummary.Row(ruleName: String(left[..<open.lowerBound]), taskCount: count, seconds: seconds)
    }
}
