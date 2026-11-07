import XCTest
@testable import XcblameKit

/// `verify --format html` and `fix --format html` (docs/SCHEMA-v0.6.md "HTML"): the template with the document's JSON,
/// byte-equal to `--format json` apart from the script-data escapes; the page dispatches on the schema kind. The DOM
/// is checked in headless Chrome by `HTMLClarityTests.testVerifyPage` / `testFixPlanPage`.
final class HTMLVerifyTests: XCTestCase {
    private func blob(_ html: Data) throws -> String { try HTMLBlob.extract(String(decoding: html, as: UTF8.self)) }

    func testVerifyPageEmbedsTheJSONOutput() throws {
        var doc = FixVerifySamples.verify()
        doc.notes.append("hostile </script><!-- note")
        let html = try HTMLReporter.renderVerify(doc, options: .init(redact: false, title: "xcblame verify"))
        let json = String(decoding: try JSONReporter.render(doc), as: UTF8.self)
        XCTAssertEqual(try blob(html), HTMLReporter.escapeScriptData(json))
        XCTAssertNotEqual(try blob(html), json, "the hostile note needed escaping")
        XCTAssertEqual(try JSONReporter.decoder().decode(VerifyDocument.self, from: Data(try blob(html).utf8)), doc)
        let page = String(decoding: html, as: UTF8.self)
        XCTAssertTrue(page.contains("<title>xcblame verify</title>"))
        XCTAssertFalse(page.contains(HTMLReporter.dataPlaceholder))
        XCTAssertEqual(html, try HTMLReporter.renderVerify(doc, options: .init(redact: false, title: "xcblame verify")), "deterministic")
    }

    func testFixPlanPageEmbedsTheJSONOutput() throws {
        let doc = FixVerifySamples.plan
        let html = try HTMLReporter.renderFixPlan(doc, options: .init(redact: false, title: "xcblame fix plan"))
        XCTAssertEqual(try blob(html), HTMLReporter.escapeScriptData(String(decoding: try JSONReporter.render(doc), as: UTF8.self)))
        XCTAssertEqual(try JSONReporter.decoder().decode(FixPlanDocument.self, from: Data(try blob(html).utf8)), doc)
    }

    func testRedactedPagesCarryNoHomePath() throws {
        let context = Redactor.Context(home: "/Users/sam", user: "sam", host: "sams-mac")
        let verify = try Redactor.redact(FixVerifySamples.verify(), context: context)
        let plan = try Redactor.redact(FixVerifySamples.plan, context: context)
        XCTAssertFalse(try blob(try HTMLReporter.renderVerify(verify, options: .init(redact: true, title: ""))).contains("/Users/sam"))
        XCTAssertFalse(try blob(try HTMLReporter.renderFixPlan(plan, options: .init(redact: true, title: ""))).contains("/Users/sam"))
    }

    func testTemplateCarriesTheV06ContractAndNoLongerLabelsVerifyAndFix() {
        let html = ReportTemplate.html
        for needle in ["<section id=\"verify\"", "<section id=\"fixplan\"", "'xcblame.verify': ['verify'", "'xcblame.fixplan': ['fixplan'",
                       "id: 'verify-start'", "id: 'verify-abort'", "'verify-results'", "class: 'verify-run', 'data-arm'",
                       "'data-verdict'", "'data-reason'", "'data-state'", "'data-verify'", "'fixplan-commands'"] {
            XCTAssertTrue(html.contains(needle), needle)
        }
        XCTAssertFalse(html.contains("available in xcblame 0.6"))
        XCTAssertTrue(html.contains("function isFuture(cmd) { return /--edit-project/.test(cmd); }"), "only --edit-project is a future command")
        XCTAssertFalse(html.contains("innerHTML"), "text only")
    }

    func testDoctorPlanMakesVerifyAndFixPlainCommands() {
        XCTAssertFalse(ReportDocument.isFutureCommand("xcblame verify --rules SET-016 --kind clean --mechanism hook"))
        XCTAssertFalse(ReportDocument.isFutureCommand("xcblame fix --rules SET-016 --apply"))
        XCTAssertTrue(ReportDocument.isFutureCommand("xcblame fix --rules SET-001 --edit-project"))
        XCTAssertEqual(ReportDocument.futureNote, "not available yet: make the change by hand")
    }
}
