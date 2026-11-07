import Foundation

/// `xcblame compare <a> <b>` (`schemaVersion: "xcblame.compare/1"`, docs/SCHEMA-v0.4.md "CompareDocument"). `a` is the
/// reference ("before"), `b` the build under test ("after"); every delta is `b - a`. Lane B fills it.
public struct CompareDocument: Codable, Sendable, Equatable {
    public static let schemaVersion = "xcblame.compare/1"

    /// Trimmed summary of one side: a report, or the runs of one side reduced to medians.
    public struct Side: Codable, Sendable, Equatable {
        /// `a` or `b`.
        public var label: String
        /// Report path, log path or history id (redactable).
        public var source: String
        public var runs: Int
        @Null public var generatedAt: Date?
        public var toolVersion: String
        @Null public var kind: String?
        @Null public var scheme: String?
        @Null public var configuration: String?
        @Null public var destination: String?
        /// Inferred Xcode version (`xcode.value`).
        @Null public var xcode: String?
        /// Medians over `runs`, seconds (`regression.wallBasis` for `wall`).
        @Null public var wall: Double?
        @Null public var busy: Double?
        @Null public var criticalPath: Double?
        public var tasks: Int
        public var errors: Int
        public var warnings: Int
        public var degraded: Bool
        @Null public var git: GitInfo?
        /// `Mac15,14/28c/96g`; nil without `environment`.
        @Null public var machine: String?

        public init(label: String, source: String, runs: Int, generatedAt: Date?, toolVersion: String, kind: String?,
                    scheme: String?, configuration: String?, destination: String?, xcode: String?, wall: Double?,
                    busy: Double?, criticalPath: Double?, tasks: Int, errors: Int, warnings: Int, degraded: Bool,
                    git: GitInfo?, machine: String?) {
            self.label = label
            self.source = source
            self.runs = runs
            self.generatedAt = generatedAt
            self.toolVersion = toolVersion
            self.kind = kind
            self.scheme = scheme
            self.configuration = configuration
            self.destination = destination
            self.xcode = xcode
            self.wall = wall
            self.busy = busy
            self.criticalPath = criticalPath
            self.tasks = tasks
            self.errors = errors
            self.warnings = warnings
            self.degraded = degraded
            self.git = git
            self.machine = machine
        }
    }

    /// A pair of numbers and their difference; nil members are unknown, never 0.
    public struct Pair: Codable, Sendable, Equatable {
        @Null public var a: Double?
        @Null public var b: Double?
        /// `b - a`; nil when either is nil.
        @Null public var delta: Double?
        /// `delta / a`, a fraction; nil when `a` is nil or 0.
        @Null public var deltaPct: Double?

        public init(a: Double?, b: Double?, delta: Double?, deltaPct: Double?) {
            self.a = a
            self.b = b
            self.delta = delta
            self.deltaPct = deltaPct
        }
    }

    /// One compared environment field. Only fields that differ are listed.
    public struct EnvDiff: Codable, Sendable, Equatable {
        /// `kind`, `scheme`, `configuration`, `destination`, `xcode`, `xcodeSelected`, `macOS`, `hwModel`, `cores`,
        /// `memGB`, `rosetta`, `ciProvider`, `branch`, `commit`, `dirty`, `toolVersion` (this is the listing order).
        public var field: String
        @Null public var a: String?
        @Null public var b: String?

        public init(field: String, a: String?, b: String?) {
            self.field = field
            self.a = a
            self.b = b
        }
    }

    /// One phase, target or path-composition row.
    public struct Row: Codable, Sendable, Equatable {
        /// Phase key, target name or `target: kind` for the path.
        public var key: String
        /// `changed` / `same` / `added` (only in b) / `removed` (only in a).
        public var status: String
        /// Task time (phases, targets) or on-path seconds (path rows).
        public var seconds: Pair
        /// Task count; nil for path rows.
        @Null public var tasks: Pair?
        /// The `other` row of a capped partition.
        public var isOther: Bool

        public init(key: String, status: String, seconds: Pair, tasks: Pair?, isOther: Bool) {
            self.key = key
            self.status = status
            self.seconds = seconds
            self.tasks = tasks
            self.isOther = isOther
        }
    }

    public struct CriticalPathDiff: Codable, Sendable, Equatable {
        /// `criticalPath.span`.
        public var span: Pair
        /// On-path seconds per target: the composition of each path, ordered by |delta|.
        public var byTarget: [Row]
        public var byTargetTotal: Int
        @Null public var byTargetShownShare: Double?
        public var notes: [String]

        public init(span: Pair, byTarget: [Row], byTargetTotal: Int, byTargetShownShare: Double?, notes: [String]) {
            self.span = span
            self.byTarget = byTarget
            self.byTargetTotal = byTargetTotal
            self.byTargetShownShare = byTargetShownShare
            self.notes = notes
        }
    }

    /// An executed task present on one side only.
    public struct TaskRef: Codable, Sendable, Equatable {
        public var rule: String
        @Null public var target: String?
        public var kind: String
        public var seconds: Double
        public var onPath: Bool
        /// The task's title (`Compiling Models.swift`); null when the side's rows came from a history entry.
        @Added public var title: String? = nil

