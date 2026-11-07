import CryptoKit
import Foundation
import XCTest
@testable import XcblameKit

/// Hand-built `ProjectModel`s (Lane A's reader is not in this lane) and the zero-writes tree hash.
enum SettingsFixtures {
    static let projects = FixtureProjectTests.root
    static let precedence = projects.appendingPathComponent("Precedence")
    static let acme = projects.appendingPathComponent("AcmeApp")
    /// Warm DerivedData for the timing tests lives under `.build` (gitignored), outside every fixture.
    static let persistentCache = projects.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent(".build/settings-test-cache")

    /// The oracle's cache home for the whole test run (`XCBLAME_CACHE_DIR`), under `.build`, never ~/Library/Caches.
    static let cacheHome: URL = {
        let url = persistentCache.appendingPathComponent("oracle-home")
        setenv("XCBLAME_CACHE_DIR", url.path, 1)
        return url
    }()

    /// Call before any oracle run with a cache folder.
    static func isolateCacheHome() { _ = cacheHome }

    static func v(_ raw: String) -> SettingValue { SettingValue(raw: raw) }

    /// `fixtures/projects/Precedence` as written in its pbxproj (or a copy of it at `root`).
    static func precedenceModel(root: URL = precedence) -> ProjectModel {
        let xcodeproj = root.appendingPathComponent("Precedence.xcodeproj")
        let config = root.appendingPathComponent("Config")
        let common: [String: SettingValue] = [
            "ACME_PROBE_LAYER": v("project-settings"), "ACME_PROBE_PROJECT_SETTINGS": v("project-settings"),
            "IPHONEOS_DEPLOYMENT_TARGET": v("17.0"), "OTHER_SWIFT_FLAGS": v("$(inherited) -DPROJECT_SETTINGS"),
            "SDKROOT": v("iphoneos"), "SWIFT_VERSION": v("5.0"),
        ]
        let projectDebug = common.merging([
            "DEBUG_INFORMATION_FORMAT": v("dwarf"), "ONLY_ACTIVE_ARCH": v("YES"),
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": v("$(inherited) DEBUG FROM_PROJECT_SETTINGS"),
            "SWIFT_OPTIMIZATION_LEVEL": v("-Onone"),
        ]) { $1 }
        let projectRelease = common.merging([
            "DEBUG_INFORMATION_FORMAT": v("dwarf-with-dsym"),
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": v("$(inherited) FROM_PROJECT_SETTINGS"),
            "SWIFT_COMPILATION_MODE": v("wholemodule"),
        ]) { $1 }
        let targetCommon: [String: SettingValue] = [
            "ACME_PROBE_TARGET_SETTINGS": v("target-settings"), "CODE_SIGN_STYLE": v("Automatic"),
            "GENERATE_INFOPLIST_FILE": v("YES"), "PRODUCT_BUNDLE_IDENTIFIER": v("com.example.acme.probe"),
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": v("$(inherited) FROM_TARGET_SETTINGS"),
        ]
        let targetDebug = targetCommon.merging([
            "ACME_PROBE_LAYER": v("target-settings"), "OTHER_SWIFT_FLAGS": v("-DTARGET_SETTINGS_ONLY"),
        ]) { $1 }
        let probe = ProjectModel.Target(
            id: "CA0000000000000000000030", name: "Probe", productType: "com.apple.product-type.application",
            hasSwiftSources: true, settings: ["Debug": targetDebug, "Release": targetCommon],
            xcconfig: ["Debug": config.appendingPathComponent("target.xcconfig"),
                       "Release": config.appendingPathComponent("target.xcconfig")])
        let project = ProjectModel.Project(
            path: xcodeproj, name: "Precedence", objectVersion: 77, configurations: ["Debug", "Release"],
            defaultConfiguration: "Release", projectSettings: ["Debug": projectDebug, "Release": projectRelease],
            projectXCConfig: ["Debug": config.appendingPathComponent("project.xcconfig"),
                              "Release": config.appendingPathComponent("project.xcconfig")],
            targets: [probe])
        let scheme = ProjectModel.Scheme(name: "Probe",
                                         path: xcodeproj.appendingPathComponent("xcshareddata/xcschemes/Probe.xcscheme"),
                                         parallelizeBuildables: nil, buildImplicitDependencies: nil, isShared: true)
        return ProjectModel(root: root, container: .xcodeproj(xcodeproj), format: .pbxproj(objectVersion: 77),
                            projects: [project], schemes: [scheme])
    }

    /// AcmeApp: targets and packages only (enough for the oracle; settings come from xcodebuild).
    static func acmeModel() -> ProjectModel {
        let xcodeproj = acme.appendingPathComponent("AcmeApp.xcodeproj")
        var model = model(xcodeproj: xcodeproj)
        let shared = acme.appendingPathComponent("Packages/AcmeShared")
        let manifest = ProjectModel.PackageManifest(name: "AcmeShared", targets: [
            .init(name: "AcmeShared", type: "regular", dependencies: ["SwiftSyntax"], plugins: ["AcmeGen"]),
            .init(name: "AcmeGen", type: "plugin"),
        ])
        model.packages = [
            .init(url: "https://github.com/apple/swift-argument-parser", path: nil, requirement: .branch("main")),
            .init(url: "https://github.com/apple/swift-collections", path: nil, requirement: .exact("1.1.4")),
            .init(url: nil, path: shared, requirement: .local, products: ["AcmeShared"], consumers: ["Acme"],
                  manifest: manifest),
        ]
        model.dependencyManagers = [.spm]
        return model
    }

    /// Minimal pbxproj scan for tests (native and aggregate targets, project configuration names); no settings.
    static func model(xcodeproj: URL) -> ProjectModel {
        let text = (try? String(contentsOf: xcodeproj.appendingPathComponent("project.pbxproj"), encoding: .utf8)) ?? ""
        let targets = captures(#"([0-9A-F]{24}) /\* ([^*]+?) \*/ = \{\s*isa = PBX(?:Native|Aggregate|Legacy)Target;"#, text)
            .map { ProjectModel.Target(id: $0[0], name: $0[1], productType: "") }
        var configurations: [String] = []
        for c in captures(#"isa = XCBuildConfiguration;[^}]*?\};\s*name = ("?)([^";]+)\1;"#, text).map({ $0[1] })
            where !configurations.contains(c) {
            configurations.append(c)
        }
        let project = ProjectModel.Project(path: xcodeproj, name: xcodeproj.deletingPathExtension().lastPathComponent,
                                           objectVersion: nil, configurations: configurations, targets: targets)
        return ProjectModel(root: xcodeproj.deletingLastPathComponent(), container: .xcodeproj(xcodeproj),
                            format: .pbxproj(objectVersion: 0), projects: [project])
    }

    static func captures(_ pattern: String, _ text: String) -> [[String]] {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }

    /// Paths, sizes and nanosecond mtimes of everything under `dir` (folders included).
    static func treeHash(_ dir: URL) -> String {
        var lines: [String] = []
        let base = dir.standardizedFileURL.resolvingSymlinksInPath().path
        let all = [base] + (FileManager.default.subpaths(atPath: base) ?? []).map { base + "/" + $0 }
        for path in all {
            var info = stat()
            guard lstat(path, &info) == 0 else { continue }
            lines.append("\(path.dropFirst(base.count)) \(info.st_size) \(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)")
        }
        return SHA256.hash(data: Data(lines.sorted().joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func xcodebuildAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/xcodebuild") && runProbe(["xcodebuild", "-version"], timeout: 10) != nil
    }

    static func scratch(_ name: String, _ test: XCTestCase) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-\(name)-\(UUID().uuidString)")
        test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
