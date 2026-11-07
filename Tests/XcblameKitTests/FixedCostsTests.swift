import XCTest
@testable import XcblameKit

/// Fixed costs (DESIGN §6.8, docs/SCHEMA-v0.5.md "Fixed costs"): basis (a) a zero-change build's executed tasks, (b)
/// history frequency, (c) static classes; per day on config, history or the labelled 50-builds assumption.
final class FixedCostsTests: XCTestCase {
    static let zeroChange26 = SLFFixtures.root.appendingPathComponent(
        "cli-xcode26-why/CEEF88A0-5057-4971-91D3-A07C8E6E6536.xcactivitylog")
    static let zeroChange27 = SLFFixtures.root.appendingPathComponent(
        "cli-xcode27.1b-why/CA2F66C2-23AC-45B9-8706-CF30D41B6C2F.xcactivitylog")

    private func assertEveryTaskClassified(_ url: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let model = try GraphFixtures.model(url)
        let document = try GraphFixtures.report(model).document
        guard document.build.kind == "zero-change" else {
            throw XCTSkip("\(url.lastPathComponent) is \(document.build.kind ?? "unclassified"), not zero-change")
        }
        let rows = try XCTUnwrap(document.fixedCosts, file: file, line: line)
        XCTAssertTrue(rows.allSatisfy { $0.basis == "zeroChange" && $0.perDayBasis == "assumed" && $0.perDayAssumedBuilds == 50 },
                      file: file, line: line)
        let executed = Timing.timeline(model).counted
        XCTAssertEqual(rows.filter { $0.class != "outsideLog" }.reduce(0) { $0 + $1.tasksTotal }, executed.count,
                       "every executed task in exactly one class", file: file, line: line)
        let total = rows.compactMap(\.seconds).reduce(0, +)
        let other = rows.first { $0.class == "other" }?.seconds ?? 0
        XCTAssertLessThanOrEqual(other, 0.1 * total, "unknown class above 10 %", file: file, line: line)
        for row in rows { XCTAssertEqual(row.perDay ?? -1, ReportDocument.round6((row.seconds ?? 0) * 50), accuracy: 1e-6) }
    }

    func testZeroChangeBuildsClassifyEveryExecutedTask() throws {
        try assertEveryTaskClassified(Self.zeroChange26)
        let document = try GraphFixtures.report(try GraphFixtures.model(Self.zeroChange26)).document
        let rows = try XCTUnwrap(document.fixedCosts)
        XCTAssertEqual(rows.map(\.class), ["planning", "sdkStatCache"])
        XCTAssertEqual(rows[0].tasksTotal, 7)
        XCTAssertEqual(rows[0].seconds ?? 0, 0.218, accuracy: 0.001)
        XCTAssertEqual(rows[1].seconds ?? 0, 0.049, accuracy: 0.001)
        XCTAssertEqual(rows[1].tasks.first?.label, "ClangStatCache")
    }

    func testZeroChangeBuildOfXcode27() throws {
        try assertEveryTaskClassified(Self.zeroChange27)
    }

    func testOutOfLogTimeOfAZeroChangeBuild() throws {
        let model = try GraphFixtures.model(Self.zeroChange26)
        let span = Timing.analyze(model).span
        let document = try ReportPipeline.run(model, options: .init(generatedAt: Date(timeIntervalSince1970: 0),
                                                                    processWall: span + 2.5)).document
        let outside = try XCTUnwrap(document.fixedCosts?.first { $0.class == "outsideLog" })
        XCTAssertEqual(outside.seconds ?? 0, 2.5, accuracy: 1e-6)
        XCTAssertEqual(outside.basis, "zeroChange")
        XCTAssertEqual(outside.tasksTotal, 0)
        XCTAssertEqual(document.fixedCosts?.first?.class, "outsideLog", "largest first")
    }

