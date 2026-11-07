import Foundation
import XCTest
@testable import XcblameKit

/// DESIGN §8.2.3: ordered steps with floors; rows go, totals stay.
final class ReportBudgetTests: XCTestCase {
    private func size(_ doc: ReportDocument, _ index: TaskIndex?) throws -> Int {
        try HTMLReporter.dataBlob(doc, taskIndex: index).utf8.count
    }

    func testNothingHappensWhenItFits() throws {
        let (doc, index) = try HTMLSample.populated()
        var out = doc
        var outIndex: TaskIndex? = index
        ReportBudget.apply(&out, taskIndex: &outIndex, maxBytes: 8_000_000, templateBytes: 100_000)
        XCTAssertEqual(out, doc)
        XCTAssertEqual(outIndex, index)
    }

    func testTopTasksGoFirst() throws {
        let (doc, index) = try HTMLSample.synthetic(tasks: 2_000, labels: 500, files: 300, hotspots: 3_000)
        var out = doc
        var outIndex: TaskIndex? = index
        ReportBudget.apply(&out, taskIndex: &outIndex, maxBytes: try size(doc, index) - 1, templateBytes: 0)
        XCTAssertEqual(out.truncation.steps.map(\.step), ["topTasks"])
        XCTAssertEqual(out.topTasks, Array(doc.topTasks!.prefix(500)))
        XCTAssertEqual(out.topTasksTotal, doc.topTasksTotal)
        XCTAssertEqual(out.hotspots, doc.hotspots)
    }

    func testHotspotsComeNextAndStopAsSoonAsItFits() throws {
        var (doc, index) = try HTMLSample.synthetic(tasks: 2_000, labels: 500, files: 300, hotspots: 3_000)
        doc.topTasks = Array(doc.topTasks!.prefix(25))
        let full = try size(doc, index)
        var out = doc
        var outIndex: TaskIndex? = index
        ReportBudget.apply(&out, taskIndex: &outIndex, maxBytes: full - 50_000, templateBytes: 0)
        XCTAssertEqual(out.truncation.steps.map(\.step), ["hotspots"])
        let step = try XCTUnwrap(out.truncation.steps.first)
        XCTAssertEqual(step.total, 3_000)
        XCTAssertEqual(step.kept, out.hotspots?.count)
        XCTAssertEqual(out.hotspotsTotal, 3_000)
        XCTAssertEqual(out.hotspotsShownShare, step.shownShare)
        XCTAssertLessThan(try XCTUnwrap(step.shownShare), 1)
        XCTAssertEqual(out.hotspots, Array(doc.hotspots!.prefix(out.hotspots!.count)), "a prefix of the ranking")
        XCTAssertEqual(outIndex, index)
        XCTAssertLessThanOrEqual(try size(out, outIndex), full - 50_000)
    }

    func testTaskIndexKeepsThePathAndEachTargetsLongestAndCountsTheDropped() throws {
        var (doc, index) = try HTMLSample.synthetic(tasks: 6_000, labels: 2_000, files: 30, hotspots: 30)
        doc.topTasks = Array(doc.topTasks!.prefix(25))
        var out = doc
        var outIndex: TaskIndex? = index
        // Room for the document but not the full index: forces step 3.
        let budget = try size(doc, nil) + 60_000
        ReportBudget.apply(&out, taskIndex: &outIndex, maxBytes: budget, templateBytes: 0)
        let steps = out.truncation.steps.map(\.step)
        XCTAssertTrue(steps.contains("taskIndex"), "\(steps)")
        let thin = try XCTUnwrap(outIndex)
        XCTAssertEqual(thin.taskIndexTotal, index.taskIndexTotal)
        XCTAssertEqual(thin.start.count + thin.dropped.reduce(0) { $0 + $1.tasks }, index.start.count)
        XCTAssertEqual(Double(thin.dur.reduce(0, +)) / 1000 + thin.dropped.reduce(0) { $0 + $1.seconds },
                       Double(index.dur.reduce(0, +)) / 1000, accuracy: 0.01)
        XCTAssertEqual(thin.onPath.filter { $0 == 1 }.count, index.onPath.filter { $0 == 1 }.count, "every on-path task kept")
        for target in Set(index.target) {
            let longest = index.start.indices.filter { index.target[$0] == target }.map { index.dur[$0] }.max()
            let kept = thin.start.indices.filter { thin.target[$0] == target }.map { thin.dur[$0] }.max()
            XCTAssertEqual(kept, longest, "target \(target) keeps its longest task")
        }
        for row in thin.start.indices { XCTAssertTrue(thin.labels.indices.contains(thin.label[row])) }
        XCTAssertEqual(thin.start, thin.start.sorted(), "still sorted by start")
        XCTAssertLessThan(try XCTUnwrap(thin.taskIndexShownShare), 1)
    }

    func testTargetsFoldIntoOtherSoThePartitionStays() throws {
        var (doc, _) = try HTMLSample.synthetic(tasks: 1_000, labels: 100, files: 10, hotspots: 10)
        doc.topTasks = Array(doc.topTasks!.prefix(25))
        var out = doc
        var none: TaskIndex?
        let budget = try size(doc, nil) - 1
        ReportBudget.apply(&out, taskIndex: &none, maxBytes: budget, templateBytes: 0)
        let rows = try XCTUnwrap(out.targets)
        XCTAssertTrue(out.truncation.steps.contains { $0.step == "targets" }, "\(out.truncation.steps)")
        XCTAssertEqual(rows.filter { !$0.isOther }.count, 25)
        XCTAssertEqual(rows.last?.isOther, true)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.tasks }, doc.targets!.reduce(0) { $0 + $1.tasks })
        XCTAssertEqual(rows.reduce(0) { $0 + $1.taskTime }, doc.targets!.reduce(0) { $0 + $1.taskTime }, accuracy: 1e-3)
        XCTAssertEqual(out.targetsTotal, doc.targetsTotal)
        XCTAssertNil(rows.last?.kinds, "folded kind mix is unknown, not summed")
    }

    func testLastResortDropsTheIndexThenKeepsOnlyTheHeader() throws {
        let (doc, index) = try HTMLSample.synthetic(tasks: 3_000, labels: 1_000, files: 300, hotspots: 600)
        var out = doc
        var outIndex: TaskIndex? = index
        ReportBudget.apply(&out, taskIndex: &outIndex, maxBytes: 20_000, templateBytes: 0)
        XCTAssertNil(outIndex)
        XCTAssertEqual(out.truncation.steps.suffix(2).map(\.step), ["lastResort", "lastResort"])
        XCTAssertNil(out.hotspots)
        XCTAssertNil(out.files)
        XCTAssertNil(out.criticalPath)
        XCTAssertEqual(out.hotspotsTotal, doc.hotspotsTotal, "withheld, not zero")
        XCTAssertEqual(out.filesTotal, doc.filesTotal)
        XCTAssertEqual(out.findings.count, doc.findings.count, "findings are never dropped")
        XCTAssertEqual(out.findings.first?.evidence.count, 3, "evidence floor")
        XCTAssertEqual(out.validation, doc.validation)
        XCTAssertEqual(out.build.span, doc.build.span)
        XCTAssertTrue(out.notes.last?.contains("report truncated") ?? false)
    }
}
