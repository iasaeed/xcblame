import XCTest
@testable import XcblameKit

final class CompareTests: XCTestCase {
    private var a: CompareFixtures.Build { CompareFixtures.xcode26 }
    private var b: CompareFixtures.Build { CompareFixtures.xcode27 }

    private func compare(_ options: Compare.Options = .init(), rows: Bool = true) throws -> CompareDocument {
        try Compare.run(a: .init(source: "a.xcactivitylog", documents: [a.document], taskRows: rows ? [a.rows] : nil),
                        b: .init(source: "b.xcactivitylog", documents: [b.document], taskRows: rows ? [b.rows] : nil),
                        options: options)
    }

    private func deepRun(enabled: Bool = true) -> ReportDocument.Deep {
        .init(enabled: enabled, scope: ["swift"], flagsInjected: ["-ftime-trace"], flagsDropped: [], shadowed: [],
              derivedData: "/cache/deep/abc", derivedDataBytes: nil, wrapper: nil, exactFiles: nil, sources: nil, notes: [])
    }

    /// An ordinary build against a `build --deep` run (either side) carries the note, in the document and the text
    /// headline; two ordinary builds, two deep builds and a deep build that was disabled carry none.
    func testDeepAgainstOrdinaryBuildIsNoted() throws {
        let plain = try CompareFixtures.report(span: 10)
        var deep = try CompareFixtures.report(span: 12)
        deep.deep = deepRun()
        func compare(_ x: ReportDocument, _ y: ReportDocument) throws -> CompareDocument {
            try Compare.run(a: .init(source: "a", documents: [x]), b: .init(source: "b", documents: [y]))
        }
        let suffix = "is a build --deep run: timing flags were injected, so its task times can be slower than a normal build"
        let bDeep = try compare(plain, deep)
        XCTAssertEqual(bDeep.notes.filter { $0.hasSuffix(suffix) }, ["b " + suffix])
        let text = CompareTextReporter.render(bDeep)
        XCTAssertEqual(text.components(separatedBy: suffix).count - 1, 1, "once, in the headline: \(text)")
        XCTAssertLessThan(try XCTUnwrap(text.range(of: suffix)).lowerBound, try XCTUnwrap(text.range(of: "RESULT")).lowerBound)
        XCTAssertEqual(try compare(deep, plain).notes.filter { $0.hasSuffix(suffix) }, ["a " + suffix])
        XCTAssertTrue(try compare(plain, plain).notes.allSatisfy { !$0.contains("--deep") })
        XCTAssertTrue(try compare(deep, deep).notes.allSatisfy { !$0.contains("--deep") })
        var disabled = plain
        disabled.deep = deepRun(enabled: false)
        XCTAssertTrue(try compare(plain, disabled).notes.allSatisfy { !$0.contains("--deep") },
                      "a deep build that ran without the flags is an ordinary build")
    }

    func testXcodeDifferenceIsTheFirstEnvironmentDifference() throws {
        let doc = try compare()
        XCTAssertEqual(doc.env.first?.field, "xcode")
        XCTAssertEqual(doc.env.first?.a, "26.0")
        XCTAssertEqual(doc.env.first?.b, "27.1")
        XCTAssertEqual(doc.a.xcode, "26.0")
        XCTAssertEqual(doc.b.xcode, "27.1")
        XCTAssertEqual(doc.regression.attribution.first?.kind, "env")
        XCTAssertEqual(doc.regression.attribution.first?.subject, "xcode")
        // Both logs are clean builds with no environment snapshot: only the Xcode version and the tool-less fields compare.
        XCTAssertEqual(doc.env.map(\.field), ["xcode"])
        XCTAssertEqual(doc.envCompared, 3, "kind, xcode and toolVersion are known on both sides")
        XCTAssertEqual(doc.schemaVersion, "xcblame.compare/1")
        XCTAssertEqual(doc.regression.baseline.source, "report")
        XCTAssertEqual(doc.regression.baseline.ref, "a.xcactivitylog")
        XCTAssertEqual(doc.regression.verdict, "indicative")
        XCTAssertGreaterThan(doc.regression.wall.delta ?? 0, 0)
    }

