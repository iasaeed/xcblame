import XCTest
@testable import XcblameKit

/// Provenance and the offline resolver against `fixtures/projects/Precedence/EXPECTED.md` (no xcodebuild needed).
final class SettingsProvenanceTests: XCTestCase {
    typealias Row = (key: String, value: String, level: Provenance.Level, file: String, inherited: Bool)
    static let pbxproj = "Precedence.xcodeproj/project.pbxproj"

    /// EXPECTED.md, Debug (sdk iphoneos).
    static let debug: [Row] = [
        ("ACME_PROBE_BASE", "base", .projectXCConfig, "Config/base.xcconfig", false),
        ("ACME_PROBE_PROJECT_XCCONFIG", "project-xcconfig", .projectXCConfig, "Config/project.xcconfig", false),
        ("ACME_PROBE_INCLUDE_ORDER", "project-xcconfig", .projectXCConfig, "Config/project.xcconfig", false),
        ("ACME_PROBE_PROJECT_SETTINGS", "project-settings", .projectSettings, pbxproj, false),
        ("ACME_PROBE_TARGET_XCCONFIG", "target-xcconfig", .targetXCConfig, "Config/target.xcconfig", false),
        ("ACME_PROBE_TARGET_SETTINGS", "target-settings", .targetSettings, pbxproj, false),
        ("ACME_PROBE_LAYER", "target-settings", .targetSettings, pbxproj, false),
        ("ACME_PROBE_SDK", "any", .projectXCConfig, "Config/project.xcconfig", false),
        ("SWIFT_ACTIVE_COMPILATION_CONDITIONS",
         " FROM_PROJECT_XCCONFIG DEBUG FROM_PROJECT_SETTINGS FROM_TARGET_XCCONFIG FROM_TARGET_SETTINGS",
         .targetSettings, pbxproj, true),
        ("OTHER_SWIFT_FLAGS", "-DTARGET_SETTINGS_ONLY", .targetSettings, pbxproj, false),
        ("GCC_PREPROCESSOR_DEFINITIONS", "TARGET_XCCONFIG=1", .targetXCConfig, "Config/target.xcconfig", false),
        ("PRODUCT_NAME", "ProbeFromTargetXCConfig", .targetXCConfig, "Config/target.xcconfig", false),
    ]

    /// EXPECTED.md, Release: Debug with three rows replaced.
    static let release: [Row] = debug.map { row in
        switch row.key {
        case "ACME_PROBE_LAYER": return ("ACME_PROBE_LAYER", "target-xcconfig", .targetXCConfig, "Config/target.xcconfig", false)
        case "SWIFT_ACTIVE_COMPILATION_CONDITIONS":
            return (row.key, " FROM_PROJECT_XCCONFIG FROM_PROJECT_SETTINGS FROM_TARGET_XCCONFIG FROM_TARGET_SETTINGS",
                    .targetSettings, pbxproj, true)
        case "OTHER_SWIFT_FLAGS":
            return (row.key, " -DPROJECT_XCCONFIG -DPROJECT_SETTINGS -DTARGET_XCCONFIG", .targetXCConfig,
                    "Config/target.xcconfig", true)
        default: return row
        }
    }

    static let rows: [(configuration: String, rows: [Row])] = [("Debug", debug), ("Release", release)]

    func testProvenanceMatchesExpectedForEveryKey() {
        let model = SettingsFixtures.precedenceModel()
        for (configuration, rows) in Self.rows {
            for row in rows {
                let p = SettingsOracle.provenance(project: model, target: "Probe", key: row.key, configuration: configuration)
                let label = "\(configuration) \(row.key)"
                XCTAssertEqual(p.level, row.level, label)
                XCTAssertEqual(p.file, row.file, label)
                XCTAssertEqual(p.inherited, row.inherited, label)
                XCTAssertNotNil(p.rawValue, label)
            }
        }
    }

    func testOfflineResolverMatchesExpectedValues() {
        let model = SettingsFixtures.precedenceModel()
        for (configuration, rows) in Self.rows {
            let settings = try! SettingsOracle.effective(project: model, configuration: configuration, scheme: nil,
                                                         offline: true, cacheDir: nil)
            XCTAssertEqual(settings.source, .offlineResolver)
            XCTAssertEqual(settings.configuration, configuration)
            let probe = settings.targets["Probe"] ?? [:]
            for row in rows {
                XCTAssertEqual(probe[row.key], row.value, "\(configuration) \(row.key)")
            }
        }
    }

