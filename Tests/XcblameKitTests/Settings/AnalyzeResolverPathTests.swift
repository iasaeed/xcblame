import XCTest
@testable import XcblameKit

/// The settings path `analyze --project` takes, at library level: the CLI test forces `--offline` (a cold oracle can miss
/// analyze's 5 s cap on a loaded machine), so the `xcodebuild -showBuildSettings` resolver and the confidence it earns
/// are covered here, on the one fixture project without packages. Needs xcodebuild, like `SettingsOracleTests`.
final class AnalyzeResolverPathTests: XCTestCase {
    override func setUpWithError() throws {
        SettingsFixtures.isolateCacheHome()
        guard SettingsFixtures.xcodebuildAvailable() else { throw XCTSkip("xcodebuild not available") }
    }

    private func findings(offline: Bool) throws -> (settings: [String: EffectiveSettings], findings: [ReportDocument.Finding]) {
        let container = SettingsFixtures.projects.appendingPathComponent("AcmeLegacy/AcmeLegacy.xcodeproj")
        let model = try ProjectModel.load(container: container, scheme: nil)
        let configuration = try XCTUnwrap(model.projects.first?.defaultConfiguration ?? model.configurationNames.first)
        // Exactly the call of `AnalyzeCommand.applyRules`: the analyze bound, no package resolution, a scratch cache.
        let settings = SettingsOracle.effectiveAll(
            project: model, configurations: [configuration], scheme: nil, offline: offline,
            cacheDir: SettingsFixtures.scratch("analyze-resolver-\(offline)", self), timeout: SettingsOracle.analyzeTimeout,
            resolvePackages: false, totalTimeout: SettingsOracle.analyzeTimeout)
        let context = RuleContext(project: model, settings: settings,
                                  provenance: RuleContext.oracleProvenance(model, settings: settings), offline: offline)
        return (settings, RulesFixtures.run(context).findings)
    }

    func testTheXcodebuildResolverEarnsMediumConfidenceWhereTheOfflineOneStaysLow() throws {
        let live = try findings(offline: false)
        let liveSources = live.settings.values.map(\.source)
        let liveNotes = live.settings.values.flatMap(\.notes)
        if SettingsFixtures.isHostedCI, liveSources != [.xcodebuild], liveNotes.contains(where: { $0.contains("timed out") }) {
            throw XCTSkip("hosted runner missed analyze's \(SettingsOracle.analyzeTimeout) s oracle cap: \(liveNotes)")
        }
        XCTAssertEqual(live.settings.values.map(\.source), [.xcodebuild], "\(live.settings.values.map(\.notes))")
        XCTAssertTrue(live.findings.contains { $0.confidence == "medium" }, "\(live.findings.map(\.confidence))")

        let offline = try findings(offline: true)
        XCTAssertEqual(offline.settings.values.map(\.source), [.offlineResolver])
        XCTAssertFalse(offline.findings.isEmpty)
        XCTAssertTrue(offline.findings.allSatisfy { $0.confidence == "low" }, "static-only findings on unverified settings")
    }
}
