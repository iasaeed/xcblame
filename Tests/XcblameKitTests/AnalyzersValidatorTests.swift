import XCTest
@testable import XcblameKit

final class AnalyzersValidatorTests: XCTestCase {
    private func warnReason(_ status: CheckStatus) -> String? {
        if case let .warn(reason) = status { return reason }
        return nil
    }

    private func failReason(_ status: CheckStatus) -> String? {
        if case let .fail(reason) = status { return reason }
        return nil
    }

    func testSyntheticModelPassesEverythingImplemented() {
        let report = TestModels.validate(SyntheticModel.make(), serializedBytes: 10_000)
        for id in ["V1", "V2", "V4", "V5", "V6", "V7", "V8", "V10", "V13", "V14"] {
            XCTAssertEqual(report.status(id), .pass, "\(id): \(String(describing: report.check(id)?.detail))")
        }
        // V3, V9, V11 are placeholders here; ReportDocument.make replaces them (it has the build description).
        for id in ["V3", "V9", "V11", "V12", "V15"] {
            XCTAssertEqual(report.status(id), .notApplicable, id)
        }
        XCTAssertEqual(report.checks.count, 15)
        XCTAssertTrue(report.degradations.isEmpty)
        XCTAssertFalse(report.hasFailure)
    }

    func testDocumentReplacesTheV3V9V11Placeholders() throws {
        let doc = try ReportPipeline.run(SyntheticModel.make()).document
        let statuses = Dictionary(uniqueKeysWithValues: doc.validation.checks.map { ($0.id, $0.status) })
        XCTAssertEqual(statuses["V3"], "pass")
        XCTAssertEqual(statuses["V9"], "notApplicable", "the synthetic compile tasks name no files")
        XCTAssertEqual(statuses["V11"], "pass")
        XCTAssertEqual(doc.validation.checks.count, 15)
    }

    func testV4CatchesBusyAboveSpan() {
        var analysis = TestModels.analyze(TestModels.overlapping())
        XCTAssertEqual(Validator.checkV4(analysis).status, .pass)
        analysis.busy = analysis.span + 1
        XCTAssertTrue(Validator.checkV4(analysis).status.isFail)
        analysis = TestModels.analyze(TestModels.overlapping())
        analysis.averageParallelism = Double(analysis.peakParallelism) + 1
        XCTAssertTrue(Validator.checkV4(analysis).status.isFail)
    }

    // MARK: V1

