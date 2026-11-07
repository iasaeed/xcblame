import Foundation
import XCTest
import XcblameKit

/// One real `xcblame build --deep` on a scratch copy of `fixtures/projects/AcmeApp` (iOS, built for the generic
/// simulator with `CODE_SIGNING_ALLOWED=NO`) into a scratch cache folder. Opt-in (`XCBLAME_E2E=1`): it resolves
/// swift-syntax over the network and takes minutes. `XCBLAME_E2E_PACKAGES=<dir>` reuses package clones
/// (`-clonedSourcePackagesDirPath`). The fixture's `Upload Symbols` script needs `sentry-cli` and fails the build
/// after every compile has run, so the exit code is xcblame's (`--exit-code xcblame`).
final class DeepE2ETests: XCTestCase {
    func testDeepBuildOfTheAcmeFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["XCBLAME_E2E"] == "1", "set XCBLAME_E2E=1 to run the xcodebuild end-to-end test")
        try XCTSkipIf(runProbe(["xcodebuild", "-version"], timeout: 10) == nil, "xcodebuild is not available")

        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/projects/AcmeApp")
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-deep-e2e-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
        // A copy, so xcodebuild never writes into the repository (it creates `.swiftpm/` in local packages).
        let project = scratch.appendingPathComponent("AcmeApp")
        try FileManager.default.copyItem(at: fixture, to: project)

        var arguments = ["build", "--deep", "--exit-code", "xcblame", "--no-history", "--format", "json",
                         "-o", scratch.appendingPathComponent("report.json").path, "--",
                         "-project", project.appendingPathComponent("AcmeApp.xcodeproj").path, "-scheme", "Acme",
                         "-configuration", "Debug", "-destination", "generic/platform=iOS Simulator",
                         "CODE_SIGNING_ALLOWED=NO"]
        if let packages = environment["XCBLAME_E2E_PACKAGES"] { arguments += ["-clonedSourcePackagesDirPath", packages] }
        let process = Process()
        process.executableURL = BuildCLIHarness.binary(for: self)
        process.arguments = arguments
        process.currentDirectoryURL = scratch
        var env = environment
        env["CI"] = nil
        env["XCBLAME_XCODEBUILD"] = nil
        env["XCBLAME_CACHE_DIR"] = scratch.appendingPathComponent("cache").path
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        process.standardError = err
        try process.run()
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(stderr.suffix(4000)))

        let data = try Data(contentsOf: scratch.appendingPathComponent("report.json"))
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let deep = try XCTUnwrap(document["deep"] as? [String: Any])
        XCTAssertEqual(deep["enabled"] as? Bool, true, "\(deep["notes"] ?? "")")
        XCTAssertTrue((deep["derivedData"] as? String)?.hasPrefix(scratch.appendingPathComponent("cache/deep").path) == true)
        let dropped = try XCTUnwrap(deep["flagsDropped"] as? [[String: String]])
        XCTAssertEqual(dropped.count, 0, "no flag dropped as unsupported on this toolchain: \(dropped)")
        let notInjected = try XCTUnwrap(deep["flagsNotInjected"] as? [[String: String]])
        XCTAssertEqual(notInjected.count, 2, "\(notInjected)")
        XCTAssertTrue(notInjected.allSatisfy { $0["reason"]?.hasPrefix("off by default") == true }, "\(notInjected)")
        let sources = try XCTUnwrap(deep["sources"] as? [String: Int])
        XCTAssertGreaterThan(sources["statsDir"] ?? 0, 0)
        XCTAssertGreaterThan(sources["debugTime"] ?? 0, 0)
        let hotspots = try XCTUnwrap(document["hotspots"] as? [[String: Any]])
        XCTAssertTrue(hotspots.contains { $0["source"] as? String == "statsDir" }, "\(hotspots)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("Packages/AcmeShared/.swiftpm").path))
    }
}
