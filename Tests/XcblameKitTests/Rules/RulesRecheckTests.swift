import XCTest
@testable import XcblameKit

/// Code review v0.3 majors 1-3 and the shadowing / provenance minors: verify before an edit, CocoaPods xcconfigs,
/// xcconfig-held flags, SDK-conditional shadowing, per-platform evaluation.
final class RulesRecheckTests: XCTestCase {
    /// AcmeApp with `extra` added to one target's written settings.
    private func acme(target: String, configuration: String, _ extra: [String: SettingValue]) -> ProjectModel {
        var model = RulesFixtures.acmeApp()
        let index = model.projects[0].targets.firstIndex { $0.name == target }!
        model.projects[0].targets[index].settings[configuration, default: [:]].merge(extra) { $1 }
        return model
    }

    private func context(_ model: ProjectModel,
                         provenance: @escaping @Sendable (String, String, String) -> Provenance = { _, _, _ in
                             Provenance(level: .unknown)
                         }) -> RuleContext {
        RuleContext(project: model, settings: RulesFixtures.effective(model), provenance: provenance, xcode: "26.0.1")
    }

    // MARK: E. +V rules go through verify, shadowed or not

    func testShadowedVerifyOnlyRuleIsVerifiedBeforeAnyProjectEdit() throws {
        let model = acme(target: "AcmeKit", configuration: "Debug", ["COPY_PHASE_STRIP": SettingValue(raw: "YES")])
        let finding = try XCTUnwrap(RulesFixtures.run(context(model), rules: ["SET-029"]).finding("SET-029"))
        XCTAssertEqual(finding.scopeTargets, ["AcmeKit"])
        XCTAssertTrue(finding.mechanism?.hasPrefix("shadowed by target settings") == true, finding.mechanism ?? "")
        XCTAssertEqual(finding.fixCommands, ["xcblame verify --rules SET-029 --kind incremental --mechanism cli"])
        // A rule without +V is delivered the same way: through cli, never a project edit (SCHEMA-v0.6 Decision 2).
        let plain = acme(target: "AcmeKit", configuration: "Debug", ["SWIFT_OPTIMIZATION_LEVEL": SettingValue(raw: "-O")])
        let set002 = try XCTUnwrap(RulesFixtures.run(context(plain), rules: ["SET-002"]).finding("SET-002"))
        XCTAssertEqual(set002.fixCommands.count, 1, "\(set002.fixCommands)")
        XCTAssertTrue(set002.fixCommands[0].hasPrefix("xcblame verify --rules SET-002 ") && set002.fixCommands[0].hasSuffix("--mechanism cli"))
    }

    // MARK: F. CocoaPods-generated xcconfigs

    func testPodsXCConfigShadowRecommendsAPostInstallSnippet() throws {
        let pods = "Pods/Target Support Files/Pods-Acme/Pods-Acme.debug.xcconfig"
        let finding = try XCTUnwrap(RulesFixtures.run(context(RulesFixtures.acmeApp()) { _, key, _ in
            key == "DEBUG_INFORMATION_FORMAT"
                ? Provenance(level: .targetXCConfig, file: pods, rawValue: "dwarf-with-dsym") : Provenance(level: .unknown)
        }, rules: ["SET-004"]).finding("SET-004"))
        XCTAssertEqual(finding.fixKind, "overlay", "cli still reaches it; Xcode builds get the post_install snippet")
        XCTAssertFalse(finding.fixCommands.contains { $0.contains("--edit-project") }, "\(finding.fixCommands)")
        XCTAssertTrue(finding.mechanism?.contains("CocoaPods-generated xcconfig") == true, finding.mechanism ?? "")
        XCTAssertTrue(finding.evidence.contains { $0.contains("post_install") && $0.contains("xc.attributes['DEBUG_INFORMATION_FORMAT'] = 'dwarf'") },
                      "\(finding.evidence)")
        XCTAssertTrue(FindingBuilder.isPodsXCConfig("Config/Pods-App.release.xcconfig"))
        XCTAssertFalse(FindingBuilder.isPodsXCConfig("Config/App.xcconfig"))
    }

