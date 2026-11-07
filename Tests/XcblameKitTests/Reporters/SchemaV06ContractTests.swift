import XCTest
@testable import XcblameKit

/// Populated samples of the v0.6 documents (docs/SCHEMA-v0.6.md), for the contract tests and the lanes' own tests.
enum V06Samples {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let tool = ReportDocument.Tool(name: "xcblame", version: XcblameVersion.current, kindTable: KindTable.v1.version)

    static let scopeHook = FixPlanDocument.ScopeRow(
        target: "AcmeFix", configuration: "Debug", key: "DEBUG_INFORMATION_FORMAT", before: "dwarf-with-dsym",
        after: "dwarf", provenance: "projectXCConfig Config/Debug.xcconfig", mechanism: .hook, reached: true)
    static let scopeCLI = FixPlanDocument.ScopeRow(
        target: "AcmeFixKit", configuration: "Debug", key: "DEBUG_INFORMATION_FORMAT", before: "dwarf-with-dsym",
        after: "dwarf", provenance: nil, mechanism: .cli, reached: true, note: "package target: cli only")

    static let step = FixPlanDocument.Step(
        order: 1, ruleId: "SET-004", title: "Debug builds generate dSYM files", fixKind: .overlay, mechanism: .hook,
        mechanismDetail: "hook", impactBand: "S", impactSeconds: 2.5, estimatedBand: nil, confidence: "high",
        verifyOnly: false, verifyKind: "clean", scope: [scopeHook, scopeCLI],
        overlay: [.init(configuration: "Debug", key: "DEBUG_INFORMATION_FORMAT", value: "dwarf",
                        line: "DEBUG_INFORMATION_FORMAT = dwarf // xcblame SET-004 (plan 7f3a91c2)")],
        defaults: [], shadowing: .none, shadowedBy: [],
        verify: .init(status: .kept, mechanism: .hook, kind: "clean", verifyId: "20261104-101500-verify",
                      verifiedAt: date, deltaSeconds: -2.1, deltaPct: -0.124),
        state: .planned, commands: ["xcblame verify --rules SET-004 --kind clean --mechanism hook",
                                    "xcblame fix --rules SET-004 --apply"],
        inXcode: ["Build Settings › Debug Information Format (DEBUG_INFORMATION_FORMAT) for AcmeFix, Debug: DWARF with dSYM File → DWARF"],
        risk: "none in Debug")

    static let defaultsStep = FixPlanDocument.Step(
        order: 2, ruleId: "ENV-002", title: "Concurrent compile tasks capped below the core count", fixKind: .defaults,
        mechanism: .defaults, confidence: "medium", verifyOnly: false,
        defaults: [.init(key: "IDEBuildOperationMaxNumberOfConcurrentCompileTasks", value: nil, type: nil)],
        commands: ["xcblame fix --rules ENV-002 --apply-defaults"])

    static let plan = FixPlanDocument(
        tool: tool, generatedAt: date, id: "7f3a91c2",
        generatedFrom: .init(analysisId: "20261104-100000-clean", analysisPath: nil, analysisKind: "clean",
                             doctorConfigurations: ["Debug", "Release"], settingsSource: "xcodebuild", rulesFilter: []),
        project: .init(container: "/src/AcmeFix/AcmeFix.xcodeproj", generator: nil, configurations: ["Debug", "Release"],
                       scheme: "AcmeFix"),
        steps: [step, defaultsStep],
        guards: [.init(id: "hookInstalled", text: "Install the hook first: xcblame fix --install-hook", ruleIds: ["SET-004"],
                       satisfied: false)],
        hook: [.init(configuration: "Debug", status: "notInstalled", baseXCConfig: "Config/Debug.xcconfig", reason: nil)],
        commands: ["xcblame fix --install-hook", "xcblame verify --rules SET-004 --kind clean --mechanism hook",
                   "xcblame fix --rules SET-004 --apply"],
        events: [.init(at: date, action: "installHook", ruleIds: [], files: ["Config/Debug.xcconfig"], defaultsKeys: [])],
        notes: [])

    static func run(_ arm: VerifyDocument.Arm, _ index: Int, wall: Double) -> VerifyDocument.Run {
        .init(arm: arm, index: index, settle: false, ok: true, exitCode: 0, wall: wall, criticalPath: wall * 0.8,
              taskKindsHash: "0123456789abcdef", targetSetHash: "fedcba9876543210", thermal: "nominal", excluded: nil)
    }

