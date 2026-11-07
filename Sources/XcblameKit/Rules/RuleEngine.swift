import Foundation

public typealias RuleOutcome = ReportDocument.RuleOutcome

/// Everything a rule predicate may read. `doctor` fills the project side; `analyze` adds the build side.
public struct RuleContext: Sendable {
    /// Nil when `analyze` found no project for the log (dynamic rules still run).
    public var project: ProjectModel?
    /// Configuration name to its effective settings; empty when the oracle could not run.
    public var settings: [String: EffectiveSettings]
    /// `SettingsOracle.provenance` bound to `project` (target, key, configuration).
    public var provenance: @Sendable (_ target: String, _ key: String, _ configuration: String) -> Provenance
    public var env: EnvSnapshot?
    /// The analyzed build (`analyze` only).
    public var analysis: Analysis?
    /// The v0.2 report of that build (`analyze` only): critical path, targets, files, kind.
    public var document: ReportDocument?
    /// Xcode version the rules compare against (`26.0.1`): the log's inferred version under `analyze`, the selected
    /// Xcode under `doctor`; nil when unknown.
    public var xcode: String?
    public var isCI: Bool
    /// `--offline`: every finding's confidence drops one step (DESIGN §7.4).
    public var offline: Bool
    /// Every task of the analyzed build that entered timing, with its clamped seconds (`analyze` only): measured
    /// costs read kinds, rule names and command lines here, never the capped `topTasks` titles.
    public var tasks: [MeasuredTask]

    public struct MeasuredTask: Sendable {
        public var task: BuildTask
        public var seconds: Double
    }

    /// `tasks` for a build model: the tasks of `Timing.timeline` (reused, invalid and untimed ones left out).
    public static func measuredTasks(_ model: BuildModel) -> [MeasuredTask] {
        Timing.timeline(model).counted.map { MeasuredTask(task: $0.task, seconds: $0.interval.duration) }
    }

    public init(project: ProjectModel?, settings: [String: EffectiveSettings] = [:],
                provenance: @escaping @Sendable (String, String, String) -> Provenance = { _, _, _ in
                    Provenance(level: .unknown)
                },
                env: EnvSnapshot? = nil, analysis: Analysis? = nil, document: ReportDocument? = nil,
                xcode: String? = nil, isCI: Bool = false, offline: Bool = false, tasks: [MeasuredTask] = []) {
        self.project = project
        self.settings = settings
        self.provenance = provenance
        self.env = env
        self.analysis = analysis
        self.document = document
        self.xcode = xcode
        self.isCI = isCI
        self.offline = offline
        self.tasks = tasks
    }

    /// `provenance` bound to `SettingsOracle.provenance` over `project`, matching conditional keys against each
    /// target's effective values in `settings` when given.
    public static func oracleProvenance(_ project: ProjectModel?, settings: [String: EffectiveSettings] = [:])
        -> @Sendable (String, String, String) -> Provenance {
        { target, key, configuration in
            guard let project else { return Provenance(level: .unknown) }
            return SettingsOracle.provenance(project: project, target: target, key: key, configuration: configuration,
                                             commandLineOverrides: [:],
                                             effective: settings[configuration]?.targets[target])
        }
    }
}

extension RuleContext {
    /// Lane A's Podfile facts (pods, `use_frameworks!`, `post_install` body and its `build_settings` assignments) for
    /// the project's CocoaPods manager; nil without a Podfile or when it cannot be read.
    var podfileFacts: (url: URL, facts: PodfileFacts)? {
        for manager in project?.dependencyManagers ?? [] {
            if case let .cocoapods(podfile, _, _) = manager {
                return ManifestReaders.podfile(podfile).map { (podfile, $0) }
            }
        }
        return nil
    }
}

/// What one engine run produced. Every evaluated rule id lands in exactly one of `findings` (as `ruleId`),
/// `passed`, `notApplicable` or `suppressed`.
public struct RuleResult: Sendable, Equatable {
    /// Fix-plan order, deduplicated by `signalKey`.
    public var findings: [ReportDocument.Finding]
    public var passed: [RuleOutcome]
    public var notApplicable: [RuleOutcome]
    /// Lost a signal-key dedupe or a conflict (RULES.md §10); `detail` names the winner.
    public var suppressed: [RuleOutcome]
    /// Keyed by rule id, exactly the rules in `findings`.
    public var ruleDocs: [String: ReportDocument.RuleDoc]
    public var notes: [String]

    public init(findings: [ReportDocument.Finding] = [], passed: [RuleOutcome] = [], notApplicable: [RuleOutcome] = [],
                suppressed: [RuleOutcome] = [], ruleDocs: [String: ReportDocument.RuleDoc] = [:], notes: [String] = []) {
        self.findings = findings
        self.passed = passed
        self.notApplicable = notApplicable
        self.suppressed = suppressed
        self.ruleDocs = ruleDocs
        self.notes = notes
    }

    /// Rules evaluated: distinct ids across the four lists.
    public var rulesEvaluated: Int {
        Set(findings.map(\.ruleId) + (passed + notApplicable + suppressed).map(\.ruleId)).count
    }
}

/// Evaluates the catalog against a context (Lane C).
public enum RuleEngine {
    /// `rules` (ids, aliases resolved) and `categories` narrow the catalog; nil means all. Dynamic-only rules are
    /// `notApplicable` without `analysis`; static-only rules are `notApplicable` without `project`.
    public static func run(_ context: RuleContext, rules: [String]? = nil,
                           categories: [RuleSpec.Category]? = nil) -> RuleResult {
        run(context, catalog: RuleCatalog.rules, rules: rules, categories: categories)
    }

