import Foundation

// v0.6 lane C (docs/SCHEMA-v0.6.md "Formats"): `fix` and `verify --format agent`: plain lines, deterministic, at most
// `options.maxBytes` (8 KB by default). The header and the `next:` line always stay; body lines go from the end first.
extension AgentReporter {
    public static func render(_ plan: FixPlanDocument, options: FormatOptions) throws -> String {
        let head = ["xcblame \(FormatText.oneLine(plan.tool.version)) agent fix plan (\(plan.schemaVersion))",
                    "plan: \(FormatText.clip(plan.id, 20)); " + FormatText.clip(FixPlanWords.summary(plan), 300),
                    FormatText.clip(FixPlanWords.source(plan.generatedFrom), 300)]
        var body = ["STEPS (\(plan.steps.count))"]
        for step in plan.steps {
            var line = "\(step.order). \(FormatText.clip(step.ruleId, 20)) [\(step.fixKind.rawValue) via \(step.mechanism.rawValue); "
                + "verify: \(FixVerifyWords.stateLabel(step.verify))\(step.verifyOnly ? ", +V" : "")] " + FormatText.clip(step.title, 160)
            if step.state != .planned { line += "; state: \(step.state.rawValue)" + (step.stateReason.map { " (\(FormatText.clip($0, 160)))" } ?? "") }
            body.append(line)
            let rows = step.scope.filter { $0.mechanism == step.mechanism }
            if !rows.isEmpty { body.append("   scope: " + FormatText.clip(FixVerifyWords.scopeSummary(rows, limit: 4), 300)) }
            body += step.overlay.map { "   overlay \(FormatText.clip($0.configuration, 40)): " + FormatText.clip($0.line, 300) }
            body += step.defaults.map { "   defaults: " + FormatText.clip(FixPlanWords.defaultsCommand($0), 300) }
            body += step.inXcode.prefix(2).map { "   by hand: " + FormatText.clip($0, 240) }
        }
        if !plan.guards.isEmpty {
            body.append("GUARDS")
            body += plan.guards.map { item in
                "- " + (item.satisfied.map { $0 ? "ok: " : "todo: " } ?? "unchecked: ") + FormatText.clip(item.text, 240)
            }
        }
        if !plan.hook.isEmpty { body += ["HOOK"] + plan.hook.map { "- " + FormatText.clip(FixPlanWords.hookLine($0), 240) } }
        if !plan.commands.isEmpty {
            body += ["RUN"] + plan.commands.enumerated().map { "\($0.offset + 1). " + FormatText.clip($0.element, 300) }
        }
        body += plan.notes.prefix(5).map { "note: " + FormatText.clip($0, 200) }
        let next = plan.commands.first ?? options.reproduceCommand ?? "xcblame fix --format json"
        return fitAgent(head: head, body: body, tail: ["next: " + FormatText.clip(next, 300)], cap: options.maxBytes)
    }

    public static func render(_ verify: VerifyDocument, options: FormatOptions) throws -> String {
        var facts = "plan: \(FormatText.clip(verify.planId, 20)); \(FixVerifyWords.kindBuilds(verify.kind)); "
            + FormatText.count(verify.runsPerArm, "run") + " per arm"
        if let scheme = verify.scheme { facts += "; scheme: " + FormatText.clip(scheme, 80) }
        if let configuration = verify.configuration { facts += "; configuration: " + FormatText.clip(configuration, 40) }
        var head = ["xcblame \(FormatText.oneLine(verify.tool.version)) agent verify (\(verify.schemaVersion))",
                    "result: " + FixVerifyWords.counts(verify), facts]
        if let abort = verify.abort {
            head.append("ABORTED (\(abort.reason.rawValue)): " + FixVerifyWords.abortSentence(abort) + " " + FormatText.clip(abort.detail, 240))
        }
        var body = ["RESULTS (\(verify.results.count) units)"]
        for unit in verify.results {
            body.append("- " + FormatText.clip(unit.ruleIds.joined(separator: "+"), 120) + ": " + FixVerifyWords.verdictLabel(unit.verdict)
                + "; " + FormatText.clip(FixVerifyWords.verdictSentence(unit, kind: verify.kind, runs: verify.runsPerArm), 400))
            for arm in unit.arms {
                body.append("  \(arm.arm.rawValue): runs ok \(arm.runsOk)/\(arm.runsTotal) \(FixVerifyWords.runMarks(arm)); p50 ± MAD "
                    + FixVerifyWords.p50mad(arm))
            }
            body.append("  delta \(FormatText.deltaText(unit.deltaSeconds, unit.deltaPct)); noise band "
                + (unit.noiseBand.map(FormatText.seconds) ?? "none") + "; mechanism \(unit.mechanism.rawValue)")
            body.append("  scope: " + FormatText.clip(FixVerifyWords.scopeSummary(unit.scope, limit: 4), 300))
            let problems = unit.checks.filter { $0.status != "pass" }
            if !problems.isEmpty {
                body.append("  checks: " + problems.map { FormatText.clip("\($0.name) \($0.status): \($0.detail)", 160) }.joined(separator: "; "))
            }
        }
        body += verify.notes.prefix(5).map { "note: " + FormatText.clip($0, 200) }
        let next = FixVerifyWords.nextCommands(verify)
        var tail = next.dropFirst().map { "then: " + FormatText.clip($0, 300) }
        tail.insert("next: " + FormatText.clip(next.first ?? options.reproduceCommand ?? "xcblame history show \(verify.id) --format json", 300), at: 0)
        return fitAgent(head: head, body: body, tail: tail, cap: options.maxBytes)
    }

    /// Head, body, tail; when over `cap`, body lines go from the end and `[truncated]` takes their place. A cap too small
    /// for head and tail alone cuts the whole text at the cap.
    static func fitAgent(head: [String], body: [String], tail: [String], cap: Int) -> String {
        let whole = (head + body + tail).joined(separator: "\n") + "\n"
        if FormatText.bytes(whole) <= cap { return whole }
        func size(_ lines: [String]) -> Int { lines.reduce(0) { $0 + FormatText.bytes($1) + 1 } }
        let room = cap - size(head) - size(tail) - FormatText.bytes(truncated) - 1
        var kept: [String] = []
        var used = 0
        for line in body {
            let next = FormatText.bytes(line) + 1
            if used + next > room { break }
            kept.append(line)
            used += next
        }
        return FormatText.clamp((head + kept + [truncated] + tail).joined(separator: "\n") + "\n", to: cap)
    }
}
