import XCTest
import XcblameKit

/// Lane B's compare, baseline and regression CLI tests are in `CompareFlowCLITests`; trend tests are in `Trend*Tests`.
final class CompareCLITests: XCTestCase {
    private func dumpModel() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-model-\(UUID().uuidString).json")
        try JSONEncoder().encode(SyntheticModel.make()).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testUsageErrorsExitTwo() throws {
        let cli = CLIRunner(test: self)
        XCTAssertEqual(try cli.run(["trend", "--by", "colour"]).status, 2)
        XCTAssertEqual(try cli.run(["compare", "a", "b", "--format", "junit"]).status, 2)
        XCTAssertEqual(try cli.run(["compare", "a", "b", "--format", "sarif"]).status, 2)
        XCTAssertEqual(try cli.run(["analyze", "--fail-if-slower", "5"]).status, 2)
    }

    func testBaselineFlagsAreAcceptedByAnalyzeAndBuild() throws {
        let cli = CLIRunner(test: self)
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-state-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: state) }
        let result = try cli.run(["analyze", "--model-json", try dumpModel().path, "--no-history", "--xcblame-dir", state.path,
                                  "--baseline", "/nonexistent/baseline.json", "--fail-if-slower", "5"])
        XCTAssertEqual(result.status, 5, result.err)
        XCTAssertTrue(result.err.contains("/nonexistent/baseline.json"), result.err)
        let help = try cli.run(["build", "--help"])
        XCTAssertTrue(help.out.contains("--baseline") && help.out.contains("--fail-if-slower"), help.out)
    }

    // v0.4 integration: compare renders markdown, github and agent (junit stays a usage error).
    func testCompareRendersMarkdownGithubAndAgent() throws {
        let cli = CLIRunner(test: self)
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/logs")
        let a = fixtures.appendingPathComponent("cli-xcode26/20E8B73D-96FE-4232-8A33-311BFD02F961.xcactivitylog").path
        let b = fixtures.appendingPathComponent("cli-xcode27.1b/21F7B51C-4B90-49D4-B328-EDA168F7A9A5.xcactivitylog").path
        let summary = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-summary-\(UUID().uuidString).md")
        addTeardownBlock { try? FileManager.default.removeItem(at: summary) }

        let markdown = try cli.run(["compare", a, b, "--format", "markdown"])
        XCTAssertEqual(markdown.status, 0, markdown.err)
        XCTAssertTrue(markdown.out.hasPrefix(MarkdownReporter.marker + "\n## xcblame compare: AcmeApp clean"), markdown.out)
        XCTAssertTrue(markdown.out.contains("### Environment"), markdown.out)
        XCTAssertLessThanOrEqual(markdown.out.utf8.count, 64 * 1024)

        let github = try cli.run(["compare", a, b, "--format", "github"], environment: ["GITHUB_STEP_SUMMARY": summary.path])
        XCTAssertEqual(github.status, 0, github.err)
        XCTAssertEqual(github.out, markdown.out, "compare has no annotations: the body is the markdown")
        XCTAssertFalse(github.err.contains("::"), github.err)
        XCTAssertEqual(try String(contentsOf: summary, encoding: .utf8), github.out + "\n")

        let agent = try cli.run(["compare", a, b, "--format", "agent"])
        XCTAssertEqual(agent.status, 0, agent.err)
        XCTAssertFalse(agent.out.contains(MarkdownReporter.marker))
        XCTAssertTrue(agent.out.hasPrefix("## xcblame compare: AcmeApp clean"), agent.out)
        XCTAssertLessThanOrEqual(agent.out.utf8.count, 8 * 1024)
    }

    // v0.4 integration: a log operand carries the build context (scheme from the manifest) that baseline keys match on.
    func testLogOperandCarriesBuildContext() throws {
        let cli = CLIRunner(test: self)
        let log = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/logs/cli-xcode26/20E8B73D-96FE-4232-8A33-311BFD02F961.xcactivitylog").path
        let json = try cli.run(["compare", log, log, "--format", "json"])
        XCTAssertEqual(json.status, 0, json.err)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any])
        for side in ["a", "b"] {
            XCTAssertEqual((object[side] as? [String: Any])?["scheme"] as? String, "AcmeApp", json.out)
        }
        let baseline = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-baseline-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: baseline) }
        XCTAssertEqual(try cli.run(["baseline", "save", "--from", log, "-o", baseline.path]).status, 0)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: baseline)) as? [String: Any])
        XCTAssertEqual((saved["key"] as? [String: Any])?["scheme"] as? String, "AcmeApp")
    }
}
