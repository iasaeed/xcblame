import XCTest
@testable import XcblameKit

/// One firing and one passing (or not-applicable) context per rule, on the hand-built fixture mirrors
/// (docs/SCHEMA-v0.3.md fixture inventory).
final class RulesPredicateTests: XCTestCase {
    typealias Extra = [String: [String: [String: String]]]

    private func evaluate(_ id: String, _ model: ProjectModel, extra: Extra = [:], xcode: String? = "26.0.1",
                          isCI: Bool = false, env: EnvSnapshot? = RulesFixtures.env(), probe: MachineProbe = RulesFixtures.probe(),
                          analysis: Analysis? = nil, document: ReportDocument? = nil)
        -> (list: String, detail: String, findings: [ReportDocument.Finding]) {
        let context = RulesFixtures.context(model, settings: RulesFixtures.effective(model, extra: extra), xcode: xcode,
                                            env: env, isCI: isCI, analysis: analysis, document: document)
        let result = RulesFixtures.run(context, rules: [id], probe: probe)
        XCTAssertEqual(result.rulesEvaluated, 1, id)
        let outcome = result.outcome(RuleCatalog.resolve(id)) ?? ("missing", "")
        return (outcome.list, outcome.detail, result.findings(RuleCatalog.resolve(id)))
    }

    @discardableResult
    private func fires(_ id: String, _ model: ProjectModel, extra: Extra = [:], xcode: String? = "26.0.1", isCI: Bool = false,
                       env: EnvSnapshot? = RulesFixtures.env(), probe: MachineProbe = RulesFixtures.probe(),
                       file: StaticString = #filePath, line: UInt = #line) -> ReportDocument.Finding? {
        let result = evaluate(id, model, extra: extra, xcode: xcode, isCI: isCI, env: env, probe: probe)
        XCTAssertEqual(result.list, "finding", "\(id): \(result.detail)", file: file, line: line)
        return result.findings.first
    }

    private func passes(_ id: String, _ model: ProjectModel, extra: Extra = [:], xcode: String? = "26.0.1", isCI: Bool = false,
                        env: EnvSnapshot? = RulesFixtures.env(), probe: MachineProbe = RulesFixtures.probe(),
                        expect list: String = "passed", file: StaticString = #filePath, line: UInt = #line) {
        let result = evaluate(id, model, extra: extra, xcode: xcode, isCI: isCI, env: env, probe: probe)
        XCTAssertEqual(result.list, list, "\(id): \(result.findings.first?.title ?? result.detail)", file: file, line: line)
    }

    private let acme = RulesFixtures.acmeApp()
    private let legacy = RulesFixtures.acmeLegacy()
    private let pods = RulesFixtures.podsLike()

    private func legacy(_ change: (inout ProjectModel) -> Void) -> ProjectModel {
        var model = RulesFixtures.acmeLegacy()
        change(&model)
        return model
    }

    // MARK: - SET

    func testDebugSettingsFireOnAcmeAppAndPassOnAcmeLegacy() throws {
        for id in ["SET-001", "SET-002", "SET-003", "SET-004", "SET-005"] {
            let finding = fires(id, acme)
            XCTAssertEqual(finding?.scopeConfigurations, ["Debug"], id)
            passes(id, legacy)
        }
        XCTAssertEqual(fires("SET-003", acme)?.scopeTargets, ["Acme"], "only the target with C sources")
        XCTAssertTrue(fires("SET-001", acme)?.title.hasPrefix("SWIFT_COMPILATION_MODE = wholemodule in Debug") ?? false)
        let dsym = try XCTUnwrap(fires("SET-004", acme))
        XCTAssertTrue(dsym.evidence.contains { $0.contains("Upload Symbols") && $0.contains("PHASE-002") }, "\(dsym.evidence)")
        XCTAssertEqual(evaluate("SET-001", legacy).detail, "Debug: singlefile")
        let flag = fires("SET-001", legacy, extra: ["Debug": ["AcmeLegacy": ["OTHER_SWIFT_FLAGS": " -wmo"]]])
        XCTAssertEqual(flag?.fixKind, "recommend", "a -wmo flag is not fixed by the overlay")
    }

