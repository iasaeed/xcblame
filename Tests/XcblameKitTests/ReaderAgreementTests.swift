import Foundation
import XCTest
@testable import XcblameKit

/// DESIGN §5.7 reader agreement on the common subset: the SLF log of the Xcode 26 clean build against the
/// `xcresulttool get log --type build` JSON of the same build.
///
/// Production path only: xcresult carries the clean action as the first of two root-level containers (3 planning
/// tasks), which SLF stores in a separate log file. `BuildModelBuilder.build` excludes it (positional rule, see
/// `splitActions`); a second test shows the excluded action is exactly the SLF clean log's content.
final class ReaderAgreementTests: XCTestCase {
    private static let cleanLog = "20E8B73D-96FE-4232-8A33-311BFD02F961.xcactivitylog"
    private static let cleaningLog = "F49B68E8-5662-416D-A441-2F16BAF5D402.xcactivitylog"

    private func slfModel(_ name: String = cleanLog) throws -> BuildModel {
        let url = LaneBFixtures.root.appendingPathComponent("cli-xcode26/" + name)
        return BuildModelBuilder.build(try SLFReader.read(url: url), reader: .slf)
    }

    private func xcresultRaw() throws -> RawLog {
        try XCResultReader.read(jsonData: try LaneBFixtures.inflated("cli-xcode26/xcresult-buildlog.json.gz"))
    }

    /// The model `analyze` builds, plus the action the builder excluded.
    private func xcresultModel() throws -> (model: BuildModel, dropped: BuildModel?) {
        let raw = try xcresultRaw()
        let excluded = BuildModelBuilder.splitActions(raw, kindTable: .v1).excluded
        return (BuildModelBuilder.build(raw, reader: .xcresult), excluded.first?.model)
    }

    private struct Key: Hashable { var rule: String; var details: String }

