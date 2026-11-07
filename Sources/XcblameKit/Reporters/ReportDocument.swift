import Foundation

/// The JSON report, `schemaVersion: "xcblame.report/1"` (DESIGN §8.1). The subset v0.1 can fill; everything unknown
/// is an explicit `null` with a reason in the nearest `notes`, never `0`. Capped arrays carry `<name>Total` and
/// `<name>ShownShare`. Both reporters render from this one value, so text and JSON cannot disagree (§8.2.1).
public struct ReportDocument: Codable, Sendable, Equatable {
    public static let schemaVersion = "xcblame.report/1"

    public struct Tool: Codable, Sendable, Equatable {
        public var name: String
        public var version: String
        public var kindTable: String
    }

    public struct Input: Codable, Sendable, Equatable {
        public var reader: String
        public var layout: String
        @Null public var logFormatVersion: Int?
        @Null public var path: String?
        public var decodeWarnings: Int
        /// Parts of the input not analyzed (the xcresult clean action), one note each.
        public var excludedActions: [String]
    }

    public struct Xcode: Codable, Sendable, Equatable {
        @Null public var value: String?
        @Null public var source: String?
        /// Why `value` was chosen, strongest first (DESIGN §5.9).
        public var evidence: [String]
        public var notes: [String]
    }

    public struct Parallelism: Codable, Sendable, Equatable {
        /// Task time / busy time.
        @Null public var average: Double?
        /// Withheld (null) with the other timing numbers when V1 fails.
        @Null public var peak: Int?
    }

    public struct Build: Codable, Sendable, Equatable {
        /// `clean` / `incremental` / ...; classification does not exist in v0.1.
        @Null public var kind: String?
        /// Why `kind` was chosen, strongest signal first (DESIGN §6.7); empty while `kind` is null.
        public var kindEvidence: [String]
        /// Log span in seconds.
        @Null public var span: Double?
        @Null public var taskTime: Double?
        @Null public var busy: Double?
        @Null public var idle: Double?
        public var parallelism: Parallelism
        /// Tasks that entered timing.
        public var tasks: Int
        /// Tasks in the model before exclusions.
        public var tasksInModel: Int
        /// Excluded as up to date (reused from an earlier build or fetched from cache).
        public var tasksReused: Int
        /// Excluded for NaN, infinite or negative times.
        public var tasksInvalid: Int
        /// Intervals clamped to the session window.
        public var tasksClamped: Int
        /// Tasks with no start or end in the log (kept in counts, excluded from timing), first `topN`.
        public var tasksWithoutTiming: [UntimedTask]
        public var tasksWithoutTimingTotal: Int
        public var notes: [String]
        // v0.4 members (docs/SCHEMA-v0.4.md "Build context"). `@Added`: nil until the build context capture lands.
        /// `-scheme` of the build; nil when not known (a log analyzed without its manifest, a project-less run).
        @Added public var scheme: String? = nil
        /// `-configuration` (`Debug`, `Release`, ...).
        @Added public var configuration: String? = nil
        /// Human destination, e.g. `macOS arm64` or `iOS Simulator iPhone 17`.
        @Added public var destination: String? = nil
        // v0.5 member (docs/SCHEMA-v0.5.md). Null until build-level cache counters are read (lane C).
        /// Compilation-cache counters; null when the log has none (most builds), with a note.
        @Added public var cache: BuildCache? = nil
    }

    public struct UntimedTask: Codable, Sendable, Equatable {
        public var id: Int
        public var rule: String
        public var kind: String
        @Null public var target: String?
        public var title: String
    }

    public struct Metrics: Codable, Sendable, Equatable {
        public var tasks: Int
        public var tasksWithCPU: Int
        public var placeholdersIgnored: Int
        @Null public var cpuSeconds: Double?
        public var tasksWithRSS: Int
        @Null public var maxRSSBytes: Int64?
        public var notes: [String]
    }

    /// One row of the kind or phase rollup.
    public struct Row: Codable, Sendable, Equatable {
        public var key: String
        public var tasks: Int
        public var taskTime: Double
        @Null public var share: Double?
        /// The `other` / `unclassified` row of the partition.
        public var isOther: Bool
    }

    public struct TargetRow: Codable, Sendable, Equatable {
        @Null public var id: Int?
        public var name: String
        @Null public var project: String?
        @Null public var isPackage: Bool?
        @Null public var isBucket: Bool?
        public var tasks: Int
        public var taskTime: Double
        @Null public var share: Double?
        public var isOther: Bool
        /// `app` / `localPackage` / `remotePackage` / `pods` / `macroPlugin` / `systemModules` / `buildSystem` /
        /// `unknown` (DESIGN §6.4).
        @Null public var owner: String?
        /// Seconds of this target's tasks on the critical path.
        @Null public var onPathSeconds: Double?
        /// Critical-path saving if this target took no time (DAG basis only, §6.2 step 6).
        @Null public var whatIfSeconds: Double?
        /// Union of this target's task intervals.
        @Null public var busy: Double?
        /// Kind mix: task time per kind for this target, a partition of `taskTime` (§8.2.2).
        @Null public var kinds: [Row]?
    }

    public struct TopTask: Codable, Sendable, Equatable {
        public var id: Int
        public var rule: String
        public var kind: String
        @Null public var target: String?
        public var seconds: Double
        public var startOffset: Double
        public var title: String
    }

