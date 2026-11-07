import Foundation
import XCTest
import XcblameKit

/// `analyze --format html` end to end through the built binary: file placement, CI and `--open`, redaction by
/// default, and re-rendering a saved JSON report.
final class HTMLCommandTests: XCTestCase {
    private static let clean26 = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent(
            "fixtures/logs/cli-xcode26/20E8B73D-96FE-4232-8A33-311BFD02F961.xcactivitylog").path

    private var binary: URL {
        Bundle(for: HTMLCommandTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("xcblame")
    }

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-html-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func run(_ arguments: [String], ci: Bool = false) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["CI"] = ci ? "true" : nil
        env["NO_COLOR"] = "1"
        // The settings oracle's cache home: under .build for the whole test run, never ~/Library/Caches.
        env["XCBLAME_CACHE_DIR"] = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/settings-test-cache/oracle-home").path
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    func testExplicitOutputIsWrittenAndRedactedByDefault() throws {
        let dir = try scratch()
        let file = dir.appendingPathComponent("nested/r.html")
        let result = try run(["analyze", Self.clean26, "--format", "html", "-o", file.path, "--no-history",
                              "--xcblame-dir", dir.appendingPathComponent(".xcblame").path])
        XCTAssertEqual(result.status, 0, result.err)
        let lines = result.out.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2, result.out)
        XCTAssertTrue(lines[0].hasPrefix("wrote \(file.path) (html, ") && lines[0].contains("· checks "), lines[0])
        XCTAssertEqual(lines[1], "open \"\(file.path)\"")
        let html = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(html.contains(NSHomeDirectory() + "/"), "html redacts by default")
        XCTAssertFalse(html.contains("\"" + NSUserName() + "\""))
        XCTAssertTrue(html.contains("\"redacted\" : true"))
        XCTAssertFalse(result.err.contains("not redacted"), result.err)
    }

    func testWithoutOutputTheFileGoesToTheReportsFolder() throws {
        let dir = try scratch()
        let state = dir.appendingPathComponent("state")
        let result = try run(["analyze", Self.clean26, "--format", "html", "--no-env", "--no-history",
                              "--xcblame-dir", state.path])
        XCTAssertEqual(result.status, 0, result.err)
        let reports = state.appendingPathComponent("reports")
        let files = try FileManager.default.contentsOfDirectory(atPath: reports.path)
        XCTAssertEqual(files.count, 1, "\(files)")
        let name = try XCTUnwrap(files.first)
        XCTAssertNotNil(name.range(of: #"^\d{8}-\d{6}-[a-z-]+\.html$"#, options: .regularExpression), name)
        XCTAssertTrue(name.hasSuffix("-report.html") || name.contains("-clean"), "kind, or report while unclassified")
        XCTAssertTrue(result.out.contains("open \"\(reports.appendingPathComponent(name).path)\""), result.out)
        let ignore = try String(contentsOf: state.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertTrue(ignore.split(separator: "\n").contains("reports/"), "reports are git-ignored: \(ignore)")
    }

    func testOpenOnCIIsIgnoredWithANote() throws {
        let dir = try scratch()
        let file = dir.appendingPathComponent("r.html")
        let result = try run(["analyze", Self.clean26, "--format", "html", "--open", "--no-env", "--no-history",
                              "-o", file.path], ci: true)
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.err.contains("note: --open ignored because CI=true"), result.err)
        XCTAssertTrue(result.out.contains("open \"\(file.path)\""), "not opened, so the hint prints: \(result.out)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testSavedJSONReportRoundTripsAndReRendersAsHTML() throws {
        let dir = try scratch()
        let json = dir.appendingPathComponent("report.json")
        let saved = try run(["analyze", Self.clean26, "--format", "json", "--top", "all", "--no-env", "--no-history",
                             "-o", json.path])
        XCTAssertEqual(saved.status, 0, saved.err)
        let again = try run(["analyze", json.path, "--format", "json"])
        XCTAssertEqual(again.status, 0, again.err)
        XCTAssertEqual(again.out, try String(contentsOf: json, encoding: .utf8), "json → load → json is byte-equal")

        let html = dir.appendingPathComponent("report.html")
        let rendered = try run(["analyze", json.path, "--format", "html", "--no-redact", "-o", html.path])
        XCTAssertEqual(rendered.status, 0, rendered.err)
        let page = try String(contentsOf: html, encoding: .utf8)
        let start = try XCTUnwrap(page.range(of: "data-encoding=\"json\">")).upperBound
        let end = try XCTUnwrap(page.range(of: "</script>", range: start..<page.endIndex)).lowerBound
        // A saved report has no task index: the blob is the saved JSON, with V13 measured on the page.
        var blob = try JSONReporter.decoder().decode(ReportDocument.self, from: Data(page[start..<end].utf8))
        let v13 = try XCTUnwrap(blob.validation.checks.firstIndex { $0.id == "V13" })
        XCTAssertEqual(blob.validation.checks[v13].status, "pass")
        XCTAssertTrue(blob.validation.checks[v13].detail?.hasSuffix("bytes (html, template included)") == true)
        let original = try JSONReporter.decoder().decode(ReportDocument.self, from: Data(contentsOf: json))
        blob.validation.checks[v13] = original.validation.checks[v13]
        XCTAssertEqual(try JSONReporter.renderString(blob), try String(contentsOf: json, encoding: .utf8))
    }

    /// Code review v0.2 #5: size never fails the command. A cap the page cannot meet writes it anyway, warns on
    /// stderr and exits 0; V13 in the page warns.
    func testHTMLOverTheCapIsWrittenWithAWarningAndExitsZero() throws {
        let dir = try scratch()
        let file = dir.appendingPathComponent("tiny.html")
        let result = try run(["analyze", Self.clean26, "--format", "html", "--max-report-bytes", "1000", "--no-env",
                              "--no-history", "-o", file.path, "--xcblame-dir", dir.appendingPathComponent(".x").path])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.err.contains("warning: the html report is "), result.err)
        XCTAssertTrue(result.err.contains("over --max-report-bytes 1000"), result.err)
        let page = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(page.contains("\"id\" : \"V13\",\n        \"status\" : \"warn\""), "V13 warns in the page")
        XCTAssertTrue(result.out.contains("0 fail"), result.out)
        let fits = try run(["analyze", Self.clean26, "--format", "html", "--max-report-bytes", "400000", "--no-env",
                            "--no-history", "-o", file.path, "--xcblame-dir", dir.appendingPathComponent(".x").path])
        XCTAssertEqual(fits.status, 0, fits.err)
        XCTAssertTrue(fits.err.contains("note: the html report was truncated to fit 400000 bytes"), fits.err)
    }

    func testIncompleteSavedReportFailsWithAReason() throws {
        let dir = try scratch()
        let json = dir.appendingPathComponent("partial.json")
        try Data(#"{"schemaVersion": "xcblame.report/1", "topN": 3}"#.utf8).write(to: json)
        let result = try run(["analyze", json.path, "--format", "html", "-o", dir.appendingPathComponent("x.html").path])
        XCTAssertEqual(result.status, 1, result.err)
        XCTAssertTrue(result.err.contains("re-rendering a saved JSON report failed"), result.err)
        XCTAssertTrue(result.err.contains("missing "), result.err)
    }
}
