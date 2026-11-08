import XCTest
@testable import XcblameKit

/// `xcblame schema` (docs/SCHEMA-v0.4.md "JSON Schema"): the four documents are encoded for real and validated against
/// the generated schema by `MiniSchemaValidator`, in strict mode, so a member the mirror table forgot fails here.
final class SchemaTests: XCTestCase {
    private func schema(_ document: JSONSchema.Document) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try JSONSchema.render(document).utf8)) as? [String: Any])
    }

    private func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: try JSONReporter.encoder().encode(value))
    }

    private func assertValid(_ value: Any, _ document: JSONSchema.Document, _ label: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let problems = MiniSchemaValidator(root: try schema(document)).errors(value)
        XCTAssertEqual(problems, [], label, file: file, line: line)
    }

    // MARK: Samples

    private func syntheticReport() throws -> ReportDocument {
        try ReportPipeline.run(SyntheticModel.make(), options: .init(generatedAt: V04Samples.date)).document
    }

    func testReportDocumentsValidateAgainstTheReportSchema() throws {
        try assertValid(try json(try syntheticReport()), .report, "pipeline report (nulls)")
        let populated = try FormatsFixtures.report()
        try assertValid(try json(populated), .report, "populated report with regression and git")
        try assertValid(try json(FormatsFixtures.doctor()), .report, "doctor report")
        var unevaluated = populated
        unevaluated.regression = nil
        unevaluated.environment = nil
        try assertValid(try json(unevaluated), .report, "report without regression or environment")
        var compared = populated
        compared.previous = .init(span: 16.2, kind: "clean", generatedAt: V04Samples.date, id: "20231114-221320-clean")
        try assertValid(try json(compared), .report, "report with a previous build (D1)")
    }

    func testHTMLTaskIndexIsDocumentedAndOptional() throws {
        let (document, index) = try HTMLSample.populated()
        var tree = try XCTUnwrap(try json(document) as? [String: Any])
        try assertValid(tree, .report, "no task index")
        tree["taskIndex"] = try json(index)
        try assertValid(tree, .report, "with task index")
        let properties = try XCTUnwrap(try schema(.report)["properties"] as? [String: Any])
        XCTAssertNotNil(properties["taskIndex"])
        XCTAssertFalse((try schema(.report)["required"] as? [String] ?? []).contains("taskIndex"))
    }

    func testCompareTrendAndBaselineSamplesValidate() throws {
        try assertValid(try json(V04Samples.compare), .compare, "compare sample")
        var rich = V04Samples.compare
        let pair = CompareDocument.Pair(a: 1, b: 2, delta: 1, deltaPct: 1)
        rich.targets = [.init(key: "App", status: "changed", seconds: pair, tasks: pair, isOther: false),
                        .init(key: "other", status: "same", seconds: pair, tasks: nil, isOther: true)]
        rich.targetsTotal = 2
        rich.targetsShownShare = 1
        rich.tasks = .init(available: true, added: [.init(rule: "SwiftCompile", target: nil, kind: "swiftCompile", seconds: 1, onPath: true)],
                           addedTotal: 1, addedShownShare: 1, removed: [], removedTotal: 0, removedShownShare: nil, notes: [])
        rich.settings = [.init(ref: "App:Debug:K", a: "1", b: nil, provenanceA: "pbxproj", provenanceB: nil)]
        rich.a.git = GitInfo(branch: "main", commit: String(repeating: "b", count: 40), dirty: false, remoteHost: "github.com")
        rich.criticalPath = nil
        try assertValid(try json(rich), .compare, "compare with rows")
        var withIndex = try XCTUnwrap(try json(rich) as? [String: Any])
        withIndex["taskIndexA"] = try json(try HTMLSample.populated().1)
        try assertValid(withIndex, .compare, "compare with taskIndexA")

        try assertValid(try json(V04Samples.trend), .trend, "trend sample")
        var trend = V04Samples.trend
        trend.filter = .init(kind: nil, scheme: "App", since: V04Samples.date, by: nil)
        trend.groups = [.init(key: nil, entries: 1, series: [.init(
            kind: "clean", points: [.init(id: "x", time: nil, wall: nil, busy: nil, xcode: nil, commit: nil, branch: nil, machine: nil)],
            wall: .init(n: 0, p50: nil, p75: nil, p95: nil), busy: .init(n: 0, p50: nil, p75: nil, p95: nil),
            xcodeChangeMarkers: [.init(atId: "x", from: "26.0", to: "26.1", time: V04Samples.date)])])]
        try assertValid(try json(trend), .trend, "trend with nulls")

        try assertValid(try json(V04Samples.baseline), .baseline, "baseline sample")
        var baseline = V04Samples.baseline
        baseline.git = nil
        baseline.tasks = nil
        baseline.machine = nil
        baseline.wall = .init(median: nil, mad: nil)
        try assertValid(try json(baseline), .baseline, "baseline with nulls")
    }

    func testEveryDocumentIsRejectedByTheOtherSchemas() throws {
        let samples: [(JSONSchema.Document, Any)] = [
            (.report, try json(try syntheticReport())), (.compare, try json(V04Samples.compare)),
            (.trend, try json(V04Samples.trend)), (.baseline, try json(V04Samples.baseline)),
        ]
        for (name, sample) in samples {
            for (other, _) in samples where other != name {
                XCTAssertFalse(MiniSchemaValidator(root: try schema(other)).errors(sample).isEmpty, "\(name) vs \(other)")
            }
        }
    }

    func testTheValidatorCatchesTypeEnumRequiredAndForgottenMembers() throws {
        var tree = try XCTUnwrap(try json(V04Samples.baseline) as? [String: Any])
        let validator = MiniSchemaValidator(root: try schema(.baseline))
        XCTAssertEqual(validator.errors(tree), [])
        var bad = tree
        bad["wallBasis"] = "median"
        XCTAssertFalse(validator.errors(bad).isEmpty, "enum")
        bad = tree
        bad["runs"] = "5"
        XCTAssertFalse(validator.errors(bad).isEmpty, "type")
        bad = tree
        bad["savedAt"] = "yesterday"
        XCTAssertFalse(validator.errors(bad).isEmpty, "date-time")
        bad = tree
        bad["wall"] = nil
        XCTAssertFalse(validator.errors(bad).isEmpty, "required")
        bad = tree
        bad["schemaVersion"] = "xcblame.baseline/2"
        XCTAssertFalse(validator.errors(bad).isEmpty, "const")
        tree["extra"] = 1
        XCTAssertFalse(validator.errors(tree).isEmpty, "a member the table forgot")
        XCTAssertEqual(MiniSchemaValidator(root: try schema(.baseline), strict: false).errors(tree), [], "additive members stay legal")
    }

    // MARK: Shape

    func testRootKeysIdsAndRequired() throws {
        let report = try schema(.report)
        XCTAssertEqual(report["$schema"] as? String, JSONSchema.dialect)
        XCTAssertEqual(report["$id"] as? String, "urn:xcblame:schema:report:1")
        XCTAssertEqual(report["type"] as? String, "object")
        XCTAssertEqual(report["additionalProperties"] as? Bool, true)
        let properties = try XCTUnwrap(report["properties"] as? [String: Any])
        let version = try XCTUnwrap(properties["schemaVersion"] as? [String: Any])
        XCTAssertEqual(version["const"] as? String, "xcblame.report/1")
        // Every always-serialized member is required; a nullable one admits null.
        let required = try XCTUnwrap(report["required"] as? [String])
        for key in ["regression", "diagnostics", "diagnosticsTotal", "diagnosticsShownShare", "project", "doctor", "fixPlan", "environment"] {
            XCTAssertTrue(required.contains(key), key)
        }
        let regression = try XCTUnwrap(properties["regression"] as? [String: Any])
        XCTAssertNotNil(regression["anyOf"])
        let build = try XCTUnwrap((report["$defs"] as? [String: Any])?["Build"] as? [String: Any])
        let scheme = try XCTUnwrap((build["properties"] as? [String: Any])?["scheme"] as? [String: Any])
        XCTAssertEqual(scheme["type"] as? [String], ["string", "null"])
        XCTAssertEqual(try schema(.compare)["$id"] as? String, "urn:xcblame:schema:compare:1")
        XCTAssertEqual(try schema(.trend)["$id"] as? String, "urn:xcblame:schema:trend:1")
        XCTAssertEqual(try schema(.baseline)["$id"] as? String, "urn:xcblame:schema:baseline:1")
    }

    func testClosedEnumsAreListedAndOpenVocabulariesAreNot() throws {
        func member(_ document: JSONSchema.Document, _ def: String, _ key: String) throws -> [String: Any] {
            let defs = try XCTUnwrap(try schema(document)["$defs"] as? [String: Any])
            let object = try XCTUnwrap(defs[def] as? [String: Any])
            return try XCTUnwrap((object["properties"] as? [String: Any])?[key] as? [String: Any])
        }
        XCTAssertEqual(try member(.report, "Regression", "verdict")["enum"] as? [String], ["faster", "slower", "same", "indicative"])
        XCTAssertEqual(try member(.report, "Regression", "wallBasis")["enum"] as? [String], ["processWall", "span"])
        XCTAssertEqual(try member(.report, "DiagnosticEntry", "severity")["enum"] as? [String], ["error", "warning"])
        XCTAssertEqual(try member(.compare, "CompareRow", "status")["enum"] as? [String], ["changed", "same", "added", "removed"])
        XCTAssertEqual((try member(.trend, "TrendFilter", "by")["enum"] as? [Any])?.count, 5, "four values and null")
        XCTAssertNil(try member(.report, "Build", "kind")["enum"])
        XCTAssertNil(try member(.report, "Finding", "ruleId")["enum"])
    }

    func testEveryCappedArrayHasTotalAndShownShare() throws {
        // `findings`, `decodeWarnings` and `tasksWithoutTiming` have a total since v0.2 and never had a share; a verify
        // arm's `runs` is never cut (`runsTotal` is `runs.count`, v0.6).
        let withoutShare: Set<String> = ["findings", "decodeWarnings", "tasksWithoutTiming", "runs"]
        var tables: [[SchemaField]] = [SchemaTable.reportFields, SchemaTable.compareFields]
        tables += SchemaTable.objects.values
        var checked = 0
        for fields in tables {
            let keys = Set(fields.map(\.key))
            for field in fields {
                guard case .array = field.type, keys.contains(field.key + "Total") else { continue }
                checked += 1
                if withoutShare.contains(field.key) { continue }
                XCTAssertTrue(keys.contains(field.key + "ShownShare"), "\(field.key) needs \(field.key)ShownShare")
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 12)
    }

    func testAllHasEveryDefAndOneOfAndRefsResolve() throws {
        let all = try schema(.all)
        let defs = try XCTUnwrap(all["$defs"] as? [String: Any])
        XCTAssertEqual(defs.keys.sorted(), ["baseline", "compare", "fixplan", "report", "trend", "verify"])
        XCTAssertEqual((all["oneOf"] as? [[String: String]])?.map { $0["$ref"] },
                       ["#/$defs/report", "#/$defs/compare", "#/$defs/trend", "#/$defs/baseline", "#/$defs/fixplan", "#/$defs/verify"])
        XCTAssertNil((defs["report"] as? [String: Any])?["$id"], "each def is $id-less")
        let validator = MiniSchemaValidator(root: all)
        XCTAssertEqual(validator.errors(try json(try syntheticReport())), [], "a report matches exactly one of the six")
        XCTAssertEqual(validator.errors(try json(V04Samples.compare)), [])
        XCTAssertEqual(validator.errors(try json(V04Samples.trend)), [])
        XCTAssertEqual(validator.errors(try json(V04Samples.baseline)), [])
        XCTAssertFalse(validator.errors(["schemaVersion": "nope"]).isEmpty)
    }

    func testRenderIsSortedPrettyDeterministicAndEndsInOneNewline() throws {
        for document in JSONSchema.Document.allCases {
            let text = try JSONSchema.render(document)
            XCTAssertEqual(text, try JSONSchema.render(document), "\(document) is byte-equal across runs")
            XCTAssertTrue(text.hasSuffix("}\n"))
            XCTAssertTrue(text.contains("\n  \""), "pretty printed")
            XCTAssertFalse(text.contains("\\/"), "slashes are not escaped")
        }
        let text = try JSONSchema.render(.baseline)
        let order = ["\"$defs\"", "\"$id\"", "\"$schema\"", "\"additionalProperties\"", "\"properties\"", "\"required\"", "\"title\"", "\"type\""]
        let positions = order.compactMap { text.range(of: "\n  " + $0)?.lowerBound }
        XCTAssertEqual(positions.count, order.count)
        XCTAssertEqual(positions, positions.sorted(), "top-level keys sorted")
    }

    func testUnknownVersionIsAUsageErrorListingTheKnownOnes() {
        XCTAssertThrowsError(try JSONSchema.render(.report, version: 2)) { error in
            guard case let XcblameError.usage(message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("known: 1"), message)
        }
    }
}
