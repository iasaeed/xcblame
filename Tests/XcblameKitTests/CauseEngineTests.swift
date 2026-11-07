import XCTest
@testable import XcblameKit

/// Cause attribution on the probe fixtures (docs/research/probes-v0.5.md §MV-2, §MV-8), each incremental log against
/// its clean log's index written into a temp history first.
///
/// Expected primary causes, from the probe doc: the incremental builds edited `LocalizeCore/Models.swift` (a new
/// `public func`) and `AcmeApp/TableSelectionHeader.swift` (a comment). So `Compile LocalizeCore` and everything rolled
/// up to it (its per-file compiles, `Link LocalizeCore.o`, the dependents' links through `ruleInputRebuilt` chains)
/// is `inputChanged:<…>/Models.swift`; the AcmeApp module compile and its per-file compiles are
/// `inputChanged:<…>/TableSelectionHeader.swift`; `ClangStatCache` is `forced` (configured to run in every
/// incremental build); build planning tasks are `planning`. The remarks fixtures have no backtraces: the driver
/// remarks name `Models.swift` (`Scheduling changed input`) and `LocalizeCore.swiftmodule` (`Invalidated externally`).
final class CauseEngineTests: XCTestCase {
    private func cause(of title: String, in document: ReportDocument, model: BuildModel,
                       target: String? = nil) throws -> ReportDocument.Incremental.Cause {
        let id = try XCTUnwrap(model.tasks.first { task in
            task.title == title && (target == nil || task.targetId.map { model.targets[$0].name } == target)
        }?.id, title)
        let incremental = try XCTUnwrap(document.incremental)
        return try XCTUnwrap(incremental.causes.first { $0.tasks.contains { $0.taskId == id } }, "no cause holds \(title)")
    }

    func testBacktraceFixturesAttributeEveryTask() throws {
        for set in [WhyFixtures.why26, WhyFixtures.why27] {
            let (model, document) = try WhyFixtures.attributed(set, test: self, topN: .max)
            let incremental = try XCTUnwrap(document.incremental, set.name)
            XCTAssertEqual(incremental.basis, "previousIndex")
            XCTAssertNotNil(incremental.previousBuild)
            XCTAssertEqual(incremental.v15.status, "pass", set.name)
            XCTAssertEqual(incremental.causes.last?.id, "unknown")
            XCTAssertEqual(incremental.causes.reduce(0) { $0 + $1.tasksTotal }, document.build.tasks, "one cause per task")
            XCTAssertLessThan(try XCTUnwrap(incremental.unknownShare), 0.01, set.name)

            let models = try cause(of: "Compile LocalizeCore (arm64)", in: document, model: model)
            XCTAssertEqual(models.class, "inputChanged")
            XCTAssertEqual(models.source, "backtrace")
            XCTAssertTrue(try XCTUnwrap(models.subject).hasSuffix("/Sources/LocalizeCore/Models.swift"))
            // Per-file compiles inherit the module compile task's cause (MV-2); chains roll up to their root.
            XCTAssertEqual(try cause(of: "Compiling Analyzer.swift", in: document, model: model).id, models.id)
            XCTAssertEqual(try cause(of: "Emitting module for LocalizeCore", in: document, model: model).id, models.id)
            XCTAssertEqual(try cause(of: "Link AcmeApp (arm64)", in: document, model: model).id, models.id)
            XCTAssertEqual(try cause(of: "Copy LocalizeCore.swiftmodule (arm64)", in: document, model: model).id, models.id,
                           "a copied module joins its emit-module task")
            let header = try cause(of: "Compiling StudioView.swift", in: document, model: model)
            XCTAssertTrue(try XCTUnwrap(header.subject).hasSuffix("/Sources/AcmeApp/TableSelectionHeader.swift"))
            XCTAssertEqual(try cause(of: "Compile AcmeApp (arm64)", in: document, model: model).id, header.id)
            let stat = try XCTUnwrap(model.tasks.first { $0.ruleName == "ClangStatCache" && $0.backtrace != nil })
            XCTAssertEqual(incremental.causes.first { $0.tasks.contains { $0.taskId == stat.id } }?.id, "forced:ClangStatCache")
            XCTAssertEqual(try cause(of: "Create build description", in: document, model: model).id, "planning:build planning")

            // The two rankings: every cause in each, never added together.
            XCTAssertEqual(Set(incremental.byTaskTime), Set(incremental.causes.map(\.id)))
            XCTAssertEqual(incremental.byTaskTime.first, models.id)
            XCTAssertEqual(Set(incremental.byPathSeconds), Set(incremental.causes.map(\.id)))
            XCTAssertEqual(document.validation.checks.first { $0.id == "V15" }?.status, "pass")
            XCTAssertFalse(document.notes.contains(CauseEngine.pendingNote))
        }
    }

