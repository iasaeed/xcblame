import XCTest
@testable import XcblameKit

/// `--format agent` (docs/SCHEMA-v0.4.md "agent"): diagnostics first, then at most 6,000 bytes of summary, 8 KB total.
final class FormatsAgentTests: XCTestCase {
    private func render(_ document: ReportDocument, cap: Int = 8 * 1024, _ extra: FormatOptions? = nil) throws -> String {
        try AgentReporter.render(document, options: extra ?? FormatOptions(maxBytes: cap))
    }

    func testSectionsAppearInTheDocumentedOrder() throws {
        let text = try render(FormatsFixtures.redacted(try FormatsFixtures.report()))
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "xcblame 0.6.1 agent report (xcblame.report/1)")
        XCTAssertEqual(lines[1], "result: failed (3 errors, 6 warnings)")
        let headings = ["ERRORS (3 unique, 6 occurrences)", "WARNINGS (6 unique, 13 occurrences)", "BUILD", "CRITICAL PATH (top 3 of 17 segments)",
                        "FINDINGS (top 1 of 1)", "NOTES", "next: "]
        let positions = headings.map { heading in lines.firstIndex { $0.hasPrefix(heading) } }
        XCTAssertFalse(positions.contains { $0 == nil }, "\(headings.filter { h in !lines.contains { $0.hasPrefix(h) } })")
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted())
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertFalse(text.hasSuffix("\n\n"))
        XCTAssertFalse(text.contains("|"), "no tables")
        XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0x1B || $0.value >= 0x1F000 })
    }

    func testDiagnosticLinesAreAssembledAndDeduped() throws {
        let text = try render(FormatsFixtures.redacted(try FormatsFixtures.report()))
        XCTAssertTrue(text.contains("- Sources/E1.swift:4:4: cannot find 'x1' in scope at Sources/E1.swift (x3)"), text)
        XCTAssertTrue(text.contains("- Sources/W3.swift:10:9: variable 'w3' was never mutated; consider 'let' (x4)"))
        XCTAssertTrue(text.contains("- variable 'w4' was never mutated; consider 'let' (x1)"), "no file, no location")
        var document = try FormatsFixtures.report()
        document.diagnostics = [.init(severity: "error", file: "A.swift", line: 1, column: nil, message: String(repeating: "m", count: 400), occurrences: 2)]
        document.diagnosticsSummary.errors = 1
        document.diagnosticsSummary.warnings = 0
        let long = try render(document)
        let line = try XCTUnwrap(long.components(separatedBy: "\n").first { $0.hasPrefix("- A.swift:1: ") })
        XCTAssertEqual(line, "- A.swift:1: " + String(repeating: "m", count: 199) + "… (x2)", "message cut at 200 characters")
    }

    func testBuildLinesFollowTheContract() throws {
        let text = try render(try FormatsFixtures.report())
        XCTAssertTrue(text.contains("BUILD\nkind: clean; scheme: App; configuration: Debug; destination: macOS arm64; xcode: 26.0 (inferred)\n"), text)
        XCTAssertTrue(text.contains("wall: 19.00 s; busy: 18.00 s; critical path: 19.00 s; tasks: 50\n"), text)
        XCTAssertTrue(text.contains("regression: slower +1.00 s (+5.6 %) vs baseline (median of 5 runs, noise band 0.60 s), threshold 5 %, FAILED\n"), text)
        XCTAssertTrue(text.contains("1. 3.00 s (9 %) NetKit: swiftCompile Compile NetKit2.swift\n"))
        XCTAssertTrue(text.contains("1. SET-016 [S, medium] Use the explicit-modules build setting. Fix: xcblame verify --rules SET-016\n"), text)
        XCTAssertTrue(text.contains("\nnext: xcblame analyze <input> --format json\n"), "with errors the next step is the full diagnostics")
        var clean = try FormatsFixtures.report()
        clean.diagnosticsSummary.errors = 0
        clean.diagnostics = []
        XCTAssertTrue(try render(clean).contains("\nnext: xcblame verify --rules SET-016\n"), "without errors, the first fix")
    }

    func testSucceededWhenThereAreNoErrorsAndNoRegressionLine() throws {
        var document = try FormatsFixtures.report(regression: nil)
        document.diagnostics = []
        document.diagnosticsSummary.errors = 0
        document.diagnosticsSummary.warnings = 0
        let text = try render(document)
        XCTAssertTrue(text.contains("result: succeeded (0 errors, 0 warnings)\nBUILD\n"), text)
        XCTAssertFalse(text.contains("ERRORS"))
        XCTAssertFalse(text.contains("regression:"))
    }

    func testDoctorDocumentGetsAFindingsSummary() throws {
        let text = try render(FormatsFixtures.redacted(FormatsFixtures.doctor()))
        XCTAssertTrue(text.contains("DOCTOR\nproject: AcmeApp.xcodeproj; xcode: 26.0.1; rules: 49 evaluated, 18 findings"), text)
        XCTAssertTrue(text.contains("FINDINGS (top 10 of 18)"))
        XCTAssertTrue(text.contains("result: failed (0 errors, 0 warnings)"), "fail-on medium is exit 4")
        XCTAssertFalse(text.contains("BUILD"))
        XCTAssertLessThan(text.utf8.count, 8 * 1024)
    }

    func testWarningsGoFirstThenErrorsDownToTwentyAndTheHeadingsKeepTheirTotals() throws {
        let document = FormatsFixtures.redacted(try FormatsFixtures.large())
        let full = try render(document, cap: .max)
        XCTAssertGreaterThan(full.utf8.count, 8 * 1024, "the fixture needs cutting")
        let text = try render(document)
        XCTAssertLessThanOrEqual(text.utf8.count, 8 * 1024)
        XCTAssertTrue(text.contains("ERRORS (40 unique, 80 occurrences)"))
        XCTAssertTrue(text.contains("WARNINGS (60 unique, "))
        XCTAssertTrue(text.contains("... 40 more errors not shown") == false, "warnings are cut before any error")
        let shown = text.components(separatedBy: "\n").filter { $0.hasPrefix("- Sources/W") || $0.hasPrefix("- variable") }.count
        XCTAssertTrue(text.contains("... \(60 - shown) more warnings not shown (xcblame analyze <input> --format json)"), text)
        // Squeeze: warnings gone entirely, then errors from the tail, never below twenty.
        let squeezed = try render(document, cap: 4_800)
        XCTAssertLessThanOrEqual(squeezed.utf8.count, 4_800)
        let errors = squeezed.components(separatedBy: "\n").filter { $0.hasPrefix("- Sources/E") }.count
        XCTAssertGreaterThanOrEqual(errors, 20)
        XCTAssertTrue(squeezed.contains("... 60 more warnings not shown"))
        XCTAssertTrue(squeezed.contains("CRITICAL PATH") && squeezed.contains("FINDINGS"), "the summary is never dropped")
        XCTAssertFalse(squeezed.contains("[truncated]"))
    }

    func testHardTruncationEndsWithTheMarkerAndNeverExceedsTheCap() throws {
        let document = FormatsFixtures.redacted(try FormatsFixtures.large())
        for cap in [0, 1, 20, 100, 500, 1000, 2000, 2500] {
            let text = try render(document, cap: cap)
            XCTAssertLessThanOrEqual(text.utf8.count, cap, "cap \(cap)")
            if cap >= 100 {
                XCTAssertTrue(text.contains("[truncated]\n"), "cap \(cap): \(text.suffix(60))")
                XCTAssertTrue(text.hasPrefix("xcblame 0.6.1 agent report"))
                // A cap that leaves room for the summary keeps all of it (the diagnostics are clipped, not the tail).
                XCTAssertTrue(text.contains("\nnext: ") || text.hasSuffix("[truncated]\n"), "cap \(cap)")
            }
        }
        var multibyte = try FormatsFixtures.report()
        multibyte.findings[0].title = String(repeating: "日本語", count: 60)
        for cap in 700...760 {
            let text = try render(multibyte, cap: cap)
            XCTAssertLessThanOrEqual(text.utf8.count, cap)
            XCTAssertNotNil(String(validatingUTF8: Array(text.utf8CString)))
        }
    }

    /// Code review v0.4 minor: at the 20-error floor the diagnostics block is clipped, never BUILD, CRITICAL PATH,
    /// FINDINGS and `next:`.
    func testTheFloorClipsTheDiagnosticsNotTheSummary() throws {
        let document = FormatsFixtures.redacted(try FormatsFixtures.large())
        let summary = try render(document, cap: .max).components(separatedBy: "\nBUILD\n").last ?? ""
        let cap = "xcblame 0.6.1 agent report".utf8.count + summary.utf8.count + 900
        let text = try render(document, cap: cap)
        XCTAssertLessThanOrEqual(text.utf8.count, cap)
        for part in ["\nBUILD\n", "CRITICAL PATH", "FINDINGS (top 3", "\nnext: "] { XCTAssertTrue(text.contains(part), "\(part)\n\(text)") }
        XCTAssertTrue(text.contains("[truncated]\nBUILD\n"), "the marker closes the clipped diagnostics:\n\(text)")
        XCTAssertTrue(text.contains("ERRORS (40 unique"), "the heading keeps its total")
    }

    func testTheSummaryIsCutAtSixThousandBytesWithTheMarker() {
        let lines = (0..<400).map { "line \($0) " + String(repeating: "x", count: 40) }
        let cut = AgentReporter.cut(lines)
        XCTAssertLessThanOrEqual(cut.reduce(0) { $0 + $1.utf8.count + 1 }, AgentReporter.summaryCap)
        XCTAssertEqual(cut.last, "[truncated]")
        XCTAssertEqual(cut[0], lines[0])
        XCTAssertEqual(AgentReporter.cut(["a", "b"]), ["a", "b"])
    }

    func testTheSummaryOfARealDocumentFitsItsShareOfTheCap() throws {
        for document in [try FormatsFixtures.report(), FormatsFixtures.doctor(), try FormatsFixtures.large()] {
            let summary = try render(document, cap: .max).components(separatedBy: "\n")
            let start = try XCTUnwrap(summary.firstIndex { $0 == "BUILD" || $0 == "DOCTOR" })
            XCTAssertLessThanOrEqual(summary[start...].joined(separator: "\n").utf8.count, 6000)
        }
    }

    func testDeterministicAndRoutedByTheFormatEnum() throws {
        let document = try FormatsFixtures.report()
        XCTAssertEqual(try render(document), try render(document))
        let output = try ReportPipeline.renderFormat(document, format: .agent, options: FormatOptions(maxBytes: 8192))
        XCTAssertEqual(output.body, try render(document))
        XCTAssertEqual(output.annotations, [])
    }

    func testReproduceCommandAppearsInTheMoreLine() throws {
        let document = FormatsFixtures.redacted(try FormatsFixtures.large())
        let text = try render(document, FormatOptions(maxBytes: 8192, reproduceCommand: "xcblame analyze b.log --format json --top all"))
        XCTAssertTrue(text.contains("not shown (xcblame analyze b.log --format json --top all)"), text)
    }
}
