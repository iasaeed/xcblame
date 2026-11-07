import XCTest
import XcblameKit

/// Regression tests for the v0.4 code review and its verifier findings, through the built binary
/// (docs/reviews/code-review-v0.4.md; docs/SCHEMA-v0.4.md "Fix notes").
final class ReviewFixesCLITests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/logs")
    private let log26 = fixtures.appendingPathComponent("cli-xcode26/20E8B73D-96FE-4232-8A33-311BFD02F961.xcactivitylog").path

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-review-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - M1: baseline from a log, gate on a build

    /// `baseline save --from <log>` records the destination from the build request (`macOS arm64`); `build` reads it from
    /// `-destination platform=macOS` (`macOS`). They are the same build: no exit 2.
    func testBaselineFromALogMatchesABuildWithADestinationArgument() throws {
        let cli = CLIRunner(test: self)
        let harness = try BuildCLIHarness.make(for: self)
        // The fake build leaves a log and its build description in DerivedData, as a real one does.
        XCTAssertEqual(try harness.build(self, ["--no-history"]).status, 0)
        let log = harness.derivedData.appendingPathComponent("Logs/Build/\(BuildCLIHarness.logUUID).xcactivitylog").path
        let baseline = harness.directory.appendingPathComponent("baseline.json")
        let saved = try cli.run(["baseline", "save", "--from", log, "-o", baseline.path])
        XCTAssertEqual(saved.status, 0, saved.err)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: baseline)) as? [String: Any])
        var key = try XCTUnwrap(object["key"] as? [String: Any])
        XCTAssertEqual(key["destination"] as? String, "macOS arm64", "from the build request")
        key["scheme"] = "App"  // the fake build is run with -scheme App; the fixture log carries its own project's scheme
        object["key"] = key
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: baseline)

        let result = try harness.run(self, ["build", "--baseline", baseline.path, "--fail-if-slower", "5000", "--no-history",
                                            "--", "-scheme", "App", "-destination", "platform=macOS",
                                            "-derivedDataPath", harness.derivedData.path])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertFalse(result.err.contains("destination differs"), result.err)
        XCTAssertTrue(result.out.contains("REGRESSION"), "the baseline was evaluated:\n\(result.out)")
    }

    // MARK: - M4: the gate fails closed when the analysis fails

    private func bogusLogScript(in harness: BuildCLIHarness) throws -> URL {
        let script = harness.directory.appendingPathComponent("bogus-xcodebuild.sh")
        let lines = ["#!/bin/sh", "mkdir -p '\(harness.derivedData.path)/Logs/Build'",
                     "echo 'not an activity log' > '\(harness.derivedData.path)/Logs/Build/\(UUID().uuidString).xcactivitylog'",
                     "exit 0"]
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func testAnalysisFailureWithABaselineExitsOneEvenInXcodebuildMode() throws {
        for bogus in [false, true] {
            let harness = try BuildCLIHarness.make(for: self, writeLog: false)
            let baseline = harness.directory.appendingPathComponent("baseline.json")
            try Data("{}".utf8).write(to: baseline)
            let environment = bogus ? ["XCBLAME_XCODEBUILD": try bogusLogScript(in: harness).path] : [:]
            let gated = try harness.run(self, ["build", "--baseline", baseline.path, "--fail-if-slower", "5", "--",
                                               "-scheme", "App", "-derivedDataPath", harness.derivedData.path],
                                        environment: environment)
            XCTAssertEqual(gated.status, 1, "bogus log: \(bogus)\n\(gated.err)")
            XCTAssertTrue(gated.err.contains("build analysis unavailable"), gated.err)
            XCTAssertTrue(gated.err.contains("baseline was not evaluated"), gated.err)
            // Without a baseline xcodebuild's own code is still the exit code.
            let plain = try harness.run(self, ["build", "--", "-scheme", "App", "-derivedDataPath", harness.derivedData.path],
                                        environment: environment)
            XCTAssertEqual(plain.status, 0, plain.err)
        }
        // xcodebuild's own failure wins over the gate.
        let failed = try BuildCLIHarness.make(for: self, exitCode: 65, writeLog: false)
        let result = try failed.build(self, ["--baseline", failed.directory.appendingPathComponent("b.json").path, "--fail-if-slower", "5"])
        XCTAssertEqual(result.status, 65, result.err)
    }

    // MARK: - analyze <history id>

    func testAnalyzeReRendersAHistoryEntryById() throws {
        let cli = CLIRunner(test: self)
        let state = try scratch()
        let first = try cli.run(["analyze", log26, "--no-rules", "--no-env", "--xcblame-dir", state.path, "--format", "json"])
        XCTAssertEqual(first.status, 0, first.err)
        let id = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: state.appendingPathComponent("history").path)
            .first { $0.hasSuffix(".json.gz") }).replacingOccurrences(of: ".json.gz", with: "")
        for argument in [id, String(id.prefix(15))] {
            let json = try cli.run(["analyze", argument, "--xcblame-dir", state.path, "--format", "json", "--no-redact"])
            XCTAssertEqual(json.status, 0, json.err)
            let document = try JSONReporter.decoder().decode(ReportDocument.self, from: Data(json.out.utf8))
            let original = try JSONReporter.decoder().decode(ReportDocument.self, from: Data(first.out.utf8))
            XCTAssertEqual(document.build.span, original.build.span)
            XCTAssertEqual(document.build.tasks, original.build.tasks)
            let markdown = try cli.run(["analyze", argument, "--xcblame-dir", state.path, "--format", "markdown"])
            XCTAssertEqual(markdown.status, 0, markdown.err)
            XCTAssertTrue(markdown.out.hasPrefix("<!-- xcblame:report -->"), markdown.out)
        }
        XCTAssertEqual(try cli.run(["analyze", "19990101-000000", "--xcblame-dir", state.path]).status, 5)
        let help = try cli.run(["analyze", "--help"])
        XCTAssertTrue(help.out.contains("history entry id"), help.out)
    }

    // MARK: - annotations survive redaction

    /// `GITHUB_WORKSPACE` is not the working directory's repository (here there is none): the repo-relative path is taken
    /// before redaction rewrites the home, so redaction on or off gives the same annotations.
    func testAnnotationsKeepTheirFilesWhenRedactionIsOnAndTheWorkspaceIsNotTheWorkingDirectory() throws {
        let harness = try BuildCLIHarness.make(for: self)
        let log27 = Self.fixtures.appendingPathComponent("cli-xcode27.1b/21F7B51C-4B90-49D4-B328-EDA168F7A9A5.xcactivitylog").path
        // The workspace the fixture log was built in, read from the log itself: the folder above its first `Sources/` file.
        let json = try harness.run(self, ["analyze", log27, "--format", "json", "--no-rules", "--no-history", "--no-env",
                                          "--no-redact", "--xcblame-dir", harness.state.path])
        let document = try JSONReporter.decoder().decode(ReportDocument.self, from: Data(json.out.utf8))
        let entry = try XCTUnwrap(document.diagnostics.first { $0.severity == "warning" && $0.line != nil
            && $0.file?.contains("/Sources/") == true })
        let file = try XCTUnwrap(entry.file), line = try XCTUnwrap(entry.line)
        let split = try XCTUnwrap(file.range(of: "/Sources/"))
        let workspace = String(file[..<split.lowerBound])
        let relative = String(file[file.index(after: split.lowerBound)...])
        func annotations(_ extra: [String]) throws -> [String] {
            let run = try harness.run(self, ["analyze", log27, "--format", "github", "--no-rules", "--no-history", "--no-env",
                                             "--xcblame-dir", harness.state.path] + extra,
                                      environment: ["GITHUB_WORKSPACE": workspace])
            XCTAssertEqual(run.status, 0, run.err)
            return run.err.split(separator: "\n").map(String.init).filter { $0.hasPrefix("::warning") || $0.hasPrefix("::error") }
        }
        let redacted = try annotations([])
        XCTAssertFalse(redacted.isEmpty, "annotations are not dropped when redaction is on")
        XCTAssertTrue(redacted.contains { $0.hasPrefix("::warning file=\(relative),line=\(line),") }, "\(redacted)")
        XCTAssertEqual(redacted, try annotations(["--no-redact"]))
        XCTAssertFalse(redacted.joined().contains("/Users"), "nothing absolute leaves")
        // No workspace at all: an entry whose path is not repo-relative is kept file-less, with the file name in the text.
        let none = try harness.run(self, ["analyze", log27, "--format", "github", "--no-rules", "--no-history", "--no-env",
                                          "--xcblame-dir", harness.state.path])
        XCTAssertEqual(none.status, 0, none.err)
        XCTAssertTrue(none.err.contains("::warning title=xcblame::\((file as NSString).lastPathComponent):\(line): "), none.err)
    }

    // MARK: - $GITHUB_STEP_SUMMARY limit

    func testStepSummaryIsNotAppendedPastOneMebibyte() throws {
        let dir = try scratch()
        let model = dir.appendingPathComponent("model.json")
        try JSONEncoder().encode(SyntheticModel.make()).write(to: model)
        let summary = dir.appendingPathComponent("summary.md")
        let big = Data(repeating: UInt8(ascii: "x"), count: 1_048_576 - 100)
        try big.write(to: summary)
        let cli = CLIRunner(test: self)
        let full = try cli.run(["analyze", "--model-json", model.path, "--no-history", "--format", "github"],
                               environment: ["GITHUB_STEP_SUMMARY": summary.path])
        XCTAssertEqual(full.status, 0, full.err)
        XCTAssertTrue(full.err.contains("warning: not appending to $GITHUB_STEP_SUMMARY"), full.err)
        XCTAssertEqual(try Data(contentsOf: summary), big, "left alone, not truncated")
        XCTAssertTrue(full.out.hasPrefix("<!-- xcblame:report -->"), "the body still goes to stdout")
        // Room for it: appended as before.
        try Data("earlier\n".utf8).write(to: summary)
        let fits = try cli.run(["analyze", "--model-json", model.path, "--no-history", "--format", "github"],
                               environment: ["GITHUB_STEP_SUMMARY": summary.path])
        XCTAssertFalse(fits.err.contains("not appending"), fits.err)
        XCTAssertTrue(try String(contentsOf: summary, encoding: .utf8).hasPrefix("earlier\n<!-- xcblame:report -->"))
    }

    // MARK: - junit target budgets

    /// A budgeted target below the top N rows is evaluated: junit renders every target unless `--top` says otherwise.
    func testJUnitEvaluatesTargetBudgetsOutsideTheTopRows() throws {
        let dir = try scratch()
        let model = dir.appendingPathComponent("model.json")
        try JSONEncoder().encode(SyntheticModel.large(taskCount: 2_000, targets: 100)).write(to: model)
        let report = try CLIRunner(test: self).run(["analyze", "--model-json", model.path, "--no-history", "--format", "json",
                                                    "--top", "all", "--no-redact"])
        let document = try JSONReporter.decoder().decode(ReportDocument.self, from: Data(report.out.utf8))
        let small = try XCTUnwrap(document.targets?.filter { !$0.isOther }.last)
        XCTAssertGreaterThan(document.targetsTotal, 15)
        let budget = max(0, small.taskTime / 2)
        let config = dir.appendingPathComponent("config.json")
        let name = small.name.replacingOccurrences(of: "\"", with: "\\\"")
        try Data(#"{"budgets": {"targets": {"\#(name)": \#(budget)}}}"#.utf8).write(to: config)
        func junit(_ extra: [String]) throws -> String {
            let run = try CLIRunner(test: self).run(["analyze", "--model-json", model.path, "--no-history", "--format", "junit",
                                                     "--xcblame-dir", dir.path] + extra)
            XCTAssertEqual(run.status, 0, run.err)
            return run.out
        }
        let all = try junit([])
        XCTAssertTrue(all.contains("name=\"target:\(small.name)\""), all)
        XCTAssertFalse(all.contains("<skipped"), "evaluated, not skipped:\n\(all)")
        XCTAssertTrue(all.contains("BudgetExceeded"), all)
        let cut = try junit(["--top", "5"])
        XCTAssertTrue(cut.contains("render with --top all"), "an explicit --top says what it cannot evaluate:\n\(cut)")
    }
}
