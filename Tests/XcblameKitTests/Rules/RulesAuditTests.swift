import XCTest
@testable import XcblameKit

/// Mismatches from the v0.3 hand audit of five real projects (shapes only): unset keys, Podfile.lock pods,
/// Package.resolved tracking.
final class RulesAuditTests: XCTestCase {
    // MARK: H. Unset keys are never a silent pass

    /// AcmeApp's Acme target has C sources; GCC_OPTIMIZATION_LEVEL unset everywhere.
    private func unsetGCC(source: EffectiveSettings.Source) -> RuleResult {
        var model = RulesFixtures.acmeApp()
        model.projects[0].projectSettings["Debug"]?["GCC_OPTIMIZATION_LEVEL"] = nil
        var settings = RulesFixtures.effective(model, source: source)
        for name in settings["Debug"]!.targets.keys { settings["Debug"]!.targets[name]!["GCC_OPTIMIZATION_LEVEL"] = nil }
        return RulesFixtures.run(RulesFixtures.context(model, settings: settings), rules: ["SET-003"])
    }

    func testUnsetGCCOptimizationFiresOnThePlatformDefault() throws {
        let finding = try XCTUnwrap(unsetGCC(source: .xcodebuild).finding("SET-003"))
        XCTAssertEqual(finding.scopeTargets, ["Acme"])
        XCTAssertTrue(finding.evidence.contains { $0.contains("= unset (platform default s)") }, "\(finding.evidence)")
        XCTAssertTrue(finding.title.contains("unset (platform default s)"), finding.title)
    }

    func testOfflineUnsetKeyIsNotApplicableNeverAPass() throws {
        let result = unsetGCC(source: .offlineResolver)
        XCTAssertNil(result.finding("SET-003"))
        let outcome = try XCTUnwrap(result.outcome("SET-003"))
        XCTAssertEqual(outcome.list, "notApplicable")
        XCTAssertTrue(outcome.detail.hasPrefix("GCC_OPTIMIZATION_LEVEL unknown (offline) for Acme"), outcome.detail)
        // Same for SET-029 (COPY_PHASE_STRIP defaults to YES): offline and unset is unknown, online it fires.
        var model = RulesFixtures.acmeApp()
        var offline = RulesFixtures.effective(model, source: .offlineResolver)
        var online = RulesFixtures.effective(model)
        for name in offline["Debug"]!.targets.keys {
            offline["Debug"]!.targets[name]!["COPY_PHASE_STRIP"] = nil
            online["Debug"]!.targets[name]!["COPY_PHASE_STRIP"] = nil
        }
        model.generator = nil
        XCTAssertEqual(RulesFixtures.run(RulesFixtures.context(model, settings: offline), rules: ["SET-029"])
            .outcome("SET-029")?.list, "notApplicable")
        XCTAssertNotNil(RulesFixtures.run(RulesFixtures.context(model, settings: online), rules: ["SET-029"]).finding("SET-029"))
    }

    // MARK: I. DEP-003 reads Podfile.lock

    func testHeavyPodsFromTheLockfileFire() throws {
        let dir = SettingsFixtures.scratch("audit-pods", self)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let podfile = dir.appendingPathComponent("Podfile")
        let lock = dir.appendingPathComponent("Podfile.lock")
        try Data("target 'App' do\n  pod 'AppCore'\nend\n".utf8).write(to: podfile)
        try Data("""
            PODS:
              - AppCore (1.0):
                - FirebaseCore (10.0.0)
              - FirebaseCore (10.0.0)
              - "gRPC-Core (1.62.0)"
              - SnapKit (5.7.1)

            DEPENDENCIES:
              - AppCore

            """.utf8).write(to: lock)
        XCTAssertEqual(DEPChecks.lockedPods(try String(contentsOf: lock, encoding: .utf8)),
                       ["AppCore", "FirebaseCore", "gRPC-Core", "SnapKit"])
        var model = RulesFixtures.podsLike()
        model.root = dir
        model.dependencyManagers = [.cocoapods(podfile: podfile, lockfile: lock, podCount: 4)]
        let result = RulesFixtures.run(RulesFixtures.context(model), rules: ["DEP-003"])
        XCTAssertEqual(result.findings("DEP-003").map(\.signalKey).sorted(), ["heavy-dependency:Firebase", "heavy-dependency:gRPC"])
        XCTAssertTrue(result.finding("DEP-003")?.evidence.contains { $0.hasPrefix("Podfile.lock: ") } == true)
    }

    // MARK: J. DEP-002 static part follows git

    private func resolvedProject() throws -> ProjectModel {
        let dir = SettingsFixtures.scratch("audit-resolved", self)
        let xcodeproj = dir.appendingPathComponent("App.xcodeproj")
        let swiftpm = xcodeproj.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm")
        try FileManager.default.createDirectory(at: swiftpm, withIntermediateDirectories: true)
        try Data("{\"pins\":[],\"version\":3}".utf8).write(to: swiftpm.appendingPathComponent("Package.resolved"))
        var model = RulesFixtures.acmeApp()
        model.root = dir
        model.container = .xcodeproj(xcodeproj)
        return model
    }

    func testPackageResolvedUntrackedFiresTrackedPassesNoGitIsNotApplicable() throws {
        let model = try resolvedProject()
        let root = model.root.path
        let file = model.container.url.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved").path
        let inRepo = "git -C \(root) rev-parse --is-inside-work-tree"
        let tracked = "git -C \(root) ls-files --error-unmatch \(file)"
        func outcome(_ run: [String: String]) -> RuleResult {
            RulesFixtures.run(RulesFixtures.context(model), rules: ["DEP-002"], probe: RulesFixtures.probe(run: run))
        }
        XCTAssertTrue(outcome([inRepo: "true"]).finding("DEP-002")?.title.contains("not tracked by git") == true)
        XCTAssertEqual(outcome([inRepo: "true", tracked: file]).outcome("DEP-002")?.list, "passed")
        let noGit = try XCTUnwrap(outcome([:]).outcome("DEP-002"))
        XCTAssertEqual(noGit.list, "notApplicable")
        XCTAssertTrue(noGit.detail.contains("not a git work tree"), noGit.detail)
        XCTAssertEqual(systemToolPaths["git"], "/usr/bin/git", "never a PATH shim")
        XCTAssertEqual(systemToolPaths["diskutil"], "/usr/sbin/diskutil")
    }
}
