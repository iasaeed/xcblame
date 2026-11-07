import XCTest
@testable import XcblameKit

/// v0.6 fix round 1 (docs/reviews/code-review-v0.6.md): the verify journal and its recovery (M2), SIGHUP/SIGQUIT,
/// `-configuration` (minor 5), other plans' blocks in arm A (minor 6), signal-killed builds (minor 7), `--max-minutes`
/// during a build (minor 8), a failing auto-revert (minor 9) and the recorded basis (gap 2). Scripted runner, no
/// xcodebuild.
final class VerifyFixRoundTests: XCTestCase {
    let fasterA = [10.0, 10.1, 9.9, 10.0, 10.05]
    let fasterB = [8.0, 8.1, 7.9, 8.0, 8.05]

    private var hookState: [FixPlanDocument.HookState] {
        [.init(configuration: "Debug", status: "installed", baseXCConfig: "Config/Debug.xcconfig", reason: nil)]
    }

    private func installHook(_ fixture: VerifyFixture) throws {
        let base = fixture.container.deletingLastPathComponent().appendingPathComponent("Config/Debug.xcconfig")
        try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(("SWIFT_VERSION = 6\n" + HookInstaller.marker + "\n#include? \"../.xcblame/overlay-Debug.xcconfig\"\n").utf8)
            .write(to: base)
    }

    private func request(_ fixture: VerifyFixture, _ plan: FixPlanDocument, arguments: [String], runs: Int = 5,
                         maxMinutes: Double? = nil) -> VerifyRequest {
        VerifyRequest(plan: plan, rules: nil, kind: nil, runs: runs, oneByOne: false, keepOnTie: false, maxMinutes: maxMinutes,
                      mechanism: nil, touch: nil, xcodebuildArguments: arguments, xcblameDir: fixture.xcblameDir,
                      cacheHome: fixture.cacheHome, executable: nil, generatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    // MARK: - M2: journal, recovery, signals

    func testHookVerifyJournalsTheOriginalBytesWhileArmBRuns() throws {
        let fixture = try VerifyFixture(self)
        try installHook(fixture)
        let overlay = VerifyOverlay.url(xcblameDir: fixture.xcblameDir, configuration: "Debug")
        let original = VerifyOverlay.header(configuration: "Debug") + "\nSWIFT_X = 1 // hand\n"
        try Data(original.utf8).write(to: overlay)
        let journal = VerifyJournal.url(xcblameDir: fixture.xcblameDir)
        let plan = fixture.plan([VerifyFixture.step("SET-004", mechanism: .hook)], hook: hookState)
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB))
        let seen = Box()
        runner.onBuild = { build in
            guard build.arm == .b, let data = FileManager.default.contents(atPath: journal.path),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            seen.set(object)
        }
        let document = try fixture.harness(runner).verify(fixture.request(plan))
        XCTAssertNil(document.abort)
        let object = try XCTUnwrap(seen.value, "the journal exists while arm B builds")
        XCTAssertEqual(object["planId"] as? String, "5e1fa0b2")
        XCTAssertEqual(object["rules"] as? [String], ["SET-004"])
        XCTAssertEqual(object["pid"] as? Int, Int(getpid()))
        let entry = try XCTUnwrap((object["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual((entry["original"] as? String).flatMap { Data(base64Encoded: $0) }, Data(original.utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.path), "removed once the bytes are back")
        XCTAssertEqual(try String(contentsOf: overlay, encoding: .utf8), original)
    }

    /// What a SIGKILLed (or crashed) verify leaves: the temporary block in the overlay and the journal; the next
    /// `fix`, `verify` or `build` puts the bytes back (`recover`), unless that verify is still running.
    func testRecoverRestoresTheOverlayOfADeadVerify() throws {
        let fixture = try VerifyFixture(self)
        let overlay = VerifyOverlay.url(xcblameDir: fixture.xcblameDir, configuration: "Debug")
        let original = VerifyOverlay.header(configuration: "Debug") + "\nSWIFT_X = 1 // hand\n"
        try Data(original.utf8).write(to: overlay)
        let mtime = Date(timeIntervalSince1970: 1_790_000_000)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: overlay.path)
        let guardian = OverlayGuard(journal: VerifyJournal(xcblameDir: fixture.xcblameDir, planId: "5e1fa0b2",
                                                           rules: ["SET-004"], pid: 99_999))
        let left = VerifyOverlay.withTemporaryBlocks(original, plan: "5e1fa0b2", configuration: "Debug",
                                                     blocks: [(rule: "SET-004", lines: ["DEBUG_INFORMATION_FORMAT = dwarf"])])
        try guardian.write(left, to: overlay)
        // The process dies here: no restore.
        XCTAssertNil(VerifyJournal.recover(xcblameDir: fixture.xcblameDir, isAlive: { _, _ in true }), "still running: untouched")
        XCTAssertEqual(try String(contentsOf: overlay, encoding: .utf8), left)

        let warning = try XCTUnwrap(VerifyJournal.recover(xcblameDir: fixture.xcblameDir, isAlive: { _, _ in false }))
        XCTAssertTrue(warning.hasPrefix("warning: restored overlay-Debug.xcconfig from an interrupted verify of plan 5e1fa0b2"),
                      warning)
        XCTAssertEqual(try String(contentsOf: overlay, encoding: .utf8), original, "byte-identical")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: overlay.path))[.modificationDate] as? Date, mtime)
        XCTAssertFalse(FileManager.default.fileExists(atPath: VerifyJournal.url(xcblameDir: fixture.xcblameDir).path))
        XCTAssertNil(VerifyJournal.recover(xcblameDir: fixture.xcblameDir), "nothing left to do")

