import XCTest
@testable import XcblameKit

/// The noise model of docs/SCHEMA-v0.4.md "Noise model", with hand-computed numbers.
final class RegressionNoiseTests: XCTestCase {
    private func baseline(_ walls: [Double], processWalls: [Double]? = nil) throws -> Baseline {
        try Baseline.make(from: CompareFixtures.reports(walls, processWalls: processWalls),
                          source: .init(kind: "report", refs: ["r.json"]), now: CompareFixtures.date)
    }

    private func evaluate(_ base: [Double], _ now: [Double], threshold: Double? = nil,
                          allowance: Double = 0.05) throws -> ReportDocument.Regression {
        try Regression.evaluate(current: CompareFixtures.reports(now), baseline: baseline(base),
                                options: .init(thresholdPct: threshold, allowancePct: allowance))
    }

    func testMedianAndMADByHand() {
        XCTAssertEqual(Stats.median([3, 1, 2]), 2)
        XCTAssertEqual(Stats.median([4, 1, 2, 3]), 2.5)
        XCTAssertNil(Stats.median([]))
        // |x - 11| = 1, 1, 0, 9, 0.5: median 1.
        XCTAssertEqual(Stats.mad([10, 12, 11, 20, 10.5]), 1)
        XCTAssertEqual(Stats.mad([7]), 0)
        XCTAssertEqual(Stats.pooled(0.3, 0.4), (0.125).squareRoot())
    }

