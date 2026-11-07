import XCTest
@testable import XcblameKit

/// The engine around the predicates: invariants, dedupe, RULES.md §10 conflicts, shadowing, confidence, bands,
/// generated-project downgrade, selection, gates, fail-on.
final class RulesEngineTests: XCTestCase {
    private let acme = RulesFixtures.acmeApp()

    private func run(_ model: ProjectModel, extra: [String: [String: [String: String]]] = [:], xcode: String? = "26.0.1",
                     isCI: Bool = false, offline: Bool = false, source: EffectiveSettings.Source = .xcodebuild,
                     analysis: Analysis? = nil, document: ReportDocument? = nil, rules: [String]? = nil) -> RuleResult {
        let settings = RulesFixtures.effective(model, source: source, extra: extra)
        return RulesFixtures.run(RulesFixtures.context(model, settings: settings, xcode: xcode, env: RulesFixtures.env(),
                                                       isCI: isCI, offline: offline, analysis: analysis, document: document),
                                 rules: rules)
    }

    // MARK: - Invariants (docs/SCHEMA-v0.3.md 1-6)

    func testEveryEvaluatedRuleLandsInExactlyOneList() {
        for model in [acme, RulesFixtures.acmeLegacy(), RulesFixtures.podsLike(), RulesFixtures.genXcodeGen(),
                      RulesFixtures.genTuist()] {
            let result = run(model)
            let findingIds = Set(result.findings.map(\.ruleId))
            let lists = [findingIds, Set(result.passed.map(\.ruleId)), Set(result.notApplicable.map(\.ruleId)),
                         Set(result.suppressed.map(\.ruleId))]
            XCTAssertEqual(lists.map(\.count).reduce(0, +), lists.reduce(Set<String>()) { $0.union($1) }.count, "disjoint")
            XCTAssertEqual(lists.reduce(Set<String>()) { $0.union($1) }, Set(RuleCatalog.all.map(\.id)), "all evaluated")
            XCTAssertEqual(result.rulesEvaluated, 49)
            XCTAssertEqual(Set(result.ruleDocs.keys), findingIds, "ruleDocs keys == finding rule ids")
            XCTAssertEqual(Set(result.findings.map(\.signalKey)).count, result.findings.count, "unique signal keys")
            XCTAssertFalse(result.findings.contains { $0.confidence == "high" }, "doctor never says high")
            for finding in result.findings { XCTAssertEqual(finding.evidence.count, finding.evidenceDetails.count, finding.ruleId) }
            // Fix-plan order: measured (or not +V/[K]) before "needs measurement".
            let flags = result.findings.map(\.needsMeasurement)
            XCTAssertEqual(flags, flags.sorted { !$0 && $1 }, "needs measurement last")
            let doc = ReportDocument.makeDoctor(project: model, settings: [:], result: result, configurations: [],
                                                environment: nil, xcode: nil, generatedAt: Date(), durationSeconds: nil,
                                                offline: false, failOn: nil)
            // Every finding command is in the plan, in order per finding; a build-setting project edit is measured first;
            // the other steps are inserted verify/check steps or manual Xcode steps (RulePlan).
            XCTAssertEqual(doc.fixPlan.map(\.order), Array(1...max(1, doc.fixPlan.count)).prefix(doc.fixPlan.count).map { $0 })
            for finding in result.findings {
                let planned = doc.fixPlan.filter { $0.ruleId == finding.ruleId }.map(\.command)
                XCTAssertEqual(planned.filter { finding.fixCommands.contains($0) }.count >= finding.fixCommands.count,
                               true, finding.ruleId)
            }
            let extra = doc.fixPlan.filter { step in !result.findings.contains { $0.fixCommands.contains(step.command) } }
            XCTAssertTrue(extra.allSatisfy { ["verify", "check", "manual"].contains($0.kind ?? "") }, "\(extra)")
            for (index, step) in doc.fixPlan.enumerated() where step.command.contains("--edit-project") && step.ruleId.hasPrefix("SET-") {
                XCTAssertTrue(doc.fixPlan[..<index].contains { $0.ruleId == step.ruleId && $0.kind == "verify" }, step.command)
            }
        }
    }

