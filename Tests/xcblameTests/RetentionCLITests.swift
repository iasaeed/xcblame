import Foundation
import XCTest

/// `history prune` also applies the retention policy to results/, logs/ and reports/ (docs/SCHEMA-v0.4.md "Lane C").
final class RetentionCLITests: XCTestCase {
    func testHistoryPruneRemovesOldReportsAndLeavesForeignFiles() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-retention-\(UUID().uuidString)")
        let reports = state.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: state) }
        let old = Date().addingTimeInterval(-120 * 86_400)
        for name in ["20260101-000000-clean.html", "notes.txt"] {
            let url = reports.appendingPathComponent(name)
            try Data("x".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        }
        let result = try CLIRunner(test: self).run(["history", "prune", "--xcblame-dir", state.path])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertEqual(result.out, "removed 0 history entries, 0 kept\nremoved 1 old entries from reports/\n")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: reports.path), ["notes.txt"])
    }

    // v0.4 integration: `analyze --format html` (reports pile up one per run) applies the policy as `build` does.
    func testAnalyzeHTMLPrunesOldReports() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-retention-\(UUID().uuidString)")
        let reports = state.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: state) }
        let stale = reports.appendingPathComponent("20260101-000000-clean.html")
        try Data("x".utf8).write(to: stale)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-120 * 86_400)], ofItemAtPath: stale.path)
        let log = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/logs/cli-xcode26/20E8B73D-96FE-4232-8A33-311BFD02F961.xcactivitylog")
        let result = try CLIRunner(test: self).run(["analyze", log.path, "--format", "html", "--no-env", "--no-history", "-q",
                                                    "--xcblame-dir", state.path])
        XCTAssertEqual(result.status, 0, result.err)
        let left = try FileManager.default.contentsOfDirectory(atPath: reports.path)
        XCTAssertEqual(left.count, 1, "\(left)")
        XCTAssertNotEqual(left.first, stale.lastPathComponent)
    }
}