    /// baseline 10 ± {0, .1, .1}: median 10, MAD 0.1; now 10.2 ± {0, .1, .1}: MAD 0.1; pooled 0.1; band max(0.3, 0.2).
    func testSameInsideTheBand() throws {
        let r = try evaluate([10, 10.1, 9.9], [10.2, 10.3, 10.1])
        XCTAssertEqual(r.verdict, "same")
        XCTAssertEqual(r.noiseBand.method, "mad")
        XCTAssertEqual(r.noiseBand.pooledMad ?? -1, 0.1, accuracy: 1e-9)
        XCTAssertEqual(r.noiseBand.band ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertEqual(r.wall.delta ?? -1, 0.2, accuracy: 1e-9)
        XCTAssertEqual(r.noiseBand.runsBaseline, 3)
        XCTAssertEqual(r.noiseBand.runsCurrent, 3)
    }

    func testSlowerAndFasterBeyondTheBand() throws {
        let slower = try evaluate([10, 10.1, 9.9], [11, 11.1, 10.9])
        XCTAssertEqual(slower.verdict, "slower")
        XCTAssertEqual(slower.wall.deltaPct ?? -1, 0.1, accuracy: 1e-9)
        let faster = try evaluate([10, 10.1, 9.9], [9, 9.1, 8.9])
        XCTAssertEqual(faster.verdict, "faster")
        XCTAssertLessThan(faster.wall.delta ?? 0, 0)
    }

    func testTwoPercentFloorIsStrict() throws {
        // MAD 0: the band is the 2 % floor, 2 s of 100. Exactly 2 s is inside, a bit more is outside.
        XCTAssertEqual(try evaluate([100, 100, 100], [102, 102, 102]).verdict, "same")
        XCTAssertEqual(try evaluate([100, 100, 100], [102.5, 102.5, 102.5]).verdict, "slower")
        XCTAssertEqual(try evaluate([100, 100, 100], [98, 98, 98]).verdict, "same")
        XCTAssertEqual(try evaluate([100, 100, 100], [97.9, 97.9, 97.9]).verdict, "faster")
        XCTAssertEqual(try evaluate([100, 100, 100], [102, 102, 102]).noiseBand.band, 2)
    }

    func testWideNoiseHidesALargeDelta() throws {
        // baseline 10, 14, 6: median 10, MAD 4. now 14, 18, 10: median 14, MAD 4. pooled 4, band 12 > delta 4.
        let r = try evaluate([10, 14, 6], [14, 18, 10])
        XCTAssertEqual(r.verdict, "same")
        XCTAssertEqual(r.noiseBand.band, 12)
    }

    func testFewerThanThreeRunsIsIndicative() throws {
        let one = try evaluate([100], [140])
        XCTAssertEqual(one.verdict, "indicative")
        XCTAssertEqual(one.noiseBand.method, "threshold")
        XCTAssertNil(one.noiseBand.pooledMad)
        XCTAssertNil(one.noiseBand.band)
        XCTAssertEqual(one.wall.delta, 40, "the sign still tells the direction")
        // Exactly three on one side only: still indicative; exactly three on both: a band.
        XCTAssertEqual(try evaluate([100, 100, 100], [140, 140]).verdict, "indicative")
        XCTAssertEqual(try evaluate([100, 100], [140, 140, 140]).verdict, "indicative")
        XCTAssertEqual(try evaluate([100, 100, 100], [140, 140, 140]).verdict, "slower")
    }

    func testThresholdIsStrictWithAMeasuredVerdict() throws {
        // 105 against 100 is exactly +5 %: not over a 5 % threshold, over a 4 % one.
        let at = try evaluate([100, 100, 100], [105, 105, 105], threshold: 0.05)
        XCTAssertEqual(at.verdict, "slower")
        XCTAssertFalse(at.failed)
        XCTAssertTrue(try evaluate([100, 100, 100], [105, 105, 105], threshold: 0.04).failed)
        // Inside the band nothing fails, whatever the threshold says (1 % under the 2 % floor).
        let quiet = try evaluate([100, 100, 100], [101, 101, 101], threshold: 0.005)
        XCTAssertEqual(quiet.verdict, "same")
        XCTAssertFalse(quiet.failed)
        // Faster never fails; no threshold never fails.
        XCTAssertFalse(try evaluate([100, 100, 100], [50, 50, 50], threshold: 0).failed)
        XCTAssertFalse(try evaluate([100, 100, 100], [200, 200, 200]).failed)
        XCTAssertNil(try evaluate([100, 100, 100], [200, 200, 200]).thresholdPct)
    }

    func testIndicativeAddsTheAllowance() throws {
        // threshold 5 % + 5 % allowance = 10 %: +9 % passes, +10 % is not over, +11 % fails.
        XCTAssertFalse(try evaluate([100], [109], threshold: 0.05).failed)
        XCTAssertFalse(try evaluate([100], [110], threshold: 0.05).failed)
        let over = try evaluate([100], [111], threshold: 0.05)
        XCTAssertTrue(over.failed)
        XCTAssertEqual(over.allowancePct, 0.05)
        // The allowance is configurable.
        XCTAssertTrue(try evaluate([100], [108], threshold: 0.05, allowance: 0.02).failed)
        XCTAssertFalse(try evaluate([100], [108], threshold: 0.05, allowance: 0.05).failed)
        XCTAssertFalse(try evaluate([100], [180], threshold: nil).failed)
    }

    func testZeroBaselineIsIndicativeAndNeverFails() throws {
        let r = try evaluate([0, 0, 0], [5, 5, 5], threshold: 0)
        XCTAssertEqual(r.verdict, "indicative")
        XCTAssertFalse(r.failed)
        XCTAssertNil(r.wall.deltaPct)
        XCTAssertTrue(r.notes.contains { $0.contains("median is 0") }, "\(r.notes)")
    }

    func testBothWallBases() throws {
        // processWall on every run of both sides: used. Missing on a current run: the log span, when the baseline is a span.
        let process = try Regression.evaluate(
            current: CompareFixtures.reports([10, 10, 10], processWalls: [12, 12, 12]),
            baseline: baseline([10, 10, 10], processWalls: [11, 11, 11]))
        XCTAssertEqual(process.wallBasis, "processWall")
        XCTAssertEqual(process.wall.baseline, 11)
        XCTAssertEqual(process.wall.current, 12)
        let span = try Regression.evaluate(current: CompareFixtures.reports([10, 10, 10], processWalls: [12, 12, 12]),
                                           baseline: baseline([10, 10, 10]))
        XCTAssertEqual(span.wallBasis, "span")
        XCTAssertEqual(span.wall.current, 10)
        // A process-wall baseline cannot be compared with a run that has none: wall unknown, busy still compared.
        let mixed = try Regression.evaluate(current: CompareFixtures.reports([10, 10, 10]),
                                            baseline: baseline([10, 10, 10], processWalls: [11, 11, 11]), options: .init(thresholdPct: 0))
        XCTAssertEqual(mixed.verdict, "indicative")
        XCTAssertNil(mixed.wall.baseline)
        XCTAssertFalse(mixed.failed)
        XCTAssertNotNil(mixed.busy.delta)
        XCTAssertTrue(mixed.notes.contains { $0.contains("process wall") })
        // The reference form takes processWall only when every run on both sides has it.
        let reference = try Regression.evaluate(
            current: CompareFixtures.reports([10], processWalls: [12]), reference: CompareFixtures.reports([10]),
            referenceRef: "a")
        XCTAssertEqual(reference.wallBasis, "span")
    }

    func testBusyAndCriticalPathUseTheirOwnMetrics() throws {
        let base = try Baseline.make(from: [CompareFixtures.report(span: 100, busy: 90, path: 80)],
                                     source: .init(kind: "report", refs: ["r"]))
        let r = try Regression.evaluate(current: [CompareFixtures.report(span: 100, busy: 99, path: 88)], baseline: base)
        XCTAssertEqual(r.busy.delta, 9)
        XCTAssertEqual(r.busy.deltaPct ?? 0, 0.1, accuracy: 1e-9)
        XCTAssertEqual(r.criticalPath.delta, 8)
        XCTAssertEqual(r.wall.delta, 0)
    }

    func testKeyMismatchIsAUsageErrorAndUnknownFieldsAreNotCompared() throws {
        let base = try baseline([10, 10, 10])
        for (field, current) in [("scheme", try CompareFixtures.report(span: 10, scheme: "Other")),
                                 ("kind", try CompareFixtures.report(span: 10, kind: "incremental")),
                                 ("configuration", try CompareFixtures.report(span: 10, configuration: "Release")),
                                 ("destination", try CompareFixtures.report(span: 10, destination: "iOS Simulator"))] {
            XCTAssertThrowsError(try Regression.evaluate(current: [current], baseline: base)) { error in
                guard case let XcblameError.usage(message) = error else { return XCTFail("\(error)") }
                XCTAssertTrue(message.contains(field), message)
            }
        }
        // A current report that does not know its scheme is not refused.
        XCTAssertNoThrow(try Regression.evaluate(current: [CompareFixtures.report(span: 10, scheme: nil, destination: nil)],
                                                 baseline: base))
        // A different inferred Xcode is attributed, not refused: the first attribution.
        let newer = try Regression.evaluate(current: [CompareFixtures.report(span: 10, xcode: "26.1")], baseline: base)
        XCTAssertEqual(newer.attribution.first?.kind, "env")
        XCTAssertEqual(newer.attribution.first?.subject, "xcode")
        XCTAssertEqual(newer.attribution.first?.detail, "26.0 -> 26.1 (inferred)")
    }

    func testAttributionOrderIsEnvironmentFirstThenBySize() {
        let items: [ReportDocument.Regression.Attribution] = [
            .init(kind: "setting", subject: "App:Debug:X", detail: "", deltaSeconds: nil),
            .init(kind: "task", subject: "t1", detail: "", deltaSeconds: 9),
            .init(kind: "path", subject: "p1", detail: "", deltaSeconds: 0.5),
            .init(kind: "path", subject: "p2", detail: "", deltaSeconds: -2),
            .init(kind: "target", subject: "T", detail: "", deltaSeconds: 3),
            .init(kind: "phase", subject: "compile", detail: "", deltaSeconds: 1),
            .init(kind: "phase", subject: "link", detail: "", deltaSeconds: 4),
            .init(kind: "env", subject: "xcode", detail: "", deltaSeconds: nil),
            .init(kind: "env", subject: "hwModel", detail: "", deltaSeconds: nil),
        ]
        XCTAssertEqual(Regression.ordered(items).map(\.subject),
                       ["xcode", "hwModel", "link", "compile", "T", "p2", "p1", "t1", "App:Debug:X"])
    }

    func testReferenceAttributionFollowsTheOrderOnTheFixtures() throws {
        let r = try Regression.evaluate(current: [CompareFixtures.xcode27.document],
                                        reference: [CompareFixtures.xcode26.document], referenceRef: "a")
        let ranks = ["env": 0, "phase": 1, "target": 2, "path": 3, "task": 4, "setting": 5]
        let kinds = r.attribution.map { ranks[$0.kind] ?? 9 }
        XCTAssertEqual(kinds, kinds.sorted(), "\(r.attribution.map(\.kind))")
        XCTAssertEqual(r.attribution.first?.kind, "env")
        XCTAssertEqual(r.attribution.first?.subject, "xcode")
        XCTAssertEqual(r.attribution.first?.detail, "26.0 -> 27.1 (inferred)")
        for kind in ["phase", "target", "path"] {
            let seconds = r.attribution.filter { $0.kind == kind }.map { abs($0.deltaSeconds ?? 0) }
            XCTAssertFalse(seconds.isEmpty, kind)
            XCTAssertEqual(seconds, seconds.sorted(by: >), kind)
        }
        XCTAssertEqual(r.baseline.source, "report")
        XCTAssertEqual(r.baseline.xcode, "26.0")
        XCTAssertEqual(r.verdict, "indicative")
    }

    func testBaselineTaskDigestsNameNewTasks() throws {
        let kept = CompareFixtures.row("SwiftCompile", "App", "aa", ms: 1000)
        let gone = CompareFixtures.row("Ld", "App", "bb", ms: 500)
        let base = try Baseline.make(from: [CompareFixtures.report(span: 10)], source: .init(kind: "report", refs: ["r"]),
                                     taskRows: [kept, gone])
        let fresh = CompareFixtures.row("SwiftCompile", "Kit", "cc", ms: 2500, onPath: true)
        let r = try Regression.evaluate(current: [CompareFixtures.report(span: 10)], baseline: base, baselineRef: ".xcblame/baseline.json",
                                        currentTaskRows: [kept, fresh])
        let tasks = r.attribution.filter { $0.kind == "task" }
        XCTAssertEqual(tasks.map(\.subject), ["Kit: SwiftCompile", "removed tasks"])
        XCTAssertEqual(tasks.first?.deltaSeconds, 2.5)
        XCTAssertNil(tasks.last?.deltaSeconds)
        XCTAssertEqual(r.baseline.ref, ".xcblame/baseline.json")
        XCTAssertEqual(r.baseline.source, "file")
    }
}
