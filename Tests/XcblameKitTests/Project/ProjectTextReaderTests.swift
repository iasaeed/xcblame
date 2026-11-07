import XCTest
@testable import XcblameKit

/// The text readers on synthetic input: xcconfig lines and include order, Package.swift shapes, Podfile blocks.
final class ProjectTextReaderTests: XCTestCase {
    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testXCConfigLineSyntax() {
        let url = URL(fileURLWithPath: "/tmp/x/a.xcconfig")
        let parsed = XCConfigReader.parse(text: """
            // header comment
            A = 1
            B = https://example.com // Xcode ends the value at the first //
            C = value;
              D[sdk=iphonesimulator*][arch=arm64] = sim-arm
            D[config=Debug] = dbg
            E[sdk=macosx*] = only-conditional
            A = 2
            not a setting
            1BAD = x
            F =
            #include? <system.xcconfig>
            """, url: url)
        let s = parsed.file.settings
        XCTAssertEqual(s["A"], SettingValue(raw: "2"), "later lines win")
        XCTAssertEqual(s["B"]?.raw, "https:")
        XCTAssertEqual(s["C"]?.raw, "value")
        XCTAssertEqual(s["D"], SettingValue(raw: nil, conditions: ["sdk=iphonesimulator*][arch=arm64": "sim-arm",
                                                                   "config=Debug": "dbg"]))
        XCTAssertEqual(s["E"], SettingValue(raw: nil, conditions: ["sdk=macosx*": "only-conditional"]))
        XCTAssertEqual(s["F"], SettingValue(raw: ""))
        XCTAssertNil(s["1BAD"])
        XCTAssertEqual(Set(s.keys), ["A", "B", "C", "D", "E", "F"])
        XCTAssertEqual(parsed.unresolvedIncludes, ["<system.xcconfig>"])
        XCTAssertFalse(parsed.hasContinuation)
        XCTAssertEqual(XCConfigReader.splitConditionalKey("K [ sdk=a ] [arch=b]")?.condition, "sdk=a][arch=b")
    }

