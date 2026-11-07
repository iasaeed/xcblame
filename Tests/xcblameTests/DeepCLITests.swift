import Foundation
import XCTest
import XcblameKit

/// `build --deep` through the CLI with a fake xcodebuild (docs/SCHEMA-v0.5.md "deep and build --deep"). The fake
/// answers `-showBuildSettings` from the wrapper it is given and, for a build, writes the AcmeApp fixture log, its
/// build description and one stats-dir compile job into the DerivedData it is pointed at. Every call is recorded with
/// the `XCODE_XCCONFIG_FILE` it saw. The toolchain probe is the real one (skipped without Xcode).
final class DeepCLITests: XCTestCase {
    private var cli: CLIRunner { CLIRunner(test: self) }

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures")
    private static let statsJob = fixtures.appendingPathComponent("deep/stats/xcode26/"
        + "stats-1793608454590408-swift-frontend-AcmeApp-StudioView.swift-arm64_apple_macos14.0-o-Onone-2835036085.json")

    /// `/var/…` and `/private/var/…` are one folder.
    private static func real(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }

    func testDeepUsageErrors() throws {
        for arguments in [["build", "--deep-scope", "swift", "--", "-scheme", "App"],
                          ["build", "--exact-files", "--", "-scheme", "App"],
                          ["build", "--deep", "--deep-scope", "rust", "--", "-scheme", "App"],
                          ["build", "--deep", "--", "-scheme", "App", "-derivedDataPath", "/tmp/dd"]] {
            XCTAssertEqual(try cli.run(arguments, environment: ["XCBLAME_XCODEBUILD": "/usr/bin/false"]).status, 2,
                           arguments.joined(separator: " "))
        }
    }

    // MARK: - Fake build

    private struct Setup {
        var harness: BuildCLIHarness
        var record: URL
        var cache: URL
        var environment: [String: String]
    }

