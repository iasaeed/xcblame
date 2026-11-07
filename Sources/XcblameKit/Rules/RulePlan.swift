import Foundation

/// The order of the fix plan (DESIGN §7.3, v0.5 clarity): guards before the edits that assume them, a measurement
/// before every project edit, and the manual steps a finding names in Xcode.
public enum RulePlan {
    /// Rule → rules whose fix must come first. SET-004 switches Debug to `dwarf`, which breaks a dSYM upload script
    /// until PHASE-002 guards it to Release; SET-030 (fuse script phases) assumes PHASE-001 declared the outputs.
    public static let prerequisites: [String: [String]] = ["SET-004": ["PHASE-002"], "SET-030": ["PHASE-001"]]

    /// `findings` with every finding moved after the findings of its prerequisite rules; otherwise the order is kept.
    public static func ordered(_ findings: [ReportDocument.Finding]) -> [ReportDocument.Finding] {
        var placed: [Int] = []
        var done = Set<Int>()
        func place(_ index: Int, _ visiting: Set<Int>) {
            guard !done.contains(index), !visiting.contains(index) else { return }
            for rule in prerequisites[findings[index].ruleId] ?? [] {
                for other in findings.indices where findings[other].ruleId == rule { place(other, visiting.union([index])) }
            }
            done.insert(index)
            placed.append(index)
        }
        for index in findings.indices { place(index, []) }
        return placed.map { findings[$0] }
    }

    /// A finding is housekeeping (not an action) only when it has no band at all: neither measured on a build nor
    /// estimated by the catalog. Confidence is shown on each action but never demotes a finding with a band, so an
    /// offline doctor run lists the same actions as an online one.
    public static func isHousekeeping(_ finding: ReportDocument.Finding) -> Bool {
        finding.effectiveBand == nil
    }
}
