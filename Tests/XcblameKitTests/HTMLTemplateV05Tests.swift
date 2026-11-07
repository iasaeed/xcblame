import Foundation
import XCTest
@testable import XcblameKit

/// The v0.5 template regions (docs/SCHEMA-v0.5.md "HTML views"): sections #7 why, #8 fixed costs and #9 module graph,
/// hidden until their member is non-null, filled by lanes B and C in disjoint regions.
final class HTMLTemplateV05Tests: XCTestCase {
    private static let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    private static let regions = ["why", "fixedcosts", "modulegraph"]

    func testMarkedRegionsAndSectionsExistOnceInOrderAndAreHiddenByDefault() {
        let html = ReportTemplate.html
        for name in Self.regions {
            for marker in ["<!-- xcblame:\(name):start -->", "<!-- xcblame:\(name):end -->", "xcblame:\(name):css:start",
                           "xcblame:\(name):css:end", "// xcblame:\(name):js:start", "// xcblame:\(name):js:end"] {
                XCTAssertEqual(html.components(separatedBy: marker).count - 1, 1, marker)
            }
            let start = html.range(of: "<section id=\"\(name)\"")!
            XCTAssertTrue(html[start.lowerBound...].prefix(120).contains(" hidden>"), "\(name) starts hidden")
        }
        for function in ["function renderWhy(doc)", "function renderFixedCosts(doc)", "function renderModuleGraph(doc)"] {
            XCTAssertTrue(html.contains(function), function)
        }
        // CSS and JS regions follow the trend regions; the markup sits with the report sections (before compare).
        for kind in ["", ":css", ":js"] {
            let ends = (kind.isEmpty ? [] : ["xcblame:trend\(kind):end"]) + ["xcblame:why\(kind):end", "xcblame:fixedcosts\(kind):end"]
            let starts = (kind.isEmpty ? [] : ["xcblame:why\(kind):start"]) + ["xcblame:fixedcosts\(kind):start", "xcblame:modulegraph\(kind):start"]
            for (end, start) in zip(ends, starts) {
                XCTAssertLessThan(html.range(of: end)!.lowerBound, html.range(of: start)!.lowerBound, "\(end) < \(start)")
            }
        }
        // #7-#9 sit between findings (#6) and environment (#10).
        XCTAssertLessThan(html.range(of: "<section id=\"findings\"")!.lowerBound, html.range(of: "<section id=\"why\"")!.lowerBound)
        XCTAssertLessThan(html.range(of: "<section id=\"modulegraph\"")!.lowerBound,
                          html.range(of: "<section id=\"environment\"")!.lowerBound)
    }

