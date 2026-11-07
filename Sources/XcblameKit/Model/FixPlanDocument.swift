import Foundation

/// `xcblame fix` plan (`schemaVersion: "xcblame.fixplan/1"`, docs/SCHEMA-v0.6.md "Fix plan document"). Stored at
/// `<xcblame-dir>/plans/<id>.json` (`FixPlanStore`). Lane A builds it (`FixPlanning`), lane B writes verify verdicts
/// into `steps[].verify`, lane C renders it. Frozen in phase 1: lanes add extensions in their own files only.
public struct FixPlanDocument: Codable, Sendable, Equatable {
    public static let schemaVersion = "xcblame.fixplan/1"

    /// The finding's `fixKind` (DESIGN §7.3, `FindingBuilder`), verbatim.
    public enum FixKind: String, Codable, Sendable, CaseIterable {
        case overlay, cli, defaults, scheme, project, manifest, recommend, measure
    }

    /// How a step's change reaches the build. `hook`: the overlay through the `#include?` hook in the project-level
    /// base xcconfig (IDE and xcodebuild, project targets only). `cli`: the overlay through the command-line wrapper
    /// `-xcconfig` (xcodebuild only, project and package targets). `defaults`: `defaults write com.apple.dt.Xcode`.
    /// `recommend`: nothing is written; the step is a printed change.
    public enum Mechanism: String, Codable, Sendable, CaseIterable {
        case hook, cli, defaults, recommend
    }

    /// Whether a level above the overlay sets the step's keys explicitly (DESIGN §7.5 "Shadowing").
    public enum Shadowing: String, Codable, Sendable, CaseIterable {
        /// No target/configuration pair of the scope is shadowed.
        case none
        /// Some pairs are shadowed: the overlay reaches only the others (`scope[].reached`).
        case partial
        /// Every pair is shadowed: the overlay cannot win; the step is `cli` (CI) or `recommend`.
        case full
    }

    /// A step's verify state; `reverted` and `indicative` carry a reason or note. Shared with `VerifyDocument`.
    public enum VerifyStatus: String, Codable, Sendable, CaseIterable {
        /// Never measured (or the verify run aborted before it).
        case unverified
        /// After-p50 lower than before-p50 beyond the noise band (or within it under `--keep-on-tie`, `tie` true).
        case kept
        /// Measured and rejected; `reason` says why.
        case reverted
        /// Fewer samples than the noise model needs (`--runs` < 4, or < 3 measured samples per arm): never kept.
        case indicative
    }

    /// Why a step was reverted (DESIGN §3.5, §7.8 step 5-6).
    public enum RevertReason: String, Codable, Sendable, CaseIterable {
        /// After-p50 higher than before-p50 beyond the noise band.
        case slower
        /// |Δ| inside the noise band (and no `--keep-on-tie`).
        case withinNoise
        /// A run of arm B exited non-zero.
        case brokeBuild
        /// The target set, or (clean kind) the task-kind multiset per target, differs between arms beyond the
        /// rule's declared effect.
        case taskSetChanged
        /// The oracle check before building showed no target's effective value changes (every key shadowed).
        case noEffect
    }

    /// A step's lifecycle in this checkout.
    public enum StepState: String, Codable, Sendable, CaseIterable {
        /// Printed, nothing written.
        case planned
        /// Written by `fix --apply` / `--apply-defaults`.
        case applied
        /// A `cli` step `fix --apply` accepted: nothing is written; `xcblame build --overlay <plan-id>` delivers it
        /// through the command-line wrapper (fix round 1, 2026-11-06).
        case appliedCLI = "applied-cli"
        /// Removed by `fix --revert`.
        case reverted
        /// `fix --apply` left it out; `stateReason` says why (not kept, mechanism differs, key owned by another plan).
        case skipped
    }

    /// What the plan was generated from.
    public struct Source: Codable, Sendable, Equatable {
        /// History entry id of the analysis whose findings (and measured bands) fed the plan; nil when there was none.
        @Null public var analysisId: String?
        /// A report JSON given with `fix --from <file>` instead of a history entry; nil otherwise.
        @Null public var analysisPath: String?
        /// That analysis's build kind (`clean`, `incremental`, ...).
        @Null public var analysisKind: String?
        /// Configurations the doctor pass evaluated.
        public var doctorConfigurations: [String]
        /// `xcodebuild` / `offline` / `mixed`: where the doctor pass took effective values from (§7.4).
        public var settingsSource: String
        /// `--rules` given to `fix`; empty for all.
        public var rulesFilter: [String]

