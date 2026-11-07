import Foundation

// v0.6 lane C (docs/SCHEMA-v0.6.md "Formats"): `fix` and `verify --format markdown`, held to `options.maxBytes` (64 KB
// by default) with the report's `Fit` steps. Pure functions of the document; the CLI redacts first.
extension MarkdownReporter {
    /// Sticky-comment markers of their own, so a fix or verify comment never replaces the report comment.
    public static let fixPlanMarker = "<!-- xcblame:fixplan -->"
    public static let verifyMarker = "<!-- xcblame:verify -->"

    public static func render(_ plan: FixPlanDocument, options: FormatOptions) throws -> String {
        let view = FixPlanMarkdown(plan: plan)
        let reproduce = options.reproduceCommand ?? "xcblame fix --format json"
        return Fit.fit(cap: options.maxBytes, reproduce: reproduce, steps: view.steps, render: view.render)
    }

    public static func render(_ verify: VerifyDocument, options: FormatOptions) throws -> String {
        let view = VerifyMarkdown(verify: verify)
        let reproduce = options.reproduceCommand ?? "xcblame history show \(verify.id) --format json"
        return Fit.fit(cap: options.maxBytes, reproduce: reproduce, steps: view.steps, render: view.render)
    }
}

/// A fenced block of commands; a backtick cannot close the fence (it becomes an apostrophe).
private func commandBlock(_ commands: [String]) -> [String] {
    ["```sh"] + commands.map { FormatText.clip($0, 400).replacingOccurrences(of: "`", with: "'") } + ["```"]
}

private func footer(_ version: String, _ schema: String, _ redacted: Bool) -> String {
    "<sub>xcblame \(FormatText.markdown(version, limit: 40)), \(schema)" + (redacted ? ", redacted" : "") + "</sub>"
}

struct FixPlanMarkdown {
    let plan: FixPlanDocument

    var steps: [FitStep] {
        [
            .drop("lines", label: "overlay, defaults and manual lines"),
            .drop("events", "hook", label: "writes, hook"),
            .cap("steps", to: 20, label: "steps beyond 20"),
            .drop("scope", label: "scope column"),
            .cap("steps", to: 5, label: "steps beyond 5"),
        ]
    }

    func render(_ fit: FitPlan, _ note: String?) -> String {
        var lines = [MarkdownReporter.fixPlanMarker,
                     "## xcblame fix plan \(FormatText.markdown(plan.id, limit: 20)): " + FormatText.count(plan.steps.count, "step"), ""]
        lines += [FormatText.markdown(FixPlanWords.source(plan.generatedFrom)) + "  ", FormatText.markdown(FixPlanWords.summary(plan)), ""]
        let shown = plan.steps.prefix(fit.limit("steps", .max))
        if !shown.isEmpty {
            let scope = fit.shows("scope")
            lines += FormatText.header(["#", "Rule", "Title", "Impact", "Fix kind", "Mechanism", "Verify"] + (scope ? ["Scope"] : []))
            for step in shown {
                var cells = [String(step.order), FormatText.markdown(step.ruleId, limit: 20), FormatText.markdown(step.title, limit: 120),
                             FormatText.markdown(FixPlanWords.impact(step), limit: 60), step.fixKind.rawValue, step.mechanism.rawValue,
                             FormatText.markdown(FixVerifyWords.stateLabel(step.verify), limit: 40)
                                + (step.verifyOnly ? " (+V)" : "") + (step.state == .planned ? "" : ", \(step.state.rawValue)")]
                if scope {
                    let rows = step.scope.filter { $0.mechanism == step.mechanism }
                    cells.append(rows.isEmpty ? "n/a" : FormatText.markdown(FixVerifyWords.scopeSummary(rows, limit: 3), limit: 200))
                }
                lines.append(FormatText.row(cells))
            }
            if shown.count < plan.steps.count { lines += ["", "_\(shown.count) of \(plan.steps.count) steps_"] }
            lines.append("")
        }
        if !plan.guards.isEmpty {
            lines += ["### Guards", ""]
            for item in plan.guards {
                let mark = item.satisfied.map { $0 ? "[x]" : "[ ]" } ?? "[ ] (not checked)"
                let rules = item.ruleIds.isEmpty ? "" : " (" + FormatText.markdown(item.ruleIds.joined(separator: ", "), limit: 120) + ")"
                lines.append("- \(mark) " + FormatText.markdown(item.text) + rules)
            }
            lines.append("")
        }
        if fit.shows("hook"), !plan.hook.isEmpty {
            lines += ["### Hook", ""] + plan.hook.map { "- " + FormatText.markdown(FixPlanWords.hookLine($0)) } + [""]
        }
        if !plan.commands.isEmpty { lines += ["### Run", ""] + commandBlock(plan.commands) + [""] }
        if fit.shows("lines") {
            var body: [String] = []
            for step in shown where !(step.overlay.isEmpty && step.defaults.isEmpty && step.inXcode.isEmpty) {
                body.append("**\(FormatText.markdown(step.ruleId, limit: 20))**")
                body.append("")
                let text = step.overlay.map(\.line) + step.defaults.map(FixPlanWords.defaultsCommand)
                if !text.isEmpty { body += commandBlock(text) }
                body += step.inXcode.map { "- by hand: " + FormatText.markdown($0) }
                body.append("")
            }
            if !body.isEmpty { lines += ["<details><summary>Lines each step writes</summary>", ""] + body + ["</details>", ""] }
        }
        if fit.shows("events"), !plan.events.isEmpty {
            lines += ["### Writes", ""] + plan.events.map { "- " + FormatText.markdown(FixPlanWords.eventLine($0)) } + [""]
        }
        lines.append(plan.events.isEmpty ? "Nothing in the project changed." : "`xcblame fix --revert \(FormatText.clip(plan.id, 20))` undoes the writes.")
        lines.append("")
        if let note { lines += [note, ""] }
        lines.append(footer(plan.tool.version, plan.schemaVersion, plan.redacted))
        return lines.joined(separator: "\n") + "\n"
    }
}

