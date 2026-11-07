import CryptoKit
import Foundation

// v0.6 lane A (docs/SCHEMA-v0.6.md "Fix plan document"): the doctor findings (plus the analysis's measured bands and
// dynamic findings) as plan steps in `RulePlan` order, each with its fix kind, mechanism, per-target scope from the
// oracle, overlay lines, guards and commands. Pure apart from the injected `cliOracle` and `isDirty` calls.
public struct FixPlanner: FixPlanning {
    /// Effective settings of `configuration` with `lines` delivered through a command-line `-xcconfig`, to confirm the
    /// `cli` scope rows; nil when the oracle cannot run (offline, a workspace without a scheme, xcodebuild failed).
    public typealias CLIOracle = @Sendable (_ configuration: String, _ lines: [String]) -> EffectiveSettings?

    /// `fix --from <report.json>`: the file the analysis came from (hashed into the plan id like a history id).
    public var analysisPath: String?
    public var cliOracle: CLIOracle?
    /// Guards' `satisfied`: the plan's files have uncommitted changes; nil checks nothing.
    public var isDirty: HookInstaller.DirtyCheck?

    public init(analysisPath: String? = nil, cliOracle: CLIOracle? = nil, isDirty: HookInstaller.DirtyCheck? = nil) {
        self.analysisPath = analysisPath
        self.cliOracle = cliOracle
        self.isDirty = isDirty
    }

    /// The defaults key a `defaults` rule writes in v0.6; every other `defaults` finding is `recommend` (ENV-001 is
    /// display-only, DEP-008's prebuilts are an Xcode 16.4 preference; probes-v0.6 Q8).
    static let defaultsKeys = ["ENV-002": "IDEBuildOperationMaxNumberOfConcurrentCompileTasks"]

    /// Keys whose value is a list: an overlay line for them starts with `$(inherited)` (probes-v0.6 Q2/Q7).
    static let listKeys: Set<String> = ["OTHER_SWIFT_FLAGS", "OTHER_LDFLAGS", "OTHER_CFLAGS", "OTHER_CPLUSPLUSFLAGS",
                                        "GCC_PREPROCESSOR_DEFINITIONS", "SWIFT_ACTIVE_COMPILATION_CONDITIONS"]

    struct Assignment: Equatable {
        var configuration: String
        var key: String
        var condition: String?
        var value: String
    }

