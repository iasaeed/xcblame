import XCTest
@testable import XcblameKit

/// INCREMENTAL CAUSES and the `why` text report (docs/SCHEMA-v0.5.md "Text").
final class WhyTextTests: XCTestCase {
    func testIncrementalLines() throws {
        XCTAssertEqual(TextReporter().incrementalLines(try syntheticReport()), [], "null member: no block")
        var (_, document) = try WhyFixtures.attributed(WhyFixtures.remarks26, test: self)
        let lines = TextReporter().incrementalLines(document)
        XCTAssertTrue(lines[0].hasPrefix("INCREMENTAL CAUSES  basis: previous build "), lines[0])
        XCTAssertTrue(lines.contains { $0.hasPrefix("  driverRemark") && $0.contains("[driverRemark]") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("  unknown share ") && $0.contains("for more evidence: xcblame why --backtraces") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("  V15 pass: causes ") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("  by path seconds: ") && $0.hasSuffix("(not added to task time)") })

        // --top 1: one ranked cause, then unknown always.
        document.topN = 1
        let top = TextReporter().incrementalLines(document)
        let causeLines = top.filter { line in
            !line.hasPrefix("  unknown share") && ReportDocument.Incremental.classes.contains { line.hasPrefix("  " + $0) }
        }
        XCTAssertEqual(causeLines.count, 2, top.joined(separator: "\n"))
        XCTAssertTrue(causeLines[1].hasPrefix("  unknown"))
        XCTAssertTrue(top.contains { $0.contains("more causes (--top)") })
    }

    /// `why --touch` changes the timestamp only: the text WHY section says what that simulates (once, even when the
    /// procedure also left the note in `incremental.notes`), and the zero-change procedure does not.
    func testTouchScenarioCarriesTheNote() throws {
        var (_, document) = try WhyFixtures.attributed(WhyFixtures.why27, test: self)
        let builds: [ReportDocument.Incremental.ProcedureBuild] = [
            .init(role: "settle", exitCode: 0, wall: 3, executedTasks: 10, executedWorkTasks: 2, historyId: nil),
            .init(role: "measure", exitCode: 0, wall: 2, executedTasks: 4, executedWorkTasks: 1, historyId: nil),
        ]
        document.incremental?.procedure = .init(mode: "touch", touched: "/src/A.swift", builds: builds,
                                                backtraces: "on", showIncremental: false)
        document.incremental?.notes.append(CauseEngine.touchNote)
        let text = TextReporter.renderWhy(document)
        XCTAssertEqual(text.components(separatedBy: CauseEngine.touchNote).count - 1, 1, text)
        XCTAssertEqual(CauseEngine.touchNote, "--touch changes only the file's timestamp, so Swift recompiled just this file. "
            + "To see what one real edit rebuilds, add a line to the file and run: xcblame why --backtraces -- <args>")
        let procedureEnd = try XCTUnwrap(text.range(of: "          settle: exit 0"))
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "why     touch /src/A.swift")).lowerBound, procedureEnd.lowerBound)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: CauseEngine.touchNote)).lowerBound, procedureEnd.lowerBound)

        document.incremental?.procedure = .init(mode: "zeroChange", touched: nil, builds: builds, backtraces: "on",
                                                showIncremental: false)
        document.incremental?.notes.removeAll { $0 == CauseEngine.touchNote }
        XCTAssertFalse(TextReporter.renderWhy(document).contains("--touch changes only"))
    }

    func testWhyReportSections() throws {
        var (_, document) = try WhyFixtures.attributed(WhyFixtures.why27, test: self)
        document.incremental?.procedure = .init(mode: "touch", touched: "/src/A.swift", builds: [
            .init(role: "settle", exitCode: 0, wall: 3, executedTasks: 10, executedWorkTasks: 2, historyId: "h1"),
            .init(role: "measure", exitCode: 0, wall: 2, executedTasks: 4, executedWorkTasks: 1, historyId: "h2"),
        ], backtraces: "on", showIncremental: true)
        let text = TextReporter.renderWhy(document)
        XCTAssertTrue(text.hasPrefix("xcblame why "))
        XCTAssertTrue(text.contains("  why     touch /src/A.swift (mtime only) · backtraces on · -driver-show-incremental"))
        XCTAssertTrue(text.contains("          settle: exit 0 · 3.0 s · 10 tasks (2 compile/plan/link) · history h1"))
        for heading in ["INCREMENTAL CAUSES", "CRITICAL PATH", "TARGETS", "checks "] { XCTAssertTrue(text.contains(heading), heading) }
        XCTAssertFalse(text.contains("TOP TASKS"))
        XCTAssertLessThan(text.range(of: "INCREMENTAL CAUSES")!.lowerBound, text.range(of: "CRITICAL PATH")!.lowerBound)

        var clean = try WhyFixtures.report(WhyFixtures.why27.clean).document
        clean = CauseEngine.attach(to: clean, model: try WhyFixtures.report(WhyFixtures.why27.clean).model,
                                   historyDir: try WhyFixtures.history([], test: self), project: nil)
        XCTAssertTrue(TextReporter.renderWhy(clean).contains("INCREMENTAL CAUSES  unavailable: incremental: not applicable — this is a clean build (no previous work to compare)"))
        // The full report carries the block too, before the findings.
        XCTAssertTrue(TextReporter.render(document).contains("INCREMENTAL CAUSES"))
    }
}
