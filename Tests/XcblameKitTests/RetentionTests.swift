import XCTest
@testable import XcblameKit

final class RetentionTests: XCTestCase {
    private let now = Date()

    /// `<yyyyMMdd-HHmmss>-<n>.<ext>` named like xcblame writes, with the given modification time.
    @discardableResult
    private func fake(_ name: String, in folder: URL, age days: Double, directory: Bool = false) throws -> URL {
        let url = folder.appendingPathComponent(name)
        if directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url.appendingPathComponent("Info.plist"))
        } else {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-days * 86_400)],
                                              ofItemAtPath: url.path)
        return url
    }

    private func names(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    func testTwoHundredFiftyEntriesKeepTheNewestTwoHundred() throws {
        let state = try makeScratchDirectory()
        let reports = state.appendingPathComponent("reports")
        for index in 0..<250 {
            // Ages 0.001 ... 0.25 days: all recent, so only the count limit applies; index 0 is the newest.
            try fake(String(format: "20261101-%06d-clean.html", index), in: reports, age: Double(index + 1) / 1000)
        }
        let outcome = try Retention.apply(stateDir: state, now: now)
        XCTAssertEqual(outcome.removed["reports"], 50)
        let left = names(reports)
        XCTAssertEqual(left.count, 200)
        XCTAssertTrue(left.contains("20261101-000000-clean.html"), "the newest stays")
        XCTAssertFalse(left.contains("20261101-000249-clean.html"), "the oldest goes")
    }

    func testEntriesOlderThanNinetyDaysGoInEveryFolderAndBundlesGoWhole() throws {
        let state = try makeScratchDirectory()
        let old = try fake("20260101-000000.xcresult", in: state.appendingPathComponent("results"), age: 91, directory: true)
        let fresh = try fake("20261101-000000.xcresult", in: state.appendingPathComponent("results"), age: 1, directory: true)
        let log = try fake("20260101-000000.xcodebuild.log", in: state.appendingPathComponent("logs"), age: 120)
        let report = try fake("20260101-000000-clean.html", in: state.appendingPathComponent("reports"), age: 90.5)
        let edge = try fake("20261001-000000-clean.html", in: state.appendingPathComponent("reports"), age: 89)

        let outcome = try Retention.apply(stateDir: state, now: now)
        XCTAssertEqual(outcome.removed, ["results": 1, "logs": 1, "reports": 1])
        XCTAssertEqual(outcome.total, 3)
        for gone in [old, log, report] { XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path), gone.lastPathComponent) }
        for kept in [fresh, edge] { XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), kept.lastPathComponent) }
    }

    func testCustomPolicyAndAFolderThatIsMissing() throws {
        let state = try makeScratchDirectory()
        for index in 0..<5 { try fake("20261101-00000\(index).xcodebuild.log", in: state.appendingPathComponent("logs"), age: Double(index)) }
        let outcome = try Retention.apply(stateDir: state, policy: .init(keepEntries: 2, keepDays: 10), now: now)
        XCTAssertEqual(outcome.removed, ["logs": 3], "results and reports do not exist and are not listed")
        XCTAssertEqual(names(state.appendingPathComponent("logs")), ["20261101-000000.xcodebuild.log", "20261101-000001.xcodebuild.log"])
    }

    func testForeignFilesAndOtherStateAreUntouched() throws {
        let state = try makeScratchDirectory()
        let reports = state.appendingPathComponent("reports")
        // Not named like xcblame names things, however old: left alone.
        let notes = try fake("notes.txt", in: reports, age: 400)
        let shortStamp = try fake("2026-old.html", in: reports, age: 400)
        let baseline = try fake("baseline.json", in: state, age: 400)
        let config = try fake("config.json", in: state, age: 400)
        let snapshot = try fake("5E3BDB3A-008A-466D-A419-CB4D4E8CED29", in: state.appendingPathComponent("snapshots"), age: 400, directory: true)
        let history = try fake("20200101-000000-clean.json.gz", in: state.appendingPathComponent("history"), age: 400)
        try fake("20200101-000000-clean.html", in: reports, age: 400)

        let outcome = try Retention.apply(stateDir: state, now: now)
        XCTAssertEqual(outcome.removed, ["reports": 1])
        for url in [notes, shortStamp, baseline, config, snapshot, history] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
        }
    }

    func testSymbolicLinksAreNeverFollowed() throws {
        let state = try makeScratchDirectory()
        let outside = try makeScratchDirectory()
        let precious = try fake("20200101-000000-precious.html", in: outside, age: 400)

        // An entry that is a link to an old folder outside: the link goes, the folder and its content stay.
        let reports = state.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        let link = reports.appendingPathComponent("20200101-000000-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        // `lutimes` ages the link itself (setAttributes would follow it and age the folder outside).
        let long = timeval(tv_sec: Int(now.timeIntervalSince1970) - 400 * 86_400, tv_usec: 0)
        XCTAssertEqual(lutimes(link.path, [long, long]), 0)
        // A whole folder that is a link: skipped, the target is not even listed.
        try FileManager.default.createSymbolicLink(at: state.appendingPathComponent("logs"), withDestinationURL: outside)

        let outcome = try Retention.apply(stateDir: state, now: now)
        XCTAssertEqual(outcome.removed, ["reports": 1])
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "the link itself is gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: precious.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
    }

    func testAMissingStateFolderIsNotAnError() throws {
        let gone = try makeScratchDirectory().appendingPathComponent("nothing")
        XCTAssertEqual(try Retention.apply(stateDir: gone, now: now), Retention.Outcome())
    }

    // MARK: - History dedupe

    private func entry(_ log: String, at date: Date, in directory: URL, kind: String = "clean") throws -> URL {
        let model = SyntheticModel.make()
        var document = try ReportPipeline.run(model, options: .init(generatedAt: date)).document
        document.build.kind = kind
        document.input.path = "/dd/Logs/Build/\(log).xcactivitylog"
        return try History.save(document: document, model: model, directory: directory)
    }

    func testDedupeKeepsTheOldestEntryOfEachLog() throws {
        let dir = try makeScratchDirectory().appendingPathComponent("history")
        let a = "5E3BDB3A-008A-466D-A419-CB4D4E8CED29"
        let b = "1724F45E-EE25-4BC4-B219-B6D39E144D71"
        let t0 = now
        let first = try entry(a, at: t0, in: dir)
        _ = try entry(b, at: t0.addingTimeInterval(60), in: dir, kind: "incremental")
        // History.save only compares with the newest entry, so analyzing A again after B adds a second A.
        let again = try entry(a, at: t0.addingTimeInterval(120), in: dir)
        XCTAssertNotEqual(first, again)
        XCTAssertEqual(History.list(directory: dir, details: false).count, 3)

        XCTAssertEqual(try Retention.dedupeHistory(directory: dir), 1)
        let left = History.list(directory: dir, details: false).map(\.url.lastPathComponent)
        XCTAssertEqual(left.count, 2)
        XCTAssertTrue(left.contains(first.lastPathComponent), "the oldest of A stays")
        XCTAssertFalse(left.contains(again.lastPathComponent))
        XCTAssertEqual(try Retention.dedupeHistory(directory: dir), 0, "idempotent")
    }

    /// Code review v0.4 M3: `history prune` never deletes a build because another log had the same file name.
    func testDedupeKeepsDistinctLogsThatShareAFileName() throws {
        let scratch = try makeScratchDirectory()
        let dir = scratch.appendingPathComponent("history")
        let model = SyntheticModel.make()
        func entry(_ folder: String, _ content: String, at date: Date) throws -> URL {
            let logs = scratch.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: logs.appendingPathComponent("build.log"))
            var document = try ReportPipeline.run(model, options: .init(generatedAt: date)).document
            document.input.path = logs.appendingPathComponent("build.log").path
            return try History.save(document: document, model: model, directory: dir)
        }
        let monday = try entry("mon", "build one\n", at: now)
        let tuesday = try entry("tue", "build two\n", at: now.addingTimeInterval(60))
        let wednesday = try entry("wed", "build three\n", at: now.addingTimeInterval(120))
        XCTAssertEqual(Set([monday, tuesday, wednesday].map(\.lastPathComponent)).count, 3)
        XCTAssertEqual(try Retention.dedupeHistory(directory: dir), 0)
        XCTAssertEqual(History.list(directory: dir, details: false).count, 3, "three different builds survive the prune")
        // Monday's log analyzed again after Wednesday's is a real duplicate: the oldest entry of it stays.
        let again = try entry("mon", "build one\n", at: now.addingTimeInterval(180))
        XCTAssertEqual(try Retention.dedupeHistory(directory: dir), 1)
        let left = Set(History.list(directory: dir, details: false).map(\.url.lastPathComponent))
        XCTAssertTrue(left.contains(monday.lastPathComponent))
        XCTAssertFalse(left.contains(again.lastPathComponent))
        XCTAssertEqual(left.count, 3)
    }

    func testDedupeLeavesEntriesWithoutALogAlone() throws {
        let dir = try makeScratchDirectory().appendingPathComponent("history")
        let model = SyntheticModel.make()
        var document = try ReportPipeline.run(model, options: .init(generatedAt: now)).document
        document.input.path = nil
        _ = try History.save(document: document, model: model, directory: dir)
        document.generatedAt = now.addingTimeInterval(60)
        _ = try History.save(document: document, model: model, directory: dir)
        XCTAssertEqual(try Retention.dedupeHistory(directory: dir), 0)
        XCTAssertEqual(History.list(directory: dir, details: false).count, 2)
    }
}