    private func dumpDOM(_ page: Data) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Self.chrome) else { throw XCTSkip("Google Chrome not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-dom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("page.html")
        try page.write(to: file)
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

    private func openingTag(of id: String, in dom: String) throws -> String {
        let start = try XCTUnwrap(dom.range(of: "<section id=\"\(id)\""), "section \(id) missing")
        let end = try XCTUnwrap(dom.range(of: ">", range: start.upperBound..<dom.endIndex))
        return String(dom[start.lowerBound..<end.upperBound])
    }

    private func assertNoJSErrors(_ dom: String) throws {
        XCTAssertTrue(dom.contains("data-rendered=\"all\""))
        let errors = try XCTUnwrap(dom.range(of: "<pre id=\"js-errors\""))
        let end = try XCTUnwrap(dom.range(of: "</pre>", range: errors.upperBound..<dom.endIndex))
        XCTAssertTrue(String(dom[errors.lowerBound..<end.upperBound]).hasSuffix("></pre>"), "js errors")
    }

    private func render(_ document: ReportDocument) throws -> Data {
        try HTMLReporter.render(document, taskIndex: nil, options: .init(redact: false, title: "t"))
    }

    func testSectionsShowOnlyWhenTheirMemberIsPresent() throws {
        // v0.5 integration: a pipeline report now carries fixedCosts and moduleGraph (lane C) but not incremental
        // (that needs the command step); with all three members null, all three sections stay hidden.
        let pipeline = try dumpDOM(try render(try syntheticReport()))
        try assertNoJSErrors(pipeline)
        XCTAssertTrue(try openingTag(of: "why", in: pipeline).contains(" hidden"), "why hidden without incremental")
        for id in ["fixedcosts", "modulegraph"] {
            XCTAssertFalse(try openingTag(of: id, in: pipeline).contains(" hidden"), "\(id) shown for a pipeline report")
        }
        var none = try syntheticReport()
        none.incremental = nil
        none.fixedCosts = nil
        none.moduleGraph = nil
        let empty = try dumpDOM(try render(none))
        try assertNoJSErrors(empty)
        for id in Self.regions { XCTAssertTrue(try openingTag(of: id, in: empty).contains(" hidden"), "\(id) hidden") }

        var document = try V05Samples.populatedReport()
        document.incremental?.procedure = nil
        let full = try dumpDOM(try render(document))
        try assertNoJSErrors(full)
        XCTAssertTrue(try openingTag(of: "why", in: full).contains("data-total=\"2\""))
        XCTAssertTrue(try openingTag(of: "fixedcosts", in: full).contains("data-total=\"2\""))
        XCTAssertTrue(try openingTag(of: "modulegraph", in: full).contains("data-total=\"3\""))
        for id in Self.regions { XCTAssertFalse(try openingTag(of: id, in: full).contains(" hidden"), "\(id) shown") }
        XCTAssertFalse(try openingTag(of: "files", in: full).contains(" hidden"))
    }

    func testAWhyDocumentShowsSections1_7_2_3_10() throws {
        let dom = try dumpDOM(try render(try V05Samples.populatedReport()))
        try assertNoJSErrors(dom)
        for id in ["files", "hotspots", "findings", "fixedcosts", "modulegraph"] {
            XCTAssertTrue(try openingTag(of: id, in: dom).contains(" hidden"), "\(id) hidden")
        }
        let order = ["summary", "why", "timeline", "targets", "environment"].map { dom.range(of: "<section id=\"\($0)\"")!.lowerBound }
        XCTAssertEqual(order, order.sorted(), "why moved after the summary")
    }
    /// v0.5 integration (the v0.4 unique-ids rule of the compare page, extended to the report page): an analyze page
    /// with all three v0.5 members, a why page (sections 1, 7, 2, 3, 10) and a doctor page (none of the three) render
    /// with no JS error, no id used twice anywhere on the page, and `data-total` on every shown v0.5 section.
    func testAnalyzeWhyAndDoctorPagesHaveUniqueIdsAndNoErrors() throws {
        var analyze = try V05Samples.populatedReport()
        analyze.incremental?.procedure = nil
        let why = try V05Samples.populatedReport()
        let pages: [(name: String, data: Data, shown: [String])] = [
            ("analyze", try HTMLReporter.renderReport(analyze, taskIndex: nil, options: .init(redact: false, title: "xcblame report")).data,
             Self.regions),
            ("why", try HTMLReporter.renderWhy(why, taskIndex: nil, options: .init(redact: false, title: "xcblame report")).data,
             ["why"]),
            ("doctor", try HTMLReporter.renderReport(HTMLSample.doctor(hostileStrings: false), taskIndex: nil,
                                                     options: .init(redact: false, title: "xcblame doctor")).data, []),
        ]
        let idPattern = try NSRegularExpression(pattern: " id=\"([^\"]+)\"")
        for page in pages {
            let dom = try dumpDOM(page.data)
            try assertNoJSErrors(dom)
            XCTAssertTrue(dom.contains("data-rendered=\"all\""), "\(page.name): every section rendered")
            // Elements only: the script's own text (comments naming ids) is not part of the DOM tree.
            let markup = try NSRegularExpression(pattern: "<script[^>]*>[\\s\\S]*?</script>")
                .stringByReplacingMatches(in: dom, range: NSRange(dom.startIndex..., in: dom), withTemplate: "")
            let ids = idPattern.matches(in: markup, range: NSRange(markup.startIndex..., in: markup))
                .compactMap { Range($0.range(at: 1), in: markup).map { String(markup[$0]) } }
            XCTAssertTrue(ids.contains("js-errors") && ids.contains("summary"), "\(page.name): ids found")
            let duplicated = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
            XCTAssertEqual(duplicated, [], "\(page.name): ids must be unique on the report page")
            for id in Self.regions {
                let tag = try openingTag(of: id, in: dom)
                if page.shown.contains(id) {
                    XCTAssertFalse(tag.contains(" hidden"), "\(page.name): \(id) shown")
                    XCTAssertTrue(tag.contains("data-total=\""), "\(page.name): \(id) has data-total: \(tag)")
                } else {
                    XCTAssertTrue(tag.contains(" hidden"), "\(page.name): \(id) hidden")
                }
            }
        }
    }
}
