import XCTest
@testable import XcblameKit

/// `--format markdown` (docs/SCHEMA-v0.4.md "markdown"): layout, headline wording, escaping, doctor and compare
/// documents, and the budget ladder.
final class FormatsMarkdownTests: XCTestCase {
    private let options = FormatOptions(maxBytes: 64 * 1024)

    private func render(_ document: ReportDocument, _ options: FormatOptions? = nil) throws -> String {
        try MarkdownReporter.render(document, options: options ?? self.options)
    }

    private func regression(_ edit: (inout ReportDocument.Regression) -> Void = { _ in }) -> ReportDocument.Regression {
        var value = V04Samples.regression
        edit(&value)
        return value
    }

    // MARK: Layout

    func testAnalyzeLayoutFollowsTheContract() throws {
        let text = try render(FormatsFixtures.redacted(try FormatsFixtures.report()))
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "<!-- xcblame:report -->")
        XCTAssertEqual(lines[1], "## xcblame: App clean, 19.00 s wall")
        let order = ["### Critical path", "### Findings", "<details><summary>Details</summary>", "#### Targets", "#### Attribution",
                     "#### Diagnostics", "#### Environment and validation", "</details>", "<sub>xcblame 0.6.1, xcblame.report/1, redacted</sub>"]
        let positions = order.map { text.range(of: $0)?.lowerBound }
        XCTAssertFalse(positions.contains { $0 == nil }, "\(order.filter { text.range(of: $0) == nil })")
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted())
        XCTAssertTrue(text.hasSuffix("</sub>\n"))
        XCTAssertFalse(text.hasSuffix("\n\n"))
        XCTAssertFalse(text.contains("\r"))
        XCTAssertEqual(text.components(separatedBy: "<details>").count, 2)
        // No emoji, no ANSI.
        XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0x1B || $0.value >= 0x1F000 || (0x2600...0x27BF).contains($0.value) })
        XCTAssertEqual(text, try render(FormatsFixtures.redacted(try FormatsFixtures.report())), "byte-equal across runs")
    }

    func testMetricTableAndCriticalPathTable() throws {
        let text = try render(try FormatsFixtures.report())
        XCTAssertTrue(text.contains("| Metric | Now | Baseline | Delta |"))
        XCTAssertTrue(text.contains("| Wall | 19.00 s | 18.00 s | +1.00 s (+5.6 %) |"))
        XCTAssertTrue(text.contains("| Busy | 18.00 s | 17.00 s | +1.00 s (+5.9 %) |"))
        XCTAssertTrue(text.contains("3 errors, 6 warnings"))
        XCTAssertTrue(text.contains("| # | Target | Work | Seconds | Share |"))
        // Top 5 of the segments, by seconds, with the footer.
        let rows = text.components(separatedBy: "\n").filter { $0.range(of: #"^\| \d+ \| "#, options: .regularExpression) != nil }
        XCTAssertEqual(rows.count, 5)
        XCTAssertTrue(text.contains("_5 of 17 segments, "), text)
    }

    func testHeadlineWordingPerVerdict() throws {
        var document = try FormatsFixtures.report()
        document.regression = regression()
        var text = try render(document)
        XCTAssertTrue(text.contains("**slower** +1.00 s (+5.6 %) vs baseline (median of 5 runs, noise band 0.60 s)"), text)
        XCTAssertTrue(text.contains("**FAILED: over the 5 % threshold**"))

        document.regression = regression {
            $0.verdict = "indicative"
            $0.noiseBand = .init(method: "threshold", pooledMad: nil, madMultiplier: 3, minPct: 0.02, band: nil, runsBaseline: 1, runsCurrent: 1)
            $0.baseline.runs = 1
            $0.failed = false
        }
        text = try render(document)
        XCTAssertTrue(text.contains("**indicative** +1.00 s (+5.6 %), 1 run per side: too few runs to tell it from noise"), text)
        XCTAssertFalse(text.contains("FAILED"))

        document.regression = regression { $0.verdict = "indicative"; $0.failed = true }
        XCTAssertTrue(try render(document).contains("FAILED: over the 5 % threshold (plus 5 % allowance for few runs)"))

        document.regression = regression { $0.verdict = "faster"; $0.wall = V04Samples.delta(18, 17); $0.failed = false }
        XCTAssertTrue(try render(document).contains("**faster** -1.00 s (-5.6 %) vs baseline"))

        document.regression = regression { $0.wall = .init(baseline: nil, current: 19, delta: nil, deltaPct: nil); $0.failed = false }
        let unknown = try render(document)
        XCTAssertTrue(unknown.contains("**slower** no wall delta vs baseline"), unknown)
        XCTAssertTrue(unknown.contains("| Wall | 19.00 s | n/a | n/a |"), "an unknown baseline is n/a, never 0")
    }

    func testWithoutBaselineThereIsOneColumnAndAHint() throws {
        let text = try render(try FormatsFixtures.report(regression: nil))
        XCTAssertTrue(text.contains("No baseline: pass `--baseline .xcblame/baseline.json` to compare."))
        XCTAssertTrue(text.contains("| Metric | Now |\n| --- | --- |\n| Wall |"), text)
        XCTAssertFalse(text.contains("Baseline |"))
        XCTAssertFalse(text.contains("#### Attribution"))
    }

    /// A doctor finding with only a catalog band says it is an estimate, not a measurement.
    func testDoctorFindingsNameTheCatalogEstimate() throws {
        let doc = HTMLSample.doctor(hostileStrings: false)
        XCTAssertTrue(doc.findings.contains { $0.ruleId == "PHASE-002" && $0.estimatedBand == "S" && $0.impactBand == "?" })
        let text = try render(doc)
        XCTAssertTrue(text.contains("**SET-001** (estimated M, "), text)  // the catalog band, named as an estimate
    }

    func testFindingLineAndFooters() throws {
        let text = try render(try FormatsFixtures.report())
        XCTAssertTrue(text.contains("1. **SET-016** (S, medium) Use the explicit-modules build setting: Debug: explicit modules off. Fix: `xcblame verify --rules SET-016`"), text)
        XCTAssertTrue(text.contains("   - App: SWIFT_ENABLE_EXPLICIT_MODULES = NO"))
        var none = try FormatsFixtures.report()
        none.findings = []
        none.findingsTotal = 0
        XCTAssertTrue(try render(none).contains("### Findings\n\nNo findings.\n"))
        var many = try FormatsFixtures.report()
        many.findings = (0..<5).map { i in
            var finding = many.findings[0]
            finding.ruleId = "SET-0\(i)"
            return finding
        }
        many.findingsTotal = 5
        let text5 = try render(many)
        XCTAssertTrue(text5.contains("_3 of 5 findings_"))
        XCTAssertFalse(text5.contains("SET-03"))
    }

    // MARK: Escaping

    func testTextIsNeverHTMLAndCellsNeverBreakTheTable() throws {
        var document = try FormatsFixtures.report(hostile: true)
        document.findings[0].title = "a|b <b>bold</b>\nsecond </details> line"
        document.targets?[0].name = "Evil|Target<script>"
        document.diagnostics[0].message = "bad </details><img src=x onerror=alert(1)> | pipe\r\nnext"
        let text = try render(document)
        XCTAssertFalse(text.contains("<img"), text)
        XCTAssertFalse(text.contains("<script"))
        XCTAssertFalse(text.contains("<b>"))
        XCTAssertEqual(text.components(separatedBy: "<details>").count, 2)
        XCTAssertEqual(text.components(separatedBy: "</details>").count, 2)
        for line in text.components(separatedBy: "\n") where line.hasPrefix("| ") {
            let pipes = line.replacingOccurrences(of: "\\|", with: "").filter { $0 == "|" }.count
            XCTAssertTrue(pipes >= 3, line)
        }
        let table = text.components(separatedBy: "\n").filter { $0.contains("Evil") }
        XCTAssertEqual(table.count, 1)
        XCTAssertTrue(table[0].contains("Evil\\|Target&lt;script>"), table[0])
        XCTAssertFalse(text.contains("\u{1B}"))
    }

    // MARK: Mentions

    func testMentionSafeWrapsLoginsOutsideCodeSpans() {
        XCTAssertEqual(FormatText.mentionSafe("ping @alice and @org/team-a now"), "ping `@alice` and `@org/team-a` now")
        XCTAssertEqual(FormatText.mentionSafe("@MainActor func f() // @available"), "`@MainActor` func f() // `@available`")
        XCTAssertEqual(FormatText.mentionSafe("already `@bob` here"), "already `@bob` here")
        XCTAssertEqual(FormatText.mentionSafe("`use @x here` and @y"), "`use @x here` and `@y`")
        XCTAssertEqual(FormatText.mentionSafe("mail ann@example.com"), "mail ann@example.com")
        XCTAssertEqual(FormatText.mentionSafe("unterminated ` @z"), "unterminated ` `@z`")
        XCTAssertEqual(FormatText.mentionSafe("no mention"), "no mention")
        XCTAssertEqual(FormatText.mentionSafe("at sign @ alone"), "at sign @ alone")
    }

    func testBodyNeverContainsABareMention() throws {
        var document = try FormatsFixtures.report()
        document.diagnostics[0].message = "cannot find @octocat in scope (see @org/reviewers)"
        document.findings[0].title = "Move @MainActor work off the path, cc @someone"
        document.targets?[0].name = "Target@dev"
        let text = try render(document)
        XCTAssertTrue(text.contains("`@octocat`") && text.contains("`@org/reviewers`") && text.contains("`@MainActor`")
            && text.contains("`@someone`"), text)
        let bare = try NSRegularExpression(pattern: "(?<![\\w`@/.])@[A-Za-z0-9]")
        for line in text.components(separatedBy: "\n") {
            // A bare mention is an @ that no backtick opens; wrapped ones follow a backtick.
            XCTAssertNil(bare.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), line)
        }
    }

    // MARK: Doctor and compare

    func testDoctorDocumentRendersFindingsOnly() throws {
        let document = FormatsFixtures.redacted(FormatsFixtures.doctor())
        let text = try render(document)
        XCTAssertTrue(text.contains("## xcblame doctor: AcmeApp.xcodeproj, 18 findings"), text)
        XCTAssertTrue(text.contains("### Findings"))
        XCTAssertTrue(text.contains("_10 of 18 findings_"))
        XCTAssertTrue(text.contains("#### Fix plan"))
        for absent in ["### Critical path", "| Metric", "No baseline", "#### Targets", "errors,"] {
            XCTAssertFalse(text.contains(absent), absent)
        }
        XCTAssertTrue(text.hasPrefix("<!-- xcblame:report -->\n"))
    }

    func testCompareDocumentLeadsWithHeadlineAndEnvironment() throws {
        var compare = V04Samples.compare
        compare.targets = [.init(key: "App", status: "changed", seconds: .init(a: 10, b: 11, delta: 1, deltaPct: 0.1),
                                 tasks: nil, isOther: false)]
        compare.targetsTotal = 1
        let text = try MarkdownReporter.render(compare, options: options)
        XCTAssertTrue(text.hasPrefix("<!-- xcblame:report -->\n## xcblame compare: App clean, 18.00 s wall (reference 18.00 s)\n"), text)
        let headline = try XCTUnwrap(text.range(of: "**slower** +1.00 s (+5.6 %) vs reference"))
        let env = try XCTUnwrap(text.range(of: "### Environment"))
        let metrics = try XCTUnwrap(text.range(of: "| Metric | Reference (a) | This build (b) | Delta |"))
        XCTAssertTrue(headline.lowerBound < env.lowerBound && env.lowerBound < metrics.lowerBound)
        XCTAssertTrue(text.contains("| xcode | 26.0 | 26.1 |"))
        XCTAssertTrue(text.contains("_1 of 1 differ, 16 fields compared_"))
        XCTAssertTrue(text.contains("### Targets"))
        XCTAssertTrue(text.contains("#### Phases"))
        compare.env = []
        XCTAssertTrue(try MarkdownReporter.render(compare, options: options).contains("No environment differences (16 fields compared)."))
    }

    // MARK: Budget

    func testFiveHundredTargetsStayUnderTheDefaultCap() throws {
        let document = FormatsFixtures.redacted(try FormatsFixtures.large())
        XCTAssertGreaterThanOrEqual(document.targets?.count ?? 0, 500)
        let text = try render(document)
        XCTAssertLessThanOrEqual(text.utf8.count, 64 * 1024)
        XCTAssertTrue(text.contains("_10 of 500 targets_") || text.contains("of 501 targets_"), "capped, not dumped")
        XCTAssertFalse(text.contains("Truncated to fit"), "nothing to cut at the default cap")
        XCTAssertLessThan(text.utf8.count, 10_000, "the mandatory part is far under the cap")
        let uncapped = try render(document, FormatOptions(maxBytes: .max))
        print("500-target worst-case document: markdown \(text.utf8.count) bytes at the 64 KB cap, \(uncapped.utf8.count) uncapped")
    }

    func testTruncationNamesWhatItDroppedInTheDocumentedOrder() throws {
        let document = FormatsFixtures.redacted(try FormatsFixtures.large())
        let full = try render(document, FormatOptions(maxBytes: .max))
        let canonical = ["hotspots, files, fix plan", "diagnostics rows beyond 5", "targets rows beyond 5", "diagnostics",
                         "attribution", "targets", "environment and validation", "finding evidence beyond one line",
                         "critical-path rows beyond 3"]
        // Just over: only the first step that changes anything runs.
        let small = try render(document, FormatOptions(maxBytes: full.utf8.count - 100))
        XCTAssertLessThanOrEqual(small.utf8.count, full.utf8.count - 100)
        XCTAssertTrue(small.contains("Truncated to fit \(full.utf8.count - 100) bytes: hotspots, files, fix plan. Full detail: "), small)
        XCTAssertTrue(small.contains("#### Diagnostics") && small.contains("#### Targets"))
        // Further down: more steps, always in order, and the footer survives.
        for cap in [full.utf8.count - 3000, full.utf8.count - 6000, 4000, 2500] {
            let text = try render(document, FormatOptions(maxBytes: cap))
            XCTAssertLessThanOrEqual(text.utf8.count, cap, "cap \(cap)")
            let note = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.hasPrefix("_Truncated to fit") }, "cap \(cap)")
            func position(_ label: String) -> String.Index? {
                [": \(label),", ", \(label),", ": \(label).", ", \(label)."].compactMap { note.range(of: $0)?.lowerBound }.min()
            }
            let positions = canonical.compactMap(position)
            XCTAssertFalse(positions.isEmpty)
            XCTAssertEqual(positions, positions.sorted(), note)
            XCTAssertTrue(text.contains("Full detail: xcblame analyze <input> --format json --top all_"))
            XCTAssertTrue(text.hasSuffix("</sub>\n") || cap < 3500, "the footer is kept while the mandatory part fits")
        }
        let reproduce = try render(document, FormatOptions(maxBytes: 2500, reproduceCommand: "xcblame analyze b.log --format json --top all"))
        XCTAssertTrue(reproduce.contains("Full detail: xcblame analyze b.log --format json --top all_"))
    }

    func testTheBodyIsNeverLongerThanTheCapWhateverTheCap() throws {
        let documents = [FormatsFixtures.redacted(try FormatsFixtures.report()), FormatsFixtures.redacted(FormatsFixtures.doctor()),
                         FormatsFixtures.redacted(try FormatsFixtures.large())]
        for document in documents {
            for cap in [0, 1, 10, 60, 120, 149, 150, 200, 260, 400, 800, 1500, 2500, 4096, 10_000] {
                let text = try render(document, FormatOptions(maxBytes: cap))
                XCTAssertLessThanOrEqual(text.utf8.count, cap, "cap \(cap)")
                if cap >= 150 {
                    XCTAssertTrue(text.hasPrefix("<!-- xcblame:report -->\n"), "cap \(cap)")
                    XCTAssertTrue(text.hasSuffix("\n"))
                }
            }
        }
        let tiny = try render(documents[0], FormatOptions(maxBytes: 300))
        XCTAssertTrue(tiny.contains("_Truncated to fit 300 bytes"), tiny)
        var compare = V04Samples.compare
        compare.targets = (0..<50).map { .init(key: "T\($0)", status: "changed", seconds: .init(a: 1, b: 2, delta: 1, deltaPct: 1), tasks: nil, isOther: false) }
        compare.targetsTotal = 50
        for cap in [0, 100, 300, 600, 900, 1200, 5000] {
            XCTAssertLessThanOrEqual(try MarkdownReporter.render(compare, options: FormatOptions(maxBytes: cap)).utf8.count, cap, "compare cap \(cap)")
        }
    }

    func testMultibyteTextIsCutOnAScalarBoundary() throws {
        var document = try FormatsFixtures.report()
        document.findings[0].title = String(repeating: "日本語のタイトル", count: 40)
        for cap in 250...330 {
            let text = try render(document, FormatOptions(maxBytes: cap))
            XCTAssertLessThanOrEqual(text.utf8.count, cap)
            XCTAssertNotNil(String(validatingUTF8: Array(text.utf8CString)), "valid UTF-8 at cap \(cap)")
        }
    }
}
