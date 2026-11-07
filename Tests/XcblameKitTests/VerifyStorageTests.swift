import XCTest
@testable import XcblameKit

/// Overlay text and restore (docs/SCHEMA-v0.6.md "Overlay file"), history verify entries ("Storage") and the per-arm
/// DerivedData folders.
final class VerifyStorageTests: XCTestCase {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-verify-storage-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testRemovingPlanBlocksIsByteExact() throws {
        let header = VerifyOverlay.header(configuration: "Debug")
        let one = "\n// xcblame plan 7f3a91c2 rule SET-004\nDEBUG_INFORMATION_FORMAT = dwarf // xcblame SET-004 (plan 7f3a91c2)\n"
            + "// end xcblame plan 7f3a91c2 rule SET-004\n"
        let two = "\n// xcblame plan 7f3a91c2 rule SET-016\nCOMPILATION_CACHE_ENABLE_CACHING = YES // xcblame SET-016 (plan 7f3a91c2)\n"
            + "// end xcblame plan 7f3a91c2 rule SET-016\n"
        let text = header + one + two
        XCTAssertEqual(try VerifyOverlay.removingPlanBlocks(text, plan: "7f3a91c2", rules: ["SET-004"], file: "o"), header + two)
        XCTAssertEqual(try VerifyOverlay.removingPlanBlocks(text, plan: "7f3a91c2", rules: ["SET-016"], file: "o"), header + one)
        XCTAssertEqual(try VerifyOverlay.removingPlanBlocks(text, plan: "7f3a91c2", rules: ["SET-004", "SET-016"], file: "o"), header)
        XCTAssertEqual(try VerifyOverlay.removingPlanBlocks(text, plan: "00000000", rules: ["SET-004"], file: "o"), text)
        XCTAssertTrue(VerifyOverlay.isEmptyOverlay(header))
        XCTAssertFalse(VerifyOverlay.isEmptyOverlay(header + one))
        XCTAssertTrue(VerifyOverlay.hasPlanBlock(text, plan: "7f3a91c2", rule: "SET-016"))

        let broken = header + "\n// xcblame plan 7f3a91c2 rule SET-004\nDEBUG_INFORMATION_FORMAT = dwarf\n"
        XCTAssertThrowsError(try VerifyOverlay.removingPlanBlocks(broken, plan: "7f3a91c2", rules: ["SET-004"],
                                                                  file: "overlay-Debug.xcconfig")) { error in
            XCTAssertEqual(error as? VerifyOverlay.OverlayError, .editedByHand("overlay-Debug.xcconfig"))
        }
    }

    func testTemporaryBlocksFormat() {
        let text = VerifyOverlay.withTemporaryBlocks("A = 1", plan: "7f3a91c2", configuration: "Debug",
                                                     blocks: [(rule: "SET-004", lines: ["B = 2 // xcblame SET-004 (plan 7f3a91c2)"])])
        XCTAssertEqual(text, "A = 1\n\n// xcblame verify 7f3a91c2 rule SET-004 (temporary)\nB = 2 // xcblame SET-004 (plan 7f3a91c2)\n"
            + "// end xcblame verify 7f3a91c2 rule SET-004\n")
    }

