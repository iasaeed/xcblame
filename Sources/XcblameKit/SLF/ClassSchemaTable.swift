import Foundation

/// Token kinds a schema slot accepts. `object` is a class instance (`classRef` plus its fields).
public struct SLFKindSet: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let int = SLFKindSet(rawValue: 1 << 0)
    public static let double = SLFKindSet(rawValue: 1 << 1)
    public static let string = SLFKindSet(rawValue: 1 << 2)
    public static let json = SLFKindSet(rawValue: 1 << 3)
    public static let null = SLFKindSet(rawValue: 1 << 4)
    public static let array = SLFKindSet(rawValue: 1 << 5)
    public static let object = SLFKindSet(rawValue: 1 << 6)

    public init(_ kind: SLFTokenKind) {
        switch kind {
        case .int: self = .int
        case .double: self = .double
        case .string: self = .string
        case .json: self = .json
        case .null: self = .null
        case .array: self = .array
        case .classRef: self = .object
        case .classDef: self = []
        }
    }

    public func accepts(_ kind: SLFTokenKind) -> Bool { contains(SLFKindSet(kind)) }
}

/// Semantic slot names (XCLogParser field order, DESIGN §5.3). Int raw values index `SLFRecord` storage.
public enum SLFSlotName: Int, Sendable, CaseIterable {
    // Section family
    case sectionType, domainType, title, signature, start, end, subsections, text, messages
    case resultCode, wasCancelled, isQuiet, wasFetchedFromCache, extraInt, subtitle, location
    case commandDetails, uniqueIdentifier, localizedResult, xcbuildSignature, attachments, trailingInt
    // Message family
    case shortTitle, timeEmitted, rangeEndInSectionText, rangeStartInSectionText, submessages, severity, type
    case categoryIdent, secondaryLocations, additionalDescription
    // Location family
    case documentURL, timestamp, startLine, startColumn, endLine, endColumn
    case characterRangeEnd, characterRangeStart, locationEncoding
    // Attachment
    case identifier, majorVersion, minorVersion, data
    // IDEConsoleItem
    case adaptorType, content, kind
}

public struct SLFSchemaSlot: Sendable, Hashable {
    public var name: SLFSlotName
    public var accepts: SLFKindSet
    /// Position known, meaning not confirmed by a fixture (e.g. the v13 ints, MV-5).
    public var uncertainSemantics: Bool

    public init(_ name: SLFSlotName, _ accepts: SLFKindSet, uncertain: Bool = false) {
        self.name = name
        self.accepts = accepts
        self.uncertainSemantics = uncertain
    }
}

public enum SLFSchemaFamily: String, Sendable {
    case section, message, attachment, location, textLocation, consoleItem
}

/// One typed layout of a class family for a range of log format versions and layouts.
public struct SLFSchemaRow: Sendable {
    public var id: String
    public var family: SLFSchemaFamily
    public var formatVersions: ClosedRange<Int>
    public var layouts: Set<RawLog.Layout>
    public var slots: [SLFSchemaSlot]

    public init(id: String, family: SLFSchemaFamily, formatVersions: ClosedRange<Int>,
                layouts: Set<RawLog.Layout> = [.commandLine, .ide], slots: [SLFSchemaSlot]) {
        self.id = id
        self.family = family
        self.formatVersions = formatVersions
        self.layouts = layouts
        self.slots = slots
    }

    /// True when both rows accept the same kinds in slots `0..<count`.
    func sharesPrefix(with other: SLFSchemaRow, count: Int) -> Bool {
        guard slots.count >= count, other.slots.count >= count else { return false }
        for i in 0..<count where slots[i].accepts != other.slots[i].accepts { return false }
        return true
    }
}

/// How the decoder treats a class name.
public struct SLFClassSchema: Sendable {
    /// Nil for a fully opaque class (no known family).
    public var family: SLFSchemaFamily?
    /// Candidate rows, preferred first.
    public var rows: [SLFSchemaRow]
    /// The class may carry fields after the row (subclass of a known shape); extras are aligned and skipped.
    public var openTail: Bool
    /// Listed in the table (the 7 observed classes or the XCLogParser-known ones); unlisted names warn once.
    public var known: Bool
}

