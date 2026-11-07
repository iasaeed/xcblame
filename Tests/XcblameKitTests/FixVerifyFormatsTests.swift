import XCTest
@testable import XcblameKit

/// Sample v0.6 documents built from the frozen types (synthetic names only): a verify run with one kept, one
/// reverted (slower) and one reverted (broke build) unit, an aborted run, and a plan with hook, cli, defaults and
/// recommend steps plus a shadowed one.
enum FixVerifySamples {
    static let date = V06Samples.date
    static let tool = V06Samples.tool

    static func runs(_ arm: VerifyDocument.Arm, _ walls: [Double], failAt: Int? = nil) -> [VerifyDocument.Run] {
        walls.enumerated().map { offset, wall in
            let ok = offset + 1 != failAt
            return .init(arm: arm, index: offset + 1, settle: false, ok: ok, exitCode: ok ? 0 : 65, wall: wall,
                         criticalPath: wall * 0.8, taskKindsHash: "0123456789abcdef", targetSetHash: "fedcba9876543210",
                         thermal: "nominal", excluded: ok ? nil : "failed")
        }
    }

    static let armA = VerifyDocument.ArmResult(arm: .a, derivedData: "/Users/sam/Library/Caches/xcblame/verify/5ab3c2d1/A",
                                               runs: runs(.a, [20.1, 20.0, 20.3, 19.9, 20.2]), runsTotal: 5, runsOk: 5,
                                               samples: 5, p50: 20.1, mad: 0.1)

    static func unit(_ rule: String, _ title: String, b: [Double], p50: Double?, verdict: VerifyDocument.Verdict,
                     failAt: Int? = nil, band: Double? = 0.424, mechanism: FixPlanDocument.Mechanism = .hook) -> VerifyDocument.UnitResult {
        let bRuns = runs(.b, b, failAt: failAt)
        let ok = bRuns.filter(\.ok).count
        let delta = p50.map { ReportDocument.round6($0 - 20.1) }
        return .init(ruleIds: [rule], titles: [title], mechanism: mechanism,
                     scope: [.init(target: "Acme", configuration: "Debug", key: "KEY", before: "a", after: "b",
                                   provenance: "projectXCConfig Config/Debug.xcconfig", mechanism: mechanism, reached: true),
                             .init(target: "AcmeLegacy", configuration: "Debug", key: "KEY", before: "a", after: "a",
                                   provenance: "targetSettings", mechanism: mechanism, reached: false)],
                     arms: [armA, .init(arm: .b, derivedData: nil, runs: bRuns, runsTotal: bRuns.count, runsOk: ok,
                                        samples: ok, p50: p50, mad: p50 == nil ? nil : 0.1)],
                     deltaSeconds: delta, deltaPct: delta.map { ReportDocument.round6($0 / 20.1) }, noiseBand: band,
                     verdict: verdict,
                     checks: [.init(name: "exitCode", status: failAt == nil ? "pass" : "fail",
                                    detail: failAt == nil ? "10/10 builds exited 0" : "build \(failAt ?? 0) of arm B exited 65")],
                     notes: [])
    }

    static let kept = unit("SET-004", "Debug builds generate dSYM files", b: [17.9, 18.1, 18.0, 17.8, 18.2], p50: 18.0,
                           verdict: .init(status: .kept))
    static let slower = unit("SET-016", "Swift flags add a frontend option", b: [21.0, 21.2, 20.9, 21.1, 21.3], p50: 21.1,
                             verdict: .init(status: .reverted, reason: .slower))
    static let broke = unit("SET-030", "Script phases run without the sandbox", b: [19.0, 2.0, 19.1, 19.2, 19.0], p50: 19.05,
                            verdict: .init(status: .reverted, reason: .brokeBuild), failAt: 2)