    func testValidArchsAndCIDeliveryForSET005() throws {
        var model = legacy
        model.projects[0].projectSettings["Debug"]?["VALID_ARCHS"] = SettingValue(raw: "arm64 x86_64")
        let finding = try XCTUnwrap(fires("SET-005", model))
        XCTAssertTrue(finding.evidence.contains { $0.contains("VALID_ARCHS = arm64 x86_64") }, "\(finding.evidence)")
        let ci = try XCTUnwrap(fires("SET-005", acme, isCI: true))
        XCTAssertEqual(ci.fixKind, "cli")
        XCTAssertTrue(ci.fixCommands.first?.contains("ONLY_ACTIVE_ARCH=YES") ?? false)
    }

    func testSET006FromThePodfileAndFromConditionalSettings() throws {
        let finding = try XCTUnwrap(fires("SET-006", pods))
        XCTAssertEqual(finding.needsMeasurement, true)
        XCTAssertEqual(finding.confidence, "low")
        let conditional = legacy { $0.projects[0].targets[0].settings["Debug"] = [
            "EXCLUDED_ARCHS": SettingValue(raw: nil, conditions: ["sdk=iphonesimulator*": "arm64"]),
        ] }
        XCTAssertEqual(fires("SET-006", conditional)?.scopeTargets, ["AcmeLegacy"])
        passes("SET-006", acme)
    }

    func testSET007ReleaseTestability() {
        fires("SET-007", legacy, extra: ["Release": ["AcmeLegacy": ["ENABLE_TESTABILITY": "YES"]]])
        passes("SET-007", acme)
    }

    func testSET008AndSET017NeedCI() throws {
        let finding = try XCTUnwrap(fires("SET-008", legacy, isCI: true, env: RulesFixtures.env(ci: "github-actions")))
        XCTAssertEqual(finding.fixKind, "cli")
        XCTAssertTrue(finding.fixCommands[0].contains("COMPILER_INDEX_STORE_ENABLE=NO"))
        passes("SET-008", legacy, expect: "notApplicable")
        passes("SET-008", legacy, extra: ["Debug": ["AcmeLegacy": ["COMPILER_INDEX_STORE_ENABLE": "NO"],
                                                    "AcmeLegacyKit": ["COMPILER_INDEX_STORE_ENABLE": "NO"]],
                                          "Release": ["AcmeLegacy": ["COMPILER_INDEX_STORE_ENABLE": "NO"],
                                                      "AcmeLegacyKit": ["COMPILER_INDEX_STORE_ENABLE": "NO"]]],
               isCI: true)
        fires("SET-017", legacy, isCI: true)
        passes("SET-017", legacy, expect: "notApplicable")
        passes("SET-017", legacy, xcode: "16.4", isCI: true, expect: "notApplicable")
    }

    func testSET009BatchModeSettingAndFlag() throws {
        let setting = try XCTUnwrap(fires("SET-009", acme))
        XCTAssertEqual(setting.scopeTargets, ["AcmeKit"])
        XCTAssertEqual(setting.scopeConfigurations, ["Debug", "Release"])
        let flag = try XCTUnwrap(fires("SET-009", legacy, extra: ["Debug": ["AcmeLegacy": ["OTHER_SWIFT_FLAGS": " -disable-batch-mode"]]]))
        XCTAssertEqual(flag.fixKind, "project")
        passes("SET-009", legacy)
    }

    func testSET010BitcodeFromSettingsFlagsAndPodfile() throws {
        XCTAssertEqual(fires("SET-010", acme)?.fixKind, "overlay", "shadowed for the hook by project settings: cli")
        XCTAssertEqual(fires("SET-010", pods)?.title.hasPrefix("Podfile post_install sets ENABLE_BITCODE = YES"), true)
        XCTAssertEqual(fires("SET-010", legacy, extra: ["Debug": ["AcmeLegacy": ["OTHER_LDFLAGS": " -fembed-bitcode"]]])?.fixKind,
                       "project")
        XCTAssertEqual(fires("SET-010", acme, xcode: "13.4")?.severity, "medium", "bitcode still costs on Xcode 13")
        passes("SET-010", legacy)
    }