    func testCleanBuildHasStaticPlanningAndStatCacheRows() throws {
        let model = try GraphFixtures.model(GraphFixtures.cleanDD)
        let document = try GraphFixtures.report(model).document
        let rows = try XCTUnwrap(document.fixedCosts)
        XCTAssertEqual(rows.map(\.class), ["planning", "sdkStatCache"])
        XCTAssertTrue(rows.allSatisfy { $0.basis == "static" })
        // DESIGN §6.8 (OBS-14, another AcmeApp clean build): planning 1.8 s and SDK stat cache 1.8 s.
        XCTAssertEqual(rows[0].seconds ?? 0, 1.598, accuracy: 0.001)
        XCTAssertEqual(rows[1].seconds ?? 0, 1.523, accuracy: 0.001)
    }

    func testSyntheticBuildListsItsScriptPhaseAsStaticAndCapsTasks() throws {
        // Code review v0.5: a script phase is a static fixed cost only when it declares no outputs; Xcode's warning
        // says so in the log (or the project does). Without either, it ran because an input changed.
        let plain = try XCTUnwrap(try ReportPipeline.run(SyntheticModel.make(),
                                                         options: .init(generatedAt: Date(timeIntervalSince1970: 0)))
            .document.fixedCosts)
        XCTAssertEqual(plain.map(\.class), ["planning", "sdkStatCache"])
        let model = Self.syntheticWithEveryBuildScript()
        let rows = try XCTUnwrap(try ReportPipeline.run(model,
                                                        options: .init(topN: 1, generatedAt: Date(timeIntervalSince1970: 0)))
            .document.fixedCosts)
        XCTAssertEqual(rows.map(\.class), ["scripts", "planning", "sdkStatCache"])
        let planning = rows[1]
        XCTAssertEqual(planning.tasksTotal, 2)
        XCTAssertEqual(planning.tasks.map(\.label), ["CreateBuildDescription"])
        XCTAssertEqual(planning.tasksShownShare ?? 0, 1.25 / 1.5, accuracy: 1e-6)
        XCTAssertEqual(planning.seconds, 1.5, "totals are computed before the cap")
    }

    /// `SyntheticModel.make()` whose `Lint` script phase carries Xcode's "will be run during every build" warning.
    static func syntheticWithEveryBuildScript() -> BuildModel {
        var model = SyntheticModel.make()
        guard let script = model.tasks.firstIndex(where: { $0.ruleName == "PhaseScriptExecution" }) else { return model }
        model.diagnostics.append(Diagnostic(
            id: model.diagnostics.count, severity: .warning,
            text: "Run script build phase 'Lint' will be run during every build because it does not specify any outputs.",
            category: nil, file: nil, line: nil, column: nil, endLine: nil, endColumn: nil, occurrences: 1,
            taskIds: [model.tasks[script].id]))
        model.tasks[script].diagnosticIds.append(model.diagnostics.count - 1)
        return model
    }

    func testClassMapping() {
        func cls(_ rule: String, _ kind: TaskKind, macro: Bool = false) -> String {
            FixedCosts.fixedCostClass(rule: rule, kind: kind, macroTarget: macro)
        }
        XCTAssertEqual(cls("PhaseScriptExecution", .script), "scripts")
        XCTAssertEqual(cls("CodeSign", .codesign), "codesign")
        XCTAssertEqual(cls("ValidateEmbeddedBinary", .validate), "validate")
        XCTAssertEqual(cls("CopySwiftLibs", .copy), "embedCopy")
        XCTAssertEqual(cls("ProcessInfoPlistFile", .resources), "infoPlist")
        XCTAssertEqual(cls("ExtractAppIntentsMetadata", .metadata), "appIntents")
        XCTAssertEqual(cls("RegisterExecutionPolicyException", .aux), "executionPolicy")
        XCTAssertEqual(cls("CreateBuildDescription", .planning), "planning")
        XCTAssertEqual(cls("ClangStatCache", .sdkStatCache), "sdkStatCache")
        XCTAssertEqual(cls("ResolvePackageGraph", .packageResolution), "packageResolution")
        XCTAssertEqual(cls("SwiftDriver", .swiftPlan), "swiftPlanning")
        XCTAssertEqual(cls("SwiftCompile", .swiftCompile, macro: true), "macroBuilds")
        XCTAssertEqual(cls("WriteAuxiliaryFile", .aux), "other")
    }

