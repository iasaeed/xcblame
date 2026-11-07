import XCTest
@testable import XcblameKit

/// `compare`, `baseline` and `--baseline` / `--fail-if-slower` through the built binary, on the fixture logs.
final class CompareFlowCLITests: XCTestCase {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/logs")
    private let log26 = fixtures.appendingPathComponent("cli-xcode26/20E8B73D-96FE-4232-8A33-311BFD02F961.xcactivitylog").path
    private let log27 = fixtures.appendingPathComponent("cli-xcode27.1b/21F7B51C-4B90-49D4-B328-EDA168F7A9A5.xcactivitylog").path

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-flow-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// Rewrites a baseline file: `edit` gets the decoded JSON object.
    private func edit(_ url: URL, _ change: (inout [String: Any]) -> Void) throws {
        var object = try json(url)
        change(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }

    private func halveWall(_ url: URL) throws {
        try edit(url) { object in
            var wall = object["wall"] as? [String: Any] ?? [:]
            wall["median"] = (wall["median"] as? Double ?? 0) / 2
            object["wall"] = wall
        }
    }

    private func saveBaseline(_ cli: CLIRunner, from log: String, to url: URL, extra: [String] = []) throws {
        let run = try cli.run(["baseline", "save", "--from", log, "-o", url.path] + extra)
        XCTAssertEqual(run.status, 0, run.err)
    }

    // MARK: - baseline

    func testBaselineSaveAndShowRoundTrip() throws {
        let cli = CLIRunner(test: self)
        let dir = try scratch()
        let file = dir.appendingPathComponent("baseline.json")
        try saveBaseline(cli, from: log26, to: file, extra: ["--with-tasks"])
        let object = try json(file)
        XCTAssertEqual(object["schemaVersion"] as? String, "xcblame.baseline/1")
        XCTAssertEqual((object["key"] as? [String: Any])?["xcode"] as? String, "26.0")
        XCTAssertEqual((object["key"] as? [String: Any])?["kind"] as? String, "clean")
        XCTAssertEqual(object["runs"] as? Int, 1)
        XCTAssertEqual((object["source"] as? [String: Any])?["kind"] as? String, "log")
        XCTAssertEqual((object["source"] as? [String: Any])?["refs"] as? [String], ["20E8B73D-96FE-4232-8A33-311BFD02F961.xcactivitylog"])
        XCTAssertGreaterThan((object["tasks"] as? [String: Any])?["total"] as? Int ?? 0, 100)
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("/Users/"), "no absolute paths")

        let show = try cli.run(["baseline", "show", file.path])
        XCTAssertEqual(show.status, 0, show.err)
        XCTAssertTrue(show.out.contains("clean · AcmeApp · xcode 26.0"), show.out)
        XCTAssertTrue(show.out.contains("runs     1 (fewer than 3"), show.out)
        let raw = try cli.run(["baseline", "show", file.path, "--json"])
        XCTAssertEqual(raw.out, try String(contentsOf: file, encoding: .utf8))
        XCTAssertEqual(try cli.run(["baseline", "show", dir.appendingPathComponent("none.json").path]).status, 5)
        // Without --with-tasks the file carries no digests.
        let plain = dir.appendingPathComponent("plain.json")
        try saveBaseline(cli, from: log26, to: plain)
        XCTAssertTrue(try json(plain)["tasks"] is NSNull)
    }

    func testBaselineFromHistoryUsesTheNewestMatchingEntries() throws {
        let cli = CLIRunner(test: self)
        let state = try scratch()
        for log in [log26, log27] {
            let run = try cli.run(["analyze", log, "--xcblame-dir", state.path, "--no-rules", "--no-env", "-q", "-o", state.appendingPathComponent("out.txt").path])
            XCTAssertEqual(run.status, 0, run.err)
        }
        // Two clean entries with different Xcode versions: the newest (27.1) fixes the key, so only it matches.
        let saved = try cli.run(["baseline", "save", "--xcblame-dir", state.path, "--kind", "clean", "--last", "5"])
        XCTAssertEqual(saved.status, 0, saved.err)
        XCTAssertTrue(saved.err.contains("another kind, scheme, configuration, destination or Xcode version"), saved.err)
        let object = try json(state.appendingPathComponent("baseline.json"))
        XCTAssertEqual((object["key"] as? [String: Any])?["xcode"] as? String, "27.1")
        XCTAssertEqual(object["runs"] as? Int, 1)
        XCTAssertEqual((object["source"] as? [String: Any])?["kind"] as? String, "history")
        XCTAssertEqual(try cli.run(["baseline", "save", "--xcblame-dir", state.path, "--kind", "incremental"]).status, 5)
        XCTAssertEqual(try cli.run(["baseline", "save", "--from", log26, "--last", "2"]).status, 2)
    }

