import Foundation
import XCTest
@testable import XcblameKit

/// The #why view (docs/SCHEMA-v0.5.md "DOM contract: why"), rendered by headless Chrome from an attributed fixture.
final class WhyHTMLTests: XCTestCase {
    private static let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    private func dumpDOM(_ page: Data) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Self.chrome) else { throw XCTSkip("Google Chrome not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-why-dom-\(UUID().uuidString)")
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

    private func tag(_ selector: String, in dom: String) throws -> String {
        let start = try XCTUnwrap(dom.range(of: selector), "\(selector) missing")
        let end = try XCTUnwrap(dom.range(of: ">", range: start.upperBound..<dom.endIndex))
        return String(dom[start.lowerBound..<end.upperBound])
    }

    private func count(_ needle: String, in text: String) -> Int { text.components(separatedBy: needle).count - 1 }

    /// The body of `<ol id="…">` … `</ol>`.
    private func list(_ id: String, in dom: String) throws -> String {
        let start = try XCTUnwrap(dom.range(of: "<ol id=\"\(id)\""))
        let end = try XCTUnwrap(dom.range(of: "</ol>", range: start.upperBound..<dom.endIndex))
        return String(dom[start.lowerBound..<end.upperBound])
    }

    func testWhyDocumentDOMContract() throws {
        var (_, document) = try WhyFixtures.attributed(WhyFixtures.why26, test: self, topN: .max)
        var incremental = try XCTUnwrap(document.incremental)
        incremental.procedure = .init(mode: "zeroChange", touched: nil, builds: [
            .init(role: "settle", exitCode: 0, wall: 3, executedTasks: 575, executedWorkTasks: 200, historyId: "h1"),
            .init(role: "measure", exitCode: 0, wall: 2, executedTasks: 79, executedWorkTasks: 50, historyId: nil),
        ], backtraces: "on", showIncremental: false)
        // Data strings go in as text: markup in a cause must not become an element.
        incremental.causes[0].cause = "<img src=x onerror=alert(1)> changed"
        document = document.applying(incremental: incremental)
        let page = try HTMLReporter.renderWhy(document, taskIndex: nil, options: .init(redact: false, title: "")).data
        XCTAssertTrue(String(decoding: page, as: UTF8.self).contains("<title>xcblame why"))
        let dom = try dumpDOM(page)
        XCTAssertTrue(dom.contains("data-rendered=\"all\""))
        let errors = try XCTUnwrap(dom.range(of: "<pre id=\"js-errors\""))
        let errorsEnd = try XCTUnwrap(dom.range(of: "</pre>", range: errors.upperBound..<dom.endIndex))
        XCTAssertTrue(String(dom[errors.lowerBound..<errorsEnd.upperBound]).hasSuffix("></pre>"), "no js errors")

        let causes = incremental.causes
        let section = try tag("<section id=\"why\"", in: dom)
        XCTAssertTrue(section.contains("data-total=\"\(causes.count)\""), section)
        XCTAssertTrue(section.contains("data-shown=\"\(incremental.byTaskTime.count)\""), section)
        XCTAssertFalse(section.contains(" hidden"))
        XCTAssertTrue(try tag("<span id=\"why-v15\"", in: dom).contains("data-status=\"pass\""))
        XCTAssertTrue(try tag("<div id=\"why-unknown\"", in: dom).contains("data-share=\"0\""))
        XCTAssertTrue(dom.contains("xcblame why --backtraces -- &lt;xcodebuild args&gt;"), "copyable hint")
        XCTAssertTrue(dom.contains("id=\"why-summary\""))
        let tabs = try tag("<div id=\"why-tabs\"", in: dom)
        XCTAssertTrue(tabs.contains("role=\"tablist\""))
        XCTAssertTrue(dom.contains("data-tab=\"task\" aria-selected=\"true\""))
        XCTAssertTrue(dom.contains("data-tab=\"path\" aria-selected=\"false\""))

        let byTask = try list("why-by-task", in: dom)
        XCTAssertTrue(byTask.contains("data-total=\"\(incremental.byTaskTime.count)\""))
        XCTAssertEqual(count("data-cause-id=", in: byTask), incremental.byTaskTime.count)
        XCTAssertTrue(byTask.contains("data-cause-id=\"unknown\""), "the unknown row is always listed")
        let byPath = try list("why-by-path", in: dom)
        XCTAssertTrue(byPath.contains(" hidden"), "one tab at a time")
        XCTAssertEqual(count("data-cause-id=", in: byPath), incremental.byPathSeconds.count)

        // Cause tree: classes in vocabulary order, one .why-cause per cause with its tasksTotal.
        let present = ReportDocument.Incremental.classes.filter { cls in causes.contains { $0.class == cls } }
        let positions = try present.map { try XCTUnwrap(dom.range(of: "data-class=\"\($0)\""), $0).lowerBound }
        XCTAssertEqual(positions, positions.sorted())
        for cause in causes {
            XCTAssertTrue(dom.contains("class=\"why-cause\" data-cause-id=\"\(cause.id)\" data-total=\"\(cause.tasksTotal)\""),
                          cause.id)
        }
        XCTAssertTrue(dom.contains("&lt;img src=x onerror=alert(1)&gt; changed"))
        XCTAssertFalse(dom.contains("<img src=\"x\""))
        XCTAssertEqual(count("<li>", in: try XCTUnwrap(dom.components(separatedBy: "id=\"why-notes\"").last?
            .components(separatedBy: "</ul>").first)), incremental.notes.count)

        // Why document: #1, #7, #2, #3, #10; files, hotspots and findings hidden.
        let order = ["summary", "why", "timeline", "targets", "environment"].map { dom.range(of: "<section id=\"\($0)\"")!.lowerBound }
        XCTAssertEqual(order, order.sorted())
        for id in ["files", "hotspots", "findings"] { XCTAssertTrue(try tag("<section id=\"\(id)\"", in: dom).contains(" hidden"), id) }
    }

    /// `why --touch`: the Start-here box says the touch changed only the timestamp; a zero-change run does not.
    func testStartHereSaysWhatATouchSimulates() throws {
        var (_, document) = try WhyFixtures.attributed(WhyFixtures.why27, test: self)
        var incremental = try XCTUnwrap(document.incremental)
        incremental.procedure = .init(mode: "touch", touched: "/src/A.swift", builds: [
            .init(role: "measure", exitCode: 0, wall: 2, executedTasks: 4, executedWorkTasks: 1, historyId: nil),
        ], backtraces: "on", showIncremental: false)
        document = document.applying(incremental: incremental)
        let touch = try dumpDOM(try HTMLReporter.renderWhy(document, taskIndex: nil, options: .init(redact: false, title: "")).data)
        let start = try XCTUnwrap(touch.range(of: "<div id=\"start-body\""))
        let box = String(touch[start.lowerBound...].prefix(4000))
        XCTAssertTrue(box.contains("--touch changes only the file's timestamp, so Swift recompiled just this file. To see what one real edit rebuilds, add a line to the file and run: "), box)
        XCTAssertTrue(box.contains("xcblame why --backtraces -- "), box)
        incremental.procedure?.mode = "zeroChange"
        incremental.procedure?.touched = nil
        let zero = try dumpDOM(try HTMLReporter.renderWhy(document.applying(incremental: incremental), taskIndex: nil,
                                                          options: .init(redact: false, title: "")).data)
        let zeroStart = try XCTUnwrap(zero.range(of: "<div id=\"start-body\""))
        XCTAssertFalse(String(zero[zeroStart.lowerBound...].prefix(4000)).contains("--touch changes only the file"))
    }

    func testAnalyzeReportShowsWhyWithoutProcedure() throws {
        let (_, document) = try WhyFixtures.attributed(WhyFixtures.remarks27, test: self)
        let dom = try dumpDOM(try HTMLReporter.render(document, taskIndex: nil, options: .init(redact: false, title: "t")))
        let section = try tag("<section id=\"why\"", in: dom)
        XCTAssertFalse(section.contains(" hidden"))
        XCTAssertTrue(try tag("<div id=\"why-unknown\"", in: dom).contains("data-share=\"\(document.incremental!.unknownShare!)\""))
        XCTAssertFalse(try tag("<section id=\"files\"", in: dom).contains(" hidden"), "a report keeps every section")
    }
}
