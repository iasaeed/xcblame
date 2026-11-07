import Foundation
import XCTest
@testable import XcblameKit

/// `xcblame verify` (docs/SCHEMA-v0.6.md "`xcblame verify`"): flag parsing and exit codes 0, 1, 2 and 6, driven by a
/// fake xcodebuild (`XCBLAME_XCODEBUILD`) and a fixed machine (`XCBLAME_VERIFY_HOST`), plus `history prune` of the
/// verify entries.
final class VerifyCLITests: XCTestCase {
    private var cli: CLIRunner { CLIRunner(test: self) }
    private let host = "power=ac,xcodebuild=none,thermal=nominal"

    private struct Scratch {
        var root: URL
        var xcblameDir: URL
        var plan: FixPlanDocument
    }

    /// A temp xcblame dir with one stored plan (SET-004, cli) and a fake xcodebuild exiting `exit`.
    private func scratch(exit: Int32 = 0, mechanism: FixPlanDocument.Mechanism = .cli) throws -> (Scratch, [String: String]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-verify-cli-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        let xcblameDir = root.appendingPathComponent(".xcblame")
        try FileManager.default.createDirectory(at: xcblameDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fake-xcodebuild")
        try Data("#!/bin/sh\nexit \(exit)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let step = FixPlanDocument.Step(
            order: 1, ruleId: "SET-004", title: "Debug builds generate dSYM files", fixKind: .overlay, mechanism: mechanism,
            confidence: "high", verifyOnly: false, verifyKind: "clean",
            scope: [.init(target: "Acme", configuration: "Debug", key: "DEBUG_INFORMATION_FORMAT", before: "dwarf-with-dsym",
                          after: "dwarf", provenance: nil, mechanism: .cli, reached: true)],
            overlay: [.init(configuration: "Debug", key: "DEBUG_INFORMATION_FORMAT", value: "dwarf",
                            line: "DEBUG_INFORMATION_FORMAT = dwarf // xcblame SET-004 (plan 1a2b3c4d)")])
        let plan = FixPlanDocument(
            tool: ReportDocument.Tool(name: "xcblame", version: XcblameVersion.current, kindTable: KindTable.v1.version),
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000), id: "1a2b3c4d",
            generatedFrom: .init(analysisId: nil, analysisPath: nil, analysisKind: nil, doctorConfigurations: ["Debug"],
                                 settingsSource: "offline", rulesFilter: []),
            project: .init(container: root.appendingPathComponent("Acme.xcodeproj").path, generator: nil,
                           configurations: ["Debug"], scheme: "Acme"),
            steps: [step])
        try FixPlanStore.save(plan, xcblameDir: xcblameDir)
        return (Scratch(root: root, xcblameDir: xcblameDir, plan: plan),
                ["XCBLAME_XCODEBUILD": script.path, "XCBLAME_VERIFY_HOST": host])
    }

    private let xcodebuild = ["--", "-project", "Acme.xcodeproj", "-scheme", "Acme", "-configuration", "Debug", "build"]

    func testHelpListsFlags() throws {
        let help = try cli.run(["verify", "--help"])
        XCTAssertEqual(help.status, 0, help.err)
        for flag in ["--runs", "--kind", "--touch", "--rules", "--one-by-one", "--keep-on-tie", "--max-minutes",
                     "--mechanism", "--plan", "--xcblame-dir", "--format", "--output", "--open", "xcodebuild-arguments"] {
            XCTAssertTrue(help.out.contains(flag), "\(flag) missing from verify --help:\n\(help.out)")
        }
        XCTAssertTrue(try cli.run(["--help"]).out.contains("verify"))
    }

    func testValidationExitsUsage() throws {
        for arguments in [["verify", "--runs", "0"], ["verify", "--kind", "warm"], ["verify", "--mechanism", "defaults"],
                          ["verify", "--touch", "A.swift"], ["verify", "--max-minutes", "0"], ["verify", "--format", "github"],
                          ["verify", "--rules", "NOPE-1"]] {
            let run = try cli.run(arguments)
            XCTAssertEqual(run.status, 2, "\(arguments): \(run.err)")
        }
    }

