import XCTest
@testable import XcblameKit

/// The previous index and the `why` capture in history rows (docs/SCHEMA-v0.5.md "History task index").
final class WhyHistoryTests: XCTestCase {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-whyhist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testPreviousIndexSkipsTheOwnLogAndOtherBuildKeys() throws {
        let set = WhyFixtures.why26
        let history = try WhyFixtures.history([set.clean, set.incremental], test: self)
        let (_, incremental) = try WhyFixtures.report(set.incremental)
        let previous = try XCTUnwrap(try History.previousIndex(for: incremental, directory: history))
        XCTAssertEqual(previous.kind, "clean", "the newest entry is the incremental log itself: skipped")
        XCTAssertEqual(previous.rows.count, 575)

        var otherScheme = incremental
        otherScheme.build.scheme = "Other"
        XCTAssertNil(try History.previousIndex(for: otherScheme, directory: history))
        XCTAssertNil(try History.previousIndex(for: incremental, directory: try temp().appendingPathComponent("none")))
    }

    /// A history entry of `build --deep` for `model`'s build: every Swift command line carries the timing flags (as
    /// the wrapper injects them), the log is another one, and the document has a `deep` member (or not, `marked`).
    private func saveDeepEntry(_ model: BuildModel, _ document: ReportDocument, to dir: URL, marked: Bool = true,
                               age: Double = 1_800) throws {
        var model = model
        for index in model.tasks.indices
        where [.swiftCompile, .swiftEmitModule, .swiftPlan].contains(model.tasks[index].kind) {
            model.tasks[index].commandDetails = (model.tasks[index].commandDetails ?? "")
                + " -Xfrontend -debug-time-function-bodies -Xfrontend -stats-output-dir -Xfrontend /cache/deep/stats"
        }
        var deep = document
        deep.input.path = "/cache/deep/0123456789abcdef/Logs/Build/\(UUID().uuidString).xcactivitylog"
        deep.deep = marked ? V05Samples.deep : nil
        deep.generatedAt = Date().addingTimeInterval(-age)
        _ = try History.save(document: deep, model: model, directory: dir)
    }

    /// Code review v0.5 M1: build, build --deep, edit, build. The deep entry is never the previous build, so the
    /// edit is `inputChanged`, not every target's `settingsChanged` against the instrumented command lines.
    func testDeepBuildsAreNeverThePreviousBuild() throws {
        let set = WhyFixtures.why26
        let dir = try temp().appendingPathComponent("history")
        let (cleanModel, report) = try WhyFixtures.report(set.clean)
        var clean = report
        clean.generatedAt = Date().addingTimeInterval(-3_600)
        let cleanId = try History.save(document: clean, model: cleanModel, directory: dir).lastPathComponent
            .replacingOccurrences(of: ".json.gz", with: "")
        try saveDeepEntry(cleanModel, clean, to: dir)

        let (model, document) = try WhyFixtures.report(set.incremental)
        let attached = CauseEngine.attach(to: document, model: model, historyDir: dir, project: nil)
        let incremental = try XCTUnwrap(attached.incremental)
        XCTAssertEqual(incremental.previousBuild?.id, cleanId, "the deep entry is newer but skipped")
        XCTAssertEqual(incremental.causes.first?.class, "inputChanged")
        XCTAssertFalse(incremental.causes.contains { $0.class == "settingsChanged" }, "\(incremental.causes.map(\.id))")
        XCTAssertEqual(incremental.v15.status, "pass")
        XCTAssertEqual(incremental.notes.filter { $0.contains("is a build --deep") }.count, 1, "\(incremental.notes)")

        // Without backtraces (the remarks fixtures) the signature signal decides: against the deep entry every
        // instrumented Swift task would be `settingsChanged`; the marked entry is skipped, so none is.
        let remarks = WhyFixtures.remarks26
        let (remarksCleanModel, remarksReport) = try WhyFixtures.report(remarks.clean)
        var remarksClean = remarksReport
        remarksClean.generatedAt = Date().addingTimeInterval(-3_600)
        let (remarksModel, remarksDocument) = try WhyFixtures.report(remarks.incremental)
        for marked in [true, false] {
            let history = try temp().appendingPathComponent("history")
            _ = try History.save(document: remarksClean, model: remarksCleanModel, directory: history)
            try saveDeepEntry(remarksCleanModel, remarksClean, to: history, marked: marked)
            let causes = try XCTUnwrap(CauseEngine.attach(to: remarksDocument, model: remarksModel, historyDir: history,
                                                          project: nil).incremental).causes
            XCTAssertEqual(causes.contains { $0.class == "settingsChanged" }, !marked, "\(causes.map(\.id))")
        }

        // Only a deep entry: no previous build, and the note says why.
        let onlyDeep = try temp().appendingPathComponent("history")
        try saveDeepEntry(cleanModel, clean, to: onlyDeep)
        let alone = try XCTUnwrap(CauseEngine.attach(to: document, model: model, historyDir: onlyDeep,
                                                     project: nil).incremental)
        XCTAssertEqual(alone.basis, "currentLogOnly")
        XCTAssertTrue(alone.notes.contains { $0.contains("is a build --deep") && $0.contains("no other previous build") },
                      "\(alone.notes)")
    }

