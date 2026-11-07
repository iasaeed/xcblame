import Foundation

// v0.6 lane C (docs/SCHEMA-v0.6.md "Text"): the `verify` table as text, and the plain-word sentences the text,
// markdown and agent formats share for both v0.6 documents (the HTML page has its own copy in `report.html`).
extension TextReporter {
    /// One block per measured unit: arm rows (runs ok/total, one mark per run, p50 ± MAD), then the delta, the noise
    /// band, the verdict in plain words, the mechanism and the per-target scope; the abort block when the run stopped.
    public static func renderVerify(_ verify: VerifyDocument, colors: Bool = false) -> String {
        let text = TextReporter(colors: colors)
        var lines: [String] = []
        var head = "xcblame verify \(text.safe(verify.id)) · plan \(text.safe(verify.planId)) · \(FixVerifyWords.kindBuilds(verify.kind))"
            + " · \(text.plural(verify.runsPerArm, "run")) per arm"
        if let scheme = verify.scheme { head += " · scheme \(text.safe(scheme))" }
        if let configuration = verify.configuration { head += " · \(text.safe(configuration))" }
        lines.append(text.bold(head))
        lines.append("  " + FixVerifyWords.counts(verify))
        let model = verify.noiseModel
        lines.append(text.dim("  noise band = max(\(String(format: "%g", model.madMultiplier)) × pooled MAD, "
            + "\(FormatText.threshold(model.minPct)) of A's p50); fewer than \(model.minRuns) runs or \(model.minSamples) "
            + "samples per arm is indicative and never kept"))
        if verify.kind != .clean { lines.append(text.dim("  the first run of each arm is the unmeasured settle build")) }
        if let touch = verify.touch { lines.append(text.dim("  touched before each measured build: " + text.safe(touch))) }
        let warned = verify.preconditions.filter { $0.status != "pass" }
        if !verify.preconditions.isEmpty {
            lines.append("  preconditions: " + (warned.isEmpty ? "all \(verify.preconditions.count) passed"
                : warned.map { "\($0.name) \($0.status): \(text.safe($0.detail))" }.joined(separator: "; ")))
        }
        if let abort = verify.abort {
            lines += ["", text.fail("ABORTED") + "  " + FixVerifyWords.abortSentence(abort)]
            if !abort.detail.isEmpty { lines.append("  " + text.safe(abort.detail)) }
        }
        for unit in verify.results {
            lines.append("")
            lines += unitLines(unit, verify: verify, text: text)
        }
        if verify.results.isEmpty { lines += ["", "  no unit was measured"] }
        let next = FixVerifyWords.nextCommands(verify)
        if !next.isEmpty {
            lines += ["", text.bold("NEXT")]
            lines += next.enumerated().map { "  \($0.offset + 1). \(text.safe($0.element))" }
        }
        if !verify.notes.isEmpty {
            lines += [""] + verify.notes.map { text.dim("note: " + text.safe($0)) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func unitLines(_ unit: VerifyDocument.UnitResult, verify: VerifyDocument, text: TextReporter) -> [String] {
        var lines = [text.bold(text.safe(unit.ruleIds.joined(separator: " + "))) + "  " + text.safe(unit.titles.joined(separator: "; "))]
        let rows = unit.arms.map { arm in
            [arm.arm == .a ? "A (without)" : "B (with)", "\(arm.runsOk)/\(arm.runsTotal)", FixVerifyWords.runMarks(arm),
             FixVerifyWords.p50mad(arm)]
        }
        let header = ["ARM", "RUNS OK", "EACH RUN", "P50 ± MAD"]
        let widths = header.indices.map { column in ([header[column]] + rows.map { $0[column] }).map(\.count).max() ?? 0 }
        func line(_ row: [String]) -> String { text.rstrip("  " + row.indices.map { text.pad(row[$0], widths[$0]) }.joined(separator: "  ")) }
        lines.append(text.dim(line(header)))
        lines += rows.map(line)
        let band = unit.noiseBand.map(FormatText.seconds) ?? "none (too few samples)"
        lines.append("  delta \(FormatText.deltaText(unit.deltaSeconds, unit.deltaPct)) · noise band \(band)")
        let verdict = FixVerifyWords.verdictLabel(unit.verdict)
        let colored = unit.verdict.status == .kept ? verdict : unit.verdict.status == .reverted ? text.fail(verdict) : text.warn(verdict)
        lines.append("  verdict " + colored + ": " + text.safe(FixVerifyWords.verdictSentence(unit, kind: verify.kind, runs: verify.runsPerArm)))
        lines.append("  mechanism " + unit.mechanism.rawValue + ": " + FixVerifyWords.mechanismSentence(unit.mechanism))
        lines.append("  scope " + text.safe(FixVerifyWords.scopeSummary(unit.scope)))
        let problems = unit.checks.filter { $0.status != "pass" }
        if !unit.checks.isEmpty {
            lines.append("  checks " + (problems.isEmpty ? "all \(unit.checks.count) passed"
                : problems.map { "\($0.name) \($0.status): \(text.safe($0.detail))" }.joined(separator: "; ")))
        }
        lines += unit.notes.map { text.dim("  note: " + text.safe($0)) }
        return lines
    }
}

/// The sentences of the v0.6 documents, shared by text, markdown and agent (docs/SCHEMA-v0.6.md "VerifyState" spelling).
enum FixVerifyWords {
    /// `kept`, `kept (tie)`, `reverted (slower)`, ..., `indicative`, `unverified`.
    static func label(_ status: FixPlanDocument.VerifyStatus, _ reason: FixPlanDocument.RevertReason?, tie: Bool) -> String {
        switch status {
        case .kept: return tie ? "kept (tie)" : "kept"
        case .reverted: return "reverted" + (reason.map { " (\(reasonWords($0)))" } ?? "")
        case .indicative, .unverified: return status.rawValue
        }
    }

    static func verdictLabel(_ verdict: VerifyDocument.Verdict) -> String { label(verdict.status, verdict.reason, tie: verdict.tie) }

    static func stateLabel(_ state: FixPlanDocument.VerifyState) -> String { label(state.status, state.reason, tie: state.tie) }

    static func reasonWords(_ reason: FixPlanDocument.RevertReason) -> String {
        switch reason {
        case .slower: return "slower"
        case .withinNoise: return "within noise"
        case .brokeBuild: return "broke build"
        case .taskSetChanged: return "task set changed"
        case .noEffect: return "no effect"
        }
    }

    static func kindBuilds(_ kind: VerifyDocument.Kind) -> String { kind.rawValue + " builds" }

    /// How a mechanism reaches the build, as a sentence.
    static func mechanismSentence(_ mechanism: FixPlanDocument.Mechanism) -> String {
        switch mechanism {
        case .hook:
            return "the overlay file, read through one #include? line (the hook) in the project's base xcconfig; Xcode and xcodebuild see it, project targets only"
        case .cli:
            return "a -xcconfig wrapper on the xcodebuild command line (CI, xcblame build --overlay); every target sees it, Xcode builds do not"
        case .defaults:
            return "an Xcode preference on this Mac (defaults write com.apple.dt.Xcode); xcblame fix --apply-defaults writes it and --revert restores it"
        case .recommend:
            return "a change you make by hand; xcblame writes nothing for it"
        }
    }

    /// One mark per run: ✓ exit 0, ✗ failed.
    static func runMarks(_ arm: VerifyDocument.ArmResult) -> String {
        arm.runs.isEmpty ? "-" : arm.runs.map { $0.ok ? "✓" : "✗" }.joined()
    }

    static func p50mad(_ arm: VerifyDocument.ArmResult) -> String {
        guard let p50 = arm.p50 else { return "n/a (no samples)" }
        return FormatText.seconds(p50) + " ± " + FormatText.seconds(arm.mad ?? 0)
    }

    /// Rules per verdict (a batch counts each of its rules): `kept 1, reverted 2`, plus indicative/unverified when any.
    static func tally(_ verify: VerifyDocument) -> [FixPlanDocument.VerifyStatus: Int] {
        var out: [FixPlanDocument.VerifyStatus: Int] = [:]
        for unit in verify.results { out[unit.verdict.status, default: 0] += unit.ruleIds.count }
        return out
    }

    static func counts(_ verify: VerifyDocument) -> String {
        let tally = tally(verify)
        let parts = [FixPlanDocument.VerifyStatus.kept, .reverted, .indicative, .unverified].compactMap { status -> String? in
            let count = tally[status] ?? 0
            return count == 0 && status != .kept && status != .reverted ? nil : "\(status.rawValue) \(count)"
        }
        return parts.joined(separator: ", ") + (verify.abort != nil ? " (the run stopped early)" : "")
    }

    private static func amount(_ seconds: Double?) -> String { FormatText.seconds(seconds.map(abs)) }

    private static func share(_ fraction: Double?) -> String {
        fraction.map { String(format: " (%.1f %%)", abs($0) * 100) } ?? ""
    }

    /// The Start-here sentence of a unit (docs/SCHEMA-v0.6.md "HTML"): what turning the change on did, and the verdict.
    static func verdictSentence(_ unit: VerifyDocument.UnitResult, kind: VerifyDocument.Kind, runs: Int) -> String {
        let subject = "Turning on " + unit.ruleIds.joined(separator: " + ")
        let builds = kindBuilds(kind)
        let band = unit.noiseBand.map { " (\(FormatText.seconds($0)))" } ?? ""
        let delta = unit.deltaSeconds
        switch (unit.verdict.status, unit.verdict.reason) {
        case (.kept, _) where unit.verdict.tie:
            return "\(subject) changed \(builds) by \(FormatText.deltaText(delta, unit.deltaPct)), inside the noise band\(band): kept anyway (--keep-on-tie)."
        case (.kept, _):
            return "\(subject) made \(builds) \(amount(delta)) faster\(share(unit.deltaPct)), more than the noise band\(band): kept."
        case (.reverted, .slower?):
            return "\(subject) made \(builds) \(amount(delta)) slower\(share(unit.deltaPct)), more than the noise band\(band): reverted."
        case (.reverted, .withinNoise?):
            return "\(subject) changed \(builds) by \(FormatText.deltaText(delta, unit.deltaPct)), inside the noise band\(band), so it is not a real change: reverted."
        case (.reverted, .brokeBuild?):
            return "\(subject) broke the build (a build with the change failed): reverted."
        case (.reverted, .taskSetChanged?):
            return "\(subject) changed which targets or tasks were built, so the times cannot be compared: reverted."
        case (.reverted, .noEffect?):
            return "\(subject) changes no target's effective setting (a higher level sets every key), so nothing was built: reverted."
        case (.reverted, nil):
            return "\(subject) was measured and rejected: reverted."
        case (.indicative, _):
            return "\(subject) changed \(builds) by \(FormatText.deltaText(delta, unit.deltaPct)), but \(runs) run(s) per arm cannot tell that from noise: indicative, never kept (verify again with --runs 5)."
        case (.unverified, _):
            return "\(unit.ruleIds.joined(separator: " + ")) was not measured (the run stopped first): unverified."
        }
    }

    /// The abort reason in plain words, with what to do.
    static func abortSentence(_ abort: VerifyDocument.Abort) -> String {
        switch abort.reason {
        case .dirtyTree: return "A file the plan touches has uncommitted changes: commit them, then run verify again."
        case .onBattery: return "The Mac is on battery, which slows builds unevenly: plug it in, then run verify again."
        case .xcodebuildRunning: return "Another xcodebuild was running: wait for it to finish, then run verify again."
        case .thermal: return "The Mac stayed hot through a run and its replacement: let it cool down, then run verify again."
        case .timeout: return "--max-minutes passed: give more minutes, or verify fewer rules (--rules)."
        case .baselineBroken: return "A build without any change (arm A) failed, so nothing can be compared: fix the build first."
        case .interrupted: return "The run was interrupted; the overlay file was restored."
        case .hookMissing: return "The hook is not installed for this configuration: run xcblame fix --install-hook, or verify with --mechanism cli."
        }
    }

    /// `reaches 2 of 3: AcmeFix (Debug), AcmeKit (Debug); not reached (shadowed): Legacy (Debug): set by targetSettings`.
    static func scopeSummary(_ rows: [FixPlanDocument.ScopeRow], limit: Int = 6) -> String {
        guard !rows.isEmpty else { return "no per-target scope (the oracle did not run)" }
        var order: [String] = []
        var reached: [String: Bool] = [:]
        var why: [String: String] = [:]
        for row in rows {
            let pair = "\(row.target) (\(row.configuration))"
            if reached[pair] == nil { order.append(pair) }
            reached[pair] = (reached[pair] ?? true) && row.reached
            if !row.reached, why[pair] == nil { why[pair] = row.note ?? row.provenance.map { "set by \($0)" } }
        }
        func names(_ list: [String], reasons: Bool) -> String {
            let shown = list.prefix(limit).map { pair in reasons ? pair + (why[pair].map { ": " + $0 } ?? "") : pair }
            return shown.joined(separator: ", ") + (list.count > limit ? ", and \(list.count - limit) more" : "")
        }
        let yes = order.filter { reached[$0] == true }, no = order.filter { reached[$0] != true }
        var out = yes.isEmpty ? "reaches no target" : "reaches \(yes.count) of \(order.count): " + names(yes, reasons: false)
        if !no.isEmpty { out += "; not reached (shadowed): " + names(no, reasons: true) }
        return out
    }

    /// What to run after a verify run: apply the kept hook steps, re-measure the indicative ones, resume after an abort.
    static func nextCommands(_ verify: VerifyDocument) -> [String] {
        var out: [String] = []
        let kept = verify.results.filter { $0.verdict.status == .kept }
        let hookKept = kept.filter { $0.mechanism != .cli }.flatMap(\.ruleIds)
        if !hookKept.isEmpty { out.append("xcblame fix --rules \(hookKept.joined(separator: ",")) --apply") }
        let cliKept = kept.filter { $0.mechanism == .cli }.flatMap(\.ruleIds)
        if !cliKept.isEmpty { out.append("xcblame verify --rules \(cliKept.joined(separator: ",")) --mechanism hook") }
        let indicative = verify.results.filter { $0.verdict.status == .indicative }.flatMap(\.ruleIds)
        if !indicative.isEmpty { out.append("xcblame verify --rules \(indicative.joined(separator: ",")) --runs 5") }
        if verify.abort != nil { out.append("xcblame verify --plan \(verify.planId)") }
        return out
    }
}
