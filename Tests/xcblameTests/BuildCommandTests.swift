import Foundation
import XCTest
import XcblameKit

/// Runs the built `xcblame` binary in a scratch folder with `XCBLAME_XCODEBUILD` pointing at a fake xcodebuild.
struct BuildCLIHarness {
    struct Run {
        var status: Int32
        var out: String
        var err: String
    }

    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/logs/cli-xcode26-dd")
    static let logUUID = "5E3BDB3A-008A-466D-A419-CB4D4E8CED29"

    var directory: URL
    var script: URL
    var derivedData: URL

    static func binary(for testCase: XCTestCase) -> URL {
        Bundle(for: type(of: testCase)).bundleURL.deletingLastPathComponent().appendingPathComponent("xcblame")
    }

    /// `exitCode` is the fake xcodebuild's; `writeLog: false` is a build that left no log behind; `sleep` in seconds;
    /// `uniqueLogs` names each build's log with a fresh uuid, as real builds do (history keeps one entry per log).
    static func make(for testCase: XCTestCase, exitCode: Int32 = 0, writeLog: Bool = true, sleep: String = "0.1",
                     uniqueLogs: Bool = false) throws -> BuildCLIHarness {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcblame-build-cli-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        testCase.addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            for case let url as URL in FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
                ?? NSEnumerator() {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            try? FileManager.default.removeItem(at: directory)
        }
        let derivedData = directory.appendingPathComponent("dd")
        let description = derivedData.appendingPathComponent("Build/Intermediates.noindex/XCBuildData/abc.xcbuilddata")
        let source = fixtures.appendingPathComponent("xcbuilddata").path
        var lines = ["#!/bin/sh", "echo 'fake xcodebuild stdout'", "echo 'fake xcodebuild stderr' >&2", "sleep \(sleep)"]
        if writeLog {
            lines += [
                "mkdir -p '\(derivedData.path)/Logs/Build'",
                "cp '\(fixtures.path)/\(logUUID).xcactivitylog' '\(derivedData.path)/Logs/Build/"
                    + (uniqueLogs ? "'$(uuidgen).xcactivitylog" : "'"),
                "mkdir -p '\(description.path)'",
                "gunzip -c '\(source)/manifest.json.gz' > '\(description.path)/manifest.json'",
                "cp '\(source)/target-graph.txt' '\(source)/build-request.json' '\(description.path)/'",
            ]
        }
        lines.append("exit \(exitCode)")
        let script = directory.appendingPathComponent("fake-xcodebuild.sh")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return BuildCLIHarness(directory: directory, script: script, derivedData: derivedData)
    }

    var state: URL { directory.appendingPathComponent(".xcblame") }

    /// `xcblame <arguments>` with the scratch folder as working directory.
    func run(_ testCase: XCTestCase, _ arguments: [String], environment: [String: String] = [:]) throws -> Run {
        let process = Process()
        process.executableURL = Self.binary(for: testCase)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var env = ProcessInfo.processInfo.environment
        env["CI"] = nil
        env["NO_COLOR"] = "1"
        // The settings oracle's cache home: under .build for the whole test run, never ~/Library/Caches.
        env["XCBLAME_CACHE_DIR"] = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/settings-test-cache/oracle-home").path
        env["XCBLAME_XCODEBUILD"] = script.path
        env.merge(environment) { $1 }
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                   err: String(decoding: errData, as: UTF8.self))
    }

    /// `build <extra> -- -scheme App -derivedDataPath <dd>`
    func build(_ testCase: XCTestCase, _ extra: [String] = []) throws -> Run {
        try run(testCase, ["build"] + extra + ["--", "-scheme", "App", "-derivedDataPath", derivedData.path])
    }

    var historyEntries: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: state.appendingPathComponent("history").path)) ?? [])
            .filter { $0.hasSuffix(".json.gz") }.sorted()
    }
}

