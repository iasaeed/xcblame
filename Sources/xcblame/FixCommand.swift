import ArgumentParser
import Foundation
import XcblameKit

/// `xcblame fix [--rules <ids>] [--apply] [--apply-defaults] [--install-hook] [--uninstall-hook] [--revert [<plan-id>]]
/// [--plan-out <file>]` (DESIGN §3.2, §7.3, §7.5; docs/SCHEMA-v0.6.md "fix").
///
/// Without a write flag it prints the plan (and stores it in `<xcblame-dir>/plans/`); nothing in the project changes.
struct FixCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fix",
        abstract: "Print a fix plan from the latest analysis and a doctor pass; write it only when asked.",
        discussion: """
            --apply writes overlay lines (.xcblame/overlay-<Configuration>.xcconfig) of the steps xcblame verify kept. \
            --apply-defaults writes the Xcode defaults steps. --install-hook adds one #include? line to the project's \
            base xcconfig so Xcode and xcodebuild read the overlay. --revert and --uninstall-hook undo them.
            """)

    @Option(help: "Only these rule ids, comma-separated.") var rules: String?
    @Flag(help: "Write the overlay lines of the steps verify kept (never anything but overlay lines).") var apply = false
    @Flag(name: .customLong("apply-defaults"),
          help: "Write the Xcode defaults steps (defaults write com.apple.dt.Xcode …); prior values are saved for --revert.")
    var applyDefaults = false
    @Flag(name: .customLong("force-unverified"),
          help: "With --apply/--apply-defaults: also write steps verify has not measured (never +V rules, never reverted steps).")
    var forceUnverified = false
    @Flag(name: .customLong("install-hook"),
          help: "Append #include? \".xcblame/overlay-<Configuration>.xcconfig\" to each configuration's project-level base xcconfig (bytes backed up).")
    var installHook = false
    @Flag(name: .customLong("uninstall-hook"), help: "Remove the hook: restore the backed-up bytes of each hooked xcconfig.")
    var uninstallHook = false
    @Flag(help: "Undo a plan: remove its overlay blocks and restore the defaults it wrote (default plan: the newest applied one).")
    var revert = false
    @Argument(help: "With --revert: the plan id (or a unique prefix) to revert.") var planId: String?
    @Flag(name: .customLong("edit-project"), help: "Edit the project file (pbxproj, scheme, manifest). Not available in xcblame 0.6.")
    var editProject = false
    @Option(name: .customLong("plan-out"), help: "Also write the plan JSON to this file.", completion: .file())
    var planOut: String?
    @Option(help: "Plan from this analysis: a history entry id or a saved report JSON (default: the newest history entry).",
            completion: .file())
    var from: String?
    @Option(help: "The .xcodeproj to plan for.", completion: .file(extensions: ["xcodeproj"])) var project: String?
    @Option(help: "The .xcworkspace to plan for.", completion: .file(extensions: ["xcworkspace"])) var workspace: String?
    @Option(name: .customLong("configuration"),
            help: "Configuration to plan for; repeat for several (default: every configuration of the project).")
    var configurations: [String] = []
    @Flag(help: "Do not run xcodebuild for the doctor pass: resolve settings from the project files only.") var offline = false
    @Option(name: .customLong("xcblame-dir"), help: "xcblame state folder (history, plans, backups, overlay files).",
            completion: .directory)
    var xcblameDir: String = ".xcblame"
    @OptionGroup var global: GlobalOptions

    static let formats: [OutputFormat] = [.text, .json, .html, .markdown, .agent]

    func validate() throws {
        if let format = global.format, !Self.formats.contains(format) {
            throw ValidationError("fix writes text, json, html, markdown or agent (--format \(format.rawValue))")
        }
        if editProject {
            throw ValidationError("--edit-project (pbxproj, scheme and manifest edits) is not part of xcblame 0.6: "
                + "make the change by hand (the plan's inXcode steps), or deliver a setting with xcblame verify --mechanism cli")
        }
        if project != nil, workspace != nil { throw ValidationError("give either --project or --workspace") }
        if planId != nil, !revert { throw ValidationError("a plan id is taken only with --revert") }
        if (revert || uninstallHook), apply || applyDefaults || installHook {
            throw ValidationError("--revert and --uninstall-hook undo writes: give them without --apply, --apply-defaults or --install-hook")
        }
        if forceUnverified, !apply, !applyDefaults { throw ValidationError("--force-unverified needs --apply or --apply-defaults") }
        if let ids = commaList(rules), !ids.contains(where: { RuleCatalog.spec($0) != nil }) {
            throw ValidationError("no known rule among --rules \(ids.joined(separator: ",")) (xcblame rules list shows the ids)")
        }
    }

    func run() throws {
        // v0.6 lane A (begin): `FixPlanner.plan` through `PlanLoading` (the stored plan with the same id keeps its
        // verify states), `FixPlanStore.save`, then the writes the flags ask for (FixApply, HookInstaller,
        // DefaultsApplier) and the output (`emitFixPlan`, lane C's five formats).
        let container = try locateContainer()
        let model = try ProjectModel.load(container: container, scheme: nil)
        let dir = stateURL
        let now = Date()
        var failed = false
        let wantedConfigurations = configurations.isEmpty ? model.configurationNames : configurations
        // A verify killed where no handler ran left its temporary block in the overlay: put the bytes back first.
        if let warning = VerifyJournal.recover(xcblameDir: dir) { writeStderr(warning) }

        if revert || uninstallHook {
            if revert { failed = try runRevert(model: model, dir: dir, now: now) || failed }
            if uninstallHook {
                let outcomes = HookInstaller.uninstall(project: model, configurations: wantedConfigurations, xcblameDir: dir)
                report(outcomes.map { ($0.isFailure ? "error: " : "") + $0.message })
                failed = failed || outcomes.contains(where: \.isFailure)
                let files = outcomes.filter { $0.status == .uninstalled }.compactMap(\.file)
                if !files.isEmpty, var plan = FixPlanStore.list(xcblameDir: dir).first(where: {
                    $0.project.container == model.container.url.path
                }) {
                    plan.events.append(.init(at: now, action: "uninstallHook", ruleIds: [], files: files, defaultsKeys: []))
                    plan.hook = HookInstaller.states(project: model, configurations: plan.project.configurations,
                                                     xcblameDir: dir)
                    try FixPlanStore.save(plan, xcblameDir: dir)
                }
            }
            if failed { throw ArgumentParser.ExitCode(XcblameExit.internalError.rawValue) }
            return
        }

        var plan = try makePlan(model: model, container: container, now: now)
        try FixPlanStore.save(plan, xcblameDir: dir)
        let eventsBefore = plan.events.count
        if apply {
            for file in HookInstaller.notLast(project: model, configurations: wantedConfigurations, xcblameDir: dir) {
                writeStderr("warning: lines after the xcblame hook in \(file) win over the overlay")
            }
            let result = FixApply.apply(plan, root: model.root, xcblameDir: dir, forceUnverified: forceUnverified, now: now)
            // With --install-hook in the same call the hook goes in right after: no "not installed" warning.
            report(result.messages.filter { !(installHook && $0.hasPrefix("warning: the hook is not installed")) })
            failed = failed || result.failed
            plan = result.plan
        }
        if installHook {
            let verifier = offline ? HookInstaller.offlineVerifier(container: container)
                : HookInstaller.xcodebuildVerifier(model: model)
            let outcomes = HookInstaller.install(project: model, configurations: wantedConfigurations, xcblameDir: dir,
                                                 isDirty: HookInstaller.gitDirty, verify: verifier)
            report(outcomes.map { ($0.isFailure ? "error: " : "") + $0.message })
            failed = failed || outcomes.contains(where: \.isFailure)
            let files = outcomes.filter { $0.status == .installed }.compactMap(\.file)
            if !files.isEmpty {
                plan.events.append(.init(at: now, action: "installHook", ruleIds: [], files: files, defaultsKeys: []))
            }
            plan.hook = HookInstaller.states(project: model, configurations: plan.project.configurations, xcblameDir: dir)
            plan.commands = FixPlanner.commands(plan)
        }
        if applyDefaults {
            let result = FixApply.applyDefaults(plan, xcblameDir: dir, runner: SystemDefaults(), now: now)
            report(result.messages)
            failed = failed || result.failed
            plan = result.plan
        }
        try FixPlanStore.save(plan, xcblameDir: dir)
        if let planOut {
            // Redacted like stdout and -o (review minor 11): no absolute container path, user or host in the file.
            try JSONReporter.render(try ReportPipeline.prepareForOutput(plan, redact: global.resolvedRedact))
                .write(to: URL(fileURLWithPath: NSString(string: planOut).expandingTildeInPath), options: .atomic)
        }
        // "the project changed" only when something was written (an apply, hook or defaults event), not for a write
        // flag that skipped every step (review B).
        try emitFixPlan(plan, global: global, stateDir: dir, wrote: plan.events.count > eventsBefore)
        if failed { throw ArgumentParser.ExitCode(XcblameExit.internalError.rawValue) }
        // v0.6 lane A (end)
    }

    // MARK: - v0.6 lane A helpers

    private var stateURL: URL {
        URL(fileURLWithPath: NSString(string: xcblameDir).expandingTildeInPath).standardizedFileURL
    }

    /// One line per message on stderr (`--quiet` keeps only errors).
    private func report(_ messages: [String]) {
        for message in messages where !global.quiet || message.hasPrefix("error") {
            writeStderr(message.hasPrefix("error") ? message : "fix: " + message)
        }
    }

    /// `--revert [<plan-id>]`; true when it failed.
    private func runRevert(model: ProjectModel, dir: URL, now: Date) throws -> Bool {
        let stored: FixPlanDocument?
        let id: String
        if let planId {
            stored = try? FixPlanStore.load(id: planId, xcblameDir: dir)
            id = stored?.id ?? planId
        } else if let newest = FixApply.newestApplied(xcblameDir: dir) {
            stored = newest
            id = newest.id
        } else {
            report(["nothing to revert: no stored plan has an apply that is not reverted yet (give the plan id)"])
            return false
        }
        let result = FixApply.revert(planId: id, plan: stored, root: model.root, xcblameDir: dir,
                                     runner: SystemDefaults(), now: now)
        report(result.messages)
        if stored != nil, !result.failed { try FixPlanStore.save(result.plan, xcblameDir: dir) }
        return result.failed
    }

    /// `--project` / `--workspace` as given (must exist), or the container found in the current directory.
    private func locateContainer() throws -> URL {
        try PlanLoading.locateContainer(project ?? workspace)
    }

    /// A doctor pass plus the analysis `--from` names (else the newest non-deep history entry), through `FixPlanner`.
    private func makePlan(model: ProjectModel, container: URL, now: Date) throws -> FixPlanDocument {
        try PlanLoading.makePlan(model: model, container: container,
                                 analysis: try PlanLoading.analysis(from: from, xcblameDir: stateURL),
                                 configurations: configurations, rules: commaList(rules), offline: offline,
                                 isCI: global.isCI, xcblameDir: stateURL, now: now)
    }
}
