import Foundation

/// `.xcblame/baseline.json` (`schemaVersion: "xcblame.baseline/1"`, docs/SCHEMA-v0.4.md "Baseline"): summaries only,
/// meant to be committed. No paths of the build machine, no task commands, no file or hotspot rows. The functions are
/// in `BaselineBuild.swift`; the shape is frozen.
public struct Baseline: Codable, Sendable, Equatable {
    public static let schemaVersion = "xcblame.baseline/1"
    /// Default location relative to the xcblame state folder.
    public static let fileName = "baseline.json"

    /// Where the numbers came from.
    public struct Source: Codable, Sendable, Equatable {
        /// `report` (saved report JSON), `history` (history entries) or `log` (a build log analyzed on the spot).
        public var kind: String
        /// One per run: report file names, history ids or log file names (basenames only, never absolute paths).
        public var refs: [String]

        public init(kind: String, refs: [String]) {
            self.kind = kind
            self.refs = refs
        }
    }

    /// The build identity a baseline is valid for (DESIGN §6.10: scheme, configuration, destination, kind, Xcode).
    public struct Key: Codable, Sendable, Equatable {
        @Null public var kind: String?
        @Null public var scheme: String?
        @Null public var configuration: String?
        @Null public var destination: String?
        /// Inferred Xcode version (`xcode.value`), e.g. `26.0`.
        @Null public var xcode: String?

        public init(kind: String?, scheme: String?, configuration: String?, destination: String?, xcode: String?) {
            self.kind = kind
            self.scheme = scheme
            self.configuration = configuration
            self.destination = destination
            self.xcode = xcode
        }
    }

    /// One metric over the runs, seconds.
    public struct Stat: Codable, Sendable, Equatable {
        @Null public var median: Double?
        /// Median absolute deviation of the runs around `median` (unscaled); 0 with one run.
        @Null public var mad: Double?

        public init(median: Double?, mad: Double?) {
            self.median = median
            self.mad = mad
        }
    }

    /// Optional digests of the executed tasks, for new/removed-task attribution without the log.
    public struct TaskDigests: Codable, Sendable, Equatable {
        /// Executed tasks of the (median-wall) run.
        public var total: Int
        /// Sorted, unique 16-hex digests: first 8 bytes of SHA256(`rule \t target \t sigDigest`), where `sigDigest` is
        /// `History.TaskIndexRow.sigDigest`.
        public var ids: [String]

        public init(total: Int, ids: [String]) {
            self.total = total
            self.ids = ids
        }
    }

    public var schemaVersion: String
    public var tool: ReportDocument.Tool
    public var savedAt: Date
    public var source: Source
    public var key: Key
    /// `processWall` or `span`, as `ReportDocument.Regression.wallBasis`; one basis for all runs.
    public var wallBasis: String
    /// Runs behind the medians.
    public var runs: Int
    public var wall: Stat
    public var busy: Stat
    public var criticalPath: Stat
    /// `environment.git` of the first run: nil when it was not captured.
    @Null public var git: GitInfo?
    /// `Mac15,14/28c/96g` (model, logical cores, memory GB); nil when `environment` was not captured.
    @Null public var machine: String?
    @Null public var tasks: TaskDigests?
    public var notes: [String]

    public init(schemaVersion: String = Baseline.schemaVersion, tool: ReportDocument.Tool, savedAt: Date,
                source: Source, key: Key, wallBasis: String, runs: Int, wall: Stat, busy: Stat, criticalPath: Stat,
                git: GitInfo?, machine: String?, tasks: TaskDigests?, notes: [String]) {
        self.schemaVersion = schemaVersion
        self.tool = tool
        self.savedAt = savedAt
        self.source = source
        self.key = key
        self.wallBasis = wallBasis
        self.runs = runs
        self.wall = wall
        self.busy = busy
        self.criticalPath = criticalPath
        self.git = git
        self.machine = machine
        self.tasks = tasks
        self.notes = notes
    }

}