    static func verify(results: [VerifyDocument.UnitResult] = [kept, slower, broke], abort: VerifyDocument.Abort? = nil,
                       kind: VerifyDocument.Kind = .clean) -> VerifyDocument {
        VerifyDocument(tool: tool, generatedAt: date, id: "20261105-101500-verify", planId: "5ab3c2d1", kind: kind,
                       mechanism: nil, runsPerArm: 5, oneByOne: true, keepOnTie: false, maxMinutes: abort == nil ? nil : 30,
                       touch: nil, scheme: "Acme", configuration: "Debug",
                       xcodebuildArguments: ["-project", "/Users/sam/src/Acme/Acme.xcodeproj", "-scheme", "Acme", "build"],
                       preconditions: [.init(name: "cleanTree", status: "pass", detail: "plan files committed"),
                                       .init(name: "thermal", status: "warn", detail: "fair at the start")],
                       results: results, abort: abort, elapsedSeconds: 640, xcode: "26.0.1", machine: "Mac15,14/28c/96g",
                       notes: ["arm A was measured once and repeated in every unit (--one-by-one)"])
    }

    static let aborted = verify(results: [kept, unit("SET-016", "Swift flags add a frontend option", b: [], p50: nil,
                                                     verdict: .init(status: .unverified), band: nil)],
                                abort: .init(reason: .timeout, detail: "30 minutes passed after 12 builds"))

    static let indicative = verify(results: [unit("SET-004", "Debug builds generate dSYM files", b: [18.0, 18.1], p50: 18.05,
                                                  verdict: .init(status: .indicative), band: nil, mechanism: .cli)])

    // MARK: Plan

    static func scope(_ target: String, _ mechanism: FixPlanDocument.Mechanism, reached: Bool = true,
                      provenance: String = "projectXCConfig Config/Debug.xcconfig") -> FixPlanDocument.ScopeRow {
        .init(target: target, configuration: "Debug", key: "SWIFT_COMPILATION_MODE", before: "wholemodule",
              after: reached ? "singlefile" : "wholemodule", provenance: provenance, mechanism: mechanism, reached: reached)
    }

    static let plan: FixPlanDocument = {
        var hook = V06Samples.step
        hook.verify = .init(status: .kept, mechanism: .hook, kind: "clean", verifyId: "20261105-101500-verify",
                            verifiedAt: date, deltaSeconds: -2.1, deltaPct: -0.104)
        let shadowed = FixPlanDocument.Step(
            order: 2, ruleId: "SET-001", title: "Debug compiles the whole module at once", fixKind: .overlay, mechanism: .cli,
            mechanismDetail: "cli on CI; shadowed for AcmeLegacy by target settings", impactBand: "M", impactSeconds: 9.5,
            confidence: "high", verifyOnly: false, verifyKind: "incremental",
            scope: [scope("Acme", .hook), scope("AcmeLegacy", .hook, reached: false, provenance: "targetSettings"),
                    scope("Acme", .cli), scope("AcmeLegacy", .cli)],
            overlay: [.init(configuration: "Debug", key: "SWIFT_COMPILATION_MODE", value: "singlefile",
                            line: "SWIFT_COMPILATION_MODE = singlefile // xcblame SET-001 (plan 5ab3c2d1)")],
            shadowing: .partial, shadowedBy: ["targetSettings"],
            verify: .init(status: .reverted, reason: .withinNoise, mechanism: .cli, kind: "incremental", deltaSeconds: 0.05, deltaPct: 0.002),
            state: .skipped, stateReason: "verified through cli; deliver with xcblame build --overlay on CI, or verify again with --mechanism hook",
            commands: ["xcblame verify --rules SET-001 --kind incremental --mechanism cli"],
            inXcode: ["Build Settings › Compilation Mode (SWIFT_COMPILATION_MODE) for AcmeLegacy, Debug: Whole Module → Incremental"])
        var defaults = V06Samples.defaultsStep
        defaults.order = 3
        let recommend = FixPlanDocument.Step(
            order: 4, ruleId: "PHASE-001", title: "A run script phase has no declared outputs", fixKind: .recommend,
            mechanism: .recommend, estimatedBand: "S", confidence: "medium", verifyOnly: true,
            inXcode: ["Target Acme › Build Phases › Run Script \"Stamp\": add an output file"])
        return FixPlanDocument(
            tool: tool, generatedAt: date, id: "5ab3c2d1",
            generatedFrom: .init(analysisId: "20261105-100000-clean", analysisPath: nil, analysisKind: "clean",
                                 doctorConfigurations: ["Debug"], settingsSource: "xcodebuild", rulesFilter: []),
            project: .init(container: "/Users/sam/src/Acme/Acme.xcodeproj", generator: nil, configurations: ["Debug"], scheme: "Acme"),
            steps: [hook, shadowed, defaults, recommend],
            guards: [.init(id: "hookInstalled", text: "Install the hook first: xcblame fix --install-hook", ruleIds: ["SET-004"], satisfied: false),
                     .init(id: "cleanTree", text: "Commit the plan's files before verify", satisfied: nil)],
            hook: [.init(configuration: "Debug", status: "notInstalled", baseXCConfig: "Config/Debug.xcconfig", reason: nil)],
            commands: ["xcblame fix --install-hook", "xcblame verify --rules SET-004 --kind clean --mechanism hook",
                       "xcblame fix --rules SET-004 --apply"],
            events: [], notes: ["PHASE-001 is a manual step: xcblame writes no project file in 0.6"])
    }()
}

