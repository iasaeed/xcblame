import XCTest
@testable import XcblameKit

// v0.6 lane B (DESIGN §12 item 7): the A/B harness driven by a scripted runner and host, so every verdict, abort and
// revert path runs without xcodebuild.

/// Scripted builds: `script` answers each build; every build is recorded with the overlay text it saw.
final class ScriptedRunner: VerifyBuildRunning, @unchecked Sendable {
    struct Seen {
        var build: VerifyBuild
        /// The hook overlay file's text while the build ran (nil: absent).
        var overlay: String?
        /// The `cli` verify overlay's text while the build ran.
        var cliOverlay: String?
    }

    private let lock = NSLock()
    private var seen: [Seen] = []
    let overlayURL: URL
    let cliOverlayURL: URL
    let script: @Sendable (VerifyBuild, Int) -> VerifyBuildOutcome
    var onBuild: (@Sendable (VerifyBuild) -> Void)?

    init(xcblameDir: URL, script: @escaping @Sendable (VerifyBuild, Int) -> VerifyBuildOutcome) {
        overlayURL = VerifyOverlay.url(xcblameDir: xcblameDir, configuration: "Debug")
        cliOverlayURL = VerifyOverlay.cliURL(xcblameDir: xcblameDir, configuration: "Debug")
        self.script = script
    }

    func build(_ build: VerifyBuild) throws -> VerifyBuildOutcome {
        lock.lock()
        let count = seen.count
        seen.append(Seen(build: build, overlay: try? String(contentsOf: overlayURL, encoding: .utf8),
                         cliOverlay: try? String(contentsOf: cliOverlayURL, encoding: .utf8)))
        lock.unlock()
        onBuild?(build)
        return script(build, count)
    }

    var builds: [Seen] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}

/// A scripted machine: power, other builds, thermal per call, dirty files, a clock that moves with each build.
final class ScriptedHost: VerifyHost, @unchecked Sendable {
    private let lock = NSLock()
    var battery: Bool? = false
    var xcodebuilds: [Int32] = []
    var dirty: [String]? = []
    var root: URL?
    /// Thermal answers in order (the precondition reads the first); `nominal` once they run out.
    var thermal: [String] = []
    var clock = Date(timeIntervalSince1970: 1_800_000_000)
    /// Seconds the clock moves per `now()` call after the first.
    var tick: Double = 0
    private(set) var touched: [URL] = []

    func thermalState() -> String {
        lock.lock()
        defer { lock.unlock() }
        return thermal.isEmpty ? "nominal" : thermal.removeFirst()
    }

    func onBattery() -> Bool? { battery }
    func otherXcodebuilds() -> [Int32] { xcodebuilds }
    func dirtyFiles(_ files: [URL], in directory: URL) -> [String]? { dirty }
    func repositoryRoot(of directory: URL) -> URL? { root }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        let value = clock
        clock = clock.addingTimeInterval(tick)
        return value
    }

    func machine() -> String? { "Mac15,14/28c/96g" }

    func touch(_ file: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        touched.append(file)
    }
}

/// A temp xcblame dir, cache home and project, and a plan over them.
struct VerifyFixture {
    let root: URL
    let xcblameDir: URL
    let cacheHome: URL
    let container: URL