final class BuildCommandTests: XCTestCase {
    func testSuccessfulBuildPrintsTheReportAndKeepsHistory() throws {
        let harness = try BuildCLIHarness.make(for: self)
        let result = try harness.build(self)
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.contains("fake xcodebuild stdout"), result.out)
        XCTAssertTrue(result.err.contains("fake xcodebuild stderr"), result.err)
        for section in ["TIME", "TARGETS", "TOP TASKS"] {
            XCTAssertTrue(result.out.contains(section), "\(section) missing:\n\(result.out)")
        }
        XCTAssertEqual(harness.historyEntries.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            harness.state.appendingPathComponent("snapshots/\(BuildCLIHarness.logUUID)/manifest.json.gz").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.state.appendingPathComponent(".gitignore").path))
    }

    func testJSONFormatCarriesProcessWall() throws {
        let harness = try BuildCLIHarness.make(for: self, sleep: "0.3")
        // xcodebuild's own stdout is streamed through unchanged, so the json goes to a file.
        let report = harness.directory.appendingPathComponent("report.json")
        let result = try harness.build(self, ["--format", "json", "--no-history", "-o", report.path])
        XCTAssertEqual(result.status, 0, result.err)
        let document = try JSONReporter.decoder().decode(ReportDocument.self, from: try Data(contentsOf: report))
        let wall = try XCTUnwrap(document.timing.processWall)
        XCTAssertGreaterThanOrEqual(wall, 0.3)
        XCTAssertLessThan(wall, 10)
        XCTAssertTrue(harness.historyEntries.isEmpty)
    }

    func testXcodebuildExitCodeIsPassedThrough() throws {
        let harness = try BuildCLIHarness.make(for: self, exitCode: 65)
        let result = try harness.build(self)
        XCTAssertEqual(result.status, 65, result.err)
        XCTAssertTrue(result.out.contains("TIME"), "the failed build is still analyzed:\n\(result.out)")
    }

    func testXcblameExitCodeModeIgnoresXcodebuildsCode() throws {
        let harness = try BuildCLIHarness.make(for: self, exitCode: 65)
        let result = try harness.build(self, ["--exit-code", "xcblame"])
        XCTAssertEqual(result.status, 0, result.err)
    }

    func testMissingLogStillExitsWithXcodebuildsCode() throws {
        for code: Int32 in [0, 65] {
            let harness = try BuildCLIHarness.make(for: self, exitCode: code, writeLog: false)
            let result = try harness.build(self)
            XCTAssertEqual(result.status, code, result.err)
            XCTAssertTrue(result.err.contains("build analysis unavailable"), result.err)
        }
    }

    func testMissingLogInXcblameModeFails() throws {
        let harness = try BuildCLIHarness.make(for: self, exitCode: 0, writeLog: false)
        let result = try harness.build(self, ["--exit-code", "xcblame"])
        XCTAssertEqual(result.status, 1, result.err)
    }

    func testHistoryFailureNeverChangesTheExitCode() throws {
        for code: Int32 in [0, 65] {
            let harness = try BuildCLIHarness.make(for: self, exitCode: code)
            // A history folder that cannot be written to.
            let history = harness.state.appendingPathComponent("history")
            try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: history.path)
            let result = try harness.build(self)
            XCTAssertEqual(result.status, code, result.err)
            XCTAssertTrue(result.err.contains("warning: build not recorded in history"), result.err)
            XCTAssertTrue(result.out.contains("TIME"), result.out)
            XCTAssertTrue(harness.historyEntries.isEmpty)
        }
    }

    func testTimeoutExitsWith124() throws {
        let harness = try BuildCLIHarness.make(for: self, writeLog: false, sleep: "30")
        let result = try harness.build(self, ["--timeout", "0.5"])
        XCTAssertEqual(result.status, 124, result.err)
        XCTAssertTrue(result.err.contains("timeout:"), result.err)
    }

    func testHTMLReportWhileLaneCIsMissingOnlyNotes() throws {
        let harness = try BuildCLIHarness.make(for: self)
        let result = try harness.build(self, ["--html"])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.contains("TIME"), result.out)
        // Either the html landed (Lane C merged) or the note says why not; never a failure.
        XCTAssertTrue(result.out.contains("wrote ") || result.err.contains("html report skipped"),
                      "out: \(result.out)\nerr: \(result.err)")
    }

    /// Code review v0.2 #7: `--html --no-redact` writes an unredacted page.
    func testHTMLSideReportHonoursNoRedact() throws {
        let harness = try BuildCLIHarness.make(for: self)
        let result = try harness.build(self, ["--html", "--no-redact", "--no-history"])
        XCTAssertEqual(result.status, 0, result.err)
        let reports = harness.state.appendingPathComponent("reports")
        let name = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: reports.path).first)
        let html = try String(contentsOf: reports.appendingPathComponent(name), encoding: .utf8)
        XCTAssertTrue(html.contains("\"redacted\" : false"))
        XCTAssertFalse(html.contains("\"redacted\" : true"))
    }

    func testNegativeTimeoutIsAUsageError() throws {
        let harness = try BuildCLIHarness.make(for: self)
        let result = try harness.run(self, ["build", "--timeout", "0", "--", "-scheme", "App"])
        XCTAssertEqual(result.status, 2, result.err)
    }
}
