import XCTest
@testable import XcblameKit

/// `WhyProcedure` with a fake xcodebuild that writes one fixture log per call (docs/SCHEMA-v0.5.md "why"). Never runs
/// a real xcodebuild.
final class WhyProcedureTests: XCTestCase {
    /// A fake xcodebuild: call n records its argv and the backtrace variable, then copies `logs[n-1]` (the last one
    /// again past the end) into `<dir>/dd/Logs/Build` and exits with `codes[n-1]` (0 past the end).
    struct SequenceFake {
        var directory: URL
        var script: URL
        var derivedData: URL

        static func make(for test: XCTestCase, logs: [URL], codes: [Int32] = []) throws -> SequenceFake {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("xcblame-whyproc-\(UUID().uuidString)").resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            test.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
            let dd = directory.appendingPathComponent("dd")
            var lines = [
                "#!/bin/sh",
                "dir='\(directory.path)'",
                "n=$(cat \"$dir/count\" 2>/dev/null || echo 0)",
                "n=$((n + 1))",
                "echo $n > \"$dir/count\"",
                "printf '%s\\n' \"$@\" > \"$dir/argv-$n.txt\"",
                "echo \"${EnableBuildBacktraceRecording:-unset}\" > \"$dir/env-$n.txt\"",
                "mkdir -p '\(dd.path)/Logs/Build'",
                "case $n in",
            ]
            for (index, log) in logs.enumerated() {
                let pattern = index == logs.count - 1 ? "*" : "\(index + 1)"
                lines.append("  \(pattern)) cp '\(log.path)' '\(dd.path)/Logs/Build/' ; code=\(index < codes.count ? codes[index] : 0) ;;")
            }
            lines += ["esac", "exit $code"]
            let script = directory.appendingPathComponent("fake-xcodebuild.sh")
            try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: script)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            return SequenceFake(directory: directory, script: script, derivedData: dd)
        }