        // A file verify created goes again.
        try FileManager.default.removeItem(at: overlay)
        let created = OverlayGuard(journal: VerifyJournal(xcblameDir: fixture.xcblameDir, planId: "5e1fa0b2",
                                                          rules: ["SET-004"], pid: 99_999))
        try created.write(VerifyOverlay.withTemporaryBlocks(nil, plan: "5e1fa0b2", configuration: "Debug",
                                                            blocks: [(rule: "SET-004", lines: ["A = 1"])]), to: overlay)
        XCTAssertNotNil(VerifyJournal.recover(xcblameDir: fixture.xcblameDir, isAlive: { _, _ in false }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlay.path))
    }

    func testSignalsCoverHangupAndQuit() {
        XCTAssertEqual(VerifySignals.handled.map(\.1), ["SIGINT", "SIGTERM", "SIGHUP", "SIGQUIT"])
    }

    // MARK: - Fix round 2

    /// Finding 2: under `nohup` (SIGHUP ignored) verify leaves SIGHUP ignored and catches the others.
    func testIgnoredSignalsStayIgnored() {
        let previous = signal(SIGHUP, SIG_IGN)
        defer { signal(SIGHUP, previous) }
        XCTAssertTrue(VerifySignals.isIgnored(SIGHUP))
        let signals = VerifySignals(guard: OverlayGuard(), interrupt: VerifyInterrupt())
        XCTAssertEqual(signals.installed, ["SIGINT", "SIGTERM", "SIGQUIT"])
        XCTAssertTrue(VerifySignals.isIgnored(SIGHUP), "still ignored while verify runs")
        signals.uninstall()
        XCTAssertTrue(VerifySignals.isIgnored(SIGHUP), "and after")
        XCTAssertFalse(VerifySignals.isIgnored(SIGINT))
    }

    /// Finding 1: a verify killed during an arm A build (the overlay written without the selected steps' applied
    /// blocks, no temporary block) is recovered too.
    func testRecoverRestoresAnArmAWrite() throws {
        let fixture = try VerifyFixture(self)
        let overlay = VerifyOverlay.url(xcblameDir: fixture.xcblameDir, configuration: "Debug")
        let header = VerifyOverlay.header(configuration: "Debug")
        let applied = header + "\n// xcblame plan 5e1fa0b2 rule SET-004\nDEBUG_INFORMATION_FORMAT = dwarf // xcblame SET-004 "
            + "(plan 5e1fa0b2)\n// end xcblame plan 5e1fa0b2 rule SET-004\n"
        try Data(applied.utf8).write(to: overlay)
        let guardian = OverlayGuard(journal: VerifyJournal(xcblameDir: fixture.xcblameDir, planId: "5e1fa0b2",
                                                           rules: ["SET-004"], pid: 99_999))
        try guardian.write(header, to: overlay) // arm A: the applied block taken out; the process dies here
        let warning = try XCTUnwrap(VerifyJournal.recover(xcblameDir: fixture.xcblameDir, isAlive: { _, _ in false }))
        XCTAssertTrue(warning.contains("restored overlay-Debug.xcconfig"), warning)
        XCTAssertEqual(try String(contentsOf: overlay, encoding: .utf8), applied, "the applied block is back")
    }

    /// Nit 7: a live process with the journal's pid but another start time is a reused pid: the verify is dead.
    func testReusedPidIsNotTakenForTheVerify() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { sleeper.terminate() }
        let pid = sleeper.processIdentifier
        let start = try XCTUnwrap(VerifyJournal.processStart(pid))
        XCTAssertTrue(VerifyJournal.processIsAlive(pid, start: start))
        XCTAssertTrue(VerifyJournal.processIsAlive(pid, start: nil), "an older journal without a start time")
        XCTAssertFalse(VerifyJournal.processIsAlive(pid, start: start - 3600), "same pid, other process")

        let fixture = try VerifyFixture(self)
        let overlay = VerifyOverlay.url(xcblameDir: fixture.xcblameDir, configuration: "Debug")
        let journal = VerifyJournal(xcblameDir: fixture.xcblameDir, planId: "5e1fa0b2", rules: ["SET-004"], pid: pid)
        try OverlayGuard(journal: journal).write("A = 1\n", to: overlay)
        XCTAssertNil(VerifyJournal.recover(xcblameDir: fixture.xcblameDir), "the journal's own process is alive")
        let data = try Data(contentsOf: journal.url)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["processStart"] as? Double, start)
        object["processStart"] = start - 3600
        try JSONSerialization.data(withJSONObject: object).write(to: journal.url)
        XCTAssertNotNil(VerifyJournal.recover(xcblameDir: fixture.xcblameDir), "reused pid: recovered")
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlay.path))
    }

    /// Verifier round 2: SET-004's B arm loses its dSYM task and its first (cold) clean build also builds the explicit
    /// module PCMs; that is the rule working, not a changed task set. The same differences for a rule that declares
    /// nothing still revert.
    func testSET004DeclaredEffectAndColdModuleBuildsAreNotATaskSetChange() throws {
        let fixture = try VerifyFixture(self)
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir) { build, _ in
            var kinds = ["Acme\tSwiftCompile": 12, "Acme\tLd": 1, "Acme\tGenerateDSYMFile": 1]
            if build.arm == .b {
                kinds["Acme\tGenerateDSYMFile"] = nil
                if build.index == 1 {
                    kinds["explicit modules\tSwiftExplicitDependencyGeneratePcm"] = 40
                    kinds["build system\tGenerateSwiftModulesReport"] = 1
                }
            }
            return VerifyFixture.outcome(build.arm == .a ? 10 : 8, kinds: kinds)
        }
        let kept = try XCTUnwrap(try fixture.harness(runner, record: false)
            .verify(fixture.request(fixture.plan([VerifyFixture.step("SET-004")]))).results.first)
        XCTAssertEqual(kept.verdict.status, .kept, "\(kept.checks)")
        XCTAssertEqual(kept.checks.first { $0.name == "taskKinds" }?.status, "pass")

        let undeclared = try XCTUnwrap(try fixture.harness(runner, record: false)
            .verify(fixture.request(fixture.plan([VerifyFixture.step("SET-030")]))).results.first)
        XCTAssertEqual(undeclared.verdict, .init(status: .reverted, reason: .taskSetChanged))
        let detail = undeclared.checks.first { $0.name == "taskKinds" }?.detail ?? ""
        XCTAssertTrue(detail.contains("Acme GenerateDSYMFile") && !detail.contains("SwiftExplicitDependencyGeneratePcm"), detail)
    }

    /// The AcmeFixWin task kinds of arm A (two architectures) and arm B (`ONLY_ACTIVE_ARCH = YES`) per clean build, as
    /// the main @ 3dae7b6 verify logs show them (scratchpad verify-v0.6-r3/v005.txt; counts per build).
    static let multiArch: [String: Int] = [
        "ConstructStubExecutorLinkFileList": 2, "Copy": 8, "CopySwiftLibs": 1, "CreateUniversalBinary": 3,
        "EmitSwiftModule": 2, "ExtractAppIntentsMetadata": 1, "GenerateDSYMFile": 2, "Ld": 6, "MkDir": 3,
        "ProcessInfoPlistFile": 1, "RegisterExecutionPolicyException": 1, "RegisterWithLaunchServices": 1,
        "SwiftCompile": 138, "SwiftDriver": 2, "SwiftDriver Compilation": 2, "SwiftDriver Compilation Requirements": 2,
        "SwiftDriverJobDiscovery": 58, "SwiftEmitModule": 2, "SwiftMergeGeneratedHeaders": 1, "Touch": 1, "Validate": 1,
        "WriteAuxiliaryFile": 23,
    ]
    static let singleArch: [String: Int] = [
        "ConstructStubExecutorLinkFileList": 1, "Copy": 4, "CopySwiftLibs": 1, "EmitSwiftModule": 1,
        "ExtractAppIntentsMetadata": 1, "GenerateDSYMFile": 2, "Ld": 3, "MkDir": 3, "ProcessInfoPlistFile": 1,
        "RegisterExecutionPolicyException": 1, "RegisterWithLaunchServices": 1, "SwiftCompile": 69, "SwiftDriver": 1,
        "SwiftDriver Compilation": 1, "SwiftDriver Compilation Requirements": 1, "SwiftDriverJobDiscovery": 29,
        "SwiftEmitModule": 1, "SwiftMergeGeneratedHeaders": 1, "Touch": 1, "Validate": 1, "WriteAuxiliaryFile": 16,
    ]

    /// Verifier round 3 (main @ 3dae7b6: `reverted (task set changed)` on the per-arch Swift driver planning kinds): with
    /// the real sets SET-005 is kept; a kind only B runs, or compile work B lost, still reverts; the same sets for a
    /// rule that changes no architecture count revert with a two-line message naming the needed effect.
    func testSET005ArchitectureCountWithTheLoggedTaskKinds() throws {
        let fixture = try VerifyFixture(self)
        func runner(_ b: [String: Int]) -> ScriptedRunner {
            ScriptedRunner(xcblameDir: fixture.xcblameDir) { build, _ in
                let kinds = build.arm == .a ? Self.multiArch : b
                return VerifyFixture.outcome(build.arm == .a ? 10.5 : 6.0,
                                             kinds: Dictionary(uniqueKeysWithValues: kinds.map { ("AcmeFixWin\t\($0.key)", $0.value) }),
                                             targets: ["AcmeFixWin"])
            }
        }
        func unit(_ rule: String, _ b: [String: Int]) throws -> VerifyDocument.UnitResult {
            try XCTUnwrap(try fixture.harness(runner(b), record: false)
                .verify(fixture.request(fixture.plan([VerifyFixture.step(rule)]))).results.first)
        }
        let kept = try unit("SET-005", Self.singleArch)
        XCTAssertEqual(kept.verdict.status, .kept, "\(kept.checks)")
        XCTAssertTrue(kept.checks.first { $0.name == "taskKinds" }?.detail.contains("architecture count changes") == true)

        XCTAssertEqual(try unit("SET-005", Self.singleArch.merging(["PhaseScriptExecution": 1]) { $1 }).verdict,
                       .init(status: .reverted, reason: .taskSetChanged), "a kind only B runs")
        var noCompile = Self.singleArch
        noCompile["SwiftCompile"] = nil
        XCTAssertEqual(try unit("SET-005", noCompile).verdict, .init(status: .reverted, reason: .taskSetChanged),
                       "the compile work must stay")

        let other = try unit("SET-030", Self.singleArch)
        XCTAssertEqual(other.verdict, .init(status: .reverted, reason: .taskSetChanged))
        let detail = other.checks.first { $0.name == "taskKinds" }?.detail ?? ""
        XCTAssertLessThanOrEqual(detail.components(separatedBy: "\n").count, 2, detail)
        XCTAssertTrue(detail.contains("(2 → 1)") || detail.contains("missing in B"), detail)
    }

    /// Finding 4: a reverted verify of an `applied-cli` step moves it to `reverted`, so `build --overlay` stops.
    func testRevertedVerifyRevertsAnAppliedCLIStep() throws {
        let fixture = try VerifyFixture(self)
        let plan = fixture.plan([VerifyFixture.step("SET-004", state: .appliedCLI)])
        try FixPlanStore.save(plan, xcblameDir: fixture.xcblameDir)
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterB, b: fasterA))
        _ = try fixture.harness(runner).verify(fixture.request(plan))
        let stored = try FixPlanStore.load(id: plan.id, xcblameDir: fixture.xcblameDir)
        XCTAssertEqual(stored.steps[0].state, .reverted)
        XCTAssertNotNil(OverlayDelivery.leftOut(stored.steps[0], unverified: true))
    }

    // MARK: - Minors 5-9

    func testMissingConfigurationIsAddedToTheArguments() throws {
        let fixture = try VerifyFixture(self)
        let plan = fixture.plan([VerifyFixture.step("SET-004")])
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB))
        let document = try fixture.harness(runner, record: false)
            .verify(request(fixture, plan, arguments: ["-project", "Acme.xcodeproj", "-scheme", "Acme", "build"]))
        XCTAssertTrue(runner.builds.allSatisfy { XcodebuildRunner.value(of: "-configuration", in: $0.build.arguments) == "Debug" })
        XCTAssertTrue(document.notes.contains { $0.hasPrefix("-configuration Debug added") }, "\(document.notes)")
    }

    func testArmAStripsAnotherPlansBlockOfTheSameKey() throws {
        let fixture = try VerifyFixture(self)
        try installHook(fixture)
        let overlay = VerifyOverlay.url(xcblameDir: fixture.xcblameDir, configuration: "Debug")
        let header = VerifyOverlay.header(configuration: "Debug")
        let older = "\n// xcblame plan aaaa1111 rule SET-004\nDEBUG_INFORMATION_FORMAT = dwarf // xcblame SET-004 (plan aaaa1111)\n"
            + "// end xcblame plan aaaa1111 rule SET-004\n"
        try Data((header + older).utf8).write(to: overlay)
        let plan = fixture.plan([VerifyFixture.step("SET-004", mechanism: .hook)], hook: hookState)
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterB, b: fasterA))
        let document = try fixture.harness(runner).verify(fixture.request(plan))
        XCTAssertEqual(runner.builds.first { $0.build.arm == .a }?.overlay, header, "arm A without plan aaaa1111's block")
        XCTAssertTrue(document.notes.contains { $0.contains("plan aaaa1111's SET-004 block") }, "\(document.notes)")
        XCTAssertTrue(document.results[0].notes.contains { $0.contains("xcblame fix --revert aaaa1111") },
                      "\(document.results[0].notes)")
        XCTAssertEqual(try String(contentsOf: overlay, encoding: .utf8), header + older, "the overlay comes back")
    }

    func testASignalKilledBuildIsInterruptedNotBroken() throws {
        let fixture = try VerifyFixture(self)
        let plan = fixture.plan([VerifyFixture.step("SET-004")])
        let interrupt = VerifyInterrupt()
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir) { build, _ in
            guard build.arm == .b, build.index == 2 else { return VerifyFixture.outcome(build.arm == .a ? 10 : 8) }
            // Ctrl-C reached xcodebuild first; the handler marks the interrupt a moment later.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { interrupt.raise("SIGINT") }
            return VerifyFixture.outcome(1, exit: 130)
        }
        let document = try fixture.harness(runner, interrupt: interrupt, record: false).verify(fixture.request(plan))
        XCTAssertEqual(document.abort?.reason, .interrupted)
        XCTAssertNotEqual(document.results.first?.verdict.reason, .brokeBuild)
    }

    func testMaxMinutesStopsARunningBuild() throws {
        let fixture = try VerifyFixture(self)
        let plan = fixture.plan([VerifyFixture.step("SET-004")])
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir) { build, _ in
            XCTAssertNotNil(build.deadline, "the budget reaches the runner")
            guard build.arm == .b, build.index == 3 else { return VerifyFixture.outcome(build.arm == .a ? 10 : 8) }
            var stopped = VerifyFixture.outcome(1, exit: 143)
            stopped.timedOut = true
            return stopped
        }
        let document = try fixture.harness(runner, record: false).verify(fixture.request(plan, maxMinutes: 30))
        XCTAssertEqual(document.abort?.reason, .timeout)
        XCTAssertTrue(document.abort?.detail.contains("ran out during arm B run 3") == true, document.abort?.detail ?? "")
    }

    /// The real runner: the timer stops a build still running at the deadline through the `Cancel`.
    func testRunnerStopsTheBuildAtTheDeadline() throws {
        let fixture = try VerifyFixture(self)
        let script = fixture.root.appendingPathComponent("slow-xcodebuild.sh")
        try Data("#!/bin/sh\nsleep 30\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let runner = XcodebuildVerifyRunner(xcblameDir: fixture.xcblameDir, executable: script)
        let started = Date()
        let outcome = try runner.build(VerifyBuild(arm: .b, label: "B-SET-004", index: 1, settle: false, clean: false,
                                                   arguments: ["build"], unsetEnvironment: [],
                                                   derivedData: fixture.cacheHome, deadline: Date().addingTimeInterval(0.5)))
        XCTAssertTrue(outcome.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 15)
    }

    func testFailingAutoRevertStillRecordsEveryVerdict() throws {
        let fixture = try VerifyFixture(self)
        try installHook(fixture)
        var step = VerifyFixture.step("SET-030", mechanism: .hook, state: .applied)
        step.overlay.append(.init(configuration: "Release", key: "XCB_TEST_SET_030", value: "YES",
                                  line: "XCB_TEST_SET_030 = YES // xcblame SET-030 (plan 5e1fa0b2)"))
        let plan = fixture.plan([step], hook: hookState)
        try FixPlanStore.save(plan, xcblameDir: fixture.xcblameDir)
        // Release's overlay holds the block's begin line but no end line: auto-revert throws there.
        let release = VerifyOverlay.url(xcblameDir: fixture.xcblameDir, configuration: "Release")
        try Data((VerifyOverlay.header(configuration: "Release") + "\n// xcblame plan 5e1fa0b2 rule SET-030\nXCB_TEST_SET_030 = YES\n")
            .utf8).write(to: release)
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterB, b: fasterA))
        let document = try fixture.harness(runner).verify(fixture.request(plan))
        XCTAssertEqual(document.results[0].verdict, .init(status: .reverted, reason: .slower))
        XCTAssertTrue(document.results[0].notes.contains { $0.hasPrefix("auto-revert of SET-030 failed") },
                      "\(document.results[0].notes)")
        let stored = try FixPlanStore.load(id: plan.id, xcblameDir: fixture.xcblameDir)
        XCTAssertEqual(stored.steps[0].verify.status, .reverted, "the verdict is saved")
        XCTAssertFalse(History.listVerify(directory: fixture.xcblameDir.appendingPathComponent("history")).isEmpty,
                       "and the history verify entry")
    }

    func testVerdictsCarryTheirBasis() throws {
        let fixture = try VerifyFixture(self)
        let plan = fixture.plan([VerifyFixture.step("SET-004")])
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB))
        let document = try fixture.harness(runner).verify(fixture.request(plan))
        let stored = try FixPlanStore.load(id: plan.id, xcblameDir: fixture.xcblameDir)
        let digest = VerifyBasis.projectDigest(container: plan.project.container, xcblameDir: fixture.xcblameDir)
        XCTAssertEqual(stored.steps[0].verify.basis,
                       VerifyBasis.value(step: plan.steps[0], container: plan.project.container, projectDigest: digest))
        XCTAssertEqual(document.results[0].basis, VerifyBasis.combined(ruleIds: ["SET-004"], plan: plan, projectDigest: digest))
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Any]?
    func set(_ value: [String: Any]) { lock.lock(); stored = value; lock.unlock() }
    var value: [String: Any]? { lock.lock(); defer { lock.unlock() }; return stored }
}
