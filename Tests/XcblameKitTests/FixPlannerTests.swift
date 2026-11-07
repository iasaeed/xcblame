import XCTest
@testable import XcblameKit

/// Scratch copies of the `fixtures/projects/AcmeFix*` projects and an offline doctor pass over them (shared by the
/// Fix*Tests files). Never runs xcodebuild.
enum FixFixture {
    static let projects = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/projects")

    /// A copy of `name` in a fresh temp folder (removed at teardown); returns the copy's folder.
    static func copy(_ name: String, test: XCTestCase) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-fix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: projects.appendingPathComponent(name), to: copy)
        return copy
    }

    static func container(_ folder: URL) -> URL {
        folder.appendingPathComponent(folder.lastPathComponent + ".xcodeproj")
    }

    /// The doctor document and rule context of an offline pass (`--rules` narrows the engine).
    static func doctor(_ folder: URL, rules: [String]? = nil, isCI: Bool = false)
        throws -> (model: ProjectModel, context: RuleContext, doctor: ReportDocument) {
        let model = try ProjectModel.load(container: container(folder), scheme: nil)
        let settings = SettingsOracle.effectiveAll(project: model, configurations: model.configurationNames, scheme: nil,
                                                   offline: true, cacheDir: nil)
        let context = RuleContext(project: model, settings: settings,
                                  provenance: RuleContext.oracleProvenance(model, settings: settings),
                                  env: nil, xcode: "26.0.1", isCI: isCI, offline: true)
        let result = RuleEngine.run(context, rules: rules)
        let doctor = ReportDocument.makeDoctor(project: model, settings: settings, result: result,
                                               configurations: model.configurationNames, environment: nil, xcode: "26.0.1",
                                               generatedAt: Date(timeIntervalSince1970: 1_700_000_000), durationSeconds: nil,
                                               offline: true, failOn: nil)
        return (model, context, doctor)
    }

    static func plan(_ folder: URL, rules: [String]? = nil, analysis: ReportDocument? = nil, analysisId: String? = nil,
                     planner: FixPlanner = FixPlanner(), isCI: Bool = false, xcblameDir: URL? = nil) throws -> FixPlanDocument {
        let pass = try doctor(folder, rules: rules, isCI: isCI)
        return try planner.plan(FixPlanRequest(doctor: pass.doctor, analysis: analysis, analysisId: analysisId,
                                               context: pass.context, rules: rules,
                                               xcblameDir: xcblameDir ?? folder.appendingPathComponent(".xcblame"),
                                               generatedAt: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    static func finding(_ id: String, fixKind: String?, overlay: [String] = [], targets: [String] = [],
                        configurations: [String] = [], commands: [String] = [], band: String? = "?") -> ReportDocument.Finding {
        ReportDocument.Finding(ruleId: id, title: id + " title", severity: "medium", impactBand: band, impactSeconds: nil,
                               impactBasis: nil, confidence: "medium", evidence: [], fixKind: fixKind, risk: nil,
                               mechanism: fixKind, signalKey: "k:\(id)", scopeTargets: targets,
                               scopeConfigurations: configurations, fixCommands: commands, overlayLines: overlay)
    }
}

/// `FixPlanner` over the AcmeFix fixtures (docs/SCHEMA-v0.6.md "Fix plan document").
final class FixPlannerTests: XCTestCase {
    func testWinPlansDSYMStepThroughTheHook() throws {
        let folder = try FixFixture.copy("AcmeFixWin", test: self)
        let plan = try FixFixture.plan(folder, rules: ["SET-004"])
        XCTAssertEqual(plan.schemaVersion, "xcblame.fixplan/1")
        XCTAssertEqual(plan.id.count, 8)
        XCTAssertEqual(plan.steps.map(\.ruleId), ["SET-004"])
        let step = try XCTUnwrap(plan.steps.first)
        XCTAssertEqual(step.order, 1)
        XCTAssertEqual(step.fixKind, .overlay)
        XCTAssertEqual(step.mechanism, .hook)
        XCTAssertEqual(step.verifyKind, "clean")
        XCTAssertFalse(step.verifyOnly)
        XCTAssertEqual(step.overlay, [.init(configuration: "Debug", key: "DEBUG_INFORMATION_FORMAT", value: "dwarf",
                                            line: "DEBUG_INFORMATION_FORMAT = dwarf // xcblame SET-004 (plan \(plan.id))")])
        XCTAssertEqual(step.shadowing, .none)
        XCTAssertEqual(step.scope.map(\.mechanism), [.hook, .cli], "rows for both mechanisms")
        let hook = try XCTUnwrap(step.scope.first)
        XCTAssertEqual(hook.target, "AcmeFixWin")
        XCTAssertEqual(hook.before, "dwarf-with-dsym")
        XCTAssertEqual(hook.after, "dwarf")
        XCTAssertTrue(hook.reached)
        XCTAssertEqual(hook.provenance, "projectXCConfig (Config/Debug.xcconfig)")
        XCTAssertNil(step.scope[1].after, "no -xcconfig oracle ran")
        XCTAssertTrue(step.scope[1].reached, "cli reaches by construction")
        XCTAssertEqual(step.commands, ["xcblame verify --rules SET-004 --kind clean --mechanism hook",
                                       "xcblame fix --rules SET-004 --apply"])
        XCTAssertEqual(plan.hook.map(\.status), ["notInstalled", "notInstalled"])
        XCTAssertEqual(plan.hook.map(\.baseXCConfig), ["Config/Debug.xcconfig", "Config/Release.xcconfig"])
        XCTAssertEqual(plan.commands, ["xcblame fix --install-hook",
                                       "xcblame verify --rules SET-004 --kind clean --mechanism hook",
                                       "xcblame fix --rules SET-004 --apply"])
        XCTAssertEqual(plan.guards.map(\.id), ["commitFirst", "hookInstalled", "cleanTree"])
        XCTAssertEqual(plan.guards.first { $0.id == "hookInstalled" }?.satisfied, false)
        XCTAssertEqual(plan.generatedFrom.settingsSource, "offline")
        XCTAssertEqual(plan.generatedFrom.doctorConfigurations, ["Debug", "Release"])
        XCTAssertNil(plan.generatedFrom.analysisId)
        XCTAssertTrue(plan.notes.contains { $0.hasPrefix("no analysis in history") })
    }

    func testPlanIdIsDeterministicAndHashesInputs() throws {
        let folder = try FixFixture.copy("AcmeFixWin", test: self)
        let first = try FixFixture.plan(folder, rules: ["SET-004"])
        let second = try FixFixture.plan(folder, rules: ["SET-004"])
        XCTAssertEqual(first.id, second.id)
        XCTAssertNotEqual(try FixFixture.plan(folder, rules: ["SET-004"], analysisId: "20261104-100000-clean").id, first.id)
        XCTAssertNotEqual(try FixFixture.plan(folder, rules: ["SET-004", "SET-016"]).id, first.id)
        XCTAssertEqual(FixPlanner.planId(source: nil, container: "/a.xcodeproj", steps: []),
                       FixPlanner.planId(source: nil, container: "/a.xcodeproj", steps: []))
    }

    func testNoopAndBreakerFixtures() throws {
        let noop = try FixFixture.plan(try FixFixture.copy("AcmeFixNoop", test: self), rules: ["SET-011"])
        let validate = try XCTUnwrap(noop.steps.first)
        XCTAssertEqual(validate.ruleId, "SET-011")
        XCTAssertEqual(validate.verifyKind, "zero-change")
        XCTAssertEqual(validate.overlay.map(\.line), ["VALIDATE_PRODUCT = NO // xcblame SET-011 (plan \(noop.id))"])
        XCTAssertEqual(validate.mechanism, .hook)

        let breaker = try FixFixture.plan(try FixFixture.copy("AcmeFixBreaker", test: self), rules: ["SET-030"])
        let sandbox = try XCTUnwrap(breaker.steps.first)
        XCTAssertEqual(sandbox.ruleId, "SET-030")
        XCTAssertEqual(sandbox.verifyKind, "incremental")
        XCTAssertEqual(sandbox.overlay.map(\.configuration), ["Debug", "Release"])
        XCTAssertEqual(Set(sandbox.overlay.map(\.key)), ["ENABLE_USER_SCRIPT_SANDBOXING"])
        XCTAssertEqual(sandbox.scope.filter { $0.mechanism == .hook }.map(\.configuration), ["Debug", "Release"])
        XCTAssertEqual(sandbox.scope.filter { $0.mechanism == .hook }.map(\.before), ["NO", "NO"])
    }

    func testVerifyOnlyStepGetsVerifyFirstGuard() throws {
        let plan = try FixFixture.plan(try FixFixture.copy("AcmeFixWin", test: self), rules: ["SET-016"])
        let step = try XCTUnwrap(plan.steps.first)
        XCTAssertTrue(step.verifyOnly)
        let verifyFirst = try XCTUnwrap(plan.guards.first { $0.id == "verifyFirst" })
        XCTAssertEqual(verifyFirst.ruleIds, ["SET-016"])
        XCTAssertEqual(verifyFirst.satisfied, false)
    }

    func testShadowedSettingPlansCLI() throws {
        // A target-level DEBUG_INFORMATION_FORMAT without $(inherited) shadows the base xcconfig (and the hook), not
        // the -xcconfig wrapper (probes Q1/Q3, SCHEMA-v0.6 Decision 2): the step keeps its lines and plans cli.
        let folder = try FixFixture.copy("AcmeFixWin", test: self)
        let pbxproj = FixFixture.container(folder).appendingPathComponent("project.pbxproj")
        var text = try String(contentsOf: pbxproj, encoding: .utf8)
        // The target's Debug XCBuildConfiguration (fixture ids are "AF01" + 20 hex digits).
        let target = "AF01" + String(format: "%020X", 0xA3) + " /* Debug */"
        let range = try XCTUnwrap(text.range(of: target + " = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n"))
        text.insert(contentsOf: "\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";\n", at: range.upperBound)
        try Data(text.utf8).write(to: pbxproj)
        let plan = try FixFixture.plan(folder, rules: ["SET-004"])
        let step = try XCTUnwrap(plan.steps.first)
        XCTAssertEqual(step.fixKind, .overlay)
        XCTAssertEqual(step.mechanism, .cli)
        XCTAssertEqual(step.shadowing, .full)
        XCTAssertEqual(step.overlay.map(\.key), ["DEBUG_INFORMATION_FORMAT"])
        XCTAssertEqual(step.commands, ["xcblame verify --rules SET-004 --kind clean --mechanism cli"])
        XCTAssertTrue(step.scope.filter { $0.mechanism == .cli }.allSatisfy(\.reached), "cli rows reach every target")
    }

    func testCIPlansCLIAndOracleConfirmsRows() throws {
        let folder = try FixFixture.copy("AcmeFixWin", test: self)
        let ci = try FixFixture.plan(folder, rules: ["SET-004"], isCI: true)
        XCTAssertEqual(ci.steps.first?.mechanism, .cli)
        XCTAssertEqual(ci.steps.first?.commands, ["xcblame verify --rules SET-004 --kind clean --mechanism cli"])

        let agree = FixPlanner(cliOracle: { configuration, lines in
            XCTAssertEqual(lines.count, 1)
            XCTAssertTrue(lines[0].hasPrefix("DEBUG_INFORMATION_FORMAT = dwarf // xcblame SET-004 (plan "))
            return EffectiveSettings(configuration: configuration, targets: ["AcmeFixWin": ["DEBUG_INFORMATION_FORMAT": "dwarf"]],
                                     source: .xcodebuild)
        })
        let confirmed = try XCTUnwrap(try FixFixture.plan(folder, rules: ["SET-004"], planner: agree).steps.first)
        let cli = try XCTUnwrap(confirmed.scope.first { $0.mechanism == .cli })
        XCTAssertEqual(cli.after, "dwarf")
        XCTAssertTrue(cli.reached)
        XCTAssertTrue(FixApply.sameScope(confirmed), "hook and cli rows agree")

        let disagree = FixPlanner(cliOracle: { configuration, _ in
            EffectiveSettings(configuration: configuration,
                              targets: ["AcmeFixWin": ["DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym"]], source: .xcodebuild)
        })
        let mismatch = try XCTUnwrap(try FixFixture.plan(folder, rules: ["SET-004"], planner: disagree).steps.first)
        let row = try XCTUnwrap(mismatch.scope.first { $0.mechanism == .cli })
        XCTAssertFalse(row.reached)
        XCTAssertTrue(row.note?.contains("oracle check shows dwarf-with-dsym") == true, row.note ?? "")
    }

    func testSyntheticFindingsListKeysDefaultsOrderAndMeasuredBands() throws {
        let folder = try FixFixture.copy("AcmeFixWin", test: self)
        let pass = try FixFixture.doctor(folder, rules: ["SET-004"])
        var doctor = pass.doctor
        doctor.findings = [
            FixFixture.finding("SET-004", fixKind: "overlay", overlay: ["DEBUG_INFORMATION_FORMAT = dwarf // xcblame SET-004"],
                               targets: ["AcmeFixWin"], configurations: ["Debug"]),
            FixFixture.finding("PHASE-002", fixKind: "project", commands: ["xcblame fix --rules PHASE-002 --edit-project"]),
            FixFixture.finding("SET-019", fixKind: "overlay", overlay: ["OTHER_SWIFT_FLAGS = -Xfrontend -foo // xcblame SET-019"],
                               targets: ["AcmeFixWin"], configurations: ["Debug"]),
            FixFixture.finding("ENV-002", fixKind: "defaults", commands: ["xcblame fix --rules ENV-002 --apply-defaults"]),
            FixFixture.finding("ENV-001", fixKind: "defaults", commands: ["xcblame fix --rules ENV-001 --apply-defaults"]),
            FixFixture.finding("DYN-001", fixKind: "measure"),
        ]
        var analysis = doctor
        analysis.findings = [FixFixture.finding("SET-004", fixKind: "overlay", band: "S")]
        analysis.findings[0].impactSeconds = 2.5
        let plan = try FixPlanner().plan(FixPlanRequest(doctor: doctor, analysis: analysis, analysisId: "20261104-100000-clean",
                                                        context: pass.context, rules: nil,
                                                        xcblameDir: folder.appendingPathComponent(".xcblame"),
                                                        generatedAt: Date()))
        XCTAssertEqual(plan.steps.map(\.ruleId), ["PHASE-002", "SET-004", "SET-019", "ENV-002", "ENV-001"],
                       "prerequisite first, measure-only dropped")
        XCTAssertEqual(plan.steps.map(\.order), [1, 2, 3, 4, 5])
        XCTAssertEqual(plan.steps[1].impactBand, "S", "measured band from the analysis")
        XCTAssertEqual(plan.steps[1].impactSeconds, 2.5)
        XCTAssertEqual(plan.steps[0].mechanism, .recommend)
        XCTAssertEqual(plan.steps[2].overlay.first?.value, "$(inherited) -Xfrontend -foo", "list keys start with $(inherited)")
        XCTAssertEqual(plan.steps[3].mechanism, .defaults)
        XCTAssertEqual(plan.steps[3].defaults, [.init(key: "IDEBuildOperationMaxNumberOfConcurrentCompileTasks", value: nil,
                                                      type: nil)])
        XCTAssertEqual(plan.steps[4].mechanism, .recommend, "ENV-001 is display-only")
        XCTAssertTrue(plan.steps[4].defaults.isEmpty)
        let prerequisite = try XCTUnwrap(plan.guards.first { $0.id == "prerequisite" })
        XCTAssertEqual(prerequisite.ruleIds, ["PHASE-002", "SET-004"])
        XCTAssertEqual(plan.generatedFrom.analysisId, "20261104-100000-clean")
        XCTAssertTrue(plan.commands.contains("xcblame fix --apply-defaults"))
        XCTAssertTrue(plan.notes.contains { $0.contains("only need measuring (DYN-001)") })
    }

    func testVerifyStatesCarryOverFromStoredPlansAndHistory() throws {
        let folder = try FixFixture.copy("AcmeFixWin", test: self)
        let dir = folder.appendingPathComponent(".xcblame")
        var stored = try FixFixture.plan(folder, rules: ["SET-004"])
        // What verify records: the verdict with its basis (fix round 1, review gap 2).
        let digest = VerifyBasis.projectDigest(container: stored.project.container, xcblameDir: dir)
        stored.steps[0].verify = .init(status: .kept, mechanism: .hook, kind: "clean", verifyId: "v1", deltaSeconds: -2,
                                       basis: VerifyBasis.value(step: stored.steps[0], container: stored.project.container,
                                                                projectDigest: digest))
        stored.steps[0].state = .applied
        stored.events = [.init(at: Date(), action: "apply", ruleIds: ["SET-004"], files: [], defaultsKeys: [])]
        try FixPlanStore.save(stored, xcblameDir: dir)
        let again = try FixFixture.plan(folder, rules: ["SET-004"])
        XCTAssertEqual(again.steps[0].verify.status, .kept)
        XCTAssertEqual(again.steps[0].state, .applied)
        XCTAssertEqual(again.events.count, 1)
        XCTAssertFalse(again.commands.contains { $0.hasPrefix("xcblame verify --rules SET-004") }, "kept: no verify command")

        // Another plan id (all rules) with the identical SET-004 step reuses its verdict, not its state.
        let wider = try FixFixture.plan(folder, rules: ["SET-004", "SET-016"])
        XCTAssertNotEqual(wider.id, stored.id)
        XCTAssertEqual(wider.steps.first { $0.ruleId == "SET-004" }?.verify.status, .kept)
        XCTAssertEqual(wider.steps.first { $0.ruleId == "SET-004" }?.state, .planned)
        XCTAssertEqual(wider.steps.first { $0.ruleId == "SET-016" }?.verify.status, .unverified)

        // A history verify entry of this plan (lane B's format) fills an unverified step.
        try FileManager.default.removeItem(at: FixPlanStore.url(id: stored.id, xcblameDir: dir))
        var entry = V06Samples.verify
        entry.planId = wider.id
        entry.results[0].ruleIds = ["SET-016"]
        entry.results[0].verdict = .init(status: .reverted, reason: .withinNoise, tie: false)
        entry.results[0].basis = VerifyBasis.combined(ruleIds: ["SET-016"], plan: wider, projectDigest: digest)
        let history = dir.appendingPathComponent("history/verify")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        let json = history.appendingPathComponent("\(entry.id).json")
        try JSONReporter.render(entry).write(to: json)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = [json.path]
        try gzip.run()
        gzip.waitUntilExit()
        let fromHistory = try FixFixture.plan(folder, rules: ["SET-004", "SET-016"])
        let set016 = try XCTUnwrap(fromHistory.steps.first { $0.ruleId == "SET-016" })
        XCTAssertEqual(set016.verify.status, .reverted)
        XCTAssertEqual(set016.verify.reason, .withinNoise)
        XCTAssertEqual(set016.verify.verifyId, entry.id)
    }

    /// Review gap 2: a verdict measured against other project files (an xcconfig edited after verify), or one without
    /// a basis, is not reused: the step is unverified again with "project changed since verify".
    func testVerdictsOfAChangedProjectAreNotReused() throws {
        let folder = try FixFixture.copy("AcmeFixWin", test: self)
        let dir = folder.appendingPathComponent(".xcblame")
        var stored = try FixFixture.plan(folder, rules: ["SET-004"])
        let digest = VerifyBasis.projectDigest(container: stored.project.container, xcblameDir: dir)
        stored.steps[0].verify = .init(status: .kept, mechanism: .hook, kind: "clean", verifyId: "v1",
                                       basis: VerifyBasis.value(step: stored.steps[0], container: stored.project.container,
                                                                projectDigest: digest))
        try FixPlanStore.save(stored, xcblameDir: dir)
        // The hook lines and the overlay do not count as a change.
        let model = try ProjectModel.load(container: FixFixture.container(folder), scheme: nil)
        _ = HookInstaller.install(project: model, configurations: ["Debug"], xcblameDir: dir, isDirty: { _ in false },
                                  verify: { _, _, _, _ in nil })
        XCTAssertEqual(try FixFixture.plan(folder, rules: ["SET-004"]).steps[0].verify.status, .kept)

        let shared = folder.appendingPathComponent("Config/Shared.xcconfig")
        try (try Data(contentsOf: shared) + Data("SWIFT_VERSION = 6.0\n".utf8)).write(to: shared)
        let changed = try FixFixture.plan(folder, rules: ["SET-004"])
        XCTAssertEqual(changed.steps[0].verify.status, .unverified)
        XCTAssertTrue(changed.notes.contains { $0.hasPrefix("SET-004: project changed since verify (v1)") }, "\(changed.notes)")
        XCTAssertTrue(changed.commands.contains { $0.hasPrefix("xcblame verify --rules SET-004") })

        // An older plan's verdict (no basis) is never reused either.
        stored.steps[0].verify.basis = nil
        try FixPlanStore.save(stored, xcblameDir: dir)
        XCTAssertEqual(try FixFixture.plan(folder, rules: ["SET-004"]).steps[0].verify.status, .unverified)
    }

    /// Review D: an incremental step's verify command names a file to touch (the largest Swift file of its target).
    func testIncrementalVerifyCommandSuggestsATouchFile() throws {
        let folder = try FixFixture.copy("AcmeFixWin", test: self)
        let model = try ProjectModel.load(container: FixFixture.container(folder), scheme: nil)
        let big = folder.appendingPathComponent("AcmeFixWin/Big.swift")
        try Data(String(repeating: "let x = 1\n", count: 10_000).utf8).write(to: big)  // larger than every Synthetic*.swift
        let touch = try XCTUnwrap(FixPlanner.touchSuggestion(model, targets: ["AcmeFixWin"]))
        XCTAssertTrue(touch.hasSuffix("AcmeFixWin/Big.swift"), touch)
        XCTAssertEqual(FixPlanner.shellWord("a b.swift"), "'a b.swift'")
        XCTAssertEqual(FixPlanner.shellWord("Sources/A.swift"), "Sources/A.swift")
    }

    func testHookStatesForSharedGeneratedAndMissingBaseXCConfigs() throws {
        let shared = try ProjectModel.load(container: FixFixture.projects.appendingPathComponent(
            "Precedence/Precedence.xcodeproj"), scheme: nil)
        let states = HookInstaller.states(project: shared, configurations: ["Debug"], xcblameDir: URL(fileURLWithPath: "/x"))
        XCTAssertEqual(states.first?.status, "unavailable")
        XCTAssertTrue(states.first?.reason?.contains("one #include? cannot name each configuration") == true)

        var generated = try ProjectModel.load(container: FixFixture.container(FixFixture.projects.appendingPathComponent("AcmeFixWin")),
                                              scheme: nil)
        generated.generator = .xcodegen(spec: URL(fileURLWithPath: "/x/project.yml"))
        XCTAssertEqual(HookInstaller.states(project: generated, configurations: ["Debug"], xcblameDir: URL(fileURLWithPath: "/x"))
            .first?.status, "generated")

        var bare = generated
        bare.generator = nil
        bare.projects[0].projectXCConfig = [:]
        let none = try XCTUnwrap(HookInstaller.states(project: bare, configurations: ["Debug"],
                                                      xcblameDir: URL(fileURLWithPath: "/x")).first)
        XCTAssertEqual(none.status, "unavailable")
        XCTAssertTrue(none.reason?.contains("no project-level base xcconfig") == true, none.reason ?? "")
        XCTAssertTrue(none.reason?.contains("0.7") == true)
    }

    func testMatchesAndExpected() {
        XCTAssertTrue(FixPlanner.matches(effective: "dwarf", written: "dwarf"))
        XCTAssertFalse(FixPlanner.matches(effective: "dwarf-with-dsym", written: "dwarf"))
        XCTAssertTrue(FixPlanner.matches(effective: " -DA -Xfrontend -foo", written: "$(inherited) -Xfrontend -foo"))
        XCTAssertFalse(FixPlanner.matches(effective: "-DA", written: "$(inherited) -Xfrontend -foo"))
        XCTAssertEqual(FixPlanner.expected("$(inherited) -foo", before: "-DA"), "-DA -foo")
        XCTAssertNil(FixPlanner.expected("$(inherited) -foo", before: nil))
        XCTAssertEqual(FixPlanner.verifyKind(["xcblame verify --rules SET-011 --kind zero-change --mechanism hook"]), "zero-change")
        XCTAssertEqual(FixPlanner.verifyKind([]), "clean")
    }

    /// The analyze/doctor fix-plan steps carry the newest stored verify state of their rule (`verifyStatus`).
    func testStoredVerifyStatesMarkTheReportPlanSteps() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-verify-labels-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try FixPlanStore.save(V06Samples.plan, xcblameDir: dir)
        let labels = FixPlanner.verifyLabels(xcblameDir: dir)
        XCTAssertEqual(labels, ["SET-004": "kept"], "unverified steps (ENV-002) carry no label")
        var doc = HTMLSample.doctor(hostileStrings: false)
        doc.fixPlan = [
            .init(order: 1, ruleId: "SET-004", command: "xcblame verify --rules SET-004 --kind clean --mechanism hook",
                  note: nil, kind: "verify"),
            .init(order: 2, ruleId: "SET-004", command: "Build Settings › Debug Information Format", note: nil, kind: "manual"),
            .init(order: 3, ruleId: "SET-001", command: "xcblame verify --rules SET-001 --mechanism cli", note: nil, kind: "verify"),
        ]
        doc.markVerified(labels)
        XCTAssertEqual(doc.fixPlan.map(\.verifyStatus), ["kept", nil, nil])
    }
}