    func testSET013ExplicitModulesByXcodeVersion() throws {
        let off = try XCTUnwrap(fires("SET-013", legacy, extra: ["Debug": ["AcmeLegacy": ["SWIFT_ENABLE_EXPLICIT_MODULES": "NO"]]]))
        XCTAssertEqual(off.fixKind, "recommend")
        XCTAssertTrue(off.title.contains("review"))
        passes("SET-013", legacy)
        XCTAssertEqual(fires("SET-013", legacy, xcode: "16.4")?.overlayLines,
                       ["_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES = YES // xcblame SET-013"])
        passes("SET-013", legacy, xcode: "15.4", expect: "notApplicable")
        passes("SET-013", legacy, xcode: nil, expect: "notApplicable")
    }

    func testSET014ClangModules() {
        fires("SET-014", legacy, extra: ["Debug": ["AcmeLegacyKit": ["CLANG_ENABLE_MODULES": "NO"]]])
        fires("SET-014", legacy, extra: ["Release": ["AcmeLegacyKit": ["DEFINES_MODULE": "NO"]]])
        passes("SET-014", acme)
    }

    func testSET015IntegratedDriver() throws {
        let modern = try XCTUnwrap(fires("SET-015", legacy, extra: ["Debug": ["AcmeLegacy": ["SWIFT_USE_INTEGRATED_DRIVER": "NO"]]]))
        XCTAssertEqual(modern.fixKind, "recommend")
        XCTAssertTrue(modern.title.contains("SET-016"))
        let older = fires("SET-015", legacy, extra: ["Debug": ["AcmeLegacy": ["SWIFT_USE_INTEGRATED_DRIVER": "NO"]]], xcode: "15.4")
        XCTAssertEqual(older?.overlayLines, ["SWIFT_USE_INTEGRATED_DRIVER = YES // xcblame SET-015"])
        passes("SET-015", legacy)
    }

    func testSET016CompilationCache() throws {
        let finding = try XCTUnwrap(fires("SET-016", acme))
        XCTAssertEqual(finding.overlayLines, ["COMPILATION_CACHE_ENABLE_CACHING = YES // xcblame SET-016"])
        XCTAssertEqual(finding.fixCommands, ["xcblame verify --rules SET-016 --kind clean --mechanism hook",
                                             "xcblame fix --rules SET-016 --apply"])
        XCTAssertTrue(finding.needsMeasurement)
        XCTAssertEqual(finding.impactBand, "?")
        XCTAssertTrue(finding.title.contains("SPM package caching unverified"))
        let on = ["COMPILATION_CACHE_ENABLE_CACHING": "YES"]
        passes("SET-016", legacy, extra: ["Debug": ["AcmeLegacy": on, "AcmeLegacyKit": on]])
        passes("SET-016", legacy, xcode: "16.4", expect: "notApplicable")
    }

    func testSET020TimingFlagsInRelease() throws {
        let finding = try XCTUnwrap(fires("SET-020", acme))
        XCTAssertEqual(finding.scopeConfigurations, ["Release"])
        XCTAssertTrue(finding.title.contains("-debug-time-function-bodies"))
        XCTAssertEqual(finding.fixKind, "project")
        passes("SET-020", legacy)
    }

    func testSET021PrefixHeader() {
        let header = ["GCC_PREFIX_HEADER": "Kit/Prefix.pch", "GCC_PRECOMPILE_PREFIX_HEADER": "NO"]
        fires("SET-021", legacy, extra: ["Debug": ["AcmeLegacyKit": header]])
        passes("SET-021", legacy, extra: ["Debug": ["AcmeLegacyKit": ["GCC_PREFIX_HEADER": "Kit/Prefix.pch"]]])
        passes("SET-021", legacy, expect: "notApplicable")
    }

    func testSET022HeaderSearch() throws {
        let finding = try XCTUnwrap(fires("SET-022", legacy, extra: ["Debug": ["AcmeLegacyKit": ["USE_HEADERMAP": "NO"]]]))
        XCTAssertEqual(finding.confidence, "low")
        XCTAssertEqual(fires("SET-022", legacy, extra: ["Debug": ["AcmeLegacyKit": ["HEADER_SEARCH_PATHS": "$(SRCROOT)/**"]]])?.fixKind,
                       "recommend")
        passes("SET-022", legacy)
    }

