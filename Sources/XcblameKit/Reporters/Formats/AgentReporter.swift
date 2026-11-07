import Foundation

/// `--format agent`: errors and warnings first, then a summary of at most 6,000 bytes (about 1,500 tokens), all inside
/// the cap (docs/SCHEMA-v0.4.md "Formats", DESIGN §8.3). Plain text, no tables, deterministic.
public enum AgentReporter {
    /// The summary (BUILD, CRITICAL PATH, FINDINGS, NOTES, next) is never dropped and never longer than this.
    static let summaryCap = 6000
    /// Errors are kept down to this many before the cap cuts the text instead.
    static let errorFloor = 20
    static let truncated = "[truncated]"

    public static func render(_ document: ReportDocument, options: FormatOptions) throws -> String {
        let doctor = FormatText.isDoctor(document)
        let reproduce = options.reproduceCommand
            ?? (doctor ? "xcblame doctor --format json" : "xcblame analyze <input> --format json")
        let errors = document.diagnostics.filter { $0.severity == "error" }
        let warnings = document.diagnostics.filter { $0.severity == "warning" }
        let summary = document.diagnosticsSummary

        let failed = summary.errors > 0 || document.doctor?.failed == true
        let header = [
            "xcblame \(FormatText.oneLine(document.tool.version)) agent report (\(document.schemaVersion))",
            "result: \(failed ? "failed" : "succeeded") (\(FormatText.count(summary.errors, "error")), "
                + "\(FormatText.count(summary.warnings, "warning")))",
        ]
        let tail = summaryLines(document, doctor: doctor, reproduce: reproduce, hasErrors: summary.errors > 0)

        func diagnostics(_ keepErrors: Int, _ keepWarnings: Int) -> [String] {
            section("ERRORS", "errors", errors, unique: summary.errors, keep: keepErrors, reproduce: reproduce, root: options.workspaceRoot)
                + section("WARNINGS", "warnings", warnings, unique: summary.warnings, keep: keepWarnings, reproduce: reproduce, root: options.workspaceRoot)
        }
        func text(_ keepErrors: Int, _ keepWarnings: Int) -> String {
            (header + diagnostics(keepErrors, keepWarnings) + tail).joined(separator: "\n") + "\n"
        }

        let cap = options.maxBytes
        // Warnings go first from the tail, then errors down to the floor; the summary stays.
        for keep in stride(from: warnings.count, through: 0, by: -1) {
            let candidate = text(errors.count, keep)
            if FormatText.bytes(candidate) <= cap { return candidate }
        }
        let floor = min(errors.count, errorFloor)
        for keep in stride(from: errors.count - 1, through: floor, by: -1) {
            let candidate = text(keep, 0)
            if FormatText.bytes(candidate) <= cap { return candidate }
        }
        // Still over at the floor: clip the diagnostics block, never the tail (the summary is never dropped). Only a cap
        // too small for the header and the summary alone cuts the text from the end.
        let fixed = (header + tail).reduce(0) { $0 + FormatText.bytes($1) + 1 }
        let room = cap - fixed - FormatText.bytes(truncated) - 1
        if room > 0 {
            var kept: [String] = []
            var used = 0
            for line in diagnostics(floor, 0) {
                let size = FormatText.bytes(line) + 1
                if used + size > room { break }
                kept.append(line)
                used += size
            }
            let candidate = (header + kept + [truncated] + tail).joined(separator: "\n") + "\n"
            if FormatText.bytes(candidate) <= cap { return candidate }
        }
        return hardTruncate(text(floor, 0), cap: cap)
    }

    // MARK: Diagnostics

    private static func section(_ title: String, _ noun: String, _ rows: [ReportDocument.DiagnosticEntry], unique: Int,
                                keep: Int, reproduce: String, root: String?) -> [String] {
        guard unique > 0 || !rows.isEmpty else { return [] }
        let total = max(unique, rows.count)
        let seen = rows.reduce(0) { $0 + $1.occurrences }
        let occurrences = rows.count < total ? "at least \(seen) occurrences" : "\(seen) occurrences"
        var lines = ["\(title) (\(total) unique, \(occurrences))"]
        for entry in rows.prefix(keep) {
            lines.append("- " + FormatText.diagnosticLine(entry, workspaceRoot: root, prefix: false, messageLimit: 200, column: true, alwaysCount: true))
        }
        let shown = min(keep, rows.count)
        if shown < total { lines.append("... \(total - shown) more \(noun) not shown (\(reproduce))") }
        return lines
    }

    // MARK: Summary

    private static func summaryLines(_ document: ReportDocument, doctor: Bool, reproduce: String,
                                     hasErrors: Bool) -> [String] {
        var lines: [String] = []
        if doctor {
            lines += doctorLines(document)
        } else {
            lines += buildLines(document)
            lines += pathLines(document)
        }
        lines += findingLines(document, limit: doctor ? 10 : 3)
        let notes = document.notes.map { FormatText.clip($0, 200) }.filter { !$0.isEmpty }.prefix(5)
        if !notes.isEmpty { lines += ["NOTES"] + notes.map { "- " + $0 } }
        let fix = document.findings.first?.fixCommands.first
        lines.append("next: " + FormatText.clip((hasErrors ? nil : fix) ?? reproduce, 200))
        return cut(lines)
    }