    public func plan(_ request: FixPlanRequest) throws -> FixPlanDocument {
        guard let model = request.context.project else {
            throw XcblameError.projectNotFound("the doctor pass read no project, so there is nothing to plan")
        }
        let context = request.context
        let configurations = model.configurationNames.filter { context.settings[$0] != nil }
        let evaluated = configurations.isEmpty ? (request.doctor.doctorConfigurations ?? model.configurationNames)
            : configurations
        let wanted = request.rules.map { Set($0.map(RuleCatalog.resolve)) }
        var notes: [String] = []

        // Findings: the doctor's, with measured bands from the analysis, plus the analysis's dynamic findings.
        var findings = request.doctor.findings
        for finding in request.analysis?.findings ?? [] {
            if let index = findings.firstIndex(where: { $0.signalKey == finding.signalKey }) {
                if finding.impactBand.map({ $0 != "?" }) == true {
                    findings[index].impactBand = finding.impactBand
                    findings[index].impactSeconds = finding.impactSeconds
                    findings[index].impactBasis = finding.impactBasis
                    findings[index].estimatedBand = nil
                }
            } else {
                findings.append(finding)
            }
        }
        if let wanted { findings = findings.filter { wanted.contains(RuleCatalog.resolve($0.ruleId)) } }
        let measureOnly = findings.filter { $0.fixKind == nil || $0.fixKind == "measure" }
        if !measureOnly.isEmpty {
            notes.append("\(measureOnly.count) finding(s) only need measuring (\(measureOnly.map(\.ruleId).joined(separator: ", "))): "
                + "no step")
        }
        let ordered = RulePlan.ordered(findings.filter { $0.fixKind != nil && $0.fixKind != "measure" })
        let hook = HookInstaller.states(project: model, configurations: evaluated, xcblameDir: request.xcblameDir)

        // Overlay assignments first: the plan id hashes them (the written lines carry the id, so they cannot).
        let drafts = ordered.map { finding in (finding, assignments(finding, context: context, configurations: evaluated)) }
        let id = Self.planId(source: request.analysisId ?? analysisPath, container: model.container.url.path,
                             steps: drafts.map { finding, assignments in
                                 (finding.ruleId, assignments, Self.defaultsKeys[finding.ruleId].map { "\($0)=" } ?? "")
                             })
        let oracle = cliRun(drafts, id: id)

        var steps: [FixPlanDocument.Step] = []
        for (index, (finding, overlay)) in drafts.enumerated() {
            steps.append(step(finding, order: index + 1, overlay: overlay, id: id, model: model, context: context,
                              hook: hook, oracle: oracle))
        }
        if request.analysis == nil {
            notes.append("no analysis in history: static findings only, bands are catalog estimates "
                + "(xcblame build or xcblame analyze measures them)")
        }
        if context.offline || context.settings.values.contains(where: { $0.source == .offlineResolver }) {
            notes.append("settings came from the offline resolver: scope rows are what the project files say")
        }
        if oracle.isEmpty, steps.contains(where: { $0.scope.contains { $0.mechanism == .cli } }) {
            notes.append("the -xcconfig oracle check did not run (offline or no scheme): cli rows have no after value")
        }

        let sources = Set(context.settings.values.map(\.source))
        let settingsSource = sources.count > 1 ? "mixed" : sources.first == .xcodebuild ? "xcodebuild" : "offline"
        var plan = FixPlanDocument(
            tool: ReportDocument.Tool(name: "xcblame", version: XcblameVersion.current, kindTable: KindTable.v1.version),
            generatedAt: request.generatedAt, id: id,
            generatedFrom: .init(analysisId: request.analysisId, analysisPath: analysisPath,
                                 analysisKind: request.analysis?.build.kind, doctorConfigurations: evaluated,
                                 settingsSource: settingsSource, rulesFilter: request.rules ?? []),
            project: .init(container: model.container.url.path, generator: model.generator?.name,
                           configurations: evaluated, scheme: request.analysis?.build.scheme),
            steps: steps, hook: hook, notes: notes)
        Self.carryOver(into: &plan, xcblameDir: request.xcblameDir,
                       projectDigest: VerifyBasis.projectDigest(model, xcblameDir: request.xcblameDir))
        plan.guards = guards(plan, model: model, findings: findings, xcblameDir: request.xcblameDir)
        plan.commands = Self.commands(plan)
        return plan
    }

    // MARK: - Steps

    /// The overlay assignments of an `overlay` finding: each line once per configuration it covers.
    func assignments(_ finding: ReportDocument.Finding, context: RuleContext, configurations: [String]) -> [Assignment] {
        guard finding.fixKind == "overlay" else { return [] }
        let covered = finding.scopeConfigurations.isEmpty ? configurations : finding.scopeConfigurations
        var out: [Assignment] = []
        for configuration in covered {
            for line in finding.overlayLines {
                let code = XCConfigChain.stripComment(line)
                guard let eq = code.firstIndex(of: "=") else { continue }
                var key = code[..<eq].trimmingCharacters(in: .whitespaces)
                var value = code[code.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                var condition: String?
                if let bracket = key.firstIndex(of: "[") {
                    condition = String(key[bracket...])
                    key = String(key[..<bracket])
                }
                let current = finding.scopeTargets.compactMap { context.settings[configuration]?.targets[$0]?[key] }
                if Self.isList(key, current: current), !value.hasPrefix("$(inherited)") {
                    value = "$(inherited) " + value
                }
                out.append(Assignment(configuration: configuration, key: key, condition: condition, value: value))
            }
        }
        return out
    }

    static func isList(_ key: String, current: [String]) -> Bool {
        listKeys.contains(key) || key.hasSuffix("_SEARCH_PATHS")
            || current.contains { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).count > 1 }
    }