        public init(rule: String, target: String?, kind: String, seconds: Double, onPath: Bool, title: String? = nil) {
            self.rule = rule
            self.target = target
            self.kind = kind
            self.seconds = seconds
            self.onPath = onPath
            self.title = title
        }
    }

    /// One task on both sides whose key and command line differ (a new Xcode rewrites them), paired by rule, target
    /// and title (`TaskIdentity.pairByOutput`): a changed task, not one new and one removed.
    public struct TaskChange: Codable, Sendable, Equatable {
        public var rule: String
        @Null public var target: String?
        public var kind: String
        @Null public var title: String?
        public var seconds: Pair
        /// On the critical path on either side.
        public var onPath: Bool

        public init(rule: String, target: String?, kind: String, title: String?, seconds: Pair, onPath: Bool) {
            self.rule = rule
            self.target = target
            self.kind = kind
            self.title = title
            self.seconds = seconds
            self.onPath = onPath
        }
    }

    /// New and removed tasks, matched as a multiset on `(rule, target, sigDigest)` from the task indexes.
    public struct TaskDiff: Codable, Sendable, Equatable {
        /// False when a side has no task index (a saved report without history rows): both lists are empty and a
        /// note says why.
        public var available: Bool
        /// Only in b, by seconds descending.
        public var added: [TaskRef]
        public var addedTotal: Int
        @Null public var addedShownShare: Double?
        /// Only in a, by seconds descending.
        public var removed: [TaskRef]
        public var removedTotal: Int
        @Null public var removedShownShare: Double?
        public var notes: [String]
        /// On both sides but with another key and command line, paired by title; by |b − a| descending.
        @Added public var changed: [TaskChange] = []
        @Added public var changedTotal: Int = 0
        @Added public var changedShownShare: Double? = nil

        public init(available: Bool, added: [TaskRef], addedTotal: Int, addedShownShare: Double?, removed: [TaskRef],
                    removedTotal: Int, removedShownShare: Double?, notes: [String], changed: [TaskChange] = [],
                    changedTotal: Int = 0, changedShownShare: Double? = nil) {
            self.changed = changed
            self.changedTotal = changedTotal
            self.changedShownShare = changedShownShare
            self.available = available
            self.added = added
            self.addedTotal = addedTotal
            self.addedShownShare = addedShownShare
            self.removed = removed
            self.removedTotal = removedTotal
            self.removedShownShare = removedShownShare
            self.notes = notes
        }
    }

    /// A setting whose value (or provenance) differs, from `findings[].evidenceDetails` of kind `setting`.
    public struct SettingDiff: Codable, Sendable, Equatable {
        /// `Target:Configuration:KEY` (`EvidenceItem.ref`).
        public var ref: String
        @Null public var a: String?
        @Null public var b: String?
        @Null public var provenanceA: String?
        @Null public var provenanceB: String?

        public init(ref: String, a: String?, b: String?, provenanceA: String?, provenanceB: String?) {
            self.ref = ref
            self.a = a
            self.b = b
            self.provenanceA = provenanceA
            self.provenanceB = provenanceB
        }
    }

    public var schemaVersion: String
    public var tool: ReportDocument.Tool
    public var generatedAt: Date
    public var a: Side
    public var b: Side
    /// Same value `analyze --baseline` embeds in a report; the headline of the view.
    public var regression: ReportDocument.Regression
    /// Differing environment fields, in the order listed on `EnvDiff.field` (environment first, DESIGN §6.10).
    public var env: [EnvDiff]
    /// Number of environment fields compared.
    public var envCompared: Int
    @Null public var phases: [Row]?
    @Null public var targets: [Row]?
    public var targetsTotal: Int
    @Null public var targetsShownShare: Double?
    @Null public var criticalPath: CriticalPathDiff?
    public var tasks: TaskDiff
    /// Nil when neither side carries setting evidence.
    @Null public var settings: [SettingDiff]?
    public var notes: [String]
    public var truncation: ReportDocument.Truncation
    /// True once the Redactor ran on this document.
    public var redacted: Bool

    public init(schemaVersion: String = CompareDocument.schemaVersion, tool: ReportDocument.Tool, generatedAt: Date,
                a: Side, b: Side, regression: ReportDocument.Regression, env: [EnvDiff], envCompared: Int,
                phases: [Row]?, targets: [Row]?, targetsTotal: Int, targetsShownShare: Double?,
                criticalPath: CriticalPathDiff?, tasks: TaskDiff, settings: [SettingDiff]?, notes: [String],
                truncation: ReportDocument.Truncation, redacted: Bool) {
        self.schemaVersion = schemaVersion
        self.tool = tool
        self.generatedAt = generatedAt
        self.a = a
        self.b = b
        self.regression = regression
        self.env = env
        self.envCompared = envCompared
        self.phases = phases
        self.targets = targets
        self.targetsTotal = targetsTotal
        self.targetsShownShare = targetsShownShare
        self.criticalPath = criticalPath
        self.tasks = tasks
        self.settings = settings
        self.notes = notes
        self.truncation = truncation
        self.redacted = redacted
    }
}