/// Text, markdown and agent output of the v0.6 documents (docs/SCHEMA-v0.6.md "Text, formats, JSON Schema").
final class FixVerifyFormatsTests: XCTestCase {
    private func options(_ cap: Int) -> FormatOptions { FormatOptions(maxBytes: cap) }

    func testVerifyTextShowsArmsMarksBandVerdictMechanismAndScope() {
        let text = TextReporter.renderVerify(FixVerifySamples.verify())
        XCTAssertTrue(text.hasPrefix("xcblame verify 20261105-101500-verify · plan 5ab3c2d1 · clean builds · 5 runs per arm · scheme Acme · Debug\n"), text)
        XCTAssertTrue(text.contains("  kept 1, reverted 2\n"), text)
        XCTAssertTrue(text.contains("  A (without)  5/5      ✓✓✓✓✓     20.10 s ± 0.10 s\n"), text)
        XCTAssertTrue(text.contains("  B (with)     4/5      ✓✗✓✓✓     19.05 s ± 0.10 s\n"), text)
        XCTAssertTrue(text.contains("  delta -2.10 s (-10.4 %) · noise band 0.42 s\n"), text)
        XCTAssertTrue(text.contains("  verdict kept: Turning on SET-004 made clean builds 2.10 s faster (10.4 %), more than the noise band (0.42 s): kept.\n"), text)
        XCTAssertTrue(text.contains("  verdict reverted (slower): Turning on SET-016 made clean builds 1.00 s slower (5.0 %)"), text)
        XCTAssertTrue(text.contains("  verdict reverted (broke build): Turning on SET-030 broke the build"), text)
        XCTAssertTrue(text.contains("  mechanism hook: the overlay file, read through one #include? line (the hook)"), text)
        XCTAssertTrue(text.contains("  scope reaches 1 of 2: Acme (Debug); not reached (shadowed): AcmeLegacy (Debug): set by targetSettings\n"), text)
        XCTAssertTrue(text.contains("  checks exitCode fail: build 2 of arm B exited 65\n"), text)
        XCTAssertTrue(text.contains("  preconditions: thermal warn: fair at the start\n"), text)
        XCTAssertTrue(text.contains("NEXT\n  1. xcblame fix --rules SET-004 --apply\n"), text)
        XCTAssertFalse(text.contains("ABORTED"))
        XCTAssertFalse(text.contains("\u{1B}["), "no colors unless asked")
        XCTAssertTrue(TextReporter.renderVerify(FixVerifySamples.verify(), colors: true).contains("\u{1B}[1m"))
    }

    func testVerifyTextAbortAndIndicative() {
        let aborted = TextReporter.renderVerify(FixVerifySamples.aborted)
        XCTAssertTrue(aborted.contains("ABORTED  --max-minutes passed: give more minutes, or verify fewer rules (--rules).\n  30 minutes passed after 12 builds\n"), aborted)
        XCTAssertTrue(aborted.contains("kept 1, reverted 0, unverified 1 (the run stopped early)"), aborted)
        XCTAssertTrue(aborted.contains("verdict unverified: SET-016 was not measured (the run stopped first): unverified."), aborted)
        XCTAssertTrue(aborted.contains("n/a (no samples)"), aborted)
        XCTAssertTrue(aborted.contains("noise band none (too few samples)"), aborted)
        XCTAssertTrue(aborted.contains("  2. xcblame verify --plan 5ab3c2d1\n"), aborted)
        let indicative = TextReporter.renderVerify(FixVerifySamples.indicative)
        XCTAssertTrue(indicative.contains("verdict indicative: Turning on SET-004 changed clean builds by -2.05 s (-10.2 %), but 5 run(s) per arm cannot tell that from noise"), indicative)
        XCTAssertTrue(indicative.contains("1. xcblame verify --rules SET-004 --runs 5"), indicative)
        let incremental = TextReporter.renderVerify(FixVerifySamples.verify(kind: .incremental))
        XCTAssertTrue(incremental.contains("the first run of each arm is the unmeasured settle build"))
    }