    func testSET023EagerLinkingNeedsTwoSwiftOnlyDynamicFrameworks() throws {
        passes("SET-023", acme, expect: "notApplicable")
        let model = legacy { model in
            model.projects[0].targets[1].hasCSources = false
            model.projects[0].targets.append(.init(id: "AB0000000000000000000032", name: "AcmeUI",
                                                   productType: "com.apple.product-type.framework", hasSwiftSources: true,
                                                   frameworkKind: .dynamic))
        }
        let finding = try XCTUnwrap(fires("SET-023", model))
        XCTAssertEqual(finding.fixCommands.first, "xcblame verify --rules SET-023 --kind incremental --mechanism hook")
        let on = ["EAGER_LINKING": "YES"]
        passes("SET-023", model, extra: ["Debug": ["AcmeLegacy": on, "AcmeLegacyKit": on, "AcmeUI": on]])
    }

    func testSET027LdClassic() throws {
        let finding = try XCTUnwrap(fires("SET-027", acme))
        XCTAssertEqual(finding.severity, "medium")
        XCTAssertEqual(fires("SET-027", acme, xcode: "27.0")?.severity, "high", "Xcode 27 removed ld64")
        passes("SET-027", legacy)
    }

    func testSET028LTO() throws {
        let debug = try XCTUnwrap(fires("SET-028", legacy, extra: ["Debug": ["AcmeLegacy": ["LLVM_LTO": "YES_THIN"]]]))
        XCTAssertEqual(debug.overlayLines, ["LLVM_LTO = NO // xcblame SET-028"])
        XCTAssertEqual(fires("SET-028", legacy, extra: ["Release": ["AcmeLegacy": ["LLVM_LTO": "YES"]]])?.fixKind, "recommend")
        passes("SET-028", legacy, extra: ["Release": ["AcmeLegacy": ["LLVM_LTO": "YES_THIN"]]])
    }

    func testSET029StripInDebug() {
        fires("SET-029", legacy, extra: ["Debug": ["AcmeLegacy": ["COPY_PHASE_STRIP": "YES"]]])
        passes("SET-029", legacy)
    }

    func testSET030WaitsForPHASE001() throws {
        XCTAssertEqual(evaluate("SET-030", acme).list, "suppressed")
        XCTAssertTrue(evaluate("SET-030", acme).detail.hasPrefix("deferred until PHASE-001"))
        passes("SET-030", RulesFixtures.genXcodeGen(), expect: "notApplicable")
        let declared = legacy { model in
            model.projects[0].targets[0].phases = [RulesFixtures.script("AB0000000000000000000041", "Generate", "gen\n",
                                                                       inputs: ["in.json"], outputs: ["out.swift"])]
        }
        let finding = try XCTUnwrap(fires("SET-030", declared, extra: ["Debug": ["AcmeLegacy": ["ENABLE_USER_SCRIPT_SANDBOXING": "NO"]]]))
        XCTAssertEqual(finding.scopeTargets, ["AcmeLegacy"])
        let on = ["FUSE_BUILD_SCRIPT_PHASES": "YES"]
        passes("SET-030", declared, extra: ["Debug": ["AcmeLegacy": on], "Release": ["AcmeLegacy": on]])
    }

    func testSET031CrossModuleOptimizationInDebug() {
        fires("SET-031", legacy, extra: ["Debug": ["AcmeLegacy": ["OTHER_SWIFT_FLAGS": " -enable-default-cmo"]]])
        passes("SET-031", legacy, extra: ["Release": ["AcmeLegacy": ["OTHER_SWIFT_FLAGS": " -enable-default-cmo"]]])
    }

    func testSET032LibraryEvolutionWithoutXCFrameworkExport() {
        let evolution: Extra = ["Debug": ["AcmeLegacyKit": ["BUILD_LIBRARY_FOR_DISTRIBUTION": "YES"]]]
        fires("SET-032", legacy, extra: evolution)
        let exporter = legacy { $0.projects[0].targets[0].phases.append(
            RulesFixtures.script("AB0000000000000000000042", "Export", "xcodebuild -create-xcframework -output Kit.xcframework\n")) }
        passes("SET-032", exporter, extra: evolution)
    }

    // MARK: - PHASE

