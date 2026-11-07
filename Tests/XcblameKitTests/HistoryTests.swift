import Foundation
import XCTest
@testable import XcblameKit

final class HistoryTests: XCTestCase {
    private func report(_ model: BuildModel = SyntheticModel.make(), kind: String? = nil,
                        generatedAt: Date = Date()) throws -> ReportDocument {
        var document = try ReportPipeline.run(model, options: ReportPipeline.Options(generatedAt: generatedAt)).document
        document.build.kind = kind
        return document
    }

    private func entryJSON(_ url: URL) throws -> [String: Any] {
        let data = Data(try GzipFile.inflate(contentsOf: url).bytes)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testSaveWritesAGzippedEntryNamedByTimeAndKind() throws {
        let dir = try makeScratchDirectory().appendingPathComponent("history")
        let model = SyntheticModel.make()
        let url = try History.save(document: try report(model), model: model, directory: dir)
        XCTAssertTrue(url.lastPathComponent.hasSuffix("-unknown.json.gz"), url.lastPathComponent)
        XCTAssertTrue(GzipFile.isGzip(try Data(contentsOf: url)))
        XCTAssertEqual(url.lastPathComponent.count, "yyyyMMdd-HHmmss-unknown.json.gz".count)
        XCTAssertEqual(try String(contentsOf: dir.deletingLastPathComponent().appendingPathComponent(".gitignore"),
                                  encoding: .utf8), "history/\nsnapshots/\nreports/\nresults/\nlogs/\ncache/\ntmp/\nplans/\nbackup/\n")

        let classified = try History.save(document: try report(model, kind: "clean"), model: model, directory: dir)
        XCTAssertTrue(classified.lastPathComponent.hasSuffix("-clean.json.gz"), classified.lastPathComponent)
        XCTAssertEqual(History.list(directory: dir).count, 2)
    }

    /// Code review v0.2 #14: analyzing the same log twice keeps one entry.
    func testTheSameLogIsRecordedOnce() throws {
        let dir = try makeScratchDirectory().appendingPathComponent("history")
        let model = SyntheticModel.make()
        var document = try report(model)
        document.input.path = "/dd/Logs/Build/5E3BDB3A-008A-466D-A419-CB4D4E8CED29.xcactivitylog"
        let first = try History.save(document: document, model: model, directory: dir)
        document.generatedAt = document.generatedAt.addingTimeInterval(60)
        XCTAssertEqual(try History.save(document: document, model: model, directory: dir), first)
        XCTAssertEqual(History.list(directory: dir).count, 1)
        document.input.path = "/dd/Logs/Build/1724F45E-EE25-4BC4-B219-B6D39E144D71.xcactivitylog"
        XCTAssertNotEqual(try History.save(document: document, model: model, directory: dir), first)
        XCTAssertEqual(History.list(directory: dir).count, 2)
    }

    func testEntryIsTheReportPlusTaskIndexRows() throws {
        let dir = try makeScratchDirectory()
        let model = SyntheticModel.make()
        let document = try report(model)
        let url = try History.save(document: document, model: model, directory: dir)
        let json = try entryJSON(url)
        XCTAssertEqual(json["schemaVersion"] as? String, "xcblame.report/1")
        let rows = try XCTUnwrap(json["taskIndexRows"] as? [[Any]])
        XCTAssertFalse(rows.isEmpty)
        // On-path rows are exactly the tasks of the critical path's segments (the synthetic model gets an inferred
        // path; every path task is an executed task, so each has a row).
        let pathIds = Set(try XCTUnwrap(document.criticalPath).segments.flatMap(\.taskIds))
        XCTAssertFalse(pathIds.isEmpty)
        XCTAssertEqual(rows.filter { $0[6] as? Int == 1 }.count, pathIds.count)
        for row in rows {
            XCTAssertEqual(row.count, 7)  // key, rule, target, kind, sigDigest, durationMs, onPath
            XCTAssertTrue(row[1] is String)
            XCTAssertTrue(row[3] is String)
            let digest = try XCTUnwrap(row[4] as? String)
            XCTAssertEqual(digest.count, 16)
            XCTAssertTrue(digest.allSatisfy(\.isHexDigit))
            XCTAssertTrue(row[5] is Int)
            XCTAssertTrue([0, 1].contains(row[6] as? Int))
        }
        // The entry still decodes as a report, and as rows.
        let shown = try History.show(id: History.list(directory: dir)[0].id, directory: dir)
        XCTAssertEqual(shown.document.build.tasks, document.build.tasks)
        XCTAssertEqual(shown.taskIndexRows.count, rows.count)

        // Without a critical path no row is on it.
        var pathless = document
        pathless.criticalPath = nil
        XCTAssertFalse(History.taskIndexRows(pathless, model).contains(where: \.onPath))
    }

    func testRowFieldsComeFromTheTask() throws {
        var model = TestModels.model([
            TestModels.task(0, "SwiftCompile", start: 100, end: 102.5),
            TestModels.task(1, "Ld", kind: .link, phase: .link, target: 0, start: 103, end: 104),
            // Reused: started before the window.
            TestModels.task(2, "CompileC", kind: .clangCompile, start: 10, end: 11),
        ], targets: [TestModels.target(0, "App")], start: 100, end: 110)
        model.tasks[0].taskKey = "key-0"
        model.tasks[0].commandDetails = "swiftc -c a.swift"
        let document = try report(model)
        let pathIds = Set(document.criticalPath?.segments.flatMap(\.taskIds) ?? [])
        let rows = History.taskIndexRows(document, model)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0], History.TaskIndexRow(
            key: "key-0", rule: "SwiftCompile", target: nil, kind: "swiftCompile",
            sigDigest: History.digest("swiftc -c a.swift"), durationMs: 2500, onPath: pathIds.contains(0),
            title: model.tasks[0].title))
        XCTAssertEqual(rows[1].onPath, pathIds.contains(1))
        XCTAssertEqual(rows[1].target, "App")
        XCTAssertNil(rows[1].key)
        // No command details: the digest is of the title.
        XCTAssertEqual(rows[1].sigDigest, History.digest("Ld 1"))
        XCTAssertEqual(History.digest("").count, 16)
    }

    func testOnPathComesFromTheCriticalPathSegments() throws {
        let model = TestModels.model([
            TestModels.task(0, start: 100, end: 104), TestModels.task(1, start: 104, end: 108),
            TestModels.task(2, start: 100, end: 101),
        ], start: 100, end: 110)
        var document = try report(model)
        let segment = ReportDocument.PathSegment(
            start: 0, end: 8, seconds: 8, share: 1, basis: "dag", target: nil, targetId: nil, label: "x",
            taskIds: [0, 1])
        document.criticalPath = ReportDocument.CriticalPath(
            span: 8, basis: "dag", segments: [segment], segmentsTotal: 1, segmentsShownShare: 1, waits: [],
            whatIf: nil, notes: [])
        XCTAssertEqual(History.taskIndexRows(document, model).map(\.onPath), [true, true, false])
    }

    func testTrimKeepsTopRowsAndRescalesShares() throws {
        var document = try report()
        document.files = (0 ..< 40).map { index in
            ReportDocument.FileRow(path: "f\(index).swift", target: nil, targetId: nil, seconds: Double(40 - index),
                                   granularity: "exact", batchSize: nil, members: nil, onPath: false,
                                   typeCheckMs: nil, taskId: nil)
        }
        document.filesTotal = 60
        // The 40 shown rows cover 820 of 1000 seconds.
        document.filesShownShare = 0.82
        let trimmed = History.trimmed(document)
        XCTAssertEqual(trimmed.files?.count, 25)
        XCTAssertEqual(trimmed.filesTotal, 60)
        // Kept 40 + ... + 16 = 700 of the 820 shown.
        XCTAssertEqual(try XCTUnwrap(trimmed.filesShownShare), 0.82 * 700 / 820, accuracy: 1e-9)
        // Short lists are left alone.
        XCTAssertEqual(History.trimmed(try report()).files, try report().files)
    }

    func testListShowsSpanAndTasksAndShowFindsByPrefix() throws {
        let dir = try makeScratchDirectory()
        let model = SyntheticModel.make()
        let document = try report(model)
        _ = try History.save(document: document, model: model, directory: dir)
        let item = try XCTUnwrap(History.list(directory: dir).first)
        XCTAssertEqual(item.kind, "unknown")
        XCTAssertEqual(item.tasks, document.build.tasks)
        XCTAssertEqual(item.span, document.build.span)
        XCTAssertNotNil(item.time)
        XCTAssertEqual(try History.show(id: String(item.id.prefix(10)), directory: dir).item.id, item.id)
        XCTAssertThrowsError(try History.show(id: "1999", directory: dir))
    }

    func testPruneKeepsTheNewestN() throws {
        let dir = try makeScratchDirectory()
        for day in 1 ... 5 { try writeEntry("2026010\(day)-120000-clean", in: dir) }
        let removed = try History.prune(directory: dir, keep: 2, olderThanDays: nil)
        XCTAssertEqual(removed, 3)
        XCTAssertEqual(History.list(directory: dir).map(\.id), ["20260105-120000-clean", "20260104-120000-clean"])
        XCTAssertEqual(try History.prune(directory: dir, keep: 2, olderThanDays: nil), 0)
        XCTAssertEqual(try History.prune(directory: dir, keep: 0, olderThanDays: nil), 2)
    }

    func testPruneDropsEntriesOlderThanTheLimit() throws {
        let dir = try makeScratchDirectory()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stamp = { (days: Double) in XcodebuildRunner.timestamp(now.addingTimeInterval(-days * 86_400)) }
        try writeEntry("\(stamp(100))-clean", in: dir)
        try writeEntry("\(stamp(89))-incremental", in: dir)
        try writeEntry("\(stamp(1))-zero-change", in: dir)
        XCTAssertEqual(try History.prune(directory: dir, keep: nil, olderThanDays: 90, now: now), 1)
        XCTAssertEqual(History.list(directory: dir).map(\.kind), ["zero-change", "incremental"])
    }

    func testPruneDropsSnapshotsNoKeptEntryNeedsPastTheLimits() throws {
        let state = try makeScratchDirectory()
        let history = state.appendingPathComponent("history")
        let snapshots = state.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let now = Date()
        func snapshot(_ uuid: String, daysOld: Double) throws {
            let dir = snapshots.appendingPathComponent(uuid)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("sig\n".utf8).write(to: dir.appendingPathComponent("SIGNATURE"))
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-daysOld * 86_400)],
                                                  ofItemAtPath: dir.path)
        }
        try writeEntry("\(XcodebuildRunner.timestamp(now))-clean", in: history,
                       json: #"{"build":{"span":1,"tasks":1},"input":{"path":"/DD/Logs/Build/AAAA.xcactivitylog"}}"#)
        try snapshot("AAAA", daysOld: 100)  // old, but a kept entry names its log
        try snapshot("BBBB", daysOld: 100)  // old, no entry
        try snapshot("CCCC", daysOld: 1)    // recent, no entry
        try History.prune(directory: history, keep: History.keepEntries, olderThanDays: History.keepDays, now: now)
        let left = { Set(try FileManager.default.contentsOfDirectory(atPath: snapshots.path)) }
        XCTAssertEqual(try left(), ["AAAA", "CCCC"])

        // Beyond the newest 200 by mtime: the oldest unneeded ones go, the needed one stays.
        for index in 0 ..< History.keepEntries { try snapshot(String(format: "N%03d", index), daysOld: Double(index) / 1000) }
        XCTAssertEqual(try History.pruneSnapshots(snapshots, history: history, now: now), 1)
        XCTAssertFalse(try left().contains("CCCC"), "1 day old, but 201st newest and unneeded")
        XCTAssertTrue(try left().contains("AAAA"), "needed by a kept entry")
        XCTAssertEqual(try left().count, History.keepEntries + 1)

        // A history folder not named `history` never touches a sibling `snapshots`.
        let other = state.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try snapshot("DDDD", daysOld: 500)
        try History.prune(directory: other, keep: 0, olderThanDays: 0, now: now)
        XCTAssertTrue(try left().contains("DDDD"))
    }

    func testSavePrunesToTheRetentionLimits() throws {
        let dir = try makeScratchDirectory()
        try writeEntry("20200101-120000-clean", in: dir)  // older than 90 days
        let model = SyntheticModel.make()
        _ = try History.save(document: try report(model), model: model, directory: dir)
        XCTAssertEqual(History.list(directory: dir).map(\.id).filter { $0.hasPrefix("2020") }, [])
        XCTAssertEqual(History.list(directory: dir).count, 1)
        XCTAssertEqual(History.keepEntries, 200)
        XCTAssertEqual(History.keepDays, 90)
    }

    func testTwoSavesInOneSecondDoNotOverwrite() throws {
        let dir = try makeScratchDirectory()
        let model = SyntheticModel.make()
        let document = try report(model)
        let first = try History.save(document: document, model: model, directory: dir)
        let second = try History.save(document: document, model: model, directory: dir)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(History.list(directory: dir).count, 2)
    }

    func testSaveThrowsInAReadOnlyDirectory() throws {
        let dir = try makeScratchDirectory()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        let model = SyntheticModel.make()
        XCTAssertThrowsError(try History.save(document: try report(model), model: model, directory: dir))
        XCTAssertTrue(History.list(directory: dir).isEmpty)
    }

    // MARK: - Task digests across machines (code review v0.4 M2)

    private func digests(root: String, home: String, hash: String, flags: String = "-O") throws -> [String] {
        var model = TestModels.model([
            TestModels.task(0, "SwiftCompile", start: 100, end: 102.5),
            TestModels.task(1, "CompileC", kind: .clangCompile, start: 103, end: 104),
            TestModels.task(2, "Ld", kind: .link, phase: .link, start: 104, end: 105),
        ], targets: [TestModels.target(0, "App")], start: 100, end: 110)
        let dd = "\(home)/Library/Developer/Xcode/DerivedData/App-\(hash)"
        model.tasks[0].commandDetails = "cd \(root)/App.xcodeproj\r    swiftc \(flags) \(root)/Sources/a.swift -o \(dd)/Build/a.o"
        model.tasks[1].commandDetails = "cd \(root)/App.xcodeproj\r    clang -c \(root)/b.c -I\(dd)/Build/include -o \(dd)/b.o"
        model.tasks[2].commandDetails = "cd \(root)/App.xcodeproj\r    ld \(dd)/Build/a.o \(dd)/Build/b.o"
        return History.taskIndexRows(try report(model), model).map(\.sigDigest)
    }

    /// The same build on a developer's Mac and on a CI runner (other home, checkout and DerivedData hash) has the same
    /// task digests; a different command line does not.
    func testTaskDigestsDoNotDependOnRootPaths() throws {
        let mac = try digests(root: "/Users/alice/Work/App", home: "/Users/alice", hash: "abcdefghijklmnopqrstuvwxyzab")
        let ci = try digests(root: "/Users/runner/builds/acme/App", home: "/Users/runner", hash: "zyxwvutsrqponmlkjihgfedcbaza")
        XCTAssertEqual(mac, ci)
        XCTAssertEqual(mac.count, 3)
        XCTAssertEqual(Set(mac).count, 3, "the tasks still tell each other apart")
        let other = try digests(root: "/Users/runner/builds/acme/App", home: "/Users/runner",
                                hash: "zyxwvutsrqponmlkjihgfedcbaza", flags: "-Onone")
        XCTAssertNotEqual(other[0], mac[0], "a flag is part of the digest")
        XCTAssertEqual(Array(other.dropFirst()), Array(mac.dropFirst()))
        // The same through the baseline digest (rule, target, sigDigest) that `--with-tasks` stores.
        func ids(_ rows: [History.TaskIndexRow]) -> [String] { rows.map(Baseline.digest) }
        let model = TestModels.model([TestModels.task(0, start: 100, end: 101)], start: 100, end: 110)
        XCTAssertEqual(ids([TaskIndexRowFixture.row(mac[0])]), ids([TaskIndexRowFixture.row(ci[0])]))
        XCTAssertFalse(History.taskIndexRows(try report(model), model).isEmpty)
    }

    func testProjectRootsAreEveryWorkingDirectoryWithoutTheProjectName() {
        var model = TestModels.model([TestModels.task(0, start: 100, end: 101), TestModels.task(1, start: 101, end: 102),
                                      TestModels.task(2, start: 102, end: 103)], start: 100, end: 110)
        XCTAssertEqual(History.projectRoots(of: model), [])
        model.tasks[0].commandDetails = "cd /w/App/App.xcodeproj\r    x"
        model.tasks[1].commandDetails = "cd /w/App/App.xcodeproj\n    y"
        model.tasks[2].commandDetails = "cd /w/Pkg\r    z"
        XCTAssertEqual(History.projectRoots(of: model), ["/w/App", "/w/Pkg"])
        XCTAssertEqual(History.portable("swiftc /w/App/a.swift /Users/bob/Library/x /w/Pkg/p", roots: ["/w/App", "/w/Pkg"]),
                       "swiftc $REPO/a.swift /Users/$USER/Library/x $REPO/p")
    }

    /// A dev Mac (`Xcode.app`, checkout in the home, DerivedData inside the repo) and a runner (`Xcode_26.0.app`, other
    /// checkout, DerivedData elsewhere, a sibling package root) give the same digests (code review v0.4 re-check M2).
    func testTaskDigestsDoNotDependOnXcodeAppNameOrDerivedDataPath() throws {
        func rows(xcode: String, root: String, package: String, dd: String) throws -> [String] {
            var model = TestModels.model([
                TestModels.task(0, "SwiftCompile", start: 100, end: 102.5),
                TestModels.task(1, "CompileC", kind: .clangCompile, start: 103, end: 104),
            ], targets: [TestModels.target(0, "App")], start: 100, end: 110)
            let dev = "/Applications/\(xcode)/Contents/Developer"
            model.tasks[0].commandDetails = "cd \(root)/App.xcodeproj\r    \(dev)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
                + " -sdk \(dev)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk -I\(dd)/Build/Products/Debug"
                + " -o \(dd)/Build/Intermediates.noindex/App.build/a.o \(root)/a.swift"
            model.tasks[1].commandDetails = "cd \(package)\r    \(dev)/usr/bin/clang -c \(package)/b.c -o \(dd)/Build/Intermediates.noindex/b.o"
            return History.taskIndexRows(try report(model), model).map(\.sigDigest)
        }
        let mac = try rows(xcode: "Xcode.app", root: "/Users/alice/Work/App", package: "/Users/alice/Work/Packages/Core",
                           dd: "/Users/alice/Work/App/build/dd")
        let ci = try rows(xcode: "Xcode_26.0.app", root: "/Users/runner/builds/acme/App",
                          package: "/Users/runner/builds/acme/Packages/Core", dd: "/tmp/ci-derived")
        XCTAssertEqual(mac, ci)
        XCTAssertEqual(Set(mac).count, 2)
    }

    // MARK: - Log identity (code review v0.4 M3)

    private func logFile(_ directory: URL, _ name: String, _ content: String) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        return url.path
    }

    func testLogIdentityIsTheUUIDOrAContentHashNeverTheName() throws {
        let dir = try makeScratchDirectory()
        XCTAssertEqual(History.logIdentity(path: "/dd/Logs/Build/5e3bdb3a-008a-466d-a419-cb4d4e8ced29.xcactivitylog"),
                       "uuid:5E3BDB3A-008A-466D-A419-CB4D4E8CED29")
        let a = try logFile(dir.appendingPathComponent("a"), "build.log", "first build\n")
        let b = try logFile(dir.appendingPathComponent("b"), "build.log", "second build\n")
        let copy = try logFile(dir.appendingPathComponent("c"), "renamed.log", "first build\n")
        let identity = try XCTUnwrap(History.logIdentity(path: a))
        XCTAssertTrue(identity.hasPrefix("sha256:"), identity)
        XCTAssertNotEqual(identity, History.logIdentity(path: b), "same name, different build")
        XCTAssertEqual(identity, History.logIdentity(path: copy), "same content, other name")
        XCTAssertNil(History.logIdentity(path: dir.appendingPathComponent("missing.log").path))
    }

    func testLogIdentityCoversTheTailOfALargeLog() throws {
        let dir = try makeScratchDirectory()
        let head = String(repeating: "x", count: (1 << 20) + 4096)
        let a = try logFile(dir.appendingPathComponent("a"), "build.log", head + "tail one\n")
        let b = try logFile(dir.appendingPathComponent("b"), "build.log", head + "tail two\n")
        let same = try logFile(dir.appendingPathComponent("c"), "again.log", head + "tail one\n")
        XCTAssertNotEqual(History.logIdentity(path: a), History.logIdentity(path: b), "same first MiB and size")
        XCTAssertEqual(History.logIdentity(path: a), History.logIdentity(path: same))
    }

    func testSameNamedDistinctLogsAreDistinctEntriesAndTheSameLogIsOne() throws {
        let scratch = try makeScratchDirectory()
        let dir = scratch.appendingPathComponent("history")
        let model = SyntheticModel.make()
        let first = try logFile(scratch.appendingPathComponent("monday"), "build.log", "monday's build\n")
        let second = try logFile(scratch.appendingPathComponent("tuesday"), "build.log", "tuesday's build\n")
        var document = try report(model)
        document.input.path = first
        let one = try History.save(document: document, model: model, directory: dir)
        document.generatedAt = document.generatedAt.addingTimeInterval(60)
        XCTAssertEqual(try History.save(document: document, model: model, directory: dir), one, "the same log again")
        document.input.path = second
        document.generatedAt = document.generatedAt.addingTimeInterval(60)
        let two = try History.save(document: document, model: model, directory: dir)
        XCTAssertNotEqual(one, two, "a different build with the same file name is recorded")
        XCTAssertEqual(History.list(directory: dir).count, 2)
        // The identity is stored in the entry.
        let stored = try entryJSON(one)
        XCTAssertEqual(stored["logId"] as? String, History.logIdentity(path: first))
        XCTAssertEqual(History.logIdentity(of: one), History.logIdentity(path: first))
    }

    private func gzippedEntry(_ id: String, in directory: URL, json text: String) throws {
        let json = directory.appendingPathComponent("\(id).json")
        try Data(text.utf8).write(to: json)
        try gzip(json, to: directory.appendingPathComponent("\(id).json.gz"))
        try FileManager.default.removeItem(at: json)
    }

    /// An entry written before `logId` existed is identified by its log's UUID name, else not at all.
    func testEntriesWithoutALogIdKeepTheirUUIDIdentity() throws {
        let dir = try makeScratchDirectory()
        try gzippedEntry("20260101-120000-clean", in: dir,
                         json: #"{"build":{"span":1,"tasks":1},"input":{"path":"/DD/Logs/Build/5E3BDB3A-008A-466D-A419-CB4D4E8CED29.xcactivitylog"}}"#)
        try gzippedEntry("20260102-120000-clean", in: dir, json: #"{"build":{"span":1,"tasks":1},"input":{"path":"/x/build.log"}}"#)
        XCTAssertEqual(History.logIdentity(of: dir.appendingPathComponent("20260101-120000-clean.json.gz")),
                       "uuid:5E3BDB3A-008A-466D-A419-CB4D4E8CED29")
        XCTAssertNil(History.logIdentity(of: dir.appendingPathComponent("20260102-120000-clean.json.gz")))
    }

    private func writeEntry(_ id: String, in directory: URL,
                            json text: String = #"{"build":{"span":1.5,"tasks":3}}"#) throws {
        let json = directory.appendingPathComponent("\(id).json")
        try Data(text.utf8).write(to: json)
        try gzip(json, to: directory.appendingPathComponent("\(id).json.gz"))
        try FileManager.default.removeItem(at: json)
    }
}

private enum TaskIndexRowFixture {
    static func row(_ digest: String) -> History.TaskIndexRow {
        .init(key: nil, rule: "SwiftCompile", target: "App", kind: "swiftCompile", sigDigest: digest, durationMs: 1, onPath: false)
    }
}
