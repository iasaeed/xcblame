import XCTest
@testable import XcblameKit

/// The #fixedcosts and #modulegraph views (docs/SCHEMA-v0.5.md "HTML views") in headless Chrome, network blocked.
/// Skips without Chrome.
final class ModuleGraphHTMLTests: XCTestCase {
    private static let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    private func dumpDOM(_ page: Data) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Self.chrome) else { throw XCTSkip("Google Chrome not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-mg-\(UUID().uuidString)")
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
        let dom = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(dom.contains("data-rendered=\"all\""))
        let errors = try XCTUnwrap(dom.range(of: "<pre id=\"js-errors\""))
        let end = try XCTUnwrap(dom.range(of: "</pre>", range: errors.upperBound..<dom.endIndex))
        XCTAssertTrue(String(dom[errors.lowerBound..<end.upperBound]).hasSuffix("></pre>"),
                      "js errors: \(dom[errors.lowerBound..<end.upperBound])")
        return dom
    }

    private func tag(_ pattern: String, in dom: String) throws -> String {
        let range = try XCTUnwrap(dom.range(of: pattern), "\(pattern) missing")
        let end = try XCTUnwrap(dom.range(of: ">", range: range.upperBound..<dom.endIndex))
        return String(dom[range.lowerBound..<end.upperBound])
    }

    private func count(_ needle: String, in dom: String) -> Int { dom.components(separatedBy: needle).count - 1 }

    private func page(_ document: ReportDocument) throws -> String {
        try dumpDOM(try HTMLReporter.render(document, taskIndex: nil, options: .init(redact: false, title: "t")))
    }

    func testDDReportRendersTheGraphAndTheFixedCosts() throws {
        let document = try GraphFixtures.report(try GraphFixtures.model(GraphFixtures.cleanDD),
                                                description: try BuildDescription.load(directory: GraphFixtures.descriptionDD)).document
        let dom = try page(document)
        let section = try tag("<section id=\"modulegraph\"", in: dom)
        XCTAssertTrue(section.contains("data-total=\"10\"") && section.contains("data-shown=\"10\""), section)
        XCTAssertFalse(section.contains(" hidden"))
        let svg = try tag("<svg id=\"mg-svg\"", in: dom)
        XCTAssertTrue(svg.contains("data-edges-total=\"16\""), svg)
        XCTAssertTrue(try tag("<g id=\"mg-viewport\"", in: dom).contains("transform=\"translate(0 0) scale(1)\""))
        for id in ["mg-zoom-in", "mg-zoom-out", "mg-reset", "mg-summary", "mg-chain", "mg-fanin", "mg-fanout",
                   "mg-blockers", "mg-macros", "mg-cycles", "mg-variants", "mg-table", "mg-notes"] {
            XCTAssertTrue(dom.contains("id=\"\(id)\""), id)
        }
        XCTAssertEqual(count("class=\"mg-node", in: dom), 10)
        XCTAssertEqual(count("class=\"mg-edge", in: dom), 16)
        XCTAssertEqual(count("class=\"mg-edge mg-critical\"", in: dom), 4)
        XCTAssertTrue(dom.contains("data-id=\"AcmeApp\" data-depth=\"4\" data-owner=\"app\""))
        XCTAssertEqual(count("class=\"mg-badge mg-variants\"", in: dom), 1, "_SwiftSyntaxCShims has 3 variants")
        XCTAssertTrue(try tag("<div id=\"mg-variants\"", in: dom).contains("data-total=\"62\""))
        XCTAssertTrue(try tag("<ol id=\"mg-chain\"", in: dom).contains("data-total=\"5\""))

        let fc = try tag("<section id=\"fixedcosts\"", in: dom)
        XCTAssertTrue(fc.contains("data-total=\"2\"") && fc.contains("data-shown=\"2\""), fc)
        XCTAssertTrue(dom.contains("data-class=\"planning\"") && dom.contains("data-class=\"sdkStatCache\""))
        XCTAssertTrue(try tag("<p id=\"fc-total\"", in: dom).contains("data-seconds=\"3.12"))
        XCTAssertEqual(count("fc-assumption\">assumption<", in: dom), 2, "the 50 builds/day are labelled an assumption")
        XCTAssertTrue(dom.contains("id=\"fc-table\""))
    }

    func testCollapsedGroupsAndNoVariants() throws {
        var document = try GraphFixtures.report(try GraphFixtures.model(GraphFixtures.cleanDD),
                                                description: try BuildDescription.load(directory: GraphFixtures.descriptionDD)).document
        let graph = try XCTUnwrap(document.moduleGraph)
        var cut = HTMLReporter.collapsedModuleGraph(graph, keep: 1)
        cut.variants = nil
        cut.notes.append("variants: none in this test")
        document.moduleGraph = cut
        document.fixedCosts = FixedCosts.applying(entries: [], configBuildsPerDay: 20, to: document).fixedCosts
        let dom = try page(document)
        let plain = cut.nodes.filter { $0.collapsed == 0 }.count
        XCTAssertTrue(try tag("<section id=\"modulegraph\"", in: dom).contains("data-shown=\"\(plain)\""))
        XCTAssertGreaterThan(count("mg-node mg-collapsed", in: dom), 0)
        XCTAssertTrue(dom.contains("data-count=\""))
        XCTAssertTrue(dom.contains("not applicable: variants: none in this test"))
        XCTAssertEqual(count("fc-assumption\">assumption<", in: dom), 0)
        XCTAssertGreaterThan(count("fc-assumption\">config<", in: dom), 0)
    }
}
