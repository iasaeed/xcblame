import ArgumentParser
import Foundation
import XcblameKit

struct AnalyzeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "analyze",
        abstract: "Analyze an existing build: timing, rollups by target and kind, top tasks, self-validation.")

    @Argument(help: "An .xcactivitylog, .xcresult, DerivedData, Logs/Build or project folder, a saved xcblame JSON report, or a history entry id or unique prefix (xcblame history list; both re-render only) (default: current directory).",
              completion: .file())
    var path: String?
    @Option(name: .customLong("model-json"),
            help: "Analyze a JSON dump of a BuildModel instead of reading a log (testing and tooling).",
            completion: .file())
    var modelJSON: String?
    @Option(help: "Pick the n-th build log of a DerivedData or Logs/Build folder (0 = newest) instead of the newest one with an executed build task.")
    var index: Int?
    @Flag(help: "List the build logs of a DerivedData or Logs/Build folder and exit.")
    var list = false
    @Flag(inversion: .prefixedNo, help: "Include a snapshot of this machine in the report (it is not what built the log).")
    var env = true
    @Option(name: .customLong("max-report-bytes"),
            help: "Budget for the report (default 2000000 json, 8000000 html including the template, 65536 markdown and github, 8192 agent, none for junit).")
    var maxReportBytes: Int?
    @Option(name: .customLong("build-description"),
            help: "Read the build description (task DAG) from this .xcbuilddata or snapshot folder.",
            completion: .directory)
    var buildDescription: String?
    @Flag(name: .customLong("no-build-description"), help: "Do not look for a build description; infer the critical path.")
    var noBuildDescription = false
    @Option(name: .customLong("xcblame-dir"), help: "xcblame state folder (snapshots, history, reports).",
            completion: .directory)
    var xcblameDir: String = ".xcblame"
    @Flag(name: .customLong("no-history"), help: "Do not record this build in the local history.")
    var noHistory = false
    @Option(help: "Project to run the rules against (default: the one that built the log, from DerivedData).",
            completion: .file(extensions: ["xcodeproj"]))
    var project: String?
    @Option(help: "Workspace to run the rules against (default: the one that built the log, from DerivedData).",
            completion: .file(extensions: ["xcworkspace"]))
    var workspace: String?
    @Flag(name: .customLong("no-rules"), help: "Do not run the rules (no findings, no project read).")
    var noRules = false
    @Flag(help: "Rules: resolve settings from the project files only, without xcodebuild -showBuildSettings.")
    var offline = false
    @OptionGroup var regression: RegressionFlags
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        if path != nil, modelJSON != nil { throw ValidationError("give either a path or --model-json, not both") }
        if let maxReportBytes, maxReportBytes < 1 { throw ValidationError("--max-report-bytes must be at least 1") }
        if let index, index < 0 { throw ValidationError("--index must be 0 or greater") }
        if list, modelJSON != nil { throw ValidationError("--list needs a folder, not --model-json") }
        if list, index != nil { throw ValidationError("give either --list or --index, not both") }
        if buildDescription != nil, noBuildDescription {
            throw ValidationError("give either --build-description or --no-build-description, not both")
        }
        if project != nil, workspace != nil { throw ValidationError("give either --project or --workspace, not both") }
    }

    func run() throws {
        if list {
            print(try listCandidates(at: resolvedURL()))
            return
        }
        let format = global.resolvedFormat
        let budget = maxReportBytes ?? (format == .html ? HTMLReporter.defaultMaxBytes : Validator.defaultBudgetBytes)
        var document: ReportDocument
        var analyzed: (model: BuildModel, analysis: Analysis)?
        switch try loadInput() {
        case let .report(saved, _):
            document = saved
        case let .model(loaded):
            // A real log, not a --model-json dump: only these get a build description and a history entry.
            let logURL = modelJSON == nil ? URL(fileURLWithPath: loaded.path) : nil
            let snapshot = env ? EnvSnapshot.capture() : nil
            var options = ReportPipeline.Options(
                topN: global.resolvedTop, budgetBytes: budget, generatedAt: Date(), inputPath: loaded.path,
                environment: snapshot,
                buildDescription: locateBuildDescription(model: loaded.model, logURL: logURL),
                physicalCores: snapshot.flatMap { s in s.performanceCores.map { $0 + (s.efficiencyCores ?? 0) } })
            options.checksSize = format.measuresJSONSize
            // v0.5 integration: module-graph edges from the .xcodeproj (--project, else the log's) when no build
            // description has a target graph.
            if logURL != nil {
                options.project = ReportPipeline.moduleGraphProject(
                    explicit: project.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath).standardizedFileURL },
                    logURL: logURL, description: options.buildDescription)
            }
            // v0.4 lane C (begin): the scheme comes from the log manifest, configuration and destination from the
            // build request of the matched build description (a log names neither); what stays unknown is a note.
            let context = BuildContext.from(manifestScheme: loaded.scheme).filling(
                from: options.buildDescription.map { BuildContext.from(buildRequest: $0.buildRequest.raw) } ?? BuildContext())
            options.buildContext = context
            // v0.4 lane C (end)
            let result = try ReportPipeline.run(loaded.model, options: options)
            if global.verbose { printVerbose(model: loaded.model, result: result) }
            document = result.document
            // v0.4 lane C (begin)
            if let note = context.missingNote(source: "the log or its build description") { document.build.notes.append(note) }
            // v0.4 lane C (end)
            if noRules {
                document.notes.append("findings: not produced (--no-rules)")
            } else {
                applyRules(to: &document, analysis: result.analysis, logURL: logURL, model: loaded.model)
                // V13 after the merge: the findings are part of the report whose size it checks.
                if options.checksSize { document = try document.remeasuringSize(budgetBytes: budget) }
            }
            // v0.5 lane B (begin): incremental causes against the previous history entry, before this log is saved.
            if logURL != nil {
                document = CauseEngine.attach(to: document, model: loaded.model,
                                              historyDir: stateURL.appendingPathComponent("history"), project: nil)
                // V13 again: `incremental` is part of the report whose size it checks.
                if options.checksSize { document = try document.remeasuringSize(budgetBytes: budget) }
            }
            // v0.5 lane B (end)
            // v0.5 lane C (begin): fixed costs re-based on history frequency and builds per day.
            document = FixedCosts.applyingHistory(to: document, historyDir: stateURL.appendingPathComponent("history"),
                                                  configURL: stateURL.appendingPathComponent("config.json"))
            // v0.5 lane C (end)
            if !noHistory, logURL != nil { saveHistory(document, model: loaded.model) }
            analyzed = (loaded.model, result.analysis)
        }
        // v0.4 lane B (begin): regression against --baseline, before redaction and rendering.
        if let baselineURL = regression.baselineURL {
            let baseline = try Baseline.load(from: baselineURL)
            let rows = baseline.tasks == nil ? nil : analyzed.map { Compare.taskRows(document: document, model: $0.model) }
            document.regression = try Regression.evaluate(current: [document], baseline: baseline,
                                                          baselineRef: regression.baseline, currentTaskRows: rows,
                                                          options: regression.options)
            regression.warnIfNotComparable(document.regression)
        }
        // v0.4 lane B (end)
        document = try ReportPipeline.prepareForOutput(relativizedForTextFormat(document, format: format),
                                                       redact: global.resolvedRedact)
        if global.open, format != .html, !global.quiet { writeStderr("note: --open applies only to --format html") }

        switch format {
        case .json: try emit(try JSONReporter.render(document), document: document, format: format)
        case .text:
            try emit(Data(TextReporter.render(document, colors: global.useColors).utf8), document: document, format: format)
        case .markdown, .github, .junit, .agent:
            try emit(try renderTextFormat(document, format: format, maxReportBytes: maxReportBytes, xcblameDir: stateURL),
                     document: document, format: format)
        case .html:
            let taskIndex = analyzed.map { TaskIndex.make(model: $0.model, analysis: $0.analysis, document: document) }
                .map { document.redacted ? Redactor.redact($0, context: .current()) : $0 }
            let rendered = try HTMLReporter.renderReport(document, taskIndex: taskIndex, options: HTMLReporter.Options(
                redact: global.resolvedRedact, maxBytes: budget, title: "xcblame report"))
            document = rendered.document
            warnAboutSize(rendered.data, document: document, cap: budget)
            try emitHTML(rendered.data, document: document)
        }
        if document.validation.checks.contains(where: { $0.status == "fail" }) {
            throw ArgumentParser.ExitCode(XcblameExit.internalError.rawValue)
        }
        // v0.4 lane B (begin): exit 3 when the regression threshold was exceeded.
        if document.regression?.failed == true { throw ArgumentParser.ExitCode(XcblameExit.failIfSlower.rawValue) }
        // v0.4 lane B (end)
    }

    // MARK: - Steps

    private func loadInput() throws -> LoadedInput {
        let fileManager = FileManager.default
        if let modelJSON {
            let url = URL(fileURLWithPath: NSString(string: modelJSON).expandingTildeInPath)
            guard fileManager.fileExists(atPath: url.path) else { throw XcblameError.logNotFound(url.path) }
            return .model(LoadedModel(model: try loadModelJSON(at: url), path: url.path))
        }
        let url = resolvedURL()
        guard fileManager.fileExists(atPath: url.path) else {
            if let path, let entry = try historyReport(path) { return entry }
            throw XcblameError.logNotFound(url.path)
        }
        let input = try loadModelOrReport(at: url, options: LoadOptions(verbose: global.verbose, quiet: global.quiet,
                                                                        index: index))
        if case let .model(loaded) = input, let note = loaded.note, !global.quiet { writeStderr("note: \(note)") }
        return input
    }

    /// `analyze <history id>`: an entry of `<xcblame-dir>/history` (an id or a unique prefix) is re-rendered like a saved
    /// JSON report. Nil when no entry matches, so the caller reports the missing path.
    private func historyReport(_ id: String) throws -> LoadedInput? {
        do {
            let shown = try History.show(id: id, directory: stateURL.appendingPathComponent("history"))
            return .report(shown.document, path: shown.item.id)
        } catch let error as History.HistoryError {
            switch error {
            case .notFound: return nil
            case .ambiguous: throw XcblameError.usage("\(error)")
            case .unreadable: throw XcblameError.readerFailure("\(error)")
            }
        }
    }

    private func resolvedURL() -> URL {
        URL(fileURLWithPath: NSString(string: path ?? ".").expandingTildeInPath).standardizedFileURL
    }

    private var stateURL: URL {
        URL(fileURLWithPath: NSString(string: xcblameDir).expandingTildeInPath).standardizedFileURL
    }

    private func locateBuildDescription(model: BuildModel, logURL: URL?) -> BuildDescription? {
        if noBuildDescription { return nil }
        let explicit = buildDescription.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        return BuildDescriptionLocator.find(model: model, logURL: logURL, explicit: explicit,
                                            snapshotsDir: stateURL.appendingPathComponent("snapshots"))
    }

    /// v0.3 rules over the analyzed build and, when one is found, its project (docs/SCHEMA-v0.3.md). Best effort:
    /// a failure only adds a note; `notImplemented` stays silent until the lanes land.
    private func applyRules(to document: inout ReportDocument, analysis: Analysis, logURL: URL?, model build: BuildModel) {
        var model: ProjectModel?
        var settings: [String: EffectiveSettings] = [:]
        var configurations: [String] = []
        do {
            if let container = try rulesContainer(logURL: logURL) {
                let loaded = try ProjectModel.load(container: container, scheme: nil)
                model = loaded
                // The log does not name its configuration; the project's default is what xcodebuild builds.
                if let configuration = loaded.projects.first?.defaultConfiguration ?? loaded.configurationNames.first {
                    configurations = [configuration]
                    // Riding along with a log analysis: 5 s per configuration, existing checkouts only, never a clone.
                    settings = SettingsOracle.effectiveAll(project: loaded, configurations: configurations, scheme: nil,
                                                           offline: offline,
                                                           cacheDir: stateURL.appendingPathComponent("cache/settings"),
                                                           timeout: SettingsOracle.analyzeTimeout, resolvePackages: false,
                                                           totalTimeout: SettingsOracle.analyzeTimeout)
                    if FileManager.default.fileExists(atPath: stateURL.path) { ensureStateIgnore(in: stateURL) }
                }
            }
        } catch XcblameError.notImplemented {
            // v0.3 lanes A/B: silent until the readers land.
        } catch {
            document.notes.append("rules: project not read (\(error)); rules ran on the build only")
        }
        let context = RuleContext(project: model, settings: settings,
                                  provenance: RuleContext.oracleProvenance(model, settings: settings),
                                  env: document.environment, analysis: analysis, document: document,
                                  xcode: document.xcode.value, isCI: global.isCI, offline: offline,
                                  tasks: RuleContext.measuredTasks(build))
        var rules = RuleEngine.run(context)
        // ENV rules read the machine running xcblame, which need not be the one that built the log.
        rules.findings = rules.findings.map { finding in
            guard finding.ruleId.hasPrefix("ENV-") else { return finding }
            var labelled = finding
            labelled.title += " (this machine, not necessarily the one that built the log)"
            return labelled
        }
        document.merge(rules: rules, project: model, settings: settings,
                       configurations: configurations, offline: offline)
        document.markVerified(FixPlanner.verifyLabels(xcblameDir: stateURL))
    }

    /// `--project`/`--workspace`, else the workspace that built the log (DerivedData `info.plist`), else the
    /// container of the project folder that was analyzed. Nil when none is known.
    private func rulesContainer(logURL: URL?) throws -> URL? {
        if let explicit = project ?? workspace {
            let url = URL(fileURLWithPath: NSString(string: explicit).expandingTildeInPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XcblameError.projectNotFound("\(url.path) does not exist")
            }
            return url
        }
        if let logURL, let found = ProjectLocator.find(forBuildLog: logURL, derivedData: nil) { return found }
        guard logURL != nil else { return nil }
        return DerivedDataLocator.projectContainers(in: resolvedURL()).first
    }

    /// History is best effort: it never fails `analyze`.
    private func saveHistory(_ document: ReportDocument, model: BuildModel) {
        do {
            _ = try History.save(document: document, model: model, directory: stateURL.appendingPathComponent("history"))
        } catch XcblameError.notImplemented {
            // Lane B: silent until history lands.
        } catch {
            writeStderr("warning: build not recorded in history: \(error)")
        }
    }

    /// §8.2.3: size never fails the command; an html page over the cap is written anyway with this warning.
    private func warnAboutSize(_ html: Data, document: ReportDocument, cap: Int) {
        if html.count > cap {
            writeStderr("warning: the html report is \(html.count) bytes, over --max-report-bytes \(cap) even after "
                + "truncation; written anyway")
        } else if !document.truncation.steps.isEmpty, !global.quiet {
            writeStderr("note: the html report was truncated to fit \(cap) bytes ("
                + document.truncation.steps.map(\.step).joined(separator: ", ") + ")")
        }
    }

    private func checksSummary(_ document: ReportDocument) -> String {
        let statuses = document.validation.checks.map(\.status)
        return "checks \(statuses.filter { $0 == "pass" }.count) pass, \(statuses.filter { $0 == "warn" }.count) warn, "
            + "\(statuses.filter { $0 == "fail" }.count) fail"
    }

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

    /// HTML never goes to stdout: it is written to `-o` or `<xcblame-dir>/reports/`.
    private func emitHTML(_ html: Data, document: ReportDocument) throws {
        if global.open, global.isCI, !global.quiet { writeStderr("note: --open ignored because CI=true") }
        let open = global.open && !global.isCI
        let url = try HTMLOutput.write(html, to: global.output, kind: document.build.kind,
                                       reportsDir: stateURL.appendingPathComponent("reports"), open: open,
                                       browser: global.browser, isCI: global.isCI)
        // v0.4 lane C (begin): reports pile up one per run; best effort, never fails the command.
        _ = try? Retention.apply(stateDir: stateURL)
        // v0.4 lane C (end)
        if !global.quiet {
            print("wrote \(url.path) (html, \(html.count) bytes) · \(checksSummary(document))")
            if !open { print("open \"\(url.path)\"") }
        }
    }

    private func printVerbose(model: BuildModel, result: ReportPipeline.Result) {
        writeStderr("verbose: \(model.tasks.count) tasks, \(model.targets.count) targets, "
            + "\(model.decodeWarnings.count) decode warnings, \(result.analysis.reusedCount) reused")
        for warning in model.decodeWarnings { writeStderr("verbose: decode warning [\(warning.kind.rawValue)] \(warning.detail)") }
    }
}