        public init(analysisId: String?, analysisPath: String?, analysisKind: String?, doctorConfigurations: [String],
                    settingsSource: String, rulesFilter: [String]) {
            self.analysisId = analysisId
            self.analysisPath = analysisPath
            self.analysisKind = analysisKind
            self.doctorConfigurations = doctorConfigurations
            self.settingsSource = settingsSource
            self.rulesFilter = rulesFilter
        }
    }

    /// The project the plan applies to.
    public struct Project: Codable, Sendable, Equatable {
        /// Container path (redactable).
        public var container: String
        /// `xcodegen` / `tuist` / ... (`ProjectModel.generator`); nil for a hand-made project.
        @Null public var generator: String?
        public var configurations: [String]
        @Null public var scheme: String?

        public init(container: String, generator: String?, configurations: [String], scheme: String?) {
            self.container = container
            self.generator = generator
            self.configurations = configurations
            self.scheme = scheme
        }
    }

    /// One target × configuration × key a step changes, under one mechanism (from the oracle; DESIGN §7.5 "Scope",
    /// Appendix B item 10). A step lists rows for every mechanism it could be delivered with.
    public struct ScopeRow: Codable, Sendable, Equatable {
        public var target: String
        public var configuration: String
        public var key: String
        /// Effective value before the change; nil when unknown (offline, no oracle).
        @Null public var before: String?
        /// Effective value with the change delivered through `mechanism`; nil when the oracle did not run.
        @Null public var after: String?
        /// `Provenance.Level` raw value of the level that sets `before` (plus the file).
        @Null public var provenance: String?
        public var mechanism: Mechanism
        /// The change reaches this target. `hook`: false when shadowed (project settings, target xcconfig or target
        /// settings set the key) or for a package target. `cli`: always true (probes-v0.6 Q1/Q3/Q9); the oracle check
        /// confirms it and a false here means the confirmation failed (`note`).
        public var reached: Bool
        @Null public var note: String?

        public init(target: String, configuration: String, key: String, before: String?, after: String?,
                    provenance: String?, mechanism: Mechanism, reached: Bool, note: String? = nil) {
            self.target = target
            self.configuration = configuration
            self.key = key
            self.before = before
            self.after = after
            self.provenance = provenance
            self.mechanism = mechanism
            self.reached = reached
            self.note = note
        }
    }

    /// One overlay assignment (§7.5 "Content"); `line` is the exact text written into the overlay block.
    public struct OverlayLine: Codable, Sendable, Equatable {
        public var configuration: String
        public var key: String
        /// An `[sdk=…]` condition (probes-v0.6 Q6: honoured in a base xcconfig and in `-xcconfig`), e.g.
        /// `[sdk=iphonesimulator*]`; nil for an unconditional line. `[config=…]` is never written (one file per
        /// configuration).
        @Null public var condition: String?
        public var value: String
        /// `KEY[cond] = VALUE // xcblame <RULE> (plan <id>)`; list-typed keys start with `$(inherited)`.
        public var line: String

        public init(configuration: String, key: String, condition: String? = nil, value: String, line: String) {
            self.configuration = configuration
            self.key = key
            self.condition = condition
            self.value = value
            self.line = line
        }
    }

    /// One `defaults write` or `defaults delete` (§7.3 `defaults`). v0.6 writes only
    /// `IDEBuildOperationMaxNumberOfConcurrentCompileTasks` (ENV-002; probes-v0.6 Q8).
    public struct DefaultsChange: Codable, Sendable, Equatable {
        /// Always `com.apple.dt.Xcode` in v0.6.
        public var domain: String
        public var key: String
        /// Nil: `defaults delete` (ENV-002's "delete the key, default = cores").
        @Null public var value: String?
        /// `bool` / `int` / `string`: the `defaults write -<type>` flag; nil with a nil `value`.
        @Null public var type: String?

        public init(domain: String = "com.apple.dt.Xcode", key: String, value: String?, type: String?) {
            self.domain = domain
            self.key = key
            self.value = value
            self.type = type
        }
    }

    /// A step's verify state, written by `verify` (lane B) from its `VerifyDocument`.
    public struct VerifyState: Codable, Sendable, Equatable {
        public var status: VerifyStatus
        /// Set when `status` is `reverted`.
        @Null public var reason: RevertReason?
        /// The mechanism the verdict was measured through (`fix --apply` refuses another one unless scope is
        /// identical, Appendix B item 10).
        @Null public var mechanism: Mechanism?
        /// `clean` / `incremental` / `zero-change`.
        @Null public var kind: String?
        /// `VerifyDocument.id` of the run that decided it.
        @Null public var verifyId: String?
        @Null public var verifiedAt: Date?
        /// After-p50 − before-p50 in seconds (negative = faster).
        @Null public var deltaSeconds: Double?
        /// `deltaSeconds` / before-p50.
        @Null public var deltaPct: Double?
        /// Kept within the noise band because of `--keep-on-tie`.
        public var tie: Bool
        /// `VerifyBasis.value` when the verdict was recorded: 16 hex over rule, overlay lines, container, planned kind
        /// and mechanism, scope rows and the project files' digest. A later plan reuses the verdict only when its own
        /// basis is equal ("project changed since verify" otherwise); nil (an older plan) is never reused.
        @Added public var basis: String? = nil

