import XCTest
@testable import XcblameKit

/// V15 (docs/SCHEMA-v0.5.md "V15"): Σ causes task time == executed task time, on every fixture.
final class V15Tests: XCTestCase {
    func testEvaluate() {
        XCTAssertEqual(V15.evaluate(sumOfCauses: 10, executedSeconds: 10.0009).status, "pass")
        XCTAssertEqual(V15.evaluate(sumOfCauses: 10, executedSeconds: 10.002).status, "fail")
        XCTAssertEqual(V15.evaluate(sumOfCauses: nil, executedSeconds: 1).status, "skipped")
        XCTAssertEqual(V15.evaluate(sumOfCauses: 1, executedSeconds: nil).status, "skipped")
    }

    func testValidatorRow() throws {
        XCTAssertEqual(Validator.checkV15(nil, executedSeconds: 1).status, .notApplicable)
        let sample = V05Samples.incremental
        XCTAssertEqual(Validator.checkV15(sample, executedSeconds: 1.5).status, .pass)
        XCTAssertTrue(Validator.checkV15(sample, executedSeconds: 2).status.isFail)
        XCTAssertEqual(Validator.checkV15(sample, executedSeconds: nil).status, .pass, "falls back to v15.executedSeconds")

        // A failed partition degrades the report like any failed check (§6.11).
        var broken = sample
        broken.causes[0].seconds = 99
        let document = try syntheticReport().applying(incremental: broken)
        XCTAssertEqual(document.validation.checks.first { $0.id == "V15" }?.status, "fail")
        XCTAssertTrue(document.degraded)
        XCTAssertTrue(document.degradations.contains { $0.detail.hasPrefix("V15:") })
    }

    func testV15HoldsOnEveryFixture() throws {
        for set in WhyFixtures.all {
            let history = try WhyFixtures.history([set.clean], test: self)
            for log in [set.clean, set.zeroChange, set.incremental] {
                let (model, document) = try WhyFixtures.report(log)
                let attached = CauseEngine.attach(to: document, model: model, historyDir: history, project: nil)
                let row = try XCTUnwrap(attached.validation.checks.first { $0.id == "V15" })
                if document.build.kind == "clean" {
                    XCTAssertNil(attached.incremental, log.lastPathComponent)
                    XCTAssertEqual(row.status, "notApplicable", log.lastPathComponent)
                } else {
                    let incremental = try XCTUnwrap(attached.incremental, log.lastPathComponent)
                    XCTAssertEqual(incremental.v15.status, "pass", log.lastPathComponent)
                    XCTAssertEqual(row.status, "pass", log.lastPathComponent)
                    XCTAssertEqual(incremental.v15.executedSeconds, document.build.taskTime)
                }
            }
        }
    }
}