    // MARK: Minor 9. A flag in an xcconfig points at that file

    func testFlagRemovalPointsAtTheXCConfigThatHoldsIt() throws {
        let inFile = try XCTUnwrap(RulesFixtures.run(context(RulesFixtures.acmeApp()) { _, key, _ in
            key == "OTHER_SWIFT_FLAGS"
                ? Provenance(level: .projectXCConfig, file: "Config/Release.xcconfig", rawValue: "-debug-time-function-bodies")
                : Provenance(level: .unknown)
        }, rules: ["SET-020"]).finding("SET-020"))
        XCTAssertEqual(inFile.fixKind, "recommend")
        XCTAssertEqual(inFile.mechanism, "recommend (edit Config/Release.xcconfig)")
        XCTAssertTrue(inFile.evidence.contains("Config/Release.xcconfig: remove -debug-time-function-bodies from OTHER_SWIFT_FLAGS"),
                      "\(inFile.evidence)")
        XCTAssertEqual(inFile.fixCommands, [])
        // Written in the pbxproj (the fixture's project settings): --edit-project.
        let inProject = try XCTUnwrap(RulesFixtures.run(context(RulesFixtures.acmeApp()), rules: ["SET-020"]).finding("SET-020"))
        XCTAssertEqual(inProject.fixKind, "project")
        XCTAssertEqual(inProject.fixCommands, ["xcblame fix --rules SET-020 --edit-project"])
    }

    // MARK: Minor 10. SDK-conditional shadowing

    func testSimulatorConditionalTargetValueShadowsTheOverlay() {
        let model = acme(target: "Acme", configuration: "Debug", [
            "SDKROOT": SettingValue(raw: "iphoneos"),
            "EAGER_LINKING": SettingValue(raw: nil, conditions: ["sdk=iphonesimulator*": "NO"]),
        ])
        let shadow = SettingsOracle.isShadowed(project: model, target: "Acme", key: "EAGER_LINKING",
                                               configuration: "Debug", byLevelAbove: .projectXCConfig)
        XCTAssertEqual(shadow?.level, .targetSettings)
        XCTAssertEqual(shadow?.rawValue, "NO")
        // A watchOS-only condition cannot apply to an iOS target.
        let other = acme(target: "Acme", configuration: "Debug", [
            "SDKROOT": SettingValue(raw: "iphoneos"),
            "EAGER_LINKING": SettingValue(raw: nil, conditions: ["sdk=watchos*": "NO"]),
        ])
        XCTAssertNil(SettingsOracle.isShadowed(project: other, target: "Acme", key: "EAGER_LINKING",
                                               configuration: "Debug", byLevelAbove: .projectXCConfig))
    }

    // MARK: G. Per-platform destinations

    func testPlatformGroupsAndDestinations() {
        XCTAssertEqual(XcodebuildSettings.destination(sdk: "iphoneos"), "generic/platform=iOS")
        XCTAssertEqual(XcodebuildSettings.destination(sdk: "macosx"), "generic/platform=macOS")
        XCTAssertEqual(XcodebuildSettings.destination(sdk: "xros"), "generic/platform=visionOS")
        XCTAssertNil(XcodebuildSettings.destination(sdk: nil))
        var model = RulesFixtures.acmeApp()
        model.projects[0].projectSettings["Debug"]?["SDKROOT"] = SettingValue(raw: "iphoneos")
        let index = model.projects[0].targets.firstIndex { $0.name == "AcmeCore" }!
        model.projects[0].targets[index].settings["Debug", default: [:]]["SDKROOT"] = SettingValue(raw: "macosx")
        let groups = XcodebuildSettings.platformGroups(model)
        XCTAssertEqual(groups.map(\.destination), ["generic/platform=iOS", "generic/platform=macOS"])
        XCTAssertEqual(groups[1].targets.map(\.target.name), ["AcmeCore"])
    }