    // MARK: - analyze --baseline --fail-if-slower

    func testFailIfSlowerExitsThreeOnlyWhenSlower() throws {
        let cli = CLIRunner(test: self)
        let dir = try scratch()
        let baseline = dir.appendingPathComponent("baseline.json")
        try saveBaseline(cli, from: log26, to: baseline)
        let common = ["analyze", log26, "--no-history", "--no-rules", "--no-env", "--xcblame-dir", dir.path, "--baseline", baseline.path]
        // The same build against itself: no change, exit 0, the section is printed.
        let same = try cli.run(common + ["--fail-if-slower", "1"])
        XCTAssertEqual(same.status, 0, same.err)
        XCTAssertTrue(same.out.contains("REGRESSION  indicative: wall +0 ms (+0.0 %)"), same.out)
        // A baseline half as long: +100 % is over 1 % plus the 5 % allowance. The report is still printed.
        try halveWall(baseline)
        let slower = try cli.run(common + ["--fail-if-slower", "1"])
        XCTAssertEqual(slower.status, 3, slower.err)
        XCTAssertTrue(slower.out.contains("FAILED"), slower.out)
        XCTAssertTrue(slower.out.contains("TARGETS"), "the whole report is written before exit 3")
        // Without a threshold it never fails; the numbers are the same.
        XCTAssertEqual(try cli.run(common).status, 0)
        // JSON carries the block.
        let out = dir.appendingPathComponent("r.json")
        XCTAssertEqual(try cli.run(common + ["--fail-if-slower", "1", "--format", "json", "-o", out.path]).status, 3)
        let regression = try XCTUnwrap(try json(out)["regression"] as? [String: Any])
        XCTAssertEqual(regression["failed"] as? Bool, true)
        XCTAssertEqual(regression["verdict"] as? String, "indicative")
        XCTAssertEqual(regression["thresholdPct"] as? Double, 0.01)
        XCTAssertEqual((regression["baseline"] as? [String: Any])?["source"] as? String, "file")
    }

    func testAnUnusableBaselineIsReported() throws {
        let cli = CLIRunner(test: self)
        let dir = try scratch()
        let baseline = dir.appendingPathComponent("baseline.json")
        try saveBaseline(cli, from: log26, to: baseline)
        let args = ["analyze", log26, "--no-history", "--no-rules", "--no-env", "--baseline", baseline.path, "--fail-if-slower", "5"]
        try edit(baseline) { object in
            var key = object["key"] as? [String: Any] ?? [:]
            key["kind"] = "incremental"
            object["key"] = key
        }
        let mismatch = try cli.run(args)
        XCTAssertEqual(mismatch.status, 2, mismatch.err)
        XCTAssertTrue(mismatch.err.contains("kind differs: baseline incremental, current clean"), mismatch.err)
        try Data("{\"hello\": true}".utf8).write(to: baseline)
        let broken = try cli.run(args)
        XCTAssertEqual(broken.status, 1, broken.err)
        XCTAssertTrue(broken.err.contains("regression: baseline.json is not an xcblame baseline"), broken.err)
        XCTAssertEqual(try cli.run(["analyze", log26, "--baseline", "/nonexistent.json"]).status, 5)
    }

    // MARK: - compare

