import XCTest
@testable import XcblameKit

final class AnalyzersTimingTests: XCTestCase {
    func testSweepUnionOfOverlappingIntervals() {
        let intervals = [
            Interval(start: 0, end: 4), Interval(start: 2, end: 6), Interval(start: 8, end: 10),
            Interval(start: 10, end: 12), Interval(start: 5, end: 5),
        ]
        let result = Timing.sweep(intervals)
        // [0,6] = 6 s and [8,12] = 4 s; touching intervals do not overlap; zero length is ignored.
        XCTAssertEqual(result.busy, 10, accuracy: 1e-9)
        XCTAssertEqual(result.peak, 2)
    }

    func testSweepEmptyAndNested() {
        XCTAssertEqual(Timing.sweep([]).busy, 0)
        XCTAssertEqual(Timing.sweep([]).peak, 0)
        let nested = Timing.sweep([Interval(start: 0, end: 10), Interval(start: 2, end: 3), Interval(start: 2, end: 4)])
        XCTAssertEqual(nested.busy, 10, accuracy: 1e-9)
        XCTAssertEqual(nested.peak, 3)
    }

    func testBusyTaskTimeAndParallelism() {
        let a = TestModels.analyze(TestModels.overlapping())
        XCTAssertEqual(a.span, 20, accuracy: 1e-9)
        XCTAssertEqual(a.taskCount, 5)
        XCTAssertEqual(a.zeroLengthCount, 1)
        XCTAssertEqual(a.taskTime, 12, accuracy: 1e-9)
        XCTAssertEqual(a.busy, 10, accuracy: 1e-9)
        XCTAssertEqual(a.idle, 10, accuracy: 1e-9)
        XCTAssertEqual(a.peakParallelism, 2)
        XCTAssertEqual(a.averageParallelism ?? -1, 1.2, accuracy: 1e-9)
    }

    func testNoTasksHasNoAverageParallelism() {
        let a = TestModels.analyze(TestModels.model([]))
        XCTAssertEqual(a.taskTime, 0)
        XCTAssertNil(a.averageParallelism)
        XCTAssertNil(a.byKind.share(of: 0))
    }

    func testRollupsArePartitionsWithOtherRowEvenWhenEmpty() {
        let model = TestModels.model(
            [TestModels.task(0, target: 0, start: 100, end: 103), TestModels.task(1, target: 1, start: 101, end: 102)],
            targets: [TestModels.target(0, "App"), TestModels.target(1, "Lib")])
        let a = TestModels.analyze(model)
        for rollup in [a.byKind, a.byPhase, a.byTarget] {
            XCTAssertTrue(rollup.isPartition, rollup.dimension)
            XCTAssertTrue(rollup.hasOtherRow, rollup.dimension)
            XCTAssertEqual(rollup.sumSeconds, 4, accuracy: 1e-9)
            XCTAssertEqual(rollup.sumTasks, 2)
        }
        XCTAssertEqual(a.byKind.rows.first { $0.isOther }?.seconds, 0)
        XCTAssertEqual(a.byKind.rows.first { $0.isOther }?.key, "other")
        XCTAssertEqual(a.byTarget.rows.first { $0.isOther }?.key, "unclassified")
        XCTAssertEqual(a.byTarget.rows.map(\.name), ["App", "Lib", "(unattributed)"])
        XCTAssertEqual(a.byTarget.rows.first?.seconds, 3)
    }

