import XCTest
@testable import XcblameKit

final class BaselineTests: XCTestCase {
    func testMediansMadsAndRunCount() throws {
        let docs = try CompareFixtures.reports([10, 12, 11, 20, 10.5])
        let b = try Baseline.make(from: docs, source: .init(kind: "history", refs: ["/Users/x/.xcblame/history/20261101-120000-clean", "r.json"]),
                                  now: CompareFixtures.date)
        XCTAssertEqual(b.runs, 5)
        XCTAssertEqual(b.wall.median, 11)
        XCTAssertEqual(b.wall.mad, 1)
        XCTAssertEqual(b.wallBasis, "span")
        XCTAssertEqual(b.busy.median, 10.9, "busy is span - 0.1 in the fixture")
        XCTAssertEqual(b.key, .init(kind: "clean", scheme: "App", configuration: "Debug", destination: "macOS arm64", xcode: "26.0"))
        XCTAssertEqual(b.source.refs, ["20261101-120000-clean", "r.json"], "basenames only")
        XCTAssertNil(b.tasks)
        XCTAssertEqual(b.notes, [])
        let one = try Baseline.make(from: [docs[0]], source: .init(kind: "report", refs: ["r.json"]))
        XCTAssertEqual(one.wall.mad, 0)
        XCTAssertTrue(one.notes.contains { $0.contains("indicative") }, "\(one.notes)")
    }

    func testProcessWallBasisNeedsEveryRun() throws {
        let all = try Baseline.make(from: CompareFixtures.reports([10, 11, 12], processWalls: [20, 22, 21]),
                                    source: .init(kind: "report", refs: ["r"]))
        XCTAssertEqual(all.wallBasis, "processWall")
        XCTAssertEqual(all.wall.median, 21)
        var some = try CompareFixtures.reports([10, 11, 12], processWalls: [20, 22, 21])
        some[1].timing.processWall = nil
        let mixed = try Baseline.make(from: some, source: .init(kind: "report", refs: ["r"]))
        XCTAssertEqual(mixed.wallBasis, "span")
        XCTAssertEqual(mixed.wall.median, 11)
        XCTAssertTrue(mixed.notes.contains { $0.contains("process wall") })
    }

    func testRunsMustShareOneBuildKey() throws {
        func make(_ other: ReportDocument) throws {
            _ = try Baseline.make(from: [CompareFixtures.report(span: 10), other], source: .init(kind: "report", refs: ["r"]))
        }
        for (field, other) in [("scheme", try CompareFixtures.report(span: 10, scheme: "Other")),
                               ("kind", try CompareFixtures.report(span: 10, kind: "incremental")),
                               ("configuration", try CompareFixtures.report(span: 10, configuration: "Release")),
                               ("destination", try CompareFixtures.report(span: 10, destination: "iOS")),
                               ("Xcode", try CompareFixtures.report(span: 10, xcode: "26.1"))] {
            XCTAssertThrowsError(try make(other), field) { error in
                guard case let XcblameError.usage(message) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(message.contains(field), message)
                XCTAssertTrue(message.hasPrefix("baseline:"), message)
            }
        }
        XCTAssertThrowsError(try Baseline.make(from: [], source: .init(kind: "report", refs: [])))
    }

    func testTaskDigestsAreSortedUniqueSixteenHex() throws {
        let rows = [CompareFixtures.row("SwiftCompile", "App", "aa", ms: 10), CompareFixtures.row("SwiftCompile", "App", "aa", ms: 20),
                    CompareFixtures.row("Ld", nil, "bb", ms: 5)]
        let b = try Baseline.make(from: [CompareFixtures.report(span: 10)], source: .init(kind: "log", refs: ["x.xcactivitylog"]),
                                  taskRows: rows)
        let tasks = try XCTUnwrap(b.tasks)
        XCTAssertEqual(tasks.total, 3)
        XCTAssertEqual(tasks.ids.count, 2, "two rows share rule, target and signature")
        XCTAssertEqual(tasks.ids, tasks.ids.sorted())
        for id in tasks.ids {
            XCTAssertEqual(id.count, 16)
            XCTAssertNotNil(id.range(of: "^[0-9a-f]{16}$", options: .regularExpression))
        }
        XCTAssertEqual(Baseline.digest(rows[0]), Baseline.digest(rows[1]), "the duration is not part of the id")
        XCTAssertNotEqual(Baseline.digest(rows[0]), Baseline.digest(rows[2]))
    }