    static let unit = VerifyDocument.UnitResult(
        ruleIds: ["SET-004"], titles: ["Debug builds generate dSYM files"], mechanism: .hook, scope: [scopeHook],
        arms: [.init(arm: .a, derivedData: "/cache/verify/7f3a91c2/A", runs: (1...5).map { run(.a, $0, wall: 17 + Double($0) * 0.1) },
                     runsTotal: 5, runsOk: 5, samples: 5, p50: 17.3, mad: 0.1),
               .init(arm: .b, derivedData: "/cache/verify/7f3a91c2/B-SET-004", runs: (1...5).map { run(.b, $0, wall: 15 + Double($0) * 0.1) },
                     runsTotal: 5, runsOk: 5, samples: 5, p50: 15.3, mad: 0.1)],
        deltaSeconds: -2, deltaPct: -0.1156, noiseBand: 0.346, verdict: .init(status: .kept),
        checks: [.init(name: "exitCode", status: "pass", detail: "10/10 builds exited 0"),
                 .init(name: "taskKinds", status: "pass", detail: "differs only by GenerateDSYMFile (declared effect of SET-004)")],
        notes: [])

    static let verify = VerifyDocument(
        tool: tool, generatedAt: date, id: "20261104-101500-verify", planId: "7f3a91c2", kind: .clean, mechanism: .hook,
        runsPerArm: 5, oneByOne: true, keepOnTie: false, maxMinutes: nil, touch: nil, scheme: "AcmeFix",
        configuration: "Debug", xcodebuildArguments: ["-project", "AcmeFix.xcodeproj", "-scheme", "AcmeFix", "build"],
        preconditions: [.init(name: "cleanTree", status: "pass", detail: "plan files committed"),
                        .init(name: "power", status: "pass", detail: "AC power")],
        results: [unit], abort: nil, elapsedSeconds: 190, xcode: "26.0.1", machine: "Mac15,14/28c/96g", notes: [])
}