    public struct Check: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var status: String
        @Null public var detail: String?
    }

    public struct Validation: Codable, Sendable, Equatable {
        public var checks: [Check]
        public var degraded: Bool
        public var notes: [String]
    }

    public struct DegradationEntry: Codable, Sendable, Equatable {
        public var kind: String
        public var detail: String
    }

    public struct DecodeWarningEntry: Codable, Sendable, Equatable {
        public var kind: String
        public var detail: String
        @Null public var offset: Int?
    }

    // MARK: - v0.2 members (docs/SCHEMA-v0.2.md; additive to schema v1)

    /// Which build description (DESIGN §5.11) the task DAG came from.
    public struct Graph: Codable, Sendable, Equatable {
        /// `snapshot` (`.xcblame/snapshots/<log-uuid>/`), `live` (DerivedData `XCBuildData`) or `none`.
        public var basis: String
        @Null public var signature: String?
        /// Directory the description was read from.
        @Null public var path: String?
        /// Commands in `manifest.json`.
        @Null public var commands: Int?
        /// Model tasks with a task key; `keyedTasks + unkeyedTasks == build.tasksInModel`.
        public var keyedTasks: Int
        public var unkeyedTasks: Int
        public var notes: [String]
    }

    public struct PathSegment: Codable, Sendable, Equatable {
        /// Seconds from the session window start.
        public var start: Double
        public var end: Double
        public var seconds: Double
        /// `seconds / criticalPath.span`.
        @Null public var share: Double?
        /// `dag` / `byTiming` / `inferred`.
        public var basis: String
        @Null public var target: String?
        @Null public var targetId: Int?
        public var label: String
        /// Model task ids in this segment, in path order.
        public var taskIds: [Int]
    }

    public struct PathWait: Codable, Sendable, Equatable {
        public var start: Double
        public var end: Double
        public var seconds: Double
    }

    public struct WhatIf: Codable, Sendable, Equatable {
        public var target: String
        @Null public var targetId: Int?
        /// Path span minus the span with every task of `target` at duration 0.
        public var savingIfZero: Double
        /// Same with every task of `target` at half its duration.
        public var savingIfHalf: Double
    }

    public struct CriticalPath: Codable, Sendable, Equatable {
        public var span: Double
        /// `dag` / `inferred` / `mixed`.
        public var basis: String
        public var segments: [PathSegment]
        public var segmentsTotal: Int
        @Null public var segmentsShownShare: Double?
        public var waits: [PathWait]
        /// DAG basis only; null under inference.
        @Null public var whatIf: [WhatIf]?
        public var notes: [String]
    }

    public struct Utilization: Codable, Sendable, Equatable {
        /// max(0.1, span / 4000).
        public var bucketSeconds: Double
        /// Average running tasks per bucket, from the session window start.
        public var lanes: [Double]
    }

    public struct SerialStretch: Codable, Sendable, Equatable {
        public var start: Double
        public var end: Double
        /// Most lanes running at any time inside the stretch (≤ `serialThresholdLanes`).
        public var lanes: Int
    }

    public struct Gap: Codable, Sendable, Equatable {
        public var start: Double
        public var end: Double
    }

    /// Sweep-line results of DESIGN §6.3 beyond the `build` headline numbers.
    public struct TimingSection: Codable, Sendable, Equatable {
        @Null public var utilization: Utilization?
        @Null public var serialStretches: [SerialStretch]?
        public var serialStretchesTotal: Int
        @Null public var serialStretchesShownShare: Double?
        /// max(1, floor(0.10 × physical cores)).
        @Null public var serialThresholdLanes: Int?
        /// Sum of all serial stretch lengths (before capping).
        @Null public var serialSeconds: Double?
        @Null public var idleGaps: [Gap]?
        public var idleGapsTotal: Int
        @Null public var idleGapsShownShare: Double?
        /// Same value as `build.parallelism.peak`.
        @Null public var peakLanes: Int?
        /// xcodebuild process wall time; only measured by `xcblame build`.
        @Null public var processWall: Double?
        /// `processWall - build.span`, floored at 0.
        @Null public var outsideLogSeconds: Double?
        public var notes: [String]
    }

    public struct FileRow: Codable, Sendable, Equatable {
        public var path: String
        @Null public var target: String?
        @Null public var targetId: Int?
        public var seconds: Double
        /// `exact` / `batch` / `estimated` / `wmo` (DESIGN §6.4).
        public var granularity: String
        @Null public var batchSize: Int?
        @Null public var members: [String]?
        public var onPath: Bool
        @Null public var typeCheckMs: Double?
        @Null public var taskId: Int?
    }

    public struct Hotspot: Codable, Sendable, Equatable {
        public var file: String
        public var line: Int
        public var col: Int
        public var declaration: String
        public var kind: String
        public var ms: Double
        /// `debugTimeFunctionBodies` / `debugTimeExpression` / `warnLong` / `statsDir` / `ftimeTrace`.
        public var source: String
        /// 1 when the file's compile task is on the critical path, else 0.25 (§6.5).
        public var onPathWeight: Double
        public var occurrences: Int
        @Null public var target: String?
        @Null public var taskId: Int?
    }

    /// DESIGN §7.2, flattened; populated from v0.3 (docs/SCHEMA-v0.3.md).
    public struct Finding: Codable, Sendable, Equatable {
        public var ruleId: String
        public var title: String
        /// `info` / `low` / `medium` / `high` (`RuleSpec.Severity`, what `--fail-on` compares).
        @Null public var severity: String?
        @Null public var impactBand: String?
        @Null public var impactSeconds: Double?
        @Null public var impactBasis: String?
        public var confidence: String
        public var evidence: [String]
        @Null public var fixKind: String?
        @Null public var risk: String?
        @Null public var mechanism: String?
        // v0.3 members.
        /// Dedupe key (RULES.md §10); unique across `findings`.
        public var signalKey: String
        /// Targets the finding covers (project and package target names); empty for project-wide findings.
        public var scopeTargets: [String] = []
        /// Configuration names it covers; empty when not configuration-specific.
        public var scopeConfigurations: [String] = []
        /// Structured form of `evidence`, same order.
        public var evidenceDetails: [EvidenceItem] = []
        /// Commands the fix plan prints for this finding, in order (`xcblame verify --rules …`, `xcblame fix …`).
        public var fixCommands: [String] = []
        /// Overlay lines (`KEY = VALUE // xcblame SET-016`) for `overlay*` fixes, else empty.
        public var overlayLines: [String] = []
        /// Rules that fired on the same `signalKey` and were folded into this one.
        public var seeAlso: [String] = []
        /// The rule's Xcode range (`26+`); nil when it applies to all versions.
        @Null public var xcode: String? = nil
        public var sources: [String] = []
        /// Static-only or [K]-gated: impact unknown until `analyze`/`verify` measures it (shown as "needs measurement").
        public var needsMeasurement: Bool = false
        /// v0.5 clarity: where to make the change in Xcode, one line per change, with the Build Settings labels Xcode
        /// shows (`Build Settings › Compilation Mode (SWIFT_COMPILATION_MODE) for Acme, Debug: Whole Module →
        /// Incremental (singlefile)`, `Target Acme › Build Phases › Run Script "Lint": …`); empty when there is none.
        @Added public var inXcode: [String] = []
        /// v0.5 clarity: the rule catalog's band (`XS`/`S`/`M`/`L`) when `impactBand` is `?` (not measured on this
        /// build): an estimate from published data, used to rank actions; nil when the catalog has no band or the
        /// cost was measured.
        @Added public var estimatedBand: String? = nil

        /// The measured band, else the catalog estimate; nil when neither is known.
        public var effectiveBand: String? {
            if let band = impactBand, band != "?" { return band }
            return estimatedBand
        }
    }

    /// One structured evidence item of a finding (DESIGN §7.2).
    public struct EvidenceItem: Codable, Sendable, Equatable {
        /// `setting` / `phase` / `package` / `file` / `task` / `env` / `report`.
        public var kind: String
        /// What it points at: `Acme:Debug:SWIFT_COMPILATION_MODE`, a phase id, a package URL, a path, a task id.
        public var ref: String
        @Null public var value: String?
        /// `Provenance.Level` raw value (plus file) for a setting; nil otherwise.
        @Null public var provenance: String?

        public init(kind: String, ref: String, value: String? = nil, provenance: String? = nil) {
            self.kind = kind
            self.ref = ref
            self.value = value
            self.provenance = provenance
        }
    }

    /// `rules explain` text for a rule present in `findings` (§8.2.2).
    public struct RuleDoc: Codable, Sendable, Equatable {
        public var title: String
        public var summary: String
        public var fix: String
        public var sources: [String]
        // v0.3 members.
        public var id: String
        /// ID prefix: `SET`, `PHASE`, ...
        public var category: String
        /// RULES.md notation: `overlay(D)`, `cli`, `rec`, ...
        public var applyKinds: [String]
        /// `+V`.
        public var verifyOnly: Bool
        public var risk: String
        /// `P` / `S` / `K` / mixed (`S/K`).
        public var evidenceTag: String
    }

    /// One rule that did not produce a finding (passed, not applicable, suppressed).
    public struct RuleOutcome: Codable, Sendable, Equatable {
        public var ruleId: String
        public var title: String
        /// Why, one line: `Debug: singlefile`, `no script phases`, `see SET-012 (same signal)`.
        public var detail: String

        public init(ruleId: String, title: String, detail: String) {
            self.ruleId = ruleId
            self.title = title
            self.detail = detail
        }
    }

    /// The project a doctor (or analyze-with-rules) run read (§8.2.4 doctor header).
    public struct ProjectSection: Codable, Sendable, Equatable {
        /// Container path (redactable).
        public var container: String
        /// `pbxproj` / `xcproj` / `package`.
        public var format: String
        @Null public var objectVersion: Int?
        /// `xcodegen` / `tuist` / other name; nil when not generated.
        @Null public var generator: String?
        /// Project targets across projects.
        public var targets: Int
        /// Targets the oracle lists that are not project targets (SPM package targets); nil without oracle output.
        @Null public var packageTargets: Int?
        public var localPackages: Int
        public var remotePackages: Int
        /// `cocoapods` / `carthage` / `spm`.
        public var dependencyManagers: [String]
        public var schemes: Int
        /// `xcodebuild -showBuildSettings -json` / `offline resolver`; nil when no settings were read.
        @Null public var settingsSource: String?
        /// Configurations evaluated.
        public var configurations: [String]
        public var notes: [String]
    }

    /// `doctor` bookkeeping (and, under `analyze`, the passed and not-applicable lists).
    public struct DoctorSection: Codable, Sendable, Equatable {
        public var passed: [RuleOutcome]
        public var notApplicable: [RuleOutcome]
        public var suppressed: [RuleOutcome]
        /// Distinct rule ids across `findings`, `passed`, `notApplicable`, `suppressed`.
        public var rulesEvaluated: Int
        /// Wall time of the doctor run; nil under `analyze`.
        @Null public var durationSeconds: Double?
        public var offline: Bool
        /// `--fail-on` value (`low` / `medium` / `high`); nil when not given or `none`.
        @Null public var failOn: String?
        /// A finding at or above `failOn` exists (exit 4).
        public var failed: Bool
    }

    /// One step of the printed fix plan, in order.
    public struct FixPlanStep: Codable, Sendable, Equatable {
        /// 1-based, consecutive.
        public var order: Int
        public var ruleId: String
        public var command: String
        @Null public var note: String?
        /// v0.5 clarity: `verify` (measure before keeping), `fix` (xcblame applies it), `check` (record a build to
        /// compare against), `manual` (`command` is a change made by hand in Xcode, not a shell command) or `command`;
        /// null in reports written before it existed.
        @Added public var kind: String? = nil
        /// v0.6 (docs/SCHEMA-v0.6.md Decisions, 2026-11-05; optional, additive): the rule's verify state from the newest
        /// stored fix plan that measured it, in the text spelling (`kept`, `kept (tie)`, `reverted (slower)`, …,
        /// `indicative`); null when no stored plan verified the rule (or the report was written before v0.6).
        @Added public var verifyStatus: String? = nil

        public init(order: Int, ruleId: String, command: String, note: String?, kind: String? = nil,
                    verifyStatus: String? = nil) {
            self.order = order
            self.ruleId = ruleId
            self.command = command
            self.note = note
            self.kind = kind
            self.verifyStatus = verifyStatus
        }
    }

    // MARK: - v0.4 members (docs/SCHEMA-v0.4.md; additive to schema v1)

    /// One deduped error or warning (DESIGN §5.10). Feeds the `agent` format and the `github` annotations.
    public struct DiagnosticEntry: Codable, Sendable, Equatable {
        /// `error` / `warning`.
        public var severity: String
        @Null public var file: String?
        /// 1-based.
        @Null public var line: Int?
        /// 1-based.
        @Null public var column: Int?
        /// First line of the message, at most 300 characters.
        public var message: String
        /// How often it was emitted (the dedupe count).
        public var occurrences: Int

        public init(severity: String, file: String?, line: Int?, column: Int?, message: String, occurrences: Int) {
            self.severity = severity
            self.file = file
            self.line = line
            self.column = column
            self.message = message
            self.occurrences = occurrences
        }
    }

    /// `regression` (DESIGN §6.10): this build against a baseline. Present only when `--baseline` was given and could
    /// be evaluated. The same value is `CompareDocument.regression`.
    public struct Regression: Codable, Sendable, Equatable {
        /// What the current numbers were compared against.
        public struct BaselineRef: Codable, Sendable, Equatable {
            /// `file` (a `.xcblame/baseline.json`), `history` (entries picked by a history query) or `report`
            /// (a saved report or log given to `compare`).
            public var source: String
            /// Path, history id or report path (redactable); nil when there is none.
            @Null public var ref: String?
            @Null public var savedAt: Date?
            /// The baseline's build key.
            @Null public var kind: String?
            @Null public var scheme: String?
            @Null public var configuration: String?
            @Null public var destination: String?
            @Null public var xcode: String?
            /// Runs behind the baseline medians.
            public var runs: Int

            public init(source: String, ref: String?, savedAt: Date?, kind: String?, scheme: String?,
                        configuration: String?, destination: String?, xcode: String?, runs: Int) {
                self.source = source
                self.ref = ref
                self.savedAt = savedAt
                self.kind = kind
                self.scheme = scheme
                self.configuration = configuration
                self.destination = destination
                self.xcode = xcode
                self.runs = runs
            }
        }

        /// One metric, seconds. Medians when a side has several runs.
        public struct Delta: Codable, Sendable, Equatable {
            @Null public var baseline: Double?
            @Null public var current: Double?
            /// `current - baseline`; nil when either side is unknown.
            @Null public var delta: Double?
            /// `delta / baseline`, a fraction (0.052 = +5.2 %); nil when `baseline` is nil or 0.
            @Null public var deltaPct: Double?

            public init(baseline: Double?, current: Double?, delta: Double?, deltaPct: Double?) {
                self.baseline = baseline
                self.current = current
                self.delta = delta
                self.deltaPct = deltaPct
            }
        }

        /// The noise model of DESIGN §6.10.
        public struct NoiseBand: Codable, Sendable, Equatable {
            /// `mad` (≥ 3 runs on each side) or `threshold` (fewer: only the threshold plus allowance applies).
            public var method: String
            /// `sqrt((madBaseline² + madCurrent²) / 2)` of the wall metric; nil under `threshold`.
            @Null public var pooledMad: Double?
            /// 3.
            public var madMultiplier: Double
            /// 0.02: a delta under 2 % is noise whatever the MAD says.
            public var minPct: Double
            /// Seconds: `max(madMultiplier × pooledMad, minPct × baseline wall)`; nil under `threshold`.
            @Null public var band: Double?
            public var runsBaseline: Int
            public var runsCurrent: Int

            public init(method: String, pooledMad: Double?, madMultiplier: Double, minPct: Double, band: Double?,
                        runsBaseline: Int, runsCurrent: Int) {
                self.method = method
                self.pooledMad = pooledMad
                self.madMultiplier = madMultiplier
                self.minPct = minPct
                self.band = band
                self.runsBaseline = runsBaseline
                self.runsCurrent = runsCurrent
            }
        }

        /// One reason for the delta. The list is ordered `env`, `phase`, `target`, `path`, `task`, `setting`
        /// (environment first, DESIGN §6.10), each group by |deltaSeconds| descending.
        public struct Attribution: Codable, Sendable, Equatable {
            /// `env` / `phase` / `target` / `path` / `task` / `setting`.
            public var kind: String
            /// `xcode`, a phase key, a target name, `AcmeApp: SwiftCompile`, a setting ref, ...
            public var subject: String
            /// One line, e.g. `26.0 -> 26.1 (inferred)` or `+1.30 s on the critical path`.
            public var detail: String
            @Null public var deltaSeconds: Double?

            public init(kind: String, subject: String, detail: String, deltaSeconds: Double?) {
                self.kind = kind
                self.subject = subject
                self.detail = detail
                self.deltaSeconds = deltaSeconds
            }
        }

        public var baseline: BaselineRef
        /// `faster` / `slower` / `same` (≥ 3 runs per side, outside or inside the band) or `indicative` (fewer).
        public var verdict: String
        /// `processWall` when both sides measured it, else `span` (`build.span`).
        public var wallBasis: String
        public var wall: Delta
        public var busy: Delta
        public var criticalPath: Delta
        public var noiseBand: NoiseBand
        public var attribution: [Attribution]
        /// `--fail-if-slower <pct>` as a fraction; nil when not given.
        @Null public var thresholdPct: Double?
        /// 0.05: added to the threshold when the verdict is `indicative`.
        public var allowancePct: Double
        /// A threshold was given and exceeded (exit 3). Always false without a threshold.
        public var failed: Bool
        public var notes: [String]

        public init(baseline: BaselineRef, verdict: String, wallBasis: String, wall: Delta, busy: Delta,
                    criticalPath: Delta, noiseBand: NoiseBand, attribution: [Attribution], thresholdPct: Double?,
                    allowancePct: Double, failed: Bool, notes: [String]) {
            self.baseline = baseline
            self.verdict = verdict
            self.wallBasis = wallBasis
            self.wall = wall
            self.busy = busy
            self.criticalPath = criticalPath
            self.noiseBand = noiseBand
            self.attribution = attribution
            self.thresholdPct = thresholdPct
            self.allowancePct = allowancePct
            self.failed = failed
            self.notes = notes
        }
    }

    // MARK: - v0.5 members (docs/SCHEMA-v0.5.md; additive to schema v1)

    /// `incremental` (DESIGN §6.6): every executed task of a non-clean build gets exactly one primary cause. Null for a
    /// clean build, a doctor document, or when timing was withheld (a note says why).
    public struct Incremental: Codable, Sendable, Equatable {
        /// The previous build of the same build key whose task index was compared.
        public struct PreviousBuild: Codable, Sendable, Equatable {
            /// History entry id (`history show` takes it).
            public var id: String
            @Null public var time: Date?

            public init(id: String, time: Date?) {
                self.id = id
                self.time = time
            }
        }

        /// One executed task of a cause. Never a command line, a signature digest or compiler output.
        public struct CauseTask: Codable, Sendable, Equatable {
            /// Task key (§5.6); nil for unkeyed tasks.
            @Null public var key: String?
            /// Short label (`Explain.label` style: `compile Models.swift`, `PhaseScriptExecution Lint`).
            public var label: String
            @Null public var target: String?
            /// `TaskKind` raw value.
            public var kind: String
            public var seconds: Double
            /// Seconds of this task on the critical path (0 when off the path; nil without a critical path).
            @Null public var pathSeconds: Double?
            /// Model task id; nil when the document was re-rendered from history.
            @Null public var taskId: Int?

            public init(key: String?, label: String, target: String?, kind: String, seconds: Double,
                        pathSeconds: Double?, taskId: Int?) {
                self.key = key
                self.label = label
                self.target = target
                self.kind = kind
                self.seconds = seconds
                self.pathSeconds = pathSeconds
                self.taskId = taskId
            }
        }

        /// One primary cause. A task belongs to exactly one cause (V15).
        public struct Cause: Codable, Sendable, Equatable {
            /// Stable id `<class>:<subject>` (`scriptPhase:Acme/Lint`, `inputChanged:$REPO/Sources/A.swift`,
            /// `unknown`); `byTaskTime` and `byPathSeconds` name causes by it.
            public var id: String
            /// `Incremental.classes` (closed vocabulary).
            public var `class`: String
            /// One line for humans: `Run Script "Lint" (Acme) declares no outputs, so it runs on every build`.
            public var cause: String
            /// The evidence that decided it (`Incremental.sources`, closed vocabulary, precedence order of §6.6).
            public var source: String
            /// What the cause points at: a file, target, phase or setting (paths redactable); nil for `unknown`.
            @Null public var subject: String?
            /// Primary evidence lines, `<source>: <detail>`.
            public var evidence: [String]
            /// Later-precedence evidence that also matched (kept, never counted), `<source>: <detail>`.
            public var secondaryEvidence: [String]
            /// Tasks of this cause by seconds descending, capped at `--top` (html: all).
            public var tasks: [CauseTask]
            public var tasksTotal: Int
            @Null public var tasksShownShare: Double?
            /// Σ task time of every task of this cause (direct, or as the root of a `ruleInputRebuilt` chain).
            public var seconds: Double
            /// Σ critical-path seconds of those tasks; nil without a critical path.
            @Null public var pathSeconds: Double?
            /// Rule that explains or fixes it (`PHASE-001`, `DYN-002`, `ENV-008`); nil when none.
            @Null public var ruleId: String?
            /// v0.5 clarity: one line on what to do about it ("Nothing to change: …" when it is Xcode's own work or
            /// expected after an edit); null in reports written before it existed.
            @Added public var whatToDo: String? = nil

            public init(id: String, class: String, cause: String, source: String, subject: String?,
                        evidence: [String], secondaryEvidence: [String], tasks: [CauseTask], tasksTotal: Int,
                        tasksShownShare: Double?, seconds: Double, pathSeconds: Double?, ruleId: String?,
                        whatToDo: String? = nil) {
                self.whatToDo = whatToDo
                self.id = id
                self.class = `class`
                self.cause = cause
                self.source = source
                self.subject = subject
                self.evidence = evidence
                self.secondaryEvidence = secondaryEvidence
                self.tasks = tasks
                self.tasksTotal = tasksTotal
                self.tasksShownShare = tasksShownShare
                self.seconds = seconds
                self.pathSeconds = pathSeconds
                self.ruleId = ruleId
            }
        }

        /// The partition invariant of §6.6, computed on the full model before any cap.
        public struct V15: Codable, Sendable, Equatable {
            /// `pass` / `fail` / `skipped` (closed).
            public var status: String
            /// Executed task time of the build (`build.taskTime`).
            @Null public var executedSeconds: Double?
            /// Σ `causes[].seconds`, `unknown` included.
            @Null public var sumOfCauses: Double?

            public init(status: String, executedSeconds: Double?, sumOfCauses: Double?) {
                self.status = status
                self.executedSeconds = executedSeconds
                self.sumOfCauses = sumOfCauses
            }
        }

        /// One xcodebuild run of the `why` procedure.
        public struct ProcedureBuild: Codable, Sendable, Equatable {
            /// `settle` / `measure` / `repeat` (the second zero-change build of the DYN-002 check).
            public var role: String
            public var exitCode: Int
            @Null public var wall: Double?
            /// Executed tasks, and executed compile/plan/emit-module/link tasks (`BuildKind.workKinds`).
            @Null public var executedTasks: Int?
            @Null public var executedWorkTasks: Int?
            /// History entry id of this build; nil when not recorded.
            @Null public var historyId: String?

            public init(role: String, exitCode: Int, wall: Double?, executedTasks: Int?, executedWorkTasks: Int?,
                        historyId: String?) {
                self.role = role
                self.exitCode = exitCode
                self.wall = wall
                self.executedTasks = executedTasks
                self.executedWorkTasks = executedWorkTasks
                self.historyId = historyId
            }
        }

        /// How `xcblame why` produced the measured build; nil for `analyze` / `build` / `why` without `--`.
        public struct Procedure: Codable, Sendable, Equatable {
            /// `zeroChange` (settle, then an unchanged build) / `touch` (settle, touch, build).
            public var mode: String
            /// `--touch` file (redactable); nil in `zeroChange` mode.
            @Null public var touched: String?
            public var builds: [ProcedureBuild]
            /// `--backtraces`: `off` / `on` (temporary scheme copy used) / `unavailable` (with a note, MV-2).
            public var backtraces: String
            /// `--show-incremental` passed `-driver-show-incremental`.
            public var showIncremental: Bool

            public init(mode: String, touched: String?, builds: [ProcedureBuild], backtraces: String,
                        showIncremental: Bool) {
                self.mode = mode
                self.touched = touched
                self.builds = builds
                self.backtraces = backtraces
                self.showIncremental = showIncremental
            }
        }

        /// Closed vocabulary of `Cause.class`, the order the HTML cause tree lists them.
        public static let classes = ["inputChanged", "scriptPhase", "settingsChanged", "upstreamInterface",
                                     "timestampChurn", "planning", "firstBuild", "forced", "driverRemark", "unknown"]
        /// Closed vocabulary of `Cause.source`, in the precedence order of DESIGN §6.6.
        public static let sources = ["backtrace", "script", "signature", "upstreamInterface", "mtimeChurn", "planning",
                                     "driverRemark", "unknown"]

        /// `previousIndex` (a history task index of the same build key was compared) / `currentLogOnly` (§6.6:
        /// backtraces and static script I/O only; everything else is `unknown`).
        public var basis: String
        @Null public var previousBuild: PreviousBuild?
        /// Every cause with at least one task, `unknown` last; never capped (the tasks inside are).
        public var causes: [Cause]
        /// Σ seconds of the `unknown` cause (0 when every task has a cause).
        public var unknownSeconds: Double
        /// `unknownSeconds / v15.executedSeconds`; nil when no task time.
        @Null public var unknownShare: Double?
        /// Cause ids by `seconds` descending (ties: id ascending).
        public var byTaskTime: [String]
        /// Cause ids by `pathSeconds` descending; empty without a critical path. Never added to `byTaskTime`.
        public var byPathSeconds: [String]
        public var v15: V15
        @Null public var procedure: Procedure?
        public var notes: [String]

        public init(basis: String, previousBuild: PreviousBuild?, causes: [Cause], unknownSeconds: Double,
                    unknownShare: Double?, byTaskTime: [String], byPathSeconds: [String], v15: V15,
                    procedure: Procedure?, notes: [String]) {
            self.basis = basis
            self.previousBuild = previousBuild
            self.causes = causes
            self.unknownSeconds = unknownSeconds
            self.unknownShare = unknownShare
            self.byTaskTime = byTaskTime
            self.byPathSeconds = byPathSeconds
            self.v15 = v15
            self.procedure = procedure
            self.notes = notes
        }
    }

    /// One fixed-cost class (DESIGN §6.8): work that runs on (nearly) every build regardless of edits.
    public struct FixedCost: Codable, Sendable, Equatable {
        /// `FixedCost.classes` (open vocabulary; new classes are additive).
        public var `class`: String
        /// Task time of this class in this build; nil for a `static` entry whose tasks did not run here.
        @Null public var seconds: Double?
        /// `seconds × perDayAssumedBuilds`; nil when `seconds` is nil.
        @Null public var perDay: Double?
        /// Builds per day behind `perDay`.
        public var perDayAssumedBuilds: Int
        /// Where that number came from: `history` (this scheme's builds per day), `config` (`buildsPerDay` in
        /// `.xcblame/config.json`) or `assumed` (50; the HTML labels it "assumption").
        public var perDayBasis: String
        /// `zeroChange` (executed in a zero-change build), `historyFrequency` (in > 80 % of this scheme's incremental
        /// builds in history) or `static` (scripts without outputs, upload scripts, linters, build-tool plugins).
        public var basis: String
        public var tasks: [Incremental.CauseTask]
        public var tasksTotal: Int
        @Null public var tasksShownShare: Double?

        /// Classes of §6.8, in display order.
        public static let classes = ["scripts", "codesign", "validate", "embedCopy", "infoPlist", "appIntents",
                                     "executionPolicy", "planning", "sdkStatCache", "packageResolution",
                                     "swiftPlanning", "macroBuilds", "outsideLog"]

        public init(class: String, seconds: Double?, perDay: Double?, perDayAssumedBuilds: Int, perDayBasis: String,
                    basis: String, tasks: [Incremental.CauseTask], tasksTotal: Int, tasksShownShare: Double?) {
            self.class = `class`
            self.seconds = seconds
            self.perDay = perDay
            self.perDayAssumedBuilds = perDayAssumedBuilds
            self.perDayBasis = perDayBasis
            self.basis = basis
            self.tasks = tasks
            self.tasksTotal = tasksTotal
            self.tasksShownShare = tasksShownShare
        }
    }

    /// `moduleGraph` (DESIGN §6.9, §8.2.2): target graph metrics, variants and the SVG graph.
    public struct ModuleGraph: Codable, Sendable, Equatable {
        public struct ChainLink: Codable, Sendable, Equatable {
            public var target: String
            /// The target's critical-path seconds (the chain weight).
            public var seconds: Double

            public init(target: String, seconds: Double) {
                self.target = target
                self.seconds = seconds
            }
        }

        public struct Degree: Codable, Sendable, Equatable {
            public var target: String
            public var count: Int

            public init(target: String, count: Int) {
                self.target = target
                self.count = count
            }
        }

        public struct Blocker: Codable, Sendable, Equatable {
            public var target: String
            /// Task seconds of dependents that start after this target's emit-module (or last task) ends.
            public var gatedSeconds: Double

            public init(target: String, gatedSeconds: Double) {
                self.target = target
                self.gatedSeconds = gatedSeconds
            }
        }

        public struct MacroPlugins: Codable, Sendable, Equatable {
            public var module: String
            public var plugins: Int
            /// Plugin module names (`-load-plugin-executable …#Name`, or the project's macro targets).
            public var names: [String]

            public init(module: String, plugins: Int, names: [String]) {
                self.module = module
                self.plugins = plugins
                self.names = names
            }
        }

        public struct ModuleVariant: Codable, Sendable, Equatable {
            public var module: String
            public var variants: Int
            /// Flags that differ between the variants (`-fapinotes-swift-version=6`, `-Xcc -D SWIFT_PACKAGE`, ...).
            public var flags: [String]
            /// `ModuleGraph.variantCauses` values classified from `flags`.
            public var causes: [String]
            @Null public var pcmTasks: Int?
            /// Task time of the variants beyond the first (the avoidable part, V12).
            @Null public var redundantSeconds: Double?

            public init(module: String, variants: Int, flags: [String], causes: [String], pcmTasks: Int?,
                        redundantSeconds: Double?) {
                self.module = module
                self.variants = variants
                self.flags = flags
                self.causes = causes
                self.pcmTasks = pcmTasks
                self.redundantSeconds = redundantSeconds
            }
        }

        public struct Variants: Codable, Sendable, Equatable {
            /// Modules in the modules reports (`Summary.csv`).
            public var modules: Int
            @Null public var pcmTasks: Int?
            /// PCM tasks beyond the first variant of each module.
            @Null public var redundantTasks: Int?
            @Null public var redundantSeconds: Double?
            /// Distinct causes across modules (`variantCauses`), most redundant seconds first.
            public var causes: [String]
            /// Modules with ≥ 2 variants, by redundant seconds then variants descending; capped at `--top`.
            public var perModule: [ModuleVariant]
            public var perModuleTotal: Int
            @Null public var perModuleShownShare: Double?

            public init(modules: Int, pcmTasks: Int?, redundantTasks: Int?, redundantSeconds: Double?,
                        causes: [String], perModule: [ModuleVariant], perModuleTotal: Int,
                        perModuleShownShare: Double?) {
                self.modules = modules
                self.pcmTasks = pcmTasks
                self.redundantTasks = redundantTasks
                self.redundantSeconds = redundantSeconds
                self.causes = causes
                self.perModule = perModule
                self.perModuleTotal = perModuleTotal
                self.perModuleShownShare = perModuleShownShare
            }
        }

        /// One SVG node: a target, or a collapse group (`collapsed` > 0) standing for that many targets of one owner.
        public struct Node: Codable, Sendable, Equatable {
            /// Target name, or `more:<owner>` for a collapse group. Edges refer to it.
            public var id: String
            /// Display name (`N more modules (remotePackage)` for a group).
            public var name: String
            @Null public var owner: String?
            /// Longest dependency path below this node (leaves are 0); the SVG layer.
            public var depth: Int
            @Null public var variants: Int?
            @Null public var macroPlugins: Int?
            @Null public var onPathSeconds: Double?
            @Null public var taskTime: Double?
            /// Targets folded into this node; 0 for a plain target.
            public var collapsed: Int

            public init(id: String, name: String, owner: String?, depth: Int, variants: Int?, macroPlugins: Int?,
                        onPathSeconds: Double?, taskTime: Double?, collapsed: Int) {
                self.id = id
                self.name = name
                self.owner = owner
                self.depth = depth
                self.variants = variants
                self.macroPlugins = macroPlugins
                self.onPathSeconds = onPathSeconds
                self.taskTime = taskTime
                self.collapsed = collapsed
            }
        }

        /// `from` depends on `to` (node ids).
        public struct Edge: Codable, Sendable, Equatable {
            public var from: String
            public var to: String
            /// Both ends on `criticalChain`, consecutive.
            public var critical: Bool

            public init(from: String, to: String, critical: Bool) {
                self.from = from
                self.to = to
                self.critical = critical
            }
        }

        /// Closed vocabulary of variant causes (§6.9).
        public static let variantCauses = ["languageMode", "swiftPackage", "macros", "other"]
        /// Most nodes drawn; beyond it, targets off the critical chain and its neighbours collapse by owner.
        public static let nodeCap = 300
        /// Closed vocabulary of `source` (v0.5 integration adds `project`).
        public static let sources = ["targetGraph", "project", "log", "none"]

        /// `targetGraph` (`target-graph.txt` of the build description), `project` (`PBXTargetDependency` edges of the
        /// `.xcodeproj` named by `--project` or by the log's DerivedData, read-only; no build description), `log` (task
        /// targets, no edges) or `none`.
        public var source: String
        public var targets: Int
        /// Longest dependency path, in edges; nil without edges.
        @Null public var depth: Int?
        /// Weighted by critical-path seconds, root first; empty without a critical path.
        public var longestChain: [ChainLink]
        @Null public var longestChainSeconds: Double?
        /// Top 10 by count (ranking views of the nodes, not capped tables: `targets` is their total).
        public var fanIn: [Degree]
        public var fanOut: [Degree]
        /// Fan-in > 50 % of the targets.
        public var umbrellaCandidates: [String]
        /// Each cycle as its target names; empty when acyclic.
        public var cycles: [[String]]
        /// Top 10 by gated seconds.
        public var blockers: [Blocker]
        /// Modules with ≥ 1 macro plugin, most plugins first.
        public var macroPluginsPerModule: [MacroPlugins]
        /// Null when no modules report (clang/swift) was found, with a note.
        @Null public var variants: Variants?
        /// Target names of the critical chain (§8.2.2), root first.
        public var criticalChain: [String]
        public var nodes: [Node]
        /// Targets in the graph before collapse (= `targets`).
        public var nodesTotal: Int
        /// Share of `nodesTotal` drawn as plain nodes; nil when 0.
        @Null public var nodesShownShare: Double?
        public var edges: [Edge]
        public var edgesTotal: Int
        @Null public var edgesShownShare: Double?
        public var notes: [String]

        public init(source: String, targets: Int, depth: Int?, longestChain: [ChainLink], longestChainSeconds: Double?,
                    fanIn: [Degree], fanOut: [Degree], umbrellaCandidates: [String], cycles: [[String]],
                    blockers: [Blocker], macroPluginsPerModule: [MacroPlugins], variants: Variants?,
                    criticalChain: [String], nodes: [Node], nodesTotal: Int, nodesShownShare: Double?, edges: [Edge],
                    edgesTotal: Int, edgesShownShare: Double?, notes: [String]) {
            self.source = source
            self.targets = targets
            self.depth = depth
            self.longestChain = longestChain
            self.longestChainSeconds = longestChainSeconds
            self.fanIn = fanIn
            self.fanOut = fanOut
            self.umbrellaCandidates = umbrellaCandidates
            self.cycles = cycles
            self.blockers = blockers
            self.macroPluginsPerModule = macroPluginsPerModule
            self.variants = variants
            self.criticalChain = criticalChain
            self.nodes = nodes
            self.nodesTotal = nodesTotal
            self.nodesShownShare = nodesShownShare
            self.edges = edges
            self.edgesTotal = edgesTotal
            self.edgesShownShare = edgesShownShare
            self.notes = notes
        }
    }

    /// `deep`: what `build --deep` injected and read (DESIGN §5.8). Null unless `--deep` was given (no note, the
    /// `regression` precedent).
    public struct Deep: Codable, Sendable, Equatable {
        public struct DroppedFlag: Codable, Sendable, Equatable {
            public var flag: String
            /// `unsupported by swift-frontend 6.2 (not in -help)`, `off by default (warnings as errors)`, ...
            public var reason: String

            public init(flag: String, reason: String) {
                self.flag = flag
                self.reason = reason
            }
        }

        public struct ExactFiles: Codable, Sendable, Equatable {
            /// Targets rebuilt with `SWIFT_ENABLE_BATCH_MODE=NO` in the deep DerivedData (top-K batches).
            public var rebuiltTargets: [String]
            /// Always says that the build shape changed (§6.4).
            public var note: String

            public init(rebuiltTargets: [String], note: String) {
                self.rebuiltTargets = rebuiltTargets
                self.note = note
            }
        }

        /// Rows each reader produced before the user-code filter and dedupe.
        public struct Sources: Codable, Sendable, Equatable {
            public var debugTime: Int
            public var warnLong: Int
            public var statsDir: Int
            public var ftimeTrace: Int

            public init(debugTime: Int, warnLong: Int, statsDir: Int, ftimeTrace: Int) {
                self.debugTime = debugTime
                self.warnLong = warnLong
                self.statsDir = statsDir
                self.ftimeTrace = ftimeTrace
            }
        }

        /// False when `--deep` was asked for but aborted before building (a target lost a pre-existing flag, MV-3;
        /// the probe failed); `notes` says why and the build ran without deep flags.
        public var enabled: Bool
        /// `swift` / `clang`.
        public var scope: [String]
        /// Flags as injected through the wrapper xcconfig (`-Xfrontend -debug-time-function-bodies`, ...).
        public var flagsInjected: [String]
        /// Flags the toolchain does not support (probe), with the reason; empty when every flag of the scope is supported.
        public var flagsDropped: [DroppedFlag]
        /// Supported flags `--deep` leaves out on purpose, with the reason (`-warn-long-*`: off by default, [OC] A20).
        @Added public var flagsNotInjected: [DroppedFlag] = []
        /// `<target>: <KEY>` whose effective value did not change with the wrapper: `shadowed (command line did not
        /// win, MV-3)`, not counted as injected.
        public var shadowed: [String]
        /// The deep DerivedData (`<cache>/deep/<sha16(container)>/`, redactable).
        public var derivedData: String
        @Null public var derivedDataBytes: Int64?
        /// `.xcblame/tmp/wrapper-<Config>.xcconfig` (redactable).
        @Null public var wrapper: String?
        /// Null without `--exact-files`.
        @Null public var exactFiles: ExactFiles?
        @Null public var sources: Sources?
        public var notes: [String]

        public init(enabled: Bool, scope: [String], flagsInjected: [String], flagsDropped: [DroppedFlag],
                    flagsNotInjected: [DroppedFlag] = [], shadowed: [String], derivedData: String,
                    derivedDataBytes: Int64?, wrapper: String?, exactFiles: ExactFiles?, sources: Sources?,
                    notes: [String]) {
            self.enabled = enabled
            self.scope = scope
            self.flagsInjected = flagsInjected
            self.flagsDropped = flagsDropped
            self.flagsNotInjected = flagsNotInjected
            self.shadowed = shadowed
            self.derivedData = derivedData
            self.derivedDataBytes = derivedDataBytes
            self.wrapper = wrapper
            self.exactFiles = exactFiles
            self.sources = sources
            self.notes = notes
        }
    }

    /// `build.cache` (DESIGN §6.7 `cached`): build-level compilation-cache counters.
    public struct BuildCache: Codable, Sendable, Equatable {
        @Null public var hits: Int?
        @Null public var misses: Int?
        /// Tasks whose own output is exactly `Cache hit` (replayed from the compilation cache, MV-12): exact, per task.
        /// Null when no task printed `Cache hit` or `Cache miss` (v0.5 integration).
        @Added public var replayedTasks: Int? = nil
        /// Compile tasks counted as replayed by the labelled heuristic of §6.7 (cache-hit remarks, or < 5 % of the
        /// previous duration with an unchanged signature); never a per-task fact. Null whenever `replayedTasks` is set.
        @Null public var replayedTasksHeuristic: Int?
        /// `buildOperationMetrics` / `casRemarks` / `history` (closed).
        public var source: String

        public init(hits: Int?, misses: Int?, replayedTasks: Int? = nil, replayedTasksHeuristic: Int?, source: String) {
            self.hits = hits
            self.misses = misses
            self.replayedTasks = replayedTasks
            self.replayedTasksHeuristic = replayedTasksHeuristic
            self.source = source
        }
    }

    public struct TruncationStep: Codable, Sendable, Equatable {
        /// `hotspots` / `files` / `taskIndex` / `moduleGraph` / `targets` / `findingsEvidence` / `diagnostics` /
        /// `lastResort` (§8.2.3).
        public var step: String
        public var kept: Int
        public var total: Int
        @Null public var shownShare: Double?
    }

    public struct Truncation: Codable, Sendable, Equatable {
        /// In the order applied; empty when nothing was truncated.
        public var steps: [TruncationStep]
    }

    public var schemaVersion: String
    public var tool: Tool
    public var generatedAt: Date
    public var input: Input
    public var xcode: Xcode
    /// Snapshot of the machine running xcblame, not of the machine that built the log; nil unless captured (`--env`).
    @Null public var environment: EnvSnapshot?
    public var build: Build
    public var metrics: Metrics
    @Null public var phases: [Row]?
    @Null public var kinds: [Row]?
    @Null public var targets: [TargetRow]?
    public var targetsTotal: Int
    @Null public var targetsShownShare: Double?
    @Null public var topTasks: [TopTask]?
    public var topTasksTotal: Int
    @Null public var topTasksShownShare: Double?
    public var diagnosticsSummary: DiagnosticsSummary
    public var validation: Validation
    /// Convenience: true iff `degradations` is non-empty (same value as `validation.degraded`).
    public var degraded: Bool
    public var degradations: [DegradationEntry]
    public var decodeWarnings: [DecodeWarningEntry]
    public var decodeWarningsTotal: Int
    public var notes: [String]

    /// Rows per capped table in the text/JSON report (`--top`).
    public var topN: Int

    // v0.2 members (docs/SCHEMA-v0.2.md).
    public var graph: Graph
    @Null public var criticalPath: CriticalPath?
    public var timing: TimingSection
    @Null public var files: [FileRow]?
    public var filesTotal: Int
    @Null public var filesShownShare: Double?
    @Null public var hotspots: [Hotspot]?
    public var hotspotsTotal: Int
    @Null public var hotspotsShownShare: Double?
    public var findings: [Finding]
    public var findingsTotal: Int
    public var ruleDocs: [String: RuleDoc]
    public var truncation: Truncation
    /// True once the Redactor ran on this document.
    public var redacted: Bool

    // v0.3 members (docs/SCHEMA-v0.3.md). `@Added`: a v0.2 saved report decodes with these null/empty.
    @Added public var project: ProjectSection? = nil
    @Added public var doctor: DoctorSection? = nil
    @Added public var fixPlan: [FixPlanStep] = []

    // v0.4 members (docs/SCHEMA-v0.4.md). `@Added`: a v0.3 saved report decodes with these nil / empty / 0.
    /// Null unless `--baseline` was given and evaluated; there is no note for an absent baseline (v0.3 precedent:
    /// `project` and `doctor` carry none either). A baseline given but not evaluable adds a note and stays null.
    @Added public var regression: Regression? = nil
    /// Deduped errors then warnings, `min(topN, 100)` rows (errors first, then by occurrences).
    @Added public var diagnostics: [DiagnosticEntry] = []
    /// Unique errors plus warnings (`diagnosticsSummary.errors + .warnings`), before the cap.
    @Added public var diagnosticsTotal: Int = 0
    /// Occurrences shown / occurrences of all errors and warnings; nil when there are none.
    @Added public var diagnosticsShownShare: Double? = nil

    // v0.5 members (docs/SCHEMA-v0.5.md). `@Added`: a v0.4 saved report decodes with these nil.
    /// Non-null for every non-clean build report (lane B); null for clean builds and doctor documents, with a note.
    @Added public var incremental: Incremental? = nil
    /// Fixed-cost classes, largest `seconds` first (lane C); null when not computed, with a note.
    @Added public var fixedCosts: [FixedCost]? = nil
    /// Target graph metrics, variants and the SVG graph (lane C); null when no graph is known, with a note.
    @Added public var moduleGraph: ModuleGraph? = nil
    /// `build --deep` only (lane A); null without a note otherwise.
    @Added public var deep: Deep? = nil
}
