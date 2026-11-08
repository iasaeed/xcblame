import ArgumentParser
import Foundation
import XcblameKit

/// `xcblame build [opts] -- <xcodebuild args>` (DESIGN §3.2). Lane B.
///
/// In the default mode this command never changes xcodebuild's exit code: a log that cannot be found or read, a failed
/// analysis, a failed history write all print to stderr and the exit code is still xcodebuild's.
struct BuildCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "build",
        abstract: "Run xcodebuild, capture its log and build description, and analyze the build.")

    enum ExitCodeSource: String, ExpressibleByArgument, CaseIterable {
        case xcodebuild, xcblame
    }

    @Flag(help: "Also write an html report to <xcblame-dir>/reports/.") var html = false
    @Flag(name: .customLong("no-history"), help: "Do not record this build in the local history.")
    var noHistory = false
    @Option(name: .customLong("exit-code"), help: "Exit with xcodebuild's code (default) or xcblame's.")
    var exitCode: ExitCodeSource = .xcodebuild
    @Option(help: "Stop xcodebuild after this many seconds (exit code 124).") var timeout: Double?
    @Option(name: .customLong("xcblame-dir"), help: "xcblame state folder (snapshots, history, reports).",
            completion: .directory)
    var xcblameDir: String = ".xcblame"
    // v0.5 flags (docs/SCHEMA-v0.5.md "build --deep"): --deep, --deep-scope, --exact-files lane A; --runs, --kind,
    // --touch lane B.
    @Flag(help: "Build with timing flags (type-check times, stats-dir, ftime-trace) in a separate DerivedData under the cache folder.")
    var deep = false
    @Option(name: .customLong("deep-scope"), help: "With --deep: swift, clang or swift,clang (default).")
    var deepScope: String?
    @Flag(name: .customLong("exact-files"),
          help: "With --deep: rebuild the targets of the longest batches without batch mode for exact per-file times (changes the build shape).")
    var exactFiles = false
    @Option(help: "Build this many times and analyze each run (default 1).") var runs: Int?
    @Option(help: "Prepare the build as clean, incremental (with --touch) or zero-change before measuring it.")
    var kind: String?
    @Option(help: "Touch this file before the measured build (with --kind incremental, or alone).", completion: .file())
    var touch: String?
    @Flag(name: .customLong("no-backtraces"),
          help: "With --kind incremental, zero-change or --touch: do not record Task Backtraces (EnableBuildBacktraceRecording=YES is set by default, as in why --backtraces).")
    var noBacktraces = false
    // v0.6 fix round 1 (DESIGN §3.2, §7.5): --overlay [<plan-id>], --overlay-unverified.
    @Flag(help: "Deliver a fix plan's kept overlay lines through a command-line -xcconfig wrapper (CI, cli steps; Xcode builds read the overlay through the hook). The newest plan with kept overlay steps unless a plan id follows. The oracle checks every key wins before the build; a key that does not is an error and nothing is built. Needs -configuration after --.")
    var overlay = false
    @Flag(name: .customLong("overlay-unverified"),
          help: "With --overlay: also deliver steps verify has not measured (never +V, reverted or indicative ones).")
    var overlayUnverified = false
    @Argument(help: "With --overlay: the fix plan id (or a unique prefix) whose overlay lines are delivered.")
    var overlayPlan: String?
    @OptionGroup var regression: RegressionFlags
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .postTerminator, help: "Arguments passed to xcodebuild, after --.")
    var xcodebuildArguments: [String] = []

    func validate() throws {
        if let timeout, timeout <= 0 { throw ValidationError("--timeout must be greater than 0") }
        if let deepScope {
            guard deep else { throw ValidationError("--deep-scope needs --deep") }
            do { _ = try DeepScope.parse(deepScope) } catch { throw ValidationError("\(error)") }
        }
        if exactFiles, !deep { throw ValidationError("--exact-files needs --deep") }
        // v0.5 lane A (begin): the deep build owns its DerivedData (docs/SCHEMA-v0.5.md "Deep DerivedData").
        if deep, xcodebuildArguments.contains("-derivedDataPath") {
            throw ValidationError("--deep builds in its own DerivedData under the cache folder; remove -derivedDataPath")
        }
        // v0.5 lane A (end)
        if let runs, runs < 1 { throw ValidationError("--runs must be at least 1") }
        if let kind, WhyProcedure.Kind(rawValue: kind) == nil {
            throw ValidationError("--kind must be one of " + WhyProcedure.Kind.allCases.map(\.rawValue).joined(separator: ", "))
        }
        if kind == WhyProcedure.Kind.incremental.rawValue, touch == nil {
            throw ValidationError("--kind incremental needs --touch <file>")
        }
        if noBacktraces, touch == nil, kind != WhyProcedure.Kind.zeroChange.rawValue {
            throw ValidationError("--no-backtraces needs --kind incremental, --kind zero-change or --touch <file>")
        }
        // v0.6 fix round 1 (begin)
        if overlayPlan != nil, !overlay { throw ValidationError("a plan id is taken only with --overlay") }
        if overlayUnverified, !overlay { throw ValidationError("--overlay-unverified needs --overlay") }
        if overlay, Self.argument("-configuration", in: xcodebuildArguments) == nil {
            throw ValidationError("--overlay needs -configuration <name> after -- (the overlay lines are per configuration)")
        }
        // v0.6 fix round 1 (end)
    }

    func run() throws {
        Self.baselineFailure = nil
        // v0.5 lane A (begin): --deep: toolchain probe, `DeepFlags.plan`, deep DerivedData, wrapper xcconfig with the
        // oracle check, then the build below runs with the rewritten arguments; `ReportPipeline.Options.deep` carries it.
        // The local `xcodebuildArguments` shadows the property for the rest of `run`, so the build below gets the deep
        // arguments (`-derivedDataPath <deep>`, `-xcconfig <wrapper>`) without touching shared code.
        // A run of `--runs` / `--kind` / `--touch` reuses the arguments `prepareDeep` made once for all runs.
        let xcodebuildArguments: [String]
        if let prepared = Self.preparedArguments {
            xcodebuildArguments = prepared
        } else {
            Self.deepRun = nil
            Self.deepUnsetEnvironment = []
            Self.overlayRun = nil
            Self.backtraceEnvironment = recordsBacktraces ? [WhyProcedure.backtraceVariable: "YES"] : nil
            // v0.6 fix round 1: a verify killed where no handler ran left a temporary block in the overlay.
            if let warning = VerifyJournal.recover(xcblameDir: stateURL) { writeStderr(warning) }
            let overlaid = overlay ? try prepareOverlay() : self.xcodebuildArguments
            xcodebuildArguments = deep ? try prepareDeep() : overlaid
        }
        // v0.5 lane A (end)
        // v0.5 lane B (begin): --kind / --touch preparation (`WhyProcedure.prepare`) and --runs repetition.
        if kind != nil || touch != nil || (runs ?? 1) > 1 {
            Self.preparedArguments = xcodebuildArguments
            defer { Self.preparedArguments = nil }
            try preparedRuns(arguments: xcodebuildArguments)
            return
        }
        // v0.5 lane B (end)
        let result: XcodebuildRunner.Result
        do {
            // XCBLAME_XCODEBUILD=<executable> replaces `xcrun xcodebuild`: the hook the CLI tests use for a fake build.
            if let fake = ProcessInfo.processInfo.environment["XCBLAME_XCODEBUILD"], !fake.isEmpty {
                result = try XcodebuildRunner.run(arguments: xcodebuildArguments, xcblameDir: stateURL, timeout: timeout,
                                                  executable: URL(fileURLWithPath: fake), executablePrefix: [],
                                                  environment: Self.backtraceEnvironment,
                                                  unsetEnvironment: Self.deepUnsetEnvironment)
            } else {
                result = try XcodebuildRunner.run(arguments: xcodebuildArguments, xcblameDir: stateURL, timeout: timeout,
                                                  environment: Self.backtraceEnvironment,
                                                  unsetEnvironment: Self.deepUnsetEnvironment)
            }
        } catch {
            writeStderr("error: \(error)")
            throw ArgumentParser.ExitCode(XcblameExit.internalError.rawValue)
        }
        if !global.quiet { for note in result.notes { writeStderr("note: \(note)") } }

        var analysisFailed = false
        var validationFailed = false
        var regressionFailed = false
        do {
            (validationFailed, regressionFailed) = try analyze(result)
        } catch {
            analysisFailed = true
            writeStderr("error: build analysis unavailable: \(error)")
            // The gate must not pass because there was nothing to gate (an unreadable baseline fails closed the same way).
            if regression.baseline != nil {
                writeStderr("error: the baseline was not evaluated because the analysis failed; exiting 1 even in "
                    + "--exit-code xcodebuild mode")
                Self.baselineFailure = XcblameExit.internalError.rawValue
            }
        }
        // v0.4 lane C (begin): every build adds a result bundle, a captured log and maybe a report; keep the newest
        // 200 / 90 days of each. Best effort, never changes the exit code.
        _ = try? Retention.apply(stateDir: stateURL)
        // v0.4 lane C (end)

        switch exitCode {
        case .xcodebuild:
            if result.exitCode != 0 { throw ArgumentParser.ExitCode(result.exitCode) }
        case .xcblame:
            if analysisFailed || validationFailed { throw ArgumentParser.ExitCode(XcblameExit.internalError.rawValue) }
        }
        // v0.4 lane B (begin): exit 3 when xcodebuild succeeded but the regression threshold was exceeded; an unusable
        // baseline (2 key mismatch, 5 unreadable, 1 not evaluable) counts the same way.
        if result.exitCode == 0, let code = Self.baselineFailure { throw ArgumentParser.ExitCode(code) }
        if result.exitCode == 0, regressionFailed { throw ArgumentParser.ExitCode(XcblameExit.failIfSlower.rawValue) }
        // v0.4 lane B (end)
    }

    // MARK: - Analysis

    /// The `analyze` path over the log this build wrote. Reports whether a validation check failed and whether the
    /// regression threshold (`--fail-if-slower`) was exceeded.
    private func analyze(_ result: XcodebuildRunner.Result) throws -> (validationFailed: Bool, regressionFailed: Bool) {
        guard let logURL = result.logURL else {
            throw XcblameError.noBuildLog("xcodebuild wrote no build log to analyze"
                + (result.notes.isEmpty || !global.quiet ? "" : " (" + result.notes.joined(separator: "; ") + ")"))
        }
        let loaded = try loadModel(at: logURL, options: LoadOptions(verbose: global.verbose, quiet: global.quiet))
        let format = global.resolvedFormat
        let snapshot = EnvSnapshot.capture()
        // The snapshot sits at `snapshots/<log uuid>/`: found there, it gets the locator's signature check.
        let description = BuildDescriptionLocator.find(
            model: loaded.model, logURL: logURL, explicit: nil, snapshotsDir: stateURL.appendingPathComponent("snapshots"))

        func pipeline(topN: Int, budget: Int, html: Bool) throws -> ReportPipeline.Result {
            var options = ReportPipeline.Options(
                topN: topN, budgetBytes: budget, generatedAt: Date(), inputPath: loaded.path, environment: snapshot,
                buildDescription: description,
                physicalCores: snapshot.performanceCores.map { $0 + (snapshot.efficiencyCores ?? 0) },
                processWall: result.wall)
            options.checksSize = !html
            // v0.5 integration: module-graph edges from the .xcodeproj (-project, else the log's) when the snapshot has
            // no target graph.
            options.project = ReportPipeline.moduleGraphProject(
                explicit: Self.argument("-project", in: xcodebuildArguments).map {
                    URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath).standardizedFileURL },
                logURL: logURL, description: description)
            // v0.5 lane A (begin): the deep build, with its DerivedData size measured once after the build.
            if let run = Self.deepRun, run.enabled, run.derivedDataBytes == nil {
                Self.deepRun?.derivedDataBytes = OracleCache.size(of: run.derivedData)
            }
            options.deep = Self.deepRun
            // v0.5 lane A (end)
            // v0.4 lane C (begin): the xcodebuild arguments (-scheme, -configuration, -destination) win, then the log
            // manifest's scheme, then the build request of the build description; what stays unknown is a note.
            let context = BuildContext.from(xcodebuildArguments: xcodebuildArguments)
                .filling(from: BuildContext.from(manifestScheme: loaded.scheme))
                .filling(from: description.map { BuildContext.from(buildRequest: $0.buildRequest.raw) } ?? BuildContext())
            options.buildContext = context
            // v0.4 lane C (end)
            var made = try ReportPipeline.run(loaded.model, options: options)
            // v0.6 fix round 1: `overlay: <plan-id>` in the build notes, so compare and trend see the delivered plan.
            if let run = Self.overlayRun { made.document.build.notes.append(run.note) }
            // v0.4 lane C (begin)
            if let note = context.missingNote(source: "the xcodebuild arguments, the log or its build description") {
                made.document.build.notes.append(note)
            }
            // v0.4 lane C (end)
            return made
        }
        let budget = format == .html ? HTMLReporter.defaultMaxBytes : Validator.defaultBudgetBytes
        var analyzed = try pipeline(topN: global.resolvedTop, budget: budget, html: !format.measuresJSONSize)
        // v0.5 lane B (begin): incremental causes against the previous history entry, before this build is saved.
        analyzed.document = CauseEngine.attach(to: analyzed.document, model: loaded.model,
                                               historyDir: stateURL.appendingPathComponent("history"), project: nil)
        // D1 (docs/SCHEMA-v0.6.md "report: previous"): the previous comparable build, before this one is saved.
        let previous = noHistory ? nil : ReportDocument.Previous.lookup(
            for: analyzed.document, historyDir: stateURL.appendingPathComponent("history"))
        analyzed.document.previous = previous
        analyzed.document = try analyzed.document.remeasuringSize(budgetBytes: budget)
        // v0.5 lane B (end)
        // v0.5 lane C (begin): fixed costs re-based on history frequency and builds per day.
        analyzed.document = FixedCosts.applyingHistory(to: analyzed.document,
                                                       historyDir: stateURL.appendingPathComponent("history"),
                                                       configURL: stateURL.appendingPathComponent("config.json"))
        // v0.5 lane C (end)
        if !noHistory { saveHistory(analyzed.document, model: loaded.model) }

        // Primary output: text or json to stdout (or -o), html to the reports folder.
        var document = analyzed.document
        // v0.4 lane B (begin): regression against --baseline, before redaction and rendering.
        if let baselineURL = regression.baselineURL {
            // A baseline that cannot be used does not stop the report: it is printed, noted in the report, and the exit
            // code is decided in `run` (xcodebuild's code still wins).
            do {
                let baseline = try Baseline.load(from: baselineURL)
                let rows = baseline.tasks == nil ? nil : Compare.taskRows(document: document, model: loaded.model)
                document.regression = try Regression.evaluate(current: [document], baseline: baseline,
                                                              baselineRef: regression.baseline, currentTaskRows: rows,
                                                              options: regression.options)
                regression.warnIfNotComparable(document.regression)
            } catch {
                writeStderr("error: \(error)")
                document.notes.append("regression: not evaluated (\(error))")
                Self.baselineFailure = (error as? XcblameError).map { XcblameExit($0).rawValue } ?? XcblameExit.internalError.rawValue
            }
        }
        // v0.4 lane B (end)
        document = relativizedForTextFormat(document, format: format)
        document = try ReportPipeline.prepareForOutput(document, redact: global.resolvedRedact)
        switch format {
        case .json: try emit(try JSONReporter.render(document), document: document, format: format)
        case .text:
            try emit(Data(TextReporter.render(document, colors: global.useColors).utf8), document: document, format: format)
        case .markdown, .github, .junit, .agent:
            try emit(try renderTextFormat(document, format: format, maxReportBytes: nil, xcblameDir: stateURL),
                     document: document, format: format)
        case .html: try writeHTML(model: loaded.model, analysis: analyzed, document: document)
        }

        // `--html` next to a text or json report: the html document wants every row, so it is built on its own.
        if html, format != .html {
            var full = try pipeline(topN: global.top?.value ?? .max, budget: HTMLReporter.defaultMaxBytes, html: true)
            full.document.previous = previous
            try writeHTML(model: loaded.model, analysis: full,
                          document: try ReportPipeline.prepareForOutput(full.document, redact: global.redact ?? true))
        }
        return (analyzed.document.validation.checks.contains { $0.status == "fail" },
                document.regression?.failed == true)
    }

    /// History is best effort: it never changes the exit code.
    private func saveHistory(_ document: ReportDocument, model: BuildModel) {
        do {
            _ = try History.save(document: document, model: model, directory: stateURL.appendingPathComponent("history"))
        } catch {
            writeStderr("warning: build not recorded in history: \(error)")
        }
    }

    // MARK: - Output (the AnalyzeCommand flow)

    private func emit(_ rendered: Data, document: ReportDocument, format: OutputFormat) throws {
        guard let output = global.output else {
            FileHandle.standardOutput.write(rendered)
            return
        }
        let url = URL(fileURLWithPath: NSString(string: output).expandingTildeInPath)
        // Atomic writes need a temp file next to the target, which devices such as /dev/null do not allow.
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        try rendered.write(to: url, options: type == nil || type == .typeRegular ? .atomic : [])
        if !global.quiet {
            print("wrote \(url.path) (\(format.rawValue), \(rendered.count) bytes) · \(checksSummary(document))")
        }
    }

    /// HTML never goes to stdout: it is written to `-o` (only when html is the primary format) or the reports folder.
    /// While Lane C's reporter or writer is missing, the note is printed and the build carries on.
    private func writeHTML(model: BuildModel, analysis: ReportPipeline.Result, document: ReportDocument) throws {
        do {
            var taskIndex = TaskIndex.make(model: model, analysis: analysis.analysis, document: document)
            if document.redacted { taskIndex = Redactor.redact(taskIndex, context: .current()) }
            let (data, document) = try HTMLReporter.renderReport(document, taskIndex: taskIndex, options: HTMLReporter.Options(
                redact: global.redact ?? true, maxBytes: HTMLReporter.defaultMaxBytes, title: "xcblame report"))
            if data.count > HTMLReporter.defaultMaxBytes {
                writeStderr("warning: the html report is \(data.count) bytes, over the \(HTMLReporter.defaultMaxBytes)-byte "
                    + "cap even after truncation; written anyway")
            }
            if global.open, global.isCI, !global.quiet { writeStderr("note: --open ignored because CI=true") }
            let open = global.open && !global.isCI
            let explicit = global.resolvedFormat == .html ? global.output : nil
            let url = try HTMLOutput.write(data, to: explicit, kind: document.build.kind,
                                           reportsDir: stateURL.appendingPathComponent("reports"), open: open,
                                           browser: global.browser, isCI: global.isCI)
            if !global.quiet {
                print("wrote \(url.path) (html, \(data.count) bytes) · \(checksSummary(document))")
                if !open { print("open \"\(url.path)\"") }
            }
        } catch XcblameError.notImplemented(let what) {
            writeStderr("note: html report skipped (\(what))")
        }
    }

    private func checksSummary(_ document: ReportDocument) -> String {
        let statuses = document.validation.checks.map(\.status)
        return "checks \(statuses.filter { $0 == "pass" }.count) pass, \(statuses.filter { $0 == "warn" }.count) warn, "
            + "\(statuses.filter { $0 == "fail" }.count) fail"
    }

    var stateURL: URL {
        URL(fileURLWithPath: NSString(string: xcblameDir).expandingTildeInPath).standardizedFileURL
    }
}

