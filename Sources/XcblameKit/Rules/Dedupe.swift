import Foundation

/// Signal-key dedupe and fix-plan order (RULES.md §10, docs/SCHEMA-v0.3.md invariants 1, 2 and 5).
enum Dedupe {
    struct Candidate {
        var finding: ReportDocument.Finding
        var spec: RuleSpec
    }

    /// One finding per `signalKey`. The winner has a fix kind other than `recommend`/`measure`, else the higher
    /// category (SET > PHASE > DEP > GRAPH > SRC > ENV > DYN > CI), else the lower id; the others are listed in its
    /// `seeAlso` and, when the losing rule has no other finding, in `suppressed` with the winner named.
    static func apply(_ candidates: [Candidate]) -> (findings: [Candidate], suppressed: [RuleOutcome]) {
        var groups: [String: [Candidate]] = [:]
        var keys: [String] = []
        for candidate in candidates {
            if groups[candidate.finding.signalKey] == nil { keys.append(candidate.finding.signalKey) }
            groups[candidate.finding.signalKey, default: []].append(candidate)
        }
        var winners: [Candidate] = []
        var losers: [(candidate: Candidate, winner: String, key: String)] = []
        for key in keys {
            let group = groups[key]!.sorted { rank($0) < rank($1) }
            var winner = group[0]
            for loser in group.dropFirst() where loser.spec.id != winner.spec.id {
                if !winner.finding.seeAlso.contains(loser.spec.id) { winner.finding.seeAlso.append(loser.spec.id) }
                losers.append((loser, winner.spec.id, key))
            }
            winners.append(winner)
        }
        let kept = Set(winners.map(\.spec.id))
        var suppressed: [RuleOutcome] = []
        for loser in losers where !kept.contains(loser.candidate.spec.id)
            && !suppressed.contains(where: { $0.ruleId == loser.candidate.spec.id }) {
            suppressed.append(RuleOutcome(ruleId: loser.candidate.spec.id, title: loser.candidate.spec.name,
                                          detail: "same signal as \(loser.winner) (\(loser.key))"))
        }
        return (winners, suppressed)
    }

    private static func rank(_ candidate: Candidate) -> (Int, Int, String) {
        let passive = ["recommend", "measure"].contains(candidate.finding.fixKind ?? "recommend") ? 1 : 0
        return (passive, candidate.spec.category.dedupeRank, candidate.spec.id)
    }

    /// Fix-plan order: measured before "needs measurement", then impact band and seconds, then category, id, key.
    static func ordered(_ findings: [Candidate]) -> [Candidate] {
        findings.sorted { lhs, rhs in
            let a = lhs.finding, b = rhs.finding
            if a.needsMeasurement != b.needsMeasurement { return !a.needsMeasurement }
            let bandA = Confidence.bandRank(a.impactBand), bandB = Confidence.bandRank(b.impactBand)
            if bandA != bandB { return bandA > bandB }
            if (a.impactSeconds ?? -1) != (b.impactSeconds ?? -1) { return (a.impactSeconds ?? -1) > (b.impactSeconds ?? -1) }
            if lhs.spec.category.dedupeRank != rhs.spec.category.dedupeRank {
                return lhs.spec.category.dedupeRank < rhs.spec.category.dedupeRank
            }
            if a.ruleId != b.ruleId { return a.ruleId < b.ruleId }
            return a.signalKey < b.signalKey
        }
    }
}