        func calls() -> Int { Int((try? String(contentsOf: directory.appendingPathComponent("count"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0 }
        func argv(_ n: Int) throws -> [String] {
            try String(contentsOf: directory.appendingPathComponent("argv-\(n).txt"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
        }
        func backtraceVariable(_ n: Int) throws -> String {
            try String(contentsOf: directory.appendingPathComponent("env-\(n).txt"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var arguments: [String] { ["-project", "App.xcodeproj", "-scheme", "App", "-derivedDataPath", derivedData.path, "build"] }
    }

    private func options(_ fake: SequenceFake, touch: String? = nil, backtraces: Bool = false,
                         showIncremental: Bool = false) -> WhyProcedure.Options {
        WhyProcedure.Options(arguments: fake.arguments, xcblameDir: fake.directory.appendingPathComponent(".xcblame"),
                             touch: touch, showIncremental: showIncremental, backtraces: backtraces, timeout: 60,
                             executable: fake.script)
    }

    func testZeroChangeProcedureRunsTheRepeatAndFindsDYN002() throws {
        let set = WhyFixtures.why26
        // settle, measure (compiles: not settled), repeat (compiles again): DYN-002.
        let fake = try SequenceFake.make(for: self, logs: [set.clean, set.incremental, WhyFixtures.remarks26.incremental])
        XCTAssertNil(ProcessInfo.processInfo.environment[WhyProcedure.backtraceVariable])
        let result = try WhyProcedure.run(options(fake, backtraces: true, showIncremental: true))
        XCTAssertEqual(fake.calls(), 3)
        XCTAssertEqual(result.steps.map(\.role), ["settle", "measure", "repeat"])
        XCTAssertTrue(result.dyn002)
        XCTAssertEqual(result.procedure.mode, "zeroChange")
        XCTAssertEqual(result.procedure.backtraces, "on")
        XCTAssertTrue(result.procedure.showIncremental)
        XCTAssertEqual(result.procedure.builds.map(\.role), ["settle", "measure", "repeat"])
        XCTAssertGreaterThan(try XCTUnwrap(result.procedure.builds[1].executedWorkTasks), 0)
        XCTAssertEqual(result.measured.logURL?.lastPathComponent, set.incremental.lastPathComponent)
        for n in 1...3 {
            // The same mechanism on every build (MV-2), and the driver flag on the command line.
            XCTAssertEqual(try fake.backtraceVariable(n), "YES", "build \(n)")
            XCTAssertTrue(try fake.argv(n).contains("OTHER_SWIFT_FLAGS=$(inherited) -driver-show-incremental"))
        }
        XCTAssertNil(ProcessInfo.processInfo.environment[WhyProcedure.backtraceVariable],
                     "only the children's environment carries it (XcodebuildRunner environment:)")

        var document = try WhyFixtures.report(set.incremental).document
        document = DYN002.applying(to: document, result: result)
        let finding = try XCTUnwrap(document.findings.first { $0.ruleId == "DYN-002" })
        XCTAssertTrue(finding.evidence.contains { $0.hasPrefix("repeat zero-change build executed") })
        XCTAssertEqual(document.ruleDocs["DYN-002"]?.title, "unstable-inputs")
        XCTAssertEqual(document.findingsTotal, document.findings.count)
    }

    func testZeroChangeWithoutWorkNeedsNoRepeat() throws {
        let set = WhyFixtures.why26
        let fake = try SequenceFake.make(for: self, logs: [set.clean, set.zeroChange])
        let result = try WhyProcedure.run(options(fake))
        XCTAssertEqual(result.steps.map(\.role), ["settle", "measure"])
        XCTAssertFalse(result.dyn002)
        XCTAssertEqual(result.procedure.backtraces, "off")
        XCTAssertEqual(try fake.backtraceVariable(1), "unset")
        XCTAssertFalse(try fake.argv(2).contains { $0.hasPrefix("OTHER_SWIFT_FLAGS") })
        XCTAssertEqual(DYN002.applying(to: try syntheticReport(), result: result).findings.count, 0)
    }

    func testTouchModeBumpsOnlyTheModificationTime() throws {
        let set = WhyFixtures.why27
        let fake = try SequenceFake.make(for: self, logs: [set.clean, set.incremental])
        let file = fake.directory.appendingPathComponent("Core.swift")
        try Data("let core = 1\n".utf8).write(to: file)
        let old = Date(timeIntervalSinceNow: -3_600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        let result = try WhyProcedure.run(options(fake, touch: file.path))
        XCTAssertEqual(result.procedure.mode, "touch")
        XCTAssertEqual(result.procedure.touched, file.standardizedFileURL.path)
        XCTAssertEqual(result.steps.map(\.role), ["settle", "measure"], "no DYN-002 repeat in touch mode")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "let core = 1\n")
        let mtime = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        XCTAssertGreaterThan(mtime, old.addingTimeInterval(60))
        XCTAssertTrue(result.notes.contains { $0.contains("mtime-only touch") })
        XCTAssertTrue(result.notes.contains(CauseEngine.touchNote), "the touch is not a real edit, and the note says so")
        XCTAssertThrowsError(try WhyProcedure.run(options(fake, touch: "/no/such/file.swift"))) { error in
            XCTAssertEqual(error as? XcblameError, .usage("--touch /no/such/file.swift: no such file"))
        }
    }

    func testAFailedBuildAbortsWithItsRole() throws {
        let set = WhyFixtures.why26
        let fake = try SequenceFake.make(for: self, logs: [set.clean, set.incremental], codes: [0, 65])
        XCTAssertThrowsError(try WhyProcedure.run(options(fake))) { error in
            guard case let WhyProcedure.ProcedureError.buildFailed(role, code) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(role, "measure")
            XCTAssertEqual(code, 65)
            XCTAssertTrue("\(error)".contains("the measure build failed (xcodebuild exit code 65)"))
        }
    }

    func testPrepare() throws {
        let set = WhyFixtures.why26
        let fake = try SequenceFake.make(for: self, logs: [set.clean])
        try WhyProcedure.prepare(kind: .clean, touch: nil, arguments: fake.arguments,
                                 xcblameDir: fake.directory.appendingPathComponent(".xcblame"), timeout: 60,
                                 executable: fake.script)
        let argv = try fake.argv(1)
        XCTAssertTrue(argv.contains("clean"), "\(argv)")
        XCTAssertFalse(argv.contains("build"), "the build action is replaced")
        XCTAssertTrue(argv.contains("App.xcodeproj"))

        let file = fake.directory.appendingPathComponent("A.swift")
        try Data("a".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -600)], ofItemAtPath: file.path)
        try WhyProcedure.prepare(kind: nil, touch: file.path, arguments: fake.arguments,
                                 xcblameDir: fake.directory.appendingPathComponent(".xcblame"), timeout: 60,
                                 executable: fake.script)
        XCTAssertTrue(try fake.argv(2).contains("build"))
        let mtime = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        XCTAssertGreaterThan(mtime.timeIntervalSinceNow, -60, "--touch alone means incremental: build, then touch")
        try WhyProcedure.prepare(kind: nil, touch: nil, arguments: fake.arguments, xcblameDir: fake.directory,
                                 timeout: 60, executable: fake.script)
        XCTAssertEqual(fake.calls(), 2, "nothing to prepare")
    }

    /// `build --kind incremental|zero-change` / `--touch`: the preparation build records Task Backtraces like `why`.
    func testPrepareRecordsBacktracesWhenAsked() throws {
        let fake = try SequenceFake.make(for: self, logs: [WhyFixtures.why26.clean])
        let state = fake.directory.appendingPathComponent(".xcblame")
        try WhyProcedure.prepare(kind: .zeroChange, touch: nil, arguments: fake.arguments, xcblameDir: state,
                                 timeout: 60, executable: fake.script, backtraces: true)
        try WhyProcedure.prepare(kind: .zeroChange, touch: nil, arguments: fake.arguments, xcblameDir: state,
                                 timeout: 60, executable: fake.script)
        XCTAssertEqual(try fake.backtraceVariable(1), "YES")
        XCTAssertEqual(try fake.backtraceVariable(2), "unset")
    }

    /// v0.5 integration: with an xcblame wrapper already on the arguments (`--deep`), the remark flag becomes a wrapper
    /// line in the same `$(inherited)` chain instead of a command-line setting; without one it stays on the command line.
    func testShowIncrementalComposesWithAWrapper() throws {
        let set = WhyFixtures.why26
        let fake = try SequenceFake.make(for: self, logs: [set.clean, set.zeroChange])
        let state = fake.directory.appendingPathComponent(".xcblame")
        let plan = try WrapperXCConfig.plan(arguments: fake.arguments, environment: [:], overlay: nil,
                                            lines: ["OTHER_SWIFT_FLAGS = $(inherited) -Xfrontend -debug-time-function-bodies // xcblame --deep"],
                                            xcblameDir: state)
        try WrapperXCConfig.write(plan)
        XCTAssertEqual(WrapperXCConfig.existing(in: plan.arguments, xcblameDir: state), plan.url)
        XCTAssertNil(WrapperXCConfig.existing(in: fake.arguments, xcblameDir: state))
        XCTAssertNil(WrapperXCConfig.existing(in: ["-xcconfig", "/elsewhere/wrapper-Debug.xcconfig"], xcblameDir: state))

        var options = options(fake, showIncremental: true)
        options.arguments = plan.arguments
        let result = try WhyProcedure.run(options)
        XCTAssertEqual(result.steps.map(\.role), ["settle", "measure"])
        for n in 1...2 {
            let argv = try fake.argv(n)
            XCTAssertFalse(argv.contains { $0.hasPrefix("OTHER_SWIFT_FLAGS") }, "no command-line setting: \(argv)")
            XCTAssertTrue(argv.contains(plan.url.path))
        }
        let text = try String(contentsOf: plan.url, encoding: .utf8)
        let lines = text.split(separator: "\n").filter { $0.hasPrefix("OTHER_SWIFT_FLAGS") }
        XCTAssertEqual(lines, ["OTHER_SWIFT_FLAGS = $(inherited) -Xfrontend -debug-time-function-bodies // xcblame --deep",
                               "OTHER_SWIFT_FLAGS = $(inherited) -driver-show-incremental // xcblame why --show-incremental"],
                       "appended once, after the deep line: \(text)")
        XCTAssertTrue(result.notes.contains { $0.contains("as a line of the xcblame wrapper xcconfig") }, "\(result.notes)")
        _ = try WhyProcedure.withRemarkFlag(plan.arguments, xcblameDir: state)
        XCTAssertEqual(try String(contentsOf: plan.url, encoding: .utf8), text, "idempotent")
        XCTAssertEqual(try WhyProcedure.withRemarkFlag(["-scheme", "A"], xcblameDir: state),
                       ["-scheme", "A", "OTHER_SWIFT_FLAGS=$(inherited) -driver-show-incremental"])
    }

    func testArgumentRewrites() {
        XCTAssertEqual(WhyProcedure.withAction("clean", ["-scheme", "App", "build", "-quiet", "CODE_SIGNING_ALLOWED=NO"]),
                       ["-scheme", "App", "-quiet", "CODE_SIGNING_ALLOWED=NO", "clean"])
        XCTAssertEqual(WhyProcedure.withAction("clean", ["-destination", "platform=macOS", "test"]),
                       ["-destination", "platform=macOS", "clean"])
        // Boolean flags never take the action word as their value (`--kind clean` must not run `build clean`).
        for flag in ["-parallelizeTargets", "-skipUnavailableActions", "-skipPackageUpdates", "-json", "-UseModernBuildSystem"] {
            XCTAssertEqual(WhyProcedure.withAction("clean", ["-scheme", "App", flag, "build"]), ["-scheme", "App", flag, "clean"],
                           flag)
        }
        XCTAssertEqual(WhyProcedure.withAction("clean", ["-scheme", "build"]), ["-scheme", "build", "clean"],
                       "a flag with a value keeps it, even when it is an action word")
        XCTAssertEqual(WhyProcedure.withSwiftFlag("-x", ["-scheme", "A"]), ["-scheme", "A", "OTHER_SWIFT_FLAGS=$(inherited) -x"])
        XCTAssertEqual(WhyProcedure.withSwiftFlag("-x", ["OTHER_SWIFT_FLAGS=-DFOO"]), ["OTHER_SWIFT_FLAGS=-DFOO -x"])
    }
}