// v0.4 lane B (begin): exit code of an unusable `--baseline`, set while the report is built and read by `run`.
extension BuildCommand {
    nonisolated(unsafe) static var baselineFailure: Int32?
}
// v0.4 lane B (end)

// v0.5 lane A (begin): `build --deep` (docs/SCHEMA-v0.5.md "deep and build --deep", DESIGN §5.8, §6.4, §7.5).
extension BuildCommand {
    /// The deep build of this run, read by `analyze`'s pipeline; nil without `--deep`.
    nonisolated(unsafe) static var deepRun: DeepRun?
    /// While `preparedRuns` runs: the xcodebuild arguments of every run (under `--deep` the ones `prepareDeep` made
    /// once: deep `-derivedDataPath`, wrapper), so neither the probe, the oracle check nor `--exact-files` repeats.
    nonisolated(unsafe) static var preparedArguments: [String]?
    /// Variables removed from the deep builds' environment (`XCODE_XCCONFIG_FILE` once the wrapper includes it); passed
    /// to `XcodebuildRunner.run(unsetEnvironment:)`, so xcblame's own environment never changes.
    nonisolated(unsafe) static var deepUnsetEnvironment: [String] = []
    /// `EnableBuildBacktraceRecording=YES` for every xcodebuild of a `--kind incremental|zero-change` / `--touch` run
    /// (set once by the outer `run`, so the copy `preparedRuns` makes for each measured build sees it too); nil
    /// otherwise. Passed to `XcodebuildRunner.run(environment:)`: xcblame's own environment never changes.
    nonisolated(unsafe) static var backtraceEnvironment: [String: String]?

