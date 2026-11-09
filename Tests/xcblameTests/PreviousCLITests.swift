import Foundation
import XCTest
import XcblameKit

/// D1 (docs/SCHEMA-v0.6.md "report: previous", 2026-11-08): `analyze` and `build` fill `previous` from the local history
/// with the newest entry strictly older than this build (by build start) of the same kind and scheme, never a deep
/// entry or the entry of the same log, null for a deep build and with `--no-history`.
final class PreviousCLITests: XCTestCase {
    private static let logs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/logs")
    /// Clean AcmeApp builds, oldest first (started 2026-10-30 17:20, 2026-10-31 18:43 and 19:20).
    private static let cleanA = logs.appendingPathComponent("cli-xcode26/20E8B73D-96FE-4232-8A33-311BFD02F961.xcactivitylog")
    private static let cleanB = logs.appendingPathComponent("cli-xcode26-dd/5E3BDB3A-008A-466D-A419-CB4D4E8CED29.xcactivitylog")
    /// An incremental AcmeApp build older than `cleanB` (2026-10-30 17:21).
    private static let incremental = logs.appendingPathComponent("cli-xcode26/D822889B-3D9A-478F-BB03-AB98C3967FD1.xcactivitylog")

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-previous-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func analyze(_ log: URL, state: URL, extra: [String] = [], file: StaticString = #filePath, line: UInt = #line) throws
        -> [String: Any] {
        let result = try CLIRunner(test: self).run(["analyze", log.path, "--xcblame-dir", state.path, "--no-rules", "--no-env",
                                                    "--format", "json"] + extra)
        XCTAssertEqual(result.status, 0, result.err, file: file, line: line)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any], result.out,
                             file: file, line: line)
    }

    private func entries(_ state: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: state.appendingPathComponent("history").path)
            .filter { $0.hasSuffix(".json.gz") }.map { String($0.dropLast(".json.gz".count)) }.sorted()
    }

    private func previousId(_ report: [String: Any]) -> String? { (report["previous"] as? [String: Any])?["id"] as? String }

    /// A history entry written through the library: the synthetic model's build started 2023-11-14, before every fixture.
    @discardableResult
    private func seed(_ history: URL, kind: String = "clean", scheme: String?, deep: Bool = false, at minute: Double) throws -> String {
        let model = SyntheticModel.make()
        // Written an hour ago (history keeps 90 days, so an old date would be pruned on save), `minute` minutes apart.
        var document = try ReportPipeline.run(model, options: .init(generatedAt: Date().addingTimeInterval(-3_600 + minute * 60)))
            .document
        document.build.kind = kind
        document.build.scheme = scheme
        if deep {
            document.deep = .init(enabled: true, scope: ["swift"], flagsInjected: ["-Xfrontend -debug-time-function-bodies"],
                                  flagsDropped: [], shadowed: [], derivedData: "/tmp/deep", derivedDataBytes: nil, wrapper: nil,
                                  exactFiles: nil, sources: nil, notes: [])
        }
        let url = try History.save(document: document, model: model, directory: history)
        return String(url.lastPathComponent.dropLast(".json.gz".count))
    }

    func testSecondAnalyzeCarriesTheFirstAsPrevious() throws {
        let state = try scratch().appendingPathComponent("state")
        let first = try analyze(Self.cleanA, state: state)
        XCTAssertTrue(first.keys.contains("previous"), "always serialized")
        XCTAssertTrue(first["previous"] is NSNull, "no history yet: \(String(describing: first["previous"]))")
        let firstId = try XCTUnwrap(try entries(state).first)

        let second = try analyze(Self.cleanB, state: state)
        let previous = try XCTUnwrap(second["previous"] as? [String: Any], "\(String(describing: second["previous"]))")
        let build = try XCTUnwrap(first["build"] as? [String: Any])
        XCTAssertEqual(Set(previous.keys), ["span", "kind", "generatedAt", "id"])
        XCTAssertEqual(previous["id"] as? String, firstId)
        XCTAssertEqual(previous["kind"] as? String, "clean")
        XCTAssertEqual(try XCTUnwrap(previous["span"] as? Double), try XCTUnwrap(build["span"] as? Double), accuracy: 1e-9)
        XCTAssertEqual(previous["generatedAt"] as? String, first["generatedAt"] as? String)

        // Re-analyzing the second log never names its own entry: the first stays the previous build.
        XCTAssertEqual(previousId(try analyze(Self.cleanB, state: state)), firstId)
        XCTAssertEqual(try entries(state).count, 2, "one entry per log")
    }

    /// Analyzed in the other order, the older build gets no previous: B ran after A, whatever was analyzed first.
    func testANewerBuildIsNeverThePrevious() throws {
        let state = try scratch().appendingPathComponent("state")
        _ = try analyze(Self.cleanB, state: state)
        let older = try analyze(Self.cleanA, state: state)
        XCTAssertTrue(older["previous"] is NSNull, "\(String(describing: older["previous"]))")
    }

    func testAnotherKindIsSkipped() throws {
        let state = try scratch().appendingPathComponent("state")
        XCTAssertEqual((try analyze(Self.incremental, state: state)["build"] as? [String: Any])?["kind"] as? String, "incremental")
        let clean = try analyze(Self.cleanB, state: state)
        XCTAssertTrue(clean["previous"] is NSNull, "an incremental build is not the previous clean build")
    }

    func testAnotherSchemeIsSkipped() throws {
        let dir = try scratch()
        let state = dir.appendingPathComponent("state")
        // Copied out of its folder the log has no manifest, so no scheme: not the same as AcmeApp.
        let copy = dir.appendingPathComponent(UUID().uuidString + ".xcactivitylog")
        try FileManager.default.copyItem(at: Self.cleanA, to: copy)
        XCTAssertTrue((try analyze(copy, state: state)["build"] as? [String: Any])?["scheme"] is NSNull)
        let other = try analyze(Self.cleanB, state: state)
        XCTAssertEqual((other["build"] as? [String: Any])?["scheme"] as? String, "AcmeApp")
        XCTAssertTrue(other["previous"] is NSNull, "\(String(describing: other["previous"]))")
    }

    func testDeepEntriesAreSkippedAndADeepBuildHasNoPrevious() throws {
        let state = try scratch().appendingPathComponent("state")
        let history = state.appendingPathComponent("history")
        try seed(history, scheme: "AcmeApp", deep: true, at: 2)
        XCTAssertTrue(try analyze(Self.cleanB, state: state, extra: ["--no-history"])["previous"] is NSNull, "only a deep entry")
        let plain = try seed(history, scheme: "AcmeApp", at: 1)
        XCTAssertEqual(previousId(try analyze(Self.cleanB, state: state)), plain, "the deep entry is skipped, the plain one is found")

        // The current build itself is deep: never compared with an ordinary build.
        var deep = try ReportPipeline.run(SyntheticModel.make(), options: .init(generatedAt: Date())).document
        deep.build.kind = "clean"
        deep.build.scheme = "AcmeApp"
        XCTAssertNotNil(ReportDocument.Previous.lookup(for: deep, buildStart: Date(), historyDir: history))
        deep.deep = .init(enabled: true, scope: ["swift"], flagsInjected: [], flagsDropped: [], shadowed: [], derivedData: "/tmp/deep",
                          derivedDataBytes: nil, wrapper: nil, exactFiles: nil, sources: nil, notes: [])
        XCTAssertNil(ReportDocument.Previous.lookup(for: deep, buildStart: Date(), historyDir: history))
    }

    func testNoHistoryLeavesPreviousNull() throws {
        let state = try scratch().appendingPathComponent("state")
        _ = try analyze(Self.cleanA, state: state)
        let second = try analyze(Self.cleanB, state: state, extra: ["--no-history"])
        XCTAssertTrue(second["previous"] is NSNull, "\(String(describing: second["previous"]))")
    }

    /// `build` fills `previous` the same way (fake xcodebuild; its `-scheme App` wins over the log's manifest).
    func testBuildFillsPreviousLikeAnalyze() throws {
        let harness = try BuildCLIHarness.make(for: self, uniqueLogs: true)
        let history = harness.state.appendingPathComponent("history")
        let plain = try seed(history, scheme: "App", at: 1)
        try seed(history, scheme: "App", deep: true, at: 2)
        try seed(history, scheme: "Other", at: 3)
        try seed(history, kind: "incremental", scheme: "App", at: 4)
        let out = harness.directory.appendingPathComponent("build.json")
        let result = try harness.build(self, ["--format", "json", "-o", out.path])
        XCTAssertEqual(result.status, 0, result.err)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any])
        XCTAssertEqual((report["build"] as? [String: Any])?["kind"] as? String, "clean")
        XCTAssertEqual(previousId(report), plain, "\(String(describing: report["previous"]))")
    }
}