    // MARK: - Fixture inventory (docs/SCHEMA-v0.3.md), real reader and oracle

    /// Rules the inventory does not list but every Xcode 26 fixture triggers: SET-016 (caching unset; the inventory
    /// names it for AcmeApp only) and SET-029 (no fixture writes `COPY_PHASE_STRIP = NO` for Debug as Xcode's templates
    /// do, so the platform default YES applies; AcmeApp writes NO).
    private let xcode26Everywhere: Set<String> = ["SET-016", "SET-029"]

    func testAcmeAppMatchesTheFixtureInventory() throws {
        let (_, result) = try RulesFixtures.real("AcmeApp/AcmeApp.xcodeproj")
        XCTAssertEqual(Set(result.findings.map(\.ruleId)), [
            "SET-001", "SET-002", "SET-003", "SET-004", "SET-005", "SET-009", "SET-010", "SET-016", "SET-020", "SET-027",
            "PHASE-001", "PHASE-002", "PHASE-003", "PHASE-005", "DEP-001", "DEP-012",
        ], "GRAPH-007 of the inventory is not in the v0.3 catalog")
        XCTAssertEqual(result.findings("PHASE-001").count, 3)
        XCTAssertFalse(result.findings("PHASE-001").contains { $0.title.contains("Generate Constants") })
        for id in ["SET-007", "SET-011", "SET-014", "SET-029", "DEP-002"] { XCTAssertEqual(result.outcome(id)?.list, "passed", id) }
        for id in ["DEP-004", "DEP-008", "SET-023", "PHASE-007", "DEP-005", "DEP-006"] {
            XCTAssertEqual(result.outcome(id)?.list, "notApplicable", id)
        }
        XCTAssertEqual(result.suppressed.map(\.ruleId), ["SET-030"])
        XCTAssertEqual(result.findings.last?.ruleId, "SET-016", "+V and unmeasured: needs measurement, last")
        XCTAssertFalse(result.notes.contains { $0.contains("provenance") }, "real provenance answers every lookup")
        // Debug values written at project level shadow the overlay for the hook (§7.5); cli delivery is never shadowed
        // (SCHEMA-v0.6 Decision 2): the overlay lines stay and the planner delivers them through cli.
        let mode = try XCTUnwrap(result.finding("SET-001"))
        XCTAssertEqual(mode.fixKind, "overlay")
        XCTAssertEqual(mode.evidenceDetails.first?.provenance, "project settings (AcmeApp.xcodeproj)")
    }

    func testAcmeLegacyMatchesTheFixtureInventory() throws {
        let (_, result) = try RulesFixtures.real("AcmeLegacy/AcmeLegacy.xcodeproj")
        XCTAssertEqual(Set(result.findings.map(\.ruleId)), Set(["PHASE-001"]).union(xcode26Everywhere))
        XCTAssertEqual(result.findings("PHASE-001").map(\.signalKey), ["script-phase:B10000000000000000000504"],
                       "Version Bump's phase id in the pbxproj")
        // SET-005 reads the written YES (xcodebuild reports NO for the generated multi-target scheme).
        for id in ["SET-001", "SET-002", "SET-003", "SET-004", "SET-005"] { XCTAssertEqual(result.outcome(id)?.list, "passed", id) }
        XCTAssertEqual(result.outcome("SET-023")?.list, "notApplicable")
    }

    func testPodsLikeMatchesTheFixtureInventory() throws {
        let (_, result) = try RulesFixtures.real("PodsLike/PodsLike.xcodeproj")
        XCTAssertEqual(Set(result.findings.map(\.ruleId)),
                       Set(["DEP-005", "DEP-006", "PHASE-007", "SET-006", "SET-010"]).union(xcode26Everywhere))
        XCTAssertTrue(try XCTUnwrap(result.finding("SET-006")).evidence.contains {
            $0.contains("post_install sets EXCLUDED_ARCHS[sdk=iphonesimulator*] = arm64")
        }, "from Lane A's Podfile facts")
        XCTAssertTrue(try XCTUnwrap(result.finding("SET-010")).evidence.contains { $0.contains("post_install sets ENABLE_BITCODE = YES") })
        XCTAssertEqual(result.outcome("DEP-004")?.list, "passed", "3 ≤ 20 pods")
    }

