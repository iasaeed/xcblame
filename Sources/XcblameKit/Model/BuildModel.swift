import Foundation

/// Reader-independent normalized build model (DESIGN §5.7). Field names map 1:1 onto the JSON report (§8.1).
/// Ids are indexes: `tasks[i].id == i`, `targets[i].id == i`, `diagnostics[i].id == i`.
public struct BuildModel: Codable, Sendable {
    public var readerKind: ReaderKind
    public var formatVersion: Int?
    public var layout: RawLog.Layout
    /// Unix epoch seconds.
    public var sessionStart: Double
    public var sessionEnd: Double
    public var tasks: [BuildTask]
    public var targets: [Target]
    public var diagnostics: [Diagnostic]
    public var decodeWarnings: [DecodeWarning]
    public var degradations: [Degradation]
    /// Share of task time in tasks of kind `other` (0...1; 0 when there is no task time).
    public var unclassifiedShare: Double
    /// Xcode's own "Build Timing Summary" aggregate; nil when the log has none.
    public var timingSummary: TimingSummary?
    /// Attachments on non-task sections (e.g. `BuildOperationMetrics`), raw.
    public var buildAttachments: [KeptAttachment]
    /// Version of the `KindTable` used to classify.
    public var kindTableVersion: String
    /// Actions of the input left out of the model (the xcresult clean action), one note each. Optional so older
    /// model dumps load.
    public var excludedActions: [String]? = nil
    /// Neither the root nor any task had a start and end: the session window (0...0) is not a measurement.
    public var sessionTimingMissing: Bool? = nil

    public var sessionSpan: Double { sessionEnd - sessionStart }
}

public enum ReaderKind: String, Codable, Sendable { case slf, xcresult }

/// Closed set (DESIGN §5.5). Tasks matching nothing are `other`.
public enum TaskKind: String, Codable, Sendable, CaseIterable {
    case swiftCompile, swiftPlan, swiftEmitModule, moduleScan, modulePrecompile, sdkStatCache, clangCompile, link
    case script, assets, resources, codesign, validate, copy, metadata, planning, packageResolution, aux, gate
    case clean, other
}

public enum Phase: String, Codable, Sendable, CaseIterable {
    case planning, compile, link, package, sign, other
}

public struct Interval: Codable, Sendable, Hashable {
    public var start: Double
    public var end: Double
    public var duration: Double { end - start }

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }
}

/// An executed task: the outermost section with a rule name (DESIGN §5.5).
public struct BuildTask: Codable, Sendable, Identifiable {
    /// How `kind` was decided.
    public enum KindSource: String, Codable, Sendable {
        /// `KindTable` hit on the rule name.
        case rule
        /// Invoked tool found in the command text or emitted output.
        case tool
        /// Nothing matched; kind is `other`.
        case none
    }

    public var id: Int
    public var ruleName: String
    public var kind: TaskKind
    public var kindSource: KindSource
    public var phase: Phase
    public var targetId: Int?
    /// Unix epoch seconds; from TaskMetrics when present, else the section.
    public var start: Double
    public var end: Double
    public var duration: Double
    public var resultCode: Int?
    public var metrics: TaskMetrics?
    public var backtrace: Backtrace?
    /// SLF task key (signature slot with the 1-byte prefix stripped, §5.6); nil for xcresult.
    public var taskKey: String?
    /// Nested sections (per-file children, extra parents); used for attribution only, never summed.
    public var subspans: [Subspan]
    public var commandDetails: String?
    public var signature: String?
    /// Display only.
    public var title: String
    public var emittedOutput: String?
    public var diagnosticIds: [Int]
    public var slfOnly: RawSection.SLFOnly?
    /// Attachments with unknown identifiers, raw JSON capped at 4 KB.
    public var unknownAttachments: [KeptAttachment]
    /// True when neither the section nor TaskMetrics gave a start and end: the task is counted and listed but never
    /// enters timing (and is never "reused"). Optional so older model dumps load.
    public var timingMissing: Bool? = nil

    public var hasTiming: Bool { timingMissing != true }
    public var interval: Interval { Interval(start: start, end: end) }
}

public struct Subspan: Codable, Sendable {
    public var ruleName: String?
    public var commandDetails: String?
    /// Display only.
    public var title: String
    public var interval: Interval
}

/// Decoded `TaskMetrics` attachment (§5.6). Placeholder records keep timing but drop CPU/RSS.
public struct TaskMetrics: Codable, Sendable, Hashable {
    /// Unix epoch seconds (wcStartTime is µs on the 2001 epoch).
    public var start: Double?
    public var duration: Double?
    /// Seconds of user CPU; nil for placeholders.
    public var userCPU: Double?
    public var systemCPU: Double?
    public var maxRSS: Int64?
    /// `maxRSS == 0 && utime == stime == wcDuration`: no CPU/RSS data.
    public var isPlaceholder: Bool