    func testEnvironmentFieldOrderAndKnownOnBothSides() throws {
        var x = try CompareFixtures.report(span: 10)
        var y = try CompareFixtures.report(span: 11, xcode: "26.1")
        x.environment = EnvSnapshot()
        y.environment = EnvSnapshot()
        x.environment?.hwModel = "Mac14,2"
        y.environment?.hwModel = "Mac15,14"
        x.environment?.logicalCPUCount = 8
        y.environment?.logicalCPUCount = 28
        x.environment?.memoryBytes = 16 << 30
        y.environment?.memoryBytes = 96 << 30
        x.environment?.macOSProductVersion = "26.0"
        y.environment?.macOSProductVersion = "26.1"
        x.environment?.xcodebuildVersion = "Xcode 26.0\nBuild version 17A324"
        y.environment?.xcodebuildVersion = "Xcode 26.1\nBuild version 17B1"
        x.environment?.processTranslated = false
        y.environment?.git = GitInfo(branch: "main", commit: String(repeating: "b", count: 40), dirty: true)
        x.environment?.git = GitInfo(branch: "feature", commit: String(repeating: "a", count: 40), dirty: false)
        y.tool.version = XcblameVersion.current + "+next"
        let doc = try Compare.run(a: .init(source: "a", documents: [x]), b: .init(source: "b", documents: [y]))
        XCTAssertEqual(doc.env.map(\.field), ["xcode", "xcodeSelected", "macOS", "hwModel", "cores", "memGB", "ciProvider",
                                              "branch", "commit", "dirty", "toolVersion"].filter { $0 != "ciProvider" })
        XCTAssertEqual(doc.env.first { $0.field == "xcodeSelected" }?.b, "26.1 (17B1)")
        XCTAssertEqual(doc.env.first { $0.field == "memGB" }?.a, "16")
        XCTAssertEqual(doc.a.machine, "Mac14,2/8c/16g")
        XCTAssertEqual(doc.b.machine, "Mac15,14/28c/96g")
        // A field known on one side only (rosetta) is not compared, so it cannot differ.
        XCTAssertNil(doc.env.first { $0.field == "rosetta" })
        // The attribution lists the environment before anything else.
        XCTAssertEqual(doc.regression.attribution.prefix(5).map(\.kind), Array(repeating: "env", count: 5))
        XCTAssertEqual(doc.regression.attribution.first?.subject, "xcode")
    }

    func testPhasesTargetsAndPathPartitionAndSortByDelta() throws {
        let doc = try compare()
        let phases = try XCTUnwrap(doc.phases)
        XCTAssertEqual(phases.first?.key, "compile")
        XCTAssertEqual(phases.last?.isOther, true)
        XCTAssertEqual(phases.reduce(0) { $0 + ($1.seconds.a ?? 0) }, a.document.phases?.reduce(0) { $0 + $1.taskTime } ?? 0, accuracy: 1e-4)
        XCTAssertEqual(phases.first?.seconds.delta ?? 0, (b.document.phases?.first { $0.key == "compile" }?.taskTime ?? 0)
            - (a.document.phases?.first { $0.key == "compile" }?.taskTime ?? 0), accuracy: 1e-5)
        let targets = try XCTUnwrap(doc.targets)
        XCTAssertEqual(doc.targetsTotal, 13)
        XCTAssertEqual(targets.count, 13)
        let deltas = targets.filter { !$0.isOther }.map { abs($0.seconds.delta ?? 0) }
        XCTAssertEqual(deltas, deltas.sorted(by: >))
        XCTAssertEqual(doc.targetsShownShare, 1)
        let path = try XCTUnwrap(doc.criticalPath)
        XCTAssertEqual(path.span.a ?? 0, a.document.criticalPath?.span ?? -1, accuracy: 1e-6)
        XCTAssertEqual(path.byTarget.reduce(0) { $0 + ($1.seconds.a ?? 0) }, path.span.a ?? 0, accuracy: 0.01,
                       "segments and waits make up the whole path")
        XCTAssertNil(path.byTarget.first?.tasks)
        XCTAssertTrue(path.byTarget.contains { $0.status == "removed" || $0.status == "added" || $0.status == "changed" })
    }

