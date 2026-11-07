import Foundation

/// `--format github`: the markdown comment plus `::warning`/`::error` annotations (docs/SCHEMA-v0.4.md "Formats").
/// The caller writes `annotations` to stderr (the runner processes workflow commands from both streams: it hooks an
/// output manager with the command manager to stdout and to stderr in `ScriptHandler`) and appends `body` to
/// `$GITHUB_STEP_SUMMARY`.
public enum GitHubReporter {
    /// The runner shows 10 warnings and 10 errors per step.
    static let annotationCap = 10
    /// Hotspots under this many milliseconds are not worth an annotation.
    static let hotspotFloorMs = 100.0

    public static func render(_ document: ReportDocument, options: FormatOptions) throws -> FormatOutput {
        // Runner commands are neutralized where the text is made (`FormatText.clip`), before the budget is fitted.
        FormatOutput(body: try MarkdownReporter.render(document, options: options),
                     annotations: annotations(document, options: options))
    }

    static func annotations(_ document: ReportDocument, options: FormatOptions) -> [String] {
        func relative(_ file: String?) -> String? {
            file.flatMap { FormatText.repoRelative($0, workspaceRoot: options.workspaceRoot) }
        }
        func command(_ level: String, file: String?, line: Int?, column: Int?, title: String, message: String) -> String {
            var properties: [String] = []
            if let file {
                properties.append("file=" + escapeProperty(file))
                if let line {
                    properties.append("line=\(line)")
                    if let column { properties.append("col=\(column)") }
                }
            }
            properties.append("title=" + escapeProperty(title))
            return "::\(level) " + properties.joined(separator: ",") + "::" + escapeData(message)
        }

        // 1. Errors with a file, by occurrences descending (the document is already ordered that way; stable sort).
        let errors = document.diagnostics.filter { $0.severity == "error" }
            .enumerated().sorted { $0.element.occurrences != $1.element.occurrences
                ? $0.element.occurrences > $1.element.occurrences : $0.offset < $1.offset }.map(\.element)
        var errorLines: [String] = []
        for entry in errors {
            if let file = relative(entry.file) {
                errorLines.append(command("error", file: file, line: entry.line, column: entry.column, title: "xcblame",
                                          message: message(entry, options)))
            } else if let located = unlocated(entry, options) {
                errorLines.append(command("error", file: nil, line: nil, column: nil, title: "xcblame", message: located))
            }
        }
        // 3. A file-less summary of the errors that got no annotation of their own (no repo path, or over the cap).
        errorLines = dedupe(errorLines)
        var errorTail: [String] = []
        if document.diagnosticsSummary.errors > min(errorLines.count, annotationCap) {
            let rest = document.diagnosticsSummary.errors - min(errorLines.count, annotationCap - 1)
            errorTail.append(command("error", file: nil, line: nil, column: nil, title: "xcblame",
                                     message: FormatText.count(rest, "build error")))
        }
        var warningTail: [String] = []
        if let regression = document.regression, regression.failed {
            let slower = regression.wall.deltaPct.map { FormatText.signedPercent($0) } ?? "an unknown amount"
            warningTail.append(command("warning", file: nil, line: nil, column: nil, title: "xcblame",
                                       message: "build is slower than the baseline by \(slower)"))
        }
        // 2. Warnings with a file, then hotspots in user code under the workspace.
        var warningLines: [String] = []
        for entry in document.diagnostics where entry.severity == "warning" {
            if let file = relative(entry.file) {
                warningLines.append(command("warning", file: file, line: entry.line, column: entry.column, title: "xcblame",
                                            message: message(entry, options)))
            } else if let located = unlocated(entry, options) {
                warningLines.append(command("warning", file: nil, line: nil, column: nil, title: "xcblame", message: located))
            }
        }
        for hotspot in document.hotspots ?? [] where hotspot.ms >= hotspotFloorMs {
            guard let file = relative(hotspot.file) else { continue }
            warningLines.append(command("warning", file: file, line: hotspot.line, column: hotspot.col,
                                        title: "xcblame hotspot",
                                        message: "\(FormatText.mentionSafe(FormatText.oneLine(hotspot.declaration))) \(Int(hotspot.ms.rounded())) ms (type-check)"))
        }
        func capped(_ head: [String], _ tail: [String]) -> [String] {
            var seen = Set<String>()
            let unique = (head.prefix(max(0, annotationCap - tail.count)) + tail).filter { seen.insert($0).inserted }
            return Array(unique)
        }
        return capped(dedupe(errorLines), errorTail) + capped(dedupe(warningLines), warningTail)
    }

    private static func dedupe(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.filter { seen.insert($0).inserted }
    }

    private static func message(_ entry: ReportDocument.DiagnosticEntry, _ options: FormatOptions) -> String {
        FormatText.mentionSafe(FormatText.clip(FormatText.repoText(entry.message, workspaceRoot: options.workspaceRoot), 300))
            + (entry.occurrences > 1 ? " (x\(entry.occurrences))" : "")
    }

    /// The message of an entry whose file cannot be a repo-relative `file=` (outside the workspace, a package checkout):
    /// the annotation is kept without a file, and the file name (never its folders: no home or absolute path leaves in
    /// an annotation) and line move into the text. Nil for an entry that has no file at all.
    private static func unlocated(_ entry: ReportDocument.DiagnosticEntry, _ options: FormatOptions) -> String? {
        guard let name = entry.file.map({ ($0 as NSString).lastPathComponent }), !name.isEmpty,
              let place = FormatText.location(file: name, line: entry.line, column: nil) else { return nil }
        return place + ": " + message(entry, options)
    }

    /// `%` to `%25`, CR to `%0D`, LF to `%0A` (the runner's data escaping), and `##[` to `##\[` so the legacy
    /// `##[command]` syntax cannot start inside a message.
    static func escapeData(_ text: String) -> String {
        FormatText.neutralizeRunnerCommands(text).replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    /// Data escaping plus `:` to `%3A` and `,` to `%2C` (property values).
    static func escapeProperty(_ text: String) -> String {
        escapeData(text).replacingOccurrences(of: ":", with: "%3A").replacingOccurrences(of: ",", with: "%2C")
    }
}