    func testPBXProjBuildSettingsConditionsAndArrays() {
        let settings = PBXProjReader.settings([
            "EXCLUDED_ARCHS[sdk=iphonesimulator*]": "arm64", "EXCLUDED_ARCHS": "", "ONLY[arch=x86_64]": "1",
            "HEADER_SEARCH_PATHS": ["$(inherited)", "$(SRCROOT)/My Headers", "plain"],
        ])
        XCTAssertEqual(settings["EXCLUDED_ARCHS"], SettingValue(raw: "", conditions: ["sdk=iphonesimulator*": "arm64"]))
        XCTAssertEqual(settings["ONLY"], SettingValue(raw: nil, conditions: ["arch=x86_64": "1"]))
        XCTAssertEqual(settings["HEADER_SEARCH_PATHS"]?.raw, #"$(inherited) "$(SRCROOT)/My Headers" plain"#)
    }

    func testXCConfigIncludesReplayInPlaceAndStopOnCycles() throws {
        let dir = try scratch()
        try "X = from-a\nY = from-a\n#include \"b.xcconfig\"\n".write(to: dir.appendingPathComponent("a.xcconfig"),
                                                                      atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "#include \"sub/c.xcconfig\"\nY = from-b\n#include? \"nope.xcconfig\"\n"
            .write(to: dir.appendingPathComponent("b.xcconfig"), atomically: true, encoding: .utf8)
        try "#include \"../a.xcconfig\"\nX = from-c\nZ[sdk=iphoneos*] = c\n"
            .write(to: dir.appendingPathComponent("sub/c.xcconfig"), atomically: true, encoding: .utf8)
        let a = try XCConfigFile.load(url: dir.appendingPathComponent("a.xcconfig"))
        XCTAssertEqual(a.includes.map(\.lastPathComponent), ["b.xcconfig"])
        XCTAssertEqual(a.settings["X"]?.raw, "from-a")
        // The include comes after X and Y, so the included chain wins: c sets X, b sets Y after including c.
        XCTAssertEqual(a.resolved(key: "X")?.raw, "from-c")
        XCTAssertEqual(a.resolved(key: "Y")?.raw, "from-b")
        XCTAssertEqual(a.resolved(key: "Z"), SettingValue(raw: nil, conditions: ["sdk=iphoneos*": "c"]))
        XCTAssertNil(a.resolved(key: "W"))
        let b = try XCConfigFile.load(url: dir.appendingPathComponent("b.xcconfig"))
        XCTAssertEqual(b.includes.map(\.path), [dir.appendingPathComponent("sub/c.xcconfig").standardizedFileURL.path])
        XCTAssertEqual(b.missingIncludes.map(\.lastPathComponent), ["nope.xcconfig"])
        XCTAssertEqual(b.optionalIncludes, [])
        // A file that is gone falls back to its parsed settings.
        let detached = XCConfigFile(url: dir.appendingPathComponent("gone.xcconfig"), settings: ["K": SettingValue(raw: "v")])
        XCTAssertEqual(detached.resolved(key: "K")?.raw, "v")
    }

    func testPackageManifestShapes() {
        let url = URL(fileURLWithPath: "/repo/Pkg/Package.swift")
        let parsed = ManifestReaders.package(text: #"""
            // swift-tools-version: 5.9
            import PackageDescription
            import CompilerPluginSupport

            /* .target(name: "Commented") */
            let package = Package(
                name: "Pkg",
                products: [.library(name: "PkgLib", targets: ["Core"]), .plugin(name: "Gen", targets: ["Gen"])],
                dependencies: [
                    .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
                    .package(url: "https://github.com/a/minor", .upToNextMinor(from: "1.2.0")),
                    .package(url: "https://github.com/a/ranged", "1.0.0"..<"2.0.0"),
                    .package(url: "https://github.com/a/rev", revision: "abc123"),
                    .package(url: "https://github.com/a/branchy", branch: "develop"),
                    .package(name: "Renamed", url: "https://github.com/a/other", exact: "3.0.0"),
                    .package(path: "../Local"),
                    someHelper(),
                ],
                targets: [
                    .macro(name: "PkgMacros", dependencies: [
                        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                    ]),
                    .target(name: "Core", dependencies: ["PkgMacros", .target(name: "Util"),
                                                         .product(name: "SwiftParser", package: "swift-syntax"),
                                                         .product(name: "Other", package: "Renamed")],
                            plugins: [.plugin(name: "Lint", package: "lint"), "Gen"]),
                    .target(name: "Util", path: "Sources/Util, with comma"),
                    .executableTarget(name: "cli", dependencies: ["Core"]),
                    .testTarget(name: "CoreTests", dependencies: ["Core"]),
                    .plugin(name: "Gen", capability: .buildTool(), dependencies: []),
                    .binaryTarget(name: "Blob", path: "Blob.xcframework"),
                    .systemLibrary(name: "CSQL"),
                ]
            )
            """#, manifest: url)
        let m = parsed.manifest
        XCTAssertEqual(m.name, "Pkg")
        XCTAssertEqual(parsed.products, ["PkgLib", "Gen"])
        XCTAssertEqual(m.targets.map(\.name), ["PkgMacros", "Core", "Util", "cli", "CoreTests", "Gen", "Blob", "CSQL"])
        XCTAssertEqual(m.targets.map(\.type), ["macro", "regular", "regular", "executable", "test", "plugin", "binary",
                                               "system"])
        XCTAssertEqual(m.targets[1].dependencies, ["PkgMacros", "Util", "SwiftParser", "Other"])
        XCTAssertEqual(m.targets[1].plugins, ["Lint", "Gen"])
        XCTAssertEqual(m.dependencies.map(\.requirement), [
            .upToNextMajor("600.0.0"), .upToNextMinor("1.2.0"), .range(from: "1.0.0", to: "2.0.0"), .revision("abc123"),
            .branch("develop"), .exact("3.0.0"), .local,
        ])
        XCTAssertEqual(m.dependencies[6].path?.path, "/repo/Local")
        XCTAssertNil(m.dependencies[6].url)
        let syntax = m.dependencies[0]
        XCTAssertEqual(syntax.url, "https://github.com/swiftlang/swift-syntax.git")
        XCTAssertEqual(syntax.products, ["SwiftSyntaxMacros", "SwiftCompilerPlugin", "SwiftParser"])
        XCTAssertEqual(syntax.consumers, ["PkgMacros", "Core"])
        XCTAssertEqual(m.dependencies[5].consumers, ["Core"], "matched by name:")
        XCTAssertEqual(parsed.notes.count, 1, "\(parsed.notes)")
        XCTAssertTrue(parsed.notes[0].contains("dependency not understood: someHelper()"))

        let opaque = ManifestReaders.package(text: "let package = makePackage()", manifest: url)
        XCTAssertNil(opaque.manifest.name)
        XCTAssertEqual(opaque.manifest.targets, [])
        XCTAssertTrue(opaque.notes[0].contains("no literal Package(...) call"))
    }

    func testPodfileBlocksAndLockfile() throws {
        let dir = try scratch()
        try """
            use_frameworks! :linkage => :static
            target 'App' do
              pod 'A' # trailing comment with 'quotes'
              pod "B/Sub", :git => 'https://example.com/b.git'
            end
            post_install do |installer|
              installer.pods_project.targets.each do |t|
                if t.name == 'A'
                  t.build_configurations.each { |c| c.build_settings["SWIFT_VERSION"] = "5.0" }
                end
              end
            end
            # pod 'Commented'
            """.write(to: dir.appendingPathComponent("Podfile"), atomically: true, encoding: .utf8)
        let facts = try XCTUnwrap(ManifestReaders.podfile(dir.appendingPathComponent("Podfile")))
        XCTAssertEqual(facts.pods, ["A", "B/Sub"])
        XCTAssertTrue(facts.useFrameworks)
        XCTAssertEqual(facts.postInstallSettings, ["SWIFT_VERSION": "5.0"])
        XCTAssertEqual(facts.postInstall?.split(separator: "\n").count, 5)
        XCTAssertNil(ManifestReaders.podfile(dir.appendingPathComponent("Nope")))

        try "PODS:\n  - A (1.0)\n  - \"B/Sub (2.0)\":\n    - A\n\nDEPENDENCIES:\n  - A\n"
            .write(to: dir.appendingPathComponent("Podfile.lock"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ManifestReaders.podCount(lockfile: dir.appendingPathComponent("Podfile.lock")), 2)
        try "COCOAPODS: 1.15.2\n".write(to: dir.appendingPathComponent("Other.lock"), atomically: true, encoding: .utf8)
        XCTAssertNil(ManifestReaders.podCount(lockfile: dir.appendingPathComponent("Other.lock")))
    }
}
