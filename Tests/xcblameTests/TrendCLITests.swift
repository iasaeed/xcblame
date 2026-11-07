import Foundation
import XCTest
import XcblameKit

final class TrendCLITests: XCTestCase {
    /// An xcblame state folder with `count` history entries, one every ten minutes ending an hour ago.
    private func stateWithHistory(count: Int, xcode: (Int) -> String = { _ in "26.0" }) throws -> URL {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-trend-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: state) }
        let history = state.appendingPathComponent("history")
        let model = SyntheticModel.make()
        let start = Date().addingTimeInterval(-3_600 - Double(count) * 600)
        for index in 0..<count {
            var document = try ReportPipeline.run(model, options: .init(generatedAt: start.addingTimeInterval(Double(index) * 600))).document
            document.build.kind = "clean"
            document.build.span = 10 + Double(index)
            document.build.scheme = "AcmeApp"
            document.xcode.value = xcode(index)
            document.input.path = "/dd/Logs/Build/\(UUID().uuidString).xcactivitylog"
            _ = try History.save(document: document, model: model, directory: history)
        }
        return state
    }

    func testTextTableOverTheHistory() throws {
        let state = try stateWithHistory(count: 4)
        let result = try CLIRunner(test: self).run(["trend", "--xcblame-dir", state.path])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.hasPrefix("xcblame trend: 4 of 4 history entries\n"), result.out)
        XCTAssertTrue(result.out.contains("clean  4  11.5 s"), result.out)
    }

    func testJSONToFileAndToStdout() throws {
        let state = try stateWithHistory(count: 3)
        let cli = CLIRunner(test: self)
        let stdout = try cli.run(["trend", "--xcblame-dir", state.path, "--format", "json", "--by", "xcode"])
        XCTAssertEqual(stdout.status, 0, stdout.err)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(stdout.out.utf8)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? String, "xcblame.trend/1")
        XCTAssertEqual(object["entriesUsed"] as? Int, 3)
        XCTAssertEqual((object["filter"] as? [String: Any])?["by"] as? String, "xcode")

        let file = state.appendingPathComponent("trend.json")
        let written = try cli.run(["trend", "--xcblame-dir", state.path, "--format", "json", "--by", "xcode", "-o", file.path])
        XCTAssertEqual(written.status, 0, written.err)
        XCTAssertTrue(written.out.hasPrefix("wrote \(file.path) (json, "), written.out)
        // The same document either way; only `generatedAt` may differ when the two runs straddle a second (it did, in
        // the v0.5 integration run), so it is compared as a valid date and every other member byte for byte.
        func withoutTime(_ data: Data) throws -> [String: Any] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNotNil((object.removeValue(forKey: "generatedAt") as? String).flatMap(ISO8601DateFormatter().date(from:)))
            return object
        }
        let fromFile = try withoutTime(try Data(contentsOf: file))
        let fromStdout = try withoutTime(Data(stdout.out.utf8))
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: fromFile, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: fromStdout, options: .sortedKeys),
                       "stdout and -o carry the same document")
        XCTAssertEqual(try Data(contentsOf: file).count, Data(stdout.out.utf8).count, "and the same byte count")
    }

    func testHTMLGoesToTheReportsFolderOrDashO() throws {
        let state = try stateWithHistory(count: 3, xcode: { $0 < 2 ? "26.0" : "26.1" })
        let cli = CLIRunner(test: self)
        let result = try cli.run(["trend", "--xcblame-dir", state.path, "--format", "html"])
        XCTAssertEqual(result.status, 0, result.err)
        let reports = state.appendingPathComponent("reports")
        let names = try FileManager.default.contentsOfDirectory(atPath: reports.path)
        XCTAssertEqual(names.count, 1, "\(names)")
        XCTAssertTrue(names[0].hasSuffix("-trend.html"), names[0])
        XCTAssertTrue(result.out.contains("wrote ") && result.out.contains("open \""), result.out)
        let page = try String(contentsOf: reports.appendingPathComponent(names[0]), encoding: .utf8)
        XCTAssertTrue(page.contains("\"schemaVersion\" : \"xcblame.trend/1\""))
        XCTAssertTrue(page.contains("id=\"trend\""))

        let target = state.appendingPathComponent("here.html")
        let explicit = try cli.run(["trend", "--xcblame-dir", state.path, "--format", "html", "-o", target.path, "--redact"])
        XCTAssertEqual(explicit.status, 0, explicit.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains("\"redacted\" : true"))
    }

    func testFiltersReachTheDocument() throws {
        let state = try stateWithHistory(count: 3)
        let cli = CLIRunner(test: self)
        let recent = try cli.run(["trend", "--xcblame-dir", state.path, "--format", "json", "--since", "0d"])
        XCTAssertEqual(recent.status, 0, recent.err)
        XCTAssertTrue(recent.out.contains("\"entriesUsed\" : 0"), recent.out)
        let wrongScheme = try cli.run(["trend", "--xcblame-dir", state.path, "--format", "json", "--scheme", "Other"])
        XCTAssertTrue(wrongScheme.out.contains("\"entriesUsed\" : 0"), wrongScheme.out)
        let kind = try cli.run(["trend", "--xcblame-dir", state.path, "--kind", "incremental"])
        XCTAssertEqual(kind.status, 0, kind.err)
        XCTAssertTrue(kind.out.contains("xcblame trend: 0 of 3"), kind.out)
    }

    func testNoHistoryIsNotAnError() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-trend-none-\(UUID().uuidString)")
        let result = try CLIRunner(test: self).run(["trend", "--xcblame-dir", state.path])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.contains("no history entries in "), result.out)
    }

    func testUsageErrorsExitTwo() throws {
        let cli = CLIRunner(test: self)
        XCTAssertEqual(try cli.run(["trend", "--by", "colour"]).status, 2)
        let since = try cli.run(["trend", "--since", "last-week"])
        XCTAssertEqual(since.status, 2)
        XCTAssertTrue(since.err.contains("--since must be a date"), since.err)
        XCTAssertEqual(try cli.run(["trend", "--format", "markdown"]).status, 2)
    }
}
