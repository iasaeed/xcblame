import XCTest
@testable import XcblameKit

/// `xcblame schema --document fixplan|verify` (docs/SCHEMA-v0.6.md, Decision 21): the contract samples and lane C's
/// samples validate in strict mode, closed vocabularies are enums, and the documents reject each other.
final class FixVerifySchemaTests: XCTestCase {
    private func schema(_ document: JSONSchema.Document) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try JSONSchema.render(document).utf8)) as? [String: Any])
    }

    private func json<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: try JSONReporter.encoder().encode(value))
    }

    private func errors(_ value: Any, _ document: JSONSchema.Document) throws -> [String] {
        MiniSchemaValidator(root: try schema(document)).errors(value)
    }

    func testSamplesValidateInStrictMode() throws {
        XCTAssertEqual(try errors(try json(V06Samples.plan), .fixplan), [], "contract plan")
        XCTAssertEqual(try errors(try json(V06Samples.verify), .verify), [], "contract verify")
        XCTAssertEqual(try errors(try json(FixVerifySamples.plan), .fixplan), [], "plan with every mechanism")
        for (label, sample) in [("verify", FixVerifySamples.verify()), ("aborted", FixVerifySamples.aborted),
                                ("indicative", FixVerifySamples.indicative)] {
            XCTAssertEqual(try errors(try json(sample), .verify), [], label)
            XCTAssertEqual(try errors(try json(sample), .all), [], "\(label) in all")
        }
        XCTAssertEqual(try errors(try json(FixVerifySamples.plan), .all), [], "plan in all")
    }

    func testClosedVocabulariesAreEnums() throws {
        func member(_ document: JSONSchema.Document, _ def: String, _ key: String) throws -> [Any] {
            let defs = try XCTUnwrap(try schema(document)["$defs"] as? [String: Any])
            let object = try XCTUnwrap(defs[def] as? [String: Any], def)
            let property = try XCTUnwrap((object["properties"] as? [String: Any])?[key] as? [String: Any], key)
            return try XCTUnwrap(property["enum"] as? [Any], "\(def).\(key) is an enum")
        }
        XCTAssertEqual(try member(.fixplan, "PlanStep", "fixKind") as? [String],
                       ["overlay", "cli", "defaults", "scheme", "project", "manifest", "recommend", "measure"])
        XCTAssertEqual(try member(.fixplan, "PlanStep", "mechanism") as? [String], ["hook", "cli", "defaults", "recommend"])
        XCTAssertEqual(try member(.fixplan, "PlanStep", "state") as? [String], ["planned", "applied", "applied-cli", "reverted", "skipped"])
        XCTAssertEqual(try member(.fixplan, "VerifyState", "status") as? [String], ["unverified", "kept", "reverted", "indicative"])
        XCTAssertEqual(try member(.fixplan, "VerifyState", "reason").count, 6, "five reasons and null")
        XCTAssertEqual(try member(.fixplan, "PlanGuard", "id") as? [String], ["commitFirst", "hookInstalled", "prerequisite", "verifyFirst", "cleanTree"])
        XCTAssertEqual(try member(.fixplan, "PlanHook", "status") as? [String], ["installed", "notInstalled", "unavailable", "generated"])
        XCTAssertEqual(try member(.fixplan, "PlanEvent", "action") as? [String], ["apply", "applyDefaults", "revert", "installHook", "uninstallHook"])
        XCTAssertEqual(try member(.verify, "VerifyAbort", "reason") as? [String],
                       ["dirtyTree", "onBattery", "xcodebuildRunning", "thermal", "timeout", "baselineBroken", "interrupted", "hookMissing"])
        XCTAssertEqual(try member(.verify, "VerifyCheck", "name") as? [String], ["exitCode", "targetSet", "taskKinds", "thermal", "oracle"])
        XCTAssertEqual(try member(.verify, "VerifyPrecondition", "name") as? [String], ["cleanTree", "power", "thermal", "otherBuild", "hook"])
        XCTAssertEqual(try member(.verify, "VerifyArm", "arm") as? [String], ["A", "B"])
        let kind = try XCTUnwrap((try schema(.verify)["properties"] as? [String: Any])?["kind"] as? [String: Any])
        XCTAssertEqual(kind["enum"] as? [String], ["clean", "incremental", "zero-change"])
    }

    func testTheValidatorCatchesBadValuesAndForgottenMembers() throws {
        let tree = try XCTUnwrap(try json(FixVerifySamples.verify()) as? [String: Any])
        var bad = tree
        bad["kind"] = "warm"
        XCTAssertFalse(try errors(bad, .verify).isEmpty, "enum")
        bad = tree
        bad["extra"] = true
        XCTAssertFalse(try errors(bad, .verify).isEmpty, "a member the table forgot")
        var plan = try XCTUnwrap(try json(FixVerifySamples.plan) as? [String: Any])
        var steps = try XCTUnwrap(plan["steps"] as? [[String: Any]])
        steps[0]["mechanism"] = "pbxproj"
        plan["steps"] = steps
        XCTAssertFalse(try errors(plan, .fixplan).isEmpty, "mechanism enum")
    }

    func testDocumentsRejectEachOtherAndAllHasSixDefs() throws {
        XCTAssertFalse(try errors(try json(FixVerifySamples.plan), .verify).isEmpty)
        XCTAssertFalse(try errors(try json(FixVerifySamples.verify()), .fixplan).isEmpty)
        XCTAssertFalse(try errors(try json(FixVerifySamples.plan), .report).isEmpty)
        XCTAssertFalse(try errors(try json(V04Samples.trend), .verify).isEmpty)
        let defs = try XCTUnwrap(try schema(.all)["$defs"] as? [String: Any])
        XCTAssertEqual(defs.keys.sorted(), ["baseline", "compare", "fixplan", "report", "trend", "verify"])
        XCTAssertEqual(try schema(.fixplan)["$id"] as? String, "urn:xcblame:schema:fixplan:1")
        XCTAssertEqual(try schema(.verify)["$id"] as? String, "urn:xcblame:schema:verify:1")
        XCTAssertTrue(Set(SchemaTable.baseObjects.keys).isDisjoint(with: SchemaTable.fixVerifyObjects.keys),
                      "a v0.6 definition never shadows a report definition")
    }
}