    func testVerdictSpellingIsTheContracts() {
        let cases: [(FixPlanDocument.VerifyStatus, FixPlanDocument.RevertReason?, Bool, String)] = [
            (.kept, nil, false, "kept"), (.kept, nil, true, "kept (tie)"), (.reverted, .slower, false, "reverted (slower)"),
            (.reverted, .withinNoise, false, "reverted (within noise)"), (.reverted, .brokeBuild, false, "reverted (broke build)"),
            (.reverted, .taskSetChanged, false, "reverted (task set changed)"), (.reverted, .noEffect, false, "reverted (no effect)"),
            (.indicative, nil, false, "indicative"), (.unverified, nil, false, "unverified"),
        ]
        for (status, reason, tie, spelling) in cases { XCTAssertEqual(FixVerifyWords.label(status, reason, tie: tie), spelling) }
        for reason in VerifyDocument.AbortReason.allCases {
            XCTAssertFalse(FixVerifyWords.abortSentence(.init(reason: reason, detail: "")).isEmpty)
        }
    }

    func testFixPlanTextListsStepsGuardsHookAndCommands() {
        let text = TextReporter.renderFixPlan(FixVerifySamples.plan)
        XCTAssertTrue(text.hasPrefix("xcblame fix plan 5ab3c2d1 · Acme.xcodeproj · scheme Acme · Debug\n"), text)
        XCTAssertTrue(text.contains("  from history entry 20261105-100000-clean (clean build) · settings from xcodebuild\n"), text)
        XCTAssertTrue(text.contains("  4 steps: 2 overlay, 1 defaults, 1 recommend · verify: 1 kept, 1 reverted (within noise), 2 unverified\n"), text)
        XCTAssertTrue(text.contains("  1. SET-004  Debug builds generate dSYM files\n     measured S, about 2.50 s · confidence high · fix kind overlay\n"), text)
        XCTAssertTrue(text.contains("     how: hook, the overlay file, read through one #include? line (the hook)"), text)
        XCTAssertTrue(text.contains("     verify: kept (-2.10 s (-10.4 %); clean builds through hook)\n"), text)
        XCTAssertTrue(text.contains("     scope hook: reaches 1 of 1: AcmeFix (Debug)\n     scope cli: reaches 1 of 1: AcmeFixKit (Debug)\n"), text)
        XCTAssertTrue(text.contains("     overlay Debug: DEBUG_INFORMATION_FORMAT = dwarf // xcblame SET-004 (plan 7f3a91c2)\n"), text)
        XCTAssertTrue(text.contains("     scope hook: reaches 1 of 2: Acme (Debug); not reached (shadowed): AcmeLegacy (Debug): set by targetSettings\n"), text)
        XCTAssertTrue(text.contains("     shadowed (partial) for the hook by targetSettings\n"), text)
        XCTAssertTrue(text.contains("     state: skipped: verified through cli; deliver with xcblame build --overlay on CI"), text)
        XCTAssertTrue(text.contains("     defaults: defaults delete com.apple.dt.Xcode IDEBuildOperationMaxNumberOfConcurrentCompileTasks\n"), text)
        XCTAssertTrue(text.contains("     verify: unverified (verify does not measure defaults steps)\n"), text)
        XCTAssertTrue(text.contains("     +V: written only after verify keeps it"), text)
        XCTAssertTrue(text.contains("     by hand: Target Acme › Build Phases › Run Script \"Stamp\": add an output file\n"), text)
        XCTAssertTrue(text.contains("GUARDS\n  [ ] Install the hook first: xcblame fix --install-hook (SET-004)\n  [?] Commit the plan's files before verify\n"), text)
        XCTAssertTrue(text.contains("HOOK\n  Debug: not installed (Config/Debug.xcconfig): xcblame fix --install-hook appends one #include? line\n"), text)
        XCTAssertTrue(text.contains("RUN\n  1. xcblame fix --install-hook\n  2. xcblame verify --rules SET-004 --kind clean --mechanism hook\n  3. xcblame fix --rules SET-004 --apply\n"), text)
        XCTAssertTrue(text.hasSuffix("nothing in the project changed: the plan is stored in xcblame's state (plans/5ab3c2d1.json)\n"), text)
        let order = ["STEPS", "GUARDS", "HOOK", "RUN"].compactMap { text.range(of: "\n\($0)\n")?.lowerBound }
        XCTAssertEqual(order, order.sorted())
        XCTAssertEqual(order.count, 4)
        XCTAssertTrue(TextReporter.renderFixPlan(FixVerifySamples.plan, wrote: true).contains("the project changed: see WRITES"))
    }