    // MARK: - History

    private func entry(daysAgo: Double, scheme: String? = "App", kind: String = "incremental",
                       rows: [History.TaskIndexRow] = []) -> FixedCosts.HistoryEntry {
        .init(time: Self.now.addingTimeInterval(-daysAgo * 86_400), scheme: scheme, kind: kind, rows: rows)
    }

    private func row(_ rule: String, _ kind: String, ms: Int, target: String = "App") -> History.TaskIndexRow {
        .init(key: "P0:\(target):\(rule)", rule: rule, target: target, kind: kind, sigDigest: "d", durationMs: ms,
              onPath: false)
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func document(scheme: String? = "App") throws -> ReportDocument {
        var document = try ReportPipeline.run(Self.syntheticWithEveryBuildScript(), options: .init(generatedAt: Self.now))
            .document
        document.build.scheme = scheme
        return document
    }

    func testHistoryFrequencyAddsClassesSeenInMoreThan80PercentOfIncrementalBuilds() throws {
        var entries: [FixedCosts.HistoryEntry] = []
        for i in 0..<6 {
            var rows = [row("PhaseScriptExecution", "script", ms: 1800 + 100 * i), row("SwiftCompile", "swiftCompile", ms: 900)]
            if i < 5 { rows.append(row("CodeSign", "codesign", ms: 300 + 10 * i)) }  // 5 of 6 = 83 %
            if i < 4 { rows.append(row("Copy", "copy", ms: 50)) }                     // 4 of 6 = 67 %
            entries.append(entry(daysAgo: Double(i) * 0.1, kind: i % 2 == 0 ? "incremental" : "zero-change", rows: rows))
        }
        entries.append(entry(daysAgo: 0.2, kind: "clean", rows: [row("Copy", "copy", ms: 50)]))
        entries.append(entry(daysAgo: 0.3, scheme: "Other", rows: [row("Copy", "copy", ms: 50)]))
        let out = FixedCosts.applying(entries: entries, configBuildsPerDay: nil, to: try document())
        let rows = try XCTUnwrap(out.fixedCosts)
        let codesign = try XCTUnwrap(rows.first { $0.class == "codesign" })
        XCTAssertEqual(codesign.basis, "historyFrequency")
        XCTAssertEqual(codesign.seconds ?? 0, 0.32, accuracy: 1e-9, "median of 300...340 ms")
        XCTAssertNil(codesign.tasks.first?.taskId)
        XCTAssertNil(rows.first { $0.class == "embedCopy" }, "67 % is not > 80 %")
        XCTAssertNil(rows.first { $0.class == "other" || $0.class == "swiftPlanning" })
        XCTAssertEqual(rows.first { $0.class == "scripts" }?.basis, "static", "this build's measured row wins")
        XCTAssertTrue(out.notes.contains { $0.hasPrefix("fixedCosts: historyFrequency rows from 6 non-clean build(s)") })

        let few = FixedCosts.applying(entries: Array(entries.prefix(4)), configBuildsPerDay: nil, to: try document())
        XCTAssertNil(few.fixedCosts?.first { $0.basis == "historyFrequency" }, "fewer than 5 builds")
        let otherScheme = FixedCosts.applying(entries: entries, configBuildsPerDay: nil, to: try document(scheme: "Lib"))
        XCTAssertNil(otherScheme.fixedCosts?.first { $0.basis == "historyFrequency" })
    }

    func testBuildsPerDayFromHistoryDates() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let noon = calendar.startOfDay(for: Self.now).addingTimeInterval(12 * 3600)
        var entries: [FixedCosts.HistoryEntry] = []
        func add(_ count: Int, daysAgo: Int) {
            for i in 0..<count {
                entries.append(.init(time: noon.addingTimeInterval(Double(-daysAgo * 86_400 + i * 60)), scheme: "App",
                                     kind: "incremental", rows: []))
            }
        }
        add(4, daysAgo: 1)
        add(6, daysAgo: 2)
        add(10, daysAgo: 3)
        add(30, daysAgo: 20)  // outside the 14 days
        // 20 builds on 3 active days: 6.7 per active day (the median day would say 6, a 14-day mean 1.4).
        XCTAssertEqual(FixedCosts.buildsPerDay(entries: entries, now: noon, calendar: calendar), 7)
        XCTAssertNil(FixedCosts.buildsPerDay(entries: Array(entries.prefix(4)), now: noon, calendar: calendar),
                     "fewer than 5 builds in the window")

        let rebased = FixedCosts.applying(entries: entries, configBuildsPerDay: nil, to: try document())
        let rows = try XCTUnwrap(rebased.fixedCosts)
        XCTAssertTrue(rows.allSatisfy { $0.perDayBasis == "history" && $0.perDayAssumedBuilds > 0 })
        for row in rows { XCTAssertEqual(row.perDay ?? 0, (row.seconds ?? 0) * Double(row.perDayAssumedBuilds), accuracy: 1e-6) }
        let configured = FixedCosts.applying(entries: entries, configBuildsPerDay: 30, to: try document())
        XCTAssertTrue(try XCTUnwrap(configured.fixedCosts).allSatisfy { $0.perDayBasis == "config" && $0.perDayAssumedBuilds == 30 })
    }

