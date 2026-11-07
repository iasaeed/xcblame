import Foundation
import XCTest
@testable import XcblameKit

/// End to end (reader -> builder -> ReportPipeline): damaged input must come out marked degraded, never as a clean
/// report (code review v0.1 rows 1-3, 22).
final class DegradedInputTests: XCTestCase {
    static let date = Date(timeIntervalSince1970: 1_800_000_000)

    func report(_ raw: RawLog) throws -> ReportPipeline.Result {
        try ReportPipeline.run(BuildModelBuilder.build(raw, reader: .slf),
                               options: .init(generatedAt: Self.date, inputPath: "crafted"))
    }

    func testTruncatedLogIsDegraded() throws {
        let data = try Data(contentsOf: SLFFixtures.cli26Clean)
        let raw = try SLFReader.read(data: data.prefix(data.count / 2))
        let result = try report(raw)
        let doc = result.document
        XCTAssertTrue(doc.validation.degraded)
        XCTAssertTrue(doc.degradations.contains { $0.kind == "truncated" }, "\(doc.degradations)")
        XCTAssertFalse(result.validation.hasFailure, "a partial analysis is not a failure (exit stays 0)")
        let text = TextReporter.render(doc)
        XCTAssertTrue(text.contains("status  DEGRADED"), text)
        XCTAssertTrue(text.contains("truncated: input truncated"), text)
        let json = try JSONSerialization.jsonObject(with: JSONReporter.render(doc)) as? [String: Any]
        XCTAssertEqual((json?["validation"] as? [String: Any])?["degraded"] as? Bool, true)
    }

    func testCompleteLogHasNoReaderDegradation() throws {
        let doc = try report(try SLFReader.read(url: SLFFixtures.cli26Clean)).document
        XCTAssertFalse(doc.degradations.contains { $0.kind == "truncated" || $0.kind == "schemaDrift" })
    }

    // MARK: V14 on decoder-produced drift

    /// Root 100..120 s with CompileC 101..102, Ld 103..104 (drifted per `drift`) and a timing summary for Ld.
    func driftedLog(_ drift: (inout SLFWriter) -> Void) -> RawLog {
        RawLog.decoded(SLFWriter.log(duration: 20) { w in
            w.section(cd: "CompileC a", start: 101)
            drift(&w)
            w.section(cd: nil, start: 110, domain: BuildModelBuilder.timingSummaryDomain, children: { w in
                w.section(cd: "Ld (1 task) | 1.0 seconds", start: 110,
                          domain: BuildModelBuilder.timingAggregateDomain)
                return 1
            })
            return 3
        })
    }

    func testV14WarnsOnMissingStartSlot() throws {
        let raw = driftedLog { $0.section(cd: "Ld b", start: 103, omitStart: true) }
        XCTAssertTrue(raw.decodeWarnings.contains { $0.kind == .schemaDrift && $0.affectsTiming },
                      "\(raw.decodeWarnings)")
        let result = try report(raw)
        let v = result.validation
        XCTAssertNotNil(v.status("V14").reason, "V14 \(v.status("V14"))")
        XCTAssertEqual(v.status("V14").label, "warn")
        XCTAssertEqual(v.status("V2").label, "warn")
        XCTAssertEqual(v.status("V5").label, "warn", "\(v.status("V5"))")
        XCTAssertTrue(result.document.validation.degraded)
        XCTAssertTrue(result.document.degradations.contains { $0.kind == "schemaDrift" })
    }

    func testV14PassesOnDriftOutsideTimingButReportIsDegraded() throws {
        let raw = driftedLog { $0.section(cd: "Ld b", start: 103, afterCommand: { $0.dbl(1); $0.int(3) }) }
        XCTAssertEqual(raw.decodeWarnings.map(\.kind), [.schemaDrift])
        XCTAssertFalse(raw.decodeWarnings[0].affectsTiming)
        let result = try report(raw)
        XCTAssertEqual(result.validation.status("V14"), .pass)
        XCTAssertEqual(result.validation.status("V2"), .pass)
        XCTAssertEqual(result.validation.status("V5"), .pass)
        XCTAssertTrue(result.document.degradations.contains { $0.kind == "schemaDrift" })
    }
}

extension DegradedInputTests {
    // MARK: Missing time slot

    func testMissingStartSlotIsUntimedNotReused() throws {
        let raw = RawLog.decoded(SLFWriter.log(duration: 30) { w in
            w.section(cd: "SwiftCompile normal arm64 a.swift", start: 101, duration: 10, omitStart: true)
            w.section(cd: "Ld b", start: 103, duration: 2)
            return 2
        })
        let model = BuildModelBuilder.build(raw, reader: .slf)
        XCTAssertEqual(model.tasks.map(\.ruleName), ["SwiftCompile", "Ld"])
        XCTAssertEqual(model.tasks.map(\.hasTiming), [false, true])
        let result = try report(raw)
        XCTAssertEqual(result.analysis.reusedCount, 0)
        XCTAssertEqual(result.analysis.untimedTaskIds, [0])
        XCTAssertEqual(result.analysis.taskCount, 1)
        XCTAssertEqual(result.analysis.taskTime, 2, accuracy: 1e-9)
        XCTAssertFalse(result.validation.status("V1").isFail, "\(result.validation.status("V1"))")
        let build = result.document.build
        XCTAssertEqual(build.tasksInModel, 2)
        XCTAssertEqual(build.tasksWithoutTimingTotal, 1)
        XCTAssertEqual(build.tasksWithoutTiming.map(\.rule), ["SwiftCompile"])
        let text = TextReporter.render(result.document)
        XCTAssertTrue(text.contains("tasks without timing (1): SwiftCompile"), text)
        XCTAssertFalse(text.contains("reused"), text)
    }

