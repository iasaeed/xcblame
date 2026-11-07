import XCTest
@testable import XcblameKit

final class ReportersJSONTests: XCTestCase {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    private func result(_ model: BuildModel, path: String? = nil, topN: Int = 15) throws -> ReportPipeline.Result {
        try ReportPipeline.run(model, options: .init(topN: topN, generatedAt: Self.date, inputPath: path))
    }

    private func object(_ model: BuildModel, topN: Int = 15) throws -> [String: Any] {
        let data = try JSONReporter.render(try result(model, topN: topN).document)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testOutputIsByteEqualAcrossRuns() throws {
        let model = SyntheticModel.make()
        let first = try JSONReporter.render(try result(model).document)
        let second = try JSONReporter.render(try result(model).document)
        XCTAssertEqual(first, second)
    }

    func testKeysAreSortedAtEveryLevelWeCheck() throws {
        let text = try JSONReporter.renderString(try result(SyntheticModel.make()).document)
        let topLevel = text.split(separator: "\n").compactMap { line -> String? in
            guard line.hasPrefix("  \""), !line.hasPrefix("   ") else { return nil }
            return line.dropFirst(3).prefix { $0 != "\"" }.description
        }
        XCTAssertGreaterThan(topLevel.count, 10)
        XCTAssertEqual(topLevel, topLevel.sorted())
    }

    func testSchemaToolDateAndSlashes() throws {
        let doc = try result(SyntheticModel.make(), path: "/Users/me/DerivedData/Logs/Build/x.xcactivitylog").document
        let text = try JSONReporter.renderString(doc)
        XCTAssertEqual(doc.schemaVersion, "xcblame.report/1")
        XCTAssertTrue(text.contains("\"schemaVersion\" : \"xcblame.report/1\""))
        XCTAssertTrue(text.contains("\"generatedAt\" : \"2023-11-14T22:13:20Z\""))
        XCTAssertTrue(text.contains("/Users/me/DerivedData/Logs/Build/x.xcactivitylog"), "slashes must not be escaped")
        XCTAssertEqual(doc.tool.name, "xcblame")
    }

    func testRoundTripsThroughDecode() throws {
        let doc = try result(SyntheticModel.make()).document
        let decoded = try JSONReporter.decoder().decode(ReportDocument.self, from: try JSONReporter.render(doc))
        XCTAssertEqual(decoded, doc)
    }

    func testUnknownValuesAreNullWithANoteNeverZero() throws {
        let json = try object(SyntheticModel.make())
        // No build-description task and nothing reused: the kind is undecided (v0.2 classifies the rest).
        var undecided = SyntheticModel.make()
        undecided.tasks[0].ruleName = "CreateBuildRequest"
        let build = try XCTUnwrap(try object(undecided)["build"] as? [String: Any])
        XCTAssertTrue(build["kind"] is NSNull)
        XCTAssertTrue((build["notes"] as? [String] ?? []).contains { $0.hasPrefix("kind:") })
        XCTAssertTrue(json["environment"] is NSNull)
        // A model with no version evidence at all: null with a note.
        var blind = SyntheticModel.make()
        blind.formatVersion = nil
        let xcode = try XCTUnwrap(try object(blind)["xcode"] as? [String: Any])
        XCTAssertTrue(xcode["value"] is NSNull)
        XCTAssertTrue(xcode["source"] is NSNull)
        XCTAssertEqual(xcode["evidence"] as? [String], [])
        XCTAssertFalse((xcode["notes"] as? [String] ?? []).isEmpty)
    }

    func testXcodeIsInferredWithEvidenceAndEnvironmentIsEmbedded() throws {
        var env = EnvSnapshot()
        env.macOSProductVersion = "26.0"
        let doc = try ReportPipeline.run(SyntheticModel.make(), options: .init(
            generatedAt: Self.date, environment: env)).document
        XCTAssertEqual(doc.xcode.value, "26.0")
        XCTAssertEqual(doc.xcode.source, "inferred")
        XCTAssertFalse(doc.xcode.evidence.isEmpty)
        XCTAssertEqual(doc.environment, env)
        XCTAssertTrue(doc.notes.contains { $0.hasPrefix("environment: captured") })
        let decoded = try JSONReporter.decoder().decode(ReportDocument.self, from: try JSONReporter.render(doc))
        XCTAssertEqual(decoded, doc)
    }

    func testEmptyBuildHasNullSharesAndAverageNotZero() throws {
        let json = try object(TestModels.model([]))
        let build = try XCTUnwrap(json["build"] as? [String: Any])
        let parallelism = try XCTUnwrap(build["parallelism"] as? [String: Any])
        XCTAssertTrue(parallelism["average"] is NSNull)
        XCTAssertTrue((build["notes"] as? [String] ?? []).contains { $0.contains("parallelism.average") })
        let kinds = try XCTUnwrap(json["kinds"] as? [[String: Any]])
        XCTAssertTrue(kinds.allSatisfy { $0["share"] is NSNull })
        let metrics = try XCTUnwrap(json["metrics"] as? [String: Any])
        XCTAssertTrue(metrics["cpuSeconds"] is NSNull)
        XCTAssertTrue(json["topTasksShownShare"] is NSNull)
    }

    func testCappedArraysCarryTotalAndShownShare() throws {
        let json = try object(SyntheticModel.make(), topN: 5)
        let top = try XCTUnwrap(json["topTasks"] as? [[String: Any]])
        XCTAssertEqual(top.count, 5)
        XCTAssertEqual(json["topTasksTotal"] as? Int, 50)
        let share = try XCTUnwrap(json["topTasksShownShare"] as? Double)
        XCTAssertTrue(share > 0 && share < 1)
        let targets = try XCTUnwrap(json["targets"] as? [[String: Any]])
        XCTAssertEqual(targets.count, 5)
        XCTAssertEqual(json["targetsTotal"] as? Int, 5)
        XCTAssertNotNil(json["targetsShownShare"] as? Double)
        let doc = try result(SyntheticModel.make(), topN: 2).document
        XCTAssertEqual(doc.targets?.count, 2)
        XCTAssertEqual(doc.targetsTotal, 5)
        XCTAssertLessThan(doc.targetsShownShare ?? 2, 1)
    }

    func testFailedV1WithholdsTimingNumbers() throws {
        var nan = TestModels.task(1, start: 100, end: 101)
        nan.duration = .nan
        let model = TestModels.model([TestModels.task(0, start: 100, end: 102), nan])
        let json = try object(model)
        let build = try XCTUnwrap(json["build"] as? [String: Any])
        XCTAssertTrue(build["taskTime"] is NSNull)
        XCTAssertTrue(build["span"] is NSNull)
        XCTAssertTrue((build["notes"] as? [String] ?? []).contains { $0.contains("withheld because V1 failed") })
        XCTAssertTrue(json["kinds"] is NSNull)
        XCTAssertTrue(json["topTasks"] is NSNull)
        XCTAssertTrue((json["notes"] as? [String] ?? []).contains { $0.contains("withheld") })
        let validation = try XCTUnwrap(json["validation"] as? [String: Any])
        let checks = try XCTUnwrap(validation["checks"] as? [[String: Any]])
        let v1 = try XCTUnwrap(checks.first { $0["id"] as? String == "V1" })
        XCTAssertEqual(v1["status"] as? String, "fail")
        XCTAssertNotNil(v1["detail"] as? String)
    }

    func testDegradationsAndDecodeWarningsAreListed() throws {
        var model = SyntheticModel.make()
        model.degradations = [Degradation(kind: .classification, detail: "9% unclassified")]
        model.decodeWarnings = [DecodeWarning(kind: .unknownClass, detail: "IDEFoo", offset: 42)]
        let doc = try result(model).document
        XCTAssertEqual(doc.degradations.map(\.kind), ["classification"])
        XCTAssertTrue(doc.validation.degraded)
        XCTAssertTrue(doc.degraded, "top-level convenience mirrors degradations")
        let json = try JSONSerialization.jsonObject(with: JSONReporter.render(doc)) as? [String: Any]
        XCTAssertEqual(json?["degraded"] as? Bool, true)
        let clean = try result(SyntheticModel.make()).document
        XCTAssertEqual(clean.degraded, !clean.degradations.isEmpty)
        XCTAssertEqual(doc.decodeWarnings.first?.offset, 42)
        XCTAssertEqual(doc.decodeWarningsTotal, 1)
    }

    func testKindsPartitionInTheDocument() throws {
        let doc = try result(SyntheticModel.make()).document
        let kinds = try XCTUnwrap(doc.kinds)
        XCTAssertEqual(kinds.reduce(0) { $0 + $1.taskTime }, doc.build.taskTime ?? -1, accuracy: 1e-4)
        XCTAssertEqual(kinds.reduce(0) { $0 + $1.tasks }, doc.build.tasks)
        XCTAssertTrue(kinds.contains { $0.isOther })
    }

    func testV13BudgetFailureAppearsInTheReport() throws {
        let doc = try ReportPipeline.run(SyntheticModel.make(),
                                         options: .init(budgetBytes: 100, generatedAt: Self.date)).document
        XCTAssertEqual(doc.validation.checks.first { $0.id == "V13" }?.status, "fail")
    }
}