    private func setup() throws -> Setup {
        try XCTSkipIf(runProbe(["xcrun", "swift-frontend", "-help-hidden"], timeout: 10) == nil,
                      "the toolchain probe needs Xcode's swift-frontend")
        let harness = try BuildCLIHarness.make(for: self)
        let record = harness.directory.appendingPathComponent("calls.txt")
        let cache = harness.directory.appendingPathComponent("cache")
        let source = BuildCLIHarness.fixtures
        let script = harness.directory.appendingPathComponent("fake-deep-xcodebuild.sh")
        try Data(#"""
        #!/bin/sh
        LOG='\#(record.path)'
        echo "--- call" >> "$LOG"
        for a in "$@"; do echo "$a" >> "$LOG"; done
        echo "ENV XCODE_XCCONFIG_FILE=${XCODE_XCCONFIG_FILE:-unset}" >> "$LOG"
        DD=""; XC=""; SHOW=0; prev=""
        for a in "$@"; do
          case "$prev" in -derivedDataPath) DD="$a";; -xcconfig) XC="$a";; esac
          [ "$a" = "-showBuildSettings" ] && SHOW=1
          prev="$a"
        done
        if [ $SHOW = 1 ]; then
          SWIFT=""; CFLAGS=""; BASE="-DAPP"
          if [ -n "$XC" ] && [ -z "$FAKE_SHADOW" ]; then
            SWIFT=$(sed -n 's/^OTHER_SWIFT_FLAGS = \$(inherited) \(.*\) \/\/ xcblame.*/\1/p' "$XC")
            CFLAGS=$(sed -n 's/^OTHER_CFLAGS = \$(inherited) \(.*\) \/\/ xcblame.*/\1/p' "$XC")
          fi
          case "$XC" in *wrapper-*) [ -n "$FAKE_LOSE" ] && BASE="";; esac
          echo "[{\"target\":\"AcmeApp\",\"action\":\"build\",\"buildSettings\":{\"PROJECT_NAME\":\"AcmeApp\",\"OTHER_SWIFT_FLAGS\":\"$BASE $SWIFT\",\"OTHER_CFLAGS\":\"$CFLAGS\"}}]"
          exit 0
        fi
        mkdir -p "$DD/Logs/Build"
        cp '\#(source.path)/\#(BuildCLIHarness.logUUID).xcactivitylog' "$DD/Logs/Build/$(uuidgen).xcactivitylog"
        D="$DD/Build/Intermediates.noindex/XCBuildData/abc.xcbuilddata"
        mkdir -p "$D"
        gunzip -c '\#(source.path)/xcbuilddata/manifest.json.gz' > "$D/manifest.json"
        cp '\#(source.path)/xcbuilddata/target-graph.txt' '\#(source.path)/xcbuilddata/build-request.json' "$D/"
        if [ -d "$DD/xcblame-stats" ]; then cp '\#(Self.statsJob.path)' "$DD/xcblame-stats/"; fi
        exit 0
        """#.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try Data("SWIFT_VERSION = 6.0\n".utf8).write(to: harness.directory.appendingPathComponent("user.xcconfig"))
        return Setup(harness: harness, record: record, cache: cache,
                     environment: ["XCBLAME_XCODEBUILD": script.path, "XCBLAME_CACHE_DIR": cache.path])
    }

    /// The recorded calls: argv and the `XCODE_XCCONFIG_FILE` each saw.
    private func calls(_ setup: Setup) throws -> [(argv: [String], xcconfigFile: String)] {
        let text = try String(contentsOf: setup.record, encoding: .utf8)
        return text.components(separatedBy: "--- call\n").dropFirst().map { block in
            var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.last == "" { lines.removeLast() }
            let env = lines.removeLast()
            return (lines, String(env.dropFirst("ENV XCODE_XCCONFIG_FILE=".count)))
        }
    }

    private func report(_ setup: Setup, _ extra: [String] = [], environment: [String: String] = [:]) throws
        -> (run: BuildCLIHarness.Run, deep: [String: Any], document: [String: Any]) {
        let output = setup.harness.directory.appendingPathComponent("report.json")
        let run = try setup.harness.run(self, ["build", "--deep"] + extra + ["--format", "json", "-o", output.path, "--",
                                               "-scheme", "App", "-xcconfig", "user.xcconfig", "-configuration", "Debug"],
                                        environment: setup.environment.merging(environment) { $1 })
        let data = try Data(contentsOf: output)
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (run, try XCTUnwrap(document["deep"] as? [String: Any], "deep member"), document)
    }

    func testDeepBuildWritesTheWrapperAndReadsTheStatsDir() throws {
        let setup = try setup()
        let global = setup.harness.directory.appendingPathComponent("global.xcconfig")
        try Data("ONLY_ACTIVE_ARCH = YES\n".utf8).write(to: global)
        let (run, deep, document) = try report(setup, environment: ["XCODE_XCCONFIG_FILE": global.path])
        XCTAssertEqual(run.status, 0, run.err)
        XCTAssertEqual(deep["enabled"] as? Bool, true)
        XCTAssertEqual(deep["scope"] as? [String], ["swift", "clang"])
        XCTAssertEqual(deep["shadowed"] as? [String], [])

        // §7.5 include order: the user's -xcconfig, XCODE_XCCONFIG_FILE, then the deep lines.
        let wrapper = setup.harness.state.appendingPathComponent("tmp/wrapper-Debug.xcconfig")
        XCTAssertEqual((deep["wrapper"] as? String).map(Self.real), wrapper.path)
        let lines = try String(contentsOf: wrapper, encoding: .utf8).split(separator: "\n").map(String.init).dropFirst()
        XCTAssertEqual(Array(lines.prefix(2)), ["#include \"\(setup.harness.directory.appendingPathComponent("user.xcconfig").path)\"",
                                                "#include \"\(global.path)\""])
        XCTAssertTrue(lines.dropFirst(2).first?.hasPrefix("OTHER_SWIFT_FLAGS = $(inherited) -Xfrontend -debug-time-function-bodies") == true)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("#include") || $0.hasSuffix(" // xcblame --deep") }, "\(lines)")

        // Oracle without the wrapper (the user's own environment), with it (variable unset), then the build.
        let calls = try calls(setup)
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls[0].argv.contains("user.xcconfig") && calls[0].argv.contains("-showBuildSettings"))
        XCTAssertEqual(calls[0].xcconfigFile, global.path)
        XCTAssertTrue(calls[1].argv.map(Self.real).contains(wrapper.path) && !calls[1].argv.contains("user.xcconfig"))
        XCTAssertEqual(calls[1].xcconfigFile, "unset")
        let build = calls[2]
        XCTAssertFalse(build.argv.contains("-showBuildSettings"))
        XCTAssertFalse(build.argv.contains("user.xcconfig"))
        XCTAssertEqual(Self.real(build.argv[build.argv.firstIndex(of: "-xcconfig")! + 1]), wrapper.path)
        let derivedData = build.argv[build.argv.firstIndex(of: "-derivedDataPath")! + 1]
        XCTAssertEqual(URL(fileURLWithPath: derivedData).deletingLastPathComponent().path,
                       setup.cache.appendingPathComponent("deep").path)
        XCTAssertEqual(deep["derivedData"] as? String, derivedData)
        XCTAssertEqual(build.xcconfigFile, "unset", "the wrapper includes it, so the child must not read it again")

        let sources = try XCTUnwrap(deep["sources"] as? [String: Int])
        XCTAssertEqual(sources["statsDir"], 1)
        let hotspots = try XCTUnwrap(document["hotspots"] as? [[String: Any]])
        let stats = hotspots.filter { $0["source"] as? String == "statsDir" }
        XCTAssertEqual(stats.count, 1)
        XCTAssertTrue((stats.first?["file"] as? String)?.hasSuffix("/StudioView.swift") == true, "\(stats)")
        let notes = try XCTUnwrap(deep["notes"] as? [String])
        XCTAssertTrue(notes.contains("oracle check: 1 target(s) compared without and with the wrapper"), "\(notes)")
        let dropped = try XCTUnwrap(deep["flagsDropped"] as? [[String: String]])
        XCTAssertEqual(dropped.count, 0, "no flag dropped as unsupported on this toolchain: \(dropped)")
        let notInjected = try XCTUnwrap(deep["flagsNotInjected"] as? [[String: String]])
        XCTAssertEqual(notInjected.count, 2, "\(notInjected)")
        XCTAssertTrue(notInjected.allSatisfy { $0["reason"]?.hasPrefix("off by default") == true }, "\(notInjected)")
    }

    func testShadowedKeysAreNotedAndLostFlagsDisableDeep() throws {
        let setup = try setup()
        let shadowed = try report(setup, environment: ["FAKE_SHADOW": "1"])
        XCTAssertEqual(shadowed.run.status, 0, shadowed.run.err)
        XCTAssertEqual(shadowed.deep["shadowed"] as? [String], ["AcmeApp: OTHER_CFLAGS", "AcmeApp: OTHER_SWIFT_FLAGS"])
        let notes = try XCTUnwrap(shadowed.deep["notes"] as? [String])
        XCTAssertTrue(notes.contains("shadowed on AcmeApp: OTHER_SWIFT_FLAGS (command line did not win, MV-3)"), "\(notes)")

        // A lost flag: the build runs as the user asked, in the usual DerivedData (which this fake cannot locate, so
        // there is no report to read here; `deep.enabled = false` with the reason is the member's part).
        try FileManager.default.removeItem(at: setup.record)
        let lost = try setup.harness.run(self, ["build", "--deep", "--", "-scheme", "App", "-xcconfig", "user.xcconfig"],
                                         environment: setup.environment.merging(["FAKE_LOSE": "1"]) { $1 })
        XCTAssertTrue(lost.err.contains("warning: --deep disabled: the wrapper made a target lose a flag (MV-3): "
            + "AcmeApp: OTHER_SWIFT_FLAGS lost -DAPP"), lost.err)
        let build = try XCTUnwrap(try calls(setup).last)
        XCTAssertTrue(build.argv.contains("user.xcconfig"), "the build ran with the user's own arguments")
        XCTAssertFalse(build.argv.contains("-derivedDataPath"))
    }

    /// Code review v0.5 M2: `--deep` with `--kind clean --runs 2` probes and checks the wrapper once, and every
    /// xcodebuild (the cleans included) runs in the deep DerivedData with the wrapper, never in the user's.
    func testDeepWithKindAndRunsPreparesInTheDeepDerivedData() throws {
        let setup = try setup()
        let global = setup.harness.directory.appendingPathComponent("global.xcconfig")
        try Data("ONLY_ACTIVE_ARCH = YES\n".utf8).write(to: global)
        let (run, deep, _) = try report(setup, ["--kind", "clean", "--runs", "2"],
                                        environment: ["XCODE_XCCONFIG_FILE": global.path])
        XCTAssertEqual(run.status, 0, run.err)
        XCTAssertEqual(deep["enabled"] as? Bool, true)
        let derivedData = try XCTUnwrap(deep["derivedData"] as? String)
        let wrapper = setup.harness.state.appendingPathComponent("tmp/wrapper-Debug.xcconfig").path
        let calls = try calls(setup)
        XCTAssertEqual(calls.filter { $0.argv.contains("-showBuildSettings") }.count, 2, "one oracle check for all runs")
        let builds = calls.filter { !$0.argv.contains("-showBuildSettings") }
        XCTAssertEqual(builds.count, 4, "clean, build, clean, build")
        XCTAssertEqual(builds.map { $0.argv.contains("clean") }, [true, false, true, false])
        for call in builds {
            let argv = call.argv
            XCTAssertEqual(argv.firstIndex(of: "-derivedDataPath").map { argv[$0 + 1] }, derivedData, "\(argv)")
            XCTAssertEqual(argv.firstIndex(of: "-xcconfig").map { Self.real(argv[$0 + 1]) }, wrapper, "\(argv)")
            XCTAssertFalse(argv.contains("user.xcconfig"), "\(argv)")
            XCTAssertEqual(call.xcconfigFile, "unset", "the wrapper includes it: \(argv)")
        }
    }

    func testExactFilesRebuildsTheTargetsOfTheLongestBatches() throws {
        let setup = try setup()
        let (run, deep, _) = try report(setup, ["--exact-files"])
        XCTAssertEqual(run.status, 0, run.err)
        let exact = try XCTUnwrap(deep["exactFiles"] as? [String: Any])
        let targets = try XCTUnwrap(exact["rebuiltTargets"] as? [String])
        XCTAssertFalse(targets.isEmpty)
        XCTAssertTrue((exact["note"] as? String)?.contains("the build shape changed") == true)
        let builds = try calls(setup).filter { !$0.argv.contains("-showBuildSettings") }
        XCTAssertEqual(builds.count, 2, "the first deep build, then the rebuild that is reported")
        let wrapper = try String(contentsOf: setup.harness.state.appendingPathComponent("tmp/wrapper-Debug.xcconfig"),
                                 encoding: .utf8)
        XCTAssertTrue(wrapper.contains("SWIFT_ENABLE_BATCH_MODE = $(XCBLAME_BATCH_MODE_$(TARGET_NAME:c99extidentifier):default=$(inherited))"))
        for target in targets {
            XCTAssertTrue(wrapper.contains("XCBLAME_BATCH_MODE_\(target) = NO // xcblame --exact-files"), wrapper)
        }
    }
}