    func testTargetCapFoldsTheRestIntoOtherAndRecordsTheStep() throws {
        let doc = try compare(.init(top: 3))
        let targets = try XCTUnwrap(doc.targets)
        XCTAssertEqual(targets.count, 4, "three rows and the other row")
        XCTAssertEqual(targets.last?.isOther, true)
        XCTAssertEqual(doc.targetsTotal, 13)
        let full = try compare()
        for pick in [\CompareDocument.Row.seconds] {
            XCTAssertEqual(targets.reduce(0) { $0 + ($1[keyPath: pick].a ?? 0) }, try XCTUnwrap(full.targets).reduce(0) { $0 + ($1[keyPath: pick].a ?? 0) }, accuracy: 1e-4)
            XCTAssertEqual(targets.reduce(0) { $0 + ($1[keyPath: pick].b ?? 0) }, try XCTUnwrap(full.targets).reduce(0) { $0 + ($1[keyPath: pick].b ?? 0) }, accuracy: 1e-4)
        }
        let share = try XCTUnwrap(doc.targetsShownShare)
        XCTAssertGreaterThan(share, 0)
        XCTAssertLessThan(share, 1)
        XCTAssertEqual(doc.truncation.steps.first { $0.step == "targets" }?.kept, 4)
        XCTAssertEqual(doc.truncation.steps.first { $0.step == "targets" }?.total, 13)
        XCTAssertTrue(doc.truncation.steps.contains { $0.step == "tasks" })
        XCTAssertEqual(doc.tasks.added.count, 3)
        XCTAssertGreaterThan(doc.tasks.addedTotal, 3)
        XCTAssertLessThan(doc.tasks.addedShownShare ?? 2, 1)
    }

    func testTaskMultisetDiff() throws {
        let x = CompareFixtures.row("SwiftCompile", "App", "xx", ms: 3000, onPath: true)
        let y = CompareFixtures.row("Ld", "App", "yy", ms: 500)
        let z = CompareFixtures.row("CopyPNG", "Kit", "zz", ms: 700)
        // a: X, X, Y   b: X, Z   ->   the second X and Y are gone, Z is new.
        let diff = CompareDiffs.taskDiff(a: [x, CompareFixtures.row("SwiftCompile", "App", "xx", ms: 1000), y], b: [x, z])
        XCTAssertEqual(diff.added.map(\.rule), ["CopyPNG"])
        XCTAssertEqual(diff.removed.map(\.rule), ["SwiftCompile", "Ld"])
        XCTAssertEqual(diff.removed.first?.seconds, 1, "the shorter of the two equal tasks is the one reported")
        XCTAssertEqual(diff.added.first?.seconds, 0.7)
        XCTAssertEqual(diff.added.first?.target, "Kit")
        // The same rows on both sides: nothing.
        let none = CompareDiffs.taskDiff(a: [x, y, z], b: [z, y, x])
        XCTAssertTrue(none.added.isEmpty && none.removed.isEmpty)
        // Through Compare.run: totals, shares and the attribution entries.
        let report = try CompareFixtures.report(span: 10)
        let doc = try Compare.run(a: .init(source: "a", documents: [report], taskRows: [[x, y]]),
                                  b: .init(source: "b", documents: [report], taskRows: [[x, z]]))
        XCTAssertTrue(doc.tasks.available)
        XCTAssertEqual(doc.tasks.addedTotal, 1)
        XCTAssertEqual(doc.tasks.removedTotal, 1)
        XCTAssertEqual(doc.tasks.addedShownShare, 1)
        XCTAssertEqual(doc.regression.attribution.filter { $0.kind == "task" }.map(\.subject), ["Kit: CopyPNG", "App: Ld"])
    }

