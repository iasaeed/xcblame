import XCTest
@testable import XcblameKit

/// `ProjectModel.load` over the fixture projects (docs/SCHEMA-v0.3.md "Fixture inventory").
final class ProjectModelLoadTests: XCTestCase {
    private let root = FixtureProjectTests.root

    private func load(_ relative: String, scheme: String? = nil) throws -> ProjectModel {
        try ProjectModel.load(container: root.appendingPathComponent(relative), scheme: scheme)
    }

    private func target(_ model: ProjectModel, _ name: String) throws -> ProjectModel.Target {
        try XCTUnwrap(model.allTargets.first { $0.name == name }, name)
    }

    private func scripts(_ target: ProjectModel.Target) -> [ProjectModel.ShellScriptPhase] {
        target.phases.compactMap { if case let .shellScript(phase) = $0 { return phase } else { return nil } }
    }

    private func sourcesCount(_ target: ProjectModel.Target) -> Int? {
        for case let .sources(count) in target.phases { return count }
        return nil
    }

    // MARK: - AcmeApp

    func testAcmeAppProjectAndSettings() throws {
        let model = try load("AcmeApp/AcmeApp.xcodeproj")
        XCTAssertEqual(model.format, .pbxproj(objectVersion: 77))
        XCTAssertEqual(model.root.path, root.appendingPathComponent("AcmeApp").path)
        XCTAssertEqual(model.projects.map(\.name), ["AcmeApp"])
        XCTAssertEqual(model.allTargets.map(\.name), ["Acme", "AcmeKit", "AcmeCore", "AcmeTests"])
        let project = try XCTUnwrap(model.projects.first)
        XCTAssertEqual(project.configurations, ["Debug", "Release"])
        XCTAssertEqual(project.defaultConfiguration, "Debug", "the Acme scheme's LaunchAction configuration")
        XCTAssertEqual(project.projectXCConfig, [:])
        XCTAssertNil(model.generator)
        XCTAssertEqual(model.dependencyManagers, [.spm])
        XCTAssertEqual(model.notes, [])

        let debug = try XCTUnwrap(project.projectSettings["Debug"])
        let expected = ["SWIFT_COMPILATION_MODE": "wholemodule", "DEBUG_INFORMATION_FORMAT": "dwarf-with-dsym",
                        "ONLY_ACTIVE_ARCH": "NO", "SWIFT_OPTIMIZATION_LEVEL": "-O", "GCC_OPTIMIZATION_LEVEL": "s",
                        "ENABLE_BITCODE": "YES", "OTHER_LDFLAGS": "-ld_classic",
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
                        "GCC_PREPROCESSOR_DEFINITIONS": "DEBUG=1 $(inherited)"]
        for (key, value) in expected { XCTAssertEqual(debug[key], SettingValue(raw: value), key) }
        XCTAssertEqual(project.projectSettings["Release"]?["OTHER_SWIFT_FLAGS"],
                       SettingValue(raw: "$(inherited) -debug-time-function-bodies"))
        XCTAssertNil(project.projectSettings["Release"]?["ENABLE_BITCODE"])

        let kit = try target(model, "AcmeKit")
        XCTAssertEqual(kit.settings["Debug"]?["SWIFT_ENABLE_BATCH_MODE"], SettingValue(raw: "NO"))
        XCTAssertEqual(kit.settings["Release"]?["SWIFT_ENABLE_BATCH_MODE"], SettingValue(raw: "NO"))
        XCTAssertEqual(kit.frameworkKind, .dynamic)
        XCTAssertEqual(kit.packageProducts, ["Collections"])
        XCTAssertEqual(try target(model, "AcmeCore").frameworkKind, .static)
        let tests = try target(model, "AcmeTests")
        XCTAssertTrue(tests.isTest)
        XCTAssertEqual(tests.dependencies, ["Acme"])
        XCTAssertNil(tests.frameworkKind)
        XCTAssertEqual(tests.productType, "com.apple.product-type.bundle.unit-test")
    }

