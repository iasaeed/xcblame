import ArgumentParser
import Foundation
import XcblameKit

/// `xcblame compare <a> <b>` (DESIGN §3.2; docs/SCHEMA-v0.4.md "CompareDocument"). Lane B.
struct CompareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "compare",
        abstract: "Diff two builds: wall, critical path, phases, targets, tasks, environment, settings.")

    @Argument(help: "The reference build (a): a saved xcblame JSON report, a build log (.xcactivitylog, .xcresult, DerivedData) or a history entry id.",
              completion: .file())
    var a: String
    @Argument(help: "The build under test (b), same forms as a.", completion: .file())
    var b: String
    @Option(help: "Exit 3 when b is slower than a by more than this percent (noise model of DESIGN §6.10).")
    var threshold: Double?
    @Option(name: .customLong("xcblame-dir"), help: "xcblame state folder (history, reports).", completion: .directory)
    var xcblameDir: String = ".xcblame"
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        if let threshold, threshold < 0 || !threshold.isFinite { throw ValidationError("--threshold must be 0 or greater") }
        if global.format.map({ ![.text, .json, .html, .markdown, .github, .agent].contains($0) }) == true {
            throw ValidationError("compare writes text, json, html, markdown, github or agent (--format \(global.format?.rawValue ?? ""))")
        }
    }

    func run() throws {
        // v0.4 lane B (begin): load both operands into `Compare.Input`s, run the diff, render text / json / html / markdown / github / agent
        // (`HTMLReporter.renderCompare`), exit 3 when `document.regression.failed`.
        let format = global.resolvedFormat
        let stateURL = URL(fileURLWithPath: NSString(string: xcblameDir).expandingTildeInPath).standardizedFileURL
        let operandA = try loadCompareOperand(a, stateDir: stateURL, verbose: global.verbose, quiet: global.quiet)
        let operandB = try loadCompareOperand(b, stateDir: stateURL, verbose: global.verbose, quiet: global.quiet)
        let options = Compare.Options(thresholdPct: threshold.map { $0 / 100 },
                                      top: global.top?.value ?? (format == .html ? .max : 25))
        var document = try Compare.run(a: operandA.input, b: operandB.input, options: options)
        document = try ReportPipeline.prepareForOutput(document, redact: global.resolvedRedact)
        if global.open, format != .html, !global.quiet { writeStderr("note: --open applies only to --format html") }

        switch format {
        case .json: try emit(try Compare.renderJSON(document), document: document, format: format)
        case .html:
            func index(_ operand: CompareOperand) -> TaskIndex? {
                operand.taskIndex.map { document.redacted ? Redactor.redact($0, context: .current()) : $0 }
            }
            let data = try HTMLReporter.renderCompare(
                document, taskIndexA: index(operandA), taskIndexB: index(operandB),
                options: HTMLReporter.Options(redact: global.resolvedRedact, maxBytes: HTMLReporter.defaultMaxBytes,
                                              title: "xcblame compare"))
            if data.count > HTMLReporter.defaultMaxBytes {
                writeStderr("warning: the html compare is \(data.count) bytes, over the \(HTMLReporter.defaultMaxBytes)-byte "
                    + "cap even after truncation; written anyway")
            }
            if global.open, global.isCI, !global.quiet { writeStderr("note: --open ignored because CI=true") }
            let open = global.open && !global.isCI
            let url = try HTMLOutput.write(data, to: global.output, kind: "compare",
                                           reportsDir: stateURL.appendingPathComponent("reports"), open: open,
                                           browser: global.browser, isCI: global.isCI)
            if !global.quiet {
                print("wrote \(url.path) (html, \(data.count) bytes) · \(summary(document))")
                if !open { print("open \"\(url.path)\"") }
            }
        case .markdown, .github, .agent:
            try emit(try renderCompareTextFormat(document, format: format, xcblameDir: stateURL), document: document,
                     format: format)
        default:
            try emit(Data(CompareTextReporter.render(document, colors: global.useColors).utf8), document: document,
                     format: format)
        }
        if document.regression.failed { throw ArgumentParser.ExitCode(XcblameExit.failIfSlower.rawValue) }
        // v0.4 lane B (end)
    }

    // v0.4 lane B (begin)
    private func summary(_ document: CompareDocument) -> String {
        let wall = document.regression.wall
        var text = "\(document.regression.verdict)"
        if let delta = wall.delta {
            text += " wall " + (delta < 0 ? "-" : "+") + TextReporter.duration(abs(delta))
            if let share = wall.deltaPct { text += String(format: " (%+.1f %%)", share * 100) }
        }
        if document.regression.failed { text += " · over the threshold" }
        return text
    }

    private func emit(_ rendered: Data, document: CompareDocument, format: OutputFormat) throws {
        guard let output = global.output else {
            FileHandle.standardOutput.write(rendered)
            return
        }
        let url = URL(fileURLWithPath: NSString(string: output).expandingTildeInPath)
        // Atomic writes need a temp file next to the target, which devices such as /dev/null do not allow.
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        try rendered.write(to: url, options: type == nil || type == .typeRegular ? .atomic : [])
        if !global.quiet { print("wrote \(url.path) (\(format.rawValue), \(rendered.count) bytes) · \(summary(document))") }
    }
    // v0.4 lane B (end)
}