    func step(_ finding: ReportDocument.Finding, order: Int, overlay: [Assignment], id: String, model: ProjectModel,
              context: RuleContext, hook: [FixPlanDocument.HookState],
              oracle: [String: EffectiveSettings]) -> FixPlanDocument.Step {
        let spec = RuleCatalog.spec(finding.ruleId)
        let fixKind = FixPlanDocument.FixKind(rawValue: finding.fixKind ?? "") ?? .recommend
        let verifyKind = Self.verifyKind(finding.fixCommands)
        var step = FixPlanDocument.Step(
            order: order, ruleId: finding.ruleId, title: finding.title, fixKind: fixKind, mechanism: .recommend,
            mechanismDetail: finding.mechanism, impactBand: finding.impactBand, impactSeconds: finding.impactSeconds,
            estimatedBand: finding.estimatedBand, confidence: finding.confidence, verifyOnly: spec?.verifyOnly ?? false,
            verifyKind: verifyKind, inXcode: finding.inXcode, risk: finding.risk)
        step.overlay = overlay.map {
            FixPlanDocument.OverlayLine(configuration: $0.configuration, key: $0.key, condition: $0.condition, value: $0.value,
                                        line: OverlayFile.line(key: $0.key, condition: $0.condition, value: $0.value,
                                                               ruleId: finding.ruleId, planId: id))
        }
        let rule = finding.ruleId
        switch fixKind {
        case .overlay:
            let projectTargets = Set(model.allTargets.map(\.name))
            var shadowedBy: [String] = []
            var hookRows: [FixPlanDocument.ScopeRow] = []
            var cliRows: [FixPlanDocument.ScopeRow] = []
            for assignment in overlay {
                let configuration = assignment.configuration
                let key = assignment.key
                for target in finding.scopeTargets {
                    let before = context.settings[configuration]?.targets[target]?[key]
                    let written = context.provenance(target, key, configuration)
                    let provenance = written.level == .unknown ? nil
                        : written.level.rawValue + (written.file.map { " (\($0))" } ?? "")
                    let expected = Self.expected(assignment.value, before: before)
                    if projectTargets.contains(target) {
                        let shadow = SettingsOracle.isShadowed(project: model, target: target, key: key,
                                                               configuration: configuration, byLevelAbove: .projectXCConfig)
                        if let shadow, !shadowedBy.contains(shadow.level.rawValue) { shadowedBy.append(shadow.level.rawValue) }
                        hookRows.append(.init(target: target, configuration: configuration, key: key, before: before,
                                              after: shadow == nil ? (assignment.condition == nil ? expected : nil) : before,
                                              provenance: provenance, mechanism: .hook, reached: shadow == nil,
                                              note: shadow.map { "shadowed by \($0.level.rawValue)" + ($0.file.map { " (\($0))" } ?? "") }))
                    }
                    var row = FixPlanDocument.ScopeRow(target: target, configuration: configuration, key: key, before: before,
                                                       after: nil, provenance: provenance, mechanism: .cli, reached: true)
                    if let settings = oracle[configuration] {
                        if let after = settings.targets[target]?[key] {
                            row.after = after
                            if assignment.condition == nil, let expected, !Self.matches(effective: after, written: assignment.value) {
                                row.reached = false
                                row.note = "the -xcconfig oracle check shows \(after), not \(expected): an unexpected "
                                    + "precedence (please report it)"
                            }
                        } else {
                            row.note = projectTargets.contains(target) ? "not listed by xcodebuild -showBuildSettings"
                                : "package target: xcodebuild -showBuildSettings does not list it; -xcconfig reaches it (probes Q9)"
                        }
                    }
                    cliRows.append(row)
                }
            }
            step.scope = hookRows + cliRows
            let unreached = hookRows.filter { !$0.reached }.count
            step.shadowing = unreached == 0 ? .none : unreached == hookRows.count ? .full : .partial
            step.shadowedBy = step.shadowing == .none ? [] : shadowedBy
            let configurations = Set(overlay.map(\.configuration))
            let hookable = hook.filter { configurations.contains($0.configuration) }
                .allSatisfy { $0.status == "installed" || $0.status == "notInstalled" }
            step.mechanism = context.isCI || !hookable || hookRows.isEmpty || step.shadowing == .full ? .cli : .hook
            // An incremental verify needs a file to touch: the largest Swift file of the step's targets (review D).
            let touch = verifyKind == "incremental" ? Self.touchSuggestion(model, targets: finding.scopeTargets) : nil
            step.commands = ["xcblame verify --rules \(rule) --kind \(verifyKind) --mechanism \(step.mechanism.rawValue)"
                + (touch.map { " --touch " + Self.shellWord($0) } ?? "")]
            if step.mechanism == .hook { step.commands.append("xcblame fix --rules \(rule) --apply") }
        case .cli:
            step.mechanism = .cli
            step.commands = finding.fixCommands
        case .defaults:
            if let key = Self.defaultsKeys[rule] {
                step.mechanism = .defaults
                step.defaults = [FixPlanDocument.DefaultsChange(key: key, value: nil, type: nil)]
                step.commands = ["xcblame fix --rules \(rule) --apply-defaults"]
            } else {
                step.commands = []
            }
        default:
            step.commands = finding.fixCommands.filter { !$0.contains("--apply-defaults") }
        }
        return step
    }

