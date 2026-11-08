import XCTest
@testable import XcblameKit

/// The compare page: the data blob (parity with `--format json`), the budget, and the DOM contract of
/// docs/SCHEMA-v0.4.md "DOM contract: compare" in headless Chrome (skipped where Chrome is not installed).
final class CompareHTMLTests: XCTestCase {
    private static let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

    private func document(_ options: Compare.Options = .init(top: .max)) throws -> CompareDocument {
        try Compare.run(a: .init(source: "a.xcactivitylog", documents: [CompareFixtures.xcode26.document],
                                 taskRows: [CompareFixtures.xcode26.rows]),
                        b: .init(source: "b.xcactivitylog", documents: [CompareFixtures.xcode27.document],
                                 taskRows: [CompareFixtures.xcode27.rows]), options: options)
    }

    private func bigIndex(tasks: Int, seed: Int) -> TaskIndex {
        var index = TaskIndex(start: [], dur: [], lane: [], target: [], kind: [], label: [], onPath: [], targets: ["App", "Kit"],
                              kinds: ["swiftCompile"], labels: [], dropped: [], taskIndexTotal: tasks, taskIndexShownShare: 1)
        for i in 0..<tasks {
            index.start.append(i * 7)
            index.dur.append(i % 40 == 0 ? 3000 : 10 + (i + seed) % 40)
            index.lane.append(i % 12)
            index.target.append(i % 2)
            index.kind.append(0)
            index.label.append(i)
            index.labels.append("SwiftCompile file\(i).swift")
            index.onPath.append(i % 500 == 0 ? 1 : 0)
        }
        return index
    }

    // MARK: - Blob

    func testBlobIsTheJSONDocumentPlusTheTaskIndexes() throws {
        let doc = try document()
        let plain = try HTMLReporter.compareBlob(doc, taskIndexA: nil, taskIndexB: nil)
        XCTAssertEqual(plain, String(decoding: try Compare.renderJSON(doc), as: UTF8.self), "byte parity with --format json")

        let blob = try HTMLReporter.compareBlob(doc, taskIndexA: CompareFixtures.xcode26.index, taskIndexB: CompareFixtures.xcode27.index)
        let data = Data(blob.utf8)
        XCTAssertEqual(try JSONReporter.decoder().decode(CompareDocument.self, from: data), doc, "the document decodes unchanged")
        struct Indexes: Decodable { var taskIndexA: TaskIndex; var taskIndexB: TaskIndex }
        let indexes = try JSONDecoder().decode(Indexes.self, from: data)
        XCTAssertEqual(indexes.taskIndexA, CompareFixtures.xcode26.index)
        XCTAssertEqual(indexes.taskIndexB, CompareFixtures.xcode27.index)
        // Spliced at their sorted positions: after "settings" and "schemaVersion", before "targets", "tasks" and "tool".
        let keys = blob.split(separator: "\n").filter { $0.hasPrefix("  \"") && !$0.hasPrefix("   ") }
            .map { $0.dropFirst(3).prefix { $0 != "\"" } }.map(String.init)
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertTrue(keys.contains("taskIndexA") && keys.contains("taskIndexB"))
        // The JSON stays inert inside <script>.
        var hostile = doc
        hostile.a.source = "</script><!-- x"
        let escaped = try HTMLReporter.compareBlob(hostile, taskIndexA: nil, taskIndexB: nil)
        XCTAssertFalse(escaped.contains("</script>"))
        XCTAssertFalse(escaped.contains("<!--"))
        XCTAssertEqual(try JSONReporter.decoder().decode(CompareDocument.self, from: Data(escaped.utf8)).a.source, "</script><!-- x")
    }