    func testTasksNeedRowsOnBothSides() throws {
        let doc = try compare(rows: false)
        XCTAssertFalse(doc.tasks.available)
        XCTAssertEqual(doc.tasks.addedTotal, 0)
        XCTAssertTrue(doc.tasks.notes.first?.contains("saved report") == true, "\(doc.tasks.notes)")
        // One side with rows is not enough.
        let half = try Compare.run(a: .init(source: "a", documents: [a.document], taskRows: [a.rows]),
                                   b: .init(source: "b", documents: [b.document]))
        XCTAssertFalse(half.tasks.available)
        XCTAssertTrue(half.tasks.notes.first?.contains("b has none") == true)
        XCTAssertFalse(doc.regression.attribution.contains { $0.kind == "task" })
    }

    func testSettingsFromFindingEvidence() throws {
        func finding(_ items: [ReportDocument.EvidenceItem]) -> ReportDocument.Finding {
            .init(ruleId: "SET-016", title: "t", severity: "medium", impactBand: nil, impactSeconds: nil, impactBasis: nil,
                  confidence: "high", evidence: items.map(\.ref), fixKind: nil, risk: nil, mechanism: nil, signalKey: "k",
                  evidenceDetails: items)
        }
        var x = try CompareFixtures.report(span: 10)
        var y = try CompareFixtures.report(span: 10)
        x.findings = [finding([.init(kind: "setting", ref: "App:Debug:SWIFT_COMPILATION_MODE", value: "singlefile", provenance: "project"),
                               .init(kind: "setting", ref: "App:Debug:ONLY_ACTIVE_ARCH", value: "YES", provenance: "project"),
                               .init(kind: "phase", ref: "compile")])]
        y.findings = [finding([.init(kind: "setting", ref: "App:Debug:SWIFT_COMPILATION_MODE", value: "wholemodule", provenance: "xcconfig"),
                               .init(kind: "setting", ref: "App:Debug:ONLY_ACTIVE_ARCH", value: "YES", provenance: "project"),
                               .init(kind: "setting", ref: "App:Debug:EXTRA", value: "1", provenance: nil)])]
        let doc = try Compare.run(a: .init(source: "a", documents: [x]), b: .init(source: "b", documents: [y]))
        let settings = try XCTUnwrap(doc.settings)
        XCTAssertEqual(settings.map(\.ref), ["App:Debug:EXTRA", "App:Debug:SWIFT_COMPILATION_MODE"], "equal settings are not listed")
        XCTAssertEqual(settings[1].a, "singlefile")
        XCTAssertEqual(settings[1].b, "wholemodule")
        XCTAssertEqual(settings[1].provenanceA, "project")
        XCTAssertEqual(settings[1].provenanceB, "xcconfig")
        XCTAssertNil(settings[0].a)
        XCTAssertEqual(doc.regression.attribution.last?.kind, "setting")
        // No evidence on either side: null, with a note.
        let none = try compare()
        XCTAssertNil(none.settings)
        XCTAssertTrue(none.notes.contains { $0.hasPrefix("settings:") })
    }

    func testBuildsThatDoNotCompareAreRefused() throws {
        let x = try CompareFixtures.report(span: 10)
        let y = try CompareFixtures.report(span: 10, scheme: "Other")
        XCTAssertThrowsError(try Compare.run(a: .init(source: "a", documents: [x]), b: .init(source: "b", documents: [y]))) { error in
            guard case let XcblameError.usage(message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("scheme"), message)
        }
        XCTAssertThrowsError(try Compare.run(a: .init(source: "a", documents: []), b: .init(source: "b", documents: [y])))
    }

    func testSeveralRunsPerSideGiveABandAndUseTheMedianRun() throws {
        let xs = try CompareFixtures.reports([10, 10.1, 9.9]), ys = try CompareFixtures.reports([12, 12.1, 11.9])
        let doc = try Compare.run(a: .init(source: "a", documents: xs), b: .init(source: "b", documents: ys),
                                  options: .init(thresholdPct: 0.05))
        XCTAssertEqual(doc.regression.verdict, "slower")
        XCTAssertTrue(doc.regression.failed)
        XCTAssertEqual(doc.a.runs, 3)
        XCTAssertEqual(doc.a.wall, 10)
        XCTAssertEqual(doc.regression.noiseBand.method, "mad")
        XCTAssertTrue(doc.notes.contains { $0.contains("closest to the median") })
    }