    /// Keeps whole lines within `summaryCap` bytes; a cut ends in `[truncated]`.
    static func cut(_ lines: [String]) -> [String] {
        func size(_ list: [String]) -> Int { list.reduce(0) { $0 + FormatText.bytes($1) + 1 } }
        guard size(lines) > summaryCap else { return lines }
        var kept: [String] = []
        for line in lines where size(kept) + FormatText.bytes(line) + 1 + FormatText.bytes(truncated) + 1 <= summaryCap {
            kept.append(line)
        }
        return kept + [truncated]
    }

    private static func buildLines(_ document: ReportDocument) -> [String] {
        var lines = ["BUILD"]
        let key = FormatText.buildKey(document).map { "\($0.0): \(FormatText.clip($0.1, 80))" }
        if !key.isEmpty { lines.append(key.joined(separator: "; ")) }
        var numbers: [String] = []
        if let wall = FormatText.wall(document) { numbers.append("wall: \(FormatText.seconds(wall))") }
        if let busy = FormatText.busy(document) { numbers.append("busy: \(FormatText.seconds(busy))") }
        if let span = FormatText.criticalPathSeconds(document) { numbers.append("critical path: \(FormatText.seconds(span))") }
        numbers.append("tasks: \(document.build.tasks)")
        lines.append(numbers.joined(separator: "; "))
        if document.degraded {
            let kinds = document.degradations.map(\.kind).prefix(5).map { FormatText.clip($0, 40) }
            lines.append("status: degraded" + (kinds.isEmpty ? "" : " (" + kinds.joined(separator: ", ") + ")"))
        }
        if let regression = document.regression {
            var text = "regression: " + FormatText.regressionSentence(regression, bold: false)
            if let limit = regression.thresholdPct { text += ", threshold \(FormatText.threshold(limit))" }
            if regression.failed { text += ", FAILED" }
            lines.append(text)
        }
        return lines
    }

    private static func pathLines(_ document: ReportDocument) -> [String] {
        guard let path = document.criticalPath, !path.segments.isEmpty else { return [] }
        let top = path.segments.enumerated().sorted {
            $0.element.seconds != $1.element.seconds ? $0.element.seconds > $1.element.seconds : $0.offset < $1.offset
        }.map(\.element).prefix(3)
        var lines = ["CRITICAL PATH (top \(top.count) of \(path.segmentsTotal) segments)"]
        for (index, segment) in top.enumerated() {
            lines.append("\(index + 1). \(FormatText.seconds(segment.seconds)) (\(FormatText.percent(segment.share))) "
                + "\(FormatText.clip(segment.target ?? "(no target)", 60)): \(FormatText.clip(segment.label, 120))")
        }
        return lines
    }

    private static func findingLines(_ document: ReportDocument, limit: Int) -> [String] {
        guard !document.findings.isEmpty else { return [] }
        let top = document.findings.prefix(limit)
        var lines = ["FINDINGS (top \(top.count) of \(document.findingsTotal))"]
        for (index, finding) in top.enumerated() {
            let badge = FormatText.findingBadge(finding, document)
            var line = "\(index + 1). \(FormatText.clip(finding.ruleId, 30))" + (badge.isEmpty ? "" : " [\(FormatText.clip(badge, 30))]")
                + " " + FormatText.clip(finding.title, 160)
            if let fix = finding.fixCommands.first {
                line += (line.hasSuffix(".") ? " " : ". ") + "Fix: " + FormatText.clip(fix, 200)
            }
            lines.append(line)
        }
        return lines
    }

    private static func doctorLines(_ document: ReportDocument) -> [String] {
        var parts: [String] = []
        let container = document.project.map { URL(fileURLWithPath: $0.container).lastPathComponent }
            ?? document.input.path.map { URL(fileURLWithPath: $0).lastPathComponent }
        if let container { parts.append("project: \(FormatText.clip(container, 80))") }
        if let xcode = document.xcode.value { parts.append("xcode: \(FormatText.clip(xcode, 40))") }
        if let doctor = document.doctor {
            parts.append("rules: \(doctor.rulesEvaluated) evaluated, \(document.findings.count) findings, "
                + "\(doctor.passed.count) passed, \(doctor.notApplicable.count) not applicable")
            if let failOn = doctor.failOn { parts.append("fail-on \(failOn): " + (doctor.failed ? "FAILED" : "ok")) }
        }
        return ["DOCTOR", parts.joined(separator: "; ")]
    }

    // MARK: Cap

    /// The text cut at the last whole line that leaves room for `[truncated]`, then clamped to the cap.
    private static func hardTruncate(_ text: String, cap: Int) -> String {
        let marker = truncated + "\n"
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last == "" { lines.removeLast() }
        var kept: [String] = []
        var used = FormatText.bytes(marker)
        for line in lines {
            let size = FormatText.bytes(line) + 1
            if used + size > cap { break }
            kept.append(line)
            used += size
        }
        return FormatText.clamp((kept + [truncated]).joined(separator: "\n") + "\n", to: cap)
    }
}