    func testGeneratedProjectsMatchTheFixtureInventory() throws {
        let (xcodegen, xcodegenResult) = try RulesFixtures.real("GenXcodeGen/AcmeGen.xcodeproj")
        XCTAssertEqual(xcodegen.generator?.name, "xcodegen")
        XCTAssertEqual(Set(xcodegenResult.findings.map(\.ruleId)), xcode26Everywhere)
        let (tuist, tuistResult) = try RulesFixtures.real("GenTuist/AcmeTuist.xcodeproj")
        XCTAssertEqual(tuist.generator?.name, "tuist")
        XCTAssertEqual(Set(tuistResult.findings.map(\.ruleId)), Set(["DEP-007"]).union(xcode26Everywhere))
    }

    func testWorkspaceAndPrecedenceMatchTheFixtureInventory() throws {
        // AcmeWorkspace = AcmeApp plus a Podfile (CocoaPods → DEP-005, PHASE-007) and no workspace-level
        // Package.resolved (DEP-002: the workspace resolves from its own pins, which the fixture does not commit).
        let (_, workspace) = try RulesFixtures.real("AcmeWorkspace/Acme.xcworkspace")
        XCTAssertEqual(Set(workspace.findings.map(\.ruleId)), [
            "SET-001", "SET-002", "SET-003", "SET-004", "SET-005", "SET-009", "SET-010", "SET-016", "SET-020", "SET-027",
            "PHASE-001", "PHASE-002", "PHASE-003", "PHASE-005", "PHASE-007", "DEP-001", "DEP-002", "DEP-005", "DEP-012",
        ])
        let (_, precedence) = try RulesFixtures.real("Precedence/Precedence.xcodeproj")
        XCTAssertEqual(Set(precedence.findings.map(\.ruleId)), xcode26Everywhere, "a provenance fixture, no build-time smell")
    }

    // MARK: - Dedupe and conflicts (RULES.md §10)

    func testTwoRulesOnOneSignalKeyFoldIntoOneFinding() throws {
        func spec(_ id: String, _ category: RuleSpec.Category, _ kind: RuleSpec.ApplyKind) -> RuleSpec {
            RuleSpec(id: id, name: id.lowercased(), category: category, detection: .static, signal: "s", fix: "f",
                     applyKinds: [kind], verifyOnly: false, impactContext: "?", risk: "r", configurations: .both,
                     xcode: "all", evidenceTag: .secondary, sources: ["[OC] X"], conflicts: [],
                     signalKeyTemplate: "task:CompileAssetCatalog:<targets>", summary: "s", severity: .low)
        }
        let hit: @Sendable (RuleScan) -> Evaluation = { _ in
            .hits([RuleHit(title: "catalog", evidence: [.init(kind: "task", ref: "t")], targets: ["App"], apply: .recommend)])
        }
        let overlayHit: @Sendable (RuleScan) -> Evaluation = { _ in
            .hits([RuleHit(title: "catalog", evidence: [.init(kind: "task", ref: "t")], targets: ["App"], apply: .overlay)])
        }
        let catalog = [Rule(spec: spec("GRAPH-011", .graph, .recommend), evaluate: hit),
                       Rule(spec: spec("SET-012", .set, .overlay), evaluate: overlayHit),
                       Rule(spec: spec("DYN-001", .dyn, .recommend), evaluate: hit)]
        let result = RuleEngine.run(RuleContext(project: acme), catalog: catalog, rules: nil, categories: nil)
        XCTAssertEqual(result.findings.map(\.ruleId), ["SET-012"], "the non-rec fix kind wins")
        XCTAssertEqual(result.findings[0].seeAlso, ["GRAPH-011", "DYN-001"])
        XCTAssertEqual(result.suppressed.map(\.ruleId), ["GRAPH-011", "DYN-001"])
        XCTAssertEqual(result.suppressed[0].detail, "same signal as SET-012 (task:CompileAssetCatalog:App)")
        XCTAssertEqual(result.rulesEvaluated, 3)
        // Without a non-rec kind, category order decides: GRAPH before DYN.
        let passive = RuleEngine.run(RuleContext(project: acme), catalog: [catalog[2], catalog[0]], rules: nil, categories: nil)
        XCTAssertEqual(passive.findings.map(\.ruleId), ["GRAPH-011"])
    }