    func testAcmeAppTargetFactsAndScriptPhases() throws {
        let model = try load("AcmeApp/AcmeApp.xcodeproj")
        let acme = try target(model, "Acme")
        XCTAssertEqual(acme.id, "AC0000000000000000000030")
        XCTAssertEqual(acme.productType, "com.apple.product-type.application")
        XCTAssertTrue(acme.hasSwiftSources, "synchronized folder scan")
        XCTAssertTrue(acme.hasCSources, "Legacy.m in the synchronized folder")
        XCTAssertTrue(acme.hasBridgingHeader)
        XCTAssertFalse(try target(model, "AcmeKit").hasBridgingHeader)
        XCTAssertFalse(try target(model, "AcmeKit").hasCSources)
        XCTAssertEqual(sourcesCount(acme), 2, "AcmeApp.swift + Legacy.m; headers are not sources")
        XCTAssertEqual(sourcesCount(try target(model, "AcmeCore")), 1)
        XCTAssertEqual(acme.dependencies, ["AcmeKit", "AcmeCore"])
        XCTAssertEqual(acme.packageProducts, ["ArgumentParser", "AcmeShared"])
        XCTAssertEqual(acme.frameworkKind, nil)
        XCTAssertFalse(acme.isTest)

        let phases = scripts(acme)
        XCTAssertEqual(phases.map(\.name), ["Lint", "Generate Constants", "Upload Symbols", "Stamp Build"])
        let lint = phases[0], generate = phases[1], upload = phases[2], stamp = phases[3]
        XCTAssertEqual(lint.id, "AC0000000000000000000043")
        XCTAssertTrue(lint.shellScript.contains("swiftlint\n"), "unescaped newlines")
        XCTAssertEqual(lint.inputPaths + lint.outputPaths + lint.inputFileListPaths + lint.outputFileListPaths, [])
        XCTAssertFalse(lint.alwaysOutOfDate)
        XCTAssertEqual(generate.inputPaths, ["$(SRCROOT)/Config/Constants.json"])
        XCTAssertEqual(generate.outputPaths, ["$(DERIVED_FILE_DIR)/Constants.swift"])
        XCTAssertTrue(generate.shellScript.contains(##"#\"$(cat "$SCRIPT_INPUT_FILE_0")\"#"##), generate.shellScript)
        XCTAssertTrue(upload.shellScript.contains("sentry-cli upload-dif"))
        XCTAssertFalse(upload.shellScript.contains("CONFIGURATION"))
        XCTAssertEqual(upload.outputPaths, [])
        XCTAssertTrue(stamp.alwaysOutOfDate)
        XCTAssertEqual(stamp.outputPaths, ["$(DERIVED_FILE_DIR)/stamp.txt"])
        XCTAssertFalse(phases.contains { $0.runOnlyForDeploymentPostprocessing })
        XCTAssertEqual(acme.phases.count, 8)
        XCTAssertEqual(acme.phases[4], .resources(count: 0, largeFileBytes: 0))
        XCTAssertEqual(acme.phases[3], .other(name: "PBXFrameworksBuildPhase"))
    }

    func testAcmeAppPackagesAndScheme() throws {
        let model = try load("AcmeApp/AcmeApp.xcodeproj")
        XCTAssertEqual(model.packages.count, 3)
        let parser = model.packages[0], collections = model.packages[1], shared = model.packages[2]
        XCTAssertEqual(parser.url, "https://github.com/apple/swift-argument-parser")
        XCTAssertEqual(parser.requirement, .branch("main"))
        XCTAssertEqual(parser.products, ["ArgumentParser"])
        XCTAssertEqual(parser.consumers, ["Acme"])
        XCTAssertNil(parser.manifest)
        XCTAssertEqual(collections.requirement, .exact("1.1.4"))
        XCTAssertEqual(collections.consumers, ["AcmeKit"])

        XCTAssertNil(shared.url)
        XCTAssertEqual(shared.path?.path, root.appendingPathComponent("AcmeApp/Packages/AcmeShared").path)
        XCTAssertEqual(shared.requirement, .local)
        XCTAssertEqual(shared.products, ["AcmeShared"], "bound by product name from the manifest (no package key)")
        XCTAssertEqual(shared.consumers, ["Acme"])
        let manifest = try XCTUnwrap(shared.manifest)
        XCTAssertEqual(manifest.name, "AcmeShared")
        XCTAssertEqual(manifest.targets, [
            .init(name: "AcmeShared", type: "regular", dependencies: ["SwiftSyntax"], plugins: ["AcmeGen"]),
            .init(name: "AcmeGen", type: "plugin"),
        ])
        XCTAssertEqual(manifest.dependencies, [
            .init(url: "https://github.com/apple/swift-syntax", path: nil, requirement: .exact("602.0.0"),
                  products: ["SwiftSyntax"], consumers: ["AcmeShared"]),
        ])

        XCTAssertEqual(model.schemes.count, 1)
        let scheme = try XCTUnwrap(model.schemes.first)
        XCTAssertEqual(scheme.name, "Acme")
        XCTAssertEqual(scheme.parallelizeBuildables, false)
        XCTAssertEqual(scheme.buildImplicitDependencies, true)
        XCTAssertTrue(scheme.isShared)
        XCTAssertEqual(scheme.path.lastPathComponent, "Acme.xcscheme")
    }

    // MARK: - AcmeLegacy, Precedence, PodsLike, generators

    func testAcmeLegacyClassicGroups() throws {
        let model = try load("AcmeLegacy/AcmeLegacy.xcodeproj")
        XCTAssertEqual(model.format, .pbxproj(objectVersion: 56))
        let app = try target(model, "AcmeLegacy"), kit = try target(model, "AcmeLegacyKit")
        XCTAssertTrue(app.hasSwiftSources)
        XCTAssertFalse(app.hasCSources)
        XCTAssertEqual(sourcesCount(app), 1)
        XCTAssertTrue(kit.hasSwiftSources)
        XCTAssertTrue(kit.hasCSources)
        XCTAssertEqual(sourcesCount(kit), 2)
        XCTAssertEqual(kit.frameworkKind, .dynamic)
        XCTAssertEqual(kit.phases.first, .other(name: "PBXHeadersBuildPhase"))
        XCTAssertEqual(app.dependencies, ["AcmeLegacyKit"])
        let bump = try XCTUnwrap(scripts(app).first)
        XCTAssertEqual(bump.name, "Version Bump")
        XCTAssertEqual(bump.shellScript,
                       "/usr/libexec/PlistBuddy -c \"Set :CFBundleVersion $(date +%s)\" \"$TARGET_BUILD_DIR/$INFOPLIST_PATH\"\n")
        XCTAssertEqual(bump.outputPaths + bump.inputPaths, [])
        let debug = try XCTUnwrap(model.projects.first?.projectSettings["Debug"])
        XCTAssertEqual(debug["SWIFT_OPTIMIZATION_LEVEL"]?.raw, "-Onone")
        XCTAssertEqual(debug["ONLY_ACTIVE_ARCH"]?.raw, "YES")
        XCTAssertEqual(model.projects.first?.projectSettings["Release"]?["SWIFT_COMPILATION_MODE"]?.raw, "wholemodule")
        XCTAssertEqual(model.schemes.map(\.parallelizeBuildables), [true])
        XCTAssertEqual(model.packages, [])
        XCTAssertEqual(model.dependencyManagers, [])
    }

    func testPrecedenceLevelsAndXCConfigChain() throws {
        let model = try load("Precedence/Precedence.xcodeproj")
        let project = try XCTUnwrap(model.projects.first)
        let config = root.appendingPathComponent("Precedence/Config")
        XCTAssertEqual(project.projectXCConfig["Debug"]?.path, config.appendingPathComponent("project.xcconfig").path)
        XCTAssertEqual(project.projectXCConfig["Release"]?.path, config.appendingPathComponent("project.xcconfig").path)
        let probe = try target(model, "Probe")
        XCTAssertEqual(probe.xcconfig["Debug"]?.path, config.appendingPathComponent("target.xcconfig").path)
        XCTAssertEqual(probe.xcconfig["Release"]?.path, config.appendingPathComponent("target.xcconfig").path)
        // Inputs per level (EXPECTED.md); which one wins is the oracle's job.
        XCTAssertEqual(project.projectSettings["Debug"]?["ACME_PROBE_LAYER"]?.raw, "project-settings")
        XCTAssertEqual(project.projectSettings["Debug"]?["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]?.raw,
                       "$(inherited) DEBUG FROM_PROJECT_SETTINGS")
        XCTAssertEqual(probe.settings["Debug"]?["ACME_PROBE_LAYER"]?.raw, "target-settings")
        XCTAssertNil(probe.settings["Release"]?["ACME_PROBE_LAYER"], "Release sets no target-level value")
        XCTAssertEqual(probe.settings["Debug"]?["OTHER_SWIFT_FLAGS"]?.raw, "-DTARGET_SETTINGS_ONLY")
        XCTAssertNil(probe.settings["Release"]?["OTHER_SWIFT_FLAGS"])
        XCTAssertFalse(model.notes.contains { $0.contains("missing.xcconfig") }, "#include? of a missing file is silent")

        let projectFile = try XCConfigFile.load(url: try XCTUnwrap(project.projectXCConfig["Debug"]))
        XCTAssertEqual(projectFile.includes.map(\.lastPathComponent), ["base.xcconfig"])
        XCTAssertEqual(projectFile.optionalIncludes, [])
        XCTAssertEqual(projectFile.missingIncludes.map(\.path), [config.appendingPathComponent("missing.xcconfig").path])
        XCTAssertEqual(projectFile.settings["ACME_PROBE_SDK"],
                       SettingValue(raw: "any", conditions: ["sdk=iphonesimulator*": "simulator"]))
        XCTAssertNil(projectFile.settings["ACME_PROBE_BASE"], "includes are listed, not merged")
        XCTAssertEqual(projectFile.resolved(key: "ACME_PROBE_BASE")?.raw, "base")
        XCTAssertEqual(projectFile.resolved(key: "ACME_PROBE_INCLUDE_ORDER")?.raw, "project-xcconfig",
                       "assigned after the include, so it beats base.xcconfig")
        XCTAssertEqual(projectFile.resolved(key: "SWIFT_ACTIVE_COMPILATION_CONDITIONS")?.raw,
                       "$(inherited) FROM_PROJECT_XCCONFIG")
        XCTAssertNil(projectFile.resolved(key: "ACME_PROBE_TARGET_XCCONFIG"))
        let targetFile = try XCConfigFile.load(url: try XCTUnwrap(probe.xcconfig["Debug"]))
        XCTAssertEqual(targetFile.settings["GCC_PREPROCESSOR_DEFINITIONS"]?.raw, "TARGET_XCCONFIG=1")
        XCTAssertEqual(targetFile.settings["PRODUCT_NAME"]?.raw, "ProbeFromTargetXCConfig")
        XCTAssertEqual(targetFile.includes + targetFile.missingIncludes, [])
    }

    func testPodsLikeManagersAndPodfileFacts() throws {
        let model = try load("PodsLike/PodsLike.xcodeproj")
        let dir = root.appendingPathComponent("PodsLike")
        XCTAssertEqual(model.dependencyManagers.map(\.name), ["cocoapods", "carthage"])
        guard case let .cocoapods(podfile, lockfile, podCount) = model.dependencyManagers[0] else { return XCTFail() }
        XCTAssertEqual(podfile.path, dir.appendingPathComponent("Podfile").path)
        XCTAssertEqual(lockfile?.path, dir.appendingPathComponent("Podfile.lock").path)
        XCTAssertEqual(podCount, 3)
        guard case let .carthage(cartfile) = model.dependencyManagers[1] else { return XCTFail() }
        XCTAssertEqual(cartfile.lastPathComponent, "Cartfile")
        XCTAssertEqual(scripts(try target(model, "PodsLike")).map(\.name),
                       ["[CP] Check Pods Manifest.lock", "[CP] Embed Pods Frameworks"])
        XCTAssertTrue(model.notes.contains { $0.contains("CocoaPods-managed") }, "\(model.notes)")

        let facts = try XCTUnwrap(ManifestReaders.podfile(dir.appendingPathComponent("Podfile")))
        XCTAssertEqual(facts.pods, ["Alamofire", "Kingfisher", "SnapKit"])
        XCTAssertTrue(facts.useFrameworks)
        XCTAssertEqual(facts.postInstallSettings, ["EXCLUDED_ARCHS[sdk=iphonesimulator*]": "arm64", "ENABLE_BITCODE": "YES"])
        let body = try XCTUnwrap(facts.postInstall)
        XCTAssertTrue(body.contains("build_configurations.each"))
        XCTAssertFalse(body.contains("post_install"))
        XCTAssertEqual(body.split(separator: "\n").count, 6, body)
        XCTAssertEqual(ManifestReaders.cartfile(dir.appendingPathComponent("Cartfile"))?.entries,
                       [#"github "ReactiveX/RxSwift" ~> 6.6"#, #"github "realm/SwiftLint" == 0.54.0"#])
    }

    func testGeneratorDetection() throws {
        let xcodegen = try load("GenXcodeGen/AcmeGen.xcodeproj")
        XCTAssertEqual(xcodegen.generator, .xcodegen(spec: root.appendingPathComponent("GenXcodeGen/project.yml")))
        let tuist = try load("GenTuist/AcmeTuist.xcodeproj")
        XCTAssertEqual(tuist.generator, .tuist(manifest: root.appendingPathComponent("GenTuist/Project.swift")))
        XCTAssertEqual(tuist.generator?.name, "tuist")
        XCTAssertEqual(tuist.projects.first?.defaultConfiguration, "Debug", "no scheme: Debug when present")
    }

    // MARK: - Workspace and package containers

    func testWorkspaceSkipsPodsAndNotesMissingProjects() throws {
        let model = try load("AcmeWorkspace/Acme.xcworkspace")
        guard case let .xcworkspace(url) = model.container else { return XCTFail("\(model.container)") }
        XCTAssertEqual(url.lastPathComponent, "Acme.xcworkspace")
        XCTAssertEqual(model.root.path, root.appendingPathComponent("AcmeWorkspace").path)
        XCTAssertEqual(model.projects.map(\.name), ["AcmeApp"])
        XCTAssertEqual(model.format, .pbxproj(objectVersion: 77))
        XCTAssertEqual(model.allTargets.count, 4)
        XCTAssertTrue(model.notes.contains { $0.contains("Pods.xcodeproj is CocoaPods-generated") }, "\(model.notes)")
        XCTAssertTrue(model.notes.contains { $0.contains("Gone.xcodeproj, which does not exist") }, "\(model.notes)")
        XCTAssertEqual(model.dependencyManagers, [
            .cocoapods(podfile: root.appendingPathComponent("AcmeWorkspace/Podfile"), lockfile: nil, podCount: nil),
            .spm,
        ])
        XCTAssertEqual(model.packages.count, 3)
        XCTAssertEqual(model.packages[2].path?.path, root.appendingPathComponent("AcmeApp/Packages/AcmeShared").path)
        XCTAssertNotNil(model.packages[2].manifest)
        XCTAssertEqual(model.schemes.map(\.name), ["Acme"])
        XCTAssertEqual(model.projects.first?.defaultConfiguration, "Debug")
    }

    func testPackageContainerFromFolderAndManifest() throws {
        for path in ["AcmeApp/Packages/AcmeShared", "AcmeApp/Packages/AcmeShared/Package.swift"] {
            let model = try load(path)
            let dir = root.appendingPathComponent("AcmeApp/Packages/AcmeShared")
            guard case let .package(manifest) = model.container else { return XCTFail("\(model.container)") }
            XCTAssertEqual(manifest.path, dir.appendingPathComponent("Package.swift").path, path)
            XCTAssertEqual(model.format, .package)
            XCTAssertEqual(model.root.path, dir.path)
            XCTAssertEqual(model.projects, [])
            XCTAssertEqual(model.dependencyManagers, [.spm])
            XCTAssertNil(model.generator)
            XCTAssertEqual(model.packages.count, 1)
            XCTAssertEqual(model.packages[0].requirement, .local)
            XCTAssertEqual(model.packages[0].manifest?.targets.map(\.type), ["regular", "plugin"])
            XCTAssertEqual(model.packages[0].manifest?.dependencies.first?.url, "https://github.com/apple/swift-syntax")
        }
    }

    func testLoadErrors() throws {
        XCTAssertThrowsError(try ProjectModel.load(container: URL(fileURLWithPath: "/nonexistent-\(UUID())"), scheme: nil)) {
            guard case XcblameError.projectNotFound = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try load("Precedence/EXPECTED.md")) {
            guard case XcblameError.projectNotFound = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try XCConfigFile.load(url: root.appendingPathComponent("Precedence/Config/missing.xcconfig"))) {
            guard case XcblameError.projectUnreadable = $0 else { return XCTFail("\($0)") }
        }
    }
}