    /// Task Backtraces are recorded for the runs that explain incremental work (v0.5 integration: the same mechanism
    /// as `why --backtraces`, settle and measured build alike), unless `--no-backtraces`.
    var recordsBacktraces: Bool {
        !noBacktraces && (touch != nil || kind == WhyProcedure.Kind.incremental.rawValue
            || kind == WhyProcedure.Kind.zeroChange.rawValue)
    }

    /// Probe, flags, deep DerivedData, wrapper xcconfig and oracle check; with `--exact-files` the first deep build and
    /// the rebuild plan. Returns the arguments of the build to report and sets `deepRun`. When the wrapper includes
    /// `XCODE_XCCONFIG_FILE`, every deep build runs without it (`deepUnsetEnvironment`).
    func prepareDeep() throws -> [String] {
        let scope = try deepScope.map(DeepScope.parse) ?? DeepScope.allCases
        let home = OracleCache.home()
        DeepDerivedData.prune(home: home, olderThanDays: DeepDerivedData.keepDays)
        let derivedData = try DeepDerivedData.prepare(for: Self.container(arguments: self.xcodebuildArguments), home: home)
        let statsDir = DeepDerivedData.statsDirectory(in: derivedData)
        let fake = ProcessInfo.processInfo.environment["XCBLAME_XCODEBUILD"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }

        let probe = try ToolchainProbe.run(probe: ToolchainProbe.defaultProbe, cacheDir: home.appendingPathComponent("deep"))
        var notes = probe.notes
        let flags = try DeepFlags.plan(scope: scope, exactFiles: exactFiles, probe: probe, statsDir: statsDir)
        func disabled(_ why: String) -> [String] {
            notes.append(why + "; the build ran without deep flags in its usual DerivedData")
            Self.deepRun = DeepRun(flags: flags, enabled: false, derivedData: derivedData, derivedDataBytes: nil,
                                   statsDir: statsDir, wrapper: nil, shadowed: [], exactFiles: nil, notes: notes)
            if !global.quiet { writeStderr("warning: --deep disabled: \(why)") }
            return self.xcodebuildArguments
        }
        guard !flags.lines.isEmpty else { return disabled("no timing flag is supported by this toolchain") }

        let environment = ProcessInfo.processInfo.environment
        let deepLines = flags.lines.map { $0 + " // xcblame --deep" }
        var plan = try WrapperXCConfig.plan(arguments: self.xcodebuildArguments, environment: environment,
                                            overlay: Self.overlayRun?.file, lines: deepLines, xcblameDir: stateURL)
        try WrapperXCConfig.write(plan)

        // Oracle check (§7.5): the build's own arguments without and with the wrapper.
        var shadowed: [String] = []
        let before = SettingsOracle.effective(withXCConfig: nil, arguments: self.xcodebuildArguments,
                                              derivedData: derivedData, executable: fake)
        let after = SettingsOracle.effective(withXCConfig: plan.url, arguments: plan.arguments, derivedData: derivedData,
                                             unsetEnvironment: plan.unsetEnvironment, executable: fake)
        if let beforeSettings = before.settings, let afterSettings = after.settings {
            var injected: [String: String] = [:]
            for line in flags.lines {
                let parts = line.components(separatedBy: " = $(inherited) ")
                if parts.count == 2 { injected[parts[0]] = parts[1] }
            }
            let check = try WrapperXCConfig.check(keys: injected.keys.sorted(), before: beforeSettings,
                                                  after: afterSettings, injected: injected)
            guard check.lost.isEmpty else {
                return disabled("the wrapper made a target lose a flag (MV-3): " + check.lost.prefix(5).joined(separator: "; "))
            }
            shadowed = check.shadowed
            notes += check.shadowed.map { "shadowed on \($0) (command line did not win, MV-3)" }
            notes.append("oracle check: \(afterSettings.targets.count) target(s) compared without and with the wrapper")
        } else {
            notes.append("oracle check skipped: " + [before.note, after.note].compactMap { $0 }.joined(separator: "; "))
        }
        if flags.injected.contains("-ftime-trace") {
            notes.append("ftime-trace covers C-family compiles only: explicit-module PCM builds and compilation-cache "
                + "hits write no trace (MV-7)")
        }

        Self.deepUnsetEnvironment = plan.unsetEnvironment
        let buildArguments = plan.arguments + ["-derivedDataPath", derivedData.path]
        var run = DeepRun(flags: flags, enabled: true, derivedData: derivedData, derivedDataBytes: nil, statsDir: statsDir,
                          wrapper: plan.url, shadowed: shadowed, exactFiles: nil, notes: notes)
        try Self.resetStats(statsDir)
        if !global.quiet { writeStderr("note: --deep: building in \(derivedData.path)") }

        if exactFiles {
            // The first deep build's batch rows pick the targets; the report is of the rebuild that follows.
            let first = try runXcodebuild(buildArguments, fake: fake)
            if let log = first.logURL, let loaded = try? loadModel(at: log, options: LoadOptions(quiet: true)) {
                var options = ReportPipeline.Options(topN: .max, generatedAt: Date(), inputPath: loaded.path)
                options.deep = run
                let files = (try? ReportPipeline.run(loaded.model, options: options))?.document.files ?? []
                let exact = try ExactFiles.plan(files: files)
                run.exactFiles = exact
                if !exact.targets.isEmpty {
                    plan = try WrapperXCConfig.plan(arguments: self.xcodebuildArguments, environment: environment,
                                                    overlay: Self.overlayRun?.file,
                                                    lines: deepLines + exact.lines.map { $0 + " // xcblame --exact-files" },
                                                    xcblameDir: stateURL)
                    try WrapperXCConfig.write(plan)
                    try Self.resetStats(statsDir)
                }
            } else {
                run.exactFiles = ExactFiles.Plan(targets: [], lines: [], note: "--exact-files: the first deep build left "
                    + "no readable log (exit \(first.exitCode)), so nothing was rebuilt; the build shape did not change")
            }
        }
        Self.deepRun = run
        return buildArguments
    }