    /// The step's `xcblame verify …` command (with the `--touch` suggestion of an incremental step).
    public static func verifyCommand(_ step: FixPlanDocument.Step) -> String {
        step.commands.first { $0.hasPrefix("xcblame verify ") }
            ?? "xcblame verify --rules \(step.ruleId) --kind \(step.verifyKind) --mechanism \(step.mechanism.rawValue)"
    }

    /// `word`, single-quoted when the shell would split or expand it.
    static func shellWord(_ word: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./+=:,@")
        guard !word.isEmpty, word.unicodeScalars.allSatisfy(plain.contains) else {
            return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        return word
    }

    /// The largest `.swift` file (by size) in the folder named like one of `targets` under the project root, else
    /// anywhere under the root (xcblame state, build products and dependency folders skipped), as a path relative to
    /// the current directory when inside it; nil when there is none. The `--touch` an incremental verify suggests.
    static func touchSuggestion(_ model: ProjectModel, targets: [String]) -> String? {
        let fm = FileManager.default
        let skipped: Set<String> = [".git", ".build", ".xcblame", "build", "DerivedData", "Pods", "Carthage",
                                    "node_modules", "SourcePackages"]
        func largest(in folder: URL) -> URL? {
            guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { return nil }
            var best: (url: URL, size: Int)?
            var visited = 0
            for case let url as URL in walker {
                visited += 1
                if visited > 20_000 { break }
                if skipped.contains(url.lastPathComponent) || url.pathExtension.hasSuffix("proj")
                    || url.pathExtension == "xcworkspace" {
                    walker.skipDescendants()
                    continue
                }
                guard url.pathExtension == "swift",
                      let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
                if best.map({ size > $0.size || (size == $0.size && url.path < $0.url.path) }) ?? true { best = (url, size) }
            }
            return best?.url
        }
        let folders = targets.map { model.root.appendingPathComponent($0) }
            .filter { var isDirectory: ObjCBool = false
                      return fm.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue }
        guard let found = folders.lazy.compactMap(largest).first ?? largest(in: model.root) else { return nil }
        let cwd = FixPaths.canonical(URL(fileURLWithPath: fm.currentDirectoryPath)).path + "/"
        let path = FixPaths.canonical(found).path
        return path.hasPrefix(cwd) ? String(path.dropFirst(cwd.count)) : path
    }

    /// `--kind` of the finding's `xcblame verify` command, else `clean`.
    static func verifyKind(_ commands: [String]) -> String {
        for command in commands where command.hasPrefix("xcblame verify") {
            let words = command.split(separator: " ").map(String.init)
            if let index = words.firstIndex(of: "--kind"), index + 1 < words.count { return words[index + 1] }
        }
        return "clean"
    }

    /// The effective value an overlay assignment gives when nothing above it sets the key: `$(inherited)` expands to
    /// the value below (probes Q7). Nil when that value is unknown and needed.
    static func expected(_ value: String, before: String?) -> String? {
        guard value.contains("$(inherited)") else { return value }
        guard let before else { return nil }
        return normalized(value.replacingOccurrences(of: "$(inherited)", with: before))
    }

    /// `effective` carries `written` (`$(inherited)` stands for whatever the lower levels give).
    static func matches(effective: String, written: String) -> Bool {
        let own = normalized(written.replacingOccurrences(of: "$(inherited)", with: ""))
        let value = normalized(effective)
        return written.contains("$(inherited)") ? own.isEmpty || (" " + value + " ").contains(" " + own + " ") : value == own
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    /// One oracle run per configuration with every overlay line of the plan (keys are distinct per configuration).
    private func cliRun(_ ordered: [(ReportDocument.Finding, [Assignment])], id: String) -> [String: EffectiveSettings] {
        guard let cliOracle else { return [:] }
        var out: [String: EffectiveSettings] = [:]
        var seen: [String] = []
        for assignment in ordered.flatMap(\.1) where !seen.contains(assignment.configuration) { seen.append(assignment.configuration) }
        for configuration in seen {
            let lines = ordered.flatMap { finding, assignments in
                assignments.filter { $0.configuration == configuration }.map {
                    OverlayFile.line(key: $0.key, condition: $0.condition, value: $0.value, ruleId: finding.ruleId, planId: id)
                }
            }
            if let settings = cliOracle(configuration, lines) { out[configuration] = settings }
        }
        return out
    }

    // MARK: - Plan id, carry-over, guards, commands

    /// First 8 hex of SHA-256 over the analysis id (or path), the container, and per step its rule id, overlay
    /// assignments (`<Config>|KEY[cond] = VALUE`) and defaults `key=value`.
    static func planId(source: String?, container: String,
                       steps: [(ruleId: String, overlay: [Assignment], defaults: String)]) -> String {
        var text = (source ?? "") + "\n" + container + "\n"
        for step in steps {
            text += step.ruleId + "\n"
            for line in step.overlay { text += "\(line.configuration)|\(line.key)\(line.condition ?? "") = \(line.value)\n" }
            if !step.defaults.isEmpty { text += step.defaults + "\n" }
        }
        return SHA256.hash(data: Data(text.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The stored plan with the same id keeps its step states and events. Verify states also come from any other
    /// stored plan of the project with an identical step (same rule and lines, e.g. `fix --rules X`), and from
    /// `history/verify/` entries of this plan, newest first. A verdict is reused only when its `basis` equals the new
    /// step's (`VerifyBasis.value` over `projectDigest`, the project files as they are now); otherwise the step stays
    /// `unverified` and the plan notes "project changed since verify" (fix round 1, review gap 2).
    static func carryOver(into plan: inout FixPlanDocument, xcblameDir: URL, projectDigest: String) {
        let stored = FixPlanStore.list(xcblameDir: xcblameDir).filter { $0.project.container == plan.project.container }
        var stale: [String: String] = [:]
        func usable(_ state: FixPlanDocument.VerifyState, for step: FixPlanDocument.Step) -> Bool {
            guard state.status != .unverified else { return false }
            if state.basis == VerifyBasis.value(step: step, container: plan.project.container, projectDigest: projectDigest) {
                return true
            }
            if stale[step.ruleId] == nil { stale[step.ruleId] = state.verifyId ?? "an earlier verify" }
            return false
        }
        if let same = stored.first(where: { $0.id == plan.id }) {
            plan.events = same.events
            for index in plan.steps.indices {
                guard let old = same.steps.first(where: { $0.ruleId == plan.steps[index].ruleId }) else { continue }
                if usable(old.verify, for: plan.steps[index]) { plan.steps[index].verify = old.verify }
                plan.steps[index].state = old.state
                plan.steps[index].stateReason = old.stateReason
            }
        }
        let entries = verifyEntries(xcblameDir: xcblameDir).filter { $0.planId == plan.id }
        for index in plan.steps.indices where plan.steps[index].verify.status == .unverified {
            let step = plan.steps[index]
            func assignments(_ step: FixPlanDocument.Step) -> [String] {
                step.overlay.map { "\($0.configuration)|\($0.key)\($0.condition ?? "") = \($0.value)" }
            }
            if let other = stored.lazy.compactMap({ plan in
                plan.steps.first { $0.ruleId == step.ruleId && assignments($0) == assignments(step) && $0.verify.status != .unverified }
            }).first(where: { usable($0.verify, for: step) }) {
                plan.steps[index].verify = other.verify
                stale[step.ruleId] = nil
                continue
            }
            for entry in entries {
                guard let unit = entry.results.first(where: { $0.ruleIds.contains(step.ruleId) }),
                      unit.verdict.status != .unverified else { continue }
                guard unit.basis != nil, unit.basis == VerifyBasis.combined(ruleIds: unit.ruleIds, plan: plan,
                                                                             projectDigest: projectDigest) else {
                    if stale[step.ruleId] == nil { stale[step.ruleId] = entry.id }
                    continue
                }
                plan.steps[index].verify = FixPlanDocument.VerifyState(
                    status: unit.verdict.status, reason: unit.verdict.reason, mechanism: unit.mechanism,
                    kind: entry.kind.rawValue, verifyId: entry.id, verifiedAt: entry.generatedAt,
                    deltaSeconds: unit.deltaSeconds, deltaPct: unit.deltaPct, tie: unit.verdict.tie,
                    basis: VerifyBasis.value(step: step, container: plan.project.container, projectDigest: projectDigest))
                stale[step.ruleId] = nil
                break
            }
        }
        for step in plan.steps where step.verify.status == .unverified {
            guard let id = stale[step.ruleId] else { continue }
            plan.notes.append("\(step.ruleId): project changed since verify (\(id)): the verdict is not reused; "
                + verifyCommand(step))
        }
    }

    /// Per rule, the verify state of the newest stored plan that measured it (`unverified` steps skipped), in the
    /// text spelling: the analyze and doctor fix-plan steps carry it (`ReportDocument.FixPlanStep.verifyStatus`).
    public static func verifyLabels(xcblameDir: URL) -> [String: String] {
        var labels: [String: String] = [:]
        for plan in FixPlanStore.list(xcblameDir: xcblameDir) {
            for step in plan.steps where step.verify.status != .unverified && labels[step.ruleId] == nil {
                labels[step.ruleId] = FixVerifyWords.stateLabel(step.verify)
            }
        }
        return labels
    }

    /// `history/verify/*.json.gz` (lane B writes them), newest first; unreadable files are skipped.
    static func verifyEntries(xcblameDir: URL) -> [VerifyDocument] {
        let dir = xcblameDir.appendingPathComponent("history/verify")
        let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent.hasSuffix(".json.gz") }
            .compactMap { url in
                (try? GzipFile.inflate(contentsOf: url)).flatMap {
                    try? JSONReporter.decoder().decode(VerifyDocument.self, from: Data($0.bytes))
                }
            }
            .sorted { $0.generatedAt > $1.generatedAt }
    }

    func guards(_ plan: FixPlanDocument, model: ProjectModel, findings: [ReportDocument.Finding],
                xcblameDir: URL) -> [FixPlanDocument.Guard] {
        var guards: [FixPlanDocument.Guard] = []
        let overlaySteps = plan.steps.filter { $0.fixKind == .overlay }
        let configurations = Set(overlaySteps.flatMap { $0.overlay.map(\.configuration) })
        // The files the plan touches: overlay files and hooked (or hookable) base xcconfigs.
        var files = configurations.sorted().map { OverlayFile.url(xcblameDir: xcblameDir, configuration: $0) }
        files += configurations.sorted().flatMap { configuration -> [URL] in
            guard case let .success(sites) = HookInstaller.sites(model, configuration: configuration) else { return [] }
            return sites.map(\.xcconfig)
        }
        let dirty: Bool? = isDirty.flatMap { check in
            let states = files.filter { FileManager.default.fileExists(atPath: $0.path) }.map(check)
            if states.contains(true) { return false }
            return states.contains(false) ? true : nil
        }
        if !overlaySteps.isEmpty {
            guards.append(.init(id: "commitFirst", text: "xcblame fix --apply writes the overlay file the team shares "
                                + "(.xcblame/overlay-<Configuration>.xcconfig): commit your own changes first so the fix "
                                + "is a commit of its own", ruleIds: overlaySteps.map(\.ruleId), satisfied: dirty))
        }
        let hookSteps = plan.steps.filter { $0.mechanism == .hook }
        if !hookSteps.isEmpty {
            let needed = Set(hookSteps.flatMap { $0.overlay.map(\.configuration) })
            let installed = plan.hook.filter { needed.contains($0.configuration) }.allSatisfy { $0.status == "installed" }
            guards.append(.init(id: "hookInstalled", text: "hook steps reach Xcode and xcodebuild only through the "
                                + "#include? hook in the project's base xcconfig: run xcblame fix --install-hook once",
                                ruleIds: hookSteps.map(\.ruleId), satisfied: installed))
        }
        for step in plan.steps {
            for prerequisite in RulePlan.prerequisites[step.ruleId] ?? []
                where findings.contains(where: { RuleCatalog.resolve($0.ruleId) == prerequisite }) {
                guards.append(.init(id: "prerequisite", text: "fix \(prerequisite) before \(step.ruleId): "
                                    + "\(step.ruleId) assumes it (the plan orders it first)",
                                    ruleIds: [prerequisite, step.ruleId], satisfied: false))
            }
        }
        let verifyOnly = plan.steps.filter(\.verifyOnly)
        if !verifyOnly.isEmpty {
            guards.append(.init(id: "verifyFirst", text: "+V steps are written only after xcblame verify keeps them "
                                + "(--force-unverified does not override this)", ruleIds: verifyOnly.map(\.ruleId),
                                satisfied: verifyOnly.allSatisfy { $0.verify.status == .kept }))
        }
        let measured = plan.steps.filter { $0.mechanism == .hook || $0.mechanism == .cli }
        if !measured.isEmpty {
            guards.append(.init(id: "cleanTree", text: "xcblame verify needs the files the plan touches committed "
                                + "(overlay files and hooked xcconfigs), so it can restore them exactly",
                                ruleIds: measured.map(\.ruleId), satisfied: dirty))
        }
        return guards
    }

    /// Plan-level commands in order: install the hook, verify each measurable step, apply.
    public static func commands(_ plan: FixPlanDocument) -> [String] {
        var commands: [String] = []
        let rules = plan.generatedFrom.rulesFilter.isEmpty ? "" : " --rules " + plan.generatedFrom.rulesFilter.joined(separator: ",")
        let hookSteps = plan.steps.filter { $0.mechanism == .hook }
        let needed = Set(hookSteps.flatMap { $0.overlay.map(\.configuration) })
        if plan.hook.contains(where: { needed.contains($0.configuration) && $0.status == "notInstalled" }) {
            commands.append("xcblame fix --install-hook")
        }
        for step in plan.steps where step.fixKind == .overlay && step.verify.status != .kept {
            commands.append(verifyCommand(step))
        }
        if plan.steps.contains(where: { $0.fixKind == .overlay }) { commands.append("xcblame fix" + rules + " --apply") }
        if plan.steps.contains(where: { $0.mechanism == .defaults }) { commands.append("xcblame fix" + rules + " --apply-defaults") }
        return commands
    }
}

extension ReportDocument {
    /// The configurations the doctor pass evaluated (`project.configurations`), nil when it has no project section.
    var doctorConfigurations: [String]? { project?.configurations.isEmpty == false ? project?.configurations : nil }
}