    func testThePlanCommandParsesAndNeedsAStoredPlan() throws {
        // The fix plan prints this exact command (FindingBuilder): it parses, then asks for a plan.
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-verify-empty-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: empty) }
        let run = try cli.run(["verify", "--rules", "SET-016", "--kind", "clean", "--mechanism", "hook",
                               "--xcblame-dir", empty.path], environment: ["XCBLAME_VERIFY_HOST": host])
        XCTAssertEqual(run.status, 1, run.err)
        XCTAssertTrue(run.err.contains("no stored fix plan") && run.err.contains("xcblame fix --rules SET-016"), run.err)
        let unknownPlan = try cli.run(["verify", "--plan", "ffff", "--xcblame-dir", empty.path])
        XCTAssertEqual(unknownPlan.status, 2, unknownPlan.err)
    }

    func testFinishedRunExitsZeroAndRecords() throws {
        let (scratch, environment) = try scratch()
        let json = try cli.run(["verify", "--runs", "1", "--format", "json", "--xcblame-dir", scratch.xcblameDir.path] + xcodebuild,
                               environment: environment)
        XCTAssertEqual(json.status, 0, json.err)
        let document = try JSONReporter.decoder().decode(VerifyDocument.self, from: Data(json.out.utf8))
        XCTAssertEqual(document.schemaVersion, "xcblame.verify/1")
        XCTAssertEqual(document.planId, "1a2b3c4d")
        XCTAssertEqual(document.results.map(\.verdict.status), [.indicative])
        XCTAssertEqual(document.results.first?.mechanism, .cli)
        XCTAssertEqual(document.results.first?.arms.map(\.runsOk), [1, 1])
        XCTAssertTrue(json.err.contains("note: verifying plan 1a2b3c4d"), json.err)
        let stored = try FixPlanStore.load(id: "1a2b3c4d", xcblameDir: scratch.xcblameDir)
        XCTAssertEqual(stored.steps[0].verify.status, .indicative)
        XCTAssertEqual(stored.steps[0].verify.verifyId, document.id)
        XCTAssertEqual(History.listVerify(directory: scratch.xcblameDir.appendingPathComponent("history")).map(\.id), [document.id])

        let text = try cli.run(["verify", "--runs", "1", "--rules", "SET-004", "--xcblame-dir", scratch.xcblameDir.path] + xcodebuild,
                               environment: environment)
        XCTAssertEqual(text.status, 0, text.err)
        XCTAssertTrue(text.out.contains("ARM") && text.out.contains("SET-004") && text.out.contains("verdict indicative"), text.out)

        let file = scratch.root.appendingPathComponent("verify.json")
        let written = try cli.run(["verify", "--runs", "1", "--format", "json", "-o", file.path,
                                   "--xcblame-dir", scratch.xcblameDir.path] + xcodebuild, environment: environment)
        XCTAssertEqual(written.status, 0, written.err)
        XCTAssertTrue(written.out.hasPrefix("wrote \(file.path) (json"), written.out)
        XCTAssertNoThrow(try JSONReporter.decoder().decode(VerifyDocument.self, from: Data(contentsOf: file)))
    }

    func testAbortsExitSix() throws {
        let (broken, brokenEnvironment) = try scratch(exit: 65)
        let baseline = try cli.run(["verify", "--format", "json", "--xcblame-dir", broken.xcblameDir.path] + xcodebuild,
                                   environment: brokenEnvironment)
        XCTAssertEqual(baseline.status, 6, baseline.err)
        XCTAssertTrue(baseline.err.contains("verify aborted (baselineBroken)"), baseline.err)
        let document = try JSONReporter.decoder().decode(VerifyDocument.self, from: Data(baseline.out.utf8))
        XCTAssertEqual(document.abort?.reason, .baselineBroken)

        let (hook, hookEnvironment) = try scratch()
        let missing = try cli.run(["verify", "--mechanism", "hook", "--xcblame-dir", hook.xcblameDir.path] + xcodebuild,
                                  environment: hookEnvironment)
        XCTAssertEqual(missing.status, 6, missing.err)
        XCTAssertTrue(missing.err.contains("hookMissing"), missing.err)
        XCTAssertTrue(missing.out.contains("ABORTED  The hook is not installed"), missing.out)

        var battery = hookEnvironment
        battery["XCBLAME_VERIFY_HOST"] = "power=battery,xcodebuild=none"
        XCTAssertEqual(try cli.run(["verify", "--xcblame-dir", hook.xcblameDir.path] + xcodebuild, environment: battery).status, 6)
    }

    func testUsageErrorsFromThePlanExitTwo() throws {
        let (scratch, environment) = try scratch()
        let rule = try cli.run(["verify", "--rules", "SET-005", "--plan", "1a2b", "--xcblame-dir", scratch.xcblameDir.path]
            + xcodebuild, environment: environment)
        XCTAssertEqual(rule.status, 2, rule.err)
        XCTAssertTrue(rule.err.contains("plan 1a2b3c4d has no step for SET-005"), rule.err)
        let noArguments = try cli.run(["verify", "--xcblame-dir", scratch.xcblameDir.path], environment: environment)
        XCTAssertEqual(noArguments.status, 2, noArguments.err)
        XCTAssertTrue(noArguments.err.contains("pass the xcodebuild arguments after --"), noArguments.err)
        let derived = try cli.run(["verify", "--xcblame-dir", scratch.xcblameDir.path] + xcodebuild + ["-derivedDataPath", "/tmp/dd"],
                                  environment: environment)
        XCTAssertEqual(derived.status, 2, derived.err)
    }

    /// One real `verify --runs 3 --kind clean --mechanism cli` on a scratch copy of `fixtures/projects/AcmeApp` with a
    /// planted no-op overlay line, DerivedData under a scratch cache folder. Opt-in (`XCBLAME_E2E=1`): six clean builds
    /// that resolve packages over the network (`XCBLAME_E2E_PACKAGES=<dir>` reuses clones). The fixture's `Upload
    /// Symbols` phase runs `sentry-cli`: a stub on `PATH` stands in for it. Three runs per arm are below the noise
    /// model's four, so the verdict is `indicative` (or `reverted (within noise)` should the model change).
    func testRealVerifyOfTheAcmeFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["XCBLAME_E2E"] == "1", "set XCBLAME_E2E=1 to run the xcodebuild end-to-end test")
        try XCTSkipIf(runProbe(["xcodebuild", "-version"], timeout: 10) == nil, "xcodebuild is not available")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/projects/AcmeApp")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-verify-e2e-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("bin"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
        let project = scratch.appendingPathComponent("AcmeApp")
        try FileManager.default.copyItem(at: fixture, to: project)
        let stub = scratch.appendingPathComponent("bin/sentry-cli")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let xcblameDir = scratch.appendingPathComponent(".xcblame")
        let container = project.appendingPathComponent("AcmeApp.xcodeproj")
        let line = "XCBLAME_E2E_NOOP = YES // xcblame SET-020 (plan e2e0b001)"
        let step = FixPlanDocument.Step(
            order: 1, ruleId: "SET-020", title: "Planted no-op setting", fixKind: .overlay, mechanism: .cli,
            confidence: "high", verifyOnly: false, verifyKind: "clean",
            scope: [.init(target: "Acme", configuration: "Debug", key: "XCBLAME_E2E_NOOP", before: nil, after: "YES",
                          provenance: nil, mechanism: .cli, reached: true)],
            overlay: [.init(configuration: "Debug", key: "XCBLAME_E2E_NOOP", value: "YES", line: line)])
        try FixPlanStore.save(FixPlanDocument(
            tool: ReportDocument.Tool(name: "xcblame", version: XcblameVersion.current, kindTable: KindTable.v1.version),
            generatedAt: Date(), id: "e2e0b001",
            generatedFrom: .init(analysisId: nil, analysisPath: nil, analysisKind: nil, doctorConfigurations: ["Debug"],
                                 settingsSource: "offline", rulesFilter: []),
            project: .init(container: container.path, generator: nil, configurations: ["Debug"], scheme: "Acme"),
            steps: [step]), xcblameDir: xcblameDir)

        var arguments = ["verify", "--runs", "3", "--kind", "clean", "--mechanism", "cli", "--plan", "e2e0b001",
                         "--format", "json", "-o", scratch.appendingPathComponent("verify.json").path,
                         "--xcblame-dir", xcblameDir.path, "--",
                         "-project", container.path, "-scheme", "Acme", "-configuration", "Debug",
                         "-destination", "generic/platform=iOS Simulator", "CODE_SIGNING_ALLOWED=NO", "build"]
        if let packages = environment["XCBLAME_E2E_PACKAGES"] { arguments += ["-clonedSourcePackagesDirPath", packages] }
        let cache = scratch.appendingPathComponent("cache")
        // Its own process, stderr to a file: xcodebuild's output goes to stderr and would fill a pipe that `CLIRunner`
        // reads only after stdout ends.
        let process = Process()
        process.executableURL = cli.binary
        process.arguments = arguments
        process.currentDirectoryURL = scratch
        var env = environment
        env["CI"] = nil
        env["XCBLAME_XCODEBUILD"] = nil
        env["XCBLAME_CACHE_DIR"] = cache.path
        // Other builds of the machine (other worktrees' tests) and its power source are not what this test checks.
        env["XCBLAME_VERIFY_HOST"] = "power=ac,xcodebuild=none"
        env["PATH"] = scratch.appendingPathComponent("bin").path + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        let errLog = scratch.appendingPathComponent("stderr.log")
        FileManager.default.createFile(atPath: errLog.path, contents: nil)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: errLog)
        try process.run()
        process.waitUntilExit()
        let stderr = (try? String(contentsOf: errLog, encoding: .utf8)) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, String(stderr.suffix(4000)))
        let document = try JSONReporter.decoder().decode(VerifyDocument.self,
                                                         from: Data(contentsOf: scratch.appendingPathComponent("verify.json")))
        XCTAssertNil(document.abort)
        let unit = try XCTUnwrap(document.results.first)
        XCTAssertTrue(unit.verdict.status == .indicative || unit.verdict == .init(status: .reverted, reason: .withinNoise),
                      "\(unit.verdict) \(unit.checks) \(unit.notes)")
        XCTAssertEqual(unit.arms.map(\.runsOk), [3, 3])
        XCTAssertTrue(unit.checks.contains { $0.name == "taskKinds" && $0.status != "fail" }, "\(unit.checks)")
        for arm in unit.arms {
            XCTAssertTrue(arm.derivedData?.hasPrefix(cache.appendingPathComponent("verify/e2e0b001").path) == true,
                          arm.derivedData ?? "nil")
            XCTAssertTrue(arm.runs.allSatisfy { $0.criticalPath != nil && $0.taskKindsHash != nil }, "\(arm.runs)")
        }
        XCTAssertNotEqual(unit.arms[0].derivedData, unit.arms[1].derivedData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent(".xcblame").path))
        XCTAssertEqual(try FixPlanStore.load(id: "e2e0b001", xcblameDir: xcblameDir).steps[0].verify.status, unit.verdict.status)
    }

    func testHistoryPruneRemovesVerifyEntries() throws {
        let (scratch, environment) = try scratch()
        let history = scratch.xcblameDir.appendingPathComponent("history")
        // Recent ids (saving prunes entries past 90 days itself).
        for id in [Date(timeIntervalSinceNow: -60), Date()].map({ XcodebuildRunner.timestamp($0) + "-verify" }) {
            let document = VerifyDocument(
                tool: scratch.plan.tool, generatedAt: scratch.plan.generatedAt, id: id, planId: scratch.plan.id, kind: .clean,
                mechanism: nil, runsPerArm: 5, oneByOne: false, keepOnTie: false, maxMinutes: nil, touch: nil, scheme: nil,
                configuration: nil, xcodebuildArguments: [], preconditions: [], results: [], abort: nil, elapsedSeconds: 0,
                xcode: nil, machine: nil, notes: [])
            try History.saveVerify(document, directory: history)
        }
        let kept = try cli.run(["history", "prune", "--xcblame-dir", scratch.xcblameDir.path], environment: environment)
        XCTAssertEqual(kept.status, 0, kept.err)
        XCTAssertFalse(kept.out.contains("verify history"), kept.out)
        let run = try cli.run(["history", "prune", "--keep", "1", "--xcblame-dir", scratch.xcblameDir.path],
                              environment: environment)
        XCTAssertEqual(run.status, 0, run.err)
        XCTAssertTrue(run.out.contains("removed 1 verify history entries"), run.out)
        XCTAssertEqual(History.listVerify(directory: history).count, 1)
    }

    /// Verify entries live in `history/verify/`: `history list` and `trend` (both on `History.list`, as are
    /// `previousIndex`, baseline and retention) never see them (SCHEMA-v0.6 Decision 17).
    func testVerifyEntriesStayOutOfHistoryListAndTrend() throws {
        let (scratch, environment) = try scratch()
        let history = scratch.xcblameDir.appendingPathComponent("history")
        let model = SyntheticModel.make()
        var ids: [String] = []
        for index in 0..<2 {
            var document = try ReportPipeline.run(model, options: .init(generatedAt: Date(timeIntervalSinceNow: -3_600 + Double(index) * 600))).document
            document.build.kind = "clean"
            document.input.path = "/dd/Logs/Build/\(UUID().uuidString).xcactivitylog"
            ids.append(String(try History.save(document: document, model: model, directory: history).lastPathComponent.dropLast(".json.gz".count)))
        }
        let verifyId = XcodebuildRunner.timestamp(Date()) + "-verify"
        try History.saveVerify(VerifyDocument(
            tool: scratch.plan.tool, generatedAt: Date(), id: verifyId, planId: scratch.plan.id, kind: .clean, mechanism: nil,
            runsPerArm: 5, oneByOne: false, keepOnTie: false, maxMinutes: nil, touch: nil, scheme: nil, configuration: nil,
            xcodebuildArguments: [], preconditions: [], results: [], abort: nil, elapsedSeconds: 0, xcode: nil, machine: nil,
            notes: []), directory: history)
        let list = try cli.run(["history", "list", "--xcblame-dir", scratch.xcblameDir.path], environment: environment)
        XCTAssertEqual(list.status, 0, list.err)
        for id in ids { XCTAssertTrue(list.out.contains(id), list.out) }
        XCTAssertFalse(list.out.contains("verify"), list.out)
        let trend = try cli.run(["trend", "--xcblame-dir", scratch.xcblameDir.path], environment: environment)
        XCTAssertEqual(trend.status, 0, trend.err)
        XCTAssertTrue(trend.out.hasPrefix("xcblame trend: 2 of 2 history entries\n"), trend.out)
    }

    /// No stored plan but an analysis in the history: verify plans through `FixPlanner` (as `fix`) instead of asking
    /// for `xcblame fix`; here the project it names does not exist, so it stops at the project lookup (exit 5).
    func testWithoutAStoredPlanVerifyPlansFromTheHistory() throws {
        let state = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-verify-fresh-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: state) }
        let model = SyntheticModel.make()
        var document = try ReportPipeline.run(model, options: .init(generatedAt: Date(timeIntervalSinceNow: -600))).document
        document.input.path = "/dd/Logs/Build/\(UUID().uuidString).xcactivitylog"
        _ = try History.save(document: document, model: model, directory: state.appendingPathComponent("history"))
        let missing = state.appendingPathComponent("Missing.xcodeproj").path
        let run = try cli.run(["verify", "--rules", "SET-004", "--xcblame-dir", state.path, "--", "-project", missing,
                               "-scheme", "Acme", "build"], environment: ["XCBLAME_VERIFY_HOST": host])
        XCTAssertEqual(run.status, 5, run.err)
        XCTAssertFalse(run.err.contains("no stored fix plan"), run.err)
        XCTAssertTrue(run.err.contains(missing), run.err)
    }
}
