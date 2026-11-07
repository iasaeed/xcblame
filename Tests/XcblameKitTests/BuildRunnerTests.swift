import Foundation
import XCTest
@testable import XcblameKit

final class BuildRunnerTests: XCTestCase {
    private func run(_ fake: FakeXcodebuild, state: URL, extra: [String] = [], timeout: Double? = nil) throws
        -> XcodebuildRunner.Result {
        try XcodebuildRunner.run(arguments: ["-scheme", "App", "-derivedDataPath", fake.derivedData.path] + extra,
                                 xcblameDir: state, timeout: timeout, executable: fake.script, executablePrefix: [])
    }

    /// v0.5 integration: `environment` is merged over this process's environment for the child only, and
    /// `unsetEnvironment` removes variables after the merge; xcblame's own environment never changes.
    func testEnvironmentIsMergedAndUnsetForTheChildOnly() throws {
        let dir = try makeScratchDirectory()
        let envFile = dir.appendingPathComponent("env.txt")
        let script = dir.appendingPathComponent("env-xcodebuild.sh")
        try Data("#!/bin/sh\nenv > '\(envFile.path)'\nexit 0\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        func childEnvironment(_ environment: [String: String]?, unset: [String] = []) throws -> [String: String] {
            _ = try XcodebuildRunner.run(arguments: ["-derivedDataPath", dir.appendingPathComponent("dd").path],
                                         xcblameDir: dir.appendingPathComponent(".xcblame"), timeout: 30,
                                         executable: script, executablePrefix: [], environment: environment,
                                         unsetEnvironment: unset)
            var result: [String: String] = [:]
            for line in try String(contentsOf: envFile, encoding: .utf8).split(separator: "\n") {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { result[parts[0]] = parts[1] }
            }
            return result
        }
        XCTAssertNil(ProcessInfo.processInfo.environment["EnableBuildBacktraceRecording"])
        XCTAssertNotNil(ProcessInfo.processInfo.environment["PATH"])
        let plain = try childEnvironment(nil)
        XCTAssertNil(plain["EnableBuildBacktraceRecording"])
        XCTAssertEqual(plain["PATH"], ProcessInfo.processInfo.environment["PATH"], "inherited unchanged")

        let merged = try childEnvironment(["EnableBuildBacktraceRecording": "YES", "HOME": "/override"], unset: ["PATH"])
        XCTAssertEqual(merged["EnableBuildBacktraceRecording"], "YES")
        XCTAssertEqual(merged["HOME"], "/override", "an override wins over the inherited value")
        XCTAssertNil(merged["PATH"], "an explicit removal")
        XCTAssertEqual(merged["USER"], ProcessInfo.processInfo.environment["USER"], "the rest is inherited")
        XCTAssertNil(ProcessInfo.processInfo.environment["EnableBuildBacktraceRecording"], "xcblame's own is untouched")
        XCTAssertNotNil(ProcessInfo.processInfo.environment["PATH"])

        XCTAssertEqual(XcodebuildRunner.childEnvironment(["A": "1", "B": "2"], merging: ["B": "3", "C": "4"],
                                                         unsetting: ["A", "C"]), ["B": "3"], "unset after the merge")
    }

    func testExitCodeIsPassedThrough() throws {
        for code: Int32 in [0, 65] {
            let dir = try makeScratchDirectory()
            let fake = try FakeXcodebuild.make(in: dir, exitCode: code)
            let result = try run(fake, state: dir.appendingPathComponent(".xcblame"))
            XCTAssertEqual(result.exitCode, code)
            XCTAssertFalse(result.timedOut)
        }
    }

    func testInjectedFlagsReachXcodebuild() throws {
        let dir = try makeScratchDirectory()
        let state = dir.appendingPathComponent(".xcblame")
        let fake = try FakeXcodebuild.make(in: dir)
        let result = try run(fake, state: state)
        let argv = try fake.recordedArguments()
        XCTAssertEqual(Array(argv.prefix(4)), ["-scheme", "App", "-derivedDataPath", fake.derivedData.path])
        let bundleIndex = try XCTUnwrap(argv.firstIndex(of: "-resultBundlePath"))
        let bundle = argv[bundleIndex + 1]
        XCTAssertTrue(bundle.hasPrefix(state.appendingPathComponent("results").path), bundle)
        XCTAssertTrue(bundle.hasSuffix(".xcresult"), bundle)
        XCTAssertEqual(result.resultBundle?.path, bundle)
        XCTAssertEqual(argv.filter { $0 == "-showBuildTimingSummary" }.count, 1)
    }

    func testUserFlagsAreNotOverridden() throws {
        let dir = try makeScratchDirectory()
        let fake = try FakeXcodebuild.make(in: dir)
        let mine = dir.appendingPathComponent("mine.xcresult").path
        let result = try run(fake, state: dir.appendingPathComponent(".xcblame"),
                             extra: ["-resultBundlePath", mine, "-showBuildTimingSummary"])
        let argv = try fake.recordedArguments()
        XCTAssertEqual(argv.filter { $0 == "-resultBundlePath" }.count, 1)
        XCTAssertEqual(argv.filter { $0 == "-showBuildTimingSummary" }.count, 1)
        XCTAssertTrue(argv.contains(mine))
        XCTAssertEqual(result.resultBundle?.path, mine)
    }

