import Foundation

/// `xcblame verify` (`schemaVersion: "xcblame.verify/1"`, docs/SCHEMA-v0.6.md "Verify document"; DESIGN §7.8): the
/// A/B runs of one invocation, the noise band and a verdict per measured unit. Saved as a history verify entry
/// (`<xcblame-dir>/history/verify/<id>.json.gz`, never read by `previousIndex`, trend or baseline). Lane B builds it
/// (`Verifying`), lane C renders it. Frozen in phase 1: lanes add extensions in their own files only.
public struct VerifyDocument: Codable, Sendable, Equatable {
    public static let schemaVersion = "xcblame.verify/1"

    /// What each measured run is (`--kind`).
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case clean, incremental
        case zeroChange = "zero-change"
    }

    /// `A`: baseline (the plan's change absent). `B`: the unit's change delivered through `mechanism`.
    public enum Arm: String, Codable, Sendable, CaseIterable {
        case a = "A", b = "B"
    }

    /// Why a verify run stopped early (exit 6, DESIGN §8.4).
    public enum AbortReason: String, Codable, Sendable, CaseIterable {
        /// A file the plan touches (overlay, hooked xcconfig) has uncommitted changes.
        case dirtyTree
        /// Not on AC power.
        case onBattery
        /// Another xcodebuild is running.
        case xcodebuildRunning
        /// Thermal pressure stayed above nominal through a run and its one replacement.
        case thermal
        /// `--max-minutes` passed.
        case timeout
        /// An arm A run exited non-zero: nothing can be compared.
        case baselineBroken
        /// SIGINT/SIGTERM; the overlay was restored.
        case interrupted
        /// `--mechanism hook` without the hook installed for the configuration.
        case hookMissing
    }

    /// One xcodebuild invocation.
    public struct Run: Codable, Sendable, Equatable {
        public var arm: Arm
        /// 1-based within the arm, settle build included.
        public var index: Int
        /// The unmeasured settle build of a non-clean kind (first run of each arm).
        public var settle: Bool
        /// Exit code 0.
        public var ok: Bool
        public var exitCode: Int32
        /// Process wall seconds (`timing.processWall`), the verdict's basis.
        @Null public var wall: Double?
        /// Critical-path seconds of the run's log; nil when the path was not computed.
        @Null public var criticalPath: Double?
        /// First 16 hex of SHA-256 over the sorted `target\tkind\tcount` lines of executed tasks.
        @Null public var taskKindsHash: String?
        /// First 16 hex of SHA-256 over the sorted built target names.
        @Null public var targetSetHash: String?
        /// `ThermalProbe` state after the run (`nominal`, `fair`, `serious`, `critical`); nil when unknown.
        @Null public var thermal: String?
        /// Why the run is not a sample (`settle build`, `thermal: replaced by run 4`, `failed`); nil for a sample.
        @Null public var excluded: String?

        public init(arm: Arm, index: Int, settle: Bool, ok: Bool, exitCode: Int32, wall: Double?, criticalPath: Double?,
                    taskKindsHash: String?, targetSetHash: String?, thermal: String?, excluded: String?) {
            self.arm = arm
            self.index = index
            self.settle = settle
            self.ok = ok
            self.exitCode = exitCode
            self.wall = wall
            self.criticalPath = criticalPath
            self.taskKindsHash = taskKindsHash
            self.targetSetHash = targetSetHash
            self.thermal = thermal
            self.excluded = excluded
        }
    }

    /// The runs of one arm and their statistics over the samples (`excluded == nil`).
    public struct ArmResult: Codable, Sendable, Equatable {
        public var arm: Arm
        /// The arm's DerivedData (`<cache>/verify/<plan>/<A|B-…>/`; redactable); nil for `clean` interleaving
        /// without `-derivedDataPath`.
        @Null public var derivedData: String?
        public var runs: [Run]
        /// `runs.count`.
        public var runsTotal: Int
        /// Runs with `ok`.
        public var runsOk: Int
        /// Runs that count (`excluded == nil`).
        public var samples: Int
        /// Median of the samples' `wall`; nil without samples.
        @Null public var p50: Double?
        /// Median absolute deviation of the samples' `wall`; nil without samples.
        @Null public var mad: Double?

        public init(arm: Arm, derivedData: String?, runs: [Run], runsTotal: Int, runsOk: Int, samples: Int,
                    p50: Double?, mad: Double?) {
            self.arm = arm
            self.derivedData = derivedData
            self.runs = runs
            self.runsTotal = runsTotal
            self.runsOk = runsOk
            self.samples = samples
            self.p50 = p50
            self.mad = mad
        }
    }

    /// The verdict of one unit; `status`/`reason` use the plan's vocabulary.
    public struct Verdict: Codable, Sendable, Equatable {
        public var status: FixPlanDocument.VerifyStatus
        @Null public var reason: FixPlanDocument.RevertReason?
        /// Kept within the noise band because of `--keep-on-tie`.
        public var tie: Bool

        public init(status: FixPlanDocument.VerifyStatus, reason: FixPlanDocument.RevertReason? = nil, tie: Bool = false) {
            self.status = status
            self.reason = reason
            self.tie = tie
        }
    }

    /// A validity check of a unit (§7.8 step 5).
    public struct Check: Codable, Sendable, Equatable {
        /// Closed: `exitCode`, `targetSet`, `taskKinds`, `thermal`, `oracle` (the change reaches ≥ 1 target).
        public var name: String
        /// `pass` / `fail` / `warn` / `skipped`.
        public var status: String
        public var detail: String

        public init(name: String, status: String, detail: String) {
            self.name = name
            self.status = status
            self.detail = detail
        }
    }

    /// A precondition checked before the first build (§7.8 step 1).
    public struct Precondition: Codable, Sendable, Equatable {
        /// Closed: `cleanTree`, `power`, `thermal`, `otherBuild`, `hook`.
        public var name: String
        /// `pass` / `warn` / `fail` (a `fail` is the abort).
        public var status: String
        public var detail: String

        public init(name: String, status: String, detail: String) {
            self.name = name
            self.status = status
            self.detail = detail
        }
    }

    /// One measured unit: a rule (`--one-by-one`) or the batch of every selected rule.
    public struct UnitResult: Codable, Sendable, Equatable {
        /// One id with `--one-by-one`, else every rule of the batch, plan order.
        public var ruleIds: [String]
        /// Titles, same order.
        public var titles: [String]
        public var mechanism: FixPlanDocument.Mechanism
        /// Per-target scope under `mechanism` (from the oracle check before building).
        public var scope: [FixPlanDocument.ScopeRow]
        /// `A` then `B`. With `--one-by-one` the A runs are measured once and repeated in every unit.
        public var arms: [ArmResult]
        /// B.p50 − A.p50 seconds; nil when either is missing.
        @Null public var deltaSeconds: Double?
        /// `deltaSeconds` / A.p50.
        @Null public var deltaPct: Double?
        /// max(`madMultiplier` × pooled MAD, `minPct` × A.p50) seconds; nil when `indicative` or missing.
        @Null public var noiseBand: Double?
        public var verdict: Verdict
        public var checks: [Check]
        public var notes: [String]
        /// `VerifyBasis.combined` of the unit's steps when it was recorded (the plan's `verify.basis` of each, joined);
        /// a plan reuses this entry's verdict only when its steps give the same value. Nil when not recorded.
        @Added public var basis: String? = nil

        public init(ruleIds: [String], titles: [String], mechanism: FixPlanDocument.Mechanism,
                    scope: [FixPlanDocument.ScopeRow], arms: [ArmResult], deltaSeconds: Double?, deltaPct: Double?,
                    noiseBand: Double?, verdict: Verdict, checks: [Check], notes: [String], basis: String? = nil) {
            self.basis = basis
            self.ruleIds = ruleIds
            self.titles = titles
            self.mechanism = mechanism
            self.scope = scope
            self.arms = arms
            self.deltaSeconds = deltaSeconds
            self.deltaPct = deltaPct
            self.noiseBand = noiseBand
            self.verdict = verdict
            self.checks = checks
            self.notes = notes
        }
    }

    /// The constants the verdicts used (the v0.4 noise model, DESIGN §6.10, plus §7.8 step 4).
    public struct NoiseModel: Codable, Sendable, Equatable {
        public var madMultiplier: Double
        public var minPct: Double
        /// Samples per arm the band needs (v0.4 `minRunsForBand`).
        public var minSamples: Int
        /// `--runs` below this makes every verdict `indicative` (§7.8 step 4).
        public var minRuns: Int

        public init(madMultiplier: Double = 3, minPct: Double = 0.02, minSamples: Int = 3, minRuns: Int = 4) {
            self.madMultiplier = madMultiplier
            self.minPct = minPct
            self.minSamples = minSamples
            self.minRuns = minRuns
        }

        public static let v06 = NoiseModel()
    }

    public struct Abort: Codable, Sendable, Equatable {
        public var reason: AbortReason
        /// One plain sentence: what was found and what to do.
        public var detail: String

        public init(reason: AbortReason, detail: String) {
            self.reason = reason
            self.detail = detail
        }
    }

    public var schemaVersion: String
    public var tool: ReportDocument.Tool
    public var generatedAt: Date
    /// History verify entry id: `<yyyyMMdd-HHmmss>-verify`.
    public var id: String
    /// `FixPlanDocument.id` whose steps were measured.
    public var planId: String
    public var kind: Kind
    /// `--mechanism`; nil when each step used its planned mechanism (`results[].mechanism`).
    @Null public var mechanism: FixPlanDocument.Mechanism?
    /// `--runs` per arm (settle build included for non-clean kinds).
    public var runsPerArm: Int
    public var oneByOne: Bool
    public var keepOnTie: Bool
    @Null public var maxMinutes: Double?
    /// The file touched before each measured `incremental` run (`--touch`, or the one verify picked).
    @Null public var touch: String?
    @Null public var scheme: String?
    @Null public var configuration: String?
    /// The xcodebuild arguments both arms share (after `--`, or derived from the plan's analysis; redactable).
    public var xcodebuildArguments: [String]
    /// Always `processWall` in v0.6.
    public var wallBasis: String
    public var noiseModel: NoiseModel
    public var preconditions: [Precondition]
    public var results: [UnitResult]
    /// Non-nil: the run stopped (exit 6); `results` holds what finished, the rest `unverified`.
    @Null public var abort: Abort?
    public var elapsedSeconds: Double
    /// Inferred Xcode version of the runs.
    @Null public var xcode: String?
    /// `Mac15,14/28c/96g`.
    @Null public var machine: String?
    public var notes: [String]
    /// True once the Redactor ran on this document.
    public var redacted: Bool

    public init(schemaVersion: String = VerifyDocument.schemaVersion, tool: ReportDocument.Tool, generatedAt: Date,
                id: String, planId: String, kind: Kind, mechanism: FixPlanDocument.Mechanism?, runsPerArm: Int,
                oneByOne: Bool, keepOnTie: Bool, maxMinutes: Double?, touch: String?, scheme: String?,
                configuration: String?, xcodebuildArguments: [String], wallBasis: String = "processWall",
                noiseModel: NoiseModel = .v06, preconditions: [Precondition], results: [UnitResult], abort: Abort?,
                elapsedSeconds: Double, xcode: String?, machine: String?, notes: [String], redacted: Bool = false) {
        self.schemaVersion = schemaVersion
        self.tool = tool
        self.generatedAt = generatedAt
        self.id = id
        self.planId = planId
        self.kind = kind
        self.mechanism = mechanism
        self.runsPerArm = runsPerArm
        self.oneByOne = oneByOne
        self.keepOnTie = keepOnTie
        self.maxMinutes = maxMinutes
        self.touch = touch
        self.scheme = scheme
        self.configuration = configuration
        self.xcodebuildArguments = xcodebuildArguments
        self.wallBasis = wallBasis
        self.noiseModel = noiseModel
        self.preconditions = preconditions
        self.results = results
        self.abort = abort
        self.elapsedSeconds = elapsedSeconds
        self.xcode = xcode
        self.machine = machine
        self.notes = notes
        self.redacted = redacted
    }
}

