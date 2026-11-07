import XCTest
@testable import XcblameKit

/// The MODULE GRAPH text block (docs/SCHEMA-v0.5.md "Text") on the cli-xcode26-dd snapshot.
final class ModuleGraphTextTests: XCTestCase {
    private func ddDocument() throws -> ReportDocument {
        try GraphFixtures.report(try GraphFixtures.model(GraphFixtures.cleanDD),
                                 description: try BuildDescription.load(directory: GraphFixtures.descriptionDD)).document
    }

    func testTextBlock() throws {
        let lines = TextReporter().moduleGraphLines(try ddDocument())
        XCTAssertEqual(lines.first, "MODULE GRAPH  10 targets · source targetGraph · depth 4")
        XCTAssertTrue(lines.contains { $0.hasPrefix("  longest chain  SwiftSyntax510 112 ms → SwiftSyntax 2.5 s") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.hasPrefix("  blockers       SwiftSyntax509 gates 107.3 s") }, "\(lines)")
        XCTAssertTrue(lines.contains("  variants       64 modules, 79 redundant PCM tasks, 7.0 s (swiftPackage, languageMode)"),
                      "\(lines)")
        var none = try ddDocument()
        none.moduleGraph = nil
        XCTAssertEqual(TextReporter().moduleGraphLines(none), [])
    }
}