    func testNegativeIntTimeIsMissingNotHuge() {
        var w = SLFWriter()
        w.int(11)
        w.obj("IDECommandLineBuildLog")
        w.int(2); w.str(Locator.buildLogDomain); w.str("t"); w.str("s"); w.dbl(100)
        w.bytes += Array("18446744073709551615#".utf8)  // -1 sentinel where the end double belongs
        let raw = RawLog.decoded(w.bytes)
        XCTAssertTrue(raw.root.timingMissing)
    }

    func testTruncatedCutsNeverInventReusedTasks() throws {
        let data = try Data(contentsOf: SLFFixtures.cli26Clean)
        for cut in [data.count * 3 / 61, data.count / 4, data.count * 3 / 5] {
            let analysis = try report(try SLFReader.read(data: data.prefix(cut))).analysis
            XCTAssertEqual(analysis.reusedCount, 0, "cut \(cut): a clean build has no reused tasks")
        }
    }
}

extension DegradedInputTests {
    // MARK: No timing at all (re-check N3)

    func testNoTimedTaskWithholdsTimingAndWarnsV1() throws {
        var w = SLFWriter()
        w.int(11)
        w.section("IDECommandLineBuildLog", cd: nil, start: 100, domain: Locator.buildLogDomain, omitStart: true,
                  children: { w in
                      w.section(cd: "SwiftCompile normal arm64 a.swift", start: 101, omitStart: true)
                      return 1
                  })
        let result = try report(RawLog.decoded(w.bytes))
        XCTAssertTrue(result.analysis.noTiming)
        let v1 = result.validation.status("V1")
        XCTAssertEqual(v1.label, "warn")
        XCTAssertTrue(v1.reason?.contains("no timed tasks") == true, "\(v1)")
        let build = result.document.build
        XCTAssertNil(build.span)
        XCTAssertNil(build.busy)
        XCTAssertNil(build.taskTime)
        XCTAssertNil(build.idle)
        XCTAssertTrue(build.notes.contains { $0.hasPrefix("timing numbers unavailable: no timing in the log") })
        XCTAssertEqual(build.tasksInModel, 1)
        XCTAssertFalse(result.validation.hasFailure)
    }

    func testTimedTasksKeepV1Passing() throws {
        let result = try report(RawLog.decoded(SLFWriter.log(duration: 5) { w in
            w.section(cd: "Ld b", start: 101)
            return 1
        }))
        XCTAssertEqual(result.validation.status("V1"), .pass)
        XCTAssertNotNil(result.document.build.span)
    }
}

extension RawLog {
    static func decoded(_ bytes: [UInt8]) -> RawLog { SLFDecoder.decode(bytes: bytes) }
}

extension DegradedInputTests {
    // MARK: Extreme but finite times (code review v0.2 #1)

    func testTaskEndingAt1e300IsInvalidAndNothingTraps() throws {
        let model = TestModels.model([TestModels.task(0, start: 101, end: 102),
                                      TestModels.task(1, start: 103, end: 1e300)])
        let result = try ReportPipeline.run(model, options: .init(generatedAt: Self.date, inputPath: "crafted"))
        XCTAssertEqual(result.document.build.tasksInvalid, 1)
        XCTAssertEqual(result.validation.status("V1").label, "warn")
        XCTAssertTrue(result.validation.status("V1").reason?.contains("beyond ±1e12 s") == true)
        XCTAssertFalse(result.validation.hasFailure, "exit stays 0")
        // Re-check R2: what the bound dropped degrades the report, like NaN or inf times.
        XCTAssertTrue(result.document.degraded)
        XCTAssertEqual(result.document.degradations.map(\.kind), ["invalidTiming"])
        XCTAssertTrue(TextReporter.render(result.document).contains("invalidTiming: 1 task(s) with times beyond ±1e12 s"))
        XCTAssertEqual(History.taskIndexRows(result.document, model).map(\.durationMs), [1000])
        let dir = try makeScratchDirectory()
        _ = try History.save(document: result.document, model: model, directory: dir.appendingPathComponent("history"))
        let index = TaskIndex.make(model: model, analysis: result.analysis, document: result.document)
        XCTAssertEqual(index.dur, [1000])
        _ = try HTMLReporter.render(result.document, taskIndex: index, options: .init(redact: false, title: "t"))
        _ = TextReporter.render(result.document)
    }

    func testSessionSpanOverflowingToInfinityDoesNotTrap() throws {
        let model = TestModels.model([TestModels.task(0, start: 101, end: 102)], start: -1.7e308, end: 1.7e308)
        let result = try ReportPipeline.run(model, options: .init(generatedAt: Self.date, inputPath: "crafted"))
        XCTAssertEqual(result.document.build.span, 1, "window derived from the tasks")
        XCTAssertEqual(result.validation.status("V1").label, "warn")
        let index = TaskIndex.make(model: model, analysis: result.analysis, document: result.document)
        _ = try HTMLReporter.render(result.document, taskIndex: index, options: .init(redact: false, title: "t"))
        _ = TextReporter.render(result.document)
        XCTAssertTrue(Utilization.compute(intervals: [], span: .infinity, peak: 0, physicalCores: nil).lanes.isEmpty)
    }

    func testMillisNeverTraps() {
        XCTAssertEqual(Timing.millis(1.2345), 1235)
        XCTAssertEqual(Timing.millis(.nan), 0)
        XCTAssertEqual(Timing.millis(.infinity), 9_007_199_254_740_992)
        XCTAssertEqual(Timing.millis(-1e300), -9_007_199_254_740_992)
    }
}