    func testSaveLoadRoundTripAndFileShape() throws {
        let dir = try CompareFixtures.tempDirectory(self)
        let url = dir.appendingPathComponent("nested/baseline.json")
        var docs = try CompareFixtures.reports([10, 12, 11])
        docs[0].environment = EnvSnapshot()
        docs[0].environment?.hwModel = "Mac15,14"
        docs[0].environment?.logicalCPUCount = 28
        docs[0].environment?.memoryBytes = 96 << 30
        docs[0].environment?.git = GitInfo(branch: "main", commit: String(repeating: "a", count: 40), dirty: false, remoteHost: "github.com")
        let b = try Baseline.make(from: docs, source: .init(kind: "history", refs: ["20261101-120000-clean"]), now: CompareFixtures.date)
        XCTAssertEqual(b.machine, "Mac15,14/28c/96g")
        try b.save(to: url)
        XCTAssertEqual(try Baseline.load(from: url), b)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasSuffix("}\n"))
        XCTAssertFalse(text.contains(dir.path), "no absolute paths")
        // Sorted keys: a second save is byte-equal.
        let again = dir.appendingPathComponent("again.json")
        try b.save(to: again)
        XCTAssertEqual(try Data(contentsOf: url), try Data(contentsOf: again))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? String, "xcblame.baseline/1")
        XCTAssertTrue(object["tasks"] is NSNull, "unknown stays an explicit null")
        XCTAssertEqual(object.keys.sorted(), ["busy", "criticalPath", "git", "key", "machine", "notes", "runs", "savedAt",
                                              "schemaVersion", "source", "tasks", "tool", "wall", "wallBasis"])
    }

    func testLoadErrors() throws {
        let dir = try CompareFixtures.tempDirectory(self)
        XCTAssertThrowsError(try Baseline.load(from: dir.appendingPathComponent("missing.json"))) { error in
            XCTAssertEqual(error as? XcblameError, .logNotFound(dir.appendingPathComponent("missing.json").path))
        }
        let bad = dir.appendingPathComponent("bad.json")
        try Data("{\"hello\": 1}".utf8).write(to: bad)
        XCTAssertThrowsError(try Baseline.load(from: bad)) { error in
            XCTAssertTrue(error is Regression.NotEvaluable, "\(error)")
            XCTAssertTrue("\(error)".hasPrefix("regression: "))
        }
        let newer = dir.appendingPathComponent("newer.json")
        try Data("{\"schemaVersion\": \"xcblame.baseline/2\"}".utf8).write(to: newer)
        XCTAssertThrowsError(try Baseline.load(from: newer)) { XCTAssertTrue("\($0)".contains("Update xcblame"), "\($0)") }
    }

    // MARK: - History selection

    private func writeEntry(_ dir: URL, second: Int, kind: String, scheme: String?, configuration: String? = "Debug",
                            destination: String? = "macOS arm64", xcode: String = "26.0", wall: Double) throws {
        var doc = try CompareFixtures.report(span: wall, kind: kind, scheme: scheme, configuration: configuration,
                                             destination: destination, xcode: xcode,
                                             generatedAt: Date(timeIntervalSinceNow: -3600 + Double(second)))
        doc.input.path = "/logs/\(second).xcactivitylog"
        _ = try History.save(document: doc, model: SyntheticModel.make(), directory: dir)
    }

    func testHistorySelectionFiltersOnKindSchemeConfigurationDestinationAndXcode() throws {
        let dir = try CompareFixtures.tempDirectory(self).appendingPathComponent("history")
        // Oldest to newest. The newest clean entry (second 70) fixes the key: App, Debug, macOS arm64, Xcode 26.0.
        try writeEntry(dir, second: 10, kind: "clean", scheme: "App", wall: 10)
        try writeEntry(dir, second: 20, kind: "clean", scheme: "Other", wall: 99)
        try writeEntry(dir, second: 30, kind: "incremental", scheme: "App", wall: 3)
        try writeEntry(dir, second: 40, kind: "clean", scheme: "App", configuration: "Release", wall: 98)
        try writeEntry(dir, second: 50, kind: "clean", scheme: "App", xcode: "26.1", wall: 97)
        try writeEntry(dir, second: 60, kind: "clean", scheme: "App", destination: "iOS Simulator", wall: 96)
        try writeEntry(dir, second: 70, kind: "clean", scheme: "App", wall: 12)
        try writeEntry(dir, second: 80, kind: "incremental", scheme: "App", wall: 4)
        try writeEntry(dir, second: 90, kind: "clean", scheme: "App", wall: 11)
        // 90 is the newest clean entry and fixes the key; 70 and 10 match it, the others differ in one member each.
        let runs = Baseline.selectHistory(directory: dir, kind: "clean", count: 5)
        XCTAssertEqual(runs.entries.map { $0.document.build.span }, [10, 12, 11], "oldest first")
        XCTAssertEqual(runs.available, 3)
        XCTAssertEqual(runs.otherKey, 4, "scheme, configuration, Xcode and destination each left one clean entry out")
        XCTAssertTrue(runs.entries.allSatisfy { $0.document.build.scheme == "App" && $0.document.build.configuration == "Debug"
            && $0.document.build.destination == "macOS arm64" && $0.document.xcode.value == "26.0" })
        // The newest N of the matching entries.
        let two = Baseline.selectHistory(directory: dir, kind: "clean", count: 2)
        XCTAssertEqual(two.entries.map { $0.document.build.span }, [12, 11])
        // Another kind picks its own key.
        let incremental = Baseline.selectHistory(directory: dir, kind: "incremental", count: 9)
        XCTAssertEqual(incremental.entries.map { $0.document.build.span }, [3, 4])
        // Without a kind the newest entry (any kind) fixes the whole key, kind included.
        let any = Baseline.selectHistory(directory: dir, kind: nil, count: 9)
        XCTAssertEqual(any.entries.map { $0.document.build.span }, [10, 12, 11])
        XCTAssertEqual(Baseline.selectHistory(directory: dir, kind: "zero-change", count: 3).entries.count, 0)
        // The task rows travel with the entries (for --with-tasks).
        XCTAssertFalse(runs.entries[0].taskIndexRows.isEmpty)
        // A baseline made of them.
        let baseline = try Baseline.make(from: runs.entries.map(\.document),
                                         source: .init(kind: "history", refs: runs.entries.map(\.item.id)),
                                         taskRows: runs.entries[Baseline.medianRunIndex(of: runs.entries.map(\.document))].taskIndexRows)
        XCTAssertEqual(baseline.runs, 3)
        XCTAssertEqual(baseline.wall.median, 11)
        XCTAssertEqual(baseline.key.scheme, "App")
        XCTAssertNotNil(baseline.tasks)
    }

    /// Code review v0.4 M1: `build` entries (destination from `-destination`, `macOS`) and `analyze` entries (from the
    /// build request, `macOS arm64`) of one build are one group.
    func testHistorySelectionGroupsBuildAndAnalyzeEntriesOfTheSameBuild() throws {
        let dir = try CompareFixtures.tempDirectory(self).appendingPathComponent("history")
        try writeEntry(dir, second: 10, kind: "clean", scheme: "App", destination: "macOS", wall: 10)
        try writeEntry(dir, second: 20, kind: "clean", scheme: "App", destination: "macOS arm64", wall: 11)
        try writeEntry(dir, second: 30, kind: "clean", scheme: "App", destination: "macOS", wall: 12)
        try writeEntry(dir, second: 40, kind: "clean", scheme: "App", destination: "iOS Simulator", wall: 99)
        try writeEntry(dir, second: 50, kind: "clean", scheme: "App", destination: "macOS arm64", wall: 13)
        let runs = Baseline.selectHistory(directory: dir, kind: "clean", count: 9)
        XCTAssertEqual(runs.entries.map { $0.document.build.span }, [10, 11, 12, 13])
        XCTAssertEqual(runs.otherKey, 1, "only the iOS Simulator entry is another build")
        // One baseline out of them keeps the more specific destination.
        let baseline = try Baseline.make(from: runs.entries.map(\.document), source: .init(kind: "history", refs: []))
        XCTAssertEqual(baseline.key.destination, "macOS arm64")
    }

    /// Code review v0.4 re-check: destination agreement is not transitive, so every run is checked against the merged
    /// destination: `macOS`, `macOS arm64` and `macOS x86_64` are not one build, and the message names the runs.
    func testMixedArchitecturesAreRefusedAndTheRunsNamed() throws {
        let mac = try CompareFixtures.report(span: 10, destination: "macOS")
        let arm = try CompareFixtures.report(span: 11, destination: "macOS arm64")
        let intel = try CompareFixtures.report(span: 12, destination: "macOS x86_64")
        for order in [[mac, arm, intel], [intel, mac, arm], [arm, intel, mac]] {
            XCTAssertThrowsError(try Regression.key(of: order, side: "current")) { error in
                guard case let XcblameError.usage(message) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(message.contains("macOS arm64") && message.contains("macOS x86_64") && message.contains("run "), message)
            }
        }
        XCTAssertNoThrow(try Regression.key(of: [mac, arm], side: "current"))
        // Through the history: the newest entry names no architecture, so both older ones agree with it pairwise.
        let dir = try CompareFixtures.tempDirectory(self).appendingPathComponent("history")
        try writeEntry(dir, second: 10, kind: "clean", scheme: "App", destination: "macOS x86_64", wall: 10)
        try writeEntry(dir, second: 20, kind: "clean", scheme: "App", destination: "macOS arm64", wall: 11)
        try writeEntry(dir, second: 30, kind: "clean", scheme: "App", destination: "macOS", wall: 12)
        let runs = Baseline.selectHistory(directory: dir, kind: "clean", count: 3)
        XCTAssertEqual(runs.entries.count, 3)
        let ids = runs.entries.map(\.item.id)
        XCTAssertThrowsError(try Baseline.make(from: runs.entries.map(\.document), source: .init(kind: "history", refs: ids))) { error in
            guard case let XcblameError.usage(message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.hasPrefix("baseline: the runs differ in destination"), message)
            XCTAssertTrue(message.contains(ids[0]) && message.contains(ids[1]), "names the runs: \(message)")
        }
        // Fewer runs that agree are fine.
        let two = Baseline.selectHistory(directory: dir, kind: "clean", count: 2)
        XCTAssertEqual(try Baseline.make(from: two.entries.map(\.document), source: .init(kind: "history", refs: [])).key.destination, "macOS arm64")
    }

    /// Code review v0.4 M1: a baseline saved from a log (`macOS arm64`, from the build request) matches a `build` run
    /// with `-destination platform=macOS` (`macOS`), and a log read the other way round; another platform still refuses.
    func testRegressionMatchesDestinationsOfMixedSources() throws {
        let baseline = try Baseline.make(from: CompareFixtures.reports([10, 11, 12]), source: .init(kind: "log", refs: ["x"]))
        XCTAssertEqual(baseline.key.destination, "macOS arm64")
        let build = try CompareFixtures.report(span: 11, destination: "macOS")
        let result = try Regression.evaluate(current: [build], baseline: baseline)
        XCTAssertEqual(result.baseline.destination, "macOS arm64")
        let other = try CompareFixtures.report(span: 11, destination: "iOS Simulator")
        XCTAssertThrowsError(try Regression.evaluate(current: [other], baseline: baseline)) { error in
            XCTAssertTrue("\(error)".contains("destination differs"), "\(error)")
        }
        // A history id (build, `macOS`) against a log (build request, `macOS arm64`) compares.
        let logSide = try CompareFixtures.report(span: 12, destination: "macOS arm64")
        XCTAssertNoThrow(try Regression.evaluate(current: [build], reference: [logSide], referenceRef: nil))
        // Runs of one side that differ only in the architecture's presence are one build.
        XCTAssertNoThrow(try Baseline.make(from: [build, logSide], source: .init(kind: "history", refs: [])))
    }

    /// Code review v0.4 M1 (minor): a key field that is unknown on a side is not compared; the notes say which.
    func testUnknownKeyFieldsAreNamedInTheNotes() throws {
        let baseline = try Baseline.make(from: CompareFixtures.reports([10, 11, 12]), source: .init(kind: "log", refs: ["x"]))
        let full = try Regression.evaluate(current: [CompareFixtures.report(span: 11)], baseline: baseline)
        XCTAssertFalse(full.notes.contains { $0.hasPrefix("key:") }, "\(full.notes)")
        let partial = try Regression.evaluate(
            current: [CompareFixtures.report(span: 11, configuration: nil, destination: nil)], baseline: baseline)
        let note = try XCTUnwrap(partial.notes.first { $0.hasPrefix("key:") })
        XCTAssertTrue(note.contains("configuration, destination"), note)
        XCTAssertFalse(note.contains("scheme"), note)
    }

    /// Code review v0.4 minor: a baseline of the process wall checked by a run without one cannot fail; the notes say so.
    func testThresholdWithoutAComparableWallIsNoted() throws {
        let baseline = try Baseline.make(from: CompareFixtures.reports([10, 11, 12], processWalls: [20, 22, 21]),
                                         source: .init(kind: "report", refs: ["r"]))
        let result = try Regression.evaluate(current: [CompareFixtures.report(span: 100)], baseline: baseline,
                                             options: .init(thresholdPct: 0.05))
        XCTAssertFalse(result.failed)
        XCTAssertNil(result.wall.delta)
        XCTAssertTrue(result.notes.contains { $0.contains("--fail-if-slower") && $0.contains("cannot fail") }, "\(result.notes)")
        let quiet = try Regression.evaluate(current: [CompareFixtures.report(span: 100)], baseline: baseline)
        XCTAssertFalse(quiet.notes.contains { $0.contains("--fail-if-slower") }, "no threshold, no remark")
    }

    func testMedianRunIndexPicksTheRunNearestTheMedian() throws {
        XCTAssertEqual(Baseline.medianRunIndex(of: try CompareFixtures.reports([10, 30, 12, 11, 50])), 2)
        XCTAssertEqual(Baseline.medianRunIndex(of: []), 0)
    }

    func testTextSummary() throws {
        let b = try Baseline.make(from: CompareFixtures.reports([10, 12, 11]), source: .init(kind: "history", refs: ["id1"]),
                                  now: CompareFixtures.date)
        let text = b.textSummary(path: ".xcblame/baseline.json")
        XCTAssertTrue(text.contains("clean · App · Debug · macOS arm64 · xcode 26.0"), text)
        XCTAssertTrue(text.contains("median 11.0 s, MAD 1.0 s"), text)
        XCTAssertTrue(text.contains("runs     3"), text)
    }
}