    func testV1CatchesNaNAndNegativeDurations() {
        var nan = TestModels.task(1, start: 100, end: 101)
        nan.duration = .nan
        var negative = TestModels.task(2, start: 100, end: 101)
        negative.duration = -0.5
        let report = TestModels.validate(TestModels.model([TestModels.task(0, start: 100, end: 102), nan, negative]))
        let reason = failReason(report.status("V1"))
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("2 task(s)") == true, reason ?? "")
        XCTAssertTrue(report.hasFailure)
    }

    func testV1CatchesInfiniteStartAndBadSummaryRows() {
        var inf = TestModels.task(0, start: 100, end: 101)
        inf.start = .infinity
        let summary = TimingSummary(rows: [.init(ruleName: "Ld", taskCount: 1, seconds: -2)])
        let report = TestModels.validate(TestModels.model([inf], timingSummary: summary))
        let reason = failReason(report.status("V1")) ?? ""
        XCTAssertTrue(reason.contains("1 task(s)") && reason.contains("timing summary"), reason)
    }

    func testV1CatchesBrokenSessionWindow() {
        let report = TestModels.validate(TestModels.model([], start: 200, end: 100))
        XCTAssertNotNil(failReason(report.status("V1")))
    }

    // MARK: V2

    func testV2ClampsAndReportsTheCount() {
        let model = TestModels.model([
            TestModels.task(0, start: 99.8, end: 101), TestModels.task(1, start: 150, end: 205),
            TestModels.task(2, start: 110, end: 112),
        ])
        let reason = warnReason(TestModels.validate(model).status("V2")) ?? ""
        XCTAssertTrue(reason.contains("2 of 3 task intervals clamped"), reason)
    }

    // MARK: V5

    func testV5PassesWithinToleranceAndWarnsBeyond() {
        let tasks = [TestModels.task(0, start: 100, end: 110), TestModels.task(1, start: 100, end: 110)]
        // 20 s of SwiftCompile; 2 % of 20 s = 0.4 s tolerance (> 0.25 s).
        func status(_ seconds: Double, count: Int = 2) -> CheckStatus {
            let summary = TimingSummary(rows: [.init(ruleName: "SwiftCompile", taskCount: count, seconds: seconds)])
            return TestModels.validate(TestModels.model(tasks, timingSummary: summary)).status("V5")
        }
        XCTAssertEqual(status(20.3), .pass)
        XCTAssertEqual(status(19.7), .pass)
        let slow = warnReason(status(21.0)) ?? ""
        XCTAssertTrue(slow.contains("20.000 s vs summary 21.000 s"), slow)
    }

    func testV5SmallRuleUsesTheAbsoluteQuarterSecondFloor() {
        let tasks = [TestModels.task(0, "WriteAuxiliaryFile", kind: .aux, phase: .other, start: 100, end: 100.5)]
        func status(_ seconds: Double) -> CheckStatus {
            let summary = TimingSummary(rows: [.init(ruleName: "WriteAuxiliaryFile", taskCount: 1, seconds: seconds)])
            return TestModels.validate(TestModels.model(tasks, timingSummary: summary)).status("V5")
        }
        XCTAssertEqual(status(0.74), .pass)
        XCTAssertNotNil(warnReason(status(0.8)))
    }

    func testV5TaskCountMismatchWarnsWithBothCounts() {
        let tasks = (0..<85).map { TestModels.task($0, "WriteAuxiliaryFile", kind: .aux, phase: .other,
                                                    start: 100, end: 100.005) }
        let summary = TimingSummary(rows: [.init(ruleName: "WriteAuxiliaryFile", taskCount: 84, seconds: 0.425)])
        let reason = warnReason(TestModels.validate(TestModels.model(tasks, timingSummary: summary)).status("V5")) ?? ""
        XCTAssertTrue(reason.contains("85 tasks vs summary 84"), reason)
    }

    func testV5ComparesPerRuleNameNotPerKind() {
        // Both rules classify as swiftPlan; the summary has one row per rule, so each is compared on its own.
        let tasks = [
            TestModels.task(0, "SwiftDriver", kind: .swiftPlan, start: 100, end: 100.4),
            TestModels.task(1, "SwiftDriver Compilation", kind: .swiftPlan, start: 100, end: 102),
            TestModels.task(2, "SwiftDriver Compilation", kind: .swiftPlan, start: 100, end: 102),
        ]
        func status(driverCount: Int, compilationSeconds: Double) -> CheckStatus {
            let summary = TimingSummary(rows: [
                .init(ruleName: "SwiftDriver", taskCount: driverCount, seconds: 0.4),
                .init(ruleName: "SwiftDriver Compilation", taskCount: 2, seconds: compilationSeconds),
            ])
            return TestModels.validate(TestModels.model(tasks, timingSummary: summary)).status("V5")
        }
        XCTAssertEqual(status(driverCount: 1, compilationSeconds: 4.0), .pass)
        let wrongCount = warnReason(status(driverCount: 2, compilationSeconds: 4.0)) ?? ""
        XCTAssertTrue(wrongCount.contains("SwiftDriver: 1 tasks vs summary 2"), wrongCount)
        let wrongSeconds = warnReason(status(driverCount: 1, compilationSeconds: 5.0)) ?? ""
        XCTAssertTrue(wrongSeconds.contains("SwiftDriver Compilation: 4.000 s vs summary 5.000 s"), wrongSeconds)
    }

    func testV5IgnoresReusedTasksOutsideTheSessionWindow() {
        let tasks = [
            TestModels.task(0, start: 100, end: 110),
            TestModels.task(1, start: 10, end: 20),  // up to date: started long before the window
        ]
        let summary = TimingSummary(rows: [.init(ruleName: "SwiftCompile", taskCount: 1, seconds: 10)])
        XCTAssertEqual(TestModels.validate(TestModels.model(tasks, timingSummary: summary)).status("V5"), .pass)
    }

    func testV5IsNotApplicableWithoutASummary() {
        XCTAssertEqual(TestModels.validate(TestModels.overlapping()).status("V5"), .notApplicable)
    }

    // MARK: V6

    func testV6FailsOnABrokenPartition() {
        let model = SyntheticModel.make()
        var analysis = TestModels.analyze(model)
        analysis.byKind.rows[0].seconds += 5
        let report = Validator.validate(model, analysis: analysis)
        XCTAssertTrue(failReason(report.status("V6"))?.contains("kind: rows sum to") == true)
    }

    func testV6FailsWithoutAnOtherRow() {
        let model = SyntheticModel.make()
        var analysis = TestModels.analyze(model)
        analysis.byPhase.rows.removeAll { $0.isOther }
        XCTAssertTrue(failReason(Validator.validate(model, analysis: analysis).status("V6"))?
            .contains("phase: no other/unclassified row") == true)
    }

    // MARK: V7, V8, V10

    func testV7WarnsAboveFivePercentUnclassified() {
        let model = TestModels.model([
            TestModels.task(0, start: 100, end: 190),
            TestModels.task(1, "Mystery", kind: .other, phase: .other, start: 100, end: 110),
        ])
        let reason = warnReason(TestModels.validate(model).status("V7")) ?? ""
        XCTAssertTrue(reason.contains("10.0% of task time is unclassified"), reason)
    }

    func testV8RejectsTargetsNamedAfterBuildSystemSteps() {
        let model = TestModels.model([], targets: [TestModels.target(0, "App"), TestModels.target(1, "SwiftCompile")])
        XCTAssertTrue(failReason(TestModels.validate(model).status("V8"))?.contains("'SwiftCompile'") == true)
    }

    func testV8RejectsMoreTargetsThanDistinctNames() {
        let model = TestModels.model([], targets: [TestModels.target(0, "App", project: "A.xcodeproj"),
                                                   TestModels.target(1, "App", project: "A.xcodeproj")])
        XCTAssertTrue(failReason(TestModels.validate(model).status("V8"))?
            .contains("2 targets but only 1 distinct") == true)
    }

    func testV8AllowsBucketsAndSameNameInDifferentProjects() {
        let model = TestModels.model([], targets: [
            TestModels.target(0, "Core", project: "A.xcodeproj"), TestModels.target(1, "Core", project: "B.xcodeproj"),
            TestModels.target(2, Target.explicitModulesBucket, bucket: true),
        ])
        XCTAssertEqual(TestModels.validate(model).status("V8"), .pass)
    }

    func testV8RejectsDanglingTargetId() {
        let model = TestModels.model([TestModels.task(0, target: 7, start: 100, end: 101)])
        XCTAssertNotNil(failReason(TestModels.validate(model).status("V8")))
    }

    func testV10FailedButCancelledFails() {
        var task = TestModels.task(0, start: 100, end: 101)
        task.resultCode = 1
        task.slfOnly = RawSection.SLFOnly(wasCancelled: true)
        let report = TestModels.validate(TestModels.model([task]))
        XCTAssertTrue(failReason(report.status("V10"))?.contains("failed and cancelled") == true)
        var ok = task
        ok.resultCode = 0
        XCTAssertEqual(TestModels.validate(TestModels.model([ok])).status("V10"), .pass)
    }

    // MARK: V13, V14

    func testV13OverBudgetFails() {
        let model = SyntheticModel.make()
        XCTAssertEqual(TestModels.validate(model, serializedBytes: 100, budget: 100).status("V13"), .pass)
        let reason = failReason(TestModels.validate(model, serializedBytes: 101, budget: 100).status("V13")) ?? ""
        XCTAssertTrue(reason.contains("101 bytes") && reason.contains("100 bytes"), reason)
        XCTAssertEqual(TestModels.validate(model, serializedBytes: nil).status("V13"), .notApplicable)
    }

    func testV14DoesNotHideAFailure() {
        var nan = TestModels.task(0, start: 100, end: 101)
        nan.duration = .nan
        var model = TestModels.model([nan])
        model.decodeWarnings = [DecodeWarning(kind: .schemaDrift, detail: "drift", affectsTiming: true)]
        XCTAssertNotNil(failReason(TestModels.validate(model).status("V1")))
    }

    /// Verifier v0.2 #8: failures (and V14 drift) degrade the report; a plain warn such as a V2 clamp does not.
    func testValidatorDegradationsCarryFailsNotPlainWarns() {
        let model = TestModels.model([TestModels.task(0, start: 99.8, end: 101)])
        let report = TestModels.validate(model)
        XCTAssertEqual(report.status("V2").label, "warn")
        XCTAssertTrue(report.degradations.isEmpty, "\(report.degradations)")
        var nan = TestModels.task(0, start: 100, end: 101)
        nan.duration = .nan
        XCTAssertTrue(TestModels.validate(TestModels.model([nan])).degradations.contains { $0.detail.hasPrefix("V1:") })
        var drifted = TestModels.model([TestModels.task(0, start: 100, end: 101)])
        drifted.decodeWarnings = [DecodeWarning(kind: .schemaDrift, detail: "drift", affectsTiming: true)]
        XCTAssertTrue(TestModels.validate(drifted).degradations.contains { $0.detail.hasPrefix("V14:") })
    }
}