    func testXCRemoteCacheSuppressesSET015AndSET016ShowsTheConflict() throws {
        let wrapper = ["CC": "/repo/XCRemoteCache/xccc", "SWIFT_USE_INTEGRATED_DRIVER": "NO"]
        let model = RulesFixtures.acmeLegacy()
        let result = run(model, extra: ["Debug": ["AcmeLegacy": wrapper, "AcmeLegacyKit": wrapper],
                                        "Release": ["AcmeLegacy": wrapper, "AcmeLegacyKit": wrapper]])
        XCTAssertEqual(result.outcome("SET-015")?.list, "suppressed")
        XCTAssertTrue(result.outcome("SET-015")?.detail.contains("XCRemoteCache") ?? false)
        let cache = try XCTUnwrap(result.finding("SET-016"))
        XCTAssertEqual(cache.fixKind, "recommend", "never set YES while XCRemoteCache needs NO")
        XCTAssertTrue(cache.evidence.contains { $0.contains("compilation caching needs YES") }, "\(cache.evidence)")
        XCTAssertNotNil(result.finding("DEP-010"))
        // Without XCRemoteCache, explicit modules off blocks SET-016 (SET-013 reports it).
        let blocked = run(model, extra: ["Debug": ["AcmeLegacy": ["SWIFT_ENABLE_EXPLICIT_MODULES": "NO"]]])
        XCTAssertEqual(blocked.outcome("SET-016")?.list, "suppressed")
        XCTAssertTrue(blocked.outcome("SET-016")?.detail.contains("SET-013") ?? false)
        XCTAssertNotNil(blocked.finding("SET-013"))
    }

    // MARK: - Shadowing (DESIGN §7.5)

    func testTargetLevelValueShadowsTheOverlay() throws {
        var model = RulesFixtures.acmeLegacy()
        for index in model.projects[0].targets.indices {
            model.projects[0].targets[index].settings["Debug"] = ["DEBUG_INFORMATION_FORMAT": SettingValue(raw: "dwarf-with-dsym")]
        }
        let finding = try XCTUnwrap(run(model, rules: ["SET-004"]).finding("SET-004"))
        // Shadowing is hook-only (SCHEMA-v0.6 Decision 2): the -xcconfig wrapper still reaches the key, so the lines stay.
        XCTAssertEqual(finding.overlayLines, ["DEBUG_INFORMATION_FORMAT = dwarf // xcblame SET-004"], "cli is never shadowed")
        XCTAssertEqual(finding.fixKind, "overlay")
        let mechanism = try XCTUnwrap(finding.mechanism)
        XCTAssertTrue(mechanism.hasPrefix("shadowed by target settings (AcmeLegacy.xcodeproj)"), mechanism)
        let cli = try XCTUnwrap(mechanism.range(of: ": cli (")), recommend = try XCTUnwrap(mechanism.range(of: "or for Xcode builds recommend"))
        XCTAssertTrue(cli.lowerBound < recommend.lowerBound, "§7.5 order: cli, then recommend")
        XCTAssertFalse(mechanism.contains("--edit-project"), mechanism)
        XCTAssertEqual(finding.fixCommands, ["xcblame verify --rules SET-004 --kind clean --mechanism cli"])
        XCTAssertEqual(finding.evidenceDetails.first?.provenance, "target settings (AcmeLegacy.xcodeproj)")
        // CI plans the same wrapper delivery (no xcodebuild KEY=VALUE: -xcconfig beats it, probes Q1).
        let ci = try XCTUnwrap(run(model, isCI: true, rules: ["SET-004"]).finding("SET-004"))
        XCTAssertEqual(ci.fixKind, "overlay")
        XCTAssertEqual(ci.fixCommands, ["xcblame verify --rules SET-004 --kind clean --mechanism cli"])
    }

