import ArgumentParser
import Foundation
import XcblameKit

/// `--mechanism hook|cli` of `verify` (`FixPlanDocument.Mechanism` minus `defaults` and `recommend`).
enum VerifyMechanism: String, ExpressibleByArgument, CaseIterable {
    case hook, cli

    var planMechanism: FixPlanDocument.Mechanism { self == .hook ? .hook : .cli }
}

extension VerifyDocument.Kind: ExpressibleByArgument {}

/// `xcblame verify [--runs n] [--kind clean|incremental|zero-change] [--rules <ids>] [--one-by-one] [--keep-on-tie]
/// [--max-minutes n] [--mechanism hook|cli] [-- <xcodebuild args>]` (DESIGN §3.2, §7.8; docs/SCHEMA-v0.6.md "verify").
/// Lane B fills `run`. Exit 6 when the run aborts (dirty tree, battery, thermal, timeout, broken baseline build).
struct VerifyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Measure fix-plan steps A/B: builds without and with each change, keeps only what is faster beyond noise.",
        discussion: """
            Each arm (A: without the change, B: with it) runs --runs builds through the mechanism the fix will use. \
            A step is kept when B's median build time is lower than A's by more than the noise band; it is reverted \
            when slower, within noise, when a B build fails, or when the set of tasks changes. Verdicts are written \
            into the plan, so xcblame fix --apply writes only kept steps.
            """)

    @Option(help: "Builds per arm, the settle build of incremental and zero-change included (default: 5; fewer than 4 gives indicative verdicts that are never kept).")
    var runs: Int = 5
    @Option(help: "What each measured build is: clean, incremental or zero-change (default: each step's planned kind).")
    var kind: VerifyDocument.Kind?
    @Option(help: "With --kind incremental: the file whose timestamp is touched before each measured build (default: one verify picks, named in the notes).",
            completion: .file())
    var touch: String?
    @Option(help: "Only these rule ids, comma-separated (default: every plan step with overlay lines).") var rules: String?
    @Flag(name: .customLong("one-by-one"), help: "Measure each rule on its own instead of all selected rules as one batch.")
    var oneByOne = false
    @Flag(name: .customLong("keep-on-tie"), help: "Keep a change whose difference is within the noise band.")
    var keepOnTie = false
    @Option(name: .customLong("max-minutes"), help: "Stop after this many minutes (exit 6; finished verdicts are kept).")
    var maxMinutes: Double?
    @Option(help: "Deliver the change through hook (the overlay via the installed #include? hook) or cli (a -xcconfig wrapper) (default: each step's planned mechanism).")
    var mechanism: VerifyMechanism?
    @Option(help: "Verify this plan (id or unique prefix; default: the newest stored plan with the selected rules, else a new one).")
    var plan: String?
    @Option(name: .customLong("xcblame-dir"), help: "xcblame state folder (history, plans, overlay files).",
            completion: .directory)
    var xcblameDir: String = ".xcblame"
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .postTerminator,
              help: "Arguments passed to xcodebuild, after -- (default: the scheme, configuration and destination of the plan's analysis).")
    var xcodebuildArguments: [String] = []

    static let formats: [OutputFormat] = [.text, .json, .html, .markdown, .agent]

    func validate() throws {
        if let format = global.format, !Self.formats.contains(format) {
            throw ValidationError("verify writes text, json, html, markdown or agent (--format \(format.rawValue))")
        }
        if runs < 1 { throw ValidationError("--runs must be at least 1") }
        if let maxMinutes, maxMinutes <= 0 { throw ValidationError("--max-minutes must be greater than 0") }
        if touch != nil, kind != .incremental { throw ValidationError("--touch needs --kind incremental") }
        if let ids = commaList(rules), !ids.contains(where: { RuleCatalog.spec($0) != nil }) {
            throw ValidationError("no known rule among --rules \(ids.joined(separator: ",")) (xcblame rules list shows the ids)")
        }
    }

    func run() throws {
        // v0.6 lane B (begin): plan (`FixPlanStore`, else a fresh one through `PlanLoading`), `ABHarness.verify`
        // (verdicts into the plan with `FixPlanStore.save`, the history verify entry), output (`emitVerify`, lane C's
        // five formats), exit 6 when `abort` is set.
        let state = URL(fileURLWithPath: NSString(string: xcblameDir).expandingTildeInPath).standardizedFileURL
        // A verify killed where no handler ran (SIGKILL, a crash) left its temporary block: the bytes come back first.
        if let warning = VerifyJournal.recover(xcblameDir: state) { writeStderr(warning) }
        let ruleIds = commaList(rules)
        let stored: FixPlanDocument?
        do {
            stored = try VerifySelection.storedPlan(id: plan, rules: ruleIds, xcblameDir: state)
        } catch let error as FixPlanStore.StoreError {
            writeStderr("error: \(error)")
            if case .unreadable = error { throw ArgumentParser.ExitCode(XcblameExit.internalError.rawValue) }
            throw ArgumentParser.ExitCode(XcblameExit.usage.rawValue)
        }
        let chosen: FixPlanDocument
        if let stored {
            chosen = stored
        } else {
            chosen = try freshPlan(state: state, ruleIds: ruleIds)
        }
        let fake = ProcessInfo.processInfo.environment["XCBLAME_XCODEBUILD"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let request = VerifyRequest(plan: chosen, rules: ruleIds, kind: kind, runs: runs, oneByOne: oneByOne,
                                    keepOnTie: keepOnTie, maxMinutes: maxMinutes, mechanism: mechanism?.planMechanism,
                                    touch: touch, xcodebuildArguments: xcodebuildArguments, xcblameDir: state,
                                    cacheHome: OracleCache.home(), executable: fake, generatedAt: Date())
        // SIGINT/SIGTERM/SIGHUP/SIGQUIT: stop the running xcodebuild first, then restore the overlay (`VerifySignals`).
        let cancel = XcodebuildRunner.Cancel()
        let interrupt = VerifyInterrupt()
        interrupt.onRaise { cancel.terminate() }
        let harness = ABHarness(runner: XcodebuildVerifyRunner(xcblameDir: state, executable: fake, cancel: cancel),
                                host: EnvironmentVerifyHost(), interrupt: interrupt)
        if !global.quiet { writeStderr("note: verifying plan \(chosen.id) (xcodebuild output goes to stderr)") }
        VerifyDerivedData.prune(home: request.cacheHome, olderThanDays: VerifyDerivedData.keepDays)
        let document: VerifyDocument
        do {
            document = try Self.stdoutOnStderr { try harness.verify(request) }
        } catch let error as XcblameError {
            writeStderr("error: \(error)")
            throw ArgumentParser.ExitCode(XcblameExit(error).rawValue)
        } catch {
            writeStderr("error: xcblame verify: \(error)")
            throw ArgumentParser.ExitCode(XcblameExit.internalError.rawValue)
        }
        _ = try? Retention.apply(stateDir: state)
        try emitVerify(document, global: global, stateDir: state)
        if let abort = document.abort {
            writeStderr("verify aborted (\(abort.reason.rawValue)): \(abort.detail)")
            throw ArgumentParser.ExitCode(XcblameExit.verifyAborted.rawValue)
        }
        // v0.6 lane B (end)
    }
}