        public init(status: VerifyStatus = .unverified, reason: RevertReason? = nil, mechanism: Mechanism? = nil,
                    kind: String? = nil, verifyId: String? = nil, verifiedAt: Date? = nil, deltaSeconds: Double? = nil,
                    deltaPct: Double? = nil, tie: Bool = false, basis: String? = nil) {
            self.status = status
            self.reason = reason
            self.mechanism = mechanism
            self.kind = kind
            self.verifyId = verifyId
            self.verifiedAt = verifiedAt
            self.deltaSeconds = deltaSeconds
            self.deltaPct = deltaPct
            self.tie = tie
            self.basis = basis
        }

        public static let unverified = VerifyState()
    }

    /// One step of the plan, in plan order (`RulePlan.ordered`, prerequisites first).
    public struct Step: Codable, Sendable, Equatable {
        /// 1-based, consecutive.
        public var order: Int
        public var ruleId: String
        public var title: String
        public var fixKind: FixKind
        public var mechanism: Mechanism
        /// The finding's `mechanism` text (`hook (…); shadowed for 2 targets by project settings: --edit-project`).
        @Null public var mechanismDetail: String?
        /// Measured band (`XS`…`L`, `?`) from the analysis; `estimatedBand` when unmeasured.
        @Null public var impactBand: String?
        @Null public var impactSeconds: Double?
        @Null public var estimatedBand: String?
        public var confidence: String
        /// `+V`: applied only after verify keeps it (RULES.md §10); `--force-unverified` never overrides this.
        public var verifyOnly: Bool
        /// The kind `verify` measures this rule with by default (`clean` / `incremental` / `zero-change`).
        public var verifyKind: String
        public var scope: [ScopeRow]
        public var overlay: [OverlayLine]
        public var defaults: [DefaultsChange]
        public var shadowing: Shadowing
        /// `Provenance.Level` labels of the shadowing levels; empty when `shadowing` is `none`.
        public var shadowedBy: [String]
        public var verify: VerifyState
        public var state: StepState
        /// Why the step is `skipped` (one plain sentence); nil otherwise.
        @Null public var stateReason: String?
        /// Commands this step prints, in order.
        public var commands: [String]
        /// The finding's `inXcode` lines (where to make the change by hand).
        public var inXcode: [String]
        @Null public var risk: String?

        public init(order: Int, ruleId: String, title: String, fixKind: FixKind, mechanism: Mechanism,
                    mechanismDetail: String? = nil, impactBand: String? = nil, impactSeconds: Double? = nil,
                    estimatedBand: String? = nil, confidence: String, verifyOnly: Bool, verifyKind: String = "clean",
                    scope: [ScopeRow] = [], overlay: [OverlayLine] = [], defaults: [DefaultsChange] = [],
                    shadowing: Shadowing = .none, shadowedBy: [String] = [], verify: VerifyState = .unverified,
                    state: StepState = .planned, stateReason: String? = nil, commands: [String] = [],
                    inXcode: [String] = [], risk: String? = nil) {
            self.order = order
            self.ruleId = ruleId
            self.title = title
            self.fixKind = fixKind
            self.mechanism = mechanism
            self.mechanismDetail = mechanismDetail
            self.impactBand = impactBand
            self.impactSeconds = impactSeconds
            self.estimatedBand = estimatedBand
            self.confidence = confidence
            self.verifyOnly = verifyOnly
            self.verifyKind = verifyKind
            self.scope = scope
            self.overlay = overlay
            self.defaults = defaults
            self.shadowing = shadowing
            self.shadowedBy = shadowedBy
            self.verify = verify
            self.state = state
            self.stateReason = stateReason
            self.commands = commands
            self.inXcode = inXcode
            self.risk = risk
        }
    }

    /// Something that must hold before (part of) the plan runs.
    public struct Guard: Codable, Sendable, Equatable {
        /// Closed: `commitFirst` (the plan writes a team-owned file), `hookInstalled` (a `hook` step needs the hook),
        /// `prerequisite` (`RulePlan.prerequisites`: a guard rule before the rule that assumes it), `verifyFirst`
        /// (a `+V` step), `cleanTree` (verify needs the plan's files committed).
        public var id: String
        /// One plain sentence.
        public var text: String
        /// Rules the guard is about; empty when plan-wide.
        public var ruleIds: [String]
        /// Nil when not checked (offline, or no git).
        @Null public var satisfied: Bool?