    func testMarkdownOfBothDocuments() throws {
        let verify = try MarkdownReporter.render(FixVerifySamples.verify(), options: options(64 * 1024))
        XCTAssertTrue(verify.hasPrefix(MarkdownReporter.verifyMarker + "\n## xcblame verify: kept 1, reverted 2\n"), verify)
        XCTAssertTrue(verify.contains("| Rule | Arm | Runs ok | Each run | p50 ± MAD | Delta | Noise band | Verdict | Mechanism |"), verify)
        XCTAssertTrue(verify.contains("| SET-004 | A | 5/5 | ✓✓✓✓✓ | 20.10 s ± 0.10 s |  |  |  |  |\n|  | B | 5/5 | ✓✓✓✓✓ | 18.00 s ± 0.10 s | -2.10 s (-10.4 %) | 0.42 s | **kept** | hook |"), verify)
        XCTAssertTrue(verify.contains("**reverted (broke build)**"))
        XCTAssertTrue(verify.contains("```sh\nxcblame fix --rules SET-004 --apply\n```"), verify)
        XCTAssertTrue(verify.hasSuffix("<sub>xcblame \(FixVerifySamples.tool.version), xcblame.verify/1</sub>\n"), verify)
        let aborted = try MarkdownReporter.render(FixVerifySamples.aborted, options: options(64 * 1024))
        XCTAssertTrue(aborted.contains("**Aborted (timeout):** --max-minutes passed"), aborted)

        let plan = try MarkdownReporter.render(FixVerifySamples.plan, options: options(64 * 1024))
        XCTAssertTrue(plan.hasPrefix(MarkdownReporter.fixPlanMarker + "\n## xcblame fix plan 5ab3c2d1: 4 steps\n"), plan)
        XCTAssertTrue(plan.contains("| 1 | SET-004 | Debug builds generate dSYM files | measured S, about 2.50 s | overlay | hook | kept |"), plan)
        XCTAssertTrue(plan.contains("| 2 | SET-001 |"), plan)
        XCTAssertTrue(plan.contains("reverted (within noise), skipped"), plan)
        XCTAssertTrue(plan.contains("- [ ] Install the hook first: xcblame fix --install-hook (SET-004)"), plan)
        XCTAssertTrue(plan.contains("### Run\n\n```sh\nxcblame fix --install-hook\n"), plan)
        XCTAssertTrue(plan.contains("<details><summary>Lines each step writes</summary>"), plan)
        XCTAssertTrue(plan.contains("Nothing in the project changed."))
    }

    func testAgentOfBothDocuments() throws {
        let verify = try AgentReporter.render(FixVerifySamples.verify(), options: options(8 * 1024))
        XCTAssertTrue(verify.hasPrefix("xcblame \(FixVerifySamples.tool.version) agent verify (xcblame.verify/1)\nresult: kept 1, reverted 2\n"), verify)
        XCTAssertTrue(verify.contains("- SET-030: reverted (broke build); Turning on SET-030 broke the build"), verify)
        XCTAssertTrue(verify.contains("  B: runs ok 4/5 ✓✗✓✓✓; p50 ± MAD 19.05 s ± 0.10 s\n"), verify)
        XCTAssertTrue(verify.hasSuffix("next: xcblame fix --rules SET-004 --apply\n"), verify)
        let aborted = try AgentReporter.render(FixVerifySamples.aborted, options: options(8 * 1024))
        XCTAssertTrue(aborted.contains("ABORTED (timeout): --max-minutes passed"), aborted)
        XCTAssertTrue(aborted.hasSuffix("then: xcblame verify --plan 5ab3c2d1\n"), aborted)

        let plan = try AgentReporter.render(FixVerifySamples.plan, options: options(8 * 1024))
        XCTAssertTrue(plan.contains("1. SET-004 [overlay via hook; verify: kept] Debug builds generate dSYM files"), plan)
        XCTAssertTrue(plan.contains("4. PHASE-001 [recommend via recommend; verify: unverified, +V]"), plan)
        XCTAssertTrue(plan.hasSuffix("next: xcblame fix --install-hook\n"), plan)
    }