    func testCompareLeadsWithTheXcodeDifference() throws {
        let cli = CLIRunner(test: self)
        let text = try cli.run(["compare", log26, log27, "--xcblame-dir", try scratch().path])
        XCTAssertEqual(text.status, 0, text.err)
        let order = ["RESULT  indicative", "ENVIRONMENT  1 of 4", "xcode  26.0 -> 27.1 (inferred)", "PHASES", "TARGETS", "CRITICAL PATH"]
            .map { text.out.range(of: $0)?.lowerBound }
        XCTAssertFalse(order.contains { $0 == nil }, text.out)
        XCTAssertEqual(order.compactMap { $0 }, order.compactMap { $0 }.sorted())
        XCTAssertTrue(text.out.contains("why  env xcode: 26.0 -> 27.1 (inferred)"), text.out)

        let dir = try scratch()
        let out = dir.appendingPathComponent("c.json")
        let json1 = try cli.run(["compare", log26, log27, "--format", "json", "-o", out.path, "--xcblame-dir", dir.path])
        XCTAssertEqual(json1.status, 0, json1.err)
        let doc = try JSONReporter.decoder().decode(CompareDocument.self, from: Data(contentsOf: out))
        XCTAssertEqual(doc.env.first?.field, "xcode")
        XCTAssertEqual(doc.env.first?.a, "26.0")
        XCTAssertEqual(doc.env.first?.b, "27.1")
        XCTAssertFalse(doc.redacted)
        XCTAssertEqual(doc.targetsTotal, 13)
        XCTAssertEqual(doc.tasks.available, true)
        XCTAssertEqual(doc.targets?.count, 13)
        // --top limits the tables; --redact rewrites the paths.
        let redacted = dir.appendingPathComponent("r.json")
        _ = try cli.run(["compare", log26, log27, "--format", "json", "--top", "3", "--redact", "-o", redacted.path, "--xcblame-dir", dir.path])
        let small = try JSONReporter.decoder().decode(CompareDocument.self, from: Data(contentsOf: redacted))
        XCTAssertTrue(small.redacted)
        XCTAssertEqual(small.targets?.count, 4)
        XCTAssertFalse(try String(contentsOf: redacted, encoding: .utf8).contains(NSHomeDirectory()))
    }

    func testCompareThresholdExitsThree() throws {
        let cli = CLIRunner(test: self)
        let state = try scratch().path
        // b is 57 % slower than a: over 5 % plus the allowance. The other way round it is faster; a build against itself is flat.
        XCTAssertEqual(try cli.run(["compare", log26, log27, "--threshold", "5", "--xcblame-dir", state]).status, 3)
        XCTAssertEqual(try cli.run(["compare", log27, log26, "--threshold", "5", "--xcblame-dir", state]).status, 0)
        XCTAssertEqual(try cli.run(["compare", log26, log26, "--threshold", "5", "--xcblame-dir", state]).status, 0)
        XCTAssertEqual(try cli.run(["compare", log26, log27, "--xcblame-dir", state]).status, 0, "no threshold, no failure")
        XCTAssertEqual(try cli.run(["compare", log26, "/nonexistent-operand", "--xcblame-dir", state]).status, 5)
    }

    func testCompareHTMLCarriesTheTimelinesAndMatchesTheJSON() throws {
        let cli = CLIRunner(test: self)
        let dir = try scratch()
        let html = dir.appendingPathComponent("c.html")
        let run = try cli.run(["compare", log26, log27, "--format", "html", "-o", html.path, "--xcblame-dir", dir.path])
        XCTAssertEqual(run.status, 0, run.err)
        XCTAssertTrue(run.out.contains("wrote"), run.out)
        let page = try String(contentsOf: html, encoding: .utf8)
        XCTAssertTrue(page.contains("\"taskIndexA\" :") && page.contains("\"taskIndexB\" :"))
        XCTAssertFalse(page.contains(NSHomeDirectory()), "redacted by default")
        // Same options as the json run (redacted, every row): the same document.
        let jsonFile = dir.appendingPathComponent("c.json")
        _ = try cli.run(["compare", log26, log27, "--format", "json", "--top", "all", "--redact", "-o", jsonFile.path, "--xcblame-dir", dir.path])
        let embedded = try XCTUnwrap(page.range(of: "data-encoding=\"json\">"))
        let end = try XCTUnwrap(page.range(of: "</script>", range: embedded.upperBound..<page.endIndex))
        let blob = Data(page[embedded.upperBound..<end.lowerBound].utf8)
        let fromPage = try JSONReporter.decoder().decode(CompareDocument.self, from: blob)
        var fromJSON = try JSONReporter.decoder().decode(CompareDocument.self, from: Data(contentsOf: jsonFile))
        // Two separate runs analyze the logs at different moments: only the times differ.
        fromJSON.generatedAt = fromPage.generatedAt
        fromJSON.a.generatedAt = fromPage.a.generatedAt
        fromJSON.b.generatedAt = fromPage.b.generatedAt
        fromJSON.regression.baseline.savedAt = fromPage.regression.baseline.savedAt
        XCTAssertEqual(fromPage, fromJSON)
    }