    func testPageIsDeterministicAndFillsTheTemplate() throws {
        let doc = try document()
        let options = HTMLReporter.Options(redact: false, title: "xcblame compare")
        let one = try HTMLReporter.renderCompare(doc, taskIndexA: nil, taskIndexB: nil, options: options)
        let two = try HTMLReporter.renderCompare(doc, taskIndexA: nil, taskIndexB: nil, options: options)
        XCTAssertEqual(one, two)
        let page = String(decoding: one, as: UTF8.self)
        XCTAssertFalse(page.contains("{{"))
        XCTAssertTrue(page.contains("<title>xcblame compare</title>"))
        XCTAssertTrue(page.contains("\"schemaVersion\" : \"xcblame.compare/1\""))
        XCTAssertTrue(page.contains("function renderCompare(doc)"))
        XCTAssertFalse(page.contains("The compare view is not implemented yet"))
    }

    func testBudgetThinsTheTaskIndexesThenDropsThemAndRecordsTheSteps() throws {
        let doc = try document()
        let a = bigIndex(tasks: 30_000, seed: 0), b = bigIndex(tasks: 30_000, seed: 5)
        let full = try HTMLReporter.renderCompare(doc, taskIndexA: a, taskIndexB: b, options: .init(redact: false, title: "t"))
        XCTAssertGreaterThan(full.count, 1_000_000, "the unbudgeted page is large")
        let template = try HTMLReporter.renderCompare(doc, taskIndexA: nil, taskIndexB: nil, options: .init(redact: false, title: "t")).count
        // Room for half a megabyte: each index is thinned, the on-path tasks stay.
        let cap = template + 500_000
        let thinned = try HTMLReporter.renderCompare(doc, taskIndexA: a, taskIndexB: b, options: .init(redact: false, maxBytes: cap, title: "t"))
        XCTAssertLessThanOrEqual(thinned.count, cap)
        let decoded = try decodedBlob(thinned)
        let steps = decoded.document.truncation.steps
        XCTAssertEqual(steps.map(\.step), ["taskIndexA", "taskIndexB"])
        for step in steps {
            XCTAssertLessThan(step.kept, 30_000)
            XCTAssertGreaterThan(step.kept, 0)
            XCTAssertEqual(step.total, 30_000)
        }
        let kept = try XCTUnwrap(decoded.a)
        XCTAssertEqual(kept.onPath.filter { $0 != 0 }.count, a.onPath.filter { $0 != 0 }.count, "on-path tasks stay")
        XCTAssertFalse(kept.dropped.isEmpty)
        // A cap the indexes cannot meet: they are dropped.
        let tight = try HTMLReporter.renderCompare(doc, taskIndexA: a, taskIndexB: b, options: .init(redact: false, maxBytes: template + 60_000, title: "t"))
        XCTAssertLessThanOrEqual(tight.count, template + 60_000)
        let dropped = try decodedBlob(tight)
        XCTAssertNil(dropped.a)
        XCTAssertEqual(dropped.document.truncation.steps.map(\.kept), [0, 0])
        // The headline numbers survive every step.
        XCTAssertEqual(dropped.document.regression, doc.regression)
        XCTAssertEqual(dropped.document.targetsTotal, doc.targetsTotal)
    }

    private func decodedBlob(_ page: Data) throws -> (document: CompareDocument, a: TaskIndex?) {
        let text = String(decoding: page, as: UTF8.self)
        let start = try XCTUnwrap(text.range(of: "data-encoding=\"json\">"))
        let end = try XCTUnwrap(text.range(of: "</script>", range: start.upperBound..<text.endIndex))
        let json = Data(text[start.upperBound..<end.lowerBound].utf8)
        struct Index: Decodable { var taskIndexA: TaskIndex? }
        return (try JSONReporter.decoder().decode(CompareDocument.self, from: json), try JSONDecoder().decode(Index.self, from: json).taskIndexA)
    }