    func testOtherKindTasksLandInOtherRow() {
        let model = TestModels.model([
            TestModels.task(0, start: 100, end: 102),
            TestModels.task(1, "Mystery", kind: .other, phase: .other, start: 100, end: 101),
        ])
        let a = TestModels.analyze(model)
        XCTAssertEqual(a.byKind.rows.first { $0.isOther }?.seconds ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(a.byKind.rows.first { $0.isOther }?.taskCount, 1)
        XCTAssertTrue(a.byKind.isPartition)
    }

    func testTopTasksAreCappedSortedAndReportShownShare() {
        let model = TestModels.model((0..<10).map { TestModels.task($0, start: 100, end: 100 + Double($0 + 1)) })
        let a = TestModels.analyze(model, topN: 3)
        XCTAssertEqual(a.topTasks.map(\.id), [9, 8, 7])
        XCTAssertEqual(a.topTasks.map(\.seconds), [10, 9, 8])
        XCTAssertEqual(a.taskCount, 10)
        XCTAssertEqual(a.taskTime, 55, accuracy: 1e-9)
    }

    func testMetricsAreCountedNotExtrapolated() {
        let real = TaskMetrics(start: nil, duration: 1, userCPU: 1, systemCPU: 0.5, maxRSS: 2_000, isPlaceholder: false)
        let placeholder = TaskMetrics(start: nil, duration: 1, userCPU: 1, systemCPU: 1, maxRSS: 0, isPlaceholder: true)
        let model = TestModels.model([
            TestModels.task(0, start: 100, end: 101, metrics: real),
            TestModels.task(1, start: 100, end: 101, metrics: placeholder),
            TestModels.task(2, start: 100, end: 101),
        ])
        let m = TestModels.analyze(model).metrics
        XCTAssertEqual(m.tasksTotal, 3)
        XCTAssertEqual(m.tasksWithCPU, 1)
        XCTAssertEqual(m.placeholders, 1)
        XCTAssertEqual(m.cpuSeconds ?? -1, 1.5, accuracy: 1e-9)
        XCTAssertEqual(m.maxRSSBytes, 2_000)
    }

    func testNoMetricsMeansNilNotZero() {
        let m = TestModels.analyze(TestModels.model([TestModels.task(0, start: 100, end: 101)])).metrics
        XCTAssertNil(m.cpuSeconds)
        XCTAssertNil(m.maxRSSBytes)
    }

    func testReusedTasksAreExcludedAndOutOfWindowIntervalsClamped() {
        let model = TestModels.model([
            TestModels.task(0, start: 99.4, end: 101),    // started 0.6 s early: reused, excluded
            TestModels.task(1, start: 99.8, end: 101),    // 0.2 s early: clamped to [100,101]
            TestModels.task(2, start: 150, end: 205),     // ends after the window: clamped to [150,200]
            TestModels.task(3, start: 110, end: 112),
        ])
        let a = TestModels.analyze(model)
        XCTAssertEqual(a.reusedCount, 1)
        XCTAssertEqual(a.clampedCount, 2)
        XCTAssertEqual(a.taskCount, 3)
        XCTAssertEqual(a.taskTime, 1 + 50 + 2, accuracy: 1e-9)
    }

    func testInvalidTasksAreExcludedAndCounted() {
        let bad = TestModels.task(1, start: 100, end: 101)
        var nan = bad
        nan.duration = .nan
        var negative = TestModels.task(2, start: 100, end: 101)
        negative.duration = -1
        let a = TestModels.analyze(TestModels.model([TestModels.task(0, start: 100, end: 102), nan, negative]))
        XCTAssertEqual(a.invalidCount, 2)
        XCTAssertEqual(a.taskCount, 1)
        XCTAssertEqual(a.taskTime, 2, accuracy: 1e-9)
    }

    func testDiagnosticsSummary() {
        let a = TestModels.analyze(SyntheticModel.make())
        XCTAssertEqual(a.diagnostics.unique, 1)
        XCTAssertEqual(a.diagnostics.warnings, 1)
        XCTAssertEqual(a.diagnostics.errors, 0)
    }

    func testSyntheticModelShapeAndAnalysis() {
        let model = SyntheticModel.make()
        XCTAssertEqual(model.tasks.count, 50)
        XCTAssertEqual(model.targets.count, 4)
        XCTAssertTrue(model.tasks.contains { !$0.subspans.isEmpty })
        let a = TestModels.analyze(model)
        XCTAssertEqual(a.taskCount, 50)
        XCTAssertEqual(a.span, SyntheticModel.sessionSpan)
        XCTAssertLessThanOrEqual(a.busy, a.span)
        XCTAssertLessThanOrEqual(a.busy, a.taskTime)
        XCTAssertGreaterThan(a.peakParallelism, 3)
        XCTAssertTrue(a.byKind.isPartition && a.byPhase.isPartition && a.byTarget.isPartition)
        // The summary rows are built from the same tasks, so subspans are never summed on top.
        XCTAssertEqual(a.taskTime, model.tasks.reduce(0) { $0 + $1.duration }, accuracy: 1e-9)
    }
}
