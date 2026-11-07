import Foundation

// v0.5 lane B (docs/SCHEMA-v0.5.md "why"): DYN-002 is built here, not in the rule catalog (unchanged in v0.5); the text
// follows docs/RULES.md DYN-002.
public enum DYN002 {
    public static let id = "DYN-002"

    /// `ruleDocs["DYN-002"]`.
    public static let ruleDoc = ReportDocument.RuleDoc(
        title: "unstable-inputs",
        summary: "Two consecutive zero-change builds both execute compile or plan tasks, or an input's modification "
            + "time is newer than the previous build while its content hash is identical: something rewrites inputs "
            + "without changing them.",
        fix: "Find the tool touching timestamps (linter, formatter, code generator) and make it write only on content "
            + "change; see PHASE-003 and PHASE-004.",
        sources: ["[PP] A1", "https://forums.swift.org/t/84803", "https://developer.apple.com/forums/thread/693285"],
        id: id, category: "DYN", applyKinds: ["rec"], verifyOnly: false, risk: "None.", evidenceTag: "S")

    /// `document` with the DYN-002 finding and its `ruleDocs` entry when the procedure found it; unchanged otherwise.
    public static func applying(to document: ReportDocument, result: WhyProcedure.Result) -> ReportDocument {
        guard result.dyn002, let measured = result.step("measure"), let repeated = result.step("repeat") else {
            return document
        }
        let work = Set(repeated.workTasks)
        let timeline = Timing.timeline(repeated.model).counted.filter { work.contains($0.task.id) }
        let labels = timeline.prefix(5).map { Explain.label($0.task, model: repeated.model) }
        let seconds = timeline.reduce(0) { $0 + $1.interval.duration }
        var document = document
        document.findings.append(finding(measured: measured.workTasks.count, repeated: repeated.workTasks.count,
                                         tasks: labels, seconds: seconds))
        document.findingsTotal = document.findings.count
        document.ruleDocs[id] = ruleDoc
        return document
    }

    /// The finding for a `why` run whose measured and repeat zero-change builds both executed compile or plan tasks.
    /// `tasks` are labels of the repeat build's work tasks (first few), `seconds` their task time.
    public static func finding(measured: Int, repeated: Int, tasks: [String], seconds: Double?) -> ReportDocument.Finding {
        var evidence = ["measured zero-change build executed \(measured) compile/plan task(s)",
                        "repeat zero-change build executed \(repeated) compile/plan task(s)"]
        evidence += tasks.prefix(5).map { "repeat ran: \($0)" }
        let details = evidence.map { ReportDocument.EvidenceItem(kind: "report", ref: "why", value: $0) }
        return ReportDocument.Finding(
            ruleId: id, title: "Zero-change builds keep compiling: inputs are rewritten between builds",
            severity: "medium", impactBand: Confidence.band(seconds: seconds, share: nil),
            impactSeconds: seconds.map(ReportDocument.round6), impactBasis: seconds == nil ? nil : "measured",
            confidence: "high", evidence: evidence, fixKind: "recommend", risk: "None.", mechanism: nil,
            signalKey: "why:dyn-002", scopeTargets: [], scopeConfigurations: [], evidenceDetails: details,
            fixCommands: [], overlayLines: [], seeAlso: ["PHASE-003", "PHASE-004"], xcode: nil,
            sources: ruleDoc.sources, needsMeasurement: false)
    }
}