    /// AcmeLegacyKit (an iOS framework the generated scheme used to evaluate as Mac Catalyst) with
    /// `SWIFT_OPTIMIZATION_LEVEL[sdk=iphoneos*] = -O` in Debug: the oracle reports `-O` and SET-002 fires.
    func testIOSDependencyTargetIsEvaluatedForIOS() throws {
        guard SettingsFixtures.xcodebuildAvailable() else { throw XCTSkip("xcodebuild not available") }
        let root = SettingsFixtures.scratch("recheck-legacy", self).appendingPathComponent("AcmeLegacy")
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: RulesFixtures.root.appendingPathComponent("AcmeLegacy"), to: root)
        let pbxproj = root.appendingPathComponent("AcmeLegacy.xcodeproj/project.pbxproj")
        var text = try String(contentsOf: pbxproj, encoding: .utf8)
        let anchor = "\t\tB10000000000000000000707 /* Debug */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n"
        XCTAssertTrue(text.contains(anchor))
        text = text.replacingOccurrences(of: anchor, with: anchor + "\t\t\t\t\"SWIFT_OPTIMIZATION_LEVEL[sdk=iphoneos*]\" = \"-O\";\n")
        try text.write(to: pbxproj, atomically: true, encoding: .utf8)
        let model = try ProjectModel.load(container: root.appendingPathComponent("AcmeLegacy.xcodeproj"), scheme: nil)
        let settings = SettingsOracle.effectiveAll(project: model, configurations: ["Debug"], scheme: nil, offline: false,
                                                   cacheDir: SettingsFixtures.scratch("recheck-legacy-state", self),
                                                   cacheHome: SettingsFixtures.scratch("recheck-legacy-home", self))
        let debug = try XCTUnwrap(settings["Debug"])
        XCTAssertEqual(debug.source, .xcodebuild, "\(debug.notes)")
        XCTAssertEqual(debug.targets["AcmeLegacyKit"]?["SDK_NAME"]?.hasPrefix("iphoneos"), true)
        XCTAssertEqual(debug.targets["AcmeLegacyKit"]?["SWIFT_OPTIMIZATION_LEVEL"], "-O")
        let context = RuleContext(project: model, settings: settings,
                                  provenance: RuleContext.oracleProvenance(model, settings: settings), xcode: "26.0.1")
        let finding = try XCTUnwrap(RulesFixtures.run(context, rules: ["SET-002"]).finding("SET-002"))
        XCTAssertEqual(finding.scopeTargets, ["AcmeLegacyKit"])
    }
}

/// Code review v0.3 minors 7, 8, 14: PHASE-002's guard, measurements from every task, (project, target) keys.
final class RulesMinorsTests: XCTestCase {
    func testConfigurationBuildDirIsNoGuard() {
        let guardPattern = PHASEChecks.guardPattern
        XCTAssertFalse(RuleScan.matches("sentry-cli debug-files upload \"$CONFIGURATION_BUILD_DIR\"", guardPattern))
        XCTAssertFalse(RuleScan.matches("cp x \"${CONFIGURATION_TEMP_DIR}/y\"", guardPattern))
        XCTAssertTrue(RuleScan.matches("if [ \"${CONFIGURATION}\" = \"Release\" ]; then upload; fi", guardPattern))
        XCTAssertTrue(RuleScan.matches("[ \"$CONFIGURATION\" == \"Release\" ] || exit 0", guardPattern))
        XCTAssertTrue(RuleScan.matches("case \"$PLATFORM_NAME\" in iphoneos) upload ;; esac", guardPattern))
        var model = RulesFixtures.acmeLegacy()
        model.projects[0].targets[0].phases = [RulesFixtures.script("AB0000000000000000000043", "Upload",
                                                                    "sentry-cli debug-files upload \"$CONFIGURATION_BUILD_DIR\"\n")]
        XCTAssertNotNil(RulesFixtures.run(RulesFixtures.context(model), rules: ["PHASE-002"]).finding("PHASE-002"))
    }