    public init(start: Double?, duration: Double?, userCPU: Double?, systemCPU: Double?, maxRSS: Int64?,
                isPlaceholder: Bool) {
        self.start = start
        self.duration = duration
        self.userCPU = userCPU
        self.systemCPU = systemCPU
        self.maxRSS = maxRSS
        self.isPlaceholder = isPlaceholder
    }
}

/// `TaskBacktrace` attachment: why the task ran.
public struct Backtrace: Codable, Sendable, Hashable {
    public struct Frame: Codable, Sendable, Hashable {
        public var category: String?
        public var description: String?
        // v0.5 lane B (`BacktraceAttachment`, probes-v0.5 §MV-2): optional, so older model dumps load.
        /// `genericTask` / `file` / `directory` / `swiftDriverJob` ...
        public var frameKind: String? = nil
        /// `task:<task key>` or `key:<BuildKey…>`.
        public var identifier: String? = nil
        public var previousFrameIdentifier: String? = nil
    }

    public var frames: [Frame]
}

public struct KeptAttachment: Codable, Sendable, Hashable {
    public var identifier: String
    public var data: Data
    public var truncated: Bool
}

public struct Target: Codable, Sendable, Identifiable {
    public var id: Int
    public var name: String
    public var project: String?
    /// The ` at path '…'` tail of the signature suffix (package targets).
    public var path: String?
    public var isPackage: Bool
    /// True for the `explicit modules` and `build system` buckets, which are not real targets.
    public var isBucket: Bool
    public var taskIds: [Int]

    public static let explicitModulesBucket = "explicit modules"
    public static let buildSystemBucket = "build system"
}

/// One row of Xcode's "Build Timing Summary": `<rule> (N tasks) | <seconds> seconds`.
public struct TimingSummary: Codable, Sendable, Hashable {
    public struct Row: Codable, Sendable, Hashable {
        public var ruleName: String
        public var taskCount: Int
        public var seconds: Double
    }

    public var rows: [Row]
}

public struct DecodeWarning: Codable, Sendable, Hashable {
    /// Open set; lanes add kinds with `extension DecodeWarning.Kind { static let x = Kind(rawValue: "x") }`.
    public struct Kind: RawRepresentable, Codable, Sendable, Hashable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// A record did not match its schema row; the decoder skipped values or dropped slots to realign.
        public static let schemaDrift = Kind(rawValue: "schemaDrift")
        /// Nothing realigned a record: the decoder skipped ahead to the next section instance at the same depth.
        public static let resync = Kind(rawValue: "resync")
        public static let unknownClass = Kind(rawValue: "unknownClass")
        public static let unknownAttachment = Kind(rawValue: "unknownAttachment")
        public static let invalidAttachment = Kind(rawValue: "invalidAttachment")
        public static let unknownDomain = Kind(rawValue: "unknownDomain")
        public static let invalidSignature = Kind(rawValue: "invalidSignature")
        public static let timingSummaryRow = Kind(rawValue: "timingSummaryRow")
        public static let truncated = Kind(rawValue: "truncated")
        /// The gzip stream inflated past the memory cap; the rest of the log was not read.
        public static let inflateCapReached = Kind(rawValue: "inflateCapReached")
    }

    public var kind: Kind
    public var detail: String
    /// Byte offset in the inflated log, when the reader knows it.
    public var offset: Int?
    /// The drifted or missing field is a timing field (section start/end, TaskMetrics start/duration). V14 keys on
    /// this flag, never on the wording of `detail`.
    public var affectsTiming: Bool

    public init(kind: Kind, detail: String, offset: Int? = nil, affectsTiming: Bool = false) {
        self.kind = kind
        self.detail = detail
        self.offset = offset
        self.affectsTiming = affectsTiming
    }

    private enum CodingKeys: String, CodingKey { case kind, detail, offset, affectsTiming }

    /// `affectsTiming` is optional in input so model dumps written before it existed still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        detail = try c.decode(String.self, forKey: .detail)
        offset = try c.decodeIfPresent(Int.self, forKey: .offset)
        affectsTiming = try c.decodeIfPresent(Bool.self, forKey: .affectsTiming) ?? false
    }
}

/// Marks the report `degraded` (DESIGN §4.3 rule 1, §6.11).
public struct Degradation: Codable, Sendable, Hashable {
    /// Open set, like `DecodeWarning.Kind`.
    public struct Kind: RawRepresentable, Codable, Sendable, Hashable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let classification = Kind(rawValue: "classification")
        public static let decode = Kind(rawValue: "decode")
        /// The input ended early (cut gzip, log still being written): the analysis covers only what was read.
        public static let truncated = Kind(rawValue: "truncated")
        /// The decoder realigned or resynchronised records (schema drift); affected values may be missing.
        public static let schemaDrift = Kind(rawValue: "schemaDrift")
        /// Finite but implausible times (beyond ±1e12 s): those tasks or the session window were left out of timing.
        public static let invalidTiming = Kind(rawValue: "invalidTiming")
    }

    public var kind: Kind
    public var detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }
}
