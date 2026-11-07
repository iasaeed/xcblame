import Foundation
import XCTest
@testable import XcblameKit

final class EnvTests: XCTestCase {
    private func model(commands: [String] = [], emitted: String? = nil, formatVersion: Int? = nil) -> BuildModel {
        let tasks = commands.enumerated().map { index, command in
            RawSection(title: "t", domainType: BuildModelBuilder.buildLogSectionDomain, commandDetails: command,
                       start: 1000 + Double(index), end: 1001 + Double(index), emittedOutput: emitted)
        }
        let root = RawSection(domainType: "Xcode.IDEActivityLogDomainType.BuildLog", start: 1000, end: 1100, subsections: tasks)
        return BuildModelBuilder.build(RawLog(formatVersion: formatVersion, layout: .commandLine, root: root), reader: .slf)
    }

    // MARK: Inference

    func testSDKNameInCommandGivesVersion() throws {
        let inferred = try XCTUnwrap(XcodeVersionInference.infer(from: model(commands: [
            "SwiftDriver Compilation App normal arm64\n    cd /p\n    swiftc -sdk /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.0.sdk -c",
        ])))
        XCTAssertEqual(inferred.value, "26.0")
        XCTAssertEqual(inferred.source, "inferred")
        XCTAssertTrue(inferred.evidence.contains { $0.contains("MacOSX26.0.sdk") }, "\(inferred.evidence)")
    }

    func testStatCacheNameGivesSDKBuildAndMaxVersionWins() throws {
        let inferred = try XCTUnwrap(XcodeVersionInference.infer(from: model(commands: [
            "ClangStatCache /x/clang-stat-cache /x/iPhoneOS26.0.sdk /dd/SDKStatCaches.noindex/macosx26.0-25A352-2880614.sdkstatcache",
            "Ld /x/iPhoneOS26.1.sdk",
        ], formatVersion: 11)))
        XCTAssertEqual(inferred.value, "26.1")
        XCTAssertTrue(inferred.evidence.contains { $0.contains("SDK build 25A352") }, "\(inferred.evidence)")
        XCTAssertFalse(inferred.evidence.contains { $0.contains("log format") }, "weakest evidence only when nothing else")
    }

    func testOlderSDKsMapThroughTableAndUnknownPlatformsAreIgnored() throws {
        let inferred = try XCTUnwrap(XcodeVersionInference.infer(from: model(commands: ["cc /x/MacOSX15.2.sdk /y/DriverKit24.2.sdk"])))
        XCTAssertEqual(inferred.value, "16.2")
        XCTAssertNil(XcodeVersionInference.infer(from: model(commands: ["cc /y/DriverKit25.0.sdk /y/MacOSX.sdk"])))
    }

    func testNonDefaultDeveloperDirAndCompilerEvidence() throws {
        let inferred = try XCTUnwrap(XcodeVersionInference.infer(from: model(
            commands: ["Ld /Applications/Xcode-26.2.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang -o x"],
            emitted: "Apple Swift version 6.2 (swiftlang-6.2.0.19.9 clang-1700.3.19.1)\n")))
        XCTAssertEqual(inferred.value, "26.2")
        XCTAssertTrue(inferred.evidence.contains { $0.contains("/Applications/Xcode-26.2.app") })
        XCTAssertTrue(inferred.evidence.contains { $0.hasPrefix("compiler: Apple Swift version 6.2") })
        // The default location is not evidence.
        XCTAssertNil(XcodeVersionInference.infer(from: model(commands: ["Ld /Applications/Xcode.app/Contents/Developer/x"])))
    }

    func testFormatVersionIsWeakestEvidence() throws {
        XCTAssertEqual(XcodeVersionInference.infer(from: model(commands: ["Ld x"], formatVersion: 11))?.value, "26.0")
        let v13 = try XCTUnwrap(XcodeVersionInference.infer(from: model(commands: ["Ld x"], formatVersion: 13)))
        XCTAssertEqual(v13.value, "27.1")
        XCTAssertEqual(v13.evidence, ["log format version 13 (written by Xcode >= 27.1)"])
    }