    /// Re-check major 1: a `build --deep` document compares with the previous deep build, not with a newer ordinary one.
    /// Without backtraces the signature decides, so against the ordinary build every instrumented compile would be
    /// `settingsChanged`; against the deep one the edit is `inputChanged`.
    func testDeepBuildsCompareWithTheirPreviousDeepBuild() throws {
        let remarks = WhyFixtures.remarks26
        let (cleanModel, cleanReport) = try WhyFixtures.report(remarks.clean)
        var clean = cleanReport
        clean.generatedAt = Date().addingTimeInterval(-600)
        let history = try temp().appendingPathComponent("history")
        try saveDeepEntry(cleanModel, clean, to: history, age: 3_600)
        _ = try History.save(document: clean, model: cleanModel, directory: history)
        var (model, document) = try WhyFixtures.report(remarks.incremental)
        for index in model.tasks.indices where [.swiftCompile, .swiftEmitModule, .swiftPlan].contains(model.tasks[index].kind) {
            model.tasks[index].commandDetails = (model.tasks[index].commandDetails ?? "")
                + " -Xfrontend -debug-time-function-bodies -Xfrontend -stats-output-dir -Xfrontend /cache/deep/stats"
        }
        document.deep = V05Samples.deep
        let incremental = try XCTUnwrap(CauseEngine.attach(to: document, model: model, historyDir: history, project: nil).incremental)
        let deepId = try XCTUnwrap(History.list(directory: history, details: false).last?.id, "the older entry is the deep one")
        XCTAssertEqual(incremental.previousBuild?.id, deepId, "compared with the deep build, not the newer ordinary one")
        XCTAssertFalse(incremental.causes.contains { $0.class == "settingsChanged" }, "\(incremental.causes.map(\.id))")
        XCTAssertTrue(incremental.notes.contains { $0.contains("is an ordinary build") }, "\(incremental.notes)")

        // With backtraces (why26): deep → deep incremental gives inputChanged for the edit.
        let set = WhyFixtures.why26
        let (why26CleanModel, why26Clean) = try WhyFixtures.report(set.clean)
        var older = why26Clean
        older.generatedAt = Date().addingTimeInterval(-600)
        let why26History = try temp().appendingPathComponent("history")
        try saveDeepEntry(why26CleanModel, older, to: why26History, age: 3_600)
        _ = try History.save(document: older, model: why26CleanModel, directory: why26History)
        var (why26Model, why26Document) = try WhyFixtures.report(set.incremental)
        for index in why26Model.tasks.indices where [.swiftCompile, .swiftEmitModule, .swiftPlan].contains(why26Model.tasks[index].kind) {
            why26Model.tasks[index].commandDetails = (why26Model.tasks[index].commandDetails ?? "")
                + " -Xfrontend -debug-time-function-bodies -Xfrontend -stats-output-dir -Xfrontend /cache/deep/stats"
        }
        why26Document.deep = V05Samples.deep
        let deepCauses = try XCTUnwrap(CauseEngine.attach(to: why26Document, model: why26Model, historyDir: why26History,
                                                          project: nil).incremental)
        XCTAssertEqual(deepCauses.previousBuild?.id, History.list(directory: why26History, details: false).last?.id)
        XCTAssertEqual(deepCauses.causes.first?.class, "inputChanged")
        XCTAssertFalse(deepCauses.causes.contains { $0.class == "settingsChanged" }, "\(deepCauses.causes.map(\.id))")

        // No deep entry at all: no previous build, with a note.
        let ordinaryOnly = try temp().appendingPathComponent("history")
        _ = try History.save(document: clean, model: cleanModel, directory: ordinaryOnly)
        let alone = try XCTUnwrap(CauseEngine.attach(to: document, model: model, historyDir: ordinaryOnly, project: nil).incremental)
        XCTAssertEqual(alone.basis, "currentLogOnly")
        XCTAssertTrue(alone.notes.contains { $0.contains("is an ordinary build") && $0.contains("no other previous build") }, "\(alone.notes)")
    }

