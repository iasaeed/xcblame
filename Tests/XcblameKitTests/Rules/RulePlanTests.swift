import XCTest
@testable import XcblameKit

/// `RulePlan.ordered`: a guard comes before every finding that assumes it; everything else keeps its order.
final class RulePlanTests: XCTestCase {
    private func finding(_ id: String, _ key: String = "") -> ReportDocument.Finding {
        .init(ruleId: id, title: id, severity: "medium", impactBand: "?", impactSeconds: nil, impactBasis: nil,
              confidence: "medium", evidence: [], fixKind: "project", risk: nil, mechanism: nil, signalKey: id + key)
    }

    func testGuardsMoveBeforeTheEditsThatAssumeThem() {
        let list = [finding("SET-001"), finding("SET-004"), finding("SET-030"), finding("SET-005"),
                    finding("PHASE-001", "a"), finding("PHASE-002"), finding("PHASE-001", "b"), finding("DEP-001")]
        let ordered = RulePlan.ordered(list).map { $0.ruleId + $0.signalKey.dropFirst($0.ruleId.count) }
        XCTAssertEqual(ordered, ["SET-001", "PHASE-002", "SET-004", "PHASE-001a", "PHASE-001b", "SET-030", "SET-005", "DEP-001"])
        // Without the guard in the list nothing moves.
        XCTAssertEqual(RulePlan.ordered([finding("SET-004"), finding("SET-001")]).map(\.ruleId), ["SET-004", "SET-001"])
        // The plan follows the same order, with the verify step before each build-setting edit.
        let plan = ReportDocument.fixPlan(list.map { var f = $0; f.fixCommands = ["xcblame fix --rules \(f.ruleId) --edit-project"]; return f })
        let fixes = plan.filter { $0.kind == "fix" }.map(\.ruleId)
        XCTAssertLessThan(fixes.firstIndex(of: "PHASE-002")!, fixes.firstIndex(of: "SET-004")!)
        XCTAssertLessThan(fixes.lastIndex(of: "PHASE-001")!, fixes.firstIndex(of: "SET-030")!)
    }
}
