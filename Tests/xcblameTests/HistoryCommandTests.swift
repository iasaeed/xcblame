import Foundation
import XCTest

final class HistoryCommandTests: XCTestCase {
    /// Two recorded builds (two logs) in a scratch folder.
    private func recorded() throws -> BuildCLIHarness {
        let harness = try BuildCLIHarness.make(for: self, uniqueLogs: true)
        for _ in 0 ..< 2 {
            let result = try harness.build(self, ["--format", "json", "-o", "/dev/null"])
            XCTAssertEqual(result.status, 0, result.err)
        }
        return harness
    }

    func testListShowsEveryRecordedBuild() throws {
        let harness = try recorded()
        XCTAssertEqual(harness.historyEntries.count, 2)
        let result = try harness.run(self, ["history", "list"])
        XCTAssertEqual(result.status, 0, result.err)
        let lines = result.out.split(separator: "\n")
        XCTAssertEqual(lines.count, 3, result.out)
        XCTAssertTrue(lines[0].hasPrefix("ID"), result.out)
        XCTAssertTrue(lines[1].contains("unknown") || lines[1].contains("clean"), result.out)
        XCTAssertTrue(lines[1].contains(" s "), "span column: \(lines[1])")
    }

    func testListOfNothingSaysSo() throws {
        let harness = try BuildCLIHarness.make(for: self)
        let result = try harness.run(self, ["history", "list"])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.hasPrefix("no history in "), result.out)
    }

    func testShowPrintsTheReportAndJSON() throws {
        let harness = try recorded()
        let id = String(try XCTUnwrap(harness.historyEntries.last).dropLast(".json.gz".count))
        let text = try harness.run(self, ["history", "show", id])
        XCTAssertEqual(text.status, 0, text.err)
        XCTAssertTrue(text.out.hasPrefix("history entry \(id) ("), text.out)
        XCTAssertTrue(text.out.contains("TOP TASKS"), text.out)

        let json = try harness.run(self, ["history", "show", id, "--json"])
        XCTAssertEqual(json.status, 0, json.err)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? String, "xcblame.report/1")
        XCTAssertFalse(try XCTUnwrap(object["taskIndexRows"] as? [Any]).isEmpty)
    }

    func testShowOfAnUnknownIdExits5() throws {
        let harness = try recorded()
        let result = try harness.run(self, ["history", "show", "19990101"])
        XCTAssertEqual(result.status, 5, result.err)
        XCTAssertTrue(result.err.contains("no history entry"), result.err)
    }

    func testPruneKeepsTheNewest() throws {
        let harness = try recorded()
        let result = try harness.run(self, ["history", "prune", "--keep", "1"])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertEqual(result.out, "removed 1 history entries, 1 kept\n")
        XCTAssertEqual(harness.historyEntries.count, 1)
    }

    /// Code review v0.3 major 4: `--oracle-cache` empties the settings-oracle cache (here a throwaway home).
    func testPruneOracleCacheRemovesTheScratchEntries() throws {
        let harness = try BuildCLIHarness.make(for: self)
        let home = harness.directory.appendingPathComponent("cache-home")
        for key in ["0123456789abcdef", "fedcba9876543210"] {
            try FileManager.default.createDirectory(at: home.appendingPathComponent("oracle/\(key)/Settings.xcworkspace"),
                                                    withIntermediateDirectories: true)
        }
        let result = try harness.run(self, ["history", "prune", "--oracle-cache"], environment: ["XCBLAME_CACHE_DIR": home.path])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertEqual(result.out, "removed 0 history entries, 0 kept\nremoved 2 settings-oracle cache entries\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("oracle").path), [])
    }

    func testPruneWithoutFlagsUsesTheRetentionDefaults() throws {
        let harness = try recorded()
        let result = try harness.run(self, ["history", "prune"])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertEqual(result.out, "removed 0 history entries, 2 kept\n")
    }

    func testNegativeKeepIsAUsageError() throws {
        let harness = try BuildCLIHarness.make(for: self)
        XCTAssertEqual(try harness.run(self, ["history", "prune", "--keep", "-1"]).status, 2)
    }
}