    /// `run` over any rule list (tests pass synthetic rules to exercise dedupe).
    static func run(_ context: RuleContext, catalog: [Rule], rules ids: [String]?,
                    categories: [RuleSpec.Category]?) -> RuleResult {
        let scan = RuleScan(context)
        var notes: [String] = []
        var selected = catalog
        if let ids {
            let known = Set(catalog.map(\.spec.id))
            let wanted = ids.map(RuleCatalog.resolve)
            for (given, id) in zip(ids, wanted) where !known.contains(id) {
                notes.append("rules: unknown rule id \(given) ignored (xcblame rules list shows the ids)")
            }
            selected = selected.filter { wanted.contains($0.spec.id) }
        }
        if let categories { selected = selected.filter { categories.contains($0.spec.category) } }

        var candidates: [Dedupe.Candidate] = []
        var passed: [RuleOutcome] = []
        var notApplicable: [RuleOutcome] = []
        var suppressed: [RuleOutcome] = []
        for rule in selected {
            let spec = rule.spec
            if let reason = gate(spec, scan) {
                notApplicable.append(RuleOutcome(ruleId: spec.id, title: spec.name, detail: reason))
                continue
            }
            switch rule.evaluate(scan) {
            case let .hits(hits) where !hits.isEmpty:
                candidates += hits.map { Dedupe.Candidate(finding: FindingBuilder.make($0, spec: spec, scan: scan), spec: spec) }
            case .hits:
                passed.append(RuleOutcome(ruleId: spec.id, title: spec.name, detail: "no signal"))
            case let .passed(detail):
                passed.append(RuleOutcome(ruleId: spec.id, title: spec.name, detail: detail))
            case let .notApplicable(reason):
                notApplicable.append(RuleOutcome(ruleId: spec.id, title: spec.name, detail: reason))
            case let .suppressed(reason):
                suppressed.append(RuleOutcome(ruleId: spec.id, title: spec.name, detail: reason))
            }
        }
        let deduped = Dedupe.apply(candidates)
        suppressed += deduped.suppressed
        let ordered = Dedupe.ordered(deduped.findings)
        var ruleDocs: [String: ReportDocument.RuleDoc] = [:]
        for candidate in ordered { ruleDocs[candidate.spec.id] = candidate.spec.ruleDoc }
        if scan.offlineSource, !ordered.isEmpty {
            notes.append("rules: settings came from the offline resolver (or --offline): every finding's confidence is "
                + "one step lower")
        }
        if scan.unknownProvenance > 0 {
            notes.append("rules: no project model for \(scan.unknownProvenance) provenance lookups; shadowing not checked")
        }
        return RuleResult(findings: ordered.map(\.finding), passed: passed, notApplicable: notApplicable,
                          suppressed: suppressed, ruleDocs: ruleDocs, notes: notes)
    }

    /// Why a rule cannot be evaluated with this context, or nil: missing project, build or machine snapshot for its
    /// detection source, or an Xcode outside its range.
    static func gate(_ spec: RuleSpec, _ scan: RuleScan) -> String? {
        let context = scan.context
        if spec.detection == .info { return "documentation-only rule" }
        if spec.category == .env {
            if context.env == nil { return "no machine snapshot (environment not captured)" }
        } else {
            switch spec.detection {
            case .static where context.project == nil: return "static rule: no project was read"
            case .dynamic where context.analysis == nil: return "dynamic rule: needs a build (xcblame analyze)"
            case .both where context.project == nil && context.analysis == nil: return "no project and no build to check"
            default: break
            }
        }
        return xcodeGate(spec.xcode, scan)
    }

    /// RULES.md `Xcode` column: `26+`, `16.4+`, `26.x`, `≤16.x`, `A-B`; `all`, notes such as `11.4-14 era`,
    /// `26+ for Xcode cache` or `≤13 matters; 14+ cleanup`, and Swift versions (`5.5+`) never gate.
    static func xcodeGate(_ range: String, _ scan: RuleScan) -> String? {
        guard !range.contains(";"), !range.contains(" era"), !range.contains(" for "),
              let token = range.split(separator: " ").first.map(String.init) else { return nil }
        var lower: [Int]?
        var upper: [Int]?
        if token.hasSuffix("+") {
            lower = RuleScan.version(String(token.dropLast()))
        } else if token.hasPrefix("≤") {
            upper = RuleScan.version(String(token.dropFirst()).replacingOccurrences(of: ".x", with: ".999"))
        } else if token.hasSuffix(".x") || Int(token) != nil {
            let major = Int(token.prefix { $0.isNumber }) ?? 0
            lower = [major]
            upper = [major, 999]
        } else if let dash = token.firstIndex(of: "-") {
            lower = RuleScan.version(String(token[..<dash]))
            upper = RuleScan.version(String(token[token.index(after: dash)...]))
            upper = upper.map { $0.count == 1 ? $0 + [999] : $0 }
        } else {
            return nil
        }
        if let floor = lower?.first, floor < 10 { return nil }
        guard let version = scan.xcodeVersion else {
            return (lower?.first ?? 0) > 16 || upper != nil ? "Xcode version unknown; rule needs Xcode \(range)" : nil
        }
        let selected = scan.context.xcode ?? ""
        if let lower, RuleScan.compare(version, lower) < 0 { return "Xcode \(range) only (selected Xcode \(selected))" }
        if let upper, RuleScan.compare(version, upper) > 0 { return "Xcode \(range) only (selected Xcode \(selected))" }
        return nil
    }
}