    func testCurrentLogOnlyKeepsBacktracesAndLeavesTheRestUnknown() throws {
        let empty = try WhyFixtures.history([], test: self)
        let (model, document) = try WhyFixtures.report(WhyFixtures.why26.incremental)
        let attached = CauseEngine.attach(to: document, model: model, historyDir: empty, project: nil)
        let incremental = try XCTUnwrap(attached.incremental)
        XCTAssertEqual(incremental.basis, "currentLogOnly")
        XCTAssertNil(incremental.previousBuild)
        XCTAssertEqual(incremental.v15.status, "pass")
        XCTAssertTrue(incremental.notes.contains { $0.hasPrefix("basis: no previous build") })
        // Planning is not static evidence: without a previous index it is unknown.
        XCTAssertGreaterThan(incremental.unknownSeconds, 0)
        XCTAssertTrue(incremental.causes.contains { $0.class == "inputChanged" && $0.source == "backtrace" })
        XCTAssertTrue(incremental.causes.last!.cause.contains("why --backtraces"))
    }

    func testRemarksFixturesUseDriverRemarks() throws {
        for set in [WhyFixtures.remarks26, WhyFixtures.remarks27] {
            let (model, document) = try WhyFixtures.attributed(set, test: self, topN: .max)
            let incremental = try XCTUnwrap(document.incremental)
            XCTAssertEqual(incremental.v15.status, "pass", set.name)
            XCTAssertTrue(incremental.notes.contains { $0.hasPrefix("backtraces: none in this log") })
            let changed = try cause(of: "Compiling Models.swift", in: document, model: model)
            XCTAssertEqual(changed.class, "driverRemark")
            XCTAssertTrue(try XCTUnwrap(changed.subject).hasSuffix("/LocalizeCore/Models.swift"))
            let external = try cause(of: "Compiling StudioView.swift", in: document, model: model)
            XCTAssertEqual(external.class, "driverRemark")
            XCTAssertEqual(external.subject, "LocalizeCore.swiftmodule (newer incremental import)")
            XCTAssertLessThan(try XCTUnwrap(incremental.unknownShare), 0.2, set.name)
            XCTAssertFalse(incremental.causes.contains { $0.class == "settingsChanged" },
                           "dynamic task keys and driver command lines are no settings signal")
        }
    }

    func testCleanAndZeroChangeBuilds() throws {
        for set in [WhyFixtures.why26, WhyFixtures.why27] {
            let history = try WhyFixtures.history([set.clean], test: self)
            let (cleanModel, cleanDocument) = try WhyFixtures.report(set.clean)
            let clean = CauseEngine.attach(to: cleanDocument, model: cleanModel, historyDir: history, project: nil)
            XCTAssertNil(clean.incremental)
            XCTAssertTrue(clean.notes.contains(CauseEngine.cleanNote), "\(clean.notes)")
            XCTAssertFalse(clean.notes.contains(CauseEngine.pendingNote))
            XCTAssertEqual(clean.validation.checks.first { $0.id == "V15" }?.status, "notApplicable")

            let (model, document) = try WhyFixtures.report(set.zeroChange)
            let zero = try XCTUnwrap(CauseEngine.attach(to: document, model: model, historyDir: history, project: nil).incremental)
            XCTAssertEqual(zero.v15.status, "pass", set.name)
            XCTAssertEqual(zero.basis, "previousIndex")
        }
    }

