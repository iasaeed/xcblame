import XCTest
@testable import XcblameKit

/// `ReportPipeline.renderFormat` and the per-format defaults (`ReportBudget.Format`).
final class FormatsRoutingTests: XCTestCase {
    func testRoutingReachesEachReporterAndRefusesTheOthers() throws {
        let document = try FormatsFixtures.report()
        let options = FormatOptions(maxBytes: 64 * 1024)
        let markdown = try ReportPipeline.renderFormat(document, format: .markdown, options: options)
        XCTAssertEqual(markdown.body, try MarkdownReporter.render(document, options: options))
        XCTAssertEqual(markdown.annotations, [])
        let github = try ReportPipeline.renderFormat(document, format: .github, options: options)
        XCTAssertEqual(github.body, markdown.body, "the github body is the markdown body")
        XCTAssertFalse(github.annotations.isEmpty)
        XCTAssertTrue(try ReportPipeline.renderFormat(document, format: .junit, options: options).body.hasPrefix("<?xml"))
        XCTAssertTrue(try ReportPipeline.renderFormat(document, format: .agent, options: options).body.hasPrefix("xcblame "))
        for format in [ReportBudget.Format.text, .json, .html] {
            XCTAssertThrowsError(try ReportPipeline.renderFormat(document, format: format, options: options))
        }
    }

    func testBudgetsAndRedactDefaultsPerFormat() {
        typealias F = ReportBudget.Format
        XCTAssertEqual(F.markdown.defaultMaxBytes, 64 * 1024)
        XCTAssertEqual(F.github.defaultMaxBytes, 64 * 1024)
        XCTAssertEqual(F.agent.defaultMaxBytes, 8 * 1024)
        XCTAssertEqual(F.junit.defaultMaxBytes, .max)
        XCTAssertEqual(F.json.defaultMaxBytes, 2_000_000)
        XCTAssertEqual(F.html.defaultMaxBytes, 8_000_000)
        XCTAssertEqual(F.allCases.filter(\.redactsByDefault).map(\.rawValue).sorted(), ["agent", "github", "html", "markdown"])
        XCTAssertEqual(F.allCases.filter(\.isV04TextFormat).map(\.rawValue).sorted(), ["agent", "github", "junit", "markdown"])
        XCTAssertEqual(JUnitReporter.Budgets(), JUnitReporter.Budgets(wall: nil, incremental: nil, criticalPath: nil, targets: nil))
    }

    func testFormatsAreByteEqualAcrossRunsAndKeepOneTrailingNewline() throws {
        let document = FormatsFixtures.redacted(try FormatsFixtures.report())
        let options = FormatOptions(maxBytes: 64 * 1024, workspaceRoot: FormatsFixtures.repo)
        for format in [ReportBudget.Format.markdown, .github, .junit, .agent] {
            let first = try ReportPipeline.renderFormat(document, format: format, options: options)
            let second = try ReportPipeline.renderFormat(document, format: format, options: options)
            XCTAssertEqual(first, second, format.rawValue)
            XCTAssertTrue(first.body.hasSuffix("\n") && !first.body.hasSuffix("\n\n"), format.rawValue)
            XCTAssertFalse(first.body.contains("\r"), format.rawValue)
            XCTAssertFalse(first.body.contains("\u{1B}"), format.rawValue)
        }
    }
}
