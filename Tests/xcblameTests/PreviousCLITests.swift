import Foundation
import XCTest

/// D1 (docs/SCHEMA-v0.6.md "report: previous", 2026-11-08): `analyze` fills `previous` from the local history with the
/// newest older entry of the same kind and scheme, never the entry of the same log, and null with `--no-history`.
final class PreviousCLITests: XCTestCase {
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/logs/cli-xcode26/20E8B73D-96FE-4232-8A33-311BFD02F961.xcactivitylog")

    /// A scratch folder with two copies of the clean log under fresh UUID names (two builds to history) and a state dir.
    private func scratch() throws -> (logs: [URL], state: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-previous-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let logs = try (0 ..< 2).map { _ -> URL in
            let url = dir.appendingPathComponent(UUID().uuidString + ".xcactivitylog")
            try FileManager.default.copyItem(at: Self.fixture, to: url)
            return url
        }
        return (logs, dir.appendingPathComponent("state"))
    }

    private func analyze(_ log: URL, state: URL, extra: [String] = []) throws -> [String: Any] {
        let result = try CLIRunner(test: self).run(["analyze", log.path, "--xcblame-dir", state.path, "--no-rules", "--no-env",
                                                    "--format", "json"] + extra)
        XCTAssertEqual(result.status, 0, result.err)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.out.utf8)) as? [String: Any], result.out)
    }

    private func entries(_ state: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: state.appendingPathComponent("history").path)
            .filter { $0.hasSuffix(".json.gz") }.map { String($0.dropLast(".json.gz".count)) }.sorted()
    }

    func testSecondAnalyzeCarriesTheFirstAsPrevious() throws {
        let (logs, state) = try scratch()
        let first = try analyze(logs[0], state: state)
        XCTAssertTrue(first.keys.contains("previous"), "always serialized")
        XCTAssertTrue(first["previous"] is NSNull, "no history yet: \(String(describing: first["previous"]))")
        let firstId = try XCTUnwrap(try entries(state).first)

        let second = try analyze(logs[1], state: state)
        let previous = try XCTUnwrap(second["previous"] as? [String: Any], "\(String(describing: second["previous"]))")
        let build = try XCTUnwrap(first["build"] as? [String: Any])
        XCTAssertEqual(Set(previous.keys), ["span", "kind", "generatedAt", "id"])
        XCTAssertEqual(previous["id"] as? String, firstId)
        XCTAssertEqual(previous["kind"] as? String, try XCTUnwrap(build["kind"] as? String))
        XCTAssertEqual(try XCTUnwrap(previous["span"] as? Double), try XCTUnwrap(build["span"] as? Double), accuracy: 1e-9)
        XCTAssertEqual(previous["generatedAt"] as? String, first["generatedAt"] as? String)
        XCTAssertEqual(try entries(state).count, 2)

        // Re-analyzing the second log never names its own entry: the first stays the previous build.
        let again = try analyze(logs[1], state: state)
        XCTAssertEqual((again["previous"] as? [String: Any])?["id"] as? String, firstId)
        XCTAssertEqual(try entries(state).count, 2, "one entry per log")
    }

    func testNoHistoryLeavesPreviousNull() throws {
        let (logs, state) = try scratch()
        _ = try analyze(logs[0], state: state)
        let second = try analyze(logs[1], state: state, extra: ["--no-history"])
        XCTAssertTrue(second["previous"] is NSNull, "\(String(describing: second["previous"]))")
    }
}