    func testPartialShadowingKeepsTheOverlayAndNamesTheShadowedTargets() throws {
        var model = RulesFixtures.acmeLegacy()
        model.projects[0].projectSettings["Debug"]?["DEBUG_INFORMATION_FORMAT"] = nil  // the app's value: platform default
        model.projects[0].targets[1].settings["Debug"] = ["DEBUG_INFORMATION_FORMAT": SettingValue(raw: "dwarf-with-dsym")]
        let finding = try XCTUnwrap(run(model, extra: ["Debug": ["AcmeLegacy": ["DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym"]]],
                                        rules: ["SET-004"]).finding("SET-004"))
        XCTAssertEqual(finding.overlayLines, ["DEBUG_INFORMATION_FORMAT = dwarf // xcblame SET-004"])
        XCTAssertEqual(finding.fixKind, "overlay")
        XCTAssertTrue(finding.mechanism?.contains("shadowed for AcmeLegacyKit by target settings") ?? false, finding.mechanism ?? "")
        XCTAssertEqual(finding.fixCommands, ["xcblame fix --rules SET-004 --apply"])
    }

    func testOracleProvenanceWinsOverTheWrittenFallback() throws {
        let settings = RulesFixtures.effective(acme)
        let context = RuleContext(project: acme, settings: settings,
                                  provenance: { _, _, _ in Provenance(level: .projectXCConfig, file: "/x/Config/Debug.xcconfig") },
                                  env: nil, xcode: "26.0.1")
        let result = RulesFixtures.run(context, rules: ["SET-001"])
        let finding = try XCTUnwrap(result.finding("SET-001"))
        XCTAssertEqual(finding.overlayLines, ["SWIFT_COMPILATION_MODE = singlefile // xcblame SET-001"],
                       "a project xcconfig value is overridden by the overlay appended to it")
        XCTAssertEqual(finding.evidenceDetails.first?.provenance, "project xcconfig (Debug.xcconfig)")
        XCTAssertTrue(result.notes.isEmpty, "no unknown-provenance note")
    }

    // MARK: - Confidence and bands (DESIGN §7.1)

    func testConfidenceTable() {
        XCTAssertEqual(Confidence.level(tag: .primary, measured: true, lowered: false), "high")
        XCTAssertEqual(Confidence.level(tag: .primary, measured: false, lowered: false), "medium")
        XCTAssertEqual(Confidence.level(tag: .secondary, measured: true, lowered: false), "medium")
        XCTAssertEqual(Confidence.level(tag: .mixed("P/S"), measured: true, lowered: false), "medium")
        XCTAssertEqual(Confidence.level(tag: .mixed("S/K"), measured: true, lowered: false), "low")
        XCTAssertEqual(Confidence.level(tag: .primary, measured: true, lowered: true), "medium")
        XCTAssertEqual(Confidence.level(tag: .secondary, measured: false, lowered: true), "low")
        XCTAssertEqual(Confidence.level(tag: .knowledge, measured: false, lowered: true), "low")
    }

    func testOfflineSourceLowersEveryFindingOneStep() {
        for result in [run(acme, offline: true), run(acme, source: .offlineResolver)] {
            XCTAssertFalse(result.findings.isEmpty)
            XCTAssertTrue(result.findings.allSatisfy { $0.confidence == "low" }, "\(result.findings.map(\.confidence))")
            XCTAssertTrue(result.notes.contains { $0.contains("offline resolver") })
        }
    }