/// Runs the A/B harness (lane B: `Verify/ABRun.swift`). An abort is returned in `abort` (the command exits 6), never
/// thrown; a throw is an internal error (exit 1).
public protocol Verifying: Sendable {
    func verify(_ request: VerifyRequest) throws -> VerifyDocument
}

/// Everything `verify` passes to the harness.
public struct VerifyRequest: Sendable {
    public var plan: FixPlanDocument
    /// `--rules`; nil for every step with overlay lines.
    public var rules: [String]?
    /// `--kind`; nil: each step's `verifyKind` (a batch with mixed kinds is a usage error).
    public var kind: VerifyDocument.Kind?
    public var runs: Int
    public var oneByOne: Bool
    public var keepOnTie: Bool
    public var maxMinutes: Double?
    /// `--mechanism`; nil: each step's planned mechanism.
    public var mechanism: FixPlanDocument.Mechanism?
    public var touch: String?
    /// After `--`; empty: derived from the plan's analysis build context.
    public var xcodebuildArguments: [String]
    public var xcblameDir: URL
    /// `OracleCache.home()`: per-arm DerivedData go to `<cacheHome>/verify/<plan>/`.
    public var cacheHome: URL
    /// `XCBLAME_XCODEBUILD` test hook; nil runs `xcrun xcodebuild`.
    public var executable: URL?
    public var generatedAt: Date

    public init(plan: FixPlanDocument, rules: [String]?, kind: VerifyDocument.Kind?, runs: Int, oneByOne: Bool,
                keepOnTie: Bool, maxMinutes: Double?, mechanism: FixPlanDocument.Mechanism?, touch: String?,
                xcodebuildArguments: [String], xcblameDir: URL, cacheHome: URL, executable: URL?, generatedAt: Date) {
        self.plan = plan
        self.rules = rules
        self.kind = kind
        self.runs = runs
        self.oneByOne = oneByOne
        self.keepOnTie = keepOnTie
        self.maxMinutes = maxMinutes
        self.mechanism = mechanism
        self.touch = touch
        self.xcodebuildArguments = xcodebuildArguments
        self.xcblameDir = xcblameDir
        self.cacheHome = cacheHome
        self.executable = executable
        self.generatedAt = generatedAt
    }
}
