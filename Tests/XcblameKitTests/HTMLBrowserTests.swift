import Foundation
import XCTest
@testable import XcblameKit

/// DESIGN §8.2.5 tier 2: the rendered page in headless Chrome with the network blocked. Skips without Chrome.
final class HTMLBrowserTests: XCTestCase {
    private static let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    /// Runs headless Chrome on `html` and returns the DOM after scripts ran.
    private func dumpDOM(_ html: Data, fragment: String? = nil) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Self.chrome) else { throw XCTSkip("Google Chrome not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-dom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("report.html")
        try html.write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.chrome)
        process.arguments = ["--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
                             "--user-data-dir=\(dir.appendingPathComponent("profile").path)",
                             "--host-resolver-rules=MAP * ~NOTFOUND", "--virtual-time-budget=3000", "--dump-dom",
                             file.absoluteString + (fragment.map { "#" + $0 } ?? "")]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func render(_ doc: ReportDocument, _ index: TaskIndex?) throws -> Data {
        try HTMLReporter.render(doc, taskIndex: index, options: .init(redact: false, title: "xcblame report"))
    }

    /// The opening tag and body of `<section id="…">`.
    private func section(_ id: String, in dom: String) throws -> (tag: String, body: String) {
        let start = try XCTUnwrap(dom.range(of: "<section id=\"\(id)\""), "section \(id) missing")
        let tagEnd = try XCTUnwrap(dom.range(of: ">", range: start.upperBound..<dom.endIndex))
        let end = try XCTUnwrap(dom.range(of: "</section>", range: tagEnd.upperBound..<dom.endIndex))
        return (String(dom[start.lowerBound..<tagEnd.upperBound]), String(dom[tagEnd.upperBound..<end.lowerBound]))
    }

    private func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: "\(name)=\"") else { return nil }
        return String(tag[range.upperBound...].prefix { $0 != "\"" })
    }

    private func rows(_ body: String) -> Int { body.components(separatedBy: " data-row=\"").count - 1 }

    private func assertPage(_ doc: ReportDocument, _ index: TaskIndex?, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let dom = try dumpDOM(try render(doc, index))
        XCTAssertTrue(dom.contains("data-rendered=\"all\""), "every section rendered", file: file, line: line)
        let errors = try XCTUnwrap(dom.range(of: "<pre id=\"js-errors\""), file: file, line: line)
        let errorsEnd = try XCTUnwrap(dom.range(of: "</pre>", range: errors.upperBound..<dom.endIndex))
        let errorBox = String(dom[errors.lowerBound..<errorsEnd.upperBound])
        XCTAssertTrue(errorBox.hasSuffix("></pre>") && errorBox.contains("hidden"), "js errors: \(errorBox)", file: file, line: line)
        let paint = try XCTUnwrap(dom.range(of: "data-first-paint=\""), "first-paint mark", file: file, line: line)
        let ms = Int(dom[paint.upperBound...].prefix { $0.isNumber }) ?? .max
        XCTAssertLessThan(ms, 1000, "first paint \(ms) ms", file: file, line: line)

        let expected: [(String, Int, Int)] = [
            ("targets", doc.targetsTotal, doc.targets?.count ?? 0),
            ("files", doc.filesTotal, doc.files?.count ?? 0),
            ("hotspots", doc.hotspotsTotal, doc.hotspots?.count ?? 0),
            ("findings", doc.findingsTotal, doc.findings.count),
            ("timeline", doc.criticalPath?.segmentsTotal ?? 0, doc.criticalPath?.segments.count ?? 0),
            ("environment", doc.validation.checks.count, doc.validation.checks.count),
        ]
        for (id, total, shown) in expected {
            let (tag, body) = try section(id, in: dom)
            XCTAssertEqual(attribute("data-total", in: tag), String(total), "\(id) data-total", file: file, line: line)
            XCTAssertEqual(attribute("data-shown", in: tag), String(shown), "\(id) data-shown", file: file, line: line)
            switch id {
            case "findings":
                XCTAssertEqual(body.components(separatedBy: "<article class=\"finding\"").count - 1, shown, file: file, line: line)
            case "timeline":
                XCTAssertEqual(rows(body), min(200, shown) + min(200, doc.criticalPath?.waits.count ?? 0), id, file: file, line: line)
            case "environment":
                XCTAssertEqual(rows(body), shown + min(200, doc.decodeWarnings.count), id, file: file, line: line)
            default:
                XCTAssertEqual(rows(body), min(200, shown), id, file: file, line: line)
            }
        }
        return dom
    }

    func testAllNullDocumentRendersEverySectionWithNotApplicableLines() throws {
        // The pipeline fills the v0.2 members even for the synthetic model (an inferred path, utilization, files),
        // so null them here to prove the not-applicable rendering.
        var (doc, index) = try HTMLSample.bare()
        doc.criticalPath = nil
        doc.files = nil
        doc.filesTotal = 0
        doc.filesShownShare = nil
        doc.hotspots = nil
        doc.hotspotsTotal = 0
        doc.hotspotsShownShare = nil
        doc.timing.utilization = nil
        doc.timing.serialStretches = nil
        doc.timing.serialStretchesTotal = 0
        doc.timing.serialStretchesShownShare = nil
        doc.timing.serialThresholdLanes = nil
        doc.timing.serialSeconds = nil
        doc.timing.idleGaps = nil
        doc.timing.idleGapsTotal = 0
        doc.timing.idleGapsShownShare = nil
        doc.targets = doc.targets?.map { row in
            var row = row
            row.onPathSeconds = nil
            row.whatIfSeconds = nil
            return row
        }
        index.onPath = index.onPath.map { _ in 0 }
        let dom = try assertPage(doc, index)
        XCTAssertTrue(try section("timeline", in: dom).body.contains("not applicable: "), "null critical path says so")
        XCTAssertTrue(try section("files", in: dom).body.contains("not applicable: "))
        XCTAssertTrue(try section("hotspots", in: dom).body.contains("not applicable: "))
        XCTAssertTrue(try section("findings", in: dom).body.contains("No findings: no rules ran for this report"))
        XCTAssertTrue(try section("summary", in: dom).body.contains("Log span"))
    }

    func testPopulatedDocumentRendersRowsAndHostileTextAsText() throws {
        let (doc, index) = try HTMLSample.populated()
        let dom = try assertPage(doc, index)
        XCTAssertTrue(dom.contains("&lt;/script&gt;&lt;img src=x onerror=alert(1)&gt;"), "hostile text shown as text")
        XCTAssertFalse(dom.contains("<img src=\"x\""), "never parsed as markup")
        XCTAssertTrue(try section("timeline", in: dom).body.contains("<canvas"))
        XCTAssertTrue(try section("findings", in: dom).body.contains("SET-016"))
    }

    /// §8.2.4 doctor variant: project header, build sections reduced to "doctor runs no build", findings with
    /// provenance, overlay lines, copy buttons and inline rule docs, the fix plan, PASS / N/A / suppressed lists.
    func testDoctorPageRendersTheProjectVariant() throws {
        let doc = HTMLSample.doctor()
        let dom = try assertPage(doc, nil)
        let summary = try section("summary", in: dom).body
        for text in ["doctor · no build", "AcmeApp.xcodeproj", "objectVersion 77", "xcodebuild -showBuildSettings -json",
                     "4 project targets", "Rules checked"] {
            XCTAssertTrue(summary.contains(text), text)
        }
        for id in ["timeline", "targets", "files", "hotspots"] {
            XCTAssertTrue(try section(id, in: dom).body.contains("doctor runs no build"), id)
        }
        let findings = try section("findings", in: dom).body
        let outcomes = try XCTUnwrap(doc.doctor)
        for text in ["Fix plan (\(doc.fixPlan.count) steps)", "COMPILATION_CACHE_ENABLE_CACHING = YES // xcblame SET-016",
                     "xcblame verify --rules SET-016 --kind clean --mechanism hook", "Later with xcblame",
                     "not available yet: make the change by hand", "Or with xcblame (verify measures it first, fix writes it):",
                     "project settings (AcmeApp.xcodeproj)", "More about this rule",
                     "Passed (\(outcomes.passed.count))", "Did not apply (",
                     "Suppressed (\(outcomes.suppressed.count))", "deferred until PHASE-001"] {
            XCTAssertTrue(findings.contains(text), text)
        }
        XCTAssertTrue(dom.contains("&lt;/script&gt;&lt;img src=x onerror=alert(1)&gt;"), "hostile text shown as text")
        XCTAssertFalse(dom.contains("<img src=\"x\""), "never parsed as markup")
    }

    func testTruncatedSyntheticPagesTablesAt200AndShowsTheBanner() throws {
        var (doc, index) = try HTMLSample.synthetic(tasks: 20_000, labels: 5_000, files: 2_000, hotspots: 4_000)
        var thinned: TaskIndex? = index
        ReportBudget.apply(&doc, taskIndex: &thinned, maxBytes: 3_000_000, templateBytes: ReportTemplate.html.utf8.count)
        XCTAssertFalse(doc.truncation.steps.isEmpty)
        let dom = try assertPage(doc, thinned)
        XCTAssertTrue(try section("summary", in: dom).body.contains("This report is truncated to fit its size cap."))
        XCTAssertTrue(dom.contains("--format json --top all"), "how to get every row (the CLI has no chrome-trace format)")
    }

    func testTargetHashOpensTheDrawerWithThatTargetsTasks() throws {
        let (doc, index) = try HTMLSample.populated(hostileStrings: false)
        let name = try XCTUnwrap(doc.targets?.first { !$0.isOther }?.name)
        let dom = try dumpDOM(try render(doc, index), fragment: "target=" + name)
        let drawer = try XCTUnwrap(dom.range(of: "<aside id=\"drawer\""))
        let tag = dom[drawer.lowerBound...].prefix { $0 != ">" }
        XCTAssertFalse(tag.contains("hidden"), "drawer open: \(tag)")
        let count = index.target.filter { index.targets[$0] == name }.count
        XCTAssertTrue(dom.contains("shown \(count) of "), "drawer count for \(name)")
    }

    /// Verifier v0.2 #8 and #9: on the DAG report of the clean log the targets' what-if cells show positive seconds,
    /// the same numbers as the text report; the header says "N pass · M warn" and shows no degraded badge.
    func testWhatIfCellsArePositiveAndMatchTheText() throws {
        let model = try GraphFixtures.model(GraphFixtures.clean26)
        let result = try GraphFixtures.report(model, description: BuildDescription.load(directory: GraphFixtures.description26))
        let doc = result.document
        let index = TaskIndex.make(model: model, analysis: result.analysis, document: doc)
        let dom = try dumpDOM(try render(doc, index))
        let title = "critical path up to this much shorter if the target took no time (build plan only)"
        let regex = try NSRegularExpression(pattern: "<span title=\"\(NSRegularExpression.escapedPattern(for: title))\">([^<]*)</span>")
        let cells = regex.matches(in: dom, range: NSRange(dom.startIndex..., in: dom)).map {
            String(dom[Range($0.range(at: 1), in: dom)!])
        }
        let expected = (doc.targets ?? []).compactMap(\.whatIfSeconds)
        XCTAssertEqual(cells.count, expected.count, "\(cells)")
        func seconds(_ cell: String) -> Double? {
            cell.hasSuffix(" ms") ? Double(cell.dropLast(3)).map { $0 / 1000 } : Double(cell.dropLast(2))
        }
        let text = TextReporter.render(doc)
        for (cell, value) in zip(cells, expected) {
            XCTAssertFalse(cell.hasPrefix("−") || cell.hasPrefix("-"), cell)
            XCTAssertEqual(try XCTUnwrap(seconds(cell), cell), value, accuracy: 0.0051, cell)
            if value >= 1 { XCTAssertTrue(text.contains(TextReporter.duration(value)), "text shows \(value)") }
        }
        let acmeapp = try XCTUnwrap(doc.targets?.first { $0.name == "AcmeApp" }?.whatIfSeconds)
        XCTAssertGreaterThan(acmeapp, 1)
        let summary = try section("summary", in: dom).body + dom
        XCTAssertTrue(summary.contains(" pass · 1 warn<"), "header counts")
        XCTAssertFalse(dom.contains(">degraded<"), "no degraded badge on a report that is not degraded")
    }

    /// Code review v0.2 #13: a malformed `#target=` hash is ignored without a script error.
    func testMalformedTargetHashThrowsNothing() throws {
        let (doc, index) = try HTMLSample.populated(hostileStrings: false)
        let dom = try dumpDOM(try render(doc, index), fragment: "target=%E0%A4")
        let errors = try XCTUnwrap(dom.range(of: "<pre id=\"js-errors\""))
        let tag = dom[errors.lowerBound...].prefix { $0 != ">" }
        XCTAssertTrue(tag.contains("hidden"), "no js error: \(dom[errors.lowerBound...].prefix(300))")
        XCTAssertTrue(dom.contains("data-rendered=\"all\""))
    }

    /// `XCBLAME_HTML_SAMPLES=<dir> swift test --filter HTMLBrowserTests` writes the sample pages for a manual look.
    func testWriteSamplesWhenAsked() throws {
        guard let dir = ProcessInfo.processInfo.environment["XCBLAME_HTML_SAMPLES"] else { throw XCTSkip("set XCBLAME_HTML_SAMPLES") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let (bare, bareIndex) = try HTMLSample.bare()
        try render(bare, bareIndex).write(to: out.appendingPathComponent("bare.html"))
        let (full, fullIndex) = try HTMLSample.populated()
        try render(full, fullIndex).write(to: out.appendingPathComponent("populated.html"))
        let model = BuildModelBuilder.build(try SLFReader.read(url: SLFFixtures.cli26Clean), reader: .slf)
        let (clean, cleanIndex) = try HTMLSample.populated(model, hostileStrings: false)
        try render(clean, cleanIndex).write(to: out.appendingPathComponent("clean26.html"))
        let (big, bigIndex) = try HTMLSample.synthetic()
        try render(big, bigIndex).write(to: out.appendingPathComponent("synthetic50k.html"))
        try render(HTMLSample.doctor(), nil).write(to: out.appendingPathComponent("doctor.html"))
        try render(HTMLSample.doctor(hostileStrings: false, generated: true), nil)
            .write(to: out.appendingPathComponent("doctor-xcodegen.html"))
    }
}
