import Foundation

/// Reader-neutral input tree. The SLF reader (lane A) and the xcresult reader (lane B) both emit a `RawLog`;
/// `BuildModelBuilder` turns it into a `BuildModel`. Plain values only: readers fill what their format has and
/// leave the rest nil.
public struct RawLog: Sendable, Equatable {
    public enum Layout: String, Codable, Sendable { case commandLine, ide, xcresult }

    /// SLF log format version (11 for Xcode 26, 13 for Xcode 27.1); nil for xcresult.
    public var formatVersion: Int?
    public var layout: Layout
    public var root: RawSection
    /// Warnings raised by the reader (schema drift, unknown classes, truncation); carried into the model.
    public var decodeWarnings: [DecodeWarning]

    public init(formatVersion: Int? = nil, layout: Layout, root: RawSection, decodeWarnings: [DecodeWarning] = []) {
        self.formatVersion = formatVersion
        self.layout = layout
        self.root = root
        self.decodeWarnings = decodeWarnings
    }
}

/// One log section (SLF `IDEActivityLogSection` family, xcresult section object).
public struct RawSection: Sendable, Equatable {
    /// SLF-only slots. xcresult has none of them.
    public struct SLFOnly: Codable, Sendable, Equatable {
        public var wasCancelled: Bool?
        public var isQuiet: Bool?
        public var wasFetchedFromCache: Bool?
        public var uniqueIdentifier: String?
        /// Hex-encoded task signature slot: 1-byte prefix + UTF-8 task key (DESIGN §5.6).
        public var xcbuildSignatureHex: String?

        public init(wasCancelled: Bool? = nil, isQuiet: Bool? = nil, wasFetchedFromCache: Bool? = nil,
                    uniqueIdentifier: String? = nil, xcbuildSignatureHex: String? = nil) {
            self.wasCancelled = wasCancelled
            self.isQuiet = isQuiet
            self.wasFetchedFromCache = wasFetchedFromCache
            self.uniqueIdentifier = uniqueIdentifier
            self.xcbuildSignatureHex = xcbuildSignatureHex
        }
    }

    /// Display only; never used for decisions (DESIGN §4.3 rule 7).
    public var title: String
    public var domainType: String?
    public var sectionType: Int?
    /// SLF `signature` slot (xcresult: nil, its `commandDetails` carries the same text).
    public var signature: String?
    /// SLF `commandDetails` / xcresult `commandInvocationDetails.commandDetails`. First token is the rule name.
    public var commandDetails: String?
    /// Unix epoch seconds; meaningless when `timingMissing`.
    public var start: Double
    /// Unix epoch seconds; meaningless when `timingMissing`.
    public var end: Double
    /// The reader found no usable start or end (slot missing, untyped, negative sentinel). Never read as time 0.
    public var timingMissing: Bool
    public var resultCode: Int?
    public var emittedOutput: String?
    public var messages: [RawMessage]
    public var attachments: [RawAttachment]
    public var subsections: [RawSection]
    public var slfOnly: SLFOnly?
    public var location: RawLocation?

    public init(title: String = "", domainType: String? = nil, sectionType: Int? = nil, signature: String? = nil,
                commandDetails: String? = nil, start: Double = 0, end: Double = 0, resultCode: Int? = nil,
                emittedOutput: String? = nil, messages: [RawMessage] = [], attachments: [RawAttachment] = [],
                subsections: [RawSection] = [], slfOnly: SLFOnly? = nil, location: RawLocation? = nil,
                timingMissing: Bool = false) {
        self.title = title
        self.domainType = domainType
        self.sectionType = sectionType
        self.signature = signature
        self.commandDetails = commandDetails
        self.start = start
        self.end = end
        self.timingMissing = timingMissing
        self.resultCode = resultCode
        self.emittedOutput = emittedOutput
        self.messages = messages
        self.attachments = attachments
        self.subsections = subsections
        self.slfOnly = slfOnly
        self.location = location
    }
}

/// A log message (SLF `IDEActivityLogMessage` family, xcresult `messages[]`).
public struct RawMessage: Sendable, Equatable {
    public var title: String
    /// SLF severity int (0 notice, 1 warning, 2 error).
    public var severity: Int?
    /// xcresult `type`: "error", "warning", "notice", "analyzer warning".
    public var type: String?
    /// Display/grouping only; never used for severity (DESIGN §5.10).
    public var categoryIdent: String?
    public var location: RawLocation?
    public var submessages: [RawMessage]

    public init(title: String, severity: Int? = nil, type: String? = nil, categoryIdent: String? = nil,
                location: RawLocation? = nil, submessages: [RawMessage] = []) {
        self.title = title
        self.severity = severity
        self.type = type
        self.categoryIdent = categoryIdent
        self.location = location
        self.submessages = submessages
    }
}

/// `DVTTextDocumentLocation` / `DVTDocumentLocation` / xcresult `sourceURL`. Readers say which base their line and
/// column numbers use; the builder converts to 1-based.
public struct RawLocation: Sendable, Equatable {
    /// File URL (`file:///...`) or path. A `#fragment` is ignored.
    public var file: String?
    public var startLine: Int?
    public var startColumn: Int?
    public var endLine: Int?
    public var endColumn: Int?
    /// 0 when the format stores 0-based numbers (SLF), 1 when already 1-based.
    public var numberBase: Int

    public init(file: String? = nil, startLine: Int? = nil, startColumn: Int? = nil, endLine: Int? = nil,
                endColumn: Int? = nil, numberBase: Int = 0) {
        self.file = file
        self.startLine = startLine
        self.startColumn = startColumn
        self.endLine = endLine
        self.endColumn = endColumn
        self.numberBase = numberBase
    }
}

/// A section attachment: identifier (e.g. `com.apple.dt.ActivityLogSectionAttachment.TaskMetrics`) + raw JSON.
public struct RawAttachment: Sendable, Equatable {
    public var identifier: String
    public var majorVersion: Int?
    public var minorVersion: Int?
    public var data: Data

    public init(identifier: String, majorVersion: Int? = nil, minorVersion: Int? = nil, data: Data) {
        self.identifier = identifier
        self.majorVersion = majorVersion
        self.minorVersion = minorVersion
        self.data = data
    }
}