    func testSizeCapsHoldAndKeepTheHeadAndTail() throws {
        let many = FixVerifySamples.verify(results: (1...400).map { index in
            FixVerifySamples.unit("SET-\(index)", String(repeating: "long title ", count: 8), b: [18, 18.1, 18.2, 18.3, 18.4],
                                  p50: 18.2, verdict: .init(status: .kept))
        })
        var bigPlan = FixVerifySamples.plan
        bigPlan.steps = (1...400).map { index in
            var step = FixVerifySamples.plan.steps[0]
            step.order = index
            step.ruleId = "SET-\(index)"
            return step
        }
        for cap in [8 * 1024, 64 * 1024, 2000] {
            let md = try MarkdownReporter.render(many, options: options(cap))
            XCTAssertLessThanOrEqual(md.utf8.count, cap, "markdown verify at \(cap)")
            XCTAssertTrue(md.contains("_Truncated to fit"), "markdown verify at \(cap) says it was cut")
            let mdPlan = try MarkdownReporter.render(bigPlan, options: options(cap))
            XCTAssertLessThanOrEqual(mdPlan.utf8.count, cap, "markdown plan at \(cap)")
            let agent = try AgentReporter.render(many, options: options(cap))
            XCTAssertLessThanOrEqual(agent.utf8.count, cap, "agent verify at \(cap)")
            XCTAssertTrue(agent.contains("[truncated]"))
            XCTAssertTrue(agent.contains("\nnext: xcblame fix --rules SET-1,SET-2,"), "the next line stays at \(cap)")
            let agentPlan = try AgentReporter.render(bigPlan, options: options(cap))
            XCTAssertLessThanOrEqual(agentPlan.utf8.count, cap, "agent plan at \(cap)")
            XCTAssertTrue(agentPlan.hasPrefix("xcblame \(FixVerifySamples.tool.version) agent fix plan"))
            XCTAssertTrue(agentPlan.hasSuffix("next: xcblame fix --install-hook\n"), "the next line stays at \(cap)")
        }
    }

    func testJSONPassthroughAndRedaction() throws {
        let plan = FixVerifySamples.plan
        XCTAssertEqual(try JSONReporter.decoder().decode(FixPlanDocument.self, from: try JSONReporter.render(plan)), plan)
        let verify = FixVerifySamples.verify()
        XCTAssertEqual(try JSONReporter.decoder().decode(VerifyDocument.self, from: try JSONReporter.render(verify)), verify)
        let context = Redactor.Context(home: "/Users/sam", user: "sam", host: "sams-mac")
        let redactedPlan = try ReportPipeline.prepareForOutput(plan, redact: true, context: context)
        XCTAssertTrue(redactedPlan.redacted)
        XCTAssertEqual(redactedPlan.project.container, "~/src/Acme/Acme.xcodeproj")
        XCTAssertEqual(redactedPlan.steps, plan.steps, "rule data has no personal paths")
        let redactedVerify = try ReportPipeline.prepareForOutput(verify, redact: true, context: context)
        XCTAssertTrue(redactedVerify.redacted)
        XCTAssertEqual(redactedVerify.results[0].arms[0].derivedData, "~/Library/Caches/xcblame/verify/5ab3c2d1/A")
        XCTAssertEqual(redactedVerify.xcodebuildArguments[1], "~/src/Acme/Acme.xcodeproj")
        XCTAssertFalse(String(decoding: try JSONReporter.render(redactedVerify), as: UTF8.self).contains("/Users/sam"))
        let untouched = try ReportPipeline.prepareForOutput(verify, redact: false, context: context)
        XCTAssertEqual(untouched, verify)
    }
}