    /// A doctor document (a project audit, `input.layout == "project"`) keeps the doctor wording; the `doctor` rules
    /// section of an analyze document does not make it one.
    func testDoctorDocumentsAndRuleSectionsAreToldApart() throws {
        let doctor = HTMLSample.doctor(hostileStrings: false)
        let model = SyntheticModel.make()
        let attached = CauseEngine.attach(to: doctor, model: model, historyDir: URL(fileURLWithPath: "/nonexistent"),
                                          project: nil)
        XCTAssertNil(attached.incremental)
        XCTAssertTrue(attached.notes.contains("incremental: null because this is a doctor document"), "\(attached.notes)")

        let set = WhyFixtures.why26
        let (incrementalModel, report) = try WhyFixtures.report(set.incremental)
        var document = report
        document.doctor = doctor.doctor
        XCTAssertNotNil(document.doctor)
        let analyzed = CauseEngine.attach(to: document, model: incrementalModel,
                                          historyDir: try WhyFixtures.history([set.clean], test: self), project: nil)
        XCTAssertEqual(analyzed.incremental?.basis, "previousIndex")
        XCTAssertFalse(analyzed.notes.contains { $0.contains("doctor document") })
    }

    /// v0.5 integration: the three previous-index limits are one note each, only when the build has tasks they touch.
    func testPreviousIndexLimitsAreNotedOnlyWhenTheyApply() throws {
        var perFileSeen = 0
        for set in WhyFixtures.all {
            let (model, document) = try WhyFixtures.attributed(set, test: self, topN: .max)
            let notes = try XCTUnwrap(document.incremental).notes
            let executed = Timing.timeline(model).counted.map(\.task)
            let clean = try WhyFixtures.report(set.clean)
            let previousKeys = Set(History.taskIndexRows(clean.document, clean.model).compactMap { TaskIdentity.stableKey($0.key) })
            let perFile = executed.filter { task in
                ["SwiftCompile", "SwiftDriverJobDiscovery"].contains(task.ruleName)
                    && TaskIdentity.stableKey(task.taskKey).map { !previousKeys.contains($0) } ?? true
            }.count
            perFileSeen += perFile
            XCTAssertEqual(notes.filter { $0.hasPrefix("limit: \(perFile) per-file Swift compile or driver job") }.count,
                           perFile > 0 ? 1 : 0, "\(set.name): \(notes)")
            XCTAssertEqual(notes.contains { $0.contains("per-file Swift compile") }, perFile > 0, set.name)
            let scripts = executed.filter { $0.kind == .script }.count
            XCTAssertEqual(notes.contains { $0.contains("script task(s) are left out") }, scripts > 0, "\(notes)")
            XCTAssertLessThanOrEqual(notes.filter { $0.contains("have no counterpart in build") }.count, 1)
        }
        XCTAssertGreaterThan(perFileSeen, 0, "driver job discovery tasks carry per-build keys")
        let empty = try WhyFixtures.history([], test: self)
        let (model, document) = try WhyFixtures.report(WhyFixtures.why26.incremental)
        let only = try XCTUnwrap(CauseEngine.attach(to: document, model: model, historyDir: empty, project: nil).incremental)
        XCTAssertFalse(only.notes.contains { $0.hasPrefix("limit:") }, "no previous index, no comparison limits")
    }

    func testProvidersAreInPrecedenceOrder() {
        XCTAssertEqual(CauseEngine.providers.map(\.source), Array(EvidenceSource.allCases.dropLast()))
        XCTAssertEqual(EvidenceSource.allCases.map(\.rawValue), ReportDocument.Incremental.sources)
        XCTAssertEqual(CauseClass.allCases.map(\.rawValue), ReportDocument.Incremental.classes)
    }
}