    func testCompareReadsSavedReportsAndHistoryIds() throws {
        let cli = CLIRunner(test: self)
        let state = try scratch()
        let r26 = state.appendingPathComponent("r26.json"), r27 = state.appendingPathComponent("r27.json")
        for (log, file) in [(log26, r26), (log27, r27)] {
            let run = try cli.run(["analyze", log, "--format", "json", "--top", "all", "--no-rules", "--no-env", "--xcblame-dir", state.path, "-o", file.path])
            XCTAssertEqual(run.status, 0, run.err)
        }
        let reports = try cli.run(["compare", r26.path, r27.path, "--xcblame-dir", state.path])
        XCTAssertEqual(reports.status, 0, reports.err)
        XCTAssertTrue(reports.out.contains("xcode  26.0 -> 27.1"), reports.out)
        XCTAssertTrue(reports.out.contains("TASKS  not compared"), "a saved report has no task rows:\n\(reports.out)")
        // The analyze runs recorded history entries: operands by id (a prefix is enough), mixed with a log.
        let ids = try FileManager.default.contentsOfDirectory(atPath: state.appendingPathComponent("history").path)
            .filter { $0.hasSuffix(".json.gz") }.map { String($0.dropLast(".json.gz".count)) }.sorted()
        XCTAssertEqual(ids.count, 2)
        let byId = try cli.run(["compare", ids[0], ids[1], "--xcblame-dir", state.path])
        XCTAssertEqual(byId.status, 0, byId.err)
        XCTAssertTrue(byId.out.contains("NEW TASKS"), "history entries carry task rows:\n\(byId.out)")
        let mixed = try cli.run(["compare", String(ids[0].prefix(15)), log27, "--xcblame-dir", state.path])
        XCTAssertEqual(mixed.status, 0, mixed.err)
        XCTAssertEqual(try cli.run(["compare", "19990101-000000", log27, "--xcblame-dir", state.path]).status, 5)
    }

    // MARK: - build

    func testBuildExitsThreeOnlyWhenXcodebuildSucceeded() throws {
        let cli = CLIRunner(test: self)
        let harnessLog = BuildCLIHarness.fixtures.appendingPathComponent("\(BuildCLIHarness.logUUID).xcactivitylog").path
        let slow = try BuildCLIHarness.make(for: self)
        let baseline = slow.directory.appendingPathComponent("baseline.json")
        try saveBaseline(cli, from: harnessLog, to: baseline)
        try halveWall(baseline)
        // The fixture log carries the scheme of its own project; the fake build below is run with `-scheme App`, and a
        // baseline only applies to a build with the same scheme (the log operand now has a scheme key).
        try edit(baseline) { object in
            var key = object["key"] as? [String: Any] ?? [:]
            key["scheme"] = "App"
            object["key"] = key
        }
        let flags = ["--baseline", baseline.path, "--fail-if-slower", "1", "--no-history"]
        let failed = try slow.build(self, flags)
        XCTAssertEqual(failed.status, 3, failed.err)
        XCTAssertTrue(failed.out.contains("REGRESSION"), failed.out)
        // xcodebuild's own failure code wins over 3.
        let broken = try BuildCLIHarness.make(for: self, exitCode: 65)
        try FileManager.default.copyItem(at: baseline, to: broken.directory.appendingPathComponent("baseline.json"))
        let wins = try broken.build(self, ["--baseline", broken.directory.appendingPathComponent("baseline.json").path,
                                          "--fail-if-slower", "1", "--no-history"])
        XCTAssertEqual(wins.status, 65, wins.err)
        // A baseline that cannot be read is reported, the report is still printed, and xcodebuild's success becomes exit 5.
        let missing = try BuildCLIHarness.make(for: self)
        let unusable = try missing.build(self, ["--baseline", missing.directory.appendingPathComponent("nope.json").path, "--no-history"])
        XCTAssertEqual(unusable.status, 5, unusable.err)
        XCTAssertTrue(unusable.err.contains("nope.json"), unusable.err)
        XCTAssertTrue(unusable.out.contains("TARGETS"), unusable.out)
    }
}