    func testBandsFromSecondsAndShares() {
        XCTAssertEqual(Confidence.band(seconds: nil, share: nil), "?")
        XCTAssertEqual(Confidence.band(seconds: 0.4, share: nil), "XS")
        XCTAssertEqual(Confidence.band(seconds: 3, share: nil), "S")
        XCTAssertEqual(Confidence.band(seconds: 12, share: nil), "M")
        XCTAssertEqual(Confidence.band(seconds: 45, share: nil), "L")
        XCTAssertEqual(Confidence.band(seconds: nil, share: 0.05), "S")
        XCTAssertEqual(Confidence.band(seconds: 0.6, share: 0.4), "L", "the larger band wins")
        let spec = RuleCatalog.spec("SET-002")!
        XCTAssertEqual(Confidence.severity(spec, override: nil, band: "L"), .high)
        XCTAssertEqual(Confidence.severity(RuleCatalog.spec("SET-003")!, override: nil, band: "M"), .medium)
        XCTAssertEqual(Confidence.severity(RuleCatalog.spec("ENV-004")!, override: .high, band: "L"), .low, "[K] capped")
    }

    /// `analyze` context: measured costs set the band, seconds and basis; a [P] rule measured on the build is `high`.
    func testMeasuredCostsFromTheAnalyzedBuild() throws {
        let pipeline = try ReportPipeline.run(SyntheticModel.make())
        var analysis = pipeline.analysis
        var document = pipeline.document
        document.build.kind = "zero-change"
        analysis.span = 5
        analysis.topTasks = [
            TaskRow(id: 1, ruleName: "PhaseScriptExecution", kind: .script, phase: .other, targetId: 0, target: "Acme",
                    seconds: 3, startOffset: 0, title: "Run custom shell script 'Lint'"),
            TaskRow(id: 2, ruleName: "GenerateDSYMFile", kind: .other, phase: .other, targetId: 0, target: "Acme",
                    seconds: 12, startOffset: 3, title: "Generate Acme.app.dSYM"),
        ]
        let result = run(acme, analysis: analysis, document: document)
        let lint = try XCTUnwrap(result.findings("PHASE-001").first { $0.signalKey.hasSuffix("43") })
        XCTAssertEqual(lint.impactBand, "L", "3 s of a 5 s zero-change build")
        XCTAssertEqual(lint.impactSeconds, 3)
        XCTAssertEqual(lint.confidence, "high", "[P] and measured")
        XCTAssertEqual(lint.severity, "high")
        XCTAssertEqual(lint.impactBasis, "1 PhaseScriptExecution task(s) in this zero-change build")
        XCTAssertFalse(lint.evidence.contains { $0.hasPrefix("catalog context") }, "measured: no catalog context")
        let dsym = try XCTUnwrap(result.finding("SET-004"))
        XCTAssertEqual(dsym.impactBand, "M")
        XCTAssertEqual(dsym.confidence, "medium", "[S] with a measured cost")
        XCTAssertEqual(result.findings.first?.ruleId, "PHASE-001", "measured findings lead the plan")
    }

    /// `analyze` without a project: the dynamic parts still run (PHASE-001 scripts, DEP-012 package share).
    func testDynamicPartsRunWithoutAProject() throws {
        let pipeline = try ReportPipeline.run(SyntheticModel.make())
        var analysis = pipeline.analysis
        var document = pipeline.document
        document.build.kind = "incremental"
        analysis.topTasks = [TaskRow(id: 1, ruleName: "PhaseScriptExecution", kind: .script, phase: .other, targetId: nil,
                                     target: nil, seconds: 2, startOffset: 0, title: "Run custom shell script 'Lint'")]
        let context = RuleContext(project: nil, analysis: analysis, document: document, xcode: "26.0.1")
        let result = RulesFixtures.run(context)
        XCTAssertEqual(result.finding("PHASE-001")?.signalKey, "script-phase:Run custom shell script 'Lint'")
        XCTAssertEqual(result.outcome("SET-002")?.detail, "static rule: no project was read")
        XCTAssertEqual(result.rulesEvaluated, 49)
    }

    // MARK: - Generated projects, selection, gates, fail-on

