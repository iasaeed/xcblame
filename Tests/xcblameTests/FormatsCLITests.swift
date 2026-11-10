import XCTest
import XcblameKit

/// The four v0.4 text formats and `xcblame schema` through the built binary.
final class FormatsCLITests: XCTestCase {
    private func dumpModel() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-model-\(UUID().uuidString).json")
        try JSONEncoder().encode(SyntheticModel.make()).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func analyze(_ format: String, _ extra: [String] = [], environment: [String: String] = [:]) throws -> CLIRunner.Run {
        try CLIRunner(test: self).run(["analyze", "--model-json", try dumpModel().path, "--no-history", "--format", format] + extra,
                                      environment: environment)
    }

    func testMarkdownIsTheStickyCommentBody() throws {
        let result = try analyze("markdown")
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.hasPrefix("<!-- xcblame:report -->\n## xcblame: "), result.out)
        XCTAssertTrue(result.out.contains("No baseline: pass `--baseline .xcblame/baseline.json` to compare."))
        XCTAssertTrue(result.out.contains("### Critical path"))
        XCTAssertTrue(result.out.hasSuffix("redacted</sub>\n"), "markdown redacts by default")
        let unredacted = try analyze("markdown", ["--no-redact"])
        XCTAssertTrue(unredacted.out.hasSuffix("xcblame.report/1</sub>\n"), unredacted.out)
    }

    /// DESIGN §11 v0.4 exit criterion: the PR comment of a 500-target synthetic log stays within 64 KB, with the default
    /// rows and with every row (`--top all`), through the CLI.
    func testFiveHundredTargetCommentFitsTheCapThroughTheCLI() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-model-\(UUID().uuidString).json")
        try JSONEncoder().encode(SyntheticModel.large(taskCount: 4_000, targets: 500)).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var sizes: [String: Int] = [:]
        for (label, extra) in [("default", [String]()), ("top all", ["--top", "all"])] {
            for format in ["markdown", "github"] {
                let result = try CLIRunner(test: self).run(["analyze", "--model-json", url.path, "--no-history", "--format", format] + extra)
                XCTAssertEqual(result.status, 0, result.err)
                XCTAssertLessThanOrEqual(result.out.utf8.count, 64 * 1024, "\(format) \(label)")
                XCTAssertTrue(result.out.contains("### Targets"), "\(format) \(label)")
                sizes["\(format) \(label)"] = result.out.utf8.count
            }
        }
        print("500-target comment bytes: \(sizes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", "))")
    }

    func testGithubWritesAnnotationsToStderrAndTheBodyToStdout() throws {
        let result = try analyze("github")
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.hasPrefix("<!-- xcblame:report -->\n"))
        XCTAssertFalse(result.out.contains("::warning"), "stdout stays the pure comment body")
        XCTAssertTrue(result.err.contains("::warning file=Sources/App/App2.swift,line=12,col=9,title=xcblame::variable 'x' was never mutated"), result.err)
        let markdown = try analyze("markdown")
        XCTAssertEqual(result.out, markdown.out, "the same body as markdown")
    }

    func testGithubAppendsTheBodyToTheStepSummaryNeverTruncatingIt() throws {
        let summary = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-summary-\(UUID().uuidString).md")
        try Data("earlier step\n".utf8).write(to: summary)
        addTeardownBlock { try? FileManager.default.removeItem(at: summary) }
        let first = try analyze("github", environment: ["GITHUB_STEP_SUMMARY": summary.path])
        XCTAssertEqual(first.status, 0, first.err)
        let once = try String(contentsOf: summary, encoding: .utf8)
        XCTAssertTrue(once.hasPrefix("earlier step\n<!-- xcblame:report -->\n"), once)
        XCTAssertTrue(once.hasSuffix(first.out + "\n"))
        _ = try analyze("github", environment: ["GITHUB_STEP_SUMMARY": summary.path])
        let twice = try String(contentsOf: summary, encoding: .utf8)
        XCTAssertTrue(twice.hasPrefix(once), "append, never truncate")
        XCTAssertEqual(twice.components(separatedBy: "<!-- xcblame:report -->").count, 3)
        // A file that does not exist yet is created.
        let fresh = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-summary-\(UUID().uuidString).md")
        addTeardownBlock { try? FileManager.default.removeItem(at: fresh) }
        _ = try analyze("github", environment: ["GITHUB_STEP_SUMMARY": fresh.path])
        XCTAssertTrue(try String(contentsOf: fresh, encoding: .utf8).hasPrefix("<!-- xcblame:report -->"))
        // markdown never touches it.
        let untouched = try analyze("markdown", environment: ["GITHUB_STEP_SUMMARY": summary.path])
        XCTAssertEqual(untouched.status, 0)
        XCTAssertEqual(try String(contentsOf: summary, encoding: .utf8), twice)
    }

    func testJUnitIsWellFormedXML() throws {
        let result = try analyze("junit")
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuites name=\"xcblame\" tests=\"1\""))
        let parser = XMLParser(data: Data(result.out.utf8))
        XCTAssertTrue(parser.parse(), "\(String(describing: parser.parserError))")
    }

    func testJUnitReadsBudgetsFromTheXcblameDir() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        try Data(#"{"budgets": {"wall": 1}}"#.utf8).write(to: directory.appendingPathComponent("config.json"))
        let result = try analyze("junit", ["--xcblame-dir", directory.path])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.contains("tests=\"2\" failures=\"1\""), result.out)
        XCTAssertTrue(result.out.contains("exceeds budget 1.00 s"))
    }

    func testAgentStaysUnderItsCapAndMaxReportBytesOverridesIt() throws {
        let result = try analyze("agent")
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.hasPrefix("xcblame 0.6.1 agent report (xcblame.report/1)\nresult: "), result.out)
        XCTAssertLessThanOrEqual(result.out.utf8.count, 8192)
        let tiny = try analyze("agent", ["--max-report-bytes", "300"])
        XCTAssertLessThanOrEqual(tiny.out.utf8.count, 301, "the final newline the CLI adds at most")
        XCTAssertTrue(tiny.out.contains("[truncated]"))
        let markdown = try analyze("markdown", ["--max-report-bytes", "700"])
        XCTAssertLessThanOrEqual(markdown.out.utf8.count, 700)
        XCTAssertTrue(markdown.out.contains("_Truncated to fit 700 bytes"), markdown.out)
    }

    func testSarifAndChromeTraceStayUnknown() throws {
        XCTAssertEqual(try analyze("sarif").status, 2)
    }

    // MARK: schema

    func testSchemaPrintsTheReportSchemaByDefault() throws {
        let result = try CLIRunner(test: self).run(["schema"])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertEqual(result.out, try JSONSchema.render(.report))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any])
        XCTAssertEqual(object["$id"] as? String, "urn:xcblame:schema:report:1")
        XCTAssertEqual(object["$schema"] as? String, "https://json-schema.org/draft/2020-12/schema")
    }

    func testSchemaDocumentsAndVersions() throws {
        let cli = CLIRunner(test: self)
        for document in ["report", "compare", "trend", "baseline", "fixplan", "verify", "all"] {
            let result = try cli.run(["schema", "--version", "1", "--document", document])
            XCTAssertEqual(result.status, 0, "\(document): \(result.err)")
            XCTAssertEqual(result.out, try JSONSchema.render(JSONSchema.Document(rawValue: document)!))
        }
        let bad = try cli.run(["schema", "--version", "2"])
        XCTAssertEqual(bad.status, 2)
        XCTAssertTrue(bad.err.contains("known: 1"), bad.err)
        XCTAssertEqual(try cli.run(["schema", "--document", "nope"]).status, 2)
    }

    func testRealReportJSONValidatesAgainstTheSchemaFromTheCLI() throws {
        let json = try analyze("json")
        XCTAssertEqual(json.status, 0, json.err)
        let schema = try CLIRunner(test: self).run(["schema"])
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any])
        let required = try XCTUnwrap((JSONSerialization.jsonObject(with: Data(schema.out.utf8)) as? [String: Any])?["required"] as? [String])
        XCTAssertEqual(required.filter { report[$0] == nil }, [], "every required member is in a real report")
    }
}
