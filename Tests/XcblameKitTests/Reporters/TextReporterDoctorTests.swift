import XCTest
@testable import XcblameKit

/// The `doctor` text (DESIGN §3.4) and the analyze FINDINGS section (§3.3), rendered from hand-built documents.
final class TextReporterDoctorTests: XCTestCase {
    /// A small generated project: target-level whole-module Debug, a branch-pinned package, caching off.
    static func smallDoctor(failOn: String? = "medium", offline: Bool = false) -> ReportDocument {
        var model = RulesFixtures.genXcodeGen()
        model.projects[0].targets[0].settings["Debug"] = ["SWIFT_COMPILATION_MODE": SettingValue(raw: "wholemodule")]
        model.packages = [.init(url: "https://github.com/apple/swift-argument-parser", path: nil, requirement: .branch("main"),
                                consumers: ["AcmeGen"])]
        model.dependencyManagers = [.spm]
        let settings = RulesFixtures.effective(model)
        let probe = RulesFixtures.probe(run: ["tmutil destinationinfo": "Name: Backup",
                                              "tmutil isexcluded /Users/sample/Library/Developer/Xcode/DerivedData": "[Included] x"])
        let result = RulesFixtures.run(RulesFixtures.context(model, settings: settings, env: RulesFixtures.env(), offline: offline),
                                       probe: probe)
        return ReportDocument.makeDoctor(project: model, settings: settings, result: result,
                                         configurations: model.configurationNames, environment: RulesFixtures.env(),
                                         xcode: "26.0.1", generatedAt: Date(timeIntervalSince1970: 0), durationSeconds: 2.8,
                                         offline: offline, failOn: failOn)
    }

    func testDoctorTextGolden() {
        let text = TextReporter.renderDoctor(Self.smallDoctor())
        let expected = """
        xcblame \(XcblameVersion.current) doctor · AcmeGen.xcodeproj (objectVersion 77, pbxproj) · Xcode 26.0.1 · 2.8 s
          generator  XcodeGen (project.yml) → project edits disabled; hook goes into project.yml
          settings   xcodebuild -showBuildSettings -json: 2 configurations (Debug, Release) x 1 target + 0 package targets
          graph      1 project target, 0 local packages, 1 remote package · spm · 0 schemes

        PASS (24)  SET-002 Debug: -Onone · SET-004 Debug: dwarf · SET-005 Debug: YES · SET-006 no arm64
                   exclusion for the simulator · SET-007 Release: NO · SET-009 Debug/Release: batch mode on
                   (no override) · SET-010 Debug: NO, Release: NO · SET-011 Debug: unset (platform default
                   NO) · SET-013 Debug: explicit modules YES, Release: explicit modules YES · SET-015 Debug:
                   integrated driver YES, Release: integrated driver YES · SET-020 Release: no timing
                   diagnostic flags in OTHER_SWIFT_FLAGS · SET-027 Debug/Release: no -ld_classic/-ld64 in
                   OTHER_LDFLAGS · SET-028 no LTO in Debug, no monolithic LTO · SET-029 Debug:
                   COPY_PHASE_STRIP and DEPLOYMENT_POSTPROCESSING off · SET-031 Debug: no cross-module
                   optimization flags · SET-032 Debug/Release: BUILD_LIBRARY_FOR_DISTRIBUTION off · DEP-003
                   no known heavy source dependency (Firebase, Realm, gRPC, abseil) · DEP-010 no
                   XCRemoteCache configuration · DEP-012 no non-macro target uses swift-syntax · ENV-001
                   ShowBuildOperationDuration = YES · ENV-002
                   IDEBuildOperationMaxNumberOfConcurrentCompileTasks unset (default = cores) · ENV-003
                   indexing on (developer machine) · ENV-005 native, 32 GB, no thermal limit · ENV-006 Xcode
                   26.0.1: no known build-time issue in the table
        N/A (20)   no targets with C/ObjC sources (SET-003, SET-022) · not a CI run (CI=true is not set)
                   (SET-008, SET-017) · no C/ObjC or framework targets with effective settings (SET-014) ·
                   no targets with a prefix header (SET-021) · fewer than 2 Swift-only dynamic framework
                   targets (0) (SET-023) · no script phases (SET-030, PHASE-001, PHASE-002, PHASE-003,
                   PHASE-004) · no local package manifests (PHASE-005) · no CocoaPods (PHASE-007) · no
                   CocoaPods (no Podfile) (DEP-004, DEP-005) · no Carthage (no Cartfile) (DEP-006) · not a
                   Tuist project, and no CI clean build on Xcode 26+ (DEP-007) · no macro target (DEP-008) ·
                   macro products of remote packages unknown (no checkout manifest for
                   swift-argument-parser) (ENV-008)

        FINDINGS                                                               impact  conf    fix
          SET-001  SWIFT_COMPILATION_MODE = wholemodule in Debug for AcmeGen;  ~M      medium  overlay
                   Debug should compile singlefile
          DEP-001  swift-argument-parser is pinned to branch main (used by     ?       medium  recommend
                   AcmeGen); pin a version or a revision from
                   Package.resolved
          DEP-002  Package.resolved is missing                                 ?       medium  recommend
                   (AcmeGen.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved):
                   every machine and CI run resolves package versions again;
                   commit it and resolve only from it on CI
          SET-016  COMPILATION_CACHE_ENABLE_CACHING not set to YES in Debug    ?       medium  overlay +V
                   for AcmeGen (Xcode 26+); covers project targets, SPM
                   package caching unverified. Needs measurement.
          ENV-004  DerivedData                                                 ?       low     recommend
                   (/Users/sample/Library/Developer/Xcode/DerivedData) not
                   excluded from Time Machine; run tmutil addexclusion on it.
                   Needs measurement.
        PLAN  1. `xcblame verify --rules SET-001 --kind clean --mechanism cli`
              2. `xcblame verify --rules SET-016 --kind clean --mechanism hook`
              3. `xcblame fix --rules SET-016 --apply`
              the hook is printed, not applied: XcodeGen: configFiles: {Debug: .xcblame/hook-Debug.xcconfig} in project.yml
        fail-on medium: 3 findings at or above medium → exit 4
        """
        if text != expected + "\n" { print(text) }
        XCTAssertEqual(text, expected + "\n")
    }