    func testGeneratedProjectDowngradesProjectEditsAndPrintsTheSourceChange() throws {
        var xcodegen = RulesFixtures.genXcodeGen()
        xcodegen.packages = [.init(url: "https://github.com/apple/swift-argument-parser", path: nil, requirement: .branch("main"),
                                   consumers: ["AcmeGen"])]
        let pin = try XCTUnwrap(run(xcodegen, rules: ["DEP-001"]).finding("DEP-001"))
        XCTAssertEqual(pin.fixKind, "recommend")
        XCTAssertEqual(pin.mechanism, "recommend (generated by XcodeGen: change project.yml)")
        XCTAssertEqual(pin.fixCommands, [])
        XCTAssertTrue(pin.evidence.contains {
            $0 == "project.yml: packages: <name>: url: https://github.com/apple/swift-argument-parser, exactVersion: "
                + "<the version in Package.resolved> in project.yml"
        }, "\(pin.evidence)")
        let tuist = RulesFixtures.genTuist()
        let flags = try XCTUnwrap(run(tuist, extra: ["Release": ["AcmeTuist": ["OTHER_SWIFT_FLAGS": " -debug-time-function-bodies"]]],
                                      rules: ["SET-020"]).finding("SET-020"))
        XCTAssertEqual(flags.fixKind, "recommend")
        XCTAssertTrue(flags.evidence.contains { $0.contains("remove -debug-time-function-bodies from \"OTHER_SWIFT_FLAGS\"") })
        let cache = try XCTUnwrap(run(xcodegen, rules: ["SET-016"]).finding("SET-016"))
        XCTAssertEqual(cache.mechanism, "hook (XcodeGen: configFiles: {Debug: .xcblame/hook-Debug.xcconfig} in project.yml)")
        XCTAssertEqual(cache.overlayLines, ["COMPILATION_CACHE_ENABLE_CACHING = YES // xcblame SET-016"])
    }

    func testSelectionByIdAliasAndCategory() {
        let alias = run(acme, rules: ["phase-006", "NOPE-1"])
        XCTAssertEqual(alias.rulesEvaluated, 1)
        XCTAssertEqual(alias.findings.map(\.ruleId), ["PHASE-002"])
        XCTAssertEqual(alias.notes.first, "rules: unknown rule id NOPE-1 ignored (xcblame rules list shows the ids)")
        let settings = RulesFixtures.effective(acme)
        let env = RulesFixtures.run(RulesFixtures.context(acme, settings: settings, env: RulesFixtures.env()), categories: [.env])
        XCTAssertEqual(env.rulesEvaluated, 7)
    }

    func testXcodeRangeGates() {
        XCTAssertEqual(run(acme, xcode: "16.4", rules: ["SET-016"]).outcome("SET-016")?.detail,
                       "Xcode 26+ only (selected Xcode 16.4)")
        XCTAssertEqual(run(acme, xcode: nil, rules: ["SET-016"]).outcome("SET-016")?.detail,
                       "Xcode version unknown; rule needs Xcode 26+")
        XCTAssertEqual(run(acme, xcode: "13.4", rules: ["SET-027"]).outcome("SET-027")?.list, "notApplicable")
        XCTAssertEqual(run(acme, xcode: "13.4", rules: ["SET-010"]).outcome("SET-010")?.list, "finding", "notes never gate")
    }

    func testFailOnUsesFindingSeverities() {
        let result = run(acme)
        XCTAssertTrue(ReportDocument.failOnHit(result.findings, threshold: "medium"))
        XCTAssertFalse(ReportDocument.failOnHit(result.findings, threshold: "high"))
        let modern = run(acme, xcode: "27.0")
        XCTAssertTrue(ReportDocument.failOnHit(modern.findings, threshold: "high"), "SET-027 is high on Xcode 27")
        let doc = ReportDocument.makeDoctor(project: acme, settings: [:], result: modern, configurations: [], environment: nil,
                                            xcode: "27.0", generatedAt: Date(), durationSeconds: 1, offline: false, failOn: "high")
        XCTAssertEqual(doc.doctor?.failed, true)
    }
}