    func testOutputIsTeedIntoTheLogAndWallTimeIsMeasured() throws {
        let dir = try makeScratchDirectory()
        let state = dir.appendingPathComponent(".xcblame")
        let fake = try FakeXcodebuild.make(in: dir)
        let result = try run(fake, state: state)
        XCTAssertGreaterThanOrEqual(result.wall, 0.1)
        XCTAssertLessThan(result.wall, 5)
        let captured = try String(contentsOf: XCTUnwrap(result.capturedOutput), encoding: .utf8)
        XCTAssertTrue(captured.contains("fake xcodebuild stdout"), captured)
        XCTAssertTrue(captured.contains("fake xcodebuild stderr"), captured)
        XCTAssertEqual(try String(contentsOf: state.appendingPathComponent(".gitignore"), encoding: .utf8),
                       "history/\nsnapshots/\nreports/\nresults/\nlogs/\ncache/\ntmp/\nplans/\nbackup/\n", "baseline.json and config.json stay committable")
    }

    /// Code review v0.2 §8.3 gap: the `*` an earlier v0.2 wrote is upgraded; a file someone edited is kept.
    func testStateGitignoreUpgradesTheOldStarButKeepsEdits() throws {
        let dir = try makeScratchDirectory()
        let file = dir.appendingPathComponent(".gitignore")
        try Data("*\n".utf8).write(to: file)
        ensureStateIgnore(in: dir)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), stateIgnoreLines)
        try Data("mine\n".utf8).write(to: file)
        ensureStateIgnore(in: dir)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "mine\n")
    }

    func testSnapshotLayout() throws {
        let dir = try makeScratchDirectory()
        let state = dir.appendingPathComponent(".xcblame")
        let fake = try FakeXcodebuild.make(in: dir)
        let result = try run(fake, state: state)

        XCTAssertEqual(result.derivedData?.path, fake.derivedData.path)
        XCTAssertEqual(result.logURL?.lastPathComponent, "\(FakeXcodebuild.logUUID).xcactivitylog")
        let snapshot = try XCTUnwrap(result.snapshot, result.notes.joined(separator: "; "))
        XCTAssertEqual(snapshot.path, state.appendingPathComponent("snapshots/\(FakeXcodebuild.logUUID)").path)
        let names = try FileManager.default.contentsOfDirectory(atPath: snapshot.path).sorted()
        XCTAssertEqual(names, ["SIGNATURE", "build-request.json", "clangmodulesreport", "manifest.json.gz",
                               "swiftmodulesreport", "target-graph.txt"])
        // The gzipped manifest is the live manifest.
        let live = fake.derivedData.appendingPathComponent(
            "Build/Intermediates.noindex/XCBuildData/\(FakeXcodebuild.signature).xcbuilddata/manifest.json")
        let inflated = try GzipFile.inflate(contentsOf: snapshot.appendingPathComponent("manifest.json.gz"))
        XCTAssertTrue(inflated.trailerVerified)
        XCTAssertEqual(Data(inflated.bytes), try Data(contentsOf: live))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("clangmodulesreport/Summary.csv").path))
        XCTAssertEqual(try String(contentsOf: snapshot.appendingPathComponent("SIGNATURE"), encoding: .utf8),
                       "\(FakeXcodebuild.signature).xcbuilddata\n")
        XCTAssertFalse(result.notes.contains { $0.contains("predate") }, "\(result.notes)")
    }

    func testBuildThatWritesNoLogHasNoLogAndNoSnapshot() throws {
        let dir = try makeScratchDirectory()
        let fake = try FakeXcodebuild.make(in: dir, exitCode: 65, writeLog: false, writeDescription: false)
        let result = try run(fake, state: dir.appendingPathComponent(".xcblame"))
        XCTAssertEqual(result.exitCode, 65)
        XCTAssertNil(result.logURL)
        XCTAssertNil(result.snapshot)
        XCTAssertTrue(result.notes.contains { $0.contains(".xcactivitylog") }, "\(result.notes)")
    }

    func testLogOlderThanTheBuildIsNotPicked() throws {
        let dir = try makeScratchDirectory()
        let fake = try FakeXcodebuild.make(in: dir, writeLog: false, writeDescription: false)
        let logs = fake.derivedData.appendingPathComponent("Logs/Build")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let stale = logs.appendingPathComponent("\(FakeXcodebuild.logUUID).xcactivitylog")
        try FileManager.default.copyItem(
            at: FakeXcodebuild.fixtures.appendingPathComponent("\(FakeXcodebuild.logUUID).xcactivitylog"), to: stale)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: stale.path)
        let result = try run(fake, state: dir.appendingPathComponent(".xcblame"))
        XCTAssertNil(result.logURL)
        XCTAssertTrue(result.notes.contains { $0.contains("1 older ones ignored") }, "\(result.notes)")
    }

    func testReusedBuildDescriptionIsSnapshottedWithANote() throws {
        let dir = try makeScratchDirectory()
        let state = dir.appendingPathComponent(".xcblame")
        let first = try FakeXcodebuild.make(in: dir)
        _ = try run(first, state: state)
        // A second build that writes only a log: the description from the first one is still the newest.
        let description = first.derivedData.appendingPathComponent("Build/Intermediates.noindex/XCBuildData")
        for url in try FileManager.default.contentsOfDirectory(at: description, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                                  ofItemAtPath: url.path)
        }
        let second = try FakeXcodebuild.make(in: dir, writeDescription: false)
        let result = try run(second, state: state)
        XCTAssertNotNil(result.snapshot)
        XCTAssertTrue(result.notes.contains { $0.contains("predate") }, "\(result.notes)")
    }

    /// Code review v0.2 #2: D822889B reused its description 6f0b463d (older); the build also leaves a newer 05e6f8da
    /// in XCBuildData. The snapshot is the one the log names, not the newest.
    func testReusedDescriptionIsPickedByTheLogsSignatureNotByMtime() throws {
        let dir = try makeScratchDirectory()
        let state = dir.appendingPathComponent(".xcblame")
        let logs = FakeXcodebuild.fixtures.deletingLastPathComponent().appendingPathComponent("cli-xcode26")
        let fake = try FakeXcodebuild.make(in: dir, log: logs.appendingPathComponent(
            "D822889B-3D9A-478F-BB03-AB98C3967FD1.xcactivitylog"))
        let own = fake.derivedData.appendingPathComponent(
            "Build/Intermediates.noindex/XCBuildData/6f0b463d2f2edd5a58b553713dc8313d.xcbuilddata")
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: logs.appendingPathComponent("xcbuilddata/manifest.json"),
                                         to: own.appendingPathComponent("manifest.json"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: own.path)
        let result = try run(fake, state: state)
        let snapshot = try XCTUnwrap(result.snapshot, result.notes.joined(separator: "; "))
        XCTAssertEqual(try String(contentsOf: snapshot.appendingPathComponent("SIGNATURE"), encoding: .utf8),
                       "6f0b463d2f2edd5a58b553713dc8313d.xcbuilddata\n")
        XCTAssertTrue(result.notes.contains { $0.contains("matched by the log's signature") }, "\(result.notes)")
        let description = try XCTUnwrap(BuildDescriptionLocator.find(
            model: BuildModelBuilder.build(try SLFReader.read(url: XCTUnwrap(result.logURL)), reader: .slf),
            logURL: result.logURL, explicit: nil, snapshotsDir: state.appendingPathComponent("snapshots")))
        XCTAssertEqual(description.basis, "snapshot")
        XCTAssertEqual(description.signature, "6f0b463d2f2edd5a58b553713dc8313d")
    }

    func testTimeoutKillsTheBuildAndReports124() throws {
        let dir = try makeScratchDirectory()
        let fake = try FakeXcodebuild.make(in: dir, sleep: "30")
        let result = try run(fake, state: dir.appendingPathComponent(".xcblame"), timeout: 0.5)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.exitCode, XcodebuildRunner.timeoutExitCode)
        XCTAssertEqual(result.exitCode, 124)
        XCTAssertLessThan(result.wall, 10)
        XCTAssertTrue(result.notes.contains { $0.hasPrefix("timeout:") }, "\(result.notes)")
    }

    func testMissingExecutableThrows() throws {
        let dir = try makeScratchDirectory()
        XCTAssertThrowsError(try XcodebuildRunner.run(
            arguments: [], xcblameDir: dir.appendingPathComponent(".xcblame"), timeout: nil,
            executable: dir.appendingPathComponent("no-such-xcodebuild"), executablePrefix: [])) { error in
            XCTAssertTrue("\(error)".contains("could not run xcodebuild"), "\(error)")
        }
    }

    func testStateFolderThatCannotBeCreatedDoesNotStopTheBuild() throws {
        let dir = try makeScratchDirectory()
        let fake = try FakeXcodebuild.make(in: dir, exitCode: 0)
        // A file where the state folder should be.
        let blocker = dir.appendingPathComponent("state-is-a-file")
        try Data("x".utf8).write(to: blocker)
        let result = try run(fake, state: blocker)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.notes.contains { $0.contains("cannot create") }, "\(result.notes)")
        let argv = try fake.recordedArguments()
        XCTAssertFalse(argv.contains("-resultBundlePath"))
        XCTAssertTrue(argv.contains("-showBuildTimingSummary"))
    }

    func testThermalNoteOnlyWhenThrottled() {
        XCTAssertNil(ThermalProbe.note(before: nil, after: nil))
        XCTAssertNil(ThermalProbe.note(before: "Note: No thermal warning level has been recorded", after: nil))
        XCTAssertNil(ThermalProbe.note(before: "CPU_Speed_Limit \t= 100", after: nil))
        XCTAssertNotNil(ThermalProbe.note(before: "CPU_Scheduler_Limit \t= 100", after: "CPU_Speed_Limit \t= 70"))
    }
}