    private func runXcodebuild(_ arguments: [String], fake: URL?) throws -> XcodebuildRunner.Result {
        if let fake {
            return try XcodebuildRunner.run(arguments: arguments, xcblameDir: stateURL, timeout: timeout,
                                            executable: fake, executablePrefix: [],
                                            environment: Self.backtraceEnvironment,
                                            unsetEnvironment: Self.deepUnsetEnvironment)
        }
        return try XcodebuildRunner.run(arguments: arguments, xcblameDir: stateURL, timeout: timeout,
                                        environment: Self.backtraceEnvironment,
                                        unsetEnvironment: Self.deepUnsetEnvironment)
    }

    /// The stats folder holds one build's jobs only.
    static func resetStats(_ statsDir: URL) throws {
        try? FileManager.default.removeItem(at: statsDir)
        try FileManager.default.createDirectory(at: statsDir, withIntermediateDirectories: true)
    }

    /// The value after `flag`.
    static func argument(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    /// `-workspace`, else `-project`, else the first workspace or project in the current folder, else the folder.
    static func container(arguments: [String]) -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if let given = Self.argument("-workspace", in: arguments)
            ?? Self.argument("-project", in: arguments) {
            return URL(fileURLWithPath: NSString(string: given).expandingTildeInPath, relativeTo: cwd).standardizedFileURL
        }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: cwd.path)) ?? []).sorted()
        if let found = names.first(where: { $0.hasSuffix(".xcworkspace") })
            ?? names.first(where: { $0.hasSuffix(".xcodeproj") }) {
            return cwd.appendingPathComponent(found)
        }
        return cwd.standardizedFileURL
    }
}
// v0.5 lane A (end)

