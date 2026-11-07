import Foundation
import XcblameKit

/// The folder the repo-relative paths of the text formats are taken from: `$GITHUB_WORKSPACE`, else the git work tree of
/// the working directory.
func formatWorkspaceRoot() -> String? {
    ProcessInfo.processInfo.environment["GITHUB_WORKSPACE"].flatMap { $0.isEmpty ? nil : $0 }
        ?? Redactor.Context.current().repoRoot
}

/// For the four text formats, the document with its paths made repo-relative; to be called before redaction (see
/// `ReportDocument.repoRelativized`). Other formats pass through.
func relativizedForTextFormat(_ document: ReportDocument, format: OutputFormat) -> ReportDocument {
    [.markdown, .github, .junit, .agent].contains(format) ? document.repoRelativized(workspaceRoot: formatWorkspaceRoot()) : document
}

/// Renders a document in one of the four v0.4 text formats and performs the `github` side effects (annotations on
/// stderr, body appended to `$GITHUB_STEP_SUMMARY`). Shared by `analyze` and `build`; the reporters themselves are pure
/// (Lane A, `Sources/XcblameKit/Reporters/Formats/`).
func renderTextFormat(_ document: ReportDocument, format: OutputFormat, maxReportBytes: Int?, xcblameDir: URL,
                      reproduceCommand: String? = nil) throws -> Data {
    let cap = maxReportBytes ?? format.budgetFormat.defaultMaxBytes
    let workspace = formatWorkspaceRoot()
    let options = FormatOptions(maxBytes: cap, configURL: xcblameDir.appendingPathComponent("config.json"),
                                reproduceCommand: reproduceCommand, workspaceRoot: workspace)
    let output = try ReportPipeline.renderFormat(document, format: format.budgetFormat, options: options)
    var body = output.body
    if !body.hasSuffix("\n") { body += "\n" }
    if format == .github {
        for line in output.annotations { writeStderr(line) }
        appendStepSummary(body)
    }
    return Data(body.utf8)
}

/// `compare --format markdown|github|agent`. `markdown` is the compare comment; `github` is the same body (compare has
/// no annotations: a diff of two builds has no file and line) and also goes to `$GITHUB_STEP_SUMMARY`; `agent` is the
/// same text without the sticky-comment marker, held to the agent budget (8 KB). `junit` is not offered for compare.
func renderCompareTextFormat(_ document: CompareDocument, format: OutputFormat, xcblameDir: URL,
                             reproduceCommand: String? = nil) throws -> Data {
    let workspace = formatWorkspaceRoot()
    let options = FormatOptions(maxBytes: format.budgetFormat.defaultMaxBytes,
                                configURL: xcblameDir.appendingPathComponent("config.json"),
                                reproduceCommand: reproduceCommand, workspaceRoot: workspace)
    var body = try MarkdownReporter.render(document, options: options)
    if format == .agent { body = body.replacingOccurrences(of: MarkdownReporter.marker + "\n", with: "") }
    if !body.hasSuffix("\n") { body += "\n" }
    if format == .github { appendStepSummary(body) }
    return Data(body.utf8)
}

/// The runner drops a whole step summary that is over this many bytes.
private let stepSummaryLimit = 1_048_576

/// `$GITHUB_STEP_SUMMARY` is a file the runner reads after the step; each step appends to it. An append that would take
/// the file over 1 MiB is skipped with a warning (the runner would drop the whole summary, the earlier appends too).
private func appendStepSummary(_ body: String) {
    guard let path = ProcessInfo.processInfo.environment["GITHUB_STEP_SUMMARY"], !path.isEmpty else { return }
    let existing = ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
    let added = body.utf8.count + 1
    if existing + added > stepSummaryLimit {
        writeStderr("warning: not appending to $GITHUB_STEP_SUMMARY: \(existing) + \(added) bytes would pass the "
            + "\(stepSummaryLimit)-byte limit and the runner would drop the whole summary (lower --max-report-bytes)")
        return
    }
    guard let handle = FileHandle(forWritingAtPath: path) ?? {
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }() else {
        writeStderr("warning: could not write $GITHUB_STEP_SUMMARY (\(path))")
        return
    }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: Data((body + "\n").utf8))
}