    func testUnknownValuesPrintAsUnknownAndListsAreCappedByTopN() {
        var doc = Self.smallDoctor(failOn: nil, offline: true)
        doc.project?.packageTargets = nil
        doc.project?.settingsSource = nil
        doc.xcode.value = nil
        doc.doctor?.durationSeconds = nil
        doc.topN = 2
        let text = TextReporter.renderDoctor(doc)
        XCTAssertTrue(text.contains(" · Xcode unknown\n"), text)
        XCTAssertTrue(text.contains("  settings   none: no effective settings were read (see notes) · 2 configurations"))
        XCTAssertTrue(text.contains("  offline    --offline: settings from the offline resolver"))
        XCTAssertFalse(text.contains("0 package targets"), "null is never printed as 0")
        XCTAssertTrue(text.contains("shown 2 of 21"), "PASS capped (two unset keys are unknown offline, N/A): \(text)")
        XCTAssertTrue(text.contains("shown 2 of 5 findings"), text)
        XCTAssertFalse(text.contains("fail-on"), "no verdict without --fail-on")
        XCTAssertTrue(doc.findings.allSatisfy { $0.confidence == "low" }, "offline lowers confidence")
    }

    func testFailOnVerdictAndEmptyFindings() {
        let passing = TextReporter.renderDoctor(Self.smallDoctor(failOn: "high"))
        XCTAssertTrue(passing.contains("\nfail-on high: no finding at or above high\n"), passing)
        var empty = Self.smallDoctor(failOn: nil)
        empty.findings = []
        empty.fixPlan = []
        XCTAssertTrue(TextReporter.renderDoctor(empty).contains("FINDINGS  none: 49 rules evaluated"))
    }

    func testAcmeAppDoctorTextShowsTheSuppressedListAndEditProjectSteps() {
        let doc = HTMLSample.doctor(hostileStrings: false)
        let text = TextReporter.renderDoctor(doc)
        XCTAssertTrue(text.contains("\nSUPPRESSED (1)  SET-030 deferred until PHASE-001"), text)
        XCTAssertTrue(text.contains("PLAN  Commit your changes first"), text)
        // SET-001 is shadowed for the hook by the project settings: cli delivery, then the change by hand for Xcode.
        XCTAssertTrue(text.contains("      1. `xcblame verify --rules SET-001 --kind clean --mechanism cli`\n      2. by hand in Xcode: Build Settings › Compilation Mode"), text)
        XCTAssertTrue(text.contains("      --edit-project is not available yet: make those changes by hand (the 'by hand' steps)"), text)
        XCTAssertTrue(text.contains("`xcblame fix --rules PHASE-002 --edit-project` (not available yet: make the change by hand)"), text)
        XCTAssertTrue(text.contains("by hand in Xcode: Target Acme › Build Phases › Run Script"), "manual steps are in the plan")
        XCTAssertTrue(text.contains("  generator  none → project edits allowed with --edit-project"))
        XCTAssertTrue(text.contains("x 4 targets + 0 package targets"))
        for line in text.split(separator: "\n") where !line.hasPrefix("note:") && !line.contains("`") {
            XCTAssertLessThanOrEqual(line.count, 120, String(line))
        }
    }

    /// The analyze report's FINDINGS / PLAN sections appear only when rules produced findings (DESIGN §3.3).
    func testAnalyzeTextFindingsSection() throws {
        var doc = try ReportPipeline.run(SyntheticModel.make()).document
        XCTAssertFalse(TextReporter.render(doc).contains("FINDINGS"), "no rule run, v0.2 layout")
        let model = RulesFixtures.acmeApp()
        let result = RulesFixtures.run(RulesFixtures.context(model, env: nil, analysis: nil, document: nil))
        doc.merge(rules: result, project: model, settings: [:], configurations: ["Release"], offline: false)
        doc.topN = 3
        let text = TextReporter.render(doc)
        XCTAssertTrue(text.contains("FINDINGS 3 of \(result.findings.count)"), text)
        XCTAssertTrue(text.contains("  ~M  SET-001  SWIFT_COMPILATION_MODE = wholemodule"), text)  // catalog estimate, not measured
        XCTAssertTrue(text.contains("shown 3 of \(result.findings.count) findings"))
        XCTAssertTrue(text.contains("PLAN  Commit your changes first"), text)
        XCTAssertTrue(text.contains("`xcblame verify --rules SET-001 --kind clean --mechanism cli`\n"), "a plain, runnable command: \(text)")
        let findings = try XCTUnwrap(text.range(of: "FINDINGS")), checks = try XCTUnwrap(text.range(of: "\nchecks "))
        XCTAssertLessThan(findings.lowerBound, checks.lowerBound)
    }
}