    func testPHASE001PerPhaseFindings() throws {
        let result = evaluate("PHASE-001", acme)
        XCTAssertEqual(result.findings.map(\.signalKey), ["script-phase:AC0000000000000000000043",
                                                          "script-phase:AC0000000000000000000045",
                                                          "script-phase:AC0000000000000000000046"],
                       "Lint, Upload Symbols, Stamp Build; not Generate Constants")
        XCTAssertEqual(evaluate("PHASE-001", legacy).findings.map(\.scopeTargets), [["AcmeLegacy"]])
        passes("PHASE-001", pods, expect: "notApplicable")
        passes("PHASE-001", RulesFixtures.genXcodeGen(), expect: "notApplicable")
    }

    func testPHASE002GuardsAndPHASE003Linters() throws {
        let guardFinding = try XCTUnwrap(fires("PHASE-002", acme))
        XCTAssertEqual(guardFinding.signalKey, "script-guard:AC0000000000000000000045")
        XCTAssertTrue(guardFinding.title.contains("sentry-cli"))
        let guarded = legacy { $0.projects[0].targets[0].phases = [RulesFixtures.script(
            "AB0000000000000000000043", "Upload", "if [ \"${CONFIGURATION}\" = \"Release\" ]; then sentry-cli upload-dif .; fi\n")] }
        passes("PHASE-002", guarded)
        XCTAssertEqual(fires("PHASE-003", acme)?.signalKey, "script-linter:AC0000000000000000000043")
        passes("PHASE-003", legacy)
    }

    func testPHASE004CodegenAndPHASE005Plugins() throws {
        let codegen = legacy { $0.projects[0].targets[0].phases = [RulesFixtures.script("AB0000000000000000000044", "SwiftGen",
                                                                                         "swiftgen config run\n")] }
        fires("PHASE-004", codegen)
        passes("PHASE-004", acme)
        let plugin = try XCTUnwrap(fires("PHASE-005", acme))
        XCTAssertEqual(plugin.signalKey, "package-plugin:AcmeShared:AcmeShared")
        passes("PHASE-005", legacy, expect: "notApplicable")
    }

    func testPHASE007CocoaPodsPhases() {
        fires("PHASE-007", pods)
        passes("PHASE-007", acme, expect: "notApplicable")
    }

    // MARK: - DEP

    func testDEP001BranchPins() throws {
        let finding = try XCTUnwrap(fires("DEP-001", acme))
        XCTAssertEqual(finding.signalKey, "package:github.com/apple/swift-argument-parser")
        XCTAssertEqual(finding.fixKind, "project")
        passes("DEP-001", legacy, expect: "notApplicable")
        var pinned = acme
        pinned.packages[0].requirement = .exact("1.5.0")
        passes("DEP-001", pinned)
    }

    func testDEP002PackageResolved() throws {
        passes("DEP-002", acme)
        var model = pods
        model.packages = [.init(url: "https://github.com/apple/swift-collections", path: nil, requirement: .exact("1.1.4"))]
        XCTAssertTrue(fires("DEP-002", model)?.title.hasPrefix("Package.resolved is missing") ?? false)
        let root = acme.root.path
        let untracked = RulesFixtures.probe(run: ["git -C \(root) rev-parse --is-inside-work-tree": "true"])
        XCTAssertTrue(fires("DEP-002", acme, probe: untracked)?.title.contains("not tracked by git") ?? false)
        passes("DEP-002", legacy, expect: "notApplicable")
    }

    func testDEP003HeavyDependencies() throws {
        var model = acme
        model.packages.append(.init(url: "https://github.com/firebase/firebase-ios-sdk.git", path: nil,
                                    requirement: .upToNextMajor("11.0.0")))
        let finding = try XCTUnwrap(fires("DEP-003", model))
        XCTAssertEqual(finding.signalKey, "heavy-dependency:Firebase")
        XCTAssertEqual(finding.confidence, "low")
        passes("DEP-003", acme)
    }

    func testDEP005DEP006DEP007Managers() {
        fires("DEP-005", pods)
        passes("DEP-005", acme, expect: "notApplicable")
        fires("DEP-006", pods)
        passes("DEP-006", acme, expect: "notApplicable")
        fires("DEP-007", RulesFixtures.genTuist())
        passes("DEP-007", acme, expect: "notApplicable")
    }

