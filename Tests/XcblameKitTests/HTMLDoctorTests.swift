import Foundation
import XCTest
@testable import XcblameKit

/// DESIGN §8.2.5 tier 1 on the `doctor` document (§8.2.4 doctor variant): parity, escaping, placeholders, size,
/// redaction, determinism. No browser.
final class HTMLDoctorTests: XCTestCase {
    private func render(_ doc: ReportDocument) throws -> (html: String, document: ReportDocument) {
        let rendered = try HTMLReporter.renderReport(doc, taskIndex: nil, options: .init(redact: false, title: "xcblame doctor"))
        return (String(decoding: rendered.data, as: UTF8.self), rendered.document)
    }

    func testDoctorBlobIsByteEqualToTheJSONReport() throws {
        let doc = HTMLSample.doctor(hostileStrings: false)
        let (html, shown) = try render(doc)
        XCTAssertEqual(shown, doc, "a doctor document has no V13 check to measure")
        XCTAssertEqual(try HTMLBlob.extract(html), try JSONReporter.renderString(doc))
        XCTAssertFalse(html.contains("\"taskIndex\""))
        XCTAssertNotNil(doc.project)
        XCTAssertNotNil(doc.doctor)
        XCTAssertFalse(doc.findings.isEmpty)
        XCTAssertEqual(Set(doc.ruleDocs.keys), Set(doc.findings.map(\.ruleId)))
    }

    func testHostileStringsInFindingsCannotEscapeTheBlob() throws {
        let doc = HTMLSample.doctor()
        let (html, _) = try render(doc)
        let blob = try HTMLBlob.extract(html)
        XCTAssertFalse(blob.lowercased().contains("</script"))
        XCTAssertFalse(blob.contains("<!--"))
        XCTAssertFalse(blob.contains("\u{2028}"))
        let back = try JSONReporter.decoder().decode(ReportDocument.self, from: Data(blob.utf8))
        XCTAssertEqual(back, doc)
        XCTAssertTrue(back.findings[0].title.hasSuffix(HTMLSample.hostile))
        XCTAssertEqual(back.doctor?.passed[0].detail, HTMLSample.hostile)
        XCTAssertEqual(html.components(separatedBy: "</script>").count - 1, 2)
        XCTAssertFalse(html.replacingOccurrences(of: blob, with: "").contains("{{"))
        XCTAssertTrue(html.contains("<title>xcblame doctor</title>"))
    }

    func testDoctorPageIsSmallDeterministicAndRedactable() throws {
        let doc = HTMLSample.doctor()
        let first = try render(doc).html
        XCTAssertEqual(first, try render(doc).html, "byte-identical renders")
        XCTAssertLessThan(first.utf8.count, 370_000, "template budget (300 KB) + 70 KB of data")
        let context = Redactor.Context(home: NSHomeDirectory(), user: NSUserName(), host: "sample-host",
                                       repoRoot: RulesFixtures.root.deletingLastPathComponent().deletingLastPathComponent().path)
        let redacted = try Redactor.redact(doc, context: context)
        XCTAssertTrue(redacted.redacted)
        let html = try render(redacted).html
        XCTAssertFalse(html.contains(NSHomeDirectory()), "no home path")
        XCTAssertFalse(html.contains(RulesFixtures.root.path), "no absolute fixture path")
        XCTAssertTrue(try HTMLBlob.extract(html).contains("$REPO/fixtures/projects/AcmeApp/AcmeApp.xcodeproj"))
    }

    func testTemplateCarriesTheDoctorVariant() {
        let template = ReportTemplate.html
        XCTAssertLessThanOrEqual(template.utf8.count, 300_000, "template budget")
        for marker in ["renderDoctorSummary", "doctor runs no build", "Copy xcblame command", "Copy the ",
                       "Not checked", "Did not apply", "Suppressed", "More about this rule", "Commit your changes first."] {
            XCTAssertTrue(template.contains(marker), marker)
        }
        XCTAssertFalse(template.contains("innerHTML"), "text only, never markup")
    }
}