    func testConditionalKeyPerSDK() {
        let model = SettingsFixtures.precedenceModel()
        let simulator = ["SDK_NAME": "iphonesimulator26.0", "ARCHS": "arm64"]
        for configuration in ["Debug", "Release"] {
            let p = SettingsOracle.provenance(project: model, target: "Probe", key: "ACME_PROBE_SDK",
                                              configuration: configuration, commandLineOverrides: [:],
                                              effective: simulator)
            XCTAssertEqual(p, Provenance(level: .projectXCConfig, file: "Config/project.xcconfig", rawValue: "simulator"))
            // From the SDKROOT path when SDK_NAME is absent; device SDK keeps the unconditional value.
            let device = SettingsOracle.provenance(
                project: model, target: "Probe", key: "ACME_PROBE_SDK", configuration: configuration,
                commandLineOverrides: [:],
                effective: ["SDKROOT": "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS26.0.sdk"])
            XCTAssertEqual(device.rawValue, "any")

            var resolver = ProvenanceResolver(project: model)
            let values = OfflineResolver.resolve(&resolver, target: "Probe", configuration: configuration,
                                                 effective: simulator).values
            XCTAssertEqual(values["ACME_PROBE_SDK"], "simulator")
        }
        // The chain keeps both assignments of the same file for the simulator.
        let chain = SettingsOracle.provenanceChain(project: model, target: "Probe", key: "ACME_PROBE_SDK",
                                                   configuration: "Debug", effective: simulator)
        XCTAssertEqual(chain.map(\.rawValue), ["any", "simulator"])
    }

    func testChainOrderAndIncludeOrder() {
        let model = SettingsFixtures.precedenceModel()
        let chain = SettingsOracle.provenanceChain(project: model, target: "Probe", key: "ACME_PROBE_LAYER",
                                                   configuration: "Debug")
        XCTAssertEqual(chain.map(\.level), [.projectXCConfig, .projectXCConfig, .projectSettings, .targetXCConfig,
                                            .targetSettings])
        XCTAssertEqual(chain.first?.file, "Config/base.xcconfig")
        let include = SettingsOracle.provenanceChain(project: model, target: "Probe", key: "ACME_PROBE_INCLUDE_ORDER",
                                                     configuration: "Debug")
        XCTAssertEqual(include.map(\.file), ["Config/base.xcconfig", "Config/project.xcconfig"])
    }

    func testPlatformDefaultUnknownTargetAndCommandLine() {
        let model = SettingsFixtures.precedenceModel()
        XCTAssertEqual(SettingsOracle.provenance(project: model, target: "Probe", key: "ACME_NOT_SET", configuration: "Debug"),
                       Provenance(level: .platformDefault))
        XCTAssertEqual(SettingsOracle.provenance(project: model, target: "Nope", key: "PRODUCT_NAME", configuration: "Debug").level,
                       .unknown)
        // EXPECTED.md command-line observation: ACME_PROBE_LAYER=command-line OTHER_SWIFT_FLAGS=-DCLI.
        let cli = ["ACME_PROBE_LAYER": "command-line", "OTHER_SWIFT_FLAGS": "-DCLI"]
        for key in cli.keys {
            let p = SettingsOracle.provenance(project: model, target: "Probe", key: key, configuration: "Debug",
                                              commandLineOverrides: cli)
            XCTAssertEqual(p, Provenance(level: .commandLine, file: nil, rawValue: cli[key]))
        }
    }

    func testMissingOptionalIncludeIsRecorded() {
        let config = SettingsFixtures.precedence.appendingPathComponent("Config")
        let chain = XCConfigChain.load(config.appendingPathComponent("project.xcconfig"))
        XCTAssertEqual(chain.files.map(\.lastPathComponent), ["project.xcconfig", "base.xcconfig"])
        XCTAssertEqual(chain.missing.map(\.url.lastPathComponent), ["missing.xcconfig"])
        XCTAssertEqual(chain.missing.map(\.optional), [true])
        // Creating the missing include must invalidate cached settings, so it is a cache input.
        let inputs = SettingsCache.inputs(project: SettingsFixtures.precedenceModel()).map(\.lastPathComponent)
        XCTAssertTrue(inputs.contains("missing.xcconfig"))
        XCTAssertTrue(inputs.contains("Probe.xcscheme"))
        XCTAssertTrue(inputs.contains("project.pbxproj"))
    }