    init(_ testCase: XCTestCase) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-verify-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        xcblameDir = root.appendingPathComponent("repo/.xcblame")
        cacheHome = root.appendingPathComponent("cache")
        container = root.appendingPathComponent("repo/Acme.xcodeproj")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: xcblameDir, withIntermediateDirectories: true)
        let root = self.root
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }

    static let arguments = ["-project", "Acme.xcodeproj", "-scheme", "Acme", "-configuration", "Debug", "build"]

    static func step(_ rule: String, order: Int = 1, mechanism: FixPlanDocument.Mechanism = .cli, kind: String = "clean",
                     reached: Bool = true, state: FixPlanDocument.StepState = .planned, plan: String = "5e1fa0b2",
                     line: String? = nil) -> FixPlanDocument.Step {
        let key = rule == "SET-004" ? "DEBUG_INFORMATION_FORMAT" : "XCB_TEST_\(rule.replacingOccurrences(of: "-", with: "_"))"
        let value = rule == "SET-004" ? "dwarf" : "YES"
        return .init(order: order, ruleId: rule, title: "Synthetic \(rule)", fixKind: .overlay, mechanism: mechanism,
                     confidence: "high", verifyOnly: false, verifyKind: kind,
                     scope: [.init(target: "Acme", configuration: "Debug", key: key, before: "x", after: value,
                                   provenance: nil, mechanism: .hook, reached: reached),
                             .init(target: "Acme", configuration: "Debug", key: key, before: "x", after: value,
                                   provenance: nil, mechanism: .cli, reached: true)],
                     overlay: [.init(configuration: "Debug", key: key, value: value,
                                     line: line ?? "\(key) = \(value) // xcblame \(rule) (plan \(plan))")],
                     state: state)
    }

    func plan(_ steps: [FixPlanDocument.Step], id: String = "5e1fa0b2",
              hook: [FixPlanDocument.HookState] = []) -> FixPlanDocument {
        FixPlanDocument(tool: V06Samples.tool, generatedAt: V06Samples.date, id: id,
                        generatedFrom: .init(analysisId: nil, analysisPath: nil, analysisKind: nil,
                                             doctorConfigurations: ["Debug"], settingsSource: "offline", rulesFilter: []),
                        project: .init(container: container.path, generator: nil, configurations: ["Debug"], scheme: "Acme"),
                        steps: steps, hook: hook)
    }

    func request(_ plan: FixPlanDocument, runs: Int = 5, kind: VerifyDocument.Kind? = nil, rules: [String]? = nil,
                 oneByOne: Bool = false, keepOnTie: Bool = false, maxMinutes: Double? = nil,
                 mechanism: FixPlanDocument.Mechanism? = nil, touch: String? = nil) -> VerifyRequest {
        VerifyRequest(plan: plan, rules: rules, kind: kind, runs: runs, oneByOne: oneByOne, keepOnTie: keepOnTie,
                      maxMinutes: maxMinutes, mechanism: mechanism, touch: touch,
                      xcodebuildArguments: Self.arguments, xcblameDir: xcblameDir, cacheHome: cacheHome, executable: nil,
                      generatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    func harness(_ runner: ScriptedRunner, host: ScriptedHost = ScriptedHost(), interrupt: VerifyInterrupt = VerifyInterrupt(),
                 record: Bool = true) -> ABHarness {
        ABHarness(runner: runner, host: host, interrupt: interrupt, environment: [:], installSignalHandlers: false,
                  record: record)
    }

    /// A clean build with `wall` seconds, two targets and a fixed task multiset.
    static func outcome(_ wall: Double, exit: Int32 = 0, kinds: [String: Int]? = nil, targets: [String] = ["Acme", "AcmeKit"],
                        sources: [VerifyBuildOutcome.SwiftSource] = []) -> VerifyBuildOutcome {
        VerifyBuildOutcome(exitCode: exit, wall: wall, criticalPath: wall * 0.8,
                           taskKinds: kinds ?? ["Acme\tSwiftCompile": 12, "Acme\tLd": 1, "AcmeKit\tSwiftCompile": 6,
                                                "Acme\tGenerateDSYMFile": 1],
                           targets: targets, swiftSources: sources, xcode: "26.0")
    }
}

/// Walls per arm, cycling through `a` and `b` by the build's index.
func walls(a: [Double], b: [Double]) -> @Sendable (VerifyBuild, Int) -> VerifyBuildOutcome {
    { build, _ in
        let list = build.arm == .a ? a : b
        return VerifyFixture.outcome(list[(build.index - 1) % list.count])
    }
}

final class VerifyHarnessTests: XCTestCase {
    let fasterA = [10.0, 10.1, 9.9, 10.0, 10.05]
    let fasterB = [8.0, 8.1, 7.9, 8.0, 8.05]

    func testKeptWritesPlanAndHistoryWithPerArmDerivedData() throws {
        let fixture = try VerifyFixture(self)
        let plan = fixture.plan([VerifyFixture.step("SET-004")])
        try FixPlanStore.save(plan, xcblameDir: fixture.xcblameDir)
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB))
        let document = try fixture.harness(runner).verify(fixture.request(plan))

        XCTAssertNil(document.abort)
        XCTAssertEqual(document.id, XcodebuildRunner.timestamp(Date(timeIntervalSince1970: 1_800_000_000)) + "-verify")
        let unit = try XCTUnwrap(document.results.first)
        XCTAssertEqual(unit.verdict, .init(status: .kept))
        XCTAssertEqual(unit.deltaSeconds ?? 0, -2.0, accuracy: 1e-9)
        XCTAssertEqual(unit.deltaPct ?? 0, -0.2, accuracy: 1e-9)
        XCTAssertEqual(unit.arms.map(\.arm), [.a, .b])
        XCTAssertEqual(unit.arms.map(\.samples), [5, 5])
        XCTAssertEqual(unit.arms[0].p50, 10.0)
        XCTAssertEqual(unit.arms[1].p50, 8.0)
        XCTAssertEqual(unit.checks.map(\.name), ["oracle", "exitCode", "targetSet", "taskKinds", "thermal"])
        XCTAssertTrue(unit.checks.allSatisfy { $0.status == "pass" }, "\(unit.checks)")
        XCTAssertEqual(document.preconditions.map(\.name), ["cleanTree", "power", "thermal", "otherBuild"])

        // ABAB, every run cleaned first, each arm in its own DerivedData under <cache>/verify/<plan>/.
        let builds = runner.builds.map(\.build)
        XCTAssertEqual(builds.map(\.arm), [.a, .b, .a, .b, .a, .b, .a, .b, .a, .b])
        XCTAssertTrue(builds.allSatisfy { $0.clean && !$0.settle })
        let a = fixture.cacheHome.appendingPathComponent("verify/5e1fa0b2/A")
        let b = fixture.cacheHome.appendingPathComponent("verify/5e1fa0b2/B-batch")
        XCTAssertEqual(Set(builds.map(\.derivedData.path)), [a.path, b.path])
        for build in builds {
            XCTAssertEqual(XcodebuildRunner.value(of: "-derivedDataPath", in: build.arguments), build.derivedData.path)
            XCTAssertEqual(build.derivedData.path, build.arm == .a ? a.path : b.path)
        }
        XCTAssertEqual(unit.arms.map(\.derivedData), [a.path, b.path])

        let stored = try FixPlanStore.load(id: plan.id, xcblameDir: fixture.xcblameDir)
        XCTAssertEqual(stored.steps[0].verify.status, .kept)
        XCTAssertEqual(stored.steps[0].verify.mechanism, .cli)
        XCTAssertEqual(stored.steps[0].verify.kind, "clean")
        XCTAssertEqual(stored.steps[0].verify.verifyId, document.id)
        XCTAssertEqual(stored.steps[0].verify.deltaSeconds ?? 0, -2.0, accuracy: 1e-9)
        let history = fixture.xcblameDir.appendingPathComponent("history")
        XCTAssertEqual(try History.showVerify(id: document.id, directory: history), document)
        XCTAssertTrue(History.list(directory: history).isEmpty, "verify entries stay out of History.list")
    }

    func testCLIWrapperIncludesOverlayPerArm() throws {
        let fixture = try VerifyFixture(self)
        let plan = fixture.plan([VerifyFixture.step("SET-004")])
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB))
        _ = try fixture.harness(runner, record: false).verify(fixture.request(plan, runs: 2))
        for seen in runner.builds {
            let wrapper = try XCTUnwrap(XcodebuildRunner.value(of: "-xcconfig", in: seen.build.arguments))
            XCTAssertTrue(wrapper.hasSuffix("tmp/wrapper-Debug.xcconfig"), wrapper)
            let text = try String(contentsOfFile: wrapper, encoding: .utf8)
            XCTAssertTrue(text.contains("#include \"\(runner.cliOverlayURL.path)\""), text)
            let overlay = seen.cliOverlay ?? ""
            XCTAssertEqual(overlay.contains("DEBUG_INFORMATION_FORMAT = dwarf"), seen.build.arm == .b, overlay)
            XCTAssertNil(seen.overlay, "cli never writes the hook overlay")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: runner.overlayURL.path))
    }

    func testSlowerWithinNoiseTieAndIndicative() throws {
        let fixture = try VerifyFixture(self)
        let plan = fixture.plan([VerifyFixture.step("SET-016")])
        func verdict(_ a: [Double], _ b: [Double], runs: Int = 5, keepOnTie: Bool = false) throws -> VerifyDocument.UnitResult {
            let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: a, b: b))
            return try XCTUnwrap(try fixture.harness(runner, record: false)
                .verify(fixture.request(plan, runs: runs, keepOnTie: keepOnTie)).results.first)
        }
        XCTAssertEqual(try verdict(fasterB, fasterA).verdict, .init(status: .reverted, reason: .slower))
        let noise = try verdict([10.0, 10.3, 9.8, 10.1, 9.9], [10.1, 9.9, 10.2, 10.0, 9.8])
        XCTAssertEqual(noise.verdict, .init(status: .reverted, reason: .withinNoise))
        XCTAssertNotNil(noise.noiseBand)
        XCTAssertEqual(try verdict([10.0, 10.3, 9.8, 10.1, 9.9], [10.1, 9.9, 10.2, 10.0, 9.8], keepOnTie: true).verdict,
                       .init(status: .kept, tie: true))
        let indicative = try verdict(fasterA, fasterB, runs: 3)
        XCTAssertEqual(indicative.verdict, .init(status: .indicative))
        XCTAssertNil(indicative.noiseBand)
        XCTAssertNotNil(indicative.deltaSeconds)
    }

    func testBrokeBuildStopsTheUnitAndRevertsIt() throws {
        let fixture = try VerifyFixture(self)
        let plan = fixture.plan([VerifyFixture.step("SET-030")])
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir) { build, _ in
            VerifyFixture.outcome(10, exit: build.arm == .b && build.index == 2 ? 65 : 0)
        }
        let unit = try XCTUnwrap(try fixture.harness(runner).verify(fixture.request(plan)).results.first)
        XCTAssertEqual(unit.verdict, .init(status: .reverted, reason: .brokeBuild))
        XCTAssertEqual(unit.arms[1].runs.map(\.ok), [true, false])
        XCTAssertEqual(unit.arms[1].runs.last?.excluded, "failed")
        XCTAssertEqual(unit.checks.first { $0.name == "exitCode" }?.status, "fail")
        XCTAssertNil(unit.deltaSeconds)
        XCTAssertEqual(runner.builds.filter { $0.build.arm == .b }.count, 2, "no B run after the failure")
        XCTAssertEqual(runner.builds.count, 4, "A stops too once no unit needs it")
        let stored = try FixPlanStore.load(id: plan.id, xcblameDir: fixture.xcblameDir)
        XCTAssertEqual(stored.steps[0].verify.status, .reverted)
        XCTAssertEqual(stored.steps[0].verify.reason, .brokeBuild)
    }

    func testTaskSetChangedUnlessDeclared() throws {
        let fixture = try VerifyFixture(self)
        // SET-004 declares GenerateDSYMFile: B without it is the rule working, not a changed task set.
        let declared = ScriptedRunner(xcblameDir: fixture.xcblameDir) { build, _ in
            var kinds = ["Acme\tSwiftCompile": 12, "Acme\tLd": 1, "Acme\tGenerateDSYMFile": 1]
            if build.arm == .b { kinds["Acme\tGenerateDSYMFile"] = nil }
            return VerifyFixture.outcome(build.arm == .a ? 10 : 8, kinds: kinds)
        }
        let kept = try XCTUnwrap(try fixture.harness(declared, record: false)
            .verify(fixture.request(fixture.plan([VerifyFixture.step("SET-004")]))).results.first)
        XCTAssertEqual(kept.verdict.status, .kept)
        XCTAssertEqual(kept.checks.first { $0.name == "taskKinds" }?.status, "pass")

        // The same difference for a rule that declares nothing, faster or not: task set changed.
        let changed = try XCTUnwrap(try fixture.harness(declared, record: false)
            .verify(fixture.request(fixture.plan([VerifyFixture.step("SET-030")]))).results.first)
        XCTAssertEqual(changed.verdict, .init(status: .reverted, reason: .taskSetChanged))
        let check = try XCTUnwrap(changed.checks.first { $0.name == "taskKinds" })
        XCTAssertEqual(check.status, "fail")
        XCTAssertTrue(check.detail.contains("Acme GenerateDSYMFile"), check.detail)

        // Another target set is a change for every rule.
        let targets = ScriptedRunner(xcblameDir: fixture.xcblameDir) { build, _ in
            VerifyFixture.outcome(build.arm == .a ? 10 : 8, targets: build.arm == .a ? ["Acme", "AcmeKit"] : ["Acme"])
        }
        let lost = try XCTUnwrap(try fixture.harness(targets, record: false)
            .verify(fixture.request(fixture.plan([VerifyFixture.step("SET-004")]))).results.first)
        XCTAssertEqual(lost.verdict, .init(status: .reverted, reason: .taskSetChanged))
        XCTAssertTrue(lost.checks.first { $0.name == "targetSet" }?.detail.contains("missing AcmeKit") == true)
    }

    func testNoEffectIsNotBuilt() throws {
        let fixture = try VerifyFixture(self)
        let plan = fixture.plan([VerifyFixture.step("SET-004", mechanism: .hook, reached: false)])
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB))
        let document = try fixture.harness(runner).verify(fixture.request(plan))
        XCTAssertNil(document.abort, "nothing is built through the hook, so the hook is not a precondition")
        let unit = try XCTUnwrap(document.results.first)
        XCTAssertEqual(unit.verdict, .init(status: .reverted, reason: .noEffect))
        XCTAssertTrue(runner.builds.isEmpty)
        XCTAssertEqual(unit.checks.first?.name, "oracle")
        XCTAssertEqual(unit.checks.first?.status, "fail")
        XCTAssertEqual(unit.arms.map(\.runsTotal), [0, 0])
    }

    func testPreconditionAborts() throws {
        let fixture = try VerifyFixture(self)
        let plan = fixture.plan([VerifyFixture.step("SET-004")])
        func aborted(_ configure: (ScriptedHost) -> Void, plan: FixPlanDocument? = nil,
                     mechanism: FixPlanDocument.Mechanism? = nil) throws -> VerifyDocument {
            let host = ScriptedHost()
            configure(host)
            let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB))
            let document = try fixture.harness(runner, host: host).verify(fixture.request(plan ?? fixture.plan([VerifyFixture.step("SET-004")]),
                                                                                         mechanism: mechanism))
            XCTAssertTrue(runner.builds.isEmpty, "a precondition abort builds nothing")
            XCTAssertEqual(document.results.map(\.verdict.status), [.unverified])
            return document
        }
        XCTAssertEqual(try aborted { $0.dirty = [".xcblame/overlay-Debug.xcconfig"] }.abort?.reason, .dirtyTree)
        XCTAssertEqual(try aborted { $0.battery = true }.abort?.reason, .onBattery)
        XCTAssertEqual(try aborted { $0.xcodebuilds = [4242] }.abort?.reason, .xcodebuildRunning)
        let hook = try aborted({ _ in }, mechanism: .hook)
        XCTAssertEqual(hook.abort?.reason, .hookMissing)
        XCTAssertTrue(hook.abort?.detail.contains("xcblame fix --install-hook") == true)
        XCTAssertEqual(hook.preconditions.last?.name, "hook")
        // Warnings do not abort: unknown power, no git, thermal fair at the start.
        let host = ScriptedHost()
        host.battery = nil
        host.dirty = nil
        host.thermal = ["fair"]
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB))
        let document = try fixture.harness(runner, host: host, record: false).verify(fixture.request(plan))
        XCTAssertNil(document.abort)
        XCTAssertEqual(document.preconditions.filter { $0.status == "warn" }.map(\.name), ["cleanTree", "power", "thermal"])
    }

    func testBaselineBrokenAbortsAndLeavesStepsUnverified() throws {
        let fixture = try VerifyFixture(self)
        let plan = fixture.plan([VerifyFixture.step("SET-004")])
        try FixPlanStore.save(plan, xcblameDir: fixture.xcblameDir)
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir) { build, _ in
            VerifyFixture.outcome(10, exit: build.arm == .a && build.index == 2 ? 1 : 0)
        }
        let document = try fixture.harness(runner).verify(fixture.request(plan))
        XCTAssertEqual(document.abort?.reason, .baselineBroken)
        XCTAssertEqual(document.results.first?.verdict.status, .unverified)
        XCTAssertEqual(runner.builds.map(\.build.arm), [.a, .b, .a])
        XCTAssertEqual(try FixPlanStore.load(id: plan.id, xcblameDir: fixture.xcblameDir).steps[0].verify.status, .unverified)
        XCTAssertEqual(History.listVerify(directory: fixture.xcblameDir.appendingPathComponent("history")).count, 1,
                       "an aborted run is still saved")
    }

    func testThermalRunIsReplacedOnceThenAborts() throws {
        let fixture = try VerifyFixture(self)
        let plan = fixture.plan([VerifyFixture.step("SET-004")])
        // Thermal is read for the precondition, then once after each build.
        let host = ScriptedHost()
        host.thermal = ["nominal", "nominal", "serious"]
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB))
        let document = try fixture.harness(runner, host: host, record: false).verify(fixture.request(plan))
        XCTAssertNil(document.abort)
        let unit = try XCTUnwrap(document.results.first)
        XCTAssertEqual(unit.arms[1].runs.first?.excluded, "thermal: replaced by run 2")
        XCTAssertEqual(unit.arms[1].runsTotal, 6)
        XCTAssertEqual(unit.arms[1].samples, 5)
        XCTAssertEqual(unit.checks.first { $0.name == "thermal" }?.status, "warn")
        XCTAssertEqual(unit.verdict.status, .kept)

        let hot = ScriptedHost()
        hot.thermal = ["nominal", "critical", "critical"]
        let again = try fixture.harness(ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB)),
                                        host: hot, record: false).verify(fixture.request(plan))
        XCTAssertEqual(again.abort?.reason, .thermal)
        XCTAssertEqual(again.results.first?.arms[0].runs.map(\.excluded), ["thermal: replaced by run 2", "thermal"])
    }

    func testTimeoutAbortsWithFinishedVerdictsKept() throws {
        let fixture = try VerifyFixture(self)
        let plan = fixture.plan([VerifyFixture.step("SET-004", order: 1), VerifyFixture.step("SET-016", order: 2)])
        let host = ScriptedHost()
        host.tick = 10
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB))
        // Clock: start, then one read per build (the time check): 10 s per read, 4 minutes = 24 reads.
        let document = try fixture.harness(runner, host: host, record: false)
            .verify(fixture.request(plan, kind: .zeroChange, oneByOne: true, maxMinutes: 2.5))
        XCTAssertEqual(document.abort?.reason, .timeout)
        XCTAssertEqual(document.results.map(\.verdict.status), [.kept, .unverified])
        XCTAssertTrue(document.results[1].notes.contains { $0.contains("not finished") })
    }

    func testInterruptRestoresOverlayAndAborts() throws {
        let fixture = try VerifyFixture(self)
        let overlay = VerifyOverlay.url(xcblameDir: fixture.xcblameDir, configuration: "Debug")
        let original = VerifyOverlay.header(configuration: "Debug") + "\nSWIFT_X = 1 // hand\n"
        try Data(original.utf8).write(to: overlay)
        try installHook(fixture)
        let plan = fixture.plan([VerifyFixture.step("SET-004", mechanism: .hook)], hook: hookState)
        let interrupt = VerifyInterrupt()
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB))
        runner.onBuild = { build in if build.arm == .b, build.index == 2 { interrupt.raise("SIGTERM") } }
        let document = try fixture.harness(runner, interrupt: interrupt).verify(fixture.request(plan))
        XCTAssertEqual(document.abort?.reason, .interrupted)
        XCTAssertTrue(document.abort?.detail.contains("SIGTERM") == true)
        XCTAssertEqual(try String(contentsOf: overlay, encoding: .utf8), original)
        XCTAssertEqual(runner.builds.count, 4)
    }

    var hookState: [FixPlanDocument.HookState] {
        [.init(configuration: "Debug", status: "installed", baseXCConfig: "Config/Debug.xcconfig", reason: nil)]
    }

    func installHook(_ fixture: VerifyFixture) throws {
        let base = fixture.container.deletingLastPathComponent().appendingPathComponent("Config/Debug.xcconfig")
        try FileManager.default.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("SWIFT_VERSION = 6\n\n// xcblame hook: xcblame fix --uninstall-hook removes these lines\n#include? \"../.xcblame/overlay-Debug.xcconfig\"\n".utf8)
            .write(to: base)
    }

    func testHookWritesTemporaryBlockAndRestoresBytes() throws {
        let fixture = try VerifyFixture(self)
        try installHook(fixture)
        let overlay = VerifyOverlay.url(xcblameDir: fixture.xcblameDir, configuration: "Debug")
        let plan = fixture.plan([VerifyFixture.step("SET-004", mechanism: .hook)], hook: hookState)
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB))
        let document = try fixture.harness(runner).verify(fixture.request(plan, runs: 2))
        XCTAssertNil(document.abort, "\(document.preconditions)")
        XCTAssertEqual(document.preconditions.last, .init(name: "hook", status: "pass",
                                                          detail: "Debug.xcconfig includes overlay-Debug.xcconfig"))
        for seen in runner.builds {
            XCTAssertNil(XcodebuildRunner.value(of: "-xcconfig", in: seen.build.arguments), "hook builds without -xcconfig")
            if seen.build.arm == .a {
                XCTAssertNil(seen.overlay, "arm A builds with the overlay as it is (absent)")
            } else {
                let text = try XCTUnwrap(seen.overlay)
                XCTAssertTrue(text.hasPrefix(VerifyOverlay.header(configuration: "Debug")))
                XCTAssertTrue(text.contains("\n// xcblame verify 5e1fa0b2 rule SET-004 (temporary)\n"
                    + "DEBUG_INFORMATION_FORMAT = dwarf // xcblame SET-004 (plan 5e1fa0b2)\n"
                    + "// end xcblame verify 5e1fa0b2 rule SET-004\n"), text)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlay.path), "a file verify created is removed again")

        // An existing overlay comes back byte-identical.
        let original = VerifyOverlay.header(configuration: "Debug") + "\n// xcblame plan aaaa1111 rule SET-001\n"
            + "SWIFT_COMPILATION_MODE = singlefile // xcblame SET-001 (plan aaaa1111)\n// end xcblame plan aaaa1111 rule SET-001\n"
        try Data(original.utf8).write(to: overlay)
        let again = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB))
        _ = try fixture.harness(again, record: false).verify(fixture.request(plan, runs: 2))
        XCTAssertEqual(try Data(contentsOf: overlay), Data(original.utf8))
        XCTAssertEqual(again.builds.first { $0.build.arm == .a }?.overlay, original)
        XCTAssertTrue(again.builds.first { $0.build.arm == .b }?.overlay?.hasPrefix(original) == true)
    }

    func testAutoRevertRemovesAppliedBlockOfRevertedStep() throws {
        let fixture = try VerifyFixture(self)
        try installHook(fixture)
        let overlay = VerifyOverlay.url(xcblameDir: fixture.xcblameDir, configuration: "Debug")
        let header = VerifyOverlay.header(configuration: "Debug")
        let other = "\n// xcblame plan aaaa1111 rule SET-001\nSWIFT_COMPILATION_MODE = singlefile // xcblame SET-001 (plan aaaa1111)\n"
            + "// end xcblame plan aaaa1111 rule SET-001\n"
        let mine = "\n// xcblame plan 5e1fa0b2 rule SET-030\nXCB_TEST_SET_030 = YES // xcblame SET-030 (plan 5e1fa0b2)\n"
            + "// end xcblame plan 5e1fa0b2 rule SET-030\n"
        try Data((header + other + mine).utf8).write(to: overlay)
        let plan = fixture.plan([VerifyFixture.step("SET-030", mechanism: .hook, state: .applied)], hook: hookState)
        try FixPlanStore.save(plan, xcblameDir: fixture.xcblameDir)
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterB, b: fasterA))
        let document = try fixture.harness(runner).verify(fixture.request(plan))

        XCTAssertEqual(document.results.first?.verdict, .init(status: .reverted, reason: .slower))
        // Arm A measured without the step's own applied block; B with its lines as a temporary block.
        XCTAssertEqual(runner.builds.first { $0.build.arm == .a }?.overlay, header + other)
        XCTAssertFalse(runner.builds.first { $0.build.arm == .b }?.overlay?.contains("xcblame plan 5e1fa0b2") ?? true)
        XCTAssertEqual(try String(contentsOf: overlay, encoding: .utf8), header + other, "byte-exact removal")
        let stored = try FixPlanStore.load(id: plan.id, xcblameDir: fixture.xcblameDir)
        XCTAssertEqual(stored.steps[0].state, .reverted)
        XCTAssertEqual(stored.steps[0].verify.reason, .slower)
        XCTAssertEqual(stored.events.last?.action, "revert")
        XCTAssertEqual(stored.events.last?.ruleIds, ["SET-030"])
        XCTAssertTrue(document.results[0].notes.contains { $0.hasPrefix("auto-revert") })

        // The last block gone: only the header is left, so the file goes.
        try Data((header + mine).utf8).write(to: overlay)
        try FixPlanStore.save(plan, xcblameDir: fixture.xcblameDir)
        _ = try fixture.harness(ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterB, b: fasterA)))
            .verify(fixture.request(plan))
        XCTAssertFalse(FileManager.default.fileExists(atPath: overlay.path))
    }

    func testStoredPlanWithAnotherIdIsNeverTouched() throws {
        let fixture = try VerifyFixture(self)
        let other = fixture.plan([VerifyFixture.step("SET-004", plan: "0ther000")], id: "0ther000")
        let otherURL = try FixPlanStore.save(other, xcblameDir: fixture.xcblameDir)
        let before = try Data(contentsOf: otherURL)
        let plan = fixture.plan([VerifyFixture.step("SET-004")])
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB))
        _ = try fixture.harness(runner).verify(fixture.request(plan))
        XCTAssertEqual(try Data(contentsOf: otherURL), before)
        XCTAssertEqual(try FixPlanStore.load(id: plan.id, xcblameDir: fixture.xcblameDir).steps[0].verify.status, .kept,
                       "a plan made for this run is stored with its verdicts")
    }

    func testIncrementalSettlesEachArmInItsOwnDerivedDataAndTouches() throws {
        let fixture = try VerifyFixture(self)
        let source = fixture.root.appendingPathComponent("repo/Acme/B.swift")
        let plan = fixture.plan([VerifyFixture.step("SET-016", kind: "incremental")])
        let host = ScriptedHost()
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir) { build, _ in
            VerifyFixture.outcome(build.arm == .a ? 4 : 3, sources: [.init(target: "Acme", path: source.path),
                                                                     .init(target: "Acme", path: "/z/A.swift"),
                                                                     .init(target: "Zed", path: "/a/A.swift")])
        }
        let document = try fixture.harness(runner, host: host, record: false).verify(fixture.request(plan))
        XCTAssertEqual(document.kind, .incremental)
        let builds = runner.builds.map(\.build)
        XCTAssertEqual(builds.map(\.arm), [.a, .a, .a, .a, .a, .b, .b, .b, .b, .b], "no interleaving for incremental")
        XCTAssertEqual(builds.map(\.settle), [true, false, false, false, false, true, false, false, false, false])
        XCTAssertTrue(builds.allSatisfy { !$0.clean })
        XCTAssertEqual(document.touch, source.path, "first Swift source of the first project target, alphabetical")
        XCTAssertEqual(host.touched.count, 8, "before every measured run of both arms")
        let unit = try XCTUnwrap(document.results.first)
        XCTAssertEqual(unit.arms.map(\.samples), [4, 4])
        XCTAssertEqual(unit.arms[0].runs.first?.excluded, "settle build")
        XCTAssertEqual(unit.checks.first { $0.name == "taskKinds" }?.status, "skipped")
        XCTAssertEqual(unit.verdict.status, .kept)
        XCTAssertNotEqual(builds.first?.derivedData, builds.last?.derivedData)
    }

    func testOneByOneMeasuresArmAOnce() throws {
        let fixture = try VerifyFixture(self)
        let plan = fixture.plan([VerifyFixture.step("SET-004", order: 1), VerifyFixture.step("SET-016", order: 2)])
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB))
        let document = try fixture.harness(runner, record: false).verify(fixture.request(plan, oneByOne: true))
        XCTAssertTrue(document.oneByOne)
        XCTAssertEqual(document.results.map(\.ruleIds), [["SET-004"], ["SET-016"]])
        XCTAssertEqual(document.results[0].arms[0], document.results[1].arms[0], "arm A is repeated in every unit")
        XCTAssertEqual(runner.builds.filter { $0.build.arm == .a }.count, 5)
        XCTAssertEqual(Set(runner.builds.filter { $0.build.arm == .b }.map(\.build.label)), ["B-SET-004", "B-SET-016"])
        XCTAssertEqual(document.results.map(\.verdict.status), [.kept, .kept])
    }

    func testBatchMeasuresEveryRuleTogether() throws {
        let fixture = try VerifyFixture(self)
        try installHook(fixture)
        let plan = fixture.plan([VerifyFixture.step("SET-004", order: 1, mechanism: .hook),
                                 VerifyFixture.step("SET-016", order: 2, mechanism: .hook)], hook: hookState)
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB))
        let document = try fixture.harness(runner, record: false).verify(fixture.request(plan, runs: 1))
        XCTAssertEqual(document.results.map(\.ruleIds), [["SET-004", "SET-016"]])
        let overlay = try XCTUnwrap(runner.builds.first { $0.build.arm == .b }?.overlay)
        XCTAssertTrue(overlay.contains("rule SET-004 (temporary)") && overlay.contains("rule SET-016 (temporary)"), overlay)
    }

    func testSelectionUsageErrors() throws {
        let fixture = try VerifyFixture(self)
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB))
        let mixed = fixture.plan([VerifyFixture.step("SET-004", order: 1), VerifyFixture.step("SET-016", order: 2, kind: "incremental")])
        XCTAssertThrowsError(try fixture.harness(runner).verify(fixture.request(mixed))) { error in
            XCTAssertTrue("\(error)".contains("give --kind or --one-by-one"), "\(error)")
        }
        XCTAssertNoThrow(try fixture.harness(runner, record: false).verify(fixture.request(mixed, kind: .clean)))
        let mechanisms = fixture.plan([VerifyFixture.step("SET-004", order: 1), VerifyFixture.step("SET-016", order: 2, mechanism: .hook)])
        XCTAssertThrowsError(try fixture.harness(runner).verify(fixture.request(mechanisms))) { error in
            XCTAssertTrue("\(error)".contains("give --mechanism or --one-by-one"), "\(error)")
        }
        XCTAssertThrowsError(try fixture.harness(runner).verify(fixture.request(mixed, rules: ["SET-005"]))) { error in
            XCTAssertEqual(error as? XcblameError, .usage("plan 5e1fa0b2 has no step for SET-005 (xcblame fix --rules SET-005 makes one)"))
        }
        var defaults = VerifyFixture.step("ENV-002")
        defaults.overlay = []
        defaults.mechanism = .defaults
        XCTAssertThrowsError(try fixture.harness(runner).verify(fixture.request(fixture.plan([defaults])))) { error in
            XCTAssertTrue("\(error)".contains("nothing to verify"), "\(error)")
        }
        XCTAssertTrue(runner.builds.count == 10, "only the --kind clean run built")
    }

    func testOneByOneWithMixedKindsMeasuresArmAPerKind() throws {
        let fixture = try VerifyFixture(self)
        let plan = fixture.plan([VerifyFixture.step("SET-004", order: 1), VerifyFixture.step("SET-016", order: 2, kind: "zero-change")])
        let runner = ScriptedRunner(xcblameDir: fixture.xcblameDir, script: walls(a: fasterA, b: fasterB))
        let document = try fixture.harness(runner).verify(fixture.request(plan, oneByOne: true))
        XCTAssertEqual(Set(runner.builds.filter { $0.build.arm == .a }.map(\.build.label)), ["A-clean-cli", "A-zero-change-cli"])
        XCTAssertTrue(document.notes.contains { $0.hasPrefix("kinds per unit") })
        let stored = try FixPlanStore.load(id: plan.id, xcblameDir: fixture.xcblameDir)
        XCTAssertEqual(stored.steps.map(\.verify.kind), ["clean", "zero-change"])
    }

    func testArgumentsFromPlanNeedEveryPart() throws {
        let fixture = try VerifyFixture(self)
        let plan = fixture.plan([VerifyFixture.step("SET-004")])
        XCTAssertThrowsError(try VerifyArguments.resolve(given: [], plan: plan,
                                                         historyDirectory: fixture.xcblameDir.appendingPathComponent("history"))) { error in
            XCTAssertTrue("\(error)".contains("needs the configuration, destination"), "\(error)")
        }
        XCTAssertThrowsError(try VerifyArguments.resolve(given: ["-derivedDataPath", "/tmp/x"], plan: plan,
                                                         historyDirectory: fixture.xcblameDir))
        XCTAssertEqual(VerifyArguments.destinationSpecifier(of: "macOS arm64"), "platform=macOS,arch=arm64")
        XCTAssertEqual(VerifyArguments.destinationSpecifier(of: "iOS Simulator"), "generic/platform=iOS Simulator")
        XCTAssertEqual(VerifyArguments.destinationSpecifier(of: "iOS"), "generic/platform=iOS")
        XCTAssertEqual(VerifyArguments.destinationSpecifier(of: "Mac Catalyst arm64"), "platform=macOS,variant=Mac Catalyst,arch=arm64")
    }
}