// v0.6 lane B (begin): output, and stdout kept for the document while xcodebuild runs.
extension VerifyCommand {
    /// xcodebuild's output (tee'd to xcblame's stdout by `XcodebuildRunner`) goes to stderr while `body` runs, so stdout
    /// carries only the verify document.
    static func stdoutOnStderr<T>(_ body: () throws -> T) rethrows -> T {
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        if saved >= 0 { dup2(STDERR_FILENO, STDOUT_FILENO) }
        defer {
            fflush(stdout)
            if saved >= 0 {
                dup2(saved, STDOUT_FILENO)
                close(saved)
            }
        }
        return try body()
    }

    /// No stored plan has the selected rules: plan from the newest non-deep history entry and a doctor pass, as `fix`
    /// does, and store it. Exit 1 only when there is no analysis at all.
    func freshPlan(state: URL, ruleIds: [String]?) throws -> FixPlanDocument {
        do {
            let analysis = try PlanLoading.analysis(from: nil, xcblameDir: state)
            guard analysis.document != nil else {
                let folder = FixPlanStore.directory(xcblameDir: state).path
                let wanted: String = ruleIds.map { "a step for every one of " + $0.joined(separator: ", ") } ?? "an overlay step"
                let command: String = "xcblame fix" + (rules.map { " --rules " + $0 } ?? "")
                writeStderr("error: no stored fix plan in \(folder) has \(wanted), and there is no analysis in the history "
                    + "to plan from: run xcblame build, or \(command) first")
                throw ArgumentParser.ExitCode(XcblameExit.internalError.rawValue)
            }
            let flag = xcodebuildArguments.firstIndex { $0 == "-workspace" || $0 == "-project" }
            let given = flag.flatMap { $0 + 1 < xcodebuildArguments.count ? xcodebuildArguments[$0 + 1] : nil }
            let container = try PlanLoading.locateContainer(given)
            let model = try ProjectModel.load(container: container, scheme: nil)
            let plan = try PlanLoading.makePlan(model: model, container: container, analysis: analysis, configurations: [],
                                                rules: ruleIds, offline: false, isCI: global.isCI, xcblameDir: state,
                                                now: Date())
            try FixPlanStore.save(plan, xcblameDir: state)
            if !global.quiet {
                writeStderr("note: no stored plan has the selected rules: planned \(plan.id) from history entry "
                    + "\(analysis.id ?? "?") and a doctor pass (stored in \(FixPlanStore.directory(xcblameDir: state).path))")
            }
            return plan
        } catch let error as XcblameError {
            writeStderr("error: \(error)")
            throw ArgumentParser.ExitCode(XcblameExit(error).rawValue)
        }
    }
}
// v0.6 lane B (end)