    func testDEP008SwiftSyntaxPrebuilts() throws {
        passes("DEP-008", acme, expect: "notApplicable")
        var model = acme
        model.packages[2].manifest?.targets.append(.init(name: "AcmeMacros", type: "macro", dependencies: ["SwiftSyntaxMacros"]))
        let finding = try XCTUnwrap(fires("DEP-008", model))
        XCTAssertEqual(finding.fixKind, "manifest")
        model.packages[2].manifest?.dependencies[0].url = "https://github.com/swiftlang/swift-syntax"
        passes("DEP-008", model)
        XCTAssertEqual(fires("DEP-008", model, xcode: "16.4")?.fixKind, "defaults", "16.4 without IDEPackageEnablePrebuilts")
    }

    func testDEP010XCRemoteCache() {
        fires("DEP-010", legacy, extra: ["Debug": ["AcmeLegacy": ["CC": "/repo/xcremotecache/xccc"]]])
        passes("DEP-010", acme)
    }

    func testDEP012SwiftSyntaxAsALibrary() throws {
        let finding = try XCTUnwrap(fires("DEP-012", acme))
        XCTAssertEqual(finding.scopeTargets, ["AcmeShared"])
        XCTAssertTrue(finding.title.hasPrefix("swift-syntax 602.0.0 is a library dependency of AcmeShared"))
        XCTAssertTrue(finding.evidence.contains { $0.contains("run xcblame analyze on a clean build") })
        passes("DEP-012", legacy)
    }

    // MARK: - ENV

    func testENV001ShowBuildDuration() throws {
        let finding = try XCTUnwrap(fires("ENV-001", legacy, probe: RulesFixtures.probe(defaults: [:])))
        XCTAssertEqual(finding.fixKind, "defaults")
        XCTAssertEqual(finding.fixCommands, ["xcblame fix --rules ENV-001 --apply-defaults"])
        passes("ENV-001", legacy)
        passes("ENV-001", legacy, env: nil, expect: "notApplicable")
    }

    func testENV002ConcurrentCompileTasks() {
        let capped = RulesFixtures.probe(defaults: ["IDEBuildOperationMaxNumberOfConcurrentCompileTasks": "4"])
        fires("ENV-002", legacy, probe: capped)
        passes("ENV-002", legacy)
        passes("ENV-002", legacy, env: RulesFixtures.env(cores: 4), probe: capped)
    }

    func testENV003IndexDisable() {
        fires("ENV-003", legacy, probe: RulesFixtures.probe(defaults: ["IDEIndexDisable": "1"]))
        fires("ENV-003", legacy, isCI: true)
        passes("ENV-003", legacy)
    }

    func testENV004DerivedDataLocation() throws {
        let backedUp = RulesFixtures.probe(run: [
            "tmutil destinationinfo": "Name: Backup", "tmutil isexcluded /Users/sample/Library/Developer/Xcode/DerivedData":
                "[Included] /Users/sample/Library/Developer/Xcode/DerivedData",
        ])
        let finding = try XCTUnwrap(fires("ENV-004", legacy, probe: backedUp))
        XCTAssertTrue(finding.title.contains("tmutil addexclusion"))
        XCTAssertTrue(finding.needsMeasurement)
        fires("ENV-004", legacy, probe: RulesFixtures.probe(freeShare: 0.04))
        fires("ENV-004", legacy, probe: RulesFixtures.probe(symlink: true))
        passes("ENV-004", legacy)
    }

    func testENV005RosettaRamThermal() throws {
        XCTAssertEqual(fires("ENV-005", legacy, env: RulesFixtures.env(rosetta: true))?.severity, "high")
        fires("ENV-005", legacy, env: RulesFixtures.env(memoryGB: 8))
        fires("ENV-005", legacy, probe: RulesFixtures.probe(run: ["pmset -g therm": "CPU_Speed_Limit = 70"]))
        passes("ENV-005", legacy)
    }

    func testENV006KnownIssues() {
        fires("ENV-006", legacy, xcode: "27.0")
        fires("ENV-006", legacy, xcode: "15.0.1")
        fires("ENV-006", legacy, probe: RulesFixtures.probe(xcodeApps: ["Xcode.app", "Xcode-beta.app"]))
        passes("ENV-006", legacy)
    }
}
