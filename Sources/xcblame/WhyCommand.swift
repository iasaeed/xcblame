import ArgumentParser
import Foundation
import XcblameKit

/// `xcblame why [--touch <file>] [--show-incremental] [--backtraces] [-- <xcodebuild args>]` (DESIGN §3.2, §6.6;
/// docs/SCHEMA-v0.5.md "why"). Lane B.
///
/// With xcodebuild arguments: settle build, then a zero-change build (or `--touch <file>`, then a build), and every
/// executed task of the measured build is attributed against the settle build's index. Without them: the latest log
/// (or `--log`) is explained against the previous build of the same key in history.
struct WhyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "why",
        abstract: "Explain why tasks ran in a non-clean build: one primary cause per executed task.")

    @Option(help: "Touch this file between the settle build and the measured build. Changes only its timestamp, so Swift recompiles just that file and dependents do not rebuild; to see what one real edit rebuilds, add a line to the file instead.",
            completion: .file())
    var touch: String?
    @Flag(name: .customLong("show-incremental"), help: "Pass -driver-show-incremental and use its remarks as evidence.")
    var showIncremental = false
    @Flag(help: "Record Task Backtraces on every build of the procedure (EnableBuildBacktraceRecording=YES; the scheme is never edited).")
    var backtraces = false
    @Option(help: "Without xcodebuild arguments: the log to explain (anything analyze reads; default: the latest log of the project in the current directory).",
            completion: .file())
    var log: String?
    @Option(help: "Stop each xcodebuild after this many seconds (the procedure then aborts, exit 1).") var timeout: Double?
    @Option(name: .customLong("xcblame-dir"), help: "xcblame state folder (history, snapshots, reports).",
            completion: .directory)
    var xcblameDir: String = ".xcblame"
    @OptionGroup var global: GlobalOptions
    @Argument(parsing: .postTerminator, help: "Arguments passed to xcodebuild, after --.")
    var xcodebuildArguments: [String] = []

    func validate() throws {
        if global.format.map({ ![.text, .json, .html].contains($0) }) == true {
            throw ValidationError("why writes text, json or html (--format \(global.format?.rawValue ?? ""))")
        }
        if let timeout, timeout <= 0 { throw ValidationError("--timeout must be greater than 0") }
        if xcodebuildArguments.isEmpty {
            if touch != nil { throw ValidationError("--touch needs xcodebuild arguments after --") }
            if showIncremental { throw ValidationError("--show-incremental needs xcodebuild arguments after --") }
            if backtraces { throw ValidationError("--backtraces needs xcodebuild arguments after --") }
        } else if log != nil {
            throw ValidationError("give either --log or xcodebuild arguments after --, not both")
        }
    }

    func run() throws {
        // v0.5 lane B (begin): `WhyProcedure.run` (with arguments) or the latest log against history, then
        // `CauseEngine.attribute`, DYN-002, history (with the capture), and text / json / html (`renderWhy`).
        let format = global.resolvedFormat
        let history = stateURL.appendingPathComponent("history")
        let topN = global.resolvedTop
        let explained: Explained
        if xcodebuildArguments.isEmpty {
            let url = URL(fileURLWithPath: NSString(string: log ?? ".").expandingTildeInPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { throw XcblameError.logNotFound(url.path) }
            let loaded = try loadModel(at: url, options: LoadOptions(verbose: global.verbose, quiet: global.quiet))
            if let note = loaded.note, !global.quiet { writeStderr("note: \(note)") }
            let made = try pipeline(loaded.model, logURL: URL(fileURLWithPath: loaded.path), path: loaded.path,
                                    context: BuildContext.from(manifestScheme: loaded.scheme), processWall: nil, topN: topN)
            var document = CauseEngine.attach(to: made.document, model: loaded.model, historyDir: history, project: nil)
            document.notes.append("findings: why runs no rules")
            explained = Explained(document: document, model: loaded.model, analysis: made.analysis)
        } else {
            explained = try procedure(history: history, topN: topN)
        }

        var document = try ReportPipeline.prepareForOutput(explained.document, redact: global.resolvedRedact)
        switch format {
        case .json: try emit(try JSONReporter.render(document), document: document, format: format)
        case .html:
            var taskIndex = TaskIndex.make(model: explained.model, analysis: explained.analysis, document: document)
            if document.redacted { taskIndex = Redactor.redact(taskIndex, context: .current()) }
            let rendered = try HTMLReporter.renderWhy(document, taskIndex: taskIndex, options: HTMLReporter.Options(
                redact: global.resolvedRedact, maxBytes: HTMLReporter.defaultMaxBytes, title: "xcblame why"))
            document = rendered.document
            try emitHTML(rendered.data, document: document)
        default:
            try emit(Data(TextReporter.renderWhy(document, colors: global.useColors).utf8), document: document, format: format)
        }
        if document.validation.checks.contains(where: { $0.status == "fail" }) {
            throw ArgumentParser.ExitCode(XcblameExit.internalError.rawValue)
        }
        // v0.5 lane B (end)
    }
}

// v0.5 lane B (begin)
extension WhyCommand {
    struct Explained {
        var document: ReportDocument
        var model: BuildModel
        var analysis: Analysis
    }