    func testTablesAreCutToTheFloorWhenTheDocumentItselfIsOverTheCap() throws {
        var doc = try document()
        // Many targets and tasks: more rows than a tight cap holds.
        let rows = (0..<400).map { CompareDocument.Row(key: "Target\($0)", status: "changed", seconds: .init(a: 1, b: 2 + Double($0), delta: 1 + Double($0), deltaPct: nil), tasks: nil, isOther: false) }
        doc.targets = rows
        doc.targetsTotal = rows.count
        let template = try HTMLReporter.renderCompare(try document(), taskIndexA: nil, taskIndexB: nil, options: .init(redact: false, title: "t")).count
        let page = try HTMLReporter.renderCompare(doc, taskIndexA: nil, taskIndexB: nil, options: .init(redact: false, maxBytes: template + 20_000, title: "t"))
        let decoded = try decodedBlob(page).document
        XCTAssertEqual(decoded.targets?.count, 26, "25 rows and the other row")
        XCTAssertEqual(decoded.targetsTotal, 400)
        XCTAssertEqual(decoded.truncation.steps.first { $0.step == "targets" }?.kept, 26)
    }

    // MARK: - DOM

    private func dumpDOM(_ page: Data) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: Self.chrome) else { throw XCTSkip("Google Chrome not installed") }
        let dir = try CompareFixtures.tempDirectory(self)
        let file = dir.appendingPathComponent("page.html")
        try page.write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.chrome)
        process.arguments = ["--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
                             "--user-data-dir=\(dir.appendingPathComponent("profile").path)",
                             "--host-resolver-rules=MAP * ~NOTFOUND", "--virtual-time-budget=4000", "--dump-dom", file.absoluteString]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// The HTML between the opening tag of `id` and the opening tag of the next block with `class="cmp-block"` (or the end).
    private func blockHTML(_ id: String, in dom: String) throws -> String {
        let start = try XCTUnwrap(dom.range(of: "id=\"\(id)\""), "missing #\(id)")
        let rest = dom[(dom.range(of: ">", range: start.upperBound..<dom.endIndex)?.upperBound ?? start.upperBound)...]
        let end = rest.range(of: "class=\"cmp-block\"")?.lowerBound ?? rest.endIndex
        return String(rest[..<end])
    }

    private func attribute(_ name: String, ofElement id: String, in dom: String) throws -> String? {
        let start = try XCTUnwrap(dom.range(of: "id=\"\(id)\""), "missing #\(id)")
        let tagEnd = try XCTUnwrap(dom.range(of: ">", range: start.upperBound..<dom.endIndex))
        // Attributes may sit before or after `id`, so look at the whole opening tag.
        let tagStart = dom[..<start.lowerBound].lastIndex(of: "<") ?? dom.startIndex
        let tag = dom[tagStart..<tagEnd.lowerBound]
        guard let found = tag.range(of: " \(name)=\"") else { return nil }
        let value = tag[found.upperBound...]
        return String(value.prefix { $0 != "\"" })
    }

    private func rows(in html: String) -> Int { html.components(separatedBy: "data-row=\"").count - 1 }

    func testDOMContract() throws {
        let doc = try document(.init(thresholdPct: 0.05, top: .max))
        let page = try HTMLReporter.renderCompare(doc, taskIndexA: CompareFixtures.xcode26.index, taskIndexB: CompareFixtures.xcode27.index,
                                                  options: .init(redact: false, title: "xcblame compare"))
        let dom = try dumpDOM(page)
        XCTAssertTrue(dom.contains("data-rendered=\"all\""))
        let errors = try XCTUnwrap(dom.range(of: "<pre id=\"js-errors\""))
        let errorEnd = try XCTUnwrap(dom.range(of: "</pre>", range: errors.upperBound..<dom.endIndex))
        XCTAssertTrue(String(dom[errors.lowerBound..<errorEnd.upperBound]).hasSuffix("></pre>"), "no JS error")

        // The section: total = targetsTotal, shown = rows rendered in #cmp-targets.
        let section = try XCTUnwrap(dom.range(of: "<section id=\"compare\""))
        let sectionTag = String(dom[section.lowerBound..<dom.range(of: ">", range: section.upperBound..<dom.endIndex)!.upperBound])
        XCTAssertFalse(sectionTag.contains(" hidden"))
        XCTAssertTrue(sectionTag.contains("data-total=\"\(doc.targetsTotal)\""), sectionTag)
        let targetRows = rows(in: try blockHTML("cmp-targets", in: dom))
        XCTAssertEqual(targetRows, doc.targets?.count)
        XCTAssertTrue(sectionTag.contains("data-shown=\"\(targetRows)\""), sectionTag)
        XCTAssertEqual(try attribute("data-total", ofElement: "cmp-targets", in: dom), String(doc.targetsTotal))

        // Two side cards, headline, verdict badge and numbers.
        XCTAssertTrue(dom.contains("data-side=\"a\"") && dom.contains("data-side=\"b\""))
        XCTAssertEqual(try attribute("data-verdict", ofElement: "cmp-verdict", in: dom), doc.regression.verdict)
        XCTAssertEqual(try attribute("data-method", ofElement: "cmp-band", in: dom), "threshold")
        XCTAssertNotNil(try attribute("data-delta", ofElement: "cmp-wall", in: dom))
        XCTAssertEqual(Double(try XCTUnwrap(try attribute("data-delta", ofElement: "cmp-wall", in: dom))) ?? 0, doc.regression.wall.delta ?? -1, accuracy: 1e-6)
        XCTAssertNotNil(try attribute("data-delta", ofElement: "cmp-busy", in: dom))
        XCTAssertTrue(dom.contains("id=\"cmp-failed\""), "the threshold was exceeded")
        // v0.4 integration: the headline cell is #cmp-path-span, so #cmp-path (the composition block) is unique.
        XCTAssertNotNil(try attribute("data-delta", ofElement: "cmp-path-span", in: dom))
        XCTAssertEqual(dom.components(separatedBy: "id=\"cmp-path\"").count - 1, 1)
        let ids = try NSRegularExpression(pattern: " id=\"([^\"]+)\"").matches(in: dom, range: NSRange(dom.startIndex..., in: dom))
            .compactMap { Range($0.range(at: 1), in: dom).map { String(dom[$0]) } }
        let duplicated = Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        XCTAssertEqual(duplicated, [], "ids must be unique in the compare page")

        // Environment first: the first block after the headline, with the Xcode row.
        let headline = try XCTUnwrap(dom.range(of: "id=\"cmp-headline\""))
        let env = try XCTUnwrap(dom.range(of: "id=\"cmp-env\""))
        let attribution = try XCTUnwrap(dom.range(of: "id=\"cmp-attribution\""))
        let phases = try XCTUnwrap(dom.range(of: "id=\"cmp-phases\""))
        XCTAssertLessThan(headline.lowerBound, env.lowerBound)
        XCTAssertLessThan(env.lowerBound, attribution.lowerBound)
        XCTAssertLessThan(attribution.lowerBound, phases.lowerBound)
        XCTAssertEqual(try attribute("data-total", ofElement: "cmp-env", in: dom), String(doc.env.count))
        XCTAssertTrue(try blockHTML("cmp-env", in: dom).contains("data-field=\"xcode\""))
        XCTAssertEqual(try attribute("data-total", ofElement: "cmp-attribution", in: dom), String(doc.regression.attribution.count))
        XCTAssertEqual(rows(in: try blockHTML("cmp-attribution", in: dom)), doc.regression.attribution.count)

        // Counts of the diverging bars and the task tables.
        XCTAssertEqual(try attribute("data-total", ofElement: "cmp-phases", in: dom), String(doc.phases?.count ?? -1))
        XCTAssertEqual(rows(in: try blockHTML("cmp-phases", in: dom)), doc.phases?.count)
        XCTAssertEqual(try attribute("data-total", ofElement: "cmp-tasks-added", in: dom), String(doc.tasks.addedTotal))
        XCTAssertEqual(try attribute("data-total", ofElement: "cmp-tasks-removed", in: dom), String(doc.tasks.removedTotal))
        XCTAssertEqual(rows(in: try blockHTML("cmp-tasks-added", in: dom)), min(200, doc.tasks.added.count), "paged by 200")
        XCTAssertEqual(try attribute("data-shown", ofElement: "cmp-tasks-added", in: dom), String(min(200, doc.tasks.added.count)))
        XCTAssertEqual(try attribute("data-total", ofElement: "cmp-settings", in: dom), "0")

        // Both timelines on one axis.
        let axis = try XCTUnwrap(Double(try XCTUnwrap(try attribute("data-axis-seconds", ofElement: "cmp-timeline", in: dom))))
        XCTAssertEqual(axis, max(doc.a.wall ?? 0, doc.b.wall ?? 0), accuracy: 1.0)
        XCTAssertEqual(try blockHTML("cmp-timeline", in: dom).components(separatedBy: "<canvas").count - 1, 2)
    }

    func testDOMWithoutTaskIndexesAndWithMultipleRunsShowsIndicativeNotesAndNoTimeline() throws {
        let one = try CompareFixtures.report(span: 10), two = try CompareFixtures.report(span: 10.5)
        let doc = try Compare.run(a: .init(source: "a.json", documents: [one]), b: .init(source: "b.json", documents: [two]))
        let dom = try dumpDOM(try HTMLReporter.renderCompare(doc, taskIndexA: nil, taskIndexB: nil, options: .init(redact: false, title: "t")))
        XCTAssertTrue(dom.contains("data-rendered=\"all\""))
        XCTAssertFalse(dom.contains("id=\"cmp-timeline\""))
        XCTAssertEqual(try attribute("data-verdict", ofElement: "cmp-verdict", in: dom), "indicative")
        XCTAssertFalse(dom.contains("id=\"cmp-failed\""))
        XCTAssertEqual(try attribute("data-total", ofElement: "cmp-tasks-added", in: dom), "0")
        XCTAssertTrue(try blockHTML("cmp-tasks-added", in: dom).contains("task diff needs"), "the note instead of the table")
        XCTAssertTrue(try blockHTML("cmp-env", in: dom).contains("no environment differences"))
        let errors = try XCTUnwrap(dom.range(of: "<pre id=\"js-errors\""))
        let errorEnd = try XCTUnwrap(dom.range(of: "</pre>", range: errors.upperBound..<dom.endIndex))
        XCTAssertTrue(String(dom[errors.lowerBound..<errorEnd.upperBound]).hasSuffix("></pre>"), String(dom[errors.lowerBound..<errorEnd.upperBound]))
    }

    /// An ordinary build against a `build --deep` run: the cockpit carries the deep note.
    func testStartHereNamesTheDeepSide() throws {
        let plain = try CompareFixtures.report(span: 10)
        var deep = try CompareFixtures.report(span: 12)
        deep.deep = .init(enabled: true, scope: ["swift"], flagsInjected: ["-ftime-trace"], flagsDropped: [], shadowed: [],
                          derivedData: "/cache/deep/abc", derivedDataBytes: nil, wrapper: nil, exactFiles: nil, sources: nil, notes: [])
        let doc = try Compare.run(a: .init(source: "a.json", documents: [plain]), b: .init(source: "b.json", documents: [deep]))
        let dom = try dumpDOM(try HTMLReporter.renderCompare(doc, taskIndexA: nil, taskIndexB: nil, options: .init(redact: false, title: "t")))
        let start = try XCTUnwrap(dom.range(of: "<section id=\"start-here\""))
        let end = try XCTUnwrap(dom.range(of: "</section>", range: start.upperBound..<dom.endIndex))
        let box = String(dom[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(box.contains("b is a --deep build: its task times run slower."), box)
    }
}