/// Typed slot rows per (class, format version, layout) (DESIGN §5.4). Version-dependent data lives here only.
public struct ClassSchemaTable: Sendable {
    public var rows: [SLFSchemaRow]
    /// Class name -> (family, open tail). Names not listed are mapped by suffix and warned about.
    public var classes: [String: (family: SLFSchemaFamily?, openTail: Bool)]

    public static let v1 = ClassSchemaTable(rows: defaultRows, classes: defaultClasses)

    public init(rows: [SLFSchemaRow], classes: [String: (family: SLFSchemaFamily?, openTail: Bool)]) {
        self.rows = rows
        self.classes = classes
    }

    public func schema(for className: String, version: Int?, layout: RawLog.Layout) -> SLFClassSchema {
        let known = classes[className]
        let entry = known ?? Self.familyBySuffix(className)
        guard let family = entry.family else {
            return SLFClassSchema(family: nil, rows: [], openTail: true, known: known != nil)
        }
        let v = min(max(version ?? 11, 0), 10_000)
        let familyRows = rows.filter { $0.family == family }
        let exact = familyRows.filter { $0.formatVersions.contains(v) && $0.layouts.contains(layout) }
        let rest = familyRows.filter { !($0.formatVersions.contains(v) && $0.layouts.contains(layout)) }
            .sorted { distance($0.formatVersions, v) < distance($1.formatVersions, v) }
        return SLFClassSchema(family: family, rows: exact + rest, openTail: entry.openTail, known: known != nil)
    }

    private func distance(_ range: ClosedRange<Int>, _ v: Int) -> Int {
        v < range.lowerBound ? range.lowerBound - v : max(0, v - range.upperBound)
    }

    static func familyBySuffix(_ name: String) -> (family: SLFSchemaFamily?, openTail: Bool) {
        if name.hasSuffix("Section") || name.hasSuffix("Log") { return (.section, true) }
        if name.hasSuffix("Message") { return (.message, true) }
        if name.hasSuffix("Location") { return (.location, true) }
        if name.hasSuffix("Attachment") { return (.attachment, true) }
        return (nil, true)
    }

    // MARK: - Data

    private static let str: SLFKindSet = [.string, .null]
    private static let list: SLFKindSet = [.array, .null]
    private static let obj: SLFKindSet = [.object, .null]

    /// Section family through the flag ints, shared by every row.
    private static let sectionHead: [SLFSchemaSlot] = [
        .init(.sectionType, .int), .init(.domainType, str), .init(.title, str), .init(.signature, str),
        .init(.start, .double), .init(.end, .double), .init(.subsections, list), .init(.text, str),
        .init(.messages, list),
    ]
    private static let flags: [SLFSchemaSlot] = [
        .init(.wasCancelled, .int), .init(.isQuiet, .int), .init(.wasFetchedFromCache, .int),
    ]
    private static let sectionTail: [SLFSchemaSlot] = [
        .init(.subtitle, str), .init(.location, obj), .init(.commandDetails, str), .init(.uniqueIdentifier, str),
        .init(.localizedResult, str), .init(.xcbuildSignature, str), .init(.attachments, list),
    ]

