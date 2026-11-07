import XCTest
@testable import XcblameKit

/// The FIXED COSTS text block (docs/SCHEMA-v0.5.md "Text").
final class FixedCostsTextTests: XCTestCase {
    private func document() throws -> ReportDocument {
        try ReportPipeline.run(FixedCostsTests.syntheticWithEveryBuildScript(),
                               options: .init(generatedAt: Date(timeIntervalSince1970: 0))).document
    }

    func testTextBlockLabelsTheAssumption() throws {
        let lines = TextReporter().fixedCostLines(try document())
        XCTAssertTrue(lines[0].hasSuffix("(assumption: 50 builds/day)"), lines[0])
        XCTAssertTrue(lines.contains { $0.hasPrefix("  scripts ") && $0.contains("100.0 s") && $0.contains("static") })
        var configured = try document()
        configured = FixedCosts.applying(entries: [], configBuildsPerDay: 20, to: configured)
        XCTAssertTrue(TextReporter().fixedCostLines(configured)[0].hasSuffix("(20 builds/day from config.json)"))
        let now = Date(timeIntervalSince1970: 0)
        let history = (0..<6).map { FixedCosts.HistoryEntry(time: now.addingTimeInterval(-Double($0) * 60), scheme: nil,
                                                            kind: "incremental", rows: []) }
        let fromHistory = FixedCosts.applying(entries: history, configBuildsPerDay: nil, to: try document())
        XCTAssertTrue(TextReporter().fixedCostLines(fromHistory)[0].hasSuffix("(6 builds per active day from history)"),
                      TextReporter().fixedCostLines(fromHistory)[0])
        var none = try document()
        none.fixedCosts = nil
        XCTAssertEqual(TextReporter().fixedCostLines(none), [])
    }
}