    /// M1: trend, `baseline save --last n` and the fixed-cost frequency basis leave deep entries out too.
    func testDeepEntriesStayOutOfTrendBaselineAndFixedCosts() throws {
        let set = WhyFixtures.why26
        let dir = try temp().appendingPathComponent("history")
        let (model, report) = try WhyFixtures.report(set.clean)
        var clean = report
        clean.generatedAt = Date().addingTimeInterval(-3_600)
        _ = try History.save(document: clean, model: model, directory: dir)
        try saveDeepEntry(model, clean, to: dir)
        XCTAssertEqual(History.list(directory: dir, details: false).count, 2)

        XCTAssertEqual(FixedCosts.loadHistory(dir).count, 1)
        let runs = Baseline.selectHistory(directory: dir, kind: nil, count: 5)
        XCTAssertEqual(runs.entries.count, 1)
        XCTAssertNil(runs.entries.first?.document.deep)
        XCTAssertEqual(runs.deep, 1)
        let trend = try Trend.run(history: dir)
        XCTAssertEqual(trend.entriesUsed, 1)
        XCTAssertTrue(trend.notes.contains { $0.hasPrefix("1 build --deep entry left out") }, "\(trend.notes)")
    }

    /// Verifier V2: `analyze <clean> --build-description` then `why --log <incremental>` (no description, so no
    /// configuration or destination), and the reverse, find each other.
    func testPreviousIndexMatchesWithOrWithoutABuildDescription() throws {
        let set = WhyFixtures.why26
        let (model, report) = try WhyFixtures.report(set.clean)
        var clean = report
        let (_, incremental) = try WhyFixtures.report(set.incremental)
        clean.generatedAt = Date().addingTimeInterval(-3_600)
        var described = clean
        described.build.configuration = "Debug"
        described.build.destination = "macOS arm64"
        var describedIncremental = incremental
        describedIncremental.build.configuration = "Debug"
        describedIncremental.build.destination = "macOS arm64"
        for (saved, explained) in [(described, incremental), (clean, describedIncremental), (described, describedIncremental)] {
            let dir = try temp().appendingPathComponent("history")
            _ = try History.save(document: saved, model: model, directory: dir)
            let lookup = History.previousLookup(for: explained, directory: dir, logEnd: nil)
            XCTAssertNotNil(lookup.index, "\(saved.build.configuration ?? "nil") vs \(explained.build.configuration ?? "nil")")
            XCTAssertEqual(lookup.notes.contains { $0.contains("known on one side only") },
                           saved.build.configuration != explained.build.configuration, "\(lookup.notes)")
        }
        // A known, different configuration or platform is still another key.
        let dir = try temp().appendingPathComponent("history")
        _ = try History.save(document: described, model: model, directory: dir)
        var release = describedIncremental
        release.build.configuration = "Release"
        XCTAssertNil(History.previousLookup(for: release, directory: dir, logEnd: nil).index)
        var simulator = describedIncremental
        simulator.build.destination = "iOS Simulator arm64"
        XCTAssertNil(History.previousLookup(for: simulator, directory: dir, logEnd: nil).index)
        // A previous entry recorded after the analyzed log ended is named.
        let late = History.previousLookup(for: describedIncremental, directory: dir, logEnd: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(late.notes.contains { $0.hasPrefix("limit: build ") && $0.contains("recorded after this log ended") },
                      "\(late.notes)")
    }

    func testSaveWithCaptureExtendsOnlyCoveredRows() throws {
        let set = WhyFixtures.why26
        let (model, document) = try WhyFixtures.report(set.incremental)
        let rows = History.taskIndexRows(document, model)
        let keyed = try XCTUnwrap(rows.first { $0.key != nil && TaskIdentity.stableKey($0.key) != nil })
        let key = try XCTUnwrap(keyed.key)
        let capture = OutputHashes.Capture(outputs: [key: .init(hash: "0123456789abcdef", bytes: 42)],
                                           inputs: [key: ["$REPO/A.swift": "fedcba9876543210"]])
        let dir = try temp().appendingPathComponent("history")
        var saved = document
        saved.generatedAt = Date()
        let url = try History.save(document: saved, model: model, directory: dir, capture: capture)
        let shown = try History.show(id: url.lastPathComponent.replacingOccurrences(of: ".json.gz", with: ""), directory: dir)
        XCTAssertEqual(shown.taskIndexRows.count, rows.count)
        let extended = try XCTUnwrap(shown.taskIndexRows.first { $0.key == key })
        XCTAssertEqual(extended.outputHash, "0123456789abcdef")
        XCTAssertEqual(extended.outputBytes, 42)
        XCTAssertEqual(extended.inputHashes, ["$REPO/A.swift": "fedcba9876543210"])
        // Uncovered rows stay seven elements long in the stored JSON.
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: shown.json) as? [String: Any])
        let stored = try XCTUnwrap(json["taskIndexRows"] as? [[Any]])
        XCTAssertEqual(stored.filter { $0.count == 10 }.count, 1)
        XCTAssertEqual(stored.filter { $0.count == 7 }.count, rows.count - 1)
        XCTAssertNotNil(json["logId"], "the log identity survives the rewrite")
        XCTAssertEqual(shown.document.build.tasks, document.build.tasks)
        // The extended entry is a previous index like any other.
        var next = document
        next.input.path = "/elsewhere/other.xcactivitylog"
        XCTAssertEqual(try History.previousIndex(for: next, directory: dir)?.rows.first { $0.key == key }?.outputHash,
                       "0123456789abcdef")
    }

    func testCaptureHashesOutputsAndInputs() throws {
        let dir = try temp()
        let source = dir.appendingPathComponent("A.swift")
        try Data("let a = 1\n".utf8).write(to: source)
        let module = dir.appendingPathComponent("Core.swiftmodule")
        try Data("module".utf8).write(to: module)
        let abi = dir.appendingPathComponent("Core.abi.json")
        try Data("{}".utf8).write(to: abi)
        var mini = WhyFixtures.Mini()
        mini.task("SwiftEmitModule", target: "Core", title: "Emitting module for Core", key: "P0:Core:emit",
                  details: "SwiftEmitModule normal arm64 -emit-module-path \(module.path) (in target 'Core' from project 'P')")
        mini.task("SwiftCompile", target: "Core", title: "Compiling A.swift", key: "P0:Core:A",
                  details: "SwiftCompile normal arm64 Compiling\\ A.swift \(source.path) (in target 'Core' from project 'P')")
        mini.task("SwiftCompile", target: "Core", title: "Compiling B.swift",
                  details: "SwiftCompile normal arm64 \(source.path)")
        let capture = try OutputHashes.capture(model: mini.model(), derivedData: dir)
        let output = try XCTUnwrap(capture.outputs["P0:Core:emit"])
        XCTAssertEqual(output.bytes, 2, "the .abi.json sibling wins over the .swiftmodule")
        XCTAssertEqual(output.hash.count, 16)
        XCTAssertEqual(capture.inputs["P0:Core:A"]?.count, 1)
        XCTAssertEqual(capture.inputs.count, 1, "unkeyed tasks are not captured")
        try Data("let a = 2\n".utf8).write(to: source)
        let changed = try OutputHashes.capture(model: mini.model(), derivedData: dir)
        XCTAssertNotEqual(changed.inputs["P0:Core:A"], capture.inputs["P0:Core:A"])
    }
}