    /// Two phases both titled "Run Script" are told apart by `Script-<id>.sh`; Swift compiles carry their arch only
    /// in the command line.
    func testMeasurementsReadEveryTaskByCommandLine() throws {
        let pipeline = try ReportPipeline.run(SyntheticModel.make())
        var document = pipeline.document
        document.build.kind = "zero-change"
        var analysis = pipeline.analysis
        analysis.span = 10
        analysis.topTasks = []
        func task(_ id: Int, _ rule: String, _ kind: TaskKind, _ title: String, _ command: String, _ seconds: Double)
            -> RuleContext.MeasuredTask {
            var task = TestModels.task(id, rule, kind: kind, start: 0, end: seconds)
            task.title = title
            task.commandDetails = command
            return RuleContext.MeasuredTask(task: task, seconds: seconds)
        }
        let tasks = [
            task(1, "PhaseScriptExecution", .script, "Run custom shell script 'Run Script'",
                 "PhaseScriptExecution Run\\ Script /dd/Script-AC0000000000000000000043.sh", 3),
            task(2, "PhaseScriptExecution", .script, "Run custom shell script 'Run Script'",
                 "PhaseScriptExecution Run\\ Script /dd/Script-FFFFFFFFFFFFFFFFFFFFFFFF.sh", 4),
            task(3, "SwiftCompile", .swiftCompile, "Compiling Models.swift", "SwiftCompile normal arm64 /src/Models.swift", 5),
            task(4, "SwiftCompile", .swiftCompile, "Compiling Models.swift", "SwiftCompile normal x86_64 /src/Models.swift", 2),
        ]
        let context = RuleContext(project: RulesFixtures.acmeApp(), settings: RulesFixtures.effective(RulesFixtures.acmeApp()),
                                  analysis: analysis, document: document, xcode: "26.0.1", tasks: tasks)
        let result = RulesFixtures.run(context, rules: ["PHASE-001", "SET-005"])
        let lint = try XCTUnwrap(result.findings("PHASE-001").first { $0.signalKey.hasSuffix("43") })
        XCTAssertEqual(lint.impactSeconds, 3, "only the Lint phase's own task")
        XCTAssertEqual(result.finding("SET-005")?.impactSeconds, 2, "the x86_64 compile, from its command line")
    }

    func testTargetsSharingANameAreKeyedPerProject() throws {
        func project(_ name: String, sdk: String) -> ProjectModel.Project {
            ProjectModel.Project(path: URL(fileURLWithPath: "/w/\(name).xcodeproj"), name: name, objectVersion: 77,
                                 configurations: ["Debug"],
                                 projectSettings: ["Debug": ["SDKROOT": SettingValue(raw: sdk)]],
                                 targets: [ProjectModel.Target(id: "\(name)00000000000000000000", name: "App",
                                                               productType: "com.apple.product-type.application")])
        }
        let model = ProjectModel(root: URL(fileURLWithPath: "/w"), container: .xcworkspace(URL(fileURLWithPath: "/w/W.xcworkspace")),
                                 format: .pbxproj(objectVersion: 77), projects: [project("One", sdk: "iphoneos"),
                                                                                  project("Two", sdk: "macosx")])
        XCTAssertEqual(model.allTargets.map(\.name), ["One/App", "Two/App"])
        XCTAssertEqual(SettingsOracle.provenance(project: model, target: "Two/App", key: "SDKROOT", configuration: "Debug").rawValue,
                       "macosx")
        let json = """
            [{"target":"App","action":"build","buildSettings":{"PROJECT_NAME":"One","SDKROOT":"iphoneos"}},
             {"target":"App","action":"build","buildSettings":{"PROJECT_NAME":"Two","SDKROOT":"macosx"}},
             {"target":"Solo","action":"build","buildSettings":{"PROJECT_NAME":"Two"}}]
            """
        let parsed = try XCTUnwrap(XcodebuildSettings.parse(Data(json.utf8)))
        XCTAssertEqual(Set(parsed.keys), ["One/App", "Two/App", "Solo"])
        XCTAssertEqual(parsed["Two/App"]?["SDKROOT"], "macosx")
        XCTAssertEqual(OfflineResolver.resolve(project: model, configuration: "Debug").targets["Two/App"]?["SDKROOT"], "macosx")
    }
}