/// Pins the member names of `xcblame.fixplan/1` and `xcblame.verify/1` (docs/SCHEMA-v0.6.md). Renaming, removing or
/// retyping a member breaks the contract: a lane that needs a change asks the integrator.
final class SchemaV06ContractTests: XCTestCase {
    private func keys<T: Encodable>(_ value: T) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: JSONReporter.encoder().encode(value))
        return try XCTUnwrap(object as? [String: Any]).keys.sorted()
    }

    func testFixPlanKeys() throws {
        let plan = V06Samples.plan
        XCTAssertEqual(plan.schemaVersion, "xcblame.fixplan/1")
        XCTAssertEqual(try keys(plan), ["commands", "events", "generatedAt", "generatedFrom", "guards", "hook", "id",
                                        "notes", "project", "redacted", "schemaVersion", "steps", "tool"])
        XCTAssertEqual(try keys(plan.generatedFrom), ["analysisId", "analysisKind", "analysisPath", "doctorConfigurations",
                                                      "rulesFilter", "settingsSource"])
        XCTAssertEqual(try keys(plan.project), ["configurations", "container", "generator", "scheme"])
        XCTAssertEqual(try keys(V06Samples.step), ["commands", "confidence", "defaults", "estimatedBand", "fixKind",
                                                   "impactBand", "impactSeconds", "inXcode", "mechanism", "mechanismDetail",
                                                   "order", "overlay", "risk", "ruleId", "scope", "shadowedBy", "shadowing",
                                                   "state", "stateReason", "title", "verify", "verifyKind", "verifyOnly"])
        XCTAssertEqual(try keys(V06Samples.scopeHook), ["after", "before", "configuration", "key", "mechanism", "note",
                                                        "provenance", "reached", "target"])
        XCTAssertEqual(try keys(V06Samples.step.overlay[0]), ["condition", "configuration", "key", "line", "value"])
        XCTAssertEqual(try keys(V06Samples.defaultsStep.defaults[0]), ["domain", "key", "type", "value"])
        XCTAssertEqual(try keys(V06Samples.step.verify), ["basis", "deltaPct", "deltaSeconds", "kind", "mechanism", "reason",
                                                          "status", "tie", "verifiedAt", "verifyId"])
        XCTAssertEqual(try keys(plan.guards[0]), ["id", "ruleIds", "satisfied", "text"])
        XCTAssertEqual(try keys(plan.hook[0]), ["baseXCConfig", "configuration", "reason", "status"])
        XCTAssertEqual(try keys(plan.events[0]), ["action", "at", "defaultsKeys", "files", "ruleIds"])
    }

    func testVerifyKeys() throws {
        let verify = V06Samples.verify
        XCTAssertEqual(verify.schemaVersion, "xcblame.verify/1")
        XCTAssertEqual(try keys(verify), ["abort", "configuration", "elapsedSeconds", "generatedAt", "id", "keepOnTie",
                                          "kind", "machine", "maxMinutes", "mechanism", "noiseModel", "notes", "oneByOne",
                                          "planId", "preconditions", "redacted", "results", "runsPerArm", "schemaVersion",
                                          "scheme", "tool", "touch", "wallBasis", "xcode", "xcodebuildArguments"])
        XCTAssertEqual(try keys(V06Samples.unit), ["arms", "basis", "checks", "deltaPct", "deltaSeconds", "mechanism", "noiseBand",
                                                   "notes", "ruleIds", "scope", "titles", "verdict"])
        XCTAssertEqual(try keys(V06Samples.unit.arms[0]), ["arm", "derivedData", "mad", "p50", "runs", "runsOk",
                                                           "runsTotal", "samples"])
        XCTAssertEqual(try keys(V06Samples.unit.arms[0].runs[0]), ["arm", "criticalPath", "excluded", "exitCode", "index",
                                                                   "ok", "settle", "targetSetHash", "taskKindsHash",
                                                                   "thermal", "wall"])
        XCTAssertEqual(try keys(V06Samples.unit.verdict), ["reason", "status", "tie"])
        XCTAssertEqual(try keys(verify.noiseModel), ["madMultiplier", "minPct", "minRuns", "minSamples"])
        XCTAssertEqual(try keys(VerifyDocument.Abort(reason: .timeout, detail: "--max-minutes 30 passed")), ["detail", "reason"])
    }

    func testClosedVocabularies() {
        XCTAssertEqual(FixPlanDocument.FixKind.allCases.map(\.rawValue),
                       ["overlay", "cli", "defaults", "scheme", "project", "manifest", "recommend", "measure"])
        XCTAssertEqual(FixPlanDocument.Mechanism.allCases.map(\.rawValue), ["hook", "cli", "defaults", "recommend"])
        XCTAssertEqual(FixPlanDocument.VerifyStatus.allCases.map(\.rawValue), ["unverified", "kept", "reverted", "indicative"])
        XCTAssertEqual(FixPlanDocument.RevertReason.allCases.map(\.rawValue),
                       ["slower", "withinNoise", "brokeBuild", "taskSetChanged", "noEffect"])
        XCTAssertEqual(FixPlanDocument.StepState.allCases.map(\.rawValue), ["planned", "applied", "applied-cli", "reverted", "skipped"])
        XCTAssertEqual(VerifyDocument.Kind.allCases.map(\.rawValue), ["clean", "incremental", "zero-change"])
        XCTAssertEqual(VerifyDocument.AbortReason.allCases.map(\.rawValue),
                       ["dirtyTree", "onBattery", "xcodebuildRunning", "thermal", "timeout", "baselineBroken",
                        "interrupted", "hookMissing"])
        XCTAssertEqual(VerifyDocument.NoiseModel.v06, .init(madMultiplier: 3, minPct: 0.02, minSamples: 3, minRuns: 4))
    }

    func testDocumentsRoundTripThroughJSON() throws {
        let plan = try JSONReporter.decoder().decode(FixPlanDocument.self, from: JSONReporter.render(V06Samples.plan))
        XCTAssertEqual(plan, V06Samples.plan)
        let verify = try JSONReporter.decoder().decode(VerifyDocument.self, from: JSONReporter.render(V06Samples.verify))
        XCTAssertEqual(verify, V06Samples.verify)
        // Nil members serialize as explicit nulls (§8.1).
        let json = String(decoding: try JSONReporter.render(V06Samples.verify), as: UTF8.self)
        XCTAssertTrue(json.contains("\"abort\" : null"), json)
    }

    func testPlanStoreSavesLoadsByPrefixAndListsNewestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-plans-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        var older = V06Samples.plan
        older.id = "7f00aaaa"
        older.generatedAt = V06Samples.date.addingTimeInterval(-60)
        try FixPlanStore.save(older, xcblameDir: dir)
        let url = try FixPlanStore.save(V06Samples.plan, xcblameDir: dir)
        XCTAssertEqual(url.lastPathComponent, "7f3a91c2.json")
        XCTAssertEqual(try FixPlanStore.load(id: "7f3a", xcblameDir: dir), V06Samples.plan)
        XCTAssertEqual(FixPlanStore.list(xcblameDir: dir).map(\.id), ["7f3a91c2", "7f00aaaa"])
        XCTAssertThrowsError(try FixPlanStore.load(id: "7f", xcblameDir: dir)) { error in
            XCTAssertEqual(error as? FixPlanStore.StoreError, .ambiguous("7f", ["7f3a91c2", "7f00aaaa"]))
        }
        XCTAssertThrowsError(try FixPlanStore.load(id: "beef", xcblameDir: dir))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(".gitignore"), encoding: .utf8), stateIgnoreLines)
    }

    /// Lane C replaced the phase-1 stubs (Decision 20); the full checks are in `HTMLVerifyTests` / `HTMLClarityTests`.
    func testLaneCReportersRenderTheSamples() throws {
        XCTAssertFalse(try HTMLReporter.renderVerify(V06Samples.verify, options: .init(redact: false, maxBytes: 1 << 20, title: "t")).isEmpty)
        XCTAssertFalse(try HTMLReporter.renderFixPlan(V06Samples.plan, options: .init(redact: false, maxBytes: 1 << 20, title: "t")).isEmpty)
    }
}
