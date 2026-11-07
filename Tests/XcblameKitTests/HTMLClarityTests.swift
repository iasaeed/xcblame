import Foundation
import XCTest
@testable import XcblameKit

/// The junior-reader contract of the HTML pages (docs/reviews/html-clarity-audit.md, DESIGN §8.2.5 clarity note): a
/// "Start here" box with at least one action link, a "What this shows" line in every section, a glossary whose every
/// dotted term has its anchor, column headers with definitions, visible "showing N of M" lines, no collapsed block that
/// hides a table, charts with `data-total`, and no script error, on all five page kinds. Headless Chrome; skips without it.
final class HTMLClarityTests: XCTestCase {
    private static let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

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

    private func matches(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: group), in: text).map { String(text[$0]) }
        }
    }

    /// Every `<section id=…>` of the page: (id, opening tag, body).
    private func sections(_ dom: String) -> [(id: String, tag: String, body: String)] {
        var out: [(String, String, String)] = []
        var at = dom.startIndex
        while let start = dom.range(of: "<section id=\"", range: at..<dom.endIndex),
              let tagEnd = dom.range(of: ">", range: start.upperBound..<dom.endIndex),
              let end = dom.range(of: "</section>", range: tagEnd.upperBound..<dom.endIndex) {
            let tag = String(dom[start.lowerBound..<tagEnd.upperBound])
            out.append((String(tag.dropFirst("<section id=\"".count).prefix { $0 != "\"" }), tag,
                        String(dom[tagEnd.upperBound..<end.lowerBound])))
            at = end.upperBound
        }
        return out
    }

    /// The visible text of a DOM fragment: scripts (the embedded JSON keeps catalog codes on purpose) and tags removed.
    private func text(_ html: String) -> String {
        var out = html.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        return out.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&nbsp;", with: " ")
    }

    /// The `<ol id="…">` list inside `body`.
    private func list(_ id: String, in body: String) -> String? {
        guard let start = body.range(of: "<ol id=\"\(id)\""), let end = body.range(of: "</ol>", range: start.upperBound..<body.endIndex) else { return nil }
        return String(body[start.lowerBound..<end.upperBound])
    }

    /// Junior-reader round 2: what the Start-here box may suggest and how it counts the checks.
    private func assertActions(_ start: String, kind: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let actions = try XCTUnwrap(list("start-actions", in: start), "\(kind): an action list", file: file, line: line)
        for pseudo in ["explicit modules", "build system"] {
            XCTAssertFalse(text(actions).contains("Target \(pseudo)") || text(actions).contains("target \(pseudo)"),
                           "\(kind): an action names the pseudo-target \(pseudo)", file: file, line: line)
        }
        XCTAssertFalse(text(actions).contains("Check:"), "\(kind): an action is an action, not \"Check:\"", file: file, line: line)
    }

    /// The card id the page gives a finding (`findingId` in the template).
    private func findingAnchor(_ f: ReportDocument.Finding) -> String {
        "finding-" + f.ruleId + "-" + String(f.signalKey.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
    }

    private func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: " \(name)=\"") else { return nil }
        return String(tag[range.upperBound...].prefix { $0 != "\"" })
    }

    /// The checks every page kind must pass; returns the DOM for page-specific checks.
    @discardableResult
    private func assertClear(_ page: Data, kind: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let dom = try dumpDOM(page)
        XCTAssertTrue(dom.contains("data-rendered=\"all\""), "\(kind): every section rendered", file: file, line: line)
        let errors = try XCTUnwrap(dom.range(of: "<pre id=\"js-errors\""), file: file, line: line)
        let errorsEnd = try XCTUnwrap(dom.range(of: "</pre>", range: errors.upperBound..<dom.endIndex), file: file, line: line)
        XCTAssertTrue(String(dom[errors.lowerBound..<errorsEnd.upperBound]).hasSuffix("></pre>"),
                      "\(kind): js errors \(dom[errors.lowerBound..<errorsEnd.upperBound])", file: file, line: line)

        let all = sections(dom)
        let visible = all.filter { !$0.tag.contains(" hidden") }
        XCTAssertGreaterThanOrEqual(visible.count, 3, "\(kind): start here, a content section and the glossary", file: file, line: line)
        for section in visible {
            XCTAssertTrue(section.body.contains("class=\"what-this-shows\""), "\(kind): #\(section.id) has a What this shows line",
                          file: file, line: line)
        }

        // Start here: first section, at least one action that links to an element of the page.
        XCTAssertEqual(visible.first?.id, "start-here", "\(kind): Start here comes first", file: file, line: line)
        let start = try XCTUnwrap(all.first { $0.id == "start-here" }, file: file, line: line)
        let links = matches("(class=\"start-link\")", in: start.body)
        XCTAssertGreaterThanOrEqual(links.count, 1, "\(kind): Start here has an action link", file: file, line: line)
        for target in matches("href=\"#([^\"]+)\" class=\"start-link\"", in: start.body) {
            XCTAssertTrue(dom.contains(" id=\"\(target)\""), "\(kind): action link #\(target) has a target", file: file, line: line)
        }

        // Glossary: at least 25 terms, and every dotted term on the page has its anchor.
        let anchors = Set(matches("<dt id=\"(g-[^\"]+)\"", in: dom))
        XCTAssertGreaterThanOrEqual(anchors.count, 25, "\(kind): glossary terms", file: file, line: line)
        let terms = matches("class=\"term\" href=\"#(g-[^\"]+)\"", in: dom)
        XCTAssertFalse(terms.isEmpty, "\(kind): dotted terms in the text", file: file, line: line)
        for term in Set(terms) { XCTAssertTrue(anchors.contains(term), "\(kind): glossary anchor \(term)", file: file, line: line) }
        XCTAssertTrue(dom.contains("Glossary (\(anchors.count) terms)"), "\(kind): the glossary says how many terms", file: file, line: line)

        // Nothing with a table starts collapsed.
        var at = dom.startIndex
        while let open = dom.range(of: "<details", range: at..<dom.endIndex),
              let tagEnd = dom.range(of: ">", range: open.upperBound..<dom.endIndex),
              let close = dom.range(of: "</details>", range: tagEnd.upperBound..<dom.endIndex) {
            let tag = dom[open.lowerBound..<tagEnd.upperBound]
            if !tag.contains(" open") {
                XCTAssertFalse(dom[tagEnd.upperBound..<close.lowerBound].contains("<table"),
                               "\(kind): a collapsed block hides a table: \(tag)", file: file, line: line)
            }
            at = tagEnd.upperBound
        }

        // Every column header carries its definition as a tooltip (and the footnote line lists it).
        for header in matches("(<th scope=\"col\"[^>]*>)", in: dom) {
            XCTAssertNotNil(attribute("title", in: header), "\(kind): column header without a definition: \(header)", file: file, line: line)
        }
        // Every chart carries data-total and an svg.
        for chart in matches("(<figure class=\"chart\"[^>]*>)", in: dom) {
            XCTAssertNotNil(attribute("data-total", in: chart), "\(kind): chart without data-total: \(chart)", file: file, line: line)
        }
        for figure in dom.components(separatedBy: "<figure class=\"chart\"").dropFirst() {
            let chart = figure.components(separatedBy: "</figure>")[0]
            XCTAssertTrue(chart.contains("<svg"), "\(kind): a chart without an svg", file: file, line: line)
        }
        return dom
    }

    private func render(_ doc: ReportDocument, _ index: TaskIndex?) throws -> Data {
        try HTMLReporter.render(doc, taskIndex: index, options: .init(redact: false, title: "xcblame report"))
    }

    // MARK: - The five page kinds

    func testAnalyzePageOfTheDDBuild() throws {
        let model = try GraphFixtures.model(GraphFixtures.cleanDD)
        let result = try GraphFixtures.report(model, description: try BuildDescription.load(directory: GraphFixtures.descriptionDD))
        let doc = result.document
        let index = TaskIndex.make(model: model, analysis: result.analysis, document: doc)
        let dom = try assertClear(try render(doc, index), kind: "analyze")
        let byId = Dictionary(sections(dom).map { ($0.id, $0.body) }, uniquingKeysWith: { a, _ in a })
        let summary = try XCTUnwrap(byId["summary"])
        XCTAssertTrue(summary.contains("id=\"chart-wall\"") && summary.contains("id=\"chart-kinds\""), "summary charts")
        XCTAssertTrue(try XCTUnwrap(byId["targets"]).contains("id=\"chart-targets\""))
        XCTAssertTrue(try XCTUnwrap(byId["fixedcosts"]).contains("id=\"chart-fixedcosts\""))
        XCTAssertTrue(try XCTUnwrap(byId["modulegraph"]).contains("class=\"mg-arrow"), "module graph edges have arrows")
        XCTAssertTrue(try XCTUnwrap(byId["modulegraph"]).contains("longest chain: "))
        XCTAssertTrue(try XCTUnwrap(byId["timeline"]).contains("<canvas"))
        // Capped and complete tables both say how many rows they show, visibly.
        for id in ["timeline", "targets", "files"] {
            let body = try XCTUnwrap(byId[id], id)
            XCTAssertTrue(body.contains("<p class=\"shown-of-total\">"), "\(id): a visible shown-of-total line")
        }
        // The chart of targets counts the same rows as the table.
        let chart = try XCTUnwrap(matches("(<figure class=\"chart\" id=\"chart-targets\"[^>]*>)", in: dom).first)
        XCTAssertEqual(attribute("data-total", in: chart), String(doc.targetsTotal))
        // Validation in plain words.
        XCTAssertTrue(try XCTUnwrap(byId["environment"]).contains("The per-rule totals match Xcode's own timing summary."))

        // Round 2: actions never name Xcode's own work; it is explained instead; unmeasured findings are housekeeping.
        let start = try XCTUnwrap(byId["start-here"])
        try assertActions(start, kind: "analyze")
        XCTAssertTrue(text(start).contains("Xcode's own work (not yours to change)"), "explicit modules is explained, not an action")
        XCTAssertTrue(text(start).contains("explicit modules:"), "the pseudo-target is named in the explanation")
        let actions = try XCTUnwrap(list("start-actions", in: start))
        let housekeeping = doc.findings.filter(RulePlan.isHousekeeping)
        if !housekeeping.isEmpty {
            let hk = try XCTUnwrap(list("start-housekeeping", in: start), "unmeasured findings are listed as housekeeping")
            XCTAssertTrue(hk.contains("href=\"#finding-"), "housekeeping links to the findings")
            for anchor in matches("href=\"#(finding-[^\"]+)\"", in: actions) {
                XCTAssertFalse(housekeeping.contains { findingAnchor($0) == anchor }, "a housekeeping finding is not an action")
            }
        }
        XCTAssertTrue(text(actions).contains("Check it worked:") && text(actions).contains("xcblame compare"), "each action says how to check it")
        // The check counts add up, the not-applicable ones included.
        let quality = try XCTUnwrap(matches("(Data quality: [^→]*)", in: text(start)).first)
        func count(_ word: String) -> Int { Int(matches("(\\d+) " + word, in: quality).first ?? "0") ?? 0 }
        let numbers = matches("(\\d+) of (\\d+) checks passed", in: quality, group: 2).compactMap(Int.init) + [count("of")]
        XCTAssertEqual(count("of") + count("warned") + count("failed") + count("not applicable"), numbers[0],
                       "passed + warned + failed + n/a = checks: \(quality)")
        XCTAssertEqual(numbers[0], doc.validation.checks.count)
        // Long tables: top rows with a visible "Show all N rows" button whose N is the row count.
        let files = try XCTUnwrap(byId["files"])
        XCTAssertTrue(files.contains(">Show all \(doc.files?.count ?? 0) rows</button>"), "files: show-all button with the count")
        XCTAssertTrue(files.contains(">Showing 25 of \(doc.files?.count ?? 0) rows.<"), "files: top 25, count visible")
        // Consecutive Xcode steps on the critical path fold into one row.
        XCTAssertTrue(try XCTUnwrap(byId["timeline"]).contains("precompiled system modules"), "explicit-module steps grouped")
        // No citation codes, vendor names or "corpus" in the page text.
        try assertNoCitations(dom, kind: "analyze")
    }

    private func assertNoCitations(_ dom: String, kind: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let visible = text(dom)
        for pattern in ["\\[(OC|PP|BP|DS|P|S|K)\\]", "\\(S\\d+(, S\\d+)*\\)", "corpus app", "\\b(Allegro|Helm|Spotify|AutoScout24)\\b",
                        "shadowed, the overlay cannot win", "cli on CI", "\\(only if the oracle", "applied as "] {
            XCTAssertTrue(matches("(" + pattern + ")", in: visible).isEmpty, "\(kind): page text shows \(pattern): \(matches("(.{0,60}" + pattern + ".{0,30})", in: visible).first ?? "")",
                          file: file, line: line)
        }
    }

    func testPopulatedAndTruncatedPagesShowWhatWasCut() throws {
        let (populated, populatedIndex) = try HTMLSample.populated(hostileStrings: false)
        let full = try assertClear(try render(populated, populatedIndex), kind: "populated")
        let hotspots = try XCTUnwrap(sections(full).first { $0.id == "hotspots" }).body
        XCTAssertTrue(hotspots.contains("id=\"chart-hotspots\""), "hotspot chart")
        let findings = try XCTUnwrap(sections(full).first { $0.id == "findings" }).body
        for label in ["Why it costs time", "How much", "How sure", "What to change", "Safe to try?"] {
            XCTAssertTrue(findings.contains(label), "finding card: \(label)")
        }

        var (doc, index) = try HTMLSample.synthetic(tasks: 20_000, labels: 5_000, files: 2_000, hotspots: 4_000)
        var thinned: TaskIndex? = index
        ReportBudget.apply(&doc, taskIndex: &thinned, maxBytes: 3_000_000, templateBytes: ReportTemplate.html.utf8.count)
        let dom = try assertClear(try render(doc, thinned), kind: "truncated")
        for section in sections(dom) where ["targets", "files", "hotspots"].contains(section.id) {
            let total = Int(attribute("data-total", in: section.tag) ?? "") ?? -1
            let shown = Int(attribute("data-shown", in: section.tag) ?? "") ?? -1
            XCTAssertTrue(section.body.contains("<p class=\"shown-of-total\">"), "\(section.id): visible shown-of-total")
            if shown < total {
                XCTAssertTrue(section.body.contains("Showing \(shown.formatted(.number.locale(Locale(identifier: "en_US")))) of "),
                              "\(section.id): says how many rows of \(total) it shows")
                XCTAssertTrue(section.body.contains("--format json --top all"), "\(section.id): how to get every row")
            }
        }
    }

    func testDoctorPage() throws {
        let doc = HTMLSample.doctor(hostileStrings: false)
        let dom = try assertClear(try render(doc, nil), kind: "doctor")
        let start = try XCTUnwrap(sections(dom).first { $0.id == "start-here" }).body
        try assertActions(start, kind: "doctor")
        // Doctor measures nothing, so the catalog band ranks the actions: band M/S/XS with medium or high confidence
        // are actions; low confidence or no band at all is housekeeping.
        let actions = try XCTUnwrap(list("start-actions", in: start))
        XCTAssertTrue(actions.contains("href=\"#finding-"), "doctor: findings with a catalog band are actions")
        XCTAssertTrue(text(actions).contains("estimated impact: M (catalog estimate, not measured on your build)"), text(actions))
        let byId = Dictionary(doc.findings.map { (findingAnchor($0), $0) }, uniquingKeysWith: { a, _ in a })
        for anchor in matches("href=\"#(finding-[^\"]+)\"", in: actions) {
            let f = try XCTUnwrap(byId[anchor], anchor)
            XCTAssertFalse(RulePlan.isHousekeeping(f), "\(f.ruleId) is an action")
        }
        for phase in ["Upload Symbols runs sentry-cli", "Stamp Build: alwaysOutOfDate"] {
            XCTAssertTrue(text(actions).contains(phase), "doctor action list: \(phase)")
        }
        if let housekeeping = list("start-housekeeping", in: start) {
            for anchor in matches("href=\"#(finding-[^\"]+)\"", in: housekeeping) {
                let f = try XCTUnwrap(byId[anchor], anchor)
                XCTAssertNil(f.effectiveBand, "\(f.ruleId) in housekeeping has no band")
            }
        }
        // Offline: every confidence drops to low, but the same findings are actions, and the action says why it is low.
        let offline = HTMLSample.doctorOffline()
        XCTAssertTrue(offline.findings.allSatisfy { $0.confidence == "low" || $0.ruleId.hasPrefix("ENV-") })
        let offlineDom = try dumpDOM(try render(offline, nil))
        let offlineStart = try XCTUnwrap(sections(offlineDom).first { $0.id == "start-here" }).body
        let offlineActions = try XCTUnwrap(list("start-actions", in: offlineStart))
        XCTAssertEqual(Set(matches("href=\"#(finding-[^\"]+)\"", in: offlineActions)), Set(matches("href=\"#(finding-[^\"]+)\"", in: actions)),
                       "offline lists the same actions as online")
        XCTAssertTrue(text(offlineActions).contains("how sure: low — settings read offline; run without --offline for exact values"))
        let offlineById = Dictionary(offline.findings.map { (findingAnchor($0), $0) }, uniquingKeysWith: { a, _ in a })
        for anchor in matches("href=\"#(finding-[^\"]+)\"", in: list("start-housekeeping", in: offlineStart) ?? "") {
            XCTAssertNil(try XCTUnwrap(offlineById[anchor], anchor).effectiveBand, "offline housekeeping has no band")
        }
        XCTAssertTrue(text(start).contains("rules checked:"), "the rule counts in words")
        // The rule counts add up: found + passed + not checked + did not apply + suppressed = checked.
        let outcome = try XCTUnwrap(doc.doctor)
        let found = Set(doc.findings.map(\.ruleId)).count
        XCTAssertEqual(found + outcome.passed.count + outcome.notApplicable.count + outcome.suppressed.count, outcome.rulesEvaluated)
        XCTAssertTrue(text(start).contains("\(outcome.rulesEvaluated) rules checked: \(found) found something"), text(start))
        // Xcode's own setting names next to the raw key and value.
        let findings = try XCTUnwrap(sections(dom).first { $0.id == "findings" }).body
        XCTAssertTrue(text(findings).contains("Compilation Mode (SWIFT_COMPILATION_MODE)"), "UI label of the setting")
        XCTAssertTrue(text(findings).contains("Whole Module → Incremental"), "UI names of the values")
        XCTAssertTrue(text(findings).contains("Commit your changes first."), "the plan starts with the commit banner")
        XCTAssertTrue(text(findings).contains("By hand in Xcode: Target Acme › Build Phases › Run Script"), "manual steps are in the plan")
        // A plan step that edits a build setting in the project is measured first, and guards come before edits.
        let commands = doc.fixPlan.map(\.command)
        for (index, step) in doc.fixPlan.enumerated() where step.command.contains("--edit-project") && step.ruleId.hasPrefix("SET-") {
            XCTAssertTrue(commands[..<index].contains { $0.hasPrefix("xcblame verify --rules \(step.ruleId)") }, step.command)
        }
        let guardStep = try XCTUnwrap(commands.firstIndex(of: "xcblame fix --rules PHASE-002 --edit-project"), "the fixture has PHASE-002")
        // SET-004 is shadowed for the hook by the pbxproj: cli delivery first (SCHEMA-v0.6 Decision 2), then by hand.
        let edit = try XCTUnwrap(commands.firstIndex { $0.hasPrefix("xcblame verify --rules SET-004 ") }, "the fixture has SET-004")
        XCTAssertLessThan(guardStep, edit, "PHASE-002 guards the dSYM upload before SET-004 switches Debug to dwarf")
        // verify and fix ship in 0.6: plain, copyable commands; only --edit-project is labelled.
        XCTAssertFalse(text(findings).contains("available in xcblame 0.6"), "0.6 commands are no longer labelled")
        XCTAssertTrue(text(findings).contains("(not available yet: make the change by hand)"), "--edit-project is labelled")
        XCTAssertTrue(text(findings).contains("What you can run today:"), "the plan says what runs today")
        try assertNoCitations(dom, kind: "doctor")
        // Rules that could not run are collapsed with their count and a one-line reason.
        XCTAssertTrue(findings.contains("<summary>Did not apply ("), "collapsed with the count")
    }

    func testComparePage() throws {
        let doc = try Compare.run(a: .init(source: "a.xcactivitylog", documents: [CompareFixtures.xcode26.document],
                                           taskRows: [CompareFixtures.xcode26.rows]),
                                  b: .init(source: "b.xcactivitylog", documents: [CompareFixtures.xcode27.document],
                                           taskRows: [CompareFixtures.xcode27.rows]), options: .init(top: .max))
        let page = try HTMLReporter.renderCompare(doc, taskIndexA: CompareFixtures.xcode26.index, taskIndexB: CompareFixtures.xcode27.index,
                                                  options: .init(redact: false, title: "xcblame compare"))
        let dom = try assertClear(page, kind: "compare")
        let start = try XCTUnwrap(sections(dom).first { $0.id == "start-here" }).body
        XCTAssertTrue(start.contains("The Xcode version changed"), "the verdict names the Xcode change")
        XCTAssertTrue(start.contains("than build a"), "a human verdict")
        let band = try XCTUnwrap(dom.range(of: "id=\"cmp-band\""))
        XCTAssertTrue(dom[band.upperBound...].prefix(4000).contains("<svg"), "the headline difference is drawn")
        let ids = matches(" id=\"([^\"]+)\"", in: dom)
        XCTAssertEqual(Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted(), [], "unique ids")

        // Round 2: Xcode 27 renamed every task; the same compiles pair into changed rows instead of new + removed.
        XCTAssertGreaterThan(doc.tasks.changedTotal, 300, "renamed tasks are paired")
        XCTAssertLessThan(doc.tasks.addedTotal + doc.tasks.removedTotal, 60, "only real new and removed tasks are left")
        XCTAssertTrue(dom.contains("id=\"cmp-tasks-changed\""), "a changed-tasks block")
        XCTAssertFalse(doc.regression.attribution.contains { $0.detail.hasPrefix("28 new tasks") }, "no 28 new + 28 removed pair")
        try assertActions(start, kind: "compare")
        XCTAssertTrue(text(start).contains("xcblame build --runs 3"), "one run per side: the command to rerun 3 times")
        XCTAssertTrue(text(start).contains("likely"), "one run per side: the verdict is worded as likely")
        // Deltas on values under 100 ms are in ms, not percent.
        let body = try XCTUnwrap(sections(dom).first { $0.id == "compare" }).body
        XCTAssertFalse(text(body).contains("1005.1%"), "no percentage on a 27 ms value")
        for block in ["cmp-tasks-added", "cmp-tasks-removed", "cmp-tasks-changed"] {
            let total = block == "cmp-tasks-added" ? doc.tasks.addedTotal : block == "cmp-tasks-removed" ? doc.tasks.removedTotal : doc.tasks.changedTotal
            if total > 25 { XCTAssertTrue(body.contains(">Show all \(total) rows</button>"), "\(block): top 25 with a show-all button") }
        }
        try assertNoCitations(dom, kind: "compare")
    }

    func testTrendPage() throws {
        let dir = try makeHistoryDirectory()
        for minute in 1...4 {
            try TrendFixture.save(.init(minutes: Double(minute), wall: 20 + Double(minute), xcode: minute < 3 ? "26.0" : "26.1"), in: dir)
        }
        let dom = try assertClear(try HTMLReporter.renderTrend(try Trend.run(history: dir), options: .init(redact: false, title: "xcblame trend")),
                                  kind: "trend")
        let body = try XCTUnwrap(sections(dom).first { $0.id == "trend" }).body
        XCTAssertTrue(body.contains("class=\"trend-svg\""))
        XCTAssertTrue(body.contains("Xcode 26.0 → 26.1"), "the marker names both versions")
        XCTAssertTrue(body.contains("max ") && body.contains("min "), "min and max are labelled")
    }

    func testWhyPage() throws {
        var (_, document) = try WhyFixtures.attributed(WhyFixtures.why26, test: self, topN: .max)
        var incremental = try XCTUnwrap(document.incremental)
        incremental.procedure = .init(mode: "zeroChange", touched: nil, builds: [
            .init(role: "settle", exitCode: 0, wall: 3, executedTasks: 575, executedWorkTasks: 200, historyId: "h1"),
            .init(role: "measure", exitCode: 0, wall: 2, executedTasks: 79, executedWorkTasks: 50, historyId: nil),
        ], backtraces: "on", showIncremental: false)
        document = document.applying(incremental: incremental)
        let page = try HTMLReporter.renderWhy(document, taskIndex: nil, options: .init(redact: false, title: "")).data
        let dom = try assertClear(page, kind: "why")
        let why = try XCTUnwrap(sections(dom).first { $0.id == "why" }).body
        XCTAssertTrue(why.contains("id=\"chart-why\""), "executed time by cause class")
        XCTAssertTrue(why.contains("An input file changed"), "cause classes in plain words")
        let start = try XCTUnwrap(sections(dom).first { $0.id == "start-here" }).body
        XCTAssertTrue(start.contains("href=\"#why\""), "the biggest cause is an action")

        // Round 2: an edit that recompiled several files of a module says so, with what to do.
        XCTAssertFalse(matches("(recompiled \\d+ other files? of module \\w+)", in: text(why)).isEmpty, "the cause names the module and the file count")
        XCTAssertFalse(text(why).contains("@testable"), "no visibility claims that do not hold inside one module")
        XCTAssertTrue(text(why).contains("What to do:"), "each cause has a what-to-do line")
        XCTAssertTrue(text(start).contains("What to do:"), "the action carries the what-to-do line")
        try assertActions(start, kind: "why")
        // The task counts agree: the tile counts the tasks that ran, the reused ones are named next to it.
        let summary = try XCTUnwrap(sections(dom).first { $0.id == "summary" }).body
        XCTAssertTrue(text(summary).contains("Tasks that ran"), "tile name")
        XCTAssertTrue(text(start).contains("in which \(document.build.tasks) tasks ran"), "Start here counts the same tasks")
    }

    // MARK: - v0.6 verify and fix-plan pages (docs/SCHEMA-v0.6.md "HTML")

    func testVerifyPage() throws {
        let doc = FixVerifySamples.verify()
        let dom = try assertClear(try HTMLReporter.renderVerify(doc, options: .init(redact: false, title: "xcblame verify")), kind: "verify")
        let all = sections(dom)
        let verify = try XCTUnwrap(all.first { $0.id == "verify" })
        XCTAssertEqual(attribute("data-total", in: verify.tag), "3", "data-total is the results count")
        XCTAssertEqual(all.filter { !$0.tag.contains(" hidden") }.map(\.id), ["start-here", "verify", "glossary"])
        let start = try XCTUnwrap(all.first { $0.id == "start-here" }).body
        XCTAssertTrue(text(start).contains("Kept 1, reverted 2."), text(start))
        XCTAssertTrue(start.contains("id=\"verify-start\""))
        XCTAssertTrue(text(start).contains("Turning on SET-004 made clean builds 2.10 s faster (10.4%), more than the noise band (424 ms): kept."), text(start))
        XCTAssertTrue(text(start).contains("xcblame fix --rules SET-004 --apply"), "what to run next")
        try assertActions(start, kind: "verify")
        // One row per unit with the contract's attributes; one mark per run with arm, ok and settle.
        XCTAssertTrue(verify.body.contains("<table id=\"verify-results\""))
        XCTAssertEqual(matches("<tr ([^>]*data-verdict=\"[^\"]+\"[^>]*)>", in: verify.body).count, 3)
        XCTAssertTrue(verify.body.contains("data-rule=\"SET-030\" data-verdict=\"reverted\" data-reason=\"brokeBuild\""), "brokeBuild row")
        XCTAssertTrue(verify.body.contains("data-rule=\"SET-016\" data-verdict=\"reverted\" data-reason=\"slower\""), "slower row")
        XCTAssertEqual(matches("(<span class=\"verify-run\" data-arm=\"[AB]\" data-ok=\"(true|false)\" data-settle=\"(true|false)\" title=\"build \\d)", in: verify.body).count, 30)
        XCTAssertEqual(matches("(data-arm=\"B\" data-ok=\"false\")", in: verify.body).count, 1, "the failed B build")
        XCTAssertTrue(text(verify.body).contains("20.1 s ± 100 ms"), "p50 ± MAD")
        XCTAssertTrue(text(verify.body).contains("why? 1"), "a reverted verdict links to its reason")
        XCTAssertTrue(verify.body.contains("id=\"verify-chart\""), "A vs B chart")
        XCTAssertTrue(verify.body.contains("id=\"verify-next\""))
        XCTAssertFalse(verify.body.contains("id=\"verify-abort\""))
        for term in ["g-arm", "g-baseline-arm", "g-percentile", "g-noise-band", "g-mechanism", "g-task-set"] {
            XCTAssertTrue(dom.contains("class=\"term\" href=\"#\(term)\""), "\(term) is linked")
        }
        for anchor in ["g-arm", "g-baseline-arm", "g-mad", "g-noise-band", "g-mechanism", "g-overlay", "g-hook", "g-revert",
                       "g-settle-build", "g-indicative", "g-task-set", "g-percentile"] {
            XCTAssertTrue(dom.contains("<dt id=\"\(anchor)\""), "glossary \(anchor)")
        }
        let ids = matches(" id=\"([^\"]+)\"", in: dom)
        XCTAssertEqual(Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted(), [], "unique ids")

        // Aborted: the banner with the reason in plain words, and the alert in Start here.
        let aborted = try assertClear(try HTMLReporter.renderVerify(FixVerifySamples.aborted, options: .init(redact: false, title: "")),
                                      kind: "verify aborted")
        let body = try XCTUnwrap(sections(aborted).first { $0.id == "verify" }).body
        XCTAssertTrue(body.contains("id=\"verify-abort\""))
        XCTAssertTrue(text(body).contains("The run stopped early (timeout)."), text(body))
        XCTAssertTrue(text(body).contains("--max-minutes passed: give more minutes or fewer rules. 30 minutes passed after 12 builds"), text(body))
        XCTAssertTrue(body.contains("data-verdict=\"unverified\""))
        XCTAssertTrue(text(try XCTUnwrap(sections(aborted).first { $0.id == "start-here" }).body).contains("xcblame verify --plan 5ab3c2d1"))
        // Incremental: the settle build is named and linked.
        let incremental = try assertClear(try HTMLReporter.renderVerify(FixVerifySamples.verify(kind: .incremental),
                                                                        options: .init(redact: false, title: "")), kind: "verify incremental")
        XCTAssertTrue(incremental.contains("class=\"term\" href=\"#g-settle-build\""))
    }

    func testFixPlanPage() throws {
        let dom = try assertClear(try HTMLReporter.renderFixPlan(FixVerifySamples.plan, options: .init(redact: false, title: "xcblame fix plan")),
                                  kind: "fix plan")
        let all = sections(dom)
        let plan = try XCTUnwrap(all.first { $0.id == "fixplan" })
        XCTAssertEqual(all.filter { !$0.tag.contains(" hidden") }.map(\.id), ["start-here", "fixplan", "glossary"])
        XCTAssertEqual(attribute("data-total", in: plan.tag), "4")
        XCTAssertTrue(plan.body.contains("data-rule=\"SET-004\" data-state=\"planned\" data-verify=\"kept\""), "kept step")
        XCTAssertTrue(plan.body.contains("data-rule=\"SET-001\" data-state=\"skipped\" data-verify=\"reverted\""), "skipped step")
        XCTAssertTrue(text(plan.body).contains("cli (hook partially shadowed)"), "shadowing is named")
        XCTAssertTrue(text(plan.body).contains("defaults delete com.apple.dt.Xcode IDEBuildOperationMaxNumberOfConcurrentCompileTasks"))
        XCTAssertTrue(text(plan.body).contains("By hand in Xcode: Target Acme › Build Phases"), "a recommend step is a manual change")
        XCTAssertTrue(plan.body.contains("id=\"fixplan-guards\"") && plan.body.contains("id=\"fixplan-hook\""))
        let commands = try XCTUnwrap(plan.body.range(of: "id=\"fixplan-commands\""))
        XCTAssertTrue(plan.body[commands.upperBound...].contains(">Copy the 3 commands</button>"), "the commands are copyable")
        let start = try XCTUnwrap(all.first { $0.id == "start-here" }).body
        XCTAssertTrue(text(start).contains("4 steps:"), text(start))
        XCTAssertTrue(text(start).contains("1 kept by verify, 0 waiting to be measured."), text(start))
        XCTAssertTrue(text(start).contains("Install the hook, so Xcode reads the overlay:"), text(start))
        try assertActions(start, kind: "fix plan")
    }
}
