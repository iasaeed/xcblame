import XCTest
@testable import XcblameKit

/// The wrapper xcconfig of DESIGN §7.5 and its oracle check.
final class WrapperXCConfigTests: XCTestCase {
    private let state = URL(fileURLWithPath: "/repo/.xcblame")
    private let cwd = URL(fileURLWithPath: "/repo")

    func testIncludeOrderArgumentsAndEnvironment() throws {
        let plan = try WrapperXCConfig.plan(
            arguments: ["-scheme", "App", "-xcconfig", "Config/CI.xcconfig", "-configuration", "Release",
                        "-xcconfig", "/abs/Second.xcconfig", "build"],
            environment: ["XCODE_XCCONFIG_FILE": "/env/Global.xcconfig", "HOME": "/Users/x"],
            overlay: URL(fileURLWithPath: "/repo/.xcblame/overlay-Release.xcconfig"),
            lines: ["OTHER_SWIFT_FLAGS = $(inherited) -Xfrontend -debug-time-function-bodies // xcblame --deep",
                    "OTHER_CFLAGS = $(inherited) -ftime-trace"],
            xcblameDir: state, cwd: cwd)
        XCTAssertEqual(plan.url.path, "/repo/.xcblame/tmp/wrapper-Release.xcconfig")
        XCTAssertEqual(plan.arguments, ["-scheme", "App", "-configuration", "Release", "build",
                                        "-xcconfig", "/repo/.xcblame/tmp/wrapper-Release.xcconfig"])
        XCTAssertEqual(plan.unsetEnvironment, ["XCODE_XCCONFIG_FILE"])
        let lines = plan.contents.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines[0].hasPrefix("// "), "a header comment first")
        XCTAssertEqual(Array(lines.dropFirst()), [
            "#include \"/repo/Config/CI.xcconfig\"",
            "#include \"/abs/Second.xcconfig\"",
            "#include \"/env/Global.xcconfig\"",
            "#include \"/repo/.xcblame/overlay-Release.xcconfig\"",
            "OTHER_SWIFT_FLAGS = $(inherited) -Xfrontend -debug-time-function-bodies // xcblame --deep",
            "OTHER_CFLAGS = $(inherited) -ftime-trace // xcblame",
        ])
    }

    func testWithoutUserConfigurationOrEnvironment() throws {
        let plan = try WrapperXCConfig.plan(arguments: ["-scheme", "App"], environment: [:], overlay: nil,
                                            lines: ["A = $(inherited) b"], xcblameDir: state, cwd: cwd)
        XCTAssertEqual(plan.url.lastPathComponent, "wrapper-Default.xcconfig")
        XCTAssertTrue(plan.unsetEnvironment.isEmpty)
        XCTAssertFalse(plan.contents.contains("#include"))
        XCTAssertThrowsError(try WrapperXCConfig.plan(arguments: ["-xcconfig"], environment: [:], overlay: nil, lines: [],
                                                      xcblameDir: state, cwd: cwd))
    }

    /// Code review v0.5: a quote or `$(` in a path cannot be written into an xcconfig line (the parser expands `$(`):
    /// a usage error, never a wrapper that includes another file.
    func testPathsAnXCConfigCannotExpressAreRefused() throws {
        for path in ["/repo/We\"ird.xcconfig", "/repo/$(HOME)/A.xcconfig", "/repo/${X}.xcconfig"] {
            XCTAssertThrowsError(try WrapperXCConfig.plan(arguments: ["-xcconfig", path], environment: [:], overlay: nil,
                                                          lines: [], xcblameDir: state, cwd: cwd), path) { error in
                XCTAssertTrue("\(error)".contains("cannot be written into an xcconfig"), "\(error)")
            }
            XCTAssertThrowsError(try WrapperXCConfig.plan(arguments: [], environment: ["XCODE_XCCONFIG_FILE": path],
                                                          overlay: nil, lines: [], xcblameDir: state, cwd: cwd), path)
        }
        XCTAssertNoThrow(try WrapperXCConfig.plan(arguments: ["-xcconfig", "/repo/With Space $X.xcconfig"], environment: [:],
                                                  overlay: nil, lines: [], xcblameDir: state, cwd: cwd))
        XCTAssertThrowsError(try DeepFlags.plan(scope: [.swift], exactFiles: false, probe: try DeepFixtures.probe26(),
                                                statsDir: URL(fileURLWithPath: "/cache/$(SRCROOT)/stats")))
    }

    func testWriteCreatesTheTmpFolder() throws {
        let dir = try DeepFixtures.scratch(self)
        let plan = try WrapperXCConfig.plan(arguments: ["-configuration", "Debug"], environment: [:], overlay: nil,
                                            lines: ["A = $(inherited) b"], xcblameDir: dir, cwd: dir)
        try WrapperXCConfig.write(plan)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("tmp/wrapper-Debug.xcconfig"), encoding: .utf8),
                       plan.contents)
    }

    func testOracleCheckFindsShadowedKeysAndLostFlags() throws {
        let injected = ["OTHER_SWIFT_FLAGS": "-Xfrontend -stats-output-dir -Xfrontend \"/c/My Cache/stats\""]
        let before = EffectiveSettings(configuration: "Debug", targets: [
            "App": ["OTHER_SWIFT_FLAGS": "-DAPP"],
            "Kit": ["OTHER_SWIFT_FLAGS": "-DKIT -DSHARED"],
            "Pkg": [:],
        ], source: .xcodebuild)
        let after = EffectiveSettings(configuration: "Debug", targets: [
            // Kept and injected (quoted path with a space).
            "App": ["OTHER_SWIFT_FLAGS": "-DAPP -Xfrontend -stats-output-dir -Xfrontend \"/c/My Cache/stats\""],
            // Target-level value without $(inherited) won: shadowed; and -DSHARED was lost.
            "Kit": ["OTHER_SWIFT_FLAGS": "-DKIT"],
            "Pkg": ["OTHER_SWIFT_FLAGS": "-Xfrontend -stats-output-dir -Xfrontend \"/c/My Cache/stats\""],
        ], source: .xcodebuild)
        let check = try WrapperXCConfig.check(keys: ["OTHER_SWIFT_FLAGS"], before: before, after: after, injected: injected)
        XCTAssertEqual(check.shadowed, ["Kit: OTHER_SWIFT_FLAGS"])
        XCTAssertEqual(check.lost, ["Kit: OTHER_SWIFT_FLAGS lost -DSHARED"])
        XCTAssertEqual(WrapperXCConfig.tokens("-a \"b c\"  d"), ["-a", "b c", "d"])
    }

    func testOracleRunsTheBuildArgumentsWithShowBuildSettings() throws {
        let dir = try DeepFixtures.scratch(self)
        let record = dir.appendingPathComponent("argv.txt")
        let script = dir.appendingPathComponent("fake.sh")
        let json = #"[{"target":"App","action":"build","buildSettings":{"OTHER_SWIFT_FLAGS":"-DAPP","CONFIGURATION":"Beta","PROJECT_NAME":"App"}}]"#
        try Data("""
        #!/bin/sh
        printf '%s\\n' "$@" > '\(record.path)'
        echo "XCODE_XCCONFIG_FILE=${XCODE_XCCONFIG_FILE:-unset}" >> '\(record.path)'
        echo '\(json)'
        """.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let wrapper = dir.appendingPathComponent("tmp/wrapper-Debug.xcconfig")
        setenv("XCODE_XCCONFIG_FILE", "/env/Global.xcconfig", 1)
        defer { unsetenv("XCODE_XCCONFIG_FILE") }
        let result = SettingsOracle.effective(
            withXCConfig: wrapper, arguments: ["-scheme", "App", "-resultBundlePath", "/r.xcresult", "clean", "build",
                                               "-showBuildTimingSummary", "COMPILER_INDEX_STORE_ENABLE=NO"],
            derivedData: dir.appendingPathComponent("dd"), unsetEnvironment: ["XCODE_XCCONFIG_FILE"], executable: script)
        XCTAssertNil(result.note)
        XCTAssertEqual(result.settings?.targets["App"]?["OTHER_SWIFT_FLAGS"], "-DAPP")
        XCTAssertEqual(result.settings?.configuration, "Beta", "no -configuration: the value xcodebuild reports")
        let argv = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(argv, ["-scheme", "App", "COMPILER_INDEX_STORE_ENABLE=NO", "-xcconfig", wrapper.path,
                              "-derivedDataPath", dir.appendingPathComponent("dd").path, "-showBuildSettings", "-json",
                              "XCODE_XCCONFIG_FILE=unset"])

        let failing = SettingsOracle.effective(withXCConfig: nil, arguments: [], derivedData: nil,
                                               executable: URL(fileURLWithPath: "/usr/bin/false"))
        XCTAssertNil(failing.settings)
        XCTAssertTrue(failing.note?.contains("failed") == true, failing.note ?? "")
    }
}