// v0.5 lane B (begin): `--kind` / `--touch` preparation and `--runs` repetition (docs/SCHEMA-v0.5.md "build --runs").
extension BuildCommand {
    /// Each run: `WhyProcedure.prepare`, then this command once more without the three flags (build, analyze, history
    /// save, so run i is compared with run i-1). Only the last run's report is printed or written (and opened); earlier
    /// ones go to /dev/null. One line per run on stderr; the exit code is the worst xcodebuild code (or xcblame's, per
    /// --exit-code). `arguments` are the measured build's (under `--deep` the deep DerivedData and wrapper, with
    /// `deepUnsetEnvironment`): the preparation cleans, settles or touches the same DerivedData the run measures.
    func preparedRuns(arguments: [String]) throws {
        let count = runs ?? 1
        let prepareKind = kind.flatMap(WhyProcedure.Kind.init(rawValue:))
        let fake = ProcessInfo.processInfo.environment["XCBLAME_XCODEBUILD"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        var worst: Int32 = 0
        for index in 0..<count {
            do {
                try WhyProcedure.prepare(kind: prepareKind, touch: touch, arguments: arguments,
                                         xcblameDir: stateURL, timeout: timeout, executable: fake,
                                         unsetEnvironment: Self.deepUnsetEnvironment,
                                         backtraces: Self.backtraceEnvironment != nil)
            } catch let error as WhyProcedure.ProcedureError {
                writeStderr("error: run \(index + 1)/\(count): \(error)")
                throw ArgumentParser.ExitCode(XcblameExit.internalError.rawValue)
            }
            // The stats folder holds the measured build's jobs only, not the preparation's.
            if let deep = Self.deepRun, deep.enabled { try Self.resetStats(deep.statsDir) }
            var single = self
            single.kind = nil
            single.touch = nil
            single.runs = nil
            if index < count - 1 {
                single.global.output = "/dev/null"
                single.global.quiet = true
                single.global.open = false
                single.html = false
            }
            var code: Int32 = 0
            do { try single.run() } catch let exit as ArgumentParser.ExitCode { code = exit.rawValue }
            if !global.quiet { writeStderr("run \(index + 1)/\(count): \(prepareKind?.rawValue ?? "as is"), exit \(code)") }
            if code != 0, worst == 0 || code > worst { worst = code }
        }
        if worst != 0 { throw ArgumentParser.ExitCode(worst) }
    }
}
// v0.5 lane B (end)