    func testConfigFileAndTheEndToEndEntryPoint() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-fc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("config.json")
        for (text, expected) in [(#"{"buildsPerDay": 30}"#, 30), (#"{"buildsPerDay": 0}"#, nil), (#"{"buildsPerDay": 2.5}"#, nil),
                                 (#"{"buildsPerDay": true}"#, nil), (#"{"buildsPerDay": "9"}"#, nil), ("{", nil)] as [(String, Int?)] {
            try Data(text.utf8).write(to: config)
            XCTAssertEqual(FixedCosts.buildsPerDay(config: config), expected, text)
        }
        try Data(#"{"buildsPerDay": 12}"#.utf8).write(to: config)
        let history = dir.appendingPathComponent("history")
        let out = FixedCosts.applyingHistory(to: try document(), historyDir: history, configURL: config)
        XCTAssertTrue(try XCTUnwrap(out.fixedCosts).allSatisfy { $0.perDayBasis == "config" && $0.perDayAssumedBuilds == 12 })
        let none = FixedCosts.applyingHistory(to: try document(), historyDir: history, configURL: nil)
        XCTAssertTrue(try XCTUnwrap(none.fixedCosts).allSatisfy { $0.perDayBasis == "assumed" && $0.perDayAssumedBuilds == 50 })
        var withheld = try document()
        withheld.fixedCosts = nil
        XCTAssertEqual(FixedCosts.applyingHistory(to: withheld, historyDir: history, configURL: config), withheld)
    }

    func testHistoryEntriesAreReadFromSavedReports() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-fch-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let model = SyntheticModel.make()
        var document = try ReportPipeline.run(model, options: .init(generatedAt: Self.now)).document
        document.build.scheme = "App"
        _ = try History.save(document: document, model: model, directory: dir)
        let entries = FixedCosts.loadHistory(dir)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.scheme, "App")
        XCTAssertEqual(entries.first?.kind, "clean")
        XCTAssertEqual(entries.first?.rows.count, Timing.timeline(model).counted.count)
    }
}
