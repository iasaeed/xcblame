import Foundation
import XCTest
@testable import XcblameKit

/// The cockpit contract of the HTML pages (DESIGN §8.2.4 and §8.2.5 "Cockpit decision (2026-11-08)", superseding the
/// Clarity tests): a first screen with `#headline`, `#floor`, `#waste` and at most three "Do this first" actions, each
/// with a saving, a confidence, one copyable command and an undo line; every section collapsed except Findings (and the
/// page's own section on compare, trend, verify and fix-plan pages); Xcode's own work folded behind a toggle; top-N
/// tables; the Details group closed; no glossary, no what-lines; at most 400 visible words and 150 visible rows on the
/// clean fixture; no script error. Headless Chrome; skips without it.
final class HTMLCockpitTests: XCTestCase {
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
                             "--host-resolver-rules=MAP * ~NOTFOUND", "--window-size=1280,900", "--virtual-time-budget=3000",
                             "--dump-dom", file.absoluteString]
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

    private func section(_ id: String, in dom: String, file: StaticString = #filePath, line: UInt = #line) throws
        -> (id: String, tag: String, body: String) {
        try XCTUnwrap(sections(dom).first { $0.id == id }, "section #\(id) missing", file: file, line: line)
    }

    /// The element with `id="…"`: its opening tag and its body up to the balanced closing tag. Nil when absent.
    private func element(_ id: String, in dom: String) -> (tag: String, body: String)? {
        guard let idRange = dom.range(of: " id=\"\(id)\""),
              let open = dom.range(of: "<", options: .backwards, range: dom.startIndex..<idRange.lowerBound),
              let tagEnd = dom.range(of: ">", range: idRange.upperBound..<dom.endIndex) else { return nil }
        let name = String(dom[open.upperBound...].prefix { $0.isLetter || $0.isNumber })
        let tag = String(dom[open.lowerBound..<tagEnd.upperBound])
        var depth = 1
        var at = tagEnd.upperBound
        while depth > 0, let next = dom.range(of: "<\(name)|</\(name)>", options: .regularExpression, range: at..<dom.endIndex) {
            let token = dom[next]
            if token.hasPrefix("</") {
                depth -= 1
                if depth == 0 { return (tag, String(dom[tagEnd.upperBound..<next.lowerBound])) }
            } else if let after = dom[next.upperBound...].first, after == " " || after == ">" {
                depth += 1
            }
            at = next.upperBound
        }
        return nil
    }

    /// The visible text of a DOM fragment: scripts (the embedded JSON keeps catalog codes on purpose) and tags removed.
    private func text(_ html: String) -> String {
        var out = html.replacingOccurrences(of: "<script[^>]*>[\\s\\S]*?</script>", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&nbsp;", with: " ")
        return out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    private func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: " \(name)=\"") else { return nil }
        return String(tag[range.upperBound...].prefix { $0 != "\"" })
    }

    /// The row id the page gives a finding (`findingId` in the template).
    private func findingAnchor(_ f: ReportDocument.Finding) -> String {
        "finding-" + f.ruleId + "-" + String(f.signalKey.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
    }

    /// The `li.act` items of `#start-actions`: (opening tag, body).
    private func actions(_ dom: String) -> [(tag: String, body: String)] {
        guard let list = element("start-actions", in: dom) else { return [] }
        return list.body.components(separatedBy: "<li ").dropFirst().compactMap { chunk in
            let tag = "<li " + chunk.prefix { $0 != ">" } + ">"
            guard (attribute("class", in: " " + tag.dropFirst(4)) ?? "").split(separator: " ").contains("act") else { return nil }
            return (tag, String(chunk.drop { $0 != ">" }.dropFirst()))
        }
    }

    /// Xcode's own pseudo-targets: never something to shorten.
    static let pseudoTargets: Set<String> = ["build system", "explicit modules", "no target", "(no target)"]

    /// The targets an action names in parentheses (`Shorten compile A.swift (AcmeApp)`) that are Xcode's own work: the
    /// pseudo-targets plus `extra` (the document's bucket targets).
    static func xcodeTargets(inAction text: String, extra: Set<String> = []) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"\(([^()]+)\)"#)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
        }.filter { pseudoTargets.contains($0.lowercased()) || extra.contains($0) }
    }

    /// The `tr[data-row]` rows of a section body that show on first load: not past the top N, not folded Xcode rows.
    private func visibleRows(_ body: String) -> [String] {
        body.components(separatedBy: "<tr ").dropFirst().map { "<tr " + $0 }.filter { row in
            let tag = row.prefix { $0 != ">" }
            return tag.contains(" data-row=\"") && !tag.contains("beyond-top") && !tag.contains("data-xcode=\"1\"")
        }
    }

    private func render(_ doc: ReportDocument, _ index: TaskIndex?) throws -> Data {
        try HTMLReporter.render(doc, taskIndex: index, options: .init(redact: false, title: "xcblame report"))
    }

    /// The `details.sec-d` that wraps a section's content: is it open? Nil when the section has none.
    private func isOpen(_ section: (id: String, tag: String, body: String)) -> Bool? {
        guard let range = section.body.range(of: "<details class=\"sec-d\"") ?? section.body.range(of: "<details class=\"sec-d ") else {
            return nil
        }
        let tag = section.body[range.lowerBound...].prefix { $0 != ">" }
        return tag.contains(" open")
    }

    // MARK: - Shared checks

    /// What every page kind must pass; `open` lists the sections whose `details.sec-d` starts open. Returns the DOM.
    @discardableResult
    private func assertCockpit(_ page: Data, kind: String, open: Set<String>, file: StaticString = #filePath,
                               line: UInt = #line) throws -> String {
        let dom = try dumpDOM(page)
        XCTAssertTrue(dom.contains("data-rendered=\"all\""), "\(kind): every section rendered", file: file, line: line)
        let errors = try XCTUnwrap(dom.range(of: "<pre id=\"js-errors\""), file: file, line: line)
        let errorsEnd = try XCTUnwrap(dom.range(of: "</pre>", range: errors.upperBound..<dom.endIndex), file: file, line: line)
        XCTAssertTrue(String(dom[errors.lowerBound..<errorsEnd.upperBound]).hasSuffix("></pre>"),
                      "\(kind): js errors \(dom[errors.lowerBound..<errorsEnd.upperBound])", file: file, line: line)
        let body = try XCTUnwrap(matches("(<body[^>]*>)", in: dom).first, file: file, line: line)
        XCTAssertNotNil(Int(attribute("data-visible-rows", in: body) ?? ""), "\(kind): data-visible-rows: \(body)", file: file, line: line)
        XCTAssertNotNil(Int(attribute("data-visible-words", in: body) ?? ""), "\(kind): data-visible-words: \(body)", file: file, line: line)

        // Removed by the cockpit decision.
        for gone in ["id=\"glossary\"", "id=\"index\"", "class=\"what-this-shows\"", "class=\"what-to-do\"", "class=\"col-defs\"",
                     "class=\"unk-notes\"", "class=\"shown-of-total\"", "class=\"term\"", "<article class=\"finding\"",
                     "id=\"chart-wall\"", "id=\"chart-targets\"", "id=\"chart-hotspots\""] {
            XCTAssertFalse(dom.contains(gone), "\(kind): \(gone) is gone", file: file, line: line)
        }
        XCTAssertFalse(text(dom).contains("What this shows"), "\(kind): no what-lines", file: file, line: line)

        // Header chips.
        XCTAssertNotNil(element("top", in: dom), "\(kind): header#top", file: file, line: line)
        XCTAssertNotNil(element("meta", in: dom), "\(kind): ul#meta chips", file: file, line: line)

        // The cockpit comes first and holds the headline.
        let visible = sections(dom).filter { !$0.tag.contains(" hidden") }
        XCTAssertEqual(visible.first?.id, "start-here", "\(kind): the cockpit comes first", file: file, line: line)
        let headline = try XCTUnwrap(element("headline", in: dom), "\(kind): p#headline", file: file, line: line)
        XCTAssertTrue(headline.tag.hasPrefix("<p "), "\(kind): headline is a p: \(headline.tag)", file: file, line: line)
        XCTAssertFalse(text(headline.body).isEmpty, "\(kind): headline has text", file: file, line: line)

        // Actions: at most three, each complete.
        let acts = actions(dom)
        XCTAssertLessThanOrEqual(acts.count, 3, "\(kind): at most 3 actions", file: file, line: line)
        let sources: Set<String> = ["finding", "path", "cause", "attribution", "hotspot", "verify", "plan"]
        for act in acts {
            let what = text(act.body)
            XCTAssertTrue(sources.contains(attribute("data-source", in: act.tag) ?? ""), "\(kind): data-source \(act.tag)", file: file, line: line)
            for part in ["act-what", "act-saving", "act-conf", "act-undo"] {
                XCTAssertTrue(act.body.contains("class=\"\(part)\""), "\(kind): action without .\(part): \(what)", file: file, line: line)
            }
            XCTAssertEqual(act.body.components(separatedBy: "class=\"cmd\"").count - 1, 1, "\(kind): one .cmd: \(what)", file: file, line: line)
            let cmd = act.body.components(separatedBy: "class=\"cmd\"").last ?? ""
            XCTAssertTrue(cmd.contains("<code"), "\(kind): .cmd holds a code: \(what)", file: file, line: line)
            XCTAssertNotNil(matches("(<button[^>]*data-copy[^>]*>Copy</button>)", in: cmd).first, "\(kind): Copy button: \(what)",
                            file: file, line: line)
            XCTAssertEqual(Self.xcodeTargets(inAction: what), [], "\(kind): an action names Xcode's own work: \(what)", file: file, line: line)
        }

        // Collapsed sections: only `open` starts open (the cockpit and the KPI strip are the first screen either way);
        // every section heading is an h2 with a short subtitle.
        for section in visible {
            guard let isOpen = isOpen(section) else { continue }
            if !["start-here", "summary"].contains(section.id) {
                XCTAssertEqual(isOpen, open.contains(section.id), "\(kind): #\(section.id) open \(isOpen)", file: file, line: line)
            }
            let summary = try XCTUnwrap(matches("<summary[^>]*>([\\s\\S]*?)</summary>", in: section.body).first,
                                        "\(kind): #\(section.id) summary", file: file, line: line)
            XCTAssertTrue(summary.contains("<h2"), "\(kind): #\(section.id) summary has an h2", file: file, line: line)
            for sub in matches("<span class=\"sub\"[^>]*>([\\s\\S]*?)</span>", in: summary) {
                XCTAssertLessThanOrEqual(text(sub).split(separator: " ").count, 8, "\(kind): #\(section.id) subtitle \(sub)", file: file, line: line)
            }
        }
        for id in open where visible.contains(where: { $0.id == id }) {
            XCTAssertEqual(isOpen(try section(id, in: dom, file: file, line: line)), true, "\(kind): #\(id) starts open", file: file, line: line)
        }

        // Charts that stay carry data-total.
        for chart in matches("(<figure class=\"chart\"[^>]*>)", in: dom) {
            XCTAssertNotNil(attribute("data-total", in: chart), "\(kind): chart without data-total: \(chart)", file: file, line: line)
        }
        let ids = matches(" id=\"([^\"]+)\"", in: dom)
        XCTAssertEqual(Dictionary(grouping: ids, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted(), [], "\(kind): unique ids",
                       file: file, line: line)
        try assertNoCitations(dom, kind: kind, file: file, line: line)
        return dom
    }

    /// The report-page checklist (DESIGN §8.2.4): floor, waste, KPIs, ribbon, Xcode fold, findings table, Details group.
    private func assertReportCockpit(_ dom: String, _ doc: ReportDocument, kind: String, file: StaticString = #filePath,
                                     line: UInt = #line) throws {
        let headline = try XCTUnwrap(element("headline", in: dom), file: file, line: line)
        if let span = doc.build.span {
            XCTAssertEqual(Double(attribute("data-span", in: headline.tag) ?? "") ?? -1, span, accuracy: 0.001,
                           "\(kind): data-span", file: file, line: line)
        }
        if let k = doc.build.kind { XCTAssertEqual(attribute("data-kind", in: headline.tag), k, "\(kind): data-kind", file: file, line: line) }
        if let path = doc.criticalPath {
            let floor = try XCTUnwrap(element("floor", in: dom), "\(kind): p#floor", file: file, line: line)
            XCTAssertEqual(Double(attribute("data-seconds", in: floor.tag) ?? "") ?? -1, path.span, accuracy: 0.001,
                           "\(kind): floor is the critical path", file: file, line: line)
            let waste = try XCTUnwrap(element("waste", in: dom), "\(kind): p#waste", file: file, line: line)
            if let span = doc.build.span {
                XCTAssertEqual(Double(attribute("data-seconds", in: waste.tag) ?? "") ?? -1, span - path.span, accuracy: 0.01,
                               "\(kind): waste is span minus the floor", file: file, line: line)
            }
        }
        if actions(dom).isEmpty {
            let nothing = try XCTUnwrap(element("nothing-to-fix", in: dom), "\(kind): no action means #nothing-to-fix", file: file, line: line)
            XCTAssertTrue(text(nothing.body).hasPrefix("Nothing to fix at this build: the floor is "), text(nothing.body), file: file, line: line)
        }
        // No action names a bucket target of this document (Xcode's own work).
        let buckets = Set((doc.targets ?? []).filter { $0.isBucket == true || ["systemModules", "buildSystem"].contains($0.owner ?? "") }.map(\.name))
        for act in actions(dom) {
            XCTAssertEqual(Self.xcodeTargets(inAction: text(act.body), extra: buckets), [], "\(kind): \(text(act.body))", file: file, line: line)
        }
        // Measured findings come in impact order.
        let measured = actions(dom).filter { attribute("data-source", in: $0.tag) == "finding" }
            .compactMap { Double(attribute("data-saving-seconds", in: $0.tag) ?? "") }
        XCTAssertEqual(measured, measured.sorted(by: >), "\(kind): findings by impactSeconds", file: file, line: line)

        // KPI tiles and the ribbon.
        let summary = try section("summary", in: dom, file: file, line: line).body
        for kpi in ["span", "task", "tasks", "par", "cp"] {
            XCTAssertTrue(summary.contains("data-kpi=\"\(kpi)\""), "\(kind): KPI \(kpi)", file: file, line: line)
        }
        if doc.criticalPath != nil { XCTAssertTrue(dom.contains("id=\"cp-ribbon\""), "\(kind): #cp-ribbon", file: file, line: line) }
        XCTAssertNotNil(matches("(\\d+ pass · \\d+ warn)", in: text(element("meta", in: dom)?.body ?? "")).first,
                        "\(kind): the quality chip", file: file, line: line)

        // Xcode work folded behind one toggle per container.
        for id in ["timeline", "targets", "where"] {
            guard let container = id == "where" ? element(id, in: dom) : (try? section(id, in: dom)).map({ ($0.tag, $0.body) }) else { continue }
            let xcode = container.body.components(separatedBy: "data-xcode=\"1\"").count - 1
            guard xcode > 0 else { continue }
            let button = "(<button[^>]*class=\"xc-toggle\"[^>]*>[^<]*</button>)"
            let toggle = try XCTUnwrap(matches(button, in: container.body).first ?? matches(button, in: dom).first,
                                       "\(kind): #\(id) has Xcode rows but no toggle", file: file, line: line)
            XCTAssertTrue(toggle.contains("aria-pressed=\"false\""), "\(kind): toggle starts off: \(toggle)", file: file, line: line)
            XCTAssertNotNil(matches("(Show Xcode work \\(\\d+\\))", in: text(toggle)).first, toggle, file: file, line: line)
            XCTAssertFalse(container.tag.contains("data-show-xcode=\"1\""), "\(kind): #\(id) starts folded", file: file, line: line)
            if id != "where" {
                let fold = try XCTUnwrap(matches("(<tr[^>]*class=\"xc-fold\"[^>]*>)", in: container.body).first,
                                         "\(kind): #\(id) has one xc-fold row", file: file, line: line)
                XCTAssertFalse(fold.contains("data-row"), "\(kind): the fold row is not a data row", file: file, line: line)
            }
        }

        // Findings: one row per finding, detail rows hidden, housekeeping under one fold.
        let findings = try section("findings", in: dom, file: file, line: line).body
        if !doc.findings.isEmpty {
            XCTAssertTrue(findings.contains("id=\"findings-table\""), "\(kind): table#findings-table", file: file, line: line)
            XCTAssertEqual(matches("(<tr[^>]*class=\"finding\"[^>]*>)", in: findings).count, doc.findings.count,
                           "\(kind): one tr.finding per finding", file: file, line: line)
            for finding in doc.findings {
                XCTAssertTrue(findings.contains("id=\"\(findingAnchor(finding))\""), "\(kind): row id for \(finding.ruleId)", file: file, line: line)
            }
            for detail in matches("(<tr[^>]*class=\"finding-detail\"[^>]*>)", in: findings) {
                XCTAssertTrue(detail.contains(" hidden"), "\(kind): detail rows start hidden: \(detail)", file: file, line: line)
            }
            let folds = matches("(<tr[^>]*class=\"hk-fold\")", in: findings).count
            XCTAssertEqual(folds, doc.findings.contains(where: RulePlan.isHousekeeping) ? 1 : 0, "\(kind): housekeeping fold",
                           file: file, line: line)
        }
        if !doc.fixPlan.isEmpty {
            let plan = try XCTUnwrap(element("fix-plan", in: dom), "\(kind): ol#fix-plan", file: file, line: line)
            XCTAssertEqual(plan.body.components(separatedBy: "data-rule=\"").count - 1, doc.fixPlan.count, "\(kind): one li per step",
                           file: file, line: line)
        }

        // Details group: closed, with diagnostics, environment and notes.
        let group = try XCTUnwrap(element("details-group", in: dom), "\(kind): details#details-group", file: file, line: line)
        XCTAssertTrue(group.tag.hasPrefix("<details"), group.tag, file: file, line: line)
        XCTAssertFalse(group.tag.contains(" open"), "\(kind): the Details group starts closed", file: file, line: line)
        for id in ["diagnostics", "environment", "notes"] {
            XCTAssertTrue(group.body.contains(" id=\"\(id)\""), "\(kind): #\(id) inside the Details group", file: file, line: line)
        }
        let diagnostics = try XCTUnwrap(element("diagnostics", in: dom), "\(kind): #diagnostics", file: file, line: line)
        XCTAssertEqual(attribute("data-total", in: diagnostics.tag), String(doc.diagnosticsTotal), "\(kind): diagnostics data-total",
                       file: file, line: line)
        XCTAssertTrue(diagnostics.body.contains("id=\"dg-mini\""), "\(kind): #dg-mini", file: file, line: line)
        if !doc.diagnostics.isEmpty {
            XCTAssertTrue(diagnostics.body.contains("id=\"dg-table\""), "\(kind): table#dg-table", file: file, line: line)
        }
    }

    private func assertNoCitations(_ dom: String, kind: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let visible = text(dom)
        for pattern in ["\\[(OC|PP|BP|DS|P|S|K)\\]", "\\(S\\d+(, S\\d+)*\\)", "corpus app", "\\b(Allegro|Helm|Spotify|AutoScout24)\\b",
                        "shadowed, the overlay cannot win", "cli on CI", "\\(only if the oracle", "applied as "] {
            XCTAssertTrue(matches("(" + pattern + ")", in: visible).isEmpty,
                          "\(kind): page text shows \(pattern): \(matches("(.{0,60}" + pattern + ".{0,30})", in: visible).first ?? "")",
                          file: file, line: line)
        }
    }

    // MARK: - Report pages

    /// The AcmeApp clean fixture (cli-xcode26, the DAG report): the headline, floor and waste, the budgets of §6.
    func testCleanFixtureFirstScreen() throws {
        let model = try GraphFixtures.model(GraphFixtures.clean26)
        let result = try GraphFixtures.report(model, description: try BuildDescription.load(directory: GraphFixtures.description26))
        let doc = result.document
        let index = TaskIndex.make(model: model, analysis: result.analysis, document: doc)
        let page = try render(doc, index)
        XCTAssertLessThan(page.count, 1_000_000, "AcmeApp page under 1 MB")
        let dom = try assertCockpit(page, kind: "clean", open: ["findings"])
        try assertReportCockpit(dom, doc, kind: "clean")
        let span = try XCTUnwrap(doc.build.span)
        XCTAssertEqual(span, 18.1, accuracy: 0.05, "the fixture's span")
        let headline = try XCTUnwrap(element("headline", in: dom))
        XCTAssertTrue(text(headline.body).hasPrefix("18.1 s clean build"), text(headline.body))
        let floor = try XCTUnwrap(element("floor", in: dom))
        XCTAssertTrue(text(floor.body).contains("18.1 s"), "floor in seconds")
        XCTAssertNil(attribute("data-delta-pct", in: headline.tag).flatMap(Double.init), "no previous build, no regression: no delta")

        // Budgets: visible rows and words on the first load.
        let body = try XCTUnwrap(matches("(<body[^>]*>)", in: dom).first)
        XCTAssertLessThanOrEqual(try XCTUnwrap(Int(attribute("data-visible-rows", in: body) ?? "")), 150, "visible rows")
        XCTAssertLessThanOrEqual(try XCTUnwrap(Int(attribute("data-visible-words", in: body) ?? "")), 400, "visible words")

        // Xcode's own work is never an action and is folded in the targets table.
        XCTAssertTrue(try section("targets", in: dom).body.contains("data-xcode=\"1\""), "bucket targets carry data-xcode")
        XCTAssertTrue(dom.contains("id=\"where\""), "#where: path seconds by target")
        XCTAssertTrue(dom.contains("id=\"hot5\""), "table#hot5 on the board")
        // Top-N on this fixture (88 files): files 10; the synthetic sample checks every table (testTopNTables…).
        let fileCount = try XCTUnwrap(doc.files?.count)
        XCTAssertGreaterThan(fileCount, 10, "the fixture has more files than the top 10")
        XCTAssertEqual(visibleRows(try section("files", in: dom).body).count, 10, "files: top 10")
        XCTAssertTrue(try section("files", in: dom).body.contains(">Show all \(fileCount) rows</button>"), "files: show-all with the count")
        XCTAssertTrue(try section("targets", in: dom).body.contains("id=\"chart-kinds\""), "#chart-kinds moved to Targets")
    }

    /// Top-N on the synthetic sample (300 targets, 200 files, 4,000 hotspots): every table shows exactly its top rows,
    /// and hotspots that are on the path or take at least 100 ms come first, whatever their ms.
    func testTopNTablesOnTheSyntheticSample() throws {
        var (doc, index) = try HTMLSample.synthetic(tasks: 2_000, labels: 500, files: 200, hotspots: 4_000)
        var hotspots = try XCTUnwrap(doc.hotspots)
        // The 20 largest are off the path and under 100 ms (not hot); one further down is off the path at 150 ms (hot).
        for i in 0..<20 { hotspots[i].onPathWeight = 0.25 }
        hotspots[30].onPathWeight = 0.25
        hotspots[30].ms = 150
        doc.hotspots = hotspots
        XCTAssertGreaterThan(doc.targets?.count ?? 0, 15)
        XCTAssertGreaterThan(doc.files?.count ?? 0, 10)
        let dom = try assertCockpit(try render(doc, index), kind: "synthetic", open: ["findings"])
        XCTAssertEqual(visibleRows(try section("files", in: dom).body).count, 10, "files: top 10")
        XCTAssertEqual(visibleRows(try section("targets", in: dom).body).count, 15, "targets: top 15")
        let hot = visibleRows(try section("hotspots", in: dom).body)
        XCTAssertEqual(hot.count, 15, "hotspots: top 15")
        XCTAssertTrue(try section("hotspots", in: dom).body.contains("Showing 15 of 4,000 rows."), "hotspots: the count")
        XCTAssertTrue(hot.first?.contains(">150 ms<") == true && hot.first?.contains("×0.25") == true,
                      "the 150 ms hotspot off the path is hot, so it comes first: \(hot.first?.prefix(400) ?? "")")
        for row in hot.dropFirst() {
            XCTAssertTrue(row.contains("×1.00"), "only on-path hotspots after it, not the larger ones off the path: \(row.prefix(400))")
        }
    }

    /// The check of Xcode's own work in actions can fail: it finds a pseudo-target in the text the template writes.
    func testThePseudoTargetCheckCatchesAnXcodeStep() {
        XCTAssertEqual(Self.xcodeTargets(inAction: "Shorten PCM Darwin (explicit modules), the longest step of explicit modules"),
                       ["explicit modules"])
        XCTAssertEqual(Self.xcodeTargets(inAction: "Shorten CreateBuildDescription (build system): up to 1.41 s"), ["build system"])
        XCTAssertEqual(Self.xcodeTargets(inAction: "Shorten compile Models.swift (Core)", extra: ["Core"]), ["Core"])
        XCTAssertEqual(Self.xcodeTargets(inAction: "Shorten compile StudioView.swift (AcmeApp): body type-checks in 425 ms"), [])
    }

    /// The longest compile step on the path belongs to Xcode's own work: it is never offered as an action.
    func testXcodeStepsAreNeverActions() throws {
        let model = try GraphFixtures.model(GraphFixtures.clean26)
        var doc = try GraphFixtures.report(model, description: try BuildDescription.load(directory: GraphFixtures.description26)).document
        var path = try XCTUnwrap(doc.criticalPath)
        let at = try XCTUnwrap(path.segments.indices.filter { path.segments[$0].label.hasPrefix("compile ") }
            .max { path.segments[$0].seconds < path.segments[$1].seconds })
        let label = path.segments[at].label
        path.segments[at].target = "explicit modules"
        path.segments[at].seconds += 30
        doc.criticalPath = path
        let dom = try assertCockpit(try render(doc, nil), kind: "xcode step", open: ["findings"])
        for act in actions(dom) {
            XCTAssertFalse(text(act.body).contains(label + " (explicit modules)"), "the Xcode step is an action: \(text(act.body))")
        }
    }

    /// The delta clause: the previous build (D1) wins over a baseline regression; neither leaves the first clause alone.
    func testHeadlineSaysHowThisBuildComparesWithThePreviousOne() throws {
        let model = try GraphFixtures.model(GraphFixtures.clean26)
        var doc = try GraphFixtures.report(model, description: try BuildDescription.load(directory: GraphFixtures.description26)).document
        let span = try XCTUnwrap(doc.build.span)
        doc.previous = .init(span: 16.2, kind: "clean", generatedAt: doc.generatedAt.addingTimeInterval(-3 * 86_400),
                             id: "20261105-101500-clean")
        let dom = try assertCockpit(try render(doc, nil), kind: "previous", open: ["findings"])
        let headline = try XCTUnwrap(element("headline", in: dom))
        XCTAssertTrue(text(headline.body).contains("slower than the previous clean build"), text(headline.body))
        XCTAssertTrue(text(headline.body).contains("16.2 s"), text(headline.body))
        XCTAssertEqual(try XCTUnwrap(Double(attribute("data-delta-pct", in: headline.tag) ?? "")), (span / 16.2 - 1) * 100, accuracy: 0.6)

        let (populated, index) = try HTMLSample.populated(hostileStrings: false)
        var regressed = try FormatsFixtures.report()
        regressed.previous = nil
        XCTAssertNotNil(regressed.regression, "the formats fixture carries a regression")
        let withBaseline = try assertCockpit(try render(regressed, nil), kind: "regression", open: ["findings"])
        let baselineHeadline = text(try XCTUnwrap(element("headline", in: withBaseline)).body)
        XCTAssertTrue(baselineHeadline.contains("than baseline"), baselineHeadline)
        let plain = try assertCockpit(try render(populated, index), kind: "populated", open: ["findings"])
        try assertReportCockpit(plain, populated, kind: "populated")
        XCTAssertFalse(text(try XCTUnwrap(element("headline", in: plain)).body).contains(" than "), "no delta clause without a comparison")
    }

    func testAnalyzePageOfTheDDBuild() throws {
        let model = try GraphFixtures.model(GraphFixtures.cleanDD)
        let result = try GraphFixtures.report(model, description: try BuildDescription.load(directory: GraphFixtures.descriptionDD))
        let doc = result.document
        let index = TaskIndex.make(model: model, analysis: result.analysis, document: doc)
        let dom = try assertCockpit(try render(doc, index), kind: "analyze", open: ["findings"])
        try assertReportCockpit(dom, doc, kind: "analyze")
        XCTAssertTrue(try section("fixedcosts", in: dom).body.contains("id=\"chart-fixedcosts\""))
        XCTAssertTrue(try section("modulegraph", in: dom).body.contains("class=\"mg-arrow"), "module graph edges have arrows")
        XCTAssertTrue(try section("modulegraph", in: dom).body.contains("longest chain: "))
        XCTAssertTrue(try section("timeline", in: dom).body.contains("<canvas"))
    }

    func testTruncatedPageShowsTheBannerOnTheFirstScreen() throws {
        var (doc, index) = try HTMLSample.synthetic(tasks: 20_000, labels: 5_000, files: 2_000, hotspots: 4_000)
        var thinned: TaskIndex? = index
        ReportBudget.apply(&doc, taskIndex: &thinned, maxBytes: 3_000_000, templateBytes: ReportTemplate.html.utf8.count)
        XCTAssertFalse(doc.truncation.steps.isEmpty)
        let dom = try assertCockpit(try render(doc, thinned), kind: "truncated", open: ["findings"])
        let banner = try XCTUnwrap(element("truncation", in: dom), "#truncation")
        XCTAssertTrue(text(banner.body).contains("This report is truncated to fit its size cap."))
        XCTAssertTrue(banner.body.contains("--format json --top all"), "how to get every row")
        XCTAssertTrue(try section("start-here", in: dom).body.contains("id=\"truncation\""), "on the first screen")
        for section in sections(dom) where ["targets", "files", "hotspots"].contains(section.id) {
            let total = Int(attribute("data-total", in: section.tag) ?? "") ?? -1
            let shown = Int(attribute("data-shown", in: section.tag) ?? "") ?? -1
            XCTAssertLessThanOrEqual(shown, total, section.id)
        }
    }

    /// Conditional members appear only when their value is set: the degraded chip, #why, #fixedcosts, #modulegraph,
    /// #truncation and the regression clause.
    func testConditionalBlocksFollowTheirMembers() throws {
        let (doc, index) = try HTMLSample.bare()
        let dom = try assertCockpit(try render(doc, index), kind: "bare", open: ["findings"])
        XCTAssertFalse(dom.contains("data-chip=\"degraded\""), "no degraded chip")
        XCTAssertNil(element("truncation", in: dom), "no truncation banner")
        for (id, isNull) in [("why", doc.incremental == nil), ("fixedcosts", doc.fixedCosts == nil), ("modulegraph", doc.moduleGraph == nil)]
            where isNull {
            XCTAssertTrue(try section(id, in: dom).tag.contains(" hidden"), "#\(id) hidden while its member is null")
        }
        var degraded = doc
        degraded.degraded = true
        degraded.degradations = [.init(kind: "decode", detail: "sample")]
        degraded.validation.degraded = true
        let shown = try assertCockpit(try render(degraded, index), kind: "degraded", open: ["findings"])
        let chip = try XCTUnwrap(matches("(<li[^>]*data-chip=\"degraded\"[^>]*>[\\s\\S]*?</li>)", in: shown).first, "degraded chip")
        XCTAssertTrue(text(chip).contains("degraded"), chip)
    }

    func testDoctorPage() throws {
        let doc = HTMLSample.doctor(hostileStrings: false)
        let dom = try assertCockpit(try render(doc, nil), kind: "doctor", open: ["findings"])
        XCTAssertTrue(dom.contains("data-chip=\"doctor\""), "doctor chip")
        for id in ["timeline", "targets", "files", "hotspots"] {
            XCTAssertTrue(try section(id, in: dom).body.contains("doctor runs no build"), id)
        }
        // Doctor measures nothing: the catalog band ranks the actions, marked estimated.
        let acts = actions(dom)
        XCTAssertFalse(acts.isEmpty, "findings with a catalog band are actions")
        for act in acts where attribute("data-source", in: act.tag) == "finding" {
            XCTAssertFalse((attribute("data-band", in: act.tag) ?? "").isEmpty, "a doctor action has a band: \(act.tag)")
            XCTAssertTrue(text(act.body).contains("estimated"), "the band is marked estimated: \(text(act.body))")
        }
        // Offline: every confidence drops to low, but the same findings are actions.
        let offline = HTMLSample.doctorOffline()
        XCTAssertTrue(offline.findings.allSatisfy { $0.confidence == "low" || $0.ruleId.hasPrefix("ENV-") })
        let offlineDom = try assertCockpit(try render(offline, nil), kind: "doctor offline", open: ["findings"])
        func whats(_ dom: String) -> [String] {
            actions(dom).map { text(matches("class=\"act-what\"[^>]*>([\\s\\S]*?)</", in: $0.body).first ?? "") }
        }
        XCTAssertEqual(whats(offlineDom), whats(dom), "offline lists the same actions as online")
        for act in actions(offlineDom) where attribute("data-source", in: act.tag) == "finding" {
            XCTAssertEqual(attribute("data-confidence", in: act.tag), "low", act.tag)
        }
        // The rule counts add up: found + passed + not checked + did not apply + suppressed = checked.
        let outcome = try XCTUnwrap(doc.doctor)
        let found = Set(doc.findings.map(\.ruleId)).count
        XCTAssertEqual(found + outcome.passed.count + outcome.notApplicable.count + outcome.suppressed.count, outcome.rulesEvaluated)
        let findings = try section("findings", in: dom).body
        XCTAssertTrue(text(findings).contains("Commit your changes first."), "the plan starts with the commit banner")
        XCTAssertTrue(text(findings).contains("Copy xcblame command") || text(findings).contains("Copy the "), "copyable plan")
        XCTAssertTrue(findings.contains("Did not apply"), "doctor outcomes nested")
        // A plan step that edits a build setting in the project is measured first, and guards come before edits.
        let commands = doc.fixPlan.map(\.command)
        for (index, step) in doc.fixPlan.enumerated() where step.command.contains("--edit-project") && step.ruleId.hasPrefix("SET-") {
            XCTAssertTrue(commands[..<index].contains { $0.hasPrefix("xcblame verify --rules \(step.ruleId)") }, step.command)
        }
        let guardStep = try XCTUnwrap(commands.firstIndex(of: "xcblame fix --rules PHASE-002 --edit-project"), "the fixture has PHASE-002")
        let edit = try XCTUnwrap(commands.firstIndex { $0.hasPrefix("xcblame verify --rules SET-004 ") }, "the fixture has SET-004")
        XCTAssertLessThan(guardStep, edit, "PHASE-002 guards the dSYM upload before SET-004 switches Debug to dwarf")
        XCTAssertFalse(text(findings).contains("available in xcblame 0.6"), "0.6 commands are no longer labelled")
    }

    // MARK: - Other documents

    func testComparePage() throws {
        let doc = try Compare.run(a: .init(source: "a.xcactivitylog", documents: [CompareFixtures.xcode26.document],
                                           taskRows: [CompareFixtures.xcode26.rows]),
                                  b: .init(source: "b.xcactivitylog", documents: [CompareFixtures.xcode27.document],
                                           taskRows: [CompareFixtures.xcode27.rows]), options: .init(top: .max))
        let page = try HTMLReporter.renderCompare(doc, taskIndexA: CompareFixtures.xcode26.index, taskIndexB: CompareFixtures.xcode27.index,
                                                  options: .init(redact: false, title: "xcblame compare"))
        let dom = try assertCockpit(page, kind: "compare", open: ["compare"])
        let headline = text(try XCTUnwrap(element("headline", in: dom)).body)
        XCTAssertNotNil(matches("(b is [+−-]?[0-9.,]+ (ms|s) \\([+−-]?[0-9.,]+ ?%\\) vs a)", in: headline).first, headline)
        XCTAssertNotNil(element("cmp-wall", in: dom), "#cmp-wall carries data-delta")
        XCTAssertLessThanOrEqual(actions(dom).count, 3, "top 3 causes")
        let band = try XCTUnwrap(dom.range(of: "id=\"cmp-band\""))
        XCTAssertTrue(dom[band.upperBound...].prefix(4000).contains("<svg"), "the headline difference is drawn")

        // Xcode 27 renamed every task; the same compiles pair into changed rows instead of new + removed.
        XCTAssertGreaterThan(doc.tasks.changedTotal, 300, "renamed tasks are paired")
        XCTAssertLessThan(doc.tasks.addedTotal + doc.tasks.removedTotal, 60, "only real new and removed tasks are left")
        XCTAssertTrue(dom.contains("id=\"cmp-tasks-changed\""), "a changed-tasks block")
        XCTAssertFalse(doc.regression.attribution.contains { $0.detail.hasPrefix("28 new tasks") }, "no 28 new + 28 removed pair")
        let body = try section("compare", in: dom).body
        XCTAssertFalse(text(body).contains("1005.1%"), "no percentage on a 27 ms value")
        for block in ["cmp-tasks-added", "cmp-tasks-removed", "cmp-tasks-changed"] {
            let total = block == "cmp-tasks-added" ? doc.tasks.addedTotal : block == "cmp-tasks-removed" ? doc.tasks.removedTotal : doc.tasks.changedTotal
            if total > 25 { XCTAssertTrue(body.contains(">Show all \(total) rows</button>"), "\(block): top 25 with a show-all button") }
        }
    }

    func testTrendPage() throws {
        let dir = try makeHistoryDirectory()
        for minute in 1...4 {
            try TrendFixture.save(.init(minutes: Double(minute), wall: 20 + Double(minute), xcode: minute < 3 ? "26.0" : "26.1"), in: dir)
        }
        let dom = try assertCockpit(try HTMLReporter.renderTrend(try Trend.run(history: dir), options: .init(redact: false, title: "xcblame trend")),
                                    kind: "trend", open: ["trend"])
        let body = try section("trend", in: dom).body
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
        let dom = try assertCockpit(page, kind: "why", open: ["why"])
        let why = try section("why", in: dom).body
        XCTAssertTrue(why.contains("id=\"chart-why\""), "executed time by cause class")
        XCTAssertFalse(matches("(recompiled \\d+ other files? of module \\w+)", in: text(why)).isEmpty, "the cause names the module and the file count")
        XCTAssertFalse(text(why).contains("@testable"), "no visibility claims that do not hold inside one module")
        XCTAssertTrue(text(why).contains("Fix:"), "each cause has a Fix: line")
        XCTAssertFalse(text(dom).contains("What to do:"), "the label is Fix:")
        // The first screen: the top causes by seconds (at most 3), each with its what-to-do.
        let causes = actions(dom).filter { attribute("data-source", in: $0.tag) == "cause" }
        XCTAssertFalse(causes.isEmpty, "the biggest cause is an action")
        let start = text(try section("start-here", in: dom).body)
        // Xcode's own work (planning, the SDK stat cache, system modules) is named in "what changed" but has nothing to fix.
        let xcodeClasses: Set<String> = ["planning", "sdkStatCache", "systemModules"]
        let xcodeTargets: Set<String> = ["build system", "explicit modules"]
        for cause in incremental.causes.sorted(by: { $0.seconds > $1.seconds }).prefix(3) where cause.id != "unknown" {
            let xcodeOwn = xcodeClasses.contains(cause.class) || cause.tasks.contains { xcodeTargets.contains($0.target ?? "") }
            if xcodeOwn {
                XCTAssertTrue(start.contains(cause.cause.replacingOccurrences(of: #" since build \S+$"#, with: "", options: .regularExpression)),
                              "the first screen names \(cause.id) in what changed")
                continue
            }
            guard let fix = cause.whatToDo else { continue }
            XCTAssertTrue(start.contains(fix), "the first screen carries \(cause.id)'s what-to-do: \(fix)")
        }
    }

    func testIncrementalReportOpensWhy() throws {
        let (_, document) = try WhyFixtures.attributed(WhyFixtures.remarks27, test: self)
        let dom = try assertCockpit(try render(document, nil), kind: "incremental", open: ["findings", "why"])
        XCTAssertFalse(try section("why", in: dom).tag.contains(" hidden"))
        XCTAssertLessThanOrEqual(actions(dom).count, 3)
    }

    // MARK: - v0.6 verify and fix-plan pages (docs/SCHEMA-v0.6.md "HTML")

    func testVerifyPage() throws {
        let doc = FixVerifySamples.verify()
        let dom = try assertCockpit(try HTMLReporter.renderVerify(doc, options: .init(redact: false, title: "xcblame verify")),
                                    kind: "verify", open: ["verify"])
        let all = sections(dom)
        let verify = try section("verify", in: dom)
        XCTAssertEqual(attribute("data-total", in: verify.tag), "3", "data-total is the results count")
        XCTAssertEqual(all.filter { !$0.tag.contains(" hidden") }.map(\.id), ["start-here", "verify"])
        let start = try section("start-here", in: dom).body
        XCTAssertTrue(text(start).contains("Kept 1, reverted 2."), text(start))
        XCTAssertTrue(start.contains("id=\"verify-start\""))
        XCTAssertTrue(text(start).contains("Turning on SET-004 made clean builds 2.10 s faster (10.4%), more than the noise band (424 ms): kept."), text(start))
        XCTAssertTrue(text(start).contains("xcblame fix --rules SET-004 --apply"), "what to run next")
        // One row per unit with the contract's attributes; one mark per run with arm, ok and settle.
        XCTAssertTrue(verify.body.contains("<table id=\"verify-results\""))
        XCTAssertEqual(matches("<tr ([^>]*data-verdict=\"[^\"]+\"[^>]*)>", in: verify.body).count, 3)
        XCTAssertTrue(verify.body.contains("data-rule=\"SET-030\" data-verdict=\"reverted\" data-reason=\"brokeBuild\""), "brokeBuild row")
        XCTAssertTrue(verify.body.contains("data-rule=\"SET-016\" data-verdict=\"reverted\" data-reason=\"slower\""), "slower row")
        XCTAssertEqual(matches("(<span class=\"verify-run\" data-arm=\"[AB]\" data-ok=\"(true|false)\" data-settle=\"(true|false)\" title=\"build \\d)", in: verify.body).count, 30)
        XCTAssertEqual(matches("(data-arm=\"B\" data-ok=\"false\")", in: verify.body).count, 1, "the failed B build")
        XCTAssertTrue(text(verify.body).contains("20.1 s ± 100 ms"), "p50 ± MAD")
        XCTAssertTrue(verify.body.contains("id=\"verify-chart\""), "A vs B chart")
        XCTAssertTrue(verify.body.contains("id=\"verify-next\""))
        XCTAssertFalse(verify.body.contains("id=\"verify-abort\""))

        // Aborted: the banner with the reason, and the command to resume in the cockpit.
        let aborted = try assertCockpit(try HTMLReporter.renderVerify(FixVerifySamples.aborted, options: .init(redact: false, title: "")),
                                        kind: "verify aborted", open: ["verify"])
        let body = try section("verify", in: aborted).body
        XCTAssertTrue(body.contains("id=\"verify-abort\""))
        XCTAssertTrue(text(body).contains("timeout"), text(body))
        XCTAssertTrue(text(body).contains("30 minutes passed after 12 builds"), "the abort detail is data: \(text(body))")
        XCTAssertTrue(body.contains("data-verdict=\"unverified\""))
        XCTAssertTrue(text(try section("start-here", in: aborted).body).contains("xcblame verify --plan 5ab3c2d1"))
        try assertCockpit(try HTMLReporter.renderVerify(FixVerifySamples.verify(kind: .incremental), options: .init(redact: false, title: "")),
                          kind: "verify incremental", open: ["verify"])
    }

    func testFixPlanPage() throws {
        let dom = try assertCockpit(try HTMLReporter.renderFixPlan(FixVerifySamples.plan, options: .init(redact: false, title: "xcblame fix plan")),
                                    kind: "fix plan", open: ["fixplan"])
        let all = sections(dom)
        let plan = try section("fixplan", in: dom)
        XCTAssertEqual(all.filter { !$0.tag.contains(" hidden") }.map(\.id), ["start-here", "fixplan"])
        XCTAssertEqual(attribute("data-total", in: plan.tag), "4")
        XCTAssertTrue(plan.body.contains("data-rule=\"SET-004\" data-state=\"planned\" data-verify=\"kept\""), "kept step")
        XCTAssertTrue(plan.body.contains("data-rule=\"SET-001\" data-state=\"skipped\" data-verify=\"reverted\""), "skipped step")
        XCTAssertTrue(text(plan.body).contains("defaults delete com.apple.dt.Xcode IDEBuildOperationMaxNumberOfConcurrentCompileTasks"))
        XCTAssertTrue(plan.body.contains("id=\"fixplan-guards\"") && plan.body.contains("id=\"fixplan-hook\""))
        let commands = try XCTUnwrap(plan.body.range(of: "id=\"fixplan-commands\""))
        XCTAssertTrue(plan.body[commands.upperBound...].contains(">Copy the 3 commands</button>"), "the commands are copyable")
        XCTAssertTrue(text(try section("start-here", in: dom).body).contains("4 steps:"))
    }
}
