import Foundation
import XCTest

/// `xcblame why` and `build --runs/--kind/--touch` (docs/SCHEMA-v0.5.md "why", "build --runs"). Never runs a real
/// xcodebuild: `XCBLAME_XCODEBUILD` points at fakes that copy fixture logs.
final class WhyCLITests: XCTestCase {
    private var cli: CLIRunner { CLIRunner(test: self) }
    private static let logs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/logs")
    private static let clean26 = logs.appendingPathComponent("cli-xcode26-why/857BD95F-03FD-4CFE-88B9-F6A5A26CBD64.xcactivitylog")
    private static let zero26 = logs.appendingPathComponent("cli-xcode26-why/CEEF88A0-5057-4971-91D3-A07C8E6E6536.xcactivitylog")
    private static let inc26 = logs.appendingPathComponent("cli-xcode26-why/408C3D38-3634-4108-91B8-EBF7C67092E8.xcactivitylog")
    private static let remarksInc26 = logs.appendingPathComponent(
        "cli-xcode26-incremental-remarks/F7EF5469-BA72-4756-916B-1BC6F1E5D04B.xcactivitylog")

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-why-cli-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// Call n copies `logs[n-1]` (the last one past the end) into `<dir>/dd/Logs/Build` and exits with `codes[n-1]`.
    private func sequenceFake(in dir: URL, logs: [URL], codes: [Int32] = []) throws -> URL {
        let dd = dir.appendingPathComponent("dd")
        var lines = ["#!/bin/sh", "n=$(cat '\(dir.path)/count' 2>/dev/null || echo 0)", "n=$((n + 1))",
                     "echo $n > '\(dir.path)/count'", "echo \"${EnableBuildBacktraceRecording:-unset}\" >> '\(dir.path)/env.log'",
                     "mkdir -p '\(dd.path)/Logs/Build'", "case $n in"]
        for (index, log) in logs.enumerated() {
            let pattern = index == logs.count - 1 ? "*" : "\(index + 1)"
            lines.append("  \(pattern)) cp '\(log.path)' '\(dd.path)/Logs/Build/' ; code=\(index < codes.count ? codes[index] : 0) ;;")
        }
        lines += ["esac", "exit $code"]
        let script = dir.appendingPathComponent("fake-xcodebuild.sh")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    func testWhyUsageErrors() throws {
        let help = try cli.run(["--help"])
        XCTAssertTrue(help.out.contains("why"), help.out)
        for arguments in [["why", "--touch", "A.swift"], ["why", "--backtraces"], ["why", "--show-incremental"],
                          ["why", "--format", "markdown"], ["why", "--log", "x.xcactivitylog", "--", "-scheme", "App"]] {
            XCTAssertEqual(try cli.run(arguments).status, 2, arguments.joined(separator: " "))
        }
        let missing = try cli.run(["why", "--log", "/no/such.xcactivitylog", "--format", "json"])
        XCTAssertEqual(missing.status, 5, missing.err)
    }

    func testWhyLogAgainstAPreviouslySavedCleanBuild() throws {
        let state = try scratch().appendingPathComponent(".xcblame")
        let saved = try cli.run(["analyze", Self.clean26.path, "--xcblame-dir", state.path, "--no-rules", "--format", "json",
                                 "-o", "/dev/null"])
        XCTAssertEqual(saved.status, 0, saved.err)

        let run = try cli.run(["why", "--log", Self.inc26.path, "--xcblame-dir", state.path, "--format", "json", "--top", "all"])
        XCTAssertEqual(run.status, 0, run.err)
        let document = try json(run.out)
        let incremental = try XCTUnwrap(document["incremental"] as? [String: Any])
        XCTAssertEqual(incremental["basis"] as? String, "previousIndex")
        XCTAssertTrue(incremental["procedure"] is NSNull, "no procedure without xcodebuild arguments")
        XCTAssertEqual((incremental["v15"] as? [String: Any])?["status"] as? String, "pass")
        let causes = try XCTUnwrap(incremental["causes"] as? [[String: Any]])
        XCTAssertEqual(causes.last?["id"] as? String, "unknown")
        XCTAssertTrue((causes.first?["subject"] as? String)?.hasSuffix("/Sources/LocalizeCore/Models.swift") == true)
        XCTAssertLessThan(try XCTUnwrap(incremental["unknownShare"] as? Double), 0.01)

        let text = try cli.run(["why", "--log", Self.inc26.path, "--xcblame-dir", state.path, "--format", "text"])
        XCTAssertEqual(text.status, 0, text.err)
        XCTAssertTrue(text.out.contains("INCREMENTAL CAUSES  basis: previous build"), text.out)
        XCTAssertTrue(text.out.contains("V15 pass"), text.out)
        XCTAssertTrue(text.out.contains("by path seconds:"), text.out)
        XCTAssertFalse(text.out.contains("FILES"), "why prints header, causes, path, targets, validation")
    }

    /// Verifier V2: the history key does not depend on whether a build description was supplied. `analyze <clean>
    /// --build-description` then `why --log <incremental>` (no description), and `analyze <clean>` then `analyze
    /// <incremental> --build-description`, both compare with the clean build.
    func testHistoryKeyIgnoresTheBuildDescription() throws {
        let description = Self.logs.appendingPathComponent("cli-xcode26-why/xcbuilddata")
        for describeClean in [true, false] {
            let state = try scratch().appendingPathComponent(".xcblame")
            let saved = try cli.run(["analyze", Self.clean26.path] + (describeClean ? ["--build-description", description.path] : [])
                + ["--xcblame-dir", state.path, "--no-rules", "--format", "json", "-o", "/dev/null"])
            XCTAssertEqual(saved.status, 0, saved.err)
            let command = describeClean ? ["why", "--log", Self.inc26.path]
                : ["analyze", Self.inc26.path, "--build-description", description.path, "--no-rules"]
            let run = try cli.run(command + ["--xcblame-dir", state.path, "--format", "json"])
            XCTAssertEqual(run.status, 0, run.err)
            let document = try json(run.out)
            let build = try XCTUnwrap(document["build"] as? [String: Any])
            XCTAssertEqual(build["configuration"] is NSNull, describeClean, "the incremental side has no description")
            let incremental = try XCTUnwrap(document["incremental"] as? [String: Any])
            XCTAssertEqual(incremental["basis"] as? String, "previousIndex", "description on the clean side: \(describeClean)")
            XCTAssertTrue((incremental["notes"] as? [String] ?? []).contains { $0.contains("known on one side only") })
        }
    }

    /// An ordinary `analyze` (rules on, so the document carries the `doctor` rules section) is no doctor document:
    /// the clean dd log says it is a clean build, the zero-change one is attributed and says no previous build is
    /// recorded.
    func testAnalyzeNotesNameTheRealReasonForIncremental() throws {
        let dd = Self.logs.appendingPathComponent("cli-xcode26-dd")
        let cases = [("5E3BDB3A-008A-466D-A419-CB4D4E8CED29", "clean"), ("1724F45E-EE25-4BC4-B219-B6D39E144D71", "zero-change")]
        for (log, kind) in cases {
            let state = try scratch().appendingPathComponent(".xcblame")
            let run = try cli.run(["analyze", dd.appendingPathComponent(log + ".xcactivitylog").path, "--build-description",
                                   dd.appendingPathComponent("xcbuilddata").path, "--xcblame-dir", state.path,
                                   "--format", "json"])
            XCTAssertEqual(run.status, 0, run.err)
            let document = try json(run.out)
            XCTAssertEqual((document["build"] as? [String: Any])?["kind"] as? String, kind)
            XCTAssertNotNil(document["doctor"] as? [String: Any], "the rules section")
            let notes = (document["notes"] as? [String] ?? []).filter { $0.hasPrefix("incremental") }
            XCTAssertFalse(notes.contains { $0.contains("doctor document") }, "\(notes)")
            if kind == "clean" {
                XCTAssertTrue(document["incremental"] is NSNull)
                XCTAssertEqual(notes, ["incremental: not applicable — this is a clean build (no previous work to compare)"])
            } else {
                let incremental = try XCTUnwrap(document["incremental"] as? [String: Any])
                XCTAssertEqual(incremental["basis"] as? String, "currentLogOnly")
                XCTAssertEqual(notes.count, 1)
                XCTAssertTrue(notes[0].hasPrefix("incremental: no previous build recorded"), "\(notes)")
            }
        }
    }

    func testWhyLogWithoutHistoryIsCurrentLogOnly() throws {
        let state = try scratch().appendingPathComponent(".xcblame")
        let run = try cli.run(["why", "--log", Self.inc26.path, "--xcblame-dir", state.path, "--format", "json"])
        XCTAssertEqual(run.status, 0, run.err)
        let incremental = try XCTUnwrap(try json(run.out)["incremental"] as? [String: Any])
        XCTAssertEqual(incremental["basis"] as? String, "currentLogOnly")
        XCTAssertTrue(incremental["previousBuild"] is NSNull)
        // A clean log has no incremental causes.
        let clean = try cli.run(["why", "--log", Self.clean26.path, "--xcblame-dir", state.path, "--format", "json"])
        XCTAssertEqual(clean.status, 0, clean.err)
        let document = try json(clean.out)
        XCTAssertTrue(document["incremental"] is NSNull)
        XCTAssertTrue((document["notes"] as? [String])?.contains("incremental: not applicable — this is a clean build (no previous work to compare)") == true)
    }

    func testWhyProcedureWithAFakeXcodebuild() throws {
        let dir = try scratch()
        let fake = try sequenceFake(in: dir, logs: [Self.clean26, Self.inc26, Self.remarksInc26])
        let state = dir.appendingPathComponent(".xcblame")
        let arguments = ["why", "--backtraces", "--xcblame-dir", state.path, "--format", "json", "--",
                         "-project", "App.xcodeproj", "-scheme", "App", "-derivedDataPath", dir.appendingPathComponent("dd").path,
                         "CODE_SIGNING_ALLOWED=NO", "build"]
        let run = try cli.run(arguments, environment: ["XCBLAME_XCODEBUILD": fake.path])
        XCTAssertEqual(run.status, 0, run.err)
        let document = try json(run.out)
        let incremental = try XCTUnwrap(document["incremental"] as? [String: Any])
        XCTAssertEqual(incremental["basis"] as? String, "previousIndex")
        let procedure = try XCTUnwrap(incremental["procedure"] as? [String: Any])
        XCTAssertEqual(procedure["mode"] as? String, "zeroChange")
        XCTAssertEqual(procedure["backtraces"] as? String, "on")
        let builds = try XCTUnwrap(procedure["builds"] as? [[String: Any]])
        XCTAssertEqual(builds.map { $0["role"] as? String }, ["settle", "measure", "repeat"])
        XCTAssertNotNil(builds[0]["historyId"] as? String)
        XCTAssertEqual((incremental["previousBuild"] as? [String: Any])?["id"] as? String, builds[0]["historyId"] as? String,
                       "the measured build is compared with the settle build")
        let findings = try XCTUnwrap(document["findings"] as? [[String: Any]])
        XCTAssertEqual(findings.map { $0["ruleId"] as? String }, ["DYN-002"])
        XCTAssertNotNil((document["ruleDocs"] as? [String: Any])?["DYN-002"])
        let entries = try FileManager.default.contentsOfDirectory(atPath: state.appendingPathComponent("history").path)
            .filter { $0.hasSuffix(".json.gz") }
        XCTAssertEqual(entries.count, 2, "settle and measure are recorded; the repeat is not")

        let html = try cli.run(["why", "--log", Self.inc26.path, "--xcblame-dir", state.path, "--format", "html",
                                "-o", dir.appendingPathComponent("why.html").path])
        XCTAssertEqual(html.status, 0, html.err)
        let page = try String(contentsOf: dir.appendingPathComponent("why.html"), encoding: .utf8)
        XCTAssertTrue(page.contains("<title>xcblame why"), String(page.prefix(400)))
    }

    func testAFailedProcedureBuildIsExit1WithTheRole() throws {
        let dir = try scratch()
        let fake = try sequenceFake(in: dir, logs: [Self.clean26], codes: [65])
        let run = try cli.run(["why", "--xcblame-dir", dir.appendingPathComponent(".xcblame").path, "--format", "json", "--",
                               "-scheme", "App", "-derivedDataPath", dir.appendingPathComponent("dd").path],
                              environment: ["XCBLAME_XCODEBUILD": fake.path])
        XCTAssertEqual(run.status, 1, run.err)
        XCTAssertTrue(run.err.contains("the settle build failed (xcodebuild exit code 65)"), run.err)
    }

    /// What `EnableBuildBacktraceRecording` each spawned fake xcodebuild saw, one entry per call.
    private func backtraceVariables(in dir: URL) throws -> [String] {
        try String(contentsOf: dir.appendingPathComponent("env.log"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    /// `build --kind incremental|zero-change` and `--touch` record Task Backtraces on every build of the run (the
    /// preparation and the measured build), `--no-backtraces` opts out, and a plain `build` never sets the variable.
    func testBuildRecordsBacktracesForIncrementalRuns() throws {
        let touched = try scratch().appendingPathComponent("A.swift")
        try Data("let a = 1\n".utf8).write(to: touched)
        let cases: [(arguments: [String], expected: [String])] = [
            (["--kind", "incremental", "--touch", touched.path], ["YES", "YES"]),
            (["--kind", "zero-change"], ["YES", "YES"]),
            (["--touch", touched.path], ["YES", "YES"]),
            (["--kind", "incremental", "--touch", touched.path, "--no-backtraces"], ["unset", "unset"]),
            ([], ["unset"]),
            (["--kind", "clean"], ["unset", "unset"]),
        ]
        for (extra, expected) in cases {
            let dir = try scratch()
            let fake = try sequenceFake(in: dir, logs: [Self.clean26, Self.inc26])
            let run = try cli.run(["build", "--format", "json", "--xcblame-dir", dir.appendingPathComponent(".xcblame").path]
                                  + extra + ["--", "-scheme", "App", "-derivedDataPath", dir.appendingPathComponent("dd").path],
                                  environment: ["XCBLAME_XCODEBUILD": fake.path, "EnableBuildBacktraceRecording": ""])
            XCTAssertEqual(run.status, 0, run.err)
            XCTAssertEqual(try backtraceVariables(in: dir), expected, "build \(extra)")
        }
        XCTAssertEqual(try cli.run(["build", "--no-backtraces", "--", "-scheme", "App"]).status, 2,
                       "--no-backtraces needs a run that records them")
    }

    func testBuildRunsKindAndTouch() throws {
        let dir = try scratch()
        let fake = try sequenceFake(in: dir, logs: [Self.clean26, Self.zero26, Self.clean26, Self.inc26])
        let state = dir.appendingPathComponent(".xcblame")
        let run = try cli.run(["build", "--runs", "2", "--kind", "zero-change", "--xcblame-dir", state.path,
                               "--format", "json", "--", "-scheme", "App", "-derivedDataPath",
                               dir.appendingPathComponent("dd").path],
                              environment: ["XCBLAME_XCODEBUILD": fake.path])
        XCTAssertEqual(run.status, 0, run.err)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("count"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), "4", "prepare + build, twice")
        XCTAssertTrue(run.err.contains("run 1/2: zero-change, exit 0"), run.err)
        XCTAssertTrue(run.err.contains("run 2/2: zero-change, exit 0"), run.err)
        let document = try json(run.out)
        XCTAssertEqual((document["build"] as? [String: Any])?["kind"] as? String, "incremental", "the last run's report")
        XCTAssertEqual((document["incremental"] as? [String: Any])?["basis"] as? String, "previousIndex",
                       "run 2 is compared with run 1")

        let fake2 = try sequenceFake(in: try scratch(), logs: [Self.clean26], codes: [70])
        let failed = try cli.run(["build", "--kind", "clean", "--xcblame-dir", state.path, "--", "-scheme", "App"],
                                 environment: ["XCBLAME_XCODEBUILD": fake2.path])
        XCTAssertEqual(failed.status, 1, failed.err)
        XCTAssertTrue(failed.err.contains("the clean build failed"), failed.err)
        XCTAssertEqual(try cli.run(["build", "--kind", "warm", "--", "-scheme", "App"]).status, 2)
        XCTAssertEqual(try cli.run(["build", "--kind", "incremental", "--", "-scheme", "App"]).status, 2)
        XCTAssertEqual(try cli.run(["build", "--runs", "0", "--", "-scheme", "App"]).status, 2)
    }
}