    static let defaultRows: [SLFSchemaRow] = [
        // v11 (Xcode 15.3 - 26.x): 19 slots + classRef = 20 tokens [RL].
        SLFSchemaRow(id: "section.v11", family: .section, formatVersions: 11...12,
                     slots: sectionHead + flags + sectionTail),
        // v13 (Xcode 27.1): two extra ints. Position of resultCode among the four ints follows XCLogParser
        // #261/#262; both ints are uncertain until a failed-task fixture exists (DESIGN §5.3, MV-5).
        SLFSchemaRow(id: "section.v13", family: .section, formatVersions: 13...Int.max,
                     slots: sectionHead + [.init(.resultCode, .int, uncertain: true)] + flags + sectionTail
                         + [.init(.trailingInt, .int, uncertain: true)]),
        // Tolerated: XCLogParser 0.2.45 reads an extra int before the subtitle from Xcode 26.2 (v11, not in corpus).
        SLFSchemaRow(id: "section.v11-extraInt", family: .section, formatVersions: 11...12,
                     slots: sectionHead + flags + [.init(.extraInt, .int, uncertain: true)] + sectionTail),
        // Tolerated: logs before attachments existed (SLF < 11).
        SLFSchemaRow(id: "section.v10", family: .section, formatVersions: 0...10,
                     slots: sectionHead + flags + Array(sectionTail.dropLast())),
        SLFSchemaRow(id: "message.v11", family: .message, formatVersions: 0...Int.max, slots: [
            .init(.title, str), .init(.shortTitle, str), .init(.timeEmitted, [.int, .double]),
            .init(.rangeEndInSectionText, .int), .init(.rangeStartInSectionText, .int),
            .init(.submessages, list), .init(.severity, .int), .init(.type, str), .init(.location, obj),
            .init(.categoryIdent, str), .init(.secondaryLocations, list), .init(.additionalDescription, str),
        ]),
        SLFSchemaRow(id: "attachment.v11", family: .attachment, formatVersions: 11...Int.max, slots: [
            .init(.identifier, str), .init(.majorVersion, .int), .init(.minorVersion, .int),
            .init(.data, [.json, .string, .null]),
        ]),
        SLFSchemaRow(id: "location.v11", family: .location, formatVersions: 0...Int.max, slots: [
            .init(.documentURL, str), .init(.timestamp, .double),
        ]),
        SLFSchemaRow(id: "textLocation.v11", family: .textLocation, formatVersions: 0...Int.max, slots: [
            .init(.documentURL, str), .init(.timestamp, .double), .init(.startLine, .int),
            .init(.startColumn, .int), .init(.endLine, .int), .init(.endColumn, .int),
            .init(.characterRangeEnd, .int), .init(.characterRangeStart, .int), .init(.locationEncoding, .int),
        ]),
        // Order from DESIGN research §1.4 (IDEConsoleItem{adaptorType,content,kind,timestamp}); kinds unverified.
        SLFSchemaRow(id: "consoleItem", family: .consoleItem, formatVersions: 0...Int.max, slots: [
            .init(.adaptorType, .int, uncertain: true), .init(.content, str, uncertain: true),
            .init(.kind, .int, uncertain: true), .init(.timestamp, .double, uncertain: true),
        ]),
    ]

    static let defaultClasses: [String: (family: SLFSchemaFamily?, openTail: Bool)] = [
        // Observed in v11 and v13 [RL].
        "IDECommandLineBuildLog": (.section, false),
        "IDEActivityLogSection": (.section, false),
        "IDEActivityLogCommandInvocationSection": (.section, false),
        "IDEDiagnosticActivityLogMessage": (.message, false),
        "IDEFoundation.IDEActivityLogSectionAttachment": (.attachment, false),
        "DVTDocumentLocation": (.location, false),
        "DVTTextDocumentLocation": (.textLocation, false),
        // XCLogParser-known (DESIGN §5.3); extra fields of subclasses are aligned and skipped.
        "IDEActivityLogMajorGroupSection": (.section, false),
        "IDEActivityLogUnitTestSection": (.section, true),
        "DBGConsoleLog": (.section, true),
        "IDEActivityLogMessage": (.message, false),
        "IDEActivityLogAnalyzerResultMessage": (.message, true),
        "IDEActivityLogAnalyzerControlFlowStepMessage": (.message, true),
        "IDEActivityLogAnalyzerEventStepMessage": (.message, true),
        "IDEActivityLogActionMessage": (.message, true),
        "IDEActivityLogSectionAttachment": (.attachment, false),
        "IDEConsoleItem": (.consoleItem, false),
        "Xcode3ProjectDocumentLocation": (.location, true),
        "IDELogDocumentLocation": (.location, true),
        "IBDocumentMemberLocation": (.location, true),
        "DVTMemberDocumentLocation": (.location, true),
    ]
}