/// Catalog gaps from the review: SET-011, DEP-004, ENV-008 (static parts).
final class RulesCatalogGapTests: XCTestCase {
    func testSET011ValidateProductInDebug() throws {
        var model = RulesFixtures.acmeApp()
        model.projects[0].projectSettings["Debug"]?["VALIDATE_PRODUCT"] = SettingValue(raw: "YES")
        let finding = try XCTUnwrap(RulesFixtures.run(RulesFixtures.context(model), rules: ["SET-011"]).finding("SET-011"))
        XCTAssertEqual(finding.scopeTargets, ["Acme"], "application targets")
        XCTAssertEqual(finding.confidence, "low", "[S/K]")
        // Written in the project settings, so the hook is shadowed: verify and deliver through the command line.
        XCTAssertEqual(finding.fixCommands, ["xcblame verify --rules SET-011 --kind zero-change --mechanism cli"])
        XCTAssertEqual(RulesFixtures.run(RulesFixtures.context(RulesFixtures.acmeApp()), rules: ["SET-011"])
            .outcome("SET-011")?.detail, "Debug: unset (platform default NO)")
    }

    func testDEP004PodCount() throws {
        var model = RulesFixtures.podsLike()
        XCTAssertEqual(RulesFixtures.run(RulesFixtures.context(model), rules: ["DEP-004"]).outcome("DEP-004")?.detail,
                       "3 pods (≤ 20)")
        if case let .cocoapods(podfile, lockfile, _) = model.dependencyManagers.first(where: {
            if case .cocoapods = $0 { return true } else { return false }
        })! {
            model.dependencyManagers = [.cocoapods(podfile: podfile, lockfile: lockfile, podCount: 34)]
        }
        let finding = try XCTUnwrap(RulesFixtures.run(RulesFixtures.context(model), rules: ["DEP-004"]).finding("DEP-004"))
        XCTAssertTrue(finding.title.hasPrefix("34 pods compiled from source"), finding.title)
        XCTAssertEqual(RulesFixtures.run(RulesFixtures.context(RulesFixtures.acmeApp()), rules: ["DEP-004"])
            .outcome("DEP-004")?.list, "notApplicable")
    }

    func testENV008MacroPluginsOnXcode26() throws {
        var model = RulesFixtures.acmeApp()
        let index = model.packages.firstIndex { $0.manifest != nil }!
        model.packages[index].manifest?.targets = [
            .init(name: "Feature", type: "regular", dependencies: ["MacrosA", "MacrosB"]),
            .init(name: "MacrosA", type: "macro"), .init(name: "MacrosB", type: "macro"),
            .init(name: "Light", type: "regular", dependencies: ["MacrosA"]),
        ]
        func run(_ xcode: String) -> RuleResult {
            RulesFixtures.run(RulesFixtures.context(model, xcode: xcode, env: RulesFixtures.env()), rules: ["ENV-008"])
        }
        let finding = try XCTUnwrap(run("26.0.1").finding("ENV-008"))
        XCTAssertEqual(finding.signalKey, "macro-plugins:Feature")
        XCTAssertTrue(finding.title.contains("Feature loads 2 macro plugins"), finding.title)
        XCTAssertEqual(run("27.0").outcome("ENV-008")?.list, "notApplicable", "Xcode 26.x only")
    }
}

