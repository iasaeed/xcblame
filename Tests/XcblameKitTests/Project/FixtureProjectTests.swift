import XCTest
@testable import XcblameKit

/// The synthetic projects under fixtures/projects (docs/SCHEMA-v0.3.md "Fixture inventory").
final class FixtureProjectTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/projects")

    /// Fixture folder → (container file name, project targets in pbxproj order).
    static let inventory: [(dir: String, container: String, targets: [String])] = [
        ("AcmeApp", "AcmeApp.xcodeproj", ["Acme", "AcmeKit", "AcmeCore", "AcmeTests"]),
        ("AcmeLegacy", "AcmeLegacy.xcodeproj", ["AcmeLegacy", "AcmeLegacyKit"]),
        ("Precedence", "Precedence.xcodeproj", ["Probe"]),
        ("PodsLike", "PodsLike.xcodeproj", ["PodsLike"]),
        ("GenXcodeGen", "AcmeGen.xcodeproj", ["AcmeGen"]),
        ("GenTuist", "AcmeTuist.xcodeproj", ["AcmeTuist"]),
    ]

    func testProjectLocatorFindsEachFixtureContainer() {
        for fixture in Self.inventory {
            let dir = Self.root.appendingPathComponent(fixture.dir)
            XCTAssertEqual(ProjectLocator.find(startingAt: dir)?.lastPathComponent, fixture.container, fixture.dir)
            // A container passed directly is returned as is.
            let container = dir.appendingPathComponent(fixture.container)
            XCTAssertEqual(ProjectLocator.find(startingAt: container), container.standardizedFileURL, fixture.dir)
        }
        let package = Self.root.appendingPathComponent("AcmeApp/Packages/AcmeShared")
        XCTAssertEqual(ProjectLocator.find(startingAt: package)?.lastPathComponent, "Package.swift")
        XCTAssertNil(ProjectLocator.find(startingAt: Self.root))
    }

    func testProjectLocatorPrefersWorkspaceAndReadsDerivedDataInfoPlist() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-locator-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
        let fm = FileManager.default
        for name in ["B.xcodeproj", "A.xcworkspace"] {
            try fm.createDirectory(at: scratch.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try Data().write(to: scratch.appendingPathComponent("Package.swift"))
        XCTAssertEqual(ProjectLocator.find(startingAt: scratch)?.lastPathComponent, "A.xcworkspace")

        let dd = scratch.appendingPathComponent("DerivedData/A-abc")
        let log = dd.appendingPathComponent("Logs/Build/1234.xcactivitylog")
        try fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: log)
        XCTAssertNil(ProjectLocator.find(forBuildLog: log, derivedData: nil), "no info.plist")
        let workspace = scratch.appendingPathComponent("A.xcworkspace")
        (["WorkspacePath": workspace.path] as NSDictionary).write(to: dd.appendingPathComponent("info.plist"),
                                                                  atomically: true)
        XCTAssertEqual(ProjectLocator.find(forBuildLog: log, derivedData: nil), workspace.standardizedFileURL)
        XCTAssertEqual(ProjectLocator.find(forBuildLog: URL(fileURLWithPath: "/elsewhere/x.xcactivitylog"),
                                           derivedData: dd), workspace.standardizedFileURL)
        (["WorkspacePath": "/nonexistent/Gone.xcworkspace"] as NSDictionary)
            .write(to: dd.appendingPathComponent("info.plist"), atomically: true)
        XCTAssertNil(ProjectLocator.find(forBuildLog: log, derivedData: nil), "a path that no longer exists")
    }

    /// xcodebuild opens every fixture and lists its targets, through the oracle's scratch workspace (a plain
    /// `xcodebuild -list -project` writes `swiftpm/configuration/` into each project, Lane B notes), and writes
    /// nothing into the fixtures. AcmeApp resolves its packages into the `.build` cache (network on the first run
    /// only; skipped when that fails).
    func testXcodebuildListsEveryFixture() throws {
        guard runProbe(["xcodebuild", "-version"], timeout: 10) != nil else { throw XCTSkip("xcodebuild not available") }
        SettingsFixtures.isolateCacheHome()
        let cache = Self.root.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/settings-test-cache/fixtures")
        for fixture in Self.inventory {
            let dir = Self.root.appendingPathComponent(fixture.dir)
            let before = SettingsFixtures.treeHash(dir)
            let model = try ProjectModel.load(container: dir.appendingPathComponent(fixture.container), scheme: nil)
            XCTAssertEqual(model.projects.first?.configurations, ["Debug", "Release"], fixture.dir)
            let settings = try XCTUnwrap(SettingsOracle.effectiveAll(project: model, configurations: ["Debug"], scheme: nil,
                                                                     offline: false, cacheDir: cache, timeout: 120)["Debug"])
            if settings.source != .xcodebuild, fixture.dir == "AcmeApp", settings.notes.first?.contains("resolve") == true {
                throw XCTSkip("AcmeApp packages could not be resolved (offline?): \(settings.notes)")
            }
            XCTAssertEqual(settings.source, .xcodebuild, "\(fixture.dir): \(settings.notes)")
            XCTAssertTrue(Set(settings.targets.keys).isSuperset(of: fixture.targets), "\(fixture.dir): \(settings.targets.keys)")
            XCTAssertEqual(SettingsFixtures.treeHash(dir), before, "xcodebuild wrote into \(fixture.dir)")
        }
    }
}
