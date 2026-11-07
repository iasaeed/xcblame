import Foundation

/// Confidence, impact band and severity policy (DESIGN §7.1, RULES.md §0).
enum Confidence {
    static let levels = ["low", "medium", "high"]

    /// high = [P] mechanism AND cost measured on this build; medium = [S] (or mixed P/S) with a measured cost, or
    /// [P]/[S] static-only; low = any [K] part. `doctor` never measures, so it never says high. An offline source
    /// lowers the result one step.
    static func level(tag: RuleSpec.EvidenceTag, measured: Bool, lowered: Bool) -> String {
        var index: Int
        if tag.isKnowledgeGated { index = 0 } else if measured && tag == .primary { index = 2 } else { index = 1 }
        if lowered { index = max(0, index - 1) }
        return levels[index]
    }

    static let bands = ["?", "XS", "S", "M", "L"]

    /// `XS` < 1 s or < 2 %, `S` 1-5 s or 2-10 %, `M` 5-30 s or 10-30 %, `L` > 30 s or > 30 %; with both numbers the
    /// larger band wins (a 0.6 s script that is 40 % of a zero-change build matters). `?` when nothing was measured.
    static func band(seconds: Double?, share: Double?) -> String {
        func bySeconds(_ s: Double) -> Int { s < 1 ? 1 : s < 5 ? 2 : s <= 30 ? 3 : 4 }
        func byShare(_ x: Double) -> Int { x < 0.02 ? 1 : x < 0.10 ? 2 : x <= 0.30 ? 3 : 4 }
        let rank = max(seconds.map(bySeconds) ?? 0, share.map(byShare) ?? 0)
        return bands[rank]
    }

    static func bandRank(_ band: String?) -> Int { bands.firstIndex(of: band ?? "?") ?? 0 }

    /// Severity policy (`RuleSpec.severity` is the default): a [K]-gated rule is at most `low`; a measured `L` band
    /// raises to `high`, `M` to at least `medium`; a predicate may override per signal (Xcode 27 makes SET-027
    /// `high`).
    static func severity(_ spec: RuleSpec, override: RuleSpec.Severity?, band: String) -> RuleSpec.Severity {
        var severity = override ?? spec.severity
        if band == "L" { severity = max(severity, .high) } else if band == "M" { severity = max(severity, .medium) }
        if spec.evidenceTag.isKnowledgeGated { severity = min(severity, .low) }
        return severity
    }

    /// "Needs measurement": any [K] part, or a `+V` rule whose impact was not measured on this build.
    static func needsMeasurement(_ spec: RuleSpec, band: String) -> Bool {
        spec.evidenceTag.isKnowledgeGated || (spec.verifyOnly && band == "?")
    }
}
