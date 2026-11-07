import Foundation
import XCTest
@testable import XcblameKit

/// Hand-built `ProjectModel` / `EffectiveSettings` values that mirror `fixtures/projects/*` (docs/SCHEMA-v0.3.md
/// fixture inventory), so the rules run before Lanes A and B land. Effective values are layered as xcodebuild would
/// report them: platform defaults < project settings < target settings.
enum RulesFixtures {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/projects")

    typealias Settings = [String: [String: SettingValue]]

    static func values(_ pairs: [String: String]) -> [String: SettingValue] {
        pairs.mapValues { SettingValue(raw: $0) }
    }

    static func defaults(_ configuration: String, _ target: ProjectModel.Target) -> [String: String] {
        let debug = configuration.lowercased().hasPrefix("debug")
        var values: [String: String] = [
            "SWIFT_COMPILATION_MODE": debug ? "singlefile" : "wholemodule",
            "SWIFT_OPTIMIZATION_LEVEL": debug ? "-Onone" : "-O",
            "GCC_OPTIMIZATION_LEVEL": debug ? "0" : "s",
            "DEBUG_INFORMATION_FORMAT": debug ? "dwarf" : "dwarf-with-dsym",
            "ONLY_ACTIVE_ARCH": debug ? "YES" : "NO",
            "ENABLE_TESTABILITY": debug ? "YES" : "NO",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": debug ? "DEBUG" : "",
            "ENABLE_BITCODE": "NO", "CLANG_ENABLE_MODULES": "YES", "USE_HEADERMAP": "YES",
            "ALWAYS_SEARCH_USER_PATHS": "NO", "COPY_PHASE_STRIP": "NO", "LLVM_LTO": "NO",
            "SWIFT_ENABLE_EXPLICIT_MODULES": "YES", "SWIFT_USE_INTEGRATED_DRIVER": "YES",
            "ENABLE_USER_SCRIPT_SANDBOXING": "YES", "OTHER_SWIFT_FLAGS": " ", "OTHER_LDFLAGS": " ",
            "COMPILER_INDEX_STORE_ENABLE": "YES", "PLATFORM_NAME": "iphonesimulator",
        ]
        if target.productType.contains("framework") { values["DEFINES_MODULE"] = "YES" }
        return values
    }

    /// Effective settings for every configuration of `project`'s first project: defaults < project < target.
    static func effective(_ model: ProjectModel, source: EffectiveSettings.Source = .xcodebuild,
                          extra: [String: [String: [String: String]]] = [:]) -> [String: EffectiveSettings] {
        var out: [String: EffectiveSettings] = [:]
        for configuration in model.configurationNames {
            var targets: [String: [String: String]] = [:]
            for project in model.projects {
                for target in project.targets {
                    var values = defaults(configuration, target)
                    for (key, value) in project.projectSettings[configuration] ?? [:] {
                        if let raw = value.raw { values[key] = expand(raw, values[key]) }
                    }
                    for (key, value) in target.settings[configuration] ?? [:] {
                        if let raw = value.raw { values[key] = expand(raw, values[key]) }
                    }
                    for (key, value) in extra[configuration]?[target.name] ?? [:] { values[key] = value }
                    targets[target.name] = values
                }
            }
            out[configuration] = EffectiveSettings(configuration: configuration, targets: targets, source: source)
        }
        return out
    }

    static func expand(_ raw: String, _ inherited: String?) -> String {
        raw.replacingOccurrences(of: "$(inherited)", with: inherited ?? "")
    }

    static func context(_ model: ProjectModel, settings: [String: EffectiveSettings]? = nil, xcode: String? = "26.0.1",
                        env: EnvSnapshot? = nil, isCI: Bool = false, offline: Bool = false,
                        analysis: Analysis? = nil, document: ReportDocument? = nil) -> RuleContext {
        RuleContext(project: model, settings: settings ?? effective(model), env: env, analysis: analysis,
                    document: document, xcode: xcode, isCI: isCI, offline: offline)
    }

    static func script(_ id: String, _ name: String, _ text: String, inputs: [String] = [], outputs: [String] = [],
                       always: Bool = false) -> ProjectModel.BuildPhase {
        .shellScript(.init(id: id, name: name, shellScript: text, inputPaths: inputs, outputPaths: outputs,
                           alwaysOutOfDate: always))
    }

    // MARK: - AcmeApp

