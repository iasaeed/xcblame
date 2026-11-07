import Foundation
import XCTest
@testable import XcblameKit

/// `xcblame build --overlay [<plan-id>] [--overlay-unverified]` (v0.6 fix round 1, review gap 1; DESIGN §3.2, §7.5)
/// with a fake xcodebuild: `-showBuildSettings` answers from the overlay file the wrapper includes (or a shadowed value
/// with `FAKE_SHADOW`), a build writes the fixture log. Every call is recorded with the `XCODE_XCCONFIG_FILE` it saw.
final class BuildOverlayCLITests: XCTestCase {
    private struct Setup {
        var harness: BuildCLIHarness
        var record: URL
        var environment: [String: String]
        var planId = "0ver1a70"
    }

    private func setup(status: FixPlanDocument.VerifyStatus = .kept) throws -> Setup {
        let harness = try BuildCLIHarness.make(for: self)
        let record = harness.directory.appendingPathComponent("calls.txt")
        let script = harness.directory.appendingPathComponent("fake-overlay-xcodebuild.sh")
        try Data(#"""
        #!/bin/sh
        LOG='\#(record.path)'
        echo "--- call" >> "$LOG"
        for a in "$@"; do echo "$a" >> "$LOG"; done
        echo "ENV XCODE_XCCONFIG_FILE=${XCODE_XCCONFIG_FILE:-unset}" >> "$LOG"
        XC=""; SHOW=0; prev=""
        for a in "$@"; do
          [ "$prev" = "-xcconfig" ] && XC="$a"
          [ "$a" = "-showBuildSettings" ] && SHOW=1
          prev="$a"
        done
        if [ $SHOW = 1 ]; then
          VALUE="dwarf-with-dsym"
          if [ -n "$XC" ] && [ -z "$FAKE_SHADOW" ]; then
            for inc in $(sed -n 's/^#include "\(.*\)"$/\1/p' "$XC"); do
              V=$(sed -n 's/^DEBUG_INFORMATION_FORMAT = \([^ ]*\) .*/\1/p' "$inc")
              [ -n "$V" ] && VALUE="$V"
            done
          fi
          echo "[{\"target\":\"App\",\"action\":\"build\",\"buildSettings\":{\"PROJECT_NAME\":\"App\",\"DEBUG_INFORMATION_FORMAT\":\"$VALUE\"}}]"
          exit 0
        fi
        exec '\#(harness.script.path)' "$@"
        """#.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try Data("SWIFT_VERSION = 6.0\n".utf8).write(to: harness.directory.appendingPathComponent("user.xcconfig"))
        // The container the build names (found in the working folder): only its plans are delivered.
        try FileManager.default.createDirectory(at: harness.directory.appendingPathComponent("App.xcodeproj"),
                                                withIntermediateDirectories: true)

        // A stored plan with one SET-004 step (what fix + verify leave).
        let setup = Setup(harness: harness, record: record, environment: ["XCBLAME_XCODEBUILD": script.path])
        let line = "DEBUG_INFORMATION_FORMAT = dwarf // xcblame SET-004 (plan \(setup.planId))"
        let step = FixPlanDocument.Step(
            order: 1, ruleId: "SET-004", title: "dSYM in Debug", fixKind: .overlay, mechanism: .cli, confidence: "high",
            verifyOnly: false,
            scope: [.init(target: "App", configuration: "Debug", key: "DEBUG_INFORMATION_FORMAT", before: "dwarf-with-dsym",
                          after: "dwarf", provenance: nil, mechanism: .cli, reached: true)],
            overlay: [.init(configuration: "Debug", key: "DEBUG_INFORMATION_FORMAT", value: "dwarf", line: line)],
            verify: .init(status: status, mechanism: .cli, kind: "clean"))
        let plan = FixPlanDocument(
            tool: ReportDocument.Tool(name: "xcblame", version: XcblameVersion.current, kindTable: KindTable.v1.version),
            generatedAt: Date(), id: setup.planId,
            generatedFrom: .init(analysisId: nil, analysisPath: nil, analysisKind: nil, doctorConfigurations: ["Debug"],
                                 settingsSource: "offline", rulesFilter: []),
            project: .init(container: harness.directory.appendingPathComponent("App.xcodeproj").path, generator: nil,
                           configurations: ["Debug"], scheme: "App"),
            steps: [step])
        try FixPlanStore.save(plan, xcblameDir: harness.state)
        return setup
    }

    private func calls(_ setup: Setup) throws -> [(argv: [String], xcconfigFile: String)] {
        let text = try String(contentsOf: setup.record, encoding: .utf8)
        return text.components(separatedBy: "--- call\n").dropFirst().map { block in
            var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last == "" { lines.removeLast() }
            let env = lines.removeLast()
            return (lines, String(env.dropFirst("ENV XCODE_XCCONFIG_FILE=".count)))
        }
    }

    private func build(_ setup: Setup, _ extra: [String] = [], environment: [String: String] = [:])
        throws -> (run: BuildCLIHarness.Run, document: [String: Any]?) {
        let output = setup.harness.directory.appendingPathComponent("report.json")
        let run = try setup.harness.run(self, ["build", "--overlay"] + extra + ["--format", "json", "-o", output.path, "--",
                                               "-scheme", "App", "-configuration", "Debug", "-xcconfig", "user.xcconfig",
                                               "-derivedDataPath", setup.harness.derivedData.path],
                                        environment: setup.environment.merging(environment) { $1 })
        let document = (try? Data(contentsOf: output)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (run, document)
    }

    func testHelpAndUsageErrors() throws {
        let help = try CLIRunner(test: self).run(["build", "--help"])
        XCTAssertEqual(help.status, 0, help.err)
        for text in ["--overlay", "--overlay-unverified", "<overlay-plan>", "-configuration"] {
            XCTAssertTrue(help.out.contains(text), "\(text) missing from build --help:\n\(help.out)")
        }
        let cli = CLIRunner(test: self)
        for arguments in [["build", "abc123", "--", "-scheme", "App"],
                          ["build", "--overlay-unverified", "--", "-scheme", "App", "-configuration", "Debug"],
                          ["build", "--overlay", "--", "-scheme", "App"]] {
            XCTAssertEqual(try cli.run(arguments, environment: ["XCBLAME_XCODEBUILD": "/usr/bin/false"]).status, 2,
                           arguments.joined(separator: " "))
        }
    }

    /// The wrapper (§7.5 order: the user's -xcconfig, XCODE_XCCONFIG_FILE, the overlay), the oracle with the wrapper and
    /// the variable unset, then the build through the wrapper; the report notes `overlay: <plan-id>`.
    func testOverlayIsDeliveredThroughTheWrapper() throws {
        let setup = try setup()
        let global = setup.harness.directory.appendingPathComponent("global.xcconfig")
        try Data("ONLY_ACTIVE_ARCH = YES\n".utf8).write(to: global)
        let (run, document) = try build(setup, environment: ["XCODE_XCCONFIG_FILE": global.path])
        XCTAssertEqual(run.status, 0, run.err)

        let state = setup.harness.state
        let overlay = state.appendingPathComponent("tmp/build-overlay-Debug.xcconfig")
        XCTAssertEqual(try String(contentsOf: overlay, encoding: .utf8).components(separatedBy: "\n").dropFirst().first,
                       "DEBUG_INFORMATION_FORMAT = dwarf // xcblame SET-004 (plan \(setup.planId))")
        let wrapper = state.appendingPathComponent("tmp/wrapper-Debug.xcconfig")
        let lines = try String(contentsOf: wrapper, encoding: .utf8).split(separator: "\n").map(String.init).dropFirst()
        XCTAssertEqual(Array(lines), ["#include \"\(setup.harness.directory.appendingPathComponent("user.xcconfig").path)\"",
                                      "#include \"\(global.path)\"", "#include \"\(overlay.path)\""])

        let calls = try calls(setup)
        XCTAssertEqual(calls.count, 2, "oracle with the wrapper, then the build")
        XCTAssertTrue(calls[0].argv.contains("-showBuildSettings"))
        XCTAssertEqual(calls[0].xcconfigFile, "unset")
        XCTAssertFalse(calls[1].argv.contains("-showBuildSettings"))
        XCTAssertFalse(calls[1].argv.contains("user.xcconfig"), "the wrapper includes it")
        XCTAssertEqual(calls[1].argv[calls[1].argv.firstIndex(of: "-xcconfig")! + 1], wrapper.path)
        XCTAssertEqual(calls[1].xcconfigFile, "unset")

        let notes = (document?["build"] as? [String: Any])?["notes"] as? [String] ?? []
        XCTAssertTrue(notes.contains { $0.hasPrefix("overlay: \(setup.planId) (SET-004 for Debug") && $0.contains("every key won") },
                      "\(notes)")
    }

    /// A key that does not win in the oracle with the wrapper: an error naming it, nothing built.
    func testOracleRefusesWhenAKeyDoesNotWin() throws {
        let setup = try setup()
        let (run, _) = try build(setup, environment: ["FAKE_SHADOW": "1"])
        XCTAssertEqual(run.status, 1, run.err)
        XCTAssertTrue(run.err.contains("a key did not win (App: DEBUG_INFORMATION_FORMAT is dwarf-with-dsym, not dwarf)"), run.err)
        XCTAssertTrue(run.err.contains("the build did not run"), run.err)
        XCTAssertEqual(try calls(setup).filter { !$0.argv.contains("-showBuildSettings") }.count, 0, "no build")
        XCTAssertTrue(setup.harness.historyEntries.isEmpty)
    }

    /// Unverified steps go only with --overlay-unverified; a reverted one never.
    func testUnverifiedNeedsTheFlagAndRevertedIsNeverDelivered() throws {
        let unverified = try setup(status: .unverified)
        let refused = try build(unverified)
        XCTAssertEqual(refused.run.status, 2, refused.run.err)
        XCTAssertTrue(refused.run.err.contains("no plan for"), refused.run.err)
        XCTAssertEqual(try build(unverified, ["--overlay-unverified", unverified.planId]).run.status, 0)

        let reverted = try setup(status: .reverted)
        let never = try build(reverted, ["--overlay-unverified", reverted.planId])
        XCTAssertEqual(never.run.status, 1, never.run.err)
        XCTAssertTrue(never.run.err.contains("nothing to deliver for Debug"), never.run.err)
        XCTAssertTrue(never.run.err.contains("verify reverted it"), never.run.err)
    }

    /// Fix round 2, finding 3: another container's plan in the shared xcblame dir is never delivered (exit 2, nothing
    /// built), unless its id is given.
    func testAnotherContainersPlanIsNotDelivered() throws {
        let setup = try setup()
        var plan = try FixPlanStore.load(id: setup.planId, xcblameDir: setup.harness.state)
        plan.project.container = "/elsewhere/Other.xcodeproj"
        try FixPlanStore.save(plan, xcblameDir: setup.harness.state)
        let (run, _) = try build(setup)
        XCTAssertEqual(run.status, 2, run.err)
        XCTAssertTrue(run.err.contains("no plan for ") && run.err.contains("/App.xcodeproj with a kept overlay step"),
                      run.err)
        XCTAssertTrue(run.err.contains("run xcblame fix"), run.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: setup.record.path), "xcodebuild never ran")
    }
}