    func testFormatVersionLiftsALowerSDKVersion() throws {
        // Xcode 27.1 beta: MacOSX27.0.sdk in the commands, but only >= 27.1 writes format 13.
        let inferred = try XCTUnwrap(XcodeVersionInference.infer(from: model(
            commands: ["Ld /x/MacOSX27.0.sdk -o x"], formatVersion: 13)))
        XCTAssertEqual(inferred.value, "27.1")
        XCTAssertEqual(inferred.evidence.first, "log format version 13 (written by Xcode >= 27.1)")
        XCTAssertTrue(inferred.evidence.contains { $0.contains("MacOSX27.0.sdk") })
    }

    func testFlagGluedToTheDeveloperDirIsNotPartOfTheAppPath() {
        XCTAssertEqual(XcodeVersionInference.nonDefaultXcodeApps(
            in: "clang -L/Applications/Xcode-27.1-beta.app/Contents/Developer/lib -F/Applications/Xcode.app/Contents/Developer/x"),
                       ["/Applications/Xcode-27.1-beta.app"])
    }

    func testEmptyModelIsNil() {
        XCTAssertNil(XcodeVersionInference.infer(from: model()))
    }

    func testFixtureInference() throws {
        let data = try LaneBFixtures.inflated("cli-xcode26/xcresult-buildlog.json.gz")
        let built = BuildModelBuilder.build(try XCResultReader.read(jsonData: data), reader: .xcresult)
        let inferred = try XCTUnwrap(XcodeVersionInference.infer(from: built))
        XCTAssertEqual(inferred.value, "26.0")
        XCTAssertTrue(inferred.evidence.contains { $0.contains("25A352") }, "\(inferred.evidence)")
    }

    // MARK: Snapshot

    func testCaptureRunsAndDoesNotCrash() {
        let snapshot = EnvSnapshot.capture()
        XCTAssertNotNil(snapshot.macOSProductVersion)
        XCTAssertNotNil(snapshot.logicalCPUCount)
        XCTAssertEqual(try? JSONDecoder().decode(EnvSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
    }

    func testCaptureWithFailingProbesIsAllUnknown() {
        let snapshot = EnvSnapshot.capture(environment: [:], probe: { _ in nil })
        XCTAssertEqual(snapshot, EnvSnapshot())
    }

    func testCIProviderTable() {
        XCTAssertEqual(EnvSnapshot.ciProvider(environment: ["GITHUB_ACTIONS": "true", "CI": "true"]), "github-actions")
        XCTAssertEqual(EnvSnapshot.ciProvider(environment: ["CI_XCODE_CLOUD": "TRUE"]), "xcode-cloud")
        XCTAssertEqual(EnvSnapshot.ciProvider(environment: ["BUILDKITE": "true"]), "buildkite")
        XCTAssertEqual(EnvSnapshot.ciProvider(environment: ["CI": "1"]), "ci")
        XCTAssertNil(EnvSnapshot.ciProvider(environment: ["GITLAB_CI": ""]))
    }

    func testSwVersParsing() {
        let fields = EnvSnapshot.keyValues("ProductName:\t\tmacOS\nProductVersion:\t\t26.0\nBuildVersion:\t\t25A354\n")
        XCTAssertEqual(fields["ProductVersion"], "26.0")
        XCTAssertEqual(fields["BuildVersion"], "25A354")
    }

    func testTimedOutProcessReportsWithoutRaising() throws {
        let start = Date()
        let out = try XCTUnwrap(runProcess(["sleep", "5"], timeout: 0.5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertTrue(out.timedOut)
        XCTAssertNotEqual(out.exitStatus, 0)
        XCTAssertFalse(out.succeeded)
    }

    func testSystemToolsRunByAbsolutePath() {
        XCTAssertEqual(systemToolPaths["xcrun"], "/usr/bin/xcrun")
        XCTAssertNotNil(runProbe(["sw_vers"]), "sw_vers runs from /usr/bin")
        for path in systemToolPaths.values { XCTAssertTrue(path.hasPrefix("/usr/")) }
    }

    func testProbeTimesOut() {
        let start = Date()
        XCTAssertNil(runProbe(["sleep", "5"], timeout: 2))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
        XCTAssertEqual(runProbe(["echo", "hi"]), "hi")
        XCTAssertNil(runProbe(["false"]))
        XCTAssertNil(runProbe(["definitely-not-a-command-xcblame"]))
    }
}
