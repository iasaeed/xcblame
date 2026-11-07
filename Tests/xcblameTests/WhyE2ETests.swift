import Foundation
import XCTest

/// The planted causes of `fixtures/projects/AcmeWhy` (docs/SCHEMA-v0.5.md "Planted-cause fixture"), measured end to
/// end with a real xcodebuild on a scratch copy of the fixture, a scratch DerivedData and `CODE_SIGNING_ALLOWED=NO`.
/// Opt-in: `XCBLAME_E2E=1 swift test --filter WhyE2ETests` (about a minute); skipped without xcodebuild.
final class WhyE2ETests: XCTestCase {
    private var cli: CLIRunner { CLIRunner(test: self) }
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/projects/AcmeWhy")

    private struct Scenario {
        var raw: [String: Any]
        var name: String { raw["scenario"] as? String ?? "" }
        var backtraces: Bool { raw["backtraces"] as? Bool ?? false }
        var cause: [String: Any] { raw["primaryCause"] as? [String: Any] ?? [:] }
        var tasks: [String: Any] { raw["tasks"] as? [String: Any] ?? [:] }
        var minShare: Double { raw["minShare"] as? Double ?? 0.9 }
    }

    private func scenarios() throws -> [String: Scenario] {
        let data = try Data(contentsOf: Self.fixture.appendingPathComponent("expected.json"))
        let list = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        return Dictionary(list.map { (($0["scenario"] as? String) ?? "", Scenario(raw: $0)) }, uniquingKeysWith: { a, _ in a })
    }

