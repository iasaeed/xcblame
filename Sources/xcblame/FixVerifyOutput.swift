import Foundation
import XcblameKit

// v0.6 lane C: the output step of `fix` and `verify` in their five formats (text, json, html, markdown, agent), so
// lanes A and B end `run` with one call. Redaction follows `--redact` / the format default; html goes to `-o` or
// `<xcblame-dir>/reports/<time>-fix.html` / `-verify.html` and opens with `--open` (never on CI).

/// Prints or writes the fix plan. `wrote`: a write flag ran (the text then lists the writes instead of "nothing in the
/// project changed").
func emitFixPlan(_ plan: FixPlanDocument, global: GlobalOptions, stateDir: URL, wrote: Bool = false) throws {
    let document = try ReportPipeline.prepareForOutput(plan, redact: global.resolvedRedact)
    let format = global.resolvedFormat
    switch format {
    case .json: try emitFixVerify(try JSONReporter.render(document), global: global)
    case .html:
        let html = try HTMLReporter.renderFixPlan(document, options: .init(redact: global.resolvedRedact, title: "xcblame fix plan"))
        try writeFixVerifyHTML(html, kind: "fix", global: global, stateDir: stateDir,
                               summary: "plan \(document.id), \(document.steps.count) step(s)")
    case .markdown, .agent:
        let options = FormatOptions(maxBytes: format.budgetFormat.defaultMaxBytes, reproduceCommand: "xcblame fix --format json",
                                    workspaceRoot: formatWorkspaceRoot())
        let body = format == .agent ? try AgentReporter.render(document, options: options)
            : try MarkdownReporter.render(document, options: options)
        try emitFixVerify(Data(body.utf8), global: global)
    default:
        try emitFixVerify(Data(TextReporter.renderFixPlan(document, colors: global.useColors, wrote: wrote).utf8), global: global)
    }
}

/// Prints or writes the verify document.
func emitVerify(_ verify: VerifyDocument, global: GlobalOptions, stateDir: URL) throws {
    let document = try ReportPipeline.prepareForOutput(verify, redact: global.resolvedRedact)
    let format = global.resolvedFormat
    switch format {
    case .json: try emitFixVerify(try JSONReporter.render(document), global: global)
    case .html:
        let html = try HTMLReporter.renderVerify(document, options: .init(redact: global.resolvedRedact, title: "xcblame verify"))
        try writeFixVerifyHTML(html, kind: "verify", global: global, stateDir: stateDir,
                               summary: "\(document.results.count) unit(s), " + (document.abort == nil ? "finished" : "aborted"))
    case .markdown, .agent:
        let options = FormatOptions(maxBytes: format.budgetFormat.defaultMaxBytes,
                                    reproduceCommand: "xcblame verify --plan \(document.planId) --format json",
                                    workspaceRoot: formatWorkspaceRoot())
        let body = format == .agent ? try AgentReporter.render(document, options: options)
            : try MarkdownReporter.render(document, options: options)
        try emitFixVerify(Data(body.utf8), global: global)
    default:
        try emitFixVerify(Data(TextReporter.renderVerify(document, colors: global.useColors).utf8), global: global)
    }
}

private func writeFixVerifyHTML(_ html: Data, kind: String, global: GlobalOptions, stateDir: URL, summary: String) throws {
    if global.open, global.isCI, !global.quiet { writeStderr("note: --open ignored because CI=true") }
    let open = global.open && !global.isCI
    let url = try HTMLOutput.write(html, to: global.output, kind: kind, reportsDir: stateDir.appendingPathComponent("reports"),
                                   open: open, browser: global.browser, isCI: global.isCI)
    _ = try? Retention.apply(stateDir: stateDir)
    if !global.quiet {
        print("wrote \(url.path) (html, \(html.count) bytes) · \(summary)")
        if !open { print("open \"\(url.path)\"") }
    }
}

/// stdout, or `-o` with a one-line summary on stdout.
private func emitFixVerify(_ rendered: Data, global: GlobalOptions) throws {
    if global.open, !global.quiet { writeStderr("note: --open applies only to --format html") }
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