    func testIsShadowed() {
        let model = SettingsFixtures.precedenceModel()
        func shadow(_ key: String, _ configuration: String, _ level: Provenance.Level,
                    _ cli: [String: String] = [:]) -> Provenance? {
            SettingsOracle.isShadowed(project: model, target: "Probe", key: key, configuration: configuration,
                                      byLevelAbove: level, commandLineOverrides: cli)
        }
        // Target settings drop every lower level without $(inherited).
        XCTAssertEqual(shadow("OTHER_SWIFT_FLAGS", "Debug", .projectXCConfig),
                       Provenance(level: .targetSettings, file: Self.pbxproj, rawValue: "-DTARGET_SETTINGS_ONLY"))
        // Release: every level above inherits, so an overlay in the project xcconfig reaches the value.
        XCTAssertNil(shadow("OTHER_SWIFT_FLAGS", "Release", .projectXCConfig))
        XCTAssertNil(shadow("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "Debug", .projectXCConfig))
        XCTAssertEqual(shadow("GCC_PREPROCESSOR_DEFINITIONS", "Debug", .projectSettings)?.level, .targetXCConfig)
        XCTAssertNil(shadow("GCC_PREPROCESSOR_DEFINITIONS", "Debug", .targetXCConfig))
        // The highest shadowing assignment is returned.
        XCTAssertEqual(shadow("ACME_PROBE_LAYER", "Debug", .projectXCConfig)?.level, .targetSettings)
        XCTAssertEqual(shadow("ACME_PROBE_LAYER", "Release", .projectXCConfig)?.level, .targetXCConfig)
        XCTAssertNil(shadow("ACME_PROBE_LAYER", "Debug", .targetSettings))
        XCTAssertEqual(shadow("ACME_PROBE_LAYER", "Debug", .targetSettings, ["ACME_PROBE_LAYER": "x"])?.level, .commandLine)
        XCTAssertNil(shadow("ACME_NOT_SET", "Debug", .platformDefault))
        XCTAssertNil(SettingsOracle.isShadowed(project: model, target: "Nope", key: "PRODUCT_NAME", configuration: "Debug",
                                               byLevelAbove: .projectXCConfig))
    }

    func testOfflineExpansionAndUnknownReferences() {
        var model = SettingsFixtures.precedenceModel()
        model.projects[0].targets[0].settings["Debug"]?["ACME_REF"] = SettingsFixtures.v("$(PRODUCT_NAME)-$(TARGET_NAME)")
        model.projects[0].targets[0].settings["Debug"]?["ACME_UNKNOWN"] = SettingsFixtures.v("$(BUILT_PRODUCTS_DIR)/x ${ACME_REF}")
        model.projects[0].targets[0].settings["Debug"]?["ACME_CYCLE"] = SettingsFixtures.v("$(ACME_CYCLE) $(ACME_MOD:lower)")
        let settings = OfflineResolver.resolve(project: model, configuration: "Debug")
        let probe = settings.targets["Probe"]!
        XCTAssertEqual(probe["ACME_REF"], "ProbeFromTargetXCConfig-Probe")
        XCTAssertEqual(probe["ACME_UNKNOWN"], "$(BUILT_PRODUCTS_DIR)/x ProbeFromTargetXCConfig-Probe")
        XCTAssertNotNil(probe["ACME_CYCLE"])
        XCTAssertNil(probe["TARGET_NAME"], "builtins are not emitted")
        XCTAssertTrue(settings.notes.contains { $0.contains("BUILT_PRODUCTS_DIR") }, "\(settings.notes)")
    }

    func testPackageTargetsFromManifest() {
        XCTAssertEqual(OfflineResolver.swiftVersion(manifest: "// swift-tools-version: 5.9\nlet p = 1"), "5")
        XCTAssertEqual(OfflineResolver.swiftVersion(manifest: "// swift-tools-version:6.0\n"), "6")
        XCTAssertEqual(OfflineResolver.swiftVersion(manifest: "// swift-tools-version: 6.0\nswiftLanguageModes: [.v5]"), "5")
        XCTAssertEqual(OfflineResolver.swiftVersion(manifest: "// swift-tools-version: 5.8\nswiftLanguageVersions: [.v4_2, .v5]"), "5")
        XCTAssertEqual(OfflineResolver.swiftVersion(manifest: #"swiftLanguageModes: [.version("6")]"#), "6")
        XCTAssertNil(OfflineResolver.swiftVersion(manifest: "no version"))

        let settings = OfflineResolver.resolve(project: SettingsFixtures.acmeModel(), configuration: "Debug")
        XCTAssertEqual(settings.targets["AcmeShared"], ["SWIFT_VERSION": "5"])
        XCTAssertNil(settings.targets["AcmeGen"], "plugins are not build targets")
        XCTAssertTrue(settings.notes.contains("package targets: offline resolver only (SWIFT_VERSION from the manifest; other settings unknown)"))
    }

    func testPackageContainerIsOfflineOnly() throws {
        let manifest = SettingsFixtures.acme.appendingPathComponent("Packages/AcmeShared/Package.swift")
        let model = ProjectModel(root: manifest.deletingLastPathComponent(), container: .package(manifest), format: .package)
        let settings = try SettingsOracle.effective(project: model, configuration: "Debug", scheme: nil, offline: false,
                                                    cacheDir: nil)
        XCTAssertEqual(settings.source, .offlineResolver)
        XCTAssertEqual(settings.notes.first, "package container: offline resolver only")
    }
}