    static func acmeApp() -> ProjectModel {
        let dir = root.appendingPathComponent("AcmeApp")
        let xcodeproj = dir.appendingPathComponent("AcmeApp.xcodeproj")
        let acme = ProjectModel.Target(
            id: "AC0000000000000000000030", name: "Acme", productType: "com.apple.product-type.application",
            hasSwiftSources: true, hasCSources: true, hasBridgingHeader: true,
            phases: [
                script("AC0000000000000000000043", "Lint",
                       "if which swiftlint >/dev/null; then\n  swiftlint\nelse\n  echo \"warning: swiftlint not installed\"\nfi\n"),
                script("AC0000000000000000000044", "Generate Constants",
                       "echo \"let constantsJSON = ...\" > \"$SCRIPT_OUTPUT_FILE_0\"\n",
                       inputs: ["$(SRCROOT)/Config/Constants.json"], outputs: ["$(DERIVED_FILE_DIR)/Constants.swift"]),
                script("AC0000000000000000000045", "Upload Symbols",
                       "export SENTRY_ORG=acme\nsentry-cli upload-dif --include-sources \"$DWARF_DSYM_FOLDER_PATH\"\n"),
                script("AC0000000000000000000046", "Stamp Build", "date > \"$SCRIPT_OUTPUT_FILE_0\"\n",
                       outputs: ["$(DERIVED_FILE_DIR)/stamp.txt"], always: true),
                .sources(count: 3),
            ],
            dependencies: ["AcmeKit", "AcmeCore"], packageProducts: ["ArgumentParser", "AcmeShared"])
        let kit = ProjectModel.Target(
            id: "AC0000000000000000000031", name: "AcmeKit", productType: "com.apple.product-type.framework",
            hasSwiftSources: true,
            settings: ["Debug": values(["SWIFT_ENABLE_BATCH_MODE": "NO", "MACH_O_TYPE": "mh_dylib"]),
                       "Release": values(["SWIFT_ENABLE_BATCH_MODE": "NO", "MACH_O_TYPE": "mh_dylib"])],
            phases: [.sources(count: 1)], packageProducts: ["Collections"], frameworkKind: .dynamic)
        let core = ProjectModel.Target(id: "AC0000000000000000000032", name: "AcmeCore",
                                       productType: "com.apple.product-type.library.static", hasSwiftSources: true,
                                       phases: [.sources(count: 1)], frameworkKind: .static)
        let tests = ProjectModel.Target(id: "AC0000000000000000000033", name: "AcmeTests",
                                        productType: "com.apple.product-type.bundle.unit-test", hasSwiftSources: true,
                                        phases: [.sources(count: 1)], dependencies: ["Acme"], isTest: true)
        let project = ProjectModel.Project(
            path: xcodeproj, name: "AcmeApp", objectVersion: 77, configurations: ["Debug", "Release"],
            defaultConfiguration: "Release",
            projectSettings: [
                "Debug": values(["SWIFT_COMPILATION_MODE": "wholemodule", "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                                 "ONLY_ACTIVE_ARCH": "NO", "SWIFT_OPTIMIZATION_LEVEL": "-O", "GCC_OPTIMIZATION_LEVEL": "s",
                                 "ENABLE_BITCODE": "YES", "OTHER_LDFLAGS": "-ld_classic",
                                 "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)"]),
                "Release": values(["SWIFT_COMPILATION_MODE": "wholemodule", "SWIFT_OPTIMIZATION_LEVEL": "-O",
                                   "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                                   "OTHER_SWIFT_FLAGS": "$(inherited) -debug-time-function-bodies"]),
            ],
            targets: [acme, kit, core, tests])
        let shared = ProjectModel.PackageManifest(
            name: "AcmeShared",
            dependencies: [.init(url: "https://github.com/apple/swift-syntax", path: nil, requirement: .exact("602.0.0"),
                                 products: ["SwiftSyntax"], consumers: ["AcmeShared"])],
            targets: [.init(name: "AcmeShared", type: "regular", dependencies: ["SwiftSyntax"], plugins: ["AcmeGen"]),
                      .init(name: "AcmeGen", type: "plugin")])
        return ProjectModel(
            root: dir, container: .xcodeproj(xcodeproj), format: .pbxproj(objectVersion: 77), projects: [project],
            schemes: [.init(name: "Acme", path: xcodeproj.appendingPathComponent("xcshareddata/xcschemes/Acme.xcscheme"),
                            parallelizeBuildables: false, buildImplicitDependencies: true, isShared: true)],
            packages: [
                .init(url: "https://github.com/apple/swift-argument-parser", path: nil, requirement: .branch("main"),
                      products: ["ArgumentParser"], consumers: ["Acme"]),
                .init(url: "https://github.com/apple/swift-collections", path: nil, requirement: .exact("1.1.4"),
                      products: ["Collections"], consumers: ["AcmeKit"]),
                .init(url: nil, path: dir.appendingPathComponent("Packages/AcmeShared"), requirement: .local,
                      products: ["AcmeShared"], consumers: ["Acme"], manifest: shared),
            ],
            dependencyManagers: [.spm])
    }

    // MARK: - AcmeLegacy

    static func acmeLegacy() -> ProjectModel {
        let dir = root.appendingPathComponent("AcmeLegacy")
        let xcodeproj = dir.appendingPathComponent("AcmeLegacy.xcodeproj")
        let app = ProjectModel.Target(
            id: "AB0000000000000000000030", name: "AcmeLegacy", productType: "com.apple.product-type.application",
            hasSwiftSources: true,
            phases: [.sources(count: 1),
                     script("AB0000000000000000000040", "Version Bump",
                            "/usr/libexec/PlistBuddy -c \"Set :CFBundleVersion $(date +%s)\" \"${TARGET_BUILD_DIR}/${INFOPLIST_PATH}\"\n")],
            dependencies: ["AcmeLegacyKit"])
        let kit = ProjectModel.Target(id: "AB0000000000000000000031", name: "AcmeLegacyKit",
                                      productType: "com.apple.product-type.framework", hasSwiftSources: true,
                                      hasCSources: true, phases: [.sources(count: 2)], frameworkKind: .dynamic)
        let project = ProjectModel.Project(
            path: xcodeproj, name: "AcmeLegacy", objectVersion: 56, configurations: ["Debug", "Release"],
            defaultConfiguration: "Release",
            projectSettings: [
                "Debug": values(["SWIFT_OPTIMIZATION_LEVEL": "-Onone", "DEBUG_INFORMATION_FORMAT": "dwarf",
                                 "ONLY_ACTIVE_ARCH": "YES", "GCC_OPTIMIZATION_LEVEL": "0"]),
                "Release": values(["SWIFT_COMPILATION_MODE": "wholemodule", "SWIFT_OPTIMIZATION_LEVEL": "-O"]),
            ],
            targets: [app, kit])
        return ProjectModel(root: dir, container: .xcodeproj(xcodeproj), format: .pbxproj(objectVersion: 56),
                            projects: [project],
                            schemes: [.init(name: "AcmeLegacy", path: xcodeproj, parallelizeBuildables: true,
                                            buildImplicitDependencies: true, isShared: true)])
    }

    // MARK: - PodsLike

    static func podsLike() -> ProjectModel {
        let dir = root.appendingPathComponent("PodsLike")
        let xcodeproj = dir.appendingPathComponent("PodsLike.xcodeproj")
        let app = ProjectModel.Target(
            id: "D00000000000000000000030", name: "PodsLike", productType: "com.apple.product-type.application",
            hasSwiftSources: true,
            phases: [script("D00000000000000000000043", "[CP] Check Pods Manifest.lock", "diff …\n",
                            inputs: ["${PODS_PODFILE_DIR_PATH}/Podfile.lock", "${PODS_ROOT}/Manifest.lock"],
                            outputs: ["$(DERIVED_FILE_DIR)/Pods-PodsLike-checkManifestLockResult.txt"]),
                     .sources(count: 1),
                     script("D00000000000000000000044", "[CP] Embed Pods Frameworks",
                            "\"${PODS_ROOT}/Target Support Files/Pods-PodsLike/Pods-PodsLike-frameworks.sh\"\n")])
        let project = ProjectModel.Project(path: xcodeproj, name: "PodsLike", objectVersion: 77,
                                           configurations: ["Debug", "Release"], defaultConfiguration: "Release",
                                           targets: [app])
        return ProjectModel(
            root: dir, container: .xcodeproj(xcodeproj), format: .pbxproj(objectVersion: 77), projects: [project],
            dependencyManagers: [.cocoapods(podfile: dir.appendingPathComponent("Podfile"),
                                            lockfile: dir.appendingPathComponent("Podfile.lock"), podCount: 3),
                                 .carthage(cartfile: dir.appendingPathComponent("Cartfile"))])
    }

    // MARK: - Generated projects

    static func generated(_ generator: ProjectModel.Generator, folder: String, name: String) -> ProjectModel {
        let dir = root.appendingPathComponent(folder)
        let xcodeproj = dir.appendingPathComponent("\(name).xcodeproj")
        let app = ProjectModel.Target(id: "E00000000000000000000030", name: name,
                                      productType: "com.apple.product-type.application", hasSwiftSources: true,
                                      phases: [.sources(count: 1)])
        let project = ProjectModel.Project(path: xcodeproj, name: name, objectVersion: 77,
                                           configurations: ["Debug", "Release"], defaultConfiguration: "Release",
                                           targets: [app])
        return ProjectModel(root: dir, container: .xcodeproj(xcodeproj), format: .pbxproj(objectVersion: 77),
                            projects: [project], generator: generator)
    }

    static func genXcodeGen() -> ProjectModel {
        generated(.xcodegen(spec: root.appendingPathComponent("GenXcodeGen/project.yml")), folder: "GenXcodeGen", name: "AcmeGen")
    }

    static func genTuist() -> ProjectModel {
        generated(.tuist(manifest: root.appendingPathComponent("GenTuist/Project.swift")), folder: "GenTuist", name: "AcmeTuist")
    }

    // MARK: - Machine

    /// A probe with no subprocesses: Xcode defaults from `defaults`, everything else unknown or healthy.
    static func probe(defaults: [String: String] = ["ShowBuildOperationDuration": "1"], run extra: [String: String] = [:],
                      symlink: Bool = false, freeShare: Double? = 0.5, xcodeApps: [String] = ["Xcode.app"]) -> MachineProbe {
        MachineProbe(
            run: { argv in
                if argv.count == 4, argv[0] == "defaults", argv[1] == "read" { return defaults[argv[3]] }
                if let answer = extra[argv.joined(separator: " ")] { return answer }
                // Without scripted answers, git (read-only; the fixtures are tracked) is the real one.
                return argv.first == "git" && extra.isEmpty ? runProbe(argv, timeout: 5) : nil
            },
            isSymlink: { _ in symlink }, freeShare: { _ in freeShare }, xcodeApps: { xcodeApps },
            homeDirectory: "/Users/sample")
    }

    static func env(cores: Int = 10, memoryGB: Int64 = 32, rosetta: Bool = false, ci: String? = nil) -> EnvSnapshot {
        var env = EnvSnapshot()
        env.logicalCPUCount = cores
        env.performanceCores = cores - 4
        env.efficiencyCores = 4
        env.memoryBytes = memoryGB << 30
        env.processTranslated = rosetta
        env.ciProvider = ci
        return env
    }

    /// Runs the engine with a fake machine probe.
    /// The fixture through the real reader and oracle (`ProjectModel.load`, `SettingsOracle.effectiveAll`, every
    /// configuration, cache under `.build`), engine run without a machine snapshot (ENV rules N/A) on Xcode 26.0.1.
    /// Skips when xcodebuild is missing.
    static func real(_ container: String, rules: [String]? = nil) throws -> (model: ProjectModel, result: RuleResult) {
        guard runProbe(["xcodebuild", "-version"], timeout: 10) != nil else { throw XCTSkip("xcodebuild not available") }
        SettingsFixtures.isolateCacheHome()
        let model = try ProjectModel.load(container: root.appendingPathComponent(container), scheme: nil)
        let settings = SettingsOracle.effectiveAll(project: model, configurations: model.configurationNames, scheme: nil,
                                                   offline: false, cacheDir: SettingsFixtures.persistentCache
                                                       .appendingPathComponent("rules-e2e"))
        let context = RuleContext(project: model, settings: settings,
                                  provenance: RuleContext.oracleProvenance(model, settings: settings), xcode: "26.0.1")
        return (model, run(context, rules: rules))
    }

    static func run(_ context: RuleContext, rules: [String]? = nil, categories: [RuleSpec.Category]? = nil,
                    probe: MachineProbe = probe()) -> RuleResult {
        MachineProbe.$current.withValue(probe) { RuleEngine.run(context, rules: rules, categories: categories) }
    }
}

extension RuleResult {
    func finding(_ id: String) -> ReportDocument.Finding? { findings.first { $0.ruleId == id } }
    func findings(_ id: String) -> [ReportDocument.Finding] { findings.filter { $0.ruleId == id } }
    func outcome(_ id: String) -> (list: String, detail: String)? {
        if let item = passed.first(where: { $0.ruleId == id }) { return ("passed", item.detail) }
        if let item = notApplicable.first(where: { $0.ruleId == id }) { return ("notApplicable", item.detail) }
        if let item = suppressed.first(where: { $0.ruleId == id }) { return ("suppressed", item.detail) }
        return finding(id).map { ("finding", $0.title) }
    }
}