/// Re-check R3 and R6 (second pass).
final class RulesSecondRecheckTests: XCTestCase {
    func testSharedNamesAreQualifiedEvenWhenOneOutputListsThemOnce() throws {
        let json = #"[{"target":"App","action":"build","buildSettings":{"PROJECT_NAME":"Two","SDKROOT":"macosx"}}]"#
        XCTAssertEqual(Set(try XCTUnwrap(XcodebuildSettings.parse(Data(json.utf8), qualified: ["App"])).keys), ["Two/App"])
        XCTAssertEqual(Set(try XCTUnwrap(XcodebuildSettings.parse(Data(json.utf8))).keys), ["App"])
    }

    /// ENV-008 with remote packages: unread manifests are N/A, not a pass; a checkout manifest whose products wrap
    /// macro targets makes a project target using two of them fire.
    func testENV008RemoteMacroProducts() throws {
        let root = SettingsFixtures.scratch("recheck-env008", self)
        let xcodeproj = root.appendingPathComponent("App.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        var model = RulesFixtures.acmeApp()
        model.root = root
        model.container = .xcodeproj(xcodeproj)
        model.packages = [.init(url: "https://github.com/acme/macro-kit", path: nil, requirement: .exact("1.0.0"))]
        model.projects[0].targets[0].packageProducts = ["MacroKitA", "MacroKitB"]
        func run() -> RuleResult {
            RulesFixtures.run(RulesFixtures.context(model, xcode: "26.0.1", env: RulesFixtures.env()), rules: ["ENV-008"])
        }
        let unknown = try XCTUnwrap(run().outcome("ENV-008"))
        XCTAssertEqual(unknown.list, "notApplicable")
        XCTAssertTrue(unknown.detail.contains("macro products of remote packages unknown"), unknown.detail)

        let derived = root.appendingPathComponent("build/dd")
        let checkout = derived.appendingPathComponent("SourcePackages/checkouts/macro-kit")
        try FileManager.default.createDirectory(at: checkout, withIntermediateDirectories: true)
        try NSDictionary(dictionary: ["WorkspacePath": xcodeproj.path]).write(to: derived.appendingPathComponent("info.plist"))
        try Data("""
            // swift-tools-version:5.9
            import PackageDescription
            let package = Package(
                name: "macro-kit",
                products: [.library(name: "MacroKitA", targets: ["MacroKitA"]), .library(name: "MacroKitB", targets: ["MacroKitB"])],
                targets: [
                    .macro(name: "PluginA"), .macro(name: "PluginB"),
                    .target(name: "MacroKitA", dependencies: ["PluginA"]),
                    .target(name: "MacroKitB", dependencies: ["PluginB"]),
                ]
            )
            """.utf8).write(to: checkout.appendingPathComponent("Package.swift"))
        let finding = try XCTUnwrap(run().finding("ENV-008"))
        XCTAssertEqual(finding.signalKey, "macro-plugins:Acme")
        XCTAssertTrue(finding.title.contains("Acme loads 2 macro plugins (MacroKitA, MacroKitB)"), finding.title)
    }
}

/// The write guard's run-wide note appears once in `project.notes`, not once per configuration.
final class GuardNoteDedupeTests: XCTestCase {
    func testGuardNotesAreNotRepeatedPerConfiguration() {
        let model = RulesFixtures.acmeApp()
        var settings = RulesFixtures.effective(model)
        for configuration in settings.keys {
            settings[configuration]!.notes = ["removed empty folders xcodebuild created: Packages/X/.swiftpm", "cache hit"]
        }
        let doc = ReportDocument.makeDoctor(project: model, settings: settings, result: RuleResult(),
                                            configurations: ["Debug", "Release"], environment: nil, xcode: "26.0.1",
                                            generatedAt: Date(timeIntervalSince1970: 0), durationSeconds: nil, offline: false,
                                            failOn: nil)
        let notes = doc.project?.notes ?? []
        XCTAssertEqual(notes.filter { $0.contains("removed empty folders") }, ["removed empty folders xcodebuild created: Packages/X/.swiftpm"])
        XCTAssertTrue(notes.contains("Debug: cache hit") && notes.contains("Release: cache hit"), "\(notes)")
    }
}