        public init(id: String, text: String, ruleIds: [String] = [], satisfied: Bool?) {
            self.id = id
            self.text = text
            self.ruleIds = ruleIds
            self.satisfied = satisfied
        }
    }

    /// The hook of one configuration when the plan was made.
    public struct HookState: Codable, Sendable, Equatable {
        public var configuration: String
        /// Closed: `installed`, `notInstalled` (a project-level base xcconfig exists: `--install-hook` can append),
        /// `unavailable` (no project-level base xcconfig, or one shared by several configurations, or a CocoaPods
        /// file: `reason`), `generated` (XcodeGen/Tuist: the hook is printed as the generator-source change).
        public var status: String
        /// Repository-relative path of the project-level base xcconfig; nil when there is none.
        @Null public var baseXCConfig: String?
        @Null public var reason: String?

        public init(configuration: String, status: String, baseXCConfig: String?, reason: String?) {
            self.configuration = configuration
            self.status = status
            self.baseXCConfig = baseXCConfig
            self.reason = reason
        }
    }

    /// One write `fix` made with this plan, oldest first.
    public struct Event: Codable, Sendable, Equatable {
        public var at: Date
        /// Closed: `apply`, `applyDefaults`, `revert`, `installHook`, `uninstallHook`.
        public var action: String
        public var ruleIds: [String]
        /// Repository-relative files written or restored.
        public var files: [String]
        /// `defaults` keys written or restored.
        public var defaultsKeys: [String]

        public init(at: Date, action: String, ruleIds: [String], files: [String], defaultsKeys: [String]) {
            self.at = at
            self.action = action
            self.ruleIds = ruleIds
            self.files = files
            self.defaultsKeys = defaultsKeys
        }
    }

    public var schemaVersion: String
    public var tool: ReportDocument.Tool
    public var generatedAt: Date
    /// 8 lowercase hex: the first 8 of SHA-256 over the plan's inputs and steps (see docs/SCHEMA-v0.6.md "Plan id");
    /// the same inputs give the same id, so a stored plan (with its verify states) is reused.
    public var id: String
    public var generatedFrom: Source
    public var project: Project
    public var steps: [Step]
    public var guards: [Guard]
    public var hook: [HookState]
    /// The commands to run, in order (`xcblame verify …`, then `xcblame fix --apply`).
    public var commands: [String]
    public var events: [Event]
    public var notes: [String]
    /// True once the Redactor ran on this document.
    public var redacted: Bool

    public init(schemaVersion: String = FixPlanDocument.schemaVersion, tool: ReportDocument.Tool, generatedAt: Date,
                id: String, generatedFrom: Source, project: Project, steps: [Step], guards: [Guard] = [],
                hook: [HookState] = [], commands: [String] = [], events: [Event] = [], notes: [String] = [],
                redacted: Bool = false) {
        self.schemaVersion = schemaVersion
        self.tool = tool
        self.generatedAt = generatedAt
        self.id = id
        self.generatedFrom = generatedFrom
        self.project = project
        self.steps = steps
        self.guards = guards
        self.hook = hook
        self.commands = commands
        self.events = events
        self.notes = notes
        self.redacted = redacted
    }
}

/// Builds a fix plan (lane A: `Fix/FixPlanner.swift`).
public protocol FixPlanning: Sendable {
    func plan(_ request: FixPlanRequest) throws -> FixPlanDocument
}

/// Everything a planner reads. `fix` and `verify` (when no stored plan fits) fill it the same way.
public struct FixPlanRequest: Sendable {
    /// The doctor pass over the project (findings, `project` section).
    public var doctor: ReportDocument
    /// The analysis the plan is generated from (measured bands, dynamic findings); nil when history has none.
    public var analysis: ReportDocument?
    /// Its history entry id (nil for `--from <file>` or no analysis).
    public var analysisId: String?
    /// Project, effective settings and provenance of the doctor pass: per-target scope comes from here.
    public var context: RuleContext
    /// `--rules`; nil for every finding.
    public var rules: [String]?
    public var xcblameDir: URL
    public var generatedAt: Date

    public init(doctor: ReportDocument, analysis: ReportDocument?, analysisId: String?, context: RuleContext,
                rules: [String]?, xcblameDir: URL, generatedAt: Date) {
        self.doctor = doctor
        self.analysis = analysis
        self.analysisId = analysisId
        self.context = context
        self.rules = rules
        self.xcblameDir = xcblameDir
        self.generatedAt = generatedAt
    }
}