    func testJSONIsByteStableAndRoundTrips() throws {
        let first = try Compare.renderJSON(try compare())
        let second = try Compare.renderJSON(try compare())
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.last, UInt8(ascii: "\n"))
        let decoded = try JSONReporter.decoder().decode(CompareDocument.self, from: first)
        XCTAssertEqual(try Compare.renderJSON(decoded), first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["a", "b", "criticalPath", "env", "envCompared", "generatedAt", "notes", "phases", "redacted",
                                          "regression", "schemaVersion", "settings", "targets", "targetsShownShare", "targetsTotal",
                                          "tasks", "tool", "truncation"])
        XCTAssertTrue(object["settings"] is NSNull)
        // Keys are sorted: "a" comes before "b" before "criticalPath".
        let text = String(decoding: first, as: UTF8.self)
        XCTAssertLessThan(try XCTUnwrap(text.range(of: "\"a\" : {")).lowerBound, try XCTUnwrap(text.range(of: "\"b\" : {")).lowerBound)
    }

    func testRedactorOverloadAppliesToTheSources() throws {
        var doc = try compare()
        doc.a.source = "/Users/zed/work/a.xcactivitylog"
        doc.regression.baseline.ref = "/Users/zed/work/a.xcactivitylog"
        let redacted = try Redactor.redact(doc, context: .init(home: "/Users/zed", user: "zed", host: "mbp.local"))
        XCTAssertTrue(redacted.redacted)
        XCTAssertEqual(redacted.a.source, "~/work/a.xcactivitylog")
        XCTAssertEqual(redacted.regression.baseline.ref, "~/work/a.xcactivitylog")
        XCTAssertFalse(doc.redacted)
    }

    func testTextReporterLeadsWithTheHeadlineThenTheEnvironment() throws {
        let text = CompareTextReporter.render(try compare(.init(thresholdPct: 0.05)))
        let positions = ["RESULT  indicative", "noise band", "threshold 5 % + 5 % allowance (indicative): FAILED", "why  env xcode",
                         "ENVIRONMENT  1 of 3", "xcode  26.0 -> 27.1 (inferred)", "PHASES", "TARGETS", "CRITICAL PATH", "NEW TASKS"]
            .map { text.range(of: $0)?.lowerBound }
        XCTAssertFalse(positions.contains { $0 == nil }, text)
        let sorted = positions.compactMap { $0 }
        XCTAssertEqual(sorted, sorted.sorted())
        XCTAssertEqual(text, CompareTextReporter.render(try compare(.init(thresholdPct: 0.05))))
        XCTAssertFalse(text.contains("\u{1B}"))
    }

    func testTextReportShowsTheRegressionSection() throws {
        let base = try Baseline.make(from: CompareFixtures.reports([100, 100, 100]), source: .init(kind: "report", refs: ["r"]))
        var doc = try CompareFixtures.report(span: 120)
        doc.regression = try Regression.evaluate(current: CompareFixtures.reports([120, 120, 120]), baseline: base, baselineRef: ".xcblame/baseline.json",
                                                 currentTaskRows: nil, options: .init(thresholdPct: 0.05))
        let lines = TextReporter().regressionLines(doc)
        XCTAssertTrue(lines.first?.hasPrefix("REGRESSION  slower: wall +20.0 s (+20.0 %) vs baseline file .xcblame/baseline.json (3 runs, log span)") == true, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("noise band 2.0 s") }, "\(lines)")
        XCTAssertTrue(lines.contains { $0.contains("threshold 5 %: FAILED") }, "\(lines)")
        XCTAssertTrue(TextReporter.render(doc).contains("REGRESSION  slower"))
    }
}