struct VerifyMarkdown {
    let verify: VerifyDocument

    var steps: [FitStep] {
        [
            .drop("details", label: "scope and checks"),
            .cap("units", to: 20, label: "units beyond 20"),
            .drop("sentences", label: "verdict sentences"),
            .cap("units", to: 5, label: "units beyond 5"),
        ]
    }

    func render(_ fit: FitPlan, _ note: String?) -> String {
        let tally = FixVerifyWords.tally(verify)
        var lines = [MarkdownReporter.verifyMarker,
                     "## xcblame verify: kept \(tally[.kept] ?? 0), reverted \(tally[.reverted] ?? 0)", ""]
        var facts = ["plan \(FormatText.markdown(verify.planId, limit: 20))", FixVerifyWords.kindBuilds(verify.kind),
                     FormatText.count(verify.runsPerArm, "run") + " per arm"]
        if let scheme = verify.scheme { facts.append("scheme " + FormatText.markdown(scheme, limit: 60)) }
        if let configuration = verify.configuration { facts.append(FormatText.markdown(configuration, limit: 40)) }
        lines += [facts.joined(separator: " · "), ""]
        if let abort = verify.abort {
            lines += ["**Aborted (\(abort.reason.rawValue)):** " + FixVerifyWords.abortSentence(abort) + " " + FormatText.markdown(abort.detail), ""]
        }
        let units = verify.results.prefix(fit.limit("units", .max))
        if fit.shows("sentences"), !units.isEmpty {
            lines += units.map { "- " + FormatText.markdown(FixVerifyWords.verdictSentence($0, kind: verify.kind, runs: verify.runsPerArm), limit: 400) }
            lines.append("")
        }
        if !units.isEmpty {
            lines += FormatText.header(["Rule", "Arm", "Runs ok", "Each run", "p50 ± MAD", "Delta", "Noise band", "Verdict", "Mechanism"])
            for unit in units {
                for (index, arm) in unit.arms.enumerated() {
                    let first = index == 0, last = index == unit.arms.count - 1
                    lines.append(FormatText.row([
                        first ? FormatText.markdown(unit.ruleIds.joined(separator: " + "), limit: 120) : "",
                        arm.arm.rawValue, "\(arm.runsOk)/\(arm.runsTotal)", FixVerifyWords.runMarks(arm), FixVerifyWords.p50mad(arm),
                        last ? FormatText.deltaText(unit.deltaSeconds, unit.deltaPct) : "",
                        last ? (unit.noiseBand.map(FormatText.seconds) ?? "none") : "",
                        last ? "**" + FixVerifyWords.verdictLabel(unit.verdict) + "**" : "", last ? unit.mechanism.rawValue : "",
                    ]))
                }
            }
            if units.count < verify.results.count { lines += ["", "_\(units.count) of \(verify.results.count) units_"] }
            lines.append("")
        } else {
            lines += ["No unit was measured.", ""]
        }
        if fit.shows("details"), !units.isEmpty {
            var body: [String] = []
            for unit in units {
                body.append("- **\(FormatText.markdown(unit.ruleIds.joined(separator: " + "), limit: 120))** scope: "
                    + FormatText.markdown(FixVerifyWords.scopeSummary(unit.scope), limit: 400))
                let problems = unit.checks.filter { $0.status != "pass" }
                body.append("  checks: " + (problems.isEmpty ? "all \(unit.checks.count) passed"
                    : problems.map { FormatText.markdown("\($0.name) \($0.status): \($0.detail)", limit: 200) }.joined(separator: "; ")))
            }
            lines += ["<details><summary>Scope and checks</summary>", ""] + body + ["", "</details>", ""]
        }
        let next = FixVerifyWords.nextCommands(verify)
        if !next.isEmpty { lines += ["### Next", ""] + commandBlock(next) + [""] }
        if let note { lines += [note, ""] }
        lines.append(footer(verify.tool.version, verify.schemaVersion, verify.redacted))
        return lines.joined(separator: "\n") + "\n"
    }
}
