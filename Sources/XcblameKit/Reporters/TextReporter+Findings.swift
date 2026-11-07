import Foundation

extension TextReporter {
    /// The analyze report's FINDINGS and PLAN sections (DESIGN §3.3): band, id, wrapped title, confidence, in fix-plan
    /// order, capped at `topN` with "n of m". Empty when no rule produced a finding, so a report without rules reads as
    /// it did in v0.2.
    func findingsLines(_ doc: ReportDocument) -> [String] {
        let summary = rulesSummary(doc).map { [dim($0)] } ?? []
        guard !doc.findings.isEmpty else { return summary }
        let shown = Array(doc.findings.prefix(doc.topN))
        let idWidth = max(7, shown.map(\.ruleId.count).max() ?? 7)
        let titleWidth = 64
        let head = "FINDINGS \(shown.count) of \(doc.findingsTotal)"
        let confidenceColumn = 2 + 4 + idWidth + 2 + titleWidth + 2
        var lines = [bold(head) + String(repeating: " ", count: max(2, confidenceColumn - head.count)) + dim("confidence")]
        for finding in shown {
            var title = finding.title
            if let seconds = finding.impactSeconds {
                title += " (" + Self.duration(seconds) + (finding.impactBasis.map { ", \($0)" } ?? "") + ")"
            }
            if finding.needsMeasurement { title += (title.hasSuffix(".") ? " " : ". ") + "Needs measurement." }
            for (row, text) in wrap(safe(title), width: titleWidth).enumerated() {
                let band = row == 0 ? pad(Self.bandText(finding), 4) : String(repeating: " ", count: 4)
                let id = row == 0 ? finding.ruleId : ""
                var line = "  " + band + pad(id, idWidth) + "  " + text
                if row == 0 { line = "  " + band + pad(id, idWidth) + "  " + pad(text, titleWidth) + "  " + finding.confidence }
                lines.append(rstrip(line))
            }
        }
        if shown.count < doc.findings.count {
            lines.append(dim("  shown \(shown.count) of \(doc.findings.count) findings (--top all shows every finding)"))
        }
        if !doc.fixPlan.isEmpty {
            let steps = Array(doc.fixPlan.prefix(doc.topN))
            if ReportDocument.planEditsProject(doc.fixPlan) { lines.append(Self.commitFirst) }
            lines += steps.enumerated().map { index, step in
                (index == 0 && !ReportDocument.planEditsProject(doc.fixPlan) ? bold("PLAN") + "  " : "      ") + planStepText(step)
            }
            if steps.count < doc.fixPlan.count { lines.append(dim("      shown \(steps.count) of \(doc.fixPlan.count) steps")) }
            if doc.fixPlan.contains(where: { ReportDocument.isFutureCommand($0.command) }) { lines.append(Self.futureLine) }
        }
        return lines + summary
    }

    /// The impact column: the measured band, `~M` for a catalog estimate not measured on this build, else `?`.
    static func bandText(_ finding: ReportDocument.Finding) -> String {
        if let band = finding.impactBand, band != "?" { return band }
        return finding.estimatedBand.map { "~" + $0 } ?? "?"
    }

    /// One line instead of the PASS / N/A lists (those belong to `doctor`): `rules: 46 evaluated, 0 findings, 46 not
    /// applicable (no project)`. Nil when no rule ran.
    func rulesSummary(_ doc: ReportDocument) -> String? {
        guard let doctor = doc.doctor else { return nil }
        var parts = ["\(doctor.rulesEvaluated) evaluated", "\(doc.findings.count) finding\(doc.findings.count == 1 ? "" : "s")"]
        if !doctor.passed.isEmpty { parts.append("\(doctor.passed.count) passed") }
        if !doctor.notApplicable.isEmpty { parts.append("\(doctor.notApplicable.count) not applicable") }
        if !doctor.suppressed.isEmpty { parts.append("\(doctor.suppressed.count) suppressed") }
        return "rules: " + parts.joined(separator: ", ") + (doc.project == nil ? " (no project)" : "")
    }
}