    private func workspace() throws -> URL {
        guard ProcessInfo.processInfo.environment["XCBLAME_E2E"] == "1" else {
            throw XCTSkip("end-to-end builds are opt-in: XCBLAME_E2E=1")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xcrun"),
              (try? Process.run(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["--find", "xcodebuild"]))
                .map({ $0.waitUntilExit(); return $0.terminationStatus == 0 }) == true else {
            throw XCTSkip("xcodebuild unavailable")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-acmewhy-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(at: Self.fixture, to: dir.appendingPathComponent("AcmeWhy"))
        return dir
    }

    private func xcodebuildArguments(_ dir: URL) -> [String] {
        ["-project", dir.appendingPathComponent("AcmeWhy/AcmeWhy.xcodeproj").path, "-scheme", "AcmeWhyApp",
         "-destination", "platform=macOS", "-derivedDataPath", dir.appendingPathComponent("dd").path,
         "CODE_SIGNING_ALLOWED=NO", "build"]
    }

    /// Asserts the scenario's tasks are held by its primary cause for at least `minShare` of their task time, and
    /// reports the share of the whole build's executed task time (`v15.executedSeconds`, DESIGN §11 v0.5) the cause
    /// holds. Returns that whole-build share.
    @discardableResult
    private func check(_ scenario: Scenario, report: String, file: StaticString = #filePath, line: UInt = #line) throws
        -> Double {
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])
        let incremental = try XCTUnwrap(document["incremental"] as? [String: Any], "\(document["notes"] ?? "")")
        XCTAssertEqual((incremental["v15"] as? [String: Any])?["status"] as? String, "pass", scenario.name, file: file, line: line)
        XCTAssertNotNil(incremental["unknownShare"] as? Double, "the unknown share is reported", file: file, line: line)
        let causes = try XCTUnwrap(incremental["causes"] as? [[String: Any]])
        let target = scenario.tasks["target"] as? String
        let rule = scenario.tasks["rule"] as? String
        var total = 0.0
        var held = 0.0
        var holder: [String: Any]?
        for cause in causes {
            for task in cause["tasks"] as? [[String: Any]] ?? [] where task["target"] as? String == target {
                if let rule, !(task["label"] as? String ?? "").hasPrefix(rule) { continue }
                let seconds = task["seconds"] as? Double ?? 0
                total += seconds
                let expected = scenario.cause
                if cause["class"] as? String == expected["class"] as? String,
                   cause["source"] as? String == expected["source"] as? String,
                   (cause["subject"] as? String ?? "").hasSuffix(expected["subject"] as? String ?? "\u{0}") {
                    held += seconds
                    holder = cause
                }
            }
        }
        XCTAssertGreaterThan(total, 0, "\(scenario.name): no task of \(target ?? "?") executed", file: file, line: line)
        let cause = try XCTUnwrap(holder, "\(scenario.name): \(causes.map { $0["id"] ?? "" })", file: file, line: line)
        XCTAssertGreaterThanOrEqual(held / total, scenario.minShare, scenario.name, file: file, line: line)
        // §11 v0.5 states the share over the build's executed task time: the cause's seconds (all its tasks, in any
        // target) over `v15.executedSeconds`.
        let executed = try XCTUnwrap((incremental["v15"] as? [String: Any])?["executedSeconds"] as? Double)
        let whole = (cause["seconds"] as? Double ?? 0) / max(executed, 1e-9)
        XCTAssertGreaterThan(whole, 0, scenario.name, file: file, line: line)
        XCTAssertLessThanOrEqual(whole, 1 + 1e-6, scenario.name, file: file, line: line)
        // §11 v0.5 (decision 2026-11-03): on a fixture this small Xcode's own per-build work outweighs the planted
        // work: planning (target "build system", kind planning: build description, dependency graph, SDK stat cache,
        // about 0.3 s), the Info.plist and Swift-library copies every build repeats, and the always-running script
        // planted for the zero-change scenario. The ≥ 90 % criterion is measured on the executed task time without them.
        let everyBuild: Set<String> = ["ProcessInfoPlistFile", "CopySwiftLibs", "RegisterExecutionPolicyException"]
        let plantedScript = scenario.cause["class"] as? String == "scriptPhase"
        func excluded(_ task: [String: Any], _ owner: [String: Any]) -> Bool {
            task["target"] as? String == "build system" || task["kind"] as? String == "planning"
                || everyBuild.contains(task["label"] as? String ?? "")
                || (!plantedScript && owner["class"] as? String == "scriptPhase")
        }
        func work(_ owner: [String: Any]) -> Double {
            (owner["tasks"] as? [[String: Any]] ?? []).filter { !excluded($0, owner) }.reduce(0) { $0 + ($1["seconds"] as? Double ?? 0) }
        }
        let executedWork = causes.reduce(0) { $0 + work($1) }
        let causeWork = work(cause)
        XCTAssertGreaterThan(executedWork, 0, scenario.name, file: file, line: line)
        XCTAssertGreaterThanOrEqual(causeWork / max(executedWork, 1e-9), 0.9,
                                    "\(scenario.name): planted cause share of executed task time without Xcode's per-build work; other work: "
                                        + causes.filter { ($0["id"] as? String) != (cause["id"] as? String) }.flatMap { c in
                                            (c["tasks"] as? [[String: Any]] ?? []).filter { !excluded($0, c) }.map {
                                                "\(c["class"] ?? "?") \($0["label"] ?? "?") [\($0["kind"] ?? "?"), \($0["target"] ?? "-")] \($0["seconds"] ?? 0)"
                                            } }.joined(separator: "; "), file: file, line: line)
        print(String(format: "E2E %@: planted cause holds %.1f %% of the executed task time without Xcode's per-build work",
                     scenario.name, 100 * causeWork / max(executedWork, 1e-9)))
        // The exit-criteria numbers (DESIGN §11 v0.5), for the record in the test log.
        print(String(format: "E2E %@: primary %@ holds %.1f %% of %.3f s of %@ task time and %.1f %% of the build's "
                        + "%.3f s executed task time; unknown share %.3f; V15 %@",
                     scenario.name, cause["id"] as? String ?? "?", 100 * held / total, total, target ?? "?", 100 * whole,
                     executed, incremental["unknownShare"] as? Double ?? -1,
                     (incremental["v15"] as? [String: Any])?["status"] as? String ?? "?"))
        if let ruleId = scenario.cause["ruleId"] as? String {
            XCTAssertEqual(cause["ruleId"] as? String, ruleId, scenario.name, file: file, line: line)
        }
        return whole
    }

    func testPlantedCauses() throws {
        let dir = try workspace()
        let expected = try scenarios()
        let state = dir.appendingPathComponent(".xcblame").path
        let arguments = xcodebuildArguments(dir)

        // 1. Zero change: the script phase without outputs.
        let zero = try XCTUnwrap(expected["zeroChange"])
        // xcodebuild's own output passes through stdout, so every report goes to a file.
        let zeroReport = dir.appendingPathComponent("zero.json")
        let zeroRun = try cli.run(["why", "--xcblame-dir", state, "--format", "json", "--top", "all", "-o", zeroReport.path,
                                   "--"] + arguments)
        XCTAssertEqual(zeroRun.status, 0, zeroRun.err)
        try check(zero, report: try String(contentsOf: zeroReport, encoding: .utf8))

        // 2. Touch: the touched file, with Task Backtraces.
        let touch = try XCTUnwrap(expected["touch"])
        let touched = dir.appendingPathComponent("AcmeWhy").appendingPathComponent(touch.raw["touch"] as? String ?? "")
        let touchReport = dir.appendingPathComponent("touch.json")
        let touchRun = try cli.run(["why", "--backtraces", "--touch", touched.path, "--xcblame-dir", state, "--format", "json",
                                    "--top", "all", "-o", touchReport.path, "--"] + arguments)
        XCTAssertEqual(touchRun.status, 0, touchRun.err)
        try check(touch, report: try String(contentsOf: touchReport, encoding: .utf8))

        // 3. Flip: WHY_FLAG between two `build`s, with Task Backtraces on both (same mechanism, MV-2).
        let flip = try XCTUnwrap(expected["flip"])
        let env = flip.backtraces ? ["EnableBuildBacktraceRecording": "YES"] : [:]
        let settle = try cli.run(["build", "--xcblame-dir", state, "--format", "json", "-o", "/dev/null", "--"] + arguments,
                                 environment: env)
        XCTAssertEqual(settle.status, 0, settle.err)
        let config = dir.appendingPathComponent("AcmeWhy/Config/Why.xcconfig")
        let text = try String(contentsOf: config, encoding: .utf8)
        try text.replacingOccurrences(of: "WHY_FLAG = WHY_A", with: "WHY_FLAG = WHY_B").write(to: config, atomically: true, encoding: .utf8)
        let report = dir.appendingPathComponent("flip.json")
        let measured = try cli.run(["build", "--xcblame-dir", state, "--format", "json", "--top", "all", "-o", report.path, "--"]
                                   + arguments, environment: env)
        XCTAssertEqual(measured.status, 0, measured.err)
        try check(flip, report: try String(contentsOf: report, encoding: .utf8))

        // 4. Flip without Task Backtraces (settle and measure both without them). The signature signal can name the
        // flip only on tasks whose previous row it finds: the settle build is zero-change, so its task index holds no
        // WhyCore compile (limit 1), and the per-file compile and emit-module keys change per build (limit 2), so a
        // flipped command digest has no counterpart and the recompiles stay `unknown` with those limit notes. Some
        // runs never reach attribution: Xcode creates a new build description for the changed settings and, without
        // backtrace recording, may reuse no task, so BuildKind says `clean` and `incremental` is null. Either way the
        // report must say why; a signature match (`settingsChanged`, source `signature`) is accepted if it happens.
        let plainSettle = try cli.run(["build", "--xcblame-dir", state, "--format", "json", "-o", "/dev/null", "--"]
                                      + arguments)
        XCTAssertEqual(plainSettle.status, 0, plainSettle.err)
        let flipped = try String(contentsOf: config, encoding: .utf8)
        try flipped.replacingOccurrences(of: "WHY_FLAG = WHY_B", with: "WHY_FLAG = WHY_C")
            .write(to: config, atomically: true, encoding: .utf8)
        let plainReport = dir.appendingPathComponent("flip-signature.json")
        let plain = try cli.run(["build", "--xcblame-dir", state, "--format", "json", "--top", "all", "-o", plainReport.path,
                                 "--"] + arguments)
        XCTAssertEqual(plain.status, 0, plain.err)
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: plainReport)) as? [String: Any])
        let build = try XCTUnwrap(document["build"] as? [String: Any])
        let evidence = build["kindEvidence"] as? [String] ?? []
        if let incremental = document["incremental"] as? [String: Any] {
            let causes = incremental["causes"] as? [[String: Any]] ?? []
            let signature = causes.first {
                $0["id"] as? String == "settingsChanged:WhyCore" && $0["source"] as? String == "signature"
            }
            let notes = incremental["notes"] as? [String] ?? []
            let limits = notes.filter {
                $0.hasPrefix("limit: ") && ($0.contains("have no counterpart") || $0.contains("cannot be matched"))
            }
            XCTAssertTrue(signature != nil || !limits.isEmpty, "\(causes.map { $0["id"] ?? "" }) \(notes)")
            print("E2E flip without backtraces: " + (signature != nil ? "settingsChanged:WhyCore by signature"
                : "no signature match; " + limits.joined(separator: " | ")))
        } else {
            XCTAssertEqual(build["kind"] as? String, "clean", "\(evidence)")
            XCTAssertTrue(evidence.contains { $0.hasPrefix("build description created") }, "\(evidence)")
            XCTAssertTrue((document["notes"] as? [String] ?? []).contains("incremental: not applicable — this is a clean build (no previous work to compare)"))
            print("E2E flip without backtraces: kind clean (\(evidence.joined(separator: "; "))), incremental null")
        }
    }
}
