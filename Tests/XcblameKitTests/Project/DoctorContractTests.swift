import XCTest
@testable import XcblameKit

/// Phase-1 behavior of the v0.3 entry points and the report helpers the lanes build on.
final class DoctorContractTests: XCTestCase {
    private let acme = FixtureProjectTests.root.appendingPathComponent("AcmeApp/AcmeApp.xcodeproj")

    private func finding(_ id: String, severity: String?, commands: [String] = []) -> ReportDocument.Finding {
        ReportDocument.Finding(ruleId: id, title: id, severity: severity, impactBand: nil, impactSeconds: nil,
                               impactBasis: nil, confidence: "medium", evidence: [], fixKind: nil, risk: nil,
                               mechanism: nil, signalKey: "k:\(id)", fixCommands: commands)
    }

    private func model() -> ProjectModel {
        let target = ProjectModel.Target(id: "AC0000000000000000000030", name: "Acme",
                                         productType: "com.apple.product-type.application", hasSwiftSources: true)
        return ProjectModel(
            root: acme.deletingLastPathComponent(), container: .xcodeproj(acme), format: .pbxproj(objectVersion: 77),
            projects: [ProjectModel.Project(path: acme, name: "AcmeApp", objectVersion: 77,
                                            configurations: ["Debug", "Release"], defaultConfiguration: "Release",
                                            targets: [target])],
            packages: [ProjectModel.PackageReference(url: nil, path: acme, requirement: .local),
                       ProjectModel.PackageReference(url: "https://example.com/x", path: nil, requirement: .branch("main"))],
            dependencyManagers: [.spm], generator: .xcodegen(spec: acme))
    }

    func testEntryPointsAreReal() throws {
        // Offline: the resolver answers from the (hand-built) model without running xcodebuild.
        let settings = try SettingsOracle.effective(project: model(), configuration: "Debug", scheme: nil,
                                                    offline: true, cacheDir: nil)
        XCTAssertEqual(settings.source, .offlineResolver)
        XCTAssertEqual(settings.configuration, "Debug")
        // A key nothing writes comes from the platform default; a target the model lacks is unknown.
        XCTAssertEqual(SettingsOracle.provenance(project: model(), target: "Acme", key: "K", configuration: "Debug").level,
                       .platformDefault)
        XCTAssertEqual(SettingsOracle.provenance(project: model(), target: "Nope", key: "K", configuration: "Debug").level,
                       .unknown)
        XCTAssertEqual(try ProjectModel.load(container: acme, scheme: nil).allTargets.map(\.name),
                       ["Acme", "AcmeKit", "AcmeCore", "AcmeTests"])
        // Lane C landed: with no project, build or machine snapshot every rule is not applicable.
        XCTAssertTrue(RuleEngine.run(RuleContext(project: nil)).findings.isEmpty)
        XCTAssertNotNil(RuleCatalog.spec("SET-001"))
    }

    func testConfigurationRole() {
        XCTAssertEqual(ConfigurationRole.role(name: "Staging", effective: ["SWIFT_OPTIMIZATION_LEVEL": "-Onone"]), .debugLike)
        // AcmeApp's deliberately bad Debug (-O plus DEBUG) is still debug-like.
        XCTAssertEqual(ConfigurationRole.role(name: "Debug", effective: [
            "SWIFT_OPTIMIZATION_LEVEL": "-O", "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "DEBUG $(inherited)",
        ]), .debugLike)
        XCTAssertEqual(ConfigurationRole.role(name: "Beta", effective: ["SWIFT_OPTIMIZATION_LEVEL": "-Osize"]), .releaseLike)
        XCTAssertEqual(ConfigurationRole.role(name: "Debug-Dev", effective: [:]), .debugLike)
        XCTAssertEqual(ConfigurationRole.role(name: "release", effective: [:]), .releaseLike)
        XCTAssertEqual(ConfigurationRole.role(name: "QA", effective: [:]), .unknown)
    }

    func testFailOnThresholds() {
        let findings = [finding("SET-001", severity: "medium"), finding("ENV-004", severity: nil)]
        XCTAssertTrue(ReportDocument.failOnHit(findings, threshold: "low"))
        XCTAssertTrue(ReportDocument.failOnHit(findings, threshold: "medium"))
        XCTAssertFalse(ReportDocument.failOnHit(findings, threshold: "high"))
        XCTAssertFalse(ReportDocument.failOnHit(findings, threshold: "none"))
        XCTAssertFalse(ReportDocument.failOnHit(findings, threshold: nil))
        XCTAssertFalse(ReportDocument.failOnHit([], threshold: "low"))
    }