    /// The procedure: builds, the settle build saved with its capture, the measured build attributed against it and
    /// saved, DYN-002. A failed or timed-out build, or a build without a log, is exit 1 with the role named.
    private func procedure(history: URL, topN: Int) throws -> Explained {
        let fake = ProcessInfo.processInfo.environment["XCBLAME_XCODEBUILD"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let options = WhyProcedure.Options(arguments: xcodebuildArguments, xcblameDir: stateURL, touch: touch,
                                           showIncremental: showIncremental, backtraces: backtraces, timeout: timeout,
                                           executable: fake)
        let result: WhyProcedure.Result
        do {
            result = try WhyProcedure.run(options)
        } catch let error as WhyProcedure.ProcedureError {
            writeStderr("error: \(error)")
            throw ArgumentParser.ExitCode(XcblameExit.internalError.rawValue)
        } catch let error as XcodebuildRunner.RunError {
            writeStderr("error: \(error)")
            throw ArgumentParser.ExitCode(XcblameExit.internalError.rawValue)
        }
        if !global.quiet { for build in result.builds { for note in build.notes { writeStderr("note: \(note)") } } }
        guard let settle = result.step("settle"), let measure = result.step("measure") else {
            throw XcblameError.noBuildLog("why: the procedure produced no measured build")
        }
        let context = BuildContext.from(xcodebuildArguments: xcodebuildArguments)
        var procedure = result.procedure

        // The settle build is the measured build's previous index: saved first, with its hashes.
        let settled = try pipeline(settle.model, logURL: settle.build.logURL, path: settle.build.logURL?.path,
                                   context: context, processWall: settle.build.wall, topN: topN)
        let settleDocument = CauseEngine.attach(to: settled.document, model: settle.model, historyDir: history, project: nil)
        procedure.builds[0].historyId = saveHistory(settleDocument, model: settle.model, capture: settle.capture,
                                                    history: history)

        let measured = try pipeline(measure.model, logURL: measure.build.logURL, path: measure.build.logURL?.path,
                                    context: context, processWall: measure.build.wall, topN: topN)
        var document = CauseEngine.attach(to: measured.document, model: measure.model, historyDir: history, project: nil,
                                          capture: measure.capture)
        document = DYN002.applying(to: document, result: result)
        document.notes.append("findings: why runs no rules" + (result.dyn002 ? " (DYN-002 comes from the procedure)" : ""))
        if var incremental = document.incremental {
            incremental.notes += result.notes
            incremental.procedure = procedure
            document = document.applying(incremental: incremental)
        } else {
            document.notes += result.notes
        }
        let measureId = saveHistory(document, model: measure.model, capture: measure.capture, history: history)
        if var incremental = document.incremental, procedure.builds.count > 1 {
            incremental.procedure?.builds[1].historyId = measureId
            document = document.applying(incremental: incremental)
        }
        return Explained(document: document, model: measure.model, analysis: measured.analysis)
    }

    /// The `build` pipeline over one log: build description from the snapshot, environment, build context.
    private func pipeline(_ model: BuildModel, logURL: URL?, path: String?, context: BuildContext, processWall: Double?,
                          topN: Int) throws -> ReportPipeline.Result {
        let html = global.resolvedFormat == .html
        let snapshot = EnvSnapshot.capture()
        let description = BuildDescriptionLocator.find(model: model, logURL: logURL, explicit: nil,
                                                       snapshotsDir: stateURL.appendingPathComponent("snapshots"))
        var options = ReportPipeline.Options(
            topN: topN, budgetBytes: html ? HTMLReporter.defaultMaxBytes : Validator.defaultBudgetBytes,
            generatedAt: Date(), inputPath: path, environment: snapshot, buildDescription: description,
            physicalCores: snapshot.performanceCores.map { $0 + (snapshot.efficiencyCores ?? 0) }, processWall: processWall)
        options.checksSize = !html
        let full = context.filling(from: description.map { BuildContext.from(buildRequest: $0.buildRequest.raw) } ?? BuildContext())
        options.buildContext = full
        var made = try ReportPipeline.run(model, options: options)
        if let note = full.missingNote(source: "the xcodebuild arguments, the log or its build description") {
            made.document.build.notes.append(note)
        }
        return made
    }

    /// History is best effort: a failed write is a warning and the run goes on.
    private func saveHistory(_ document: ReportDocument, model: BuildModel, capture: OutputHashes.Capture?,
                             history: URL) -> String? {
        do {
            let url = try capture.map { try History.save(document: document, model: model, directory: history, capture: $0) }
                ?? History.save(document: document, model: model, directory: history)
            return String(url.lastPathComponent.dropLast(".json.gz".count))
        } catch {
            writeStderr("warning: build not recorded in history: \(error)")
            return nil
        }
    }

    private var stateURL: URL {
        URL(fileURLWithPath: NSString(string: xcblameDir).expandingTildeInPath).standardizedFileURL
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
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        try rendered.write(to: url, options: type == nil || type == .typeRegular ? .atomic : [])
        if !global.quiet {
            print("wrote \(url.path) (\(format.rawValue), \(rendered.count) bytes) · \(checksSummary(document))")
        }
    }

    /// HTML never goes to stdout: `-o`, else `<xcblame-dir>/reports/` with file kind `why`.
    private func emitHTML(_ html: Data, document: ReportDocument) throws {
        if global.open, global.isCI, !global.quiet { writeStderr("note: --open ignored because CI=true") }
        let open = global.open && !global.isCI
        let url = try HTMLOutput.write(html, to: global.output, kind: "why",
                                       reportsDir: stateURL.appendingPathComponent("reports"), open: open,
                                       browser: global.browser, isCI: global.isCI)
        _ = try? Retention.apply(stateDir: stateURL)
        if !global.quiet {
            print("wrote \(url.path) (html, \(html.count) bytes) · \(checksSummary(document))")
            if !open { print("open \"\(url.path)\"") }
        }
    }
}
// v0.5 lane B (end)
