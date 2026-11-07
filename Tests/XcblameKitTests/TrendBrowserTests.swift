import XCTest
@testable import XcblameKit

/// The trend page in headless Chrome with the network blocked (DESIGN §8.2.5 tier 2; docs/SCHEMA-v0.4.md "DOM
/// contract: trend"). Skips without Chrome.
final class TrendBrowserTests: XCTestCase {
    private static let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    private func dumpDOM(_ html: Data) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Self.chrome) else { throw XCTSkip("Google Chrome not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-dom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("trend.html")
        try html.write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.chrome)
        process.arguments = ["--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
                             "--user-data-dir=\(dir.appendingPathComponent("profile").path)",
                             "--host-resolver-rules=MAP * ~NOTFOUND", "--virtual-time-budget=3000", "--dump-dom",
                             file.absoluteString]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    private func openingTag(of id: String, in dom: String) throws -> String {
        let start = try XCTUnwrap(dom.range(of: "<section id=\"\(id)\""), "section \(id) missing")
        let end = try XCTUnwrap(dom.range(of: ">", range: start.upperBound..<dom.endIndex))
        return String(dom[start.lowerBound..<end.upperBound])
    }

    private func trendBody(_ dom: String) throws -> String {
        let start = try XCTUnwrap(dom.range(of: "<div id=\"trend-body\">"))
        let end = try XCTUnwrap(dom.range(of: "</section>", range: start.upperBound..<dom.endIndex))
        return String(dom[start.lowerBound..<end.lowerBound])
    }

    private func assertNoScriptErrors(_ dom: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(dom.contains("data-rendered=\"all\""), "rendered", file: file, line: line)
        let errors = try XCTUnwrap(dom.range(of: "<pre id=\"js-errors\""), file: file, line: line)
        let end = try XCTUnwrap(dom.range(of: "</pre>", range: errors.upperBound..<dom.endIndex), file: file, line: line)
        XCTAssertTrue(String(dom[errors.lowerBound..<end.upperBound]).hasSuffix("></pre>"), "js errors", file: file, line: line)
    }

    func testTrendPageFollowsTheDOMContract() throws {
        let dir = try makeHistoryDirectory()
        for minute in 1...6 {
            try TrendFixture.save(.init(minutes: Double(minute), wall: 20 + Double(minute), xcode: "26.0",
                                        commit: TrendFixture.hash("a"), branch: "main"), in: dir)
        }
        for minute in 7...12 {
            try TrendFixture.save(.init(minutes: Double(minute), wall: 30 + Double(minute), xcode: "26.1",
                                        commit: TrendFixture.hash("b"), branch: "main"), in: dir)
        }
        let id = try TrendFixture.save(.init(minutes: 13, kind: "incremental", wall: 3, busy: nil, xcode: "26.1"), in: dir)
        let doc = try Trend.run(history: dir)
        let dom = try dumpDOM(try HTMLReporter.renderTrend(doc, options: .init(redact: false, title: "xcblame trend")))
        try assertNoScriptErrors(dom)

        let tag = try openingTag(of: "trend", in: dom)
        XCTAssertFalse(tag.contains(" hidden"))
        XCTAssertTrue(tag.contains("data-total=\"13\""), tag)
        XCTAssertTrue(tag.contains("data-shown=\"13\""), tag)
        XCTAssertTrue(try openingTag(of: "compare", in: dom).contains(" hidden"))

        let body = try trendBody(dom)
        XCTAssertEqual(count("class=\"trend-group\"", in: body), 1)
        XCTAssertTrue(body.contains("id=\"trend-group-0\" data-key=\"\" data-total=\"13\""), "group")
        XCTAssertEqual(count("class=\"trend-series\"", in: body), 2)
        XCTAssertTrue(body.contains("id=\"trend-series-0-clean\" data-kind=\"clean\" data-total=\"12\""), "clean series")
        XCTAssertTrue(body.contains("id=\"trend-series-0-incremental\" data-kind=\"incremental\" data-total=\"1\""))
        XCTAssertEqual(count("class=\"trend-point\"", in: body) + count("class=\"trend-point trend-nowall\"", in: body), 13,
                       "one mark per history entry")
        XCTAssertTrue(body.contains("data-id=\"\(id)\""), "a mark carries its history entry id")
        XCTAssertEqual(count("data-row=", in: body), 13, "one table row per point")
        XCTAssertEqual(count("class=\"trend-marker\"", in: body), 1, "26.0 -> 26.1")
        XCTAssertTrue(body.contains("data-from=\"26.0\" data-to=\"26.1\""), body)
        // p50 of 21 ... 26 and 37 ... 42 (R-7): the median of twelve values is the mean of the middle two.
        XCTAssertTrue(body.contains("class=\"trend-p50\" data-value=\"31.5\""), "p50")
        XCTAssertTrue(body.contains("class=\"trend-p75\" data-value=\""), "p75")
        XCTAssertTrue(body.contains("class=\"trend-p95\" data-value=\""), "p95")
        XCTAssertTrue(dom.contains("id=\"trend-filter\""))
        XCTAssertTrue(dom.contains("13 of 13 history entries used."))
    }

    func testGroupedPageAndHostileStringsStayText() throws {
        let dir = try makeHistoryDirectory()
        let hostile = "</script><img src=x onerror=alert(1)>"
        try TrendFixture.save(.init(minutes: 1, xcode: "26.0", branch: hostile), in: dir)
        try TrendFixture.save(.init(minutes: 2, xcode: "26.1", branch: "main"), in: dir)
        try TrendFixture.save(.init(minutes: 3, xcode: "26.1"), in: dir)
        for by in TrendDocument.By.allCases {
            let doc = try Trend.run(history: dir, options: .init(by: by))
            let dom = try dumpDOM(try HTMLReporter.renderTrend(doc, options: .init(redact: false, title: "xcblame trend")))
            try assertNoScriptErrors(dom)
            let body = try trendBody(dom)
            XCTAssertEqual(count("class=\"trend-group\"", in: body), doc.groups.count, "\(by)")
            for (index, group) in doc.groups.enumerated() where !(group.key ?? "").contains("<") {
                XCTAssertTrue(body.contains("id=\"trend-group-\(index)\" data-key=\"\(group.key ?? "")\""), "\(by) group \(index)")
            }
            // The page's own script data holds the escaped JSON (inert); the rendered body must hold no element of it.
            XCTAssertFalse(body.contains("<img"), "\(by): a hostile string became markup")
        }
    }

    func testEmptyTrendShowsItsNotes() throws {
        let missing = try makeScratchDirectory().appendingPathComponent("history")
        let doc = try Trend.run(history: missing)
        let dom = try dumpDOM(try HTMLReporter.renderTrend(doc, options: .init(redact: false, title: "xcblame trend")))
        try assertNoScriptErrors(dom)
        XCTAssertTrue(try openingTag(of: "trend", in: dom).contains("data-total=\"0\""))
        XCTAssertTrue(try trendBody(dom).contains("no history entries in "))
    }
}
