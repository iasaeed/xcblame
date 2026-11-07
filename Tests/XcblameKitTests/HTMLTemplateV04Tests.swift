import Foundation
import XCTest
@testable import XcblameKit

/// The v0.4 template regions (docs/SCHEMA-v0.4.md "HTML views"): marked, empty-by-default sections for compare and
/// trend that lanes B and C fill in disjoint regions, and the dispatch on `schemaVersion`.
final class HTMLTemplateV04Tests: XCTestCase {
    private static let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    func testMarkedRegionsAndSectionsExistOnceAndAreHiddenByDefault() {
        let html = ReportTemplate.html
        for name in ["compare", "trend"] {
            for marker in ["<!-- xcblame:\(name):start -->", "<!-- xcblame:\(name):end -->", "xcblame:\(name):css:start",
                           "xcblame:\(name):css:end", "// xcblame:\(name):js:start", "// xcblame:\(name):js:end"] {
                XCTAssertEqual(html.components(separatedBy: marker).count - 1, 1, marker)
            }
            XCTAssertEqual(html.components(separatedBy: "<section id=\"\(name)\"").count - 1, 1)
            let start = html.range(of: "<section id=\"\(name)\"")!
            XCTAssertTrue(html[start.lowerBound...].prefix(120).contains(" hidden>"), "\(name) starts hidden")
        }
        XCTAssertTrue(html.contains("function renderCompare(doc)"))
        XCTAssertTrue(html.contains("function renderTrend(doc)"))
        // Disjoint regions: compare comes before trend everywhere, so a merge never interleaves them.
        for pair in [("<!-- xcblame:compare:end -->", "<!-- xcblame:trend:start -->"),
                     ("xcblame:compare:css:end", "xcblame:trend:css:start"),
                     ("// xcblame:compare:js:end", "// xcblame:trend:js:start")] {
            XCTAssertLessThan(html.range(of: pair.0)!.lowerBound, html.range(of: pair.1)!.lowerBound)
        }
    }

    private func dumpDOM(_ page: String) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Self.chrome) else { throw XCTSkip("Google Chrome not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-dom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("page.html")
        try Data(page.utf8).write(to: file)
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

    private func page<T: Encodable>(_ document: T) throws -> String {
        var page = HTMLReporter.filledTemplate(toolVersion: XcblameVersion.current, generatedAt: V04Samples.date, title: "t")
        let blob = HTMLReporter.escapeScriptData(String(decoding: try JSONReporter.encoder().encode(document), as: UTF8.self))
        let range = try XCTUnwrap(page.range(of: HTMLReporter.dataPlaceholder))
        page.replaceSubrange(range, with: blob)
        return page
    }

    private func openingTag(of id: String, in dom: String) throws -> String {
        let start = try XCTUnwrap(dom.range(of: "<section id=\"\(id)\""), "section \(id) missing")
        let end = try XCTUnwrap(dom.range(of: ">", range: start.upperBound..<dom.endIndex))
        return String(dom[start.lowerBound..<end.upperBound])
    }

    private func assertDispatch(_ dom: String, shows id: String, hides other: String) throws {
        XCTAssertTrue(dom.contains("data-rendered=\"all\""))
        let errors = try XCTUnwrap(dom.range(of: "<pre id=\"js-errors\""))
        let end = try XCTUnwrap(dom.range(of: "</pre>", range: errors.upperBound..<dom.endIndex))
        XCTAssertTrue(String(dom[errors.lowerBound..<end.upperBound]).hasSuffix("></pre>"), "js errors")
        XCTAssertFalse(try openingTag(of: id, in: dom).contains(" hidden"), "\(id) shown")
        XCTAssertTrue(try openingTag(of: other, in: dom).contains(" hidden"), "\(other) hidden")
        XCTAssertTrue(try openingTag(of: "summary", in: dom).contains(" hidden"), "report sections hidden")
    }

    func testCompareAndTrendDocumentsDispatchToTheirOwnSection() throws {
        let compare = try dumpDOM(try page(V04Samples.compare))
        try assertDispatch(compare, shows: "compare", hides: "trend")
        XCTAssertTrue(try openingTag(of: "compare", in: compare).contains("data-total=\"\(V04Samples.compare.targetsTotal)\""))
        let trend = try dumpDOM(try page(V04Samples.trend))
        try assertDispatch(trend, shows: "trend", hides: "compare")
        XCTAssertTrue(try openingTag(of: "trend", in: trend).contains("data-total=\"\(V04Samples.trend.entriesUsed)\""))
    }
}
