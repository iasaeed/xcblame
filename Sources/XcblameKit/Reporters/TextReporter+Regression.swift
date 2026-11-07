import Foundation

extension TextReporter {
    /// The `REGRESSION` section of the text report (docs/SCHEMA-v0.4.md "Regression"): empty without
    /// `doc.regression`. The same block heads `xcblame compare` (`CompareTextReporter`).
    func regressionLines(_ doc: ReportDocument) -> [String] {
        guard let regression = doc.regression else { return [] }
        return regressionBlock(regression, title: "REGRESSION")
    }

    /// Verdict and headline delta, the noise band, busy and critical path, the threshold result, then why: the
    /// attribution, environment first.
    func regressionBlock(_ r: ReportDocument.Regression, title: String, against override: String? = nil,
                         attributionLimit: Int = 6) -> [String] {
        let lead = bold(title) + "  "
        let pad = String(repeating: " ", count: title.count + 2)
        var lines: [String] = []

        let against: String
        switch override == nil ? r.baseline.source : "override" {
        case "override": against = override ?? ""
        case "file": against = "baseline file " + (r.baseline.ref.map(safe) ?? "")
        case "history": against = "history " + (r.baseline.ref.map(safe) ?? "")
        default: against = r.baseline.ref.map(safe) ?? "the reference"
        }
        let runs = "\(r.baseline.runs) run\(r.baseline.runs == 1 ? "" : "s")"
        let verdict = r.verdict == "slower" ? warn(r.verdict) : r.verdict
        lines.append(lead + "\(verdict): wall \(deltaText(r.wall)) vs \(against.trimmingCharacters(in: .whitespaces)) "
            + "(\(runs), \(r.wallBasis == "processWall" ? "process wall" : "log span"))")

        let noise = r.noiseBand
        if noise.method == "mad", let band = noise.band, let pooled = noise.pooledMad {
            lines.append(pad + "noise band \(Self.duration(band)): 3 x pooled MAD \(Self.duration(pooled)), at least "
                + String(format: "%.0f %%", noise.minPct * 100) + " of the baseline; "
                + "\(noise.runsCurrent) runs now, \(noise.runsBaseline) in the baseline")
        } else {
            lines.append(pad + "no noise band: \(noise.runsCurrent) run\(noise.runsCurrent == 1 ? "" : "s") now, "
                + "\(noise.runsBaseline) in the baseline (3 on each side give a band); the verdict is indicative, a likely "
                + "difference: rerun with xcblame build --runs 3 -- <xcodebuild args>, or three builds and baseline save --last 3")
        }
        lines.append(pad + "busy \(deltaText(r.busy)) · critical path \(deltaText(r.criticalPath))")
        if let threshold = r.thresholdPct {
            var text = "threshold " + String(format: "%g %%", threshold * 100)
            if r.verdict == "indicative" { text += String(format: " + %g %% allowance (indicative)", r.allowancePct * 100) }
            text += r.failed ? ": " + fail("FAILED") : ": ok"
            lines.append(pad + text)
        }
        for note in r.notes where !note.hasPrefix("indicative:") { lines.append(pad + dim(safe(note))) }
        if !r.attribution.isEmpty {
            let shown = r.attribution.prefix(attributionLimit)
            for (index, item) in shown.enumerated() {
                lines.append((index == 0 ? pad + "why  " : pad + "     ") + "\(item.kind) \(safe(item.subject)): \(safe(item.detail))")
            }
            if r.attribution.count > shown.count {
                lines.append(pad + "     " + dim("(\(r.attribution.count - shown.count) more in the JSON)"))
            }
        }
        return lines
    }

    /// `+900 ms (+5.2 %)`; `unknown` when there is no delta.
    func deltaText(_ delta: ReportDocument.Regression.Delta) -> String {
        guard let change = delta.delta else { return "unknown" }
        var text = Regression.signed(change)
        if let share = delta.deltaPct { text += String(format: " (%+.1f %%)", share * 100) }
        return text
    }
}