    func testGuardRestoresBytesAndDeletesWhatItCreated() throws {
        let dir = try scratch()
        let existing = dir.appendingPathComponent("overlay-Debug.xcconfig")
        let created = dir.appendingPathComponent("overlay-Release.xcconfig")
        let bytes = Data("X = 1\r\nno final newline".utf8)
        try bytes.write(to: existing)
        let guarded = OverlayGuard()
        try guarded.write("changed", to: existing)
        try guarded.write("again", to: existing)
        try guarded.write("new", to: created)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "again")
        guarded.restore(existing)
        XCTAssertEqual(try Data(contentsOf: existing), bytes, "the first original wins over later writes")
        try guarded.write("changed", to: existing)
        guarded.restoreAll()
        XCTAssertEqual(try Data(contentsOf: existing), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.path))
    }

    func testGuardKeepsInodeAndModificationTimes() throws {
        let file = try scratch().appendingPathComponent("overlay-Debug.xcconfig")
        try Data("A = 1\n".utf8).write(to: file)
        let then = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.modificationDate: then], ofItemAtPath: file.path)
        func stat() throws -> (inode: Int, modified: Date?) {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            return ((attributes[.systemFileNumber] as? Int) ?? -1, attributes[.modificationDate] as? Date)
        }
        let before = try stat()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let guarded = OverlayGuard()
        for _ in 0..<2 {
            try guarded.write("A = 1\nB = 2\n", to: file, modificationDate: stamp)
            XCTAssertEqual(try stat().modified, stamp, "every B run sees the same mtime")
            guarded.restore(file)
            XCTAssertEqual(try stat().modified, then)
        }
        XCTAssertEqual(try stat().inode, before.inode, "written in place")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "A = 1\n")
    }

    func testHistoryVerifyEntriesAreSeparateAndPruned() throws {
        let history = try scratch().appendingPathComponent("history")
        func document(_ id: String) -> VerifyDocument {
            VerifyDocument(tool: V06Samples.tool, generatedAt: V06Samples.date, id: id, planId: "7f3a91c2", kind: .clean,
                           mechanism: nil, runsPerArm: 5, oneByOne: false, keepOnTie: false, maxMinutes: nil, touch: nil,
                           scheme: "Acme", configuration: "Debug", xcodebuildArguments: [], preconditions: [], results: [],
                           abort: nil, elapsedSeconds: 1, xcode: nil, machine: nil, notes: [])
        }
        let first = try History.saveVerify(document("20261101-100000-verify"), directory: history)
        XCTAssertEqual(first.lastPathComponent, "20261101-100000-verify.json.gz")
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, "verify")
        let twin = try History.saveVerify(document("20261101-100000-verify"), directory: history)
        XCTAssertEqual(twin.lastPathComponent, "20261101-100000-verify-2.json.gz")
        try History.saveVerify(document("20261104-100000-verify"), directory: history)
        XCTAssertEqual(History.listVerify(directory: history).map(\.id),
                       ["20261104-100000-verify", "20261101-100000-verify-2", "20261101-100000-verify"])
        XCTAssertTrue(History.list(directory: history).isEmpty)
        XCTAssertEqual(try History.showVerify(id: "20261104", directory: history).id, "20261104-100000-verify")
        XCTAssertThrowsError(try History.showVerify(id: "20261101", directory: history))
        XCTAssertTrue(FileManager.default.fileExists(atPath: history.deletingLastPathComponent().appendingPathComponent(".gitignore").path))

        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-05T00:00:00Z"))
        XCTAssertEqual(try History.pruneVerify(directory: history, keep: 2, olderThanDays: nil, now: now), 1)
        XCTAssertEqual(try History.pruneVerify(directory: history, keep: nil, olderThanDays: 2, now: now), 1)
        XCTAssertEqual(History.listVerify(directory: history).map(\.id), ["20261104-100000-verify"])
    }

    func testVerifyDerivedDataPerArmAndPrune() throws {
        let home = try scratch()
        let a = try VerifyDerivedData.prepare(home: home, plan: "7f3a91c2", label: "A")
        let b = try VerifyDerivedData.prepare(home: home, plan: "7f3a91c2", label: "B-SET-004")
        XCTAssertEqual(a.path, home.appendingPathComponent("verify/7f3a91c2/A").path)
        XCTAssertNotEqual(a, b)
        let stray = home.appendingPathComponent("verify/7f3a91c2/unmarked")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        let old = Date(timeIntervalSinceNow: -40 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: a.path)
        XCTAssertEqual(VerifyDerivedData.prune(home: home, olderThanDays: VerifyDerivedData.keepDays), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path), "only marked arms are pruned")
        XCTAssertEqual(VerifyDerivedData.prune(home: home, olderThanDays: nil), 1)
    }

    func testSystemHostParsesPmset() {
        XCTAssertEqual(SystemVerifyHost.onBattery(pmset: "Now drawing from 'Battery Power'\n -InternalBattery-0"), true)
        XCTAssertEqual(SystemVerifyHost.onBattery(pmset: "Now drawing from 'AC Power'"), false)
        XCTAssertNil(SystemVerifyHost.onBattery(pmset: "something else"))
        XCTAssertEqual(SystemVerifyHost.spelling(.serious), "serious")
        let host = EnvironmentVerifyHost(environment: ["XCBLAME_VERIFY_HOST": "power=battery,xcodebuild=12 34,thermal=fair"])
        XCTAssertEqual(host.onBattery(), true)
        XCTAssertEqual(host.otherXcodebuilds(), [12, 34])
        XCTAssertEqual(host.thermalState(), "fair")
    }
}
