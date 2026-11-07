import Foundation
import XCTest
@testable import XcblameKit

/// Repo-relative fixture access shared by the lane B tests.
enum LaneBFixtures {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/logs")

    static func inflated(_ relativePath: String) throws -> Data {
        let url = root.appendingPathComponent(relativePath)
        let out = try XCTUnwrap(runProcess(["/usr/bin/gunzip", "-c", url.path], timeout: 30))
        XCTAssertTrue(out.succeeded, out.stderrString)
        return out.stdout
    }
}

final class XCResultReaderTests: XCTestCase {
    func testFixtureThroughBuilder() throws {
        let data = try LaneBFixtures.inflated("cli-xcode26/xcresult-buildlog.json.gz")
        let raw = try XCResultReader.read(jsonData: data)
        XCTAssertEqual(raw.layout, .xcresult)
        XCTAssertNil(raw.formatVersion)
        XCTAssertTrue(raw.decodeWarnings.isEmpty, "\(raw.decodeWarnings)")
        XCTAssertEqual(raw.root.end - raw.root.start, 18.79, accuracy: 0.01)
        XCTAssertGreaterThan(raw.root.start, 1_700_000_000)

        let model = BuildModelBuilder.build(raw, reader: .xcresult)
        XCTAssertEqual(model.tasks.count, 577, "the clean action (3 tasks) is excluded, as in SLF")
        let swiftCompile = model.tasks.filter { $0.kind == .swiftCompile }.reduce(0) { $0 + $1.duration }
        // The builder prefers TaskMetrics durations, which sum to Xcode's own "Build Timing Summary" row
        // (109.343 s); the raw section durations the reader emits sum to 109.276 s (brief: 109.28).
        let summary = try XCTUnwrap(model.timingSummary?.rows.first { $0.ruleName == "SwiftCompile" })
        XCTAssertEqual(summary.taskCount, 87)
        XCTAssertEqual(swiftCompile, summary.seconds, accuracy: 0.05)
        XCTAssertEqual(rawSwiftCompileSeconds(raw.root), 109.28, accuracy: 0.05)
        XCTAssertEqual(model.tasks.filter { $0.metrics != nil }.count, 466)
        XCTAssertTrue(model.decodeWarnings.isEmpty, "\(model.decodeWarnings)")
        XCTAssertTrue(model.degradations.isEmpty, "\(model.degradations)")
        print("xcresult fixture: tasks=\(model.tasks.count) swiftCompile=\(swiftCompile) "
              + "metrics=\(model.tasks.filter { $0.metrics != nil }.count) diagnostics=\(model.diagnostics.count)")
    }

    /// Sum of section durations of outermost `SwiftCompile` task sections (no TaskMetrics involved).
    private func rawSwiftCompileSeconds(_ section: RawSection) -> Double {
        if section.domainType == BuildModelBuilder.buildLogSectionDomain, let rule = BuildModelBuilder.ruleName(of: section) {
            return rule == "SwiftCompile" ? section.end - section.start : 0
        }
        return section.subsections.reduce(0) { $0 + rawSwiftCompileSeconds($1) }
    }

    func testWarningSeverityAndLocation() throws {
        let data = try LaneBFixtures.inflated("cli-xcode26/xcresult-buildlog.json.gz")
        let model = BuildModelBuilder.build(try XCResultReader.read(jsonData: data), reader: .xcresult)
        let warnings = model.diagnostics.filter { $0.severity == .warning }
        XCTAssertEqual(warnings.count, 1)
        let warning = try XCTUnwrap(warnings.first)
        XCTAssertEqual(warning.file?.hasSuffix("StudioView.swift"), true)
        XCTAssertEqual(warning.line, 394, "fragment is 0-based, the model is 1-based")
        XCTAssertEqual(warning.column, 9)
        XCTAssertFalse(model.diagnostics.contains { $0.severity == .unknown })
    }

    func testMinimalAndUnknownKeysAreTolerated() throws {
        let json = #"""
        {"futureKey": [1, 2], "subsections": [
          {"startTime": 100.5, "duration": 2, "commandInvocationDetails": {"commandDetails": "Ld x", "exitCode": 1},
           "domainType": "com.apple.dt.IDE.BuildLogSection",
           "messages": [{"title": "boom", "type": "error", "category": "Weird Category",
                         "annotations": [{"title": "note", "location": null}],
                         "location": {"url": "file:///a.swift#StartingLineNumber=3&StartingColumnNumber=1&Bogus=x"}}],
           "attachments": [{"uniformTypeIdentifier": "x.y", "typeMajorVersion": 1, "data": "{\"a\":1}"}, {"data": 7}]}
        ]}
        """#
        let raw = try XCResultReader.read(jsonData: Data(json.utf8))
        XCTAssertEqual(raw.root.title, "")
        XCTAssertEqual(raw.root.start, 100.5)
        let task = try XCTUnwrap(raw.root.subsections.first)
        XCTAssertEqual(task.start, 100.5)
        XCTAssertEqual(task.end, 102.5)
        XCTAssertEqual(task.resultCode, 1)
        XCTAssertEqual(task.commandDetails, "Ld x")
        let message = try XCTUnwrap(task.messages.first)
        XCTAssertEqual(message.type, "error")
        XCTAssertNil(message.severity)
        XCTAssertEqual(message.categoryIdent, "Weird Category")
        XCTAssertEqual(message.submessages.map(\.title), ["note"])
        XCTAssertEqual(message.location, RawLocation(file: "file:///a.swift", startLine: 3, startColumn: 1, numberBase: 0))
        XCTAssertEqual(task.attachments.map(\.identifier), ["x.y"])
        XCTAssertEqual(task.attachments.first?.majorVersion, 1)
        XCTAssertEqual(raw.decodeWarnings.map(\.kind), [.invalidAttachment])
    }

    func testInvalidInputThrows() {
        XCTAssertThrowsError(try XCResultReader.read(jsonData: Data("not json".utf8)))
        XCTAssertThrowsError(try XCResultReader.read(jsonData: Data("[1]".utf8))) {
            XCTAssertEqual($0 as? XCResultReader.ReadError, .notASection)
        }
    }

    func testMissingBundleReportsToolStderr() {
        let bogus = URL(fileURLWithPath: "/nonexistent/none.xcresult")
        XCTAssertThrowsError(try XCResultReader.read(resultBundle: bogus)) { error in
            guard case XCResultReader.ReadError.toolFailed(_, let stderr)? = error as? XCResultReader.ReadError else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertFalse(stderr.isEmpty)
        }
    }
}