    /// SLF writes `commandDetails` line breaks as CR, xcresult as LF; everything else is byte-identical.
    private func normalized(_ details: String?) -> String {
        (details ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    private struct Pair { var slf: BuildTask; var xc: BuildTask }

    /// Matches by (rule name, commandDetails) and start within 2 ms; per key both sides are walked in start order.
    private func match(_ slf: BuildModel, _ xc: BuildModel) -> (pairs: [Pair], onlySLF: [BuildTask], onlyXC: [BuildTask]) {
        func grouped(_ model: BuildModel) -> [Key: [BuildTask]] {
            Dictionary(grouping: model.tasks) { Key(rule: $0.ruleName, details: normalized($0.commandDetails)) }
                .mapValues { $0.sorted { $0.start < $1.start } }
        }
        let (a, b) = (grouped(slf), grouped(xc))
        var pairs: [Pair] = []
        var onlySLF: [BuildTask] = []
        var onlyXC: [BuildTask] = []
        for key in Set(a.keys).union(b.keys) {
            let left = a[key] ?? []
            let right = b[key] ?? []
            var i = 0
            var j = 0
            while i < left.count, j < right.count {
                let delta = left[i].start - right[j].start
                if abs(delta) <= 0.002 {
                    pairs.append(Pair(slf: left[i], xc: right[j]))
                    i += 1
                    j += 1
                } else if delta < 0 {
                    onlySLF.append(left[i])
                    i += 1
                } else {
                    onlyXC.append(right[j])
                    j += 1
                }
            }
            onlySLF.append(contentsOf: left[i...])
            onlyXC.append(contentsOf: right[j...])
        }
        return (pairs, onlySLF, onlyXC)
    }

    private func targetName(_ task: BuildTask, in model: BuildModel) -> String? {
        task.targetId.flatMap { model.targets.indices.contains($0) ? model.targets[$0].name : nil }
    }

    func testBuildActionAgreesWithSLF() throws {
        let slf = try slfModel()
        let (xc, dropped) = try xcresultModel()
        XCTAssertEqual(slf.tasks.count, 577)
        XCTAssertEqual(xc.tasks.count, 577, "xcresult build action; 580 with the clean action")
        XCTAssertEqual(dropped?.tasks.count, 3)
        XCTAssertEqual(xc.sessionSpan, slf.sessionSpan, accuracy: 0.005, "window is the build action's")

        let (pairs, onlySLF, onlyXC) = match(slf, xc)
        print("reader agreement: matched \(pairs.count) of \(slf.tasks.count) SLF / \(xc.tasks.count) xcresult; "
            + "only SLF \(onlySLF.count), only xcresult \(onlyXC.count)")
        XCTAssertEqual(onlySLF.count, 0, "SLF-only tasks: \(onlySLF.prefix(5).map(\.title))")
        XCTAssertEqual(onlyXC.count, 0, "xcresult-only tasks: \(onlyXC.prefix(5).map(\.title))")
        XCTAssertEqual(pairs.count, slf.tasks.count)

        // Durations within 2 ms (reported, with the worst offenders printed when any exceed).
        let deltas = pairs.map { abs($0.slf.duration - $0.xc.duration) }
        let maxDelta = deltas.max() ?? 0
        let over = pairs.filter { abs($0.slf.duration - $0.xc.duration) > 0.002 }
        let startDeltaMax = pairs.map { abs($0.slf.start - $0.xc.start) }.max() ?? 0
        print(String(format: "reader agreement: max duration delta %.3f ms, %d of %d over 2 ms; max start delta %.3f ms",
                     maxDelta * 1000, over.count, pairs.count, startDeltaMax * 1000))
        for pair in over.prefix(10) {
            print(String(format: "  over 2 ms: %@ slf %.4f s xcresult %.4f s", pair.slf.title,
                         pair.slf.duration, pair.xc.duration))
        }
        XCTAssertGreaterThanOrEqual(Double(pairs.count - over.count) / Double(pairs.count), 0.99,
                                    "at least 99% of durations within 2 ms")
        XCTAssertEqual(over.count, 0, "durations over 2 ms: \(over.prefix(5).map(\.slf.title))")

        // Same targets and kinds, task by task.
        let wrongTarget = pairs.filter { targetName($0.slf, in: slf) != targetName($0.xc, in: xc) }
        let wrongKind = pairs.filter { $0.slf.kind != $0.xc.kind }
        XCTAssertTrue(wrongTarget.isEmpty, "target differs: \(wrongTarget.prefix(5).map { "\($0.slf.title): \(targetName($0.slf, in: slf) ?? "-") vs \(targetName($0.xc, in: xc) ?? "-")" })")
        XCTAssertTrue(wrongKind.isEmpty, "kind differs: \(wrongKind.prefix(5).map { "\($0.slf.title): \($0.slf.kind) vs \($0.xc.kind)" })")
        XCTAssertEqual(slf.targets.map(\.name).sorted(), xc.targets.map(\.name).sorted())

        // Same diagnostics after dedupe: same count, same occurrences, same (severity, location, first line of text).
        // Only the first line is compared: xcresulttool flattens the nested "Explicit dependency on target" edges of
        // the `Target dependency graph` notice that SLF keeps as sub-messages, so that one notice's full text differs.
        func summary(_ model: BuildModel) -> [String] {
            model.diagnostics.map { d in
                "\(d.severity.rawValue)|\(d.file ?? "-"):\(d.line ?? 0):\(d.column ?? 0)|"
                    + (d.text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "")
            }.sorted()
        }
        XCTAssertEqual(slf.diagnostics.count, xc.diagnostics.count)
        XCTAssertEqual(summary(slf), summary(xc))
        XCTAssertEqual(slf.diagnostics.map(\.occurrences).reduce(0, +), xc.diagnostics.map(\.occurrences).reduce(0, +))
        let located = { (model: BuildModel) in Set(model.diagnostics.filter { $0.file != nil }.map(\.key)) }
        XCTAssertEqual(located(slf), located(xc), "diagnostics with a source location agree in full")
    }

    /// The 3 tasks xcresult adds are the `Cleaning` action, which SLF keeps in its own log file.
    func testCleaningContainerIsTheSeparateSLFCleanLog() throws {
        let (_, dropped) = try xcresultModel()
        let xcClean = try XCTUnwrap(dropped)
        let slfClean = try slfModel(Self.cleaningLog)
        XCTAssertEqual(xcClean.tasks.count, slfClean.tasks.count)
        let (pairs, onlySLF, onlyXC) = match(slfClean, xcClean)
        XCTAssertEqual(pairs.count, 3)
        XCTAssertTrue(onlySLF.isEmpty && onlyXC.isEmpty)
    }

    func testWholeXCResultReportsTheBuildActionAndNotesTheCleanAction() throws {
        let whole = BuildModelBuilder.build(try xcresultRaw(), reader: .xcresult)
        XCTAssertEqual(whole.tasks.count, 577)
        let note = try XCTUnwrap(whole.excludedActions?.first)
        XCTAssertTrue(note.hasPrefix("clean action (3 tasks, 0.65 s) excluded, same as a separate SLF log"), note)
        let doc = try ReportPipeline.run(whole, options: .init(generatedAt: Date(timeIntervalSince1970: 0))).document
        XCTAssertEqual(doc.input.excludedActions, [note])
        XCTAssertTrue(TextReporter.render(doc).contains("  input   clean action (3 tasks"))
    }

    /// Every action is examined: the clean action is excluded wherever it sits (re-check N2).
    func testCleanActionIsExcludedInAnyPosition() throws {
        var raw = try xcresultRaw()
        raw.root.subsections.reverse()
        let model = BuildModelBuilder.build(raw, reader: .xcresult)
        XCTAssertEqual(model.tasks.count, 577)
        XCTAssertEqual(model.excludedActions?.count, 1)
        XCTAssertEqual(model.sessionSpan, try slfModel().sessionSpan, accuracy: 0.005)
    }

    /// A planning-only action that described a build (an up-to-date build before a test action) is kept and never
    /// labelled clean; an empty action is kept too (re-check N2).
    func testPlanningOnlyBuildActionAndEmptyActionAreKept() throws {
        let raw = try xcresultRaw()
        let building = try XCTUnwrap(raw.root.subsections.last)
        let planningKinds = BuildModelBuilder.nonBuildKinds
        var upToDate = building
        upToDate.subsections = building.subsections.filter { section in
            guard let rule = BuildModelBuilder.ruleName(of: section) else { return false }
            return KindTable.v1.lookup(rule).map { planningKinds.contains($0.kind) } ?? false
        }
        XCTAssertTrue(upToDate.subsections.contains { $0.commandDetails == "CreateBuildDescription" })
        var empty = building
        empty.subsections = []
        for first in [upToDate, empty] {
            var tree = raw
            tree.root.subsections = [first, building]
            let model = BuildModelBuilder.build(tree, reader: .xcresult)
            XCTAssertNil(model.excludedActions)
            XCTAssertEqual(model.tasks.count, 577 + first.subsections.filter { BuildModelBuilder.ruleName(of: $0) != nil }.count)
        }
    }
}
