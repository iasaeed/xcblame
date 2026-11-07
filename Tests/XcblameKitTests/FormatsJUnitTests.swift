import XCTest
@testable import XcblameKit

/// `--format junit` (docs/SCHEMA-v0.4.md "junit"): well-formed XML, one testcase per budget, counts that add up.
final class FormatsJUnitTests: XCTestCase {
    /// Elements in document order with their attributes and text, through `XMLParser` (so the XML must be well-formed).
    private final class Collector: NSObject, XMLParserDelegate {
        struct Element { var name: String; var attributes: [String: String]; var text = ""; var depth: Int }
        var elements: [Element] = []
        private var open: [Int] = []
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            elements.append(Element(name: name, attributes: attributes, depth: open.count + 1))
            open.append(elements.count - 1)
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if let index = open.last { elements[index].text += string }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) { open.removeLast() }
    }

    private func parse(_ xml: String, file: StaticString = #filePath, line: UInt = #line) throws -> [Collector.Element] {
        let parser = XMLParser(data: Data(xml.utf8))
        let collector = Collector()
        parser.delegate = collector
        XCTAssertTrue(parser.parse(), "\(String(describing: parser.parserError)) in\n\(xml)", file: file, line: line)
        return collector.elements
    }

    private func config(_ json: String) throws -> FormatOptions {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-junit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        try Data(json.utf8).write(to: url)
        return FormatOptions(maxBytes: .max, configURL: url)
    }

    private func cases(_ xml: String) throws -> [Collector.Element] { try parse(xml).filter { $0.name == "testcase" } }

    func testWithoutConfigOrRegressionTheSuiteHoldsTheValidationCaseOnly() throws {
        var document = try FormatsFixtures.report(regression: nil)
        document.build.kind = "clean"
        document.timing.processWall = nil
        document.build.span = 19
        let xml = try JUnitReporter.render(document, options: FormatOptions(maxBytes: .max))
        let elements = try parse(xml)
        XCTAssertEqual(elements.map(\.name), ["testsuites", "testsuite", "properties"] + Array(repeating: "property", count: 8) + ["testcase"])
        let suites = elements[0]
        XCTAssertEqual(suites.attributes["name"], "xcblame")
        XCTAssertEqual(suites.attributes["tests"], "1")
        XCTAssertEqual(suites.attributes["failures"], "0")
        XCTAssertEqual(suites.attributes["errors"], "0")
        XCTAssertEqual(suites.attributes["skipped"], "0")
        XCTAssertEqual(suites.attributes["time"], "19.000", "the wall")
        let suite = elements[1]
        XCTAssertEqual(suite.attributes["timestamp"], "2023-11-14T22:13:20Z")
        XCTAssertEqual(suite.attributes["tests"], "1")
        XCTAssertEqual(elements.last?.attributes, ["classname": "xcblame.build", "name": "validation", "time": "0.000"])
        let properties = Dictionary(uniqueKeysWithValues: elements.filter { $0.name == "property" }.map { ($0.attributes["name"]!, $0.attributes["value"]!) })
        XCTAssertEqual(properties["kind"], "clean")
        XCTAssertEqual(properties["scheme"], "App")
        XCTAssertEqual(properties["xcode"], "26.0")
        XCTAssertEqual(properties["branch"], "ann/fix")
        XCTAssertEqual(properties["commit"], String(repeating: "a", count: 40))
        XCTAssertTrue(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<testsuites "))
        XCTAssertTrue(xml.hasSuffix("</testsuites>\n"))
    }

    func testBudgetsFromConfigBecomeTestcasesWithMessageAndSeconds() throws {
        let options = try config(#"{"budgets": {"wall": 15, "criticalPath": 100, "targets": {"App": 10, "CoreKit": 100, "Missing": 5}}}"#)
        let document = try FormatsFixtures.report()
        let xml = try JUnitReporter.render(document, options: options)
        let found = try cases(xml)
        XCTAssertEqual(found.map { ($0.attributes["classname"]!, $0.attributes["name"]!) }.map { "\($0.0) / \($0.1)" }, [
            "xcblame.build / validation", "xcblame.budget / wall", "xcblame.budget / criticalPath", "xcblame.budget / target:App",
            "xcblame.budget / target:CoreKit", "xcblame.budget / target:Missing", "xcblame.regression / wall",
        ])
        let suite = try XCTUnwrap(try parse(xml).first { $0.name == "testsuite" })
        XCTAssertEqual(suite.attributes["tests"], "7")
        XCTAssertEqual(suite.attributes["failures"], "3", "wall, App and the regression")
        XCTAssertEqual(suite.attributes["skipped"], "1", "Missing is not in the document")
        let failures = try parse(xml).filter { $0.name == "failure" }
        XCTAssertEqual(failures.map { $0.attributes["type"]! }, ["BudgetExceeded", "BudgetExceeded", "Regression"])
        XCTAssertEqual(failures[0].attributes["message"], "wall 19.00 s exceeds budget 15.00 s")
        XCTAssertEqual(failures[0].text, "wall: 19.00 s (budget 15.00 s)")
        XCTAssertEqual(failures[1].attributes["message"], "target App task time 42.75 s exceeds budget 10.00 s")
        XCTAssertEqual(failures[2].attributes["message"], "slower than baseline by 5.6 % (threshold 5 %)")
        XCTAssertEqual(found[1].attributes["time"], "19.000")
        XCTAssertEqual(found[3].attributes["time"], "42.750")
        XCTAssertEqual(found[4].attributes["time"], "21.750")
        XCTAssertEqual(found[2].attributes["time"], String(format: "%.3f", document.criticalPath!.span))
        XCTAssertNotNil(try parse(xml).first { $0.name == "skipped" }?.attributes["message"])
    }

    func testIncrementalBudgetReplacesWallForAnIncrementalBuild() throws {
        let options = try config(#"{"budgets": {"wall": 100, "incremental": 5}}"#)
        var document = try FormatsFixtures.report(regression: nil)
        document.timing.processWall = nil
        document.build.span = 19
        document.build.kind = "incremental"
        let failures = try parse(try JUnitReporter.render(document, options: options)).filter { $0.name == "failure" }
        XCTAssertEqual(failures.first?.attributes["message"], "wall 19.00 s exceeds incremental budget 5.00 s")
        document.build.kind = "clean"
        XCTAssertTrue(try parse(try JUnitReporter.render(document, options: options)).filter { $0.name == "failure" }.isEmpty,
                      "the wall budget of 100 s applies to a clean build")
    }

    func testPassingBudgetsAndEqualityAreNotFailures() throws {
        let options = try config(#"{"budgets": {"wall": 19, "criticalPath": 1000}}"#)
        var document = try FormatsFixtures.report(regression: nil)
        document.timing.processWall = nil
        document.build.span = 19
        let xml = try JUnitReporter.render(document, options: options)
        XCTAssertTrue(try parse(xml).filter { $0.name == "failure" }.isEmpty, "strictly over fails; equal passes")
        XCTAssertEqual(try cases(xml).count, 3)
    }

    func testMissingMalformedAndMistypedConfigsMeanNoBudgets() throws {
        let document = try FormatsFixtures.report(regression: nil)
        for json in ["{", "[]", #"{"budgets": 5}"#, #"{"budgets": {"wall": "fast", "criticalPath": true, "targets": []}}"#, "{}"] {
            let xml = try JUnitReporter.render(document, options: try config(json))
            XCTAssertEqual(try cases(xml).count, 1, json)
        }
        let missing = FormatOptions(maxBytes: .max, configURL: URL(fileURLWithPath: "/nonexistent/xcblame/config.json"))
        XCTAssertEqual(try cases(try JUnitReporter.render(document, options: missing)).count, 1)
        let partial = try config(#"{"budgets": {"wall": "fast", "criticalPath": 5}}"#)
        XCTAssertEqual(try cases(try JUnitReporter.render(document, options: partial)).count, 2, "a good member survives a bad one")
        XCTAssertEqual(ConfigFile.budgets(in: try config(#"{"budgets": {"wall": 1, "incremental": 2, "criticalPath": 3, "targets": {"A": 4}}}"#).configURL),
                       JUnitReporter.Budgets(wall: 1, incremental: 2, criticalPath: 3, targets: ["A": 4]))
    }

    func testValidationFailuresAndDegradationFailTheValidationCase() throws {
        var document = try FormatsFixtures.report(regression: nil)
        document.validation.checks = [.init(id: "V3", title: "t", status: "fail", detail: "sum off by 2 <&> \"q\" 'a' \u{1}"),
                                      .init(id: "V9", title: "t", status: "pass", detail: nil)]
        var xml = try JUnitReporter.render(document, options: FormatOptions(maxBytes: .max))
        var failure = try XCTUnwrap(try parse(xml).first { $0.name == "failure" })
        XCTAssertEqual(failure.attributes["message"], "validation failed: V3")
        XCTAssertEqual(failure.attributes["type"], "ValidationFailed")
        XCTAssertEqual(failure.text, "V3 sum off by 2 <&> \"q\" 'a'", "the control character is stripped, the rest survives escaping")
        XCTAssertFalse(xml.contains("\u{1}"))
        XCTAssertTrue(xml.contains("&lt;&amp;&gt;"))

        document.validation.checks = []
        document.degraded = true
        document.degradations = [.init(kind: "truncated", detail: "log ends early")]
        xml = try JUnitReporter.render(document, options: FormatOptions(maxBytes: .max))
        failure = try XCTUnwrap(try parse(xml).first { $0.name == "failure" })
        XCTAssertEqual(failure.attributes["message"], "analysis degraded")
        XCTAssertEqual(failure.text, "truncated: log ends early")
    }

    func testTextIsEscapedAndNoHostNameAppears() throws {
        var document = try FormatsFixtures.report(regression: nil)
        document.build.scheme = "A&B <x> \"y\" 'z'"
        let xml = try JUnitReporter.render(document, options: FormatOptions(maxBytes: .max))
        let property = try XCTUnwrap(try parse(xml).first { $0.attributes["name"] == "scheme" })
        XCTAssertEqual(property.attributes["value"], "A&B <x> \"y\" 'z'")
        XCTAssertTrue(xml.contains("A&amp;B &lt;x&gt; &quot;y&quot; &apos;z&apos;"))
        XCTAssertFalse(xml.contains(ProcessInfo.processInfo.hostName))
        XCTAssertEqual(JUnitReporter.xml("a\u{0}b\u{8}c\u{FFFE}d\u{1F600}e\tf\ng"), "abcd\u{1F600}e\tf\ng")
    }

    func testDoctorDocumentAndDeterminism() throws {
        let document = FormatsFixtures.doctor()
        let xml = try JUnitReporter.render(document, options: FormatOptions(maxBytes: .max))
        XCTAssertEqual(try cases(xml).count, 1)
        XCTAssertTrue(try parse(xml).filter { $0.name == "failure" }.isEmpty)
        XCTAssertEqual(xml, try JUnitReporter.render(document, options: FormatOptions(maxBytes: .max)))
        XCTAssertEqual(try parse(xml)[0].attributes["time"], "0.000", "no wall in a doctor document is not a made-up number")
    }

    func testRouteReachesTheReporter() throws {
        let output = try ReportPipeline.renderFormat(try FormatsFixtures.report(), format: .junit, options: FormatOptions(maxBytes: .max))
        XCTAssertTrue(output.body.hasPrefix("<?xml"))
        XCTAssertEqual(output.annotations, [])
        for format in [ReportBudget.Format.text, .json, .html] {
            XCTAssertThrowsError(try ReportPipeline.renderFormat(try FormatsFixtures.report(), format: format, options: FormatOptions(maxBytes: 1000)))
        }
    }
}
