import Foundation

/// `xcblame trend` (`schemaVersion: "xcblame.trend/1"`, docs/SCHEMA-v0.4.md "TrendDocument"): percentiles over
/// `.xcblame/history`, summaries only (no task rows, no report bodies). Lane C fills it.
public struct TrendDocument: Codable, Sendable, Equatable {
    public static let schemaVersion = "xcblame.trend/1"

    /// What `--by` groups on.
    public enum By: String, Codable, Sendable, CaseIterable {
        case xcode, branch, commit, machine
    }

    /// The query that produced the document.
    public struct Filter: Codable, Sendable, Equatable {
        @Null public var kind: String?
        @Null public var scheme: String?
        @Null public var since: Date?
        /// Nil: one group (`key` nil).
        @Null public var by: By?

        public init(kind: String?, scheme: String?, since: Date?, by: By?) {
            self.kind = kind
            self.scheme = scheme
            self.since = since
            self.by = by
        }
    }

    /// One history entry as a point of a series.
    public struct Point: Codable, Sendable, Equatable {
        /// History entry id (`<yyyyMMdd-HHmmss>-<kind>`), what `history show` takes.
        public var id: String
        @Null public var time: Date?
        /// Seconds; `regression`-style basis: `processWall` else `span`. Nil when the entry withheld it.
        @Null public var wall: Double?
        @Null public var busy: Double?
        /// Inferred Xcode version.
        @Null public var xcode: String?
        /// Full commit hash from `environment.git`; nil for entries written before v0.4.
        @Null public var commit: String?
        @Null public var branch: String?
        /// `Mac15,14/28c/96g`.
        @Null public var machine: String?

        public init(id: String, time: Date?, wall: Double?, busy: Double?, xcode: String?, commit: String?,
                    branch: String?, machine: String?) {
            self.id = id
            self.time = time
            self.wall = wall
            self.busy = busy
            self.xcode = xcode
            self.commit = commit
            self.branch = branch
            self.machine = machine
        }
    }

    /// Percentiles of one metric over a series: linear interpolation between order statistics (R-7), so `p50` is the
    /// median. Nil members: no point has the metric.
    public struct Percentiles: Codable, Sendable, Equatable {
        public var n: Int
        @Null public var p50: Double?
        @Null public var p75: Double?
        @Null public var p95: Double?

        public init(n: Int, p50: Double?, p75: Double?, p95: Double?) {
            self.n = n
            self.p50 = p50
            self.p75 = p75
            self.p95 = p95
        }
    }

    /// Where the inferred Xcode version changes between two consecutive points of a series.
    public struct XcodeChange: Codable, Sendable, Equatable {
        /// Id of the first point on the new version.
        public var atId: String
        @Null public var from: String?
        @Null public var to: String?
        @Null public var time: Date?

        public init(atId: String, from: String?, to: String?, time: Date?) {
            self.atId = atId
            self.from = from
            self.to = to
            self.time = time
        }
    }

    /// The points of one build kind inside a group, oldest first.
    public struct Series: Codable, Sendable, Equatable {
        public var kind: String
        public var points: [Point]
        public var wall: Percentiles
        public var busy: Percentiles
        /// Between consecutive points whose `xcode` differs and is known on both sides; empty under `--by xcode`.
        public var xcodeChangeMarkers: [XcodeChange]

        public init(kind: String, points: [Point], wall: Percentiles, busy: Percentiles,
                    xcodeChangeMarkers: [XcodeChange]) {
            self.kind = kind
            self.points = points
            self.wall = wall
            self.busy = busy
            self.xcodeChangeMarkers = xcodeChangeMarkers
        }
    }

    /// One value of `--by` (or the single group without it).
    public struct Group: Codable, Sendable, Equatable {
        /// The `--by` value (`26.0`, `main`, a commit hash, a machine) or `unknown` when the entries carry none; nil
        /// without `--by`.
        @Null public var key: String?
        /// Points over all series of the group.
        public var entries: Int
        /// By kind name, ascending.
        public var series: [Series]

        public init(key: String?, entries: Int, series: [Series]) {
            self.key = key
            self.entries = entries
            self.series = series
        }
    }

    public var schemaVersion: String
    public var tool: ReportDocument.Tool
    public var generatedAt: Date
    public var filter: Filter
    /// History entries read (before the filter).
    public var entriesTotal: Int
    /// Entries that matched the filter and became points (`sum(groups[].entries)`).
    public var entriesUsed: Int
    /// Ordered by key ascending, `unknown` last; one group with a nil key without `--by`.
    public var groups: [Group]
    public var notes: [String]
    /// True once the Redactor ran on this document.
    public var redacted: Bool

    public init(schemaVersion: String = TrendDocument.schemaVersion, tool: ReportDocument.Tool, generatedAt: Date,
                filter: Filter, entriesTotal: Int, entriesUsed: Int, groups: [Group], notes: [String], redacted: Bool) {
        self.schemaVersion = schemaVersion
        self.tool = tool
        self.generatedAt = generatedAt
        self.filter = filter
        self.entriesTotal = entriesTotal
        self.entriesUsed = entriesUsed
        self.groups = groups
        self.notes = notes
        self.redacted = redacted
    }
}