    func testMakeDoctorFillsProjectDoctorAndFixPlanAndNullsTheBuild() throws {
        let result = RuleResult(
            findings: [finding("SET-001", severity: "high", commands: ["xcblame verify --rules SET-001", "xcblame fix"]),
                       finding("DEP-001", severity: "low", commands: ["xcblame fix --rules DEP-001"])],
            passed: [RuleOutcome(ruleId: "SET-002", title: "t", detail: "Debug: -Onone")],
            notApplicable: [RuleOutcome(ruleId: "PHASE-007", title: "t", detail: "no CocoaPods")])
        let settings = ["Debug": EffectiveSettings(configuration: "Debug",
                                                   targets: ["Acme": [:], "AcmeShared": [:]], source: .xcodebuild)]
        let doc = ReportDocument.makeDoctor(project: model(), settings: settings, result: result,
                                            configurations: ["Debug"], environment: nil, xcode: "26.0.1",
                                            generatedAt: Date(timeIntervalSince1970: 0), durationSeconds: 1.25,
                                            offline: false, failOn: "high")
        let project = try XCTUnwrap(doc.project)
        XCTAssertEqual(project.format, "pbxproj")
        XCTAssertEqual(project.objectVersion, 77)
        XCTAssertEqual(project.generator, "xcodegen")
        XCTAssertEqual(project.targets, 1)
        XCTAssertEqual(project.packageTargets, 1)
        XCTAssertEqual(project.localPackages, 1)
        XCTAssertEqual(project.remotePackages, 1)
        XCTAssertEqual(project.settingsSource, "xcodebuild -showBuildSettings -json")
        let doctor = try XCTUnwrap(doc.doctor)
        XCTAssertEqual(doctor.rulesEvaluated, 4)
        XCTAssertEqual(doctor.failOn, "high")
        XCTAssertTrue(doctor.failed)
        XCTAssertEqual(doc.fixPlan.map(\.order), [1, 2, 3])
        XCTAssertEqual(doc.fixPlan.map(\.ruleId), ["SET-001", "SET-001", "DEP-001"])
        XCTAssertEqual(doc.findingsTotal, 2)
        XCTAssertNil(doc.build.span)
        XCTAssertNil(doc.criticalPath)
        XCTAssertNil(doc.targets)
        XCTAssertTrue(doc.notes.contains { $0.hasPrefix("doctor runs no build") })
        XCTAssertEqual(doc.xcode.value, "26.0.1")

        // Offline: no settings → packageTargets and settingsSource are null with a note.
        let offline = ReportDocument.makeDoctor(project: model(), settings: [:], result: RuleResult(),
                                                configurations: ["Debug"], environment: nil, xcode: nil,
                                                generatedAt: Date(), durationSeconds: nil, offline: true, failOn: nil)
        XCTAssertNil(offline.project?.packageTargets)
        XCTAssertNil(offline.project?.settingsSource)
        XCTAssertFalse(offline.doctor?.failed ?? true)
        // The page renders the doctor document (Lane C adds its doctor view).
        XCTAssertNoThrow(try HTMLReporter.render(doc, taskIndex: nil, options: .init(redact: false, title: "xcblame doctor")))
        XCTAssertTrue(TextReporter.renderDoctor(doc).contains("SET-001"))
    }

    func testMergeIntoAnAnalyzeDocument() throws {
        var doc = try ReportPipeline.run(SyntheticModel.make()).document
        let before = doc
        doc.merge(rules: RuleResult(), project: nil, settings: [:], configurations: [], offline: false)
        XCTAssertEqual(doc, before, "an empty rule run leaves the analyze document unchanged")
        doc.merge(rules: RuleResult(findings: [finding("DYN-001", severity: "medium", commands: ["xcblame why"])],
                                    passed: [RuleOutcome(ruleId: "SET-001", title: "t", detail: "d")]),
                  project: model(), settings: [:], configurations: ["Release"], offline: false)
        XCTAssertEqual(doc.findings.map(\.ruleId), ["DYN-001"])
        XCTAssertEqual(doc.findingsTotal, 1)
        XCTAssertEqual(doc.fixPlan.count, 1)
        XCTAssertEqual(doc.doctor?.rulesEvaluated, 2)
        XCTAssertNil(doc.doctor?.durationSeconds)
        XCTAssertEqual(doc.project?.configurations, ["Release"])
    }

    func testEvidenceTagAndSeverityCoding() throws {
        let tags: [RuleSpec.EvidenceTag] = [.primary, .secondary, .knowledge, .mixed("S/K")]
        let data = try JSONEncoder().encode(tags)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"["P","S","K","S\/K"]"#)
        XCTAssertEqual(try JSONDecoder().decode([RuleSpec.EvidenceTag].self, from: data), tags)
        XCTAssertEqual(tags.map(\.isKnowledgeGated), [false, false, true, true])
        XCTAssertLessThan(RuleSpec.Severity.info, .low)
        XCTAssertLessThan(RuleSpec.Severity.medium, .high)
        XCTAssertEqual(RuleSpec.Category.set.dedupeRank, 0)
        XCTAssertLessThan(RuleSpec.Category.phase.dedupeRank, RuleSpec.Category.dep.dedupeRank)
    }
}
