import ArgumentParser
import Foundation
import XcblameKit

/// `xcblame trend` (DESIGN §3.2; docs/SCHEMA-v0.4.md "TrendDocument"). Lane C.
struct TrendCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trend",
        abstract: "p50/p75/p95 of the local history by build kind, grouped by Xcode, branch, commit or machine.")

    @Option(help: "Only builds of this kind (clean, incremental, ...).") var kind: String?
    @Option(help: "Only builds of this scheme.") var scheme: String?
    @Option(help: "Only builds since this date (YYYY-MM-DD) or this long ago (30d).") var since: String?
    @Option(help: "Group by xcode, branch, commit or machine.") var by: String?
    @Option(name: .customLong("xcblame-dir"), help: "xcblame state folder (history, reports).", completion: .directory)
    var xcblameDir: String = ".xcblame"
    @OptionGroup var global: GlobalOptions

    func validate() throws {
        if let by, TrendDocument.By(rawValue: by) == nil {
            throw ValidationError("--by must be one of " + TrendDocument.By.allCases.map(\.rawValue).joined(separator: ", "))
        }
        if let since, Trend.parseSince(since) == nil {
            throw ValidationError("--since must be a date (YYYY-MM-DD) or a number of days such as 30d, not \(since)")
        }
        if global.format.map({ ![.text, .json, .html].contains($0) }) == true {
            throw ValidationError("trend writes text, json or html (--format \(global.format?.rawValue ?? ""))")
        }
    }

    func run() throws {
        // v0.4 lane C (begin): parse --since, `Trend.run`, render text / json / html (`HTMLReporter.renderTrend`).
        let state = URL(fileURLWithPath: NSString(string: xcblameDir).expandingTildeInPath).standardizedFileURL
        let now = Date()
        var document = try Trend.run(
            history: state.appendingPathComponent("history"),
            options: Trend.Options(kind: kind, scheme: scheme, since: since.flatMap { Trend.parseSince($0, now: now) },
                                   by: by.flatMap(TrendDocument.By.init(rawValue:))),
            now: now)
        document = try ReportPipeline.prepareForOutput(document, redact: global.resolvedRedact)
        if global.open, global.resolvedFormat != .html, !global.quiet { writeStderr("note: --open applies only to --format html") }

        switch global.resolvedFormat {
        case .json: try emit(try Trend.renderJSON(document))
        case .html:
            let html = try HTMLReporter.renderTrend(document, options: HTMLReporter.Options(
                redact: global.resolvedRedact, title: "xcblame trend"))
            if html.count > HTMLReporter.defaultMaxBytes {
                writeStderr("warning: the html trend is \(html.count) bytes, over the \(HTMLReporter.defaultMaxBytes)-byte cap; "
                    + "written anyway")
            }
            if global.open, global.isCI, !global.quiet { writeStderr("note: --open ignored because CI=true") }
            let open = global.open && !global.isCI
            let url = try HTMLOutput.write(html, to: global.output, kind: "trend",
                                           reportsDir: state.appendingPathComponent("reports"), open: open,
                                           browser: global.browser, isCI: global.isCI)
            _ = try? Retention.apply(stateDir: state)
            if !global.quiet {
                print("wrote \(url.path) (html, \(html.count) bytes) · \(document.entriesUsed) of \(document.entriesTotal) entries")
                if !open { print("open \"\(url.path)\"") }
            }
        default: try emit(Data(TrendTextReporter.render(document).utf8))
        }
        // v0.4 lane C (end)
    }

    /// stdout, or `-o` with a one-line summary on stdout.
    private func emit(_ rendered: Data) throws {
        guard let output = global.output else {
            FileHandle.standardOutput.write(rendered)
            return
        }
        let url = URL(fileURLWithPath: NSString(string: output).expandingTildeInPath)
        // Atomic writes need a temp file next to the target, which devices such as /dev/null do not allow.
        let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
        try rendered.write(to: url, options: type == nil || type == .typeRegular ? .atomic : [])
        if !global.quiet { print("wrote \(url.path) (\(global.resolvedFormat.rawValue), \(rendered.count) bytes)") }
    }
}
