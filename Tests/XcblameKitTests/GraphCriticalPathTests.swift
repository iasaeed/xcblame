import XCTest
@testable import XcblameKit

final class GraphCriticalPathTests: XCTestCase {
    /// Correctness rules of §6.2 for any path: ordered, disjoint, Σ segments + Σ waits = span ≤ window, ends at the
    /// latest task end, every segment has a basis and task ids.
    private func assertPathRules(_ path: PathResult, model: BuildModel, file: StaticString = #filePath,
                                 line: UInt = #line) {
        let timeline = Timing.timeline(model)
        XCTAssertFalse(path.segments.isEmpty, file: file, line: line)
        XCTAssertLessThanOrEqual(path.span, timeline.window.end - timeline.window.start + 1e-9, file: file, line: line)
        var covered = 0.0
        var previousEnd = -Double.infinity
        let pieces = (path.segments.map { ($0.start, $0.end) } + path.waits.map { ($0.start, $0.end) })
            .sorted { $0.0 < $1.0 }
        for (start, end) in pieces {
            XCTAssertGreaterThanOrEqual(start, previousEnd - 1e-9, "overlap", file: file, line: line)
            XCTAssertLessThan(start, end, file: file, line: line)
            covered += end - start
            previousEnd = end
        }
        XCTAssertEqual(covered, path.span, accuracy: 1e-6, file: file, line: line)
        let lastEnd = timeline.counted.filter { $0.interval.duration > 0 }.map(\.interval.end).max()
        XCTAssertEqual(path.end, lastEnd ?? 0, accuracy: 1e-9, file: file, line: line)
        for segment in path.segments {
            XCTAssertTrue(["dag", "byTiming", "inferred"].contains(segment.basis), file: file, line: line)
            XCTAssertFalse(segment.taskIds.isEmpty, file: file, line: line)
        }
    }

    func testDAGOnTheDDCleanLog() throws {
        let (model, dag, _, graph) = try GraphFixtures.bothPaths(GraphFixtures.cleanDD,
                                                                 description: GraphFixtures.descriptionDD)
        XCTAssertEqual(graph.matchedTasks, 218)
        XCTAssertTrue(graph.isConsistent)
        XCTAssertEqual(graph.checkedEdges, 300, "direct manifest edges between executed commands only")
        XCTAssertEqual(graph.violations, 0)
        XCTAssertEqual(dag.basis, "mixed", "PCM tasks and build-system steps attach by timing")
        assertPathRules(dag, model: model)
        let whatIf = try XCTUnwrap(dag.whatIf)
        for row in whatIf {
            XCTAssertLessThanOrEqual(row.savingIfZero, dag.span + 1e-9)
            XCTAssertLessThanOrEqual(row.savingIfHalf, row.savingIfZero + 1e-9)
        }
        XCTAssertEqual(whatIf.first?.name, Target.explicitModulesBucket)
    }

    /// Exit criterion: the DAG path on the clean AcmeApp 26 log has the §3.3 shape: planning → SDK stat cache →
    /// swift-syntax emit-module → LocalizeCore planning and PCMs → AcmeApp PCMs → AcmeApp compile → link. The §3.3
    /// mock (computed by timing) puts "LocalizeCore compile" between; the DAG shows AcmeApp waits for LocalizeCore's
    /// emit-module (its swiftmodule), not its compiles.
    func testDAGReproducesTheDesignPathShape() throws {
        let (model, dag, _, _) = try GraphFixtures.bothPaths(GraphFixtures.clean26,
                                                             description: GraphFixtures.description26)
        assertPathRules(dag, model: model)
        let steps = dag.segments.flatMap(\.taskIds).map { id -> String in
            let task = model.tasks[id]
            let target = task.targetId.map { model.targets[$0].name } ?? "-"
            return "\(task.ruleName)|\(target)"
        }
        let expected = ["CreateBuildDescription|build system", "ClangStatCache|build system",
                        "SwiftEmitModule|SwiftSyntax", "SwiftDriver|LocalizeCore",
                        "SwiftExplicitDependencyGeneratePcm|explicit modules", "SwiftEmitModule|LocalizeCore",
                        "SwiftDriver|AcmeApp", "SwiftExplicitDependencyGeneratePcm|explicit modules",
                        "SwiftCompile|AcmeApp", "Ld|AcmeApp"]
        var cursor = 0
        for step in steps where cursor < expected.count && step == expected[cursor] { cursor += 1 }
        XCTAssertEqual(cursor, expected.count, "missing \(expected[min(cursor, expected.count - 1)]) in \(steps)")
        XCTAssertEqual(dag.span, 18.13, accuracy: 0.05)
    }

    /// DAG vs inference on the three clean logs with their descriptions. Both span the same window (first task to
    /// the last); tasks on both paths agree within 0.2 s per segment except where the predecessor differs, which
    /// the message lists.
    func testDAGAndInferenceAgreeOrTheDifferenceIsExplained() throws {
        let fixtures = [(GraphFixtures.clean26, GraphFixtures.description26),
                        (GraphFixtures.cleanDD, GraphFixtures.descriptionDD),
                        (GraphFixtures.cleanDD3, GraphFixtures.descriptionDD3)]
        for (log, description) in fixtures {
            let (model, dag, inferred, _) = try GraphFixtures.bothPaths(log, description: description)
            assertPathRules(dag, model: model)
            assertPathRules(inferred, model: model)
            XCTAssertEqual(dag.span, inferred.span, accuracy: 0.2, log.lastPathComponent)
            let comparison = Self.compare(dag, inferred, model: model)
            print("DAG-vs-inference \(log.lastPathComponent.prefix(8)): \(comparison.summary)")
            XCTAssertLessThanOrEqual(comparison.maxDelta, 0.2, comparison.summary)
        }
    }

    struct Comparison {
        var maxDelta: Double
        var summary: String
    }

    /// Per task on both paths: |Δ end| (ends are measured, starts move with the predecessor). Lists the tasks
    /// only one path holds, grouped by target and rule.
    static func compare(_ dag: PathResult, _ inferred: PathResult, model: BuildModel) -> Comparison {
        func ends(_ path: PathResult) -> [Int: Double] {
            var map: [Int: Double] = [:]
            for segment in path.segments { for id in segment.taskIds { map[id] = segment.end } }
            return map
        }
        let a = ends(dag), b = ends(inferred)
        let common = Set(a.keys).intersection(b.keys)
        let maxDelta = common.map { abs(a[$0]! - b[$0]!) }.max() ?? 0
        func describe(_ ids: Set<Int>) -> String {
            var seconds: [String: Double] = [:]
            for id in ids {
                let task = model.tasks[id]
                let key = (task.targetId.map { model.targets[$0].name } ?? "-") + " " + task.ruleName
                seconds[key, default: 0] += task.duration
            }
            return seconds.sorted { $0.value > $1.value }.prefix(3)
                .map { "\($0.key) \(String(format: "%.2f", $0.value)) s" }.joined(separator: ", ")
        }
        let summary = String(format: "span dag %.3f / inferred %.3f s, %d common tasks, max Δend %.3f s; dag only: ",
                             dag.span, inferred.span, common.count, maxDelta)
            + describe(Set(a.keys).subtracting(common)) + "; inferred only: " + describe(Set(b.keys).subtracting(common))
        return Comparison(maxDelta: maxDelta, summary: summary)
    }

    /// Exit criterion: the incremental log excludes its 39 reused tasks; span ≈ 1.6 s.
    func testIncrementalLogExcludesReusedTasks() throws {
        let model = try GraphFixtures.model(GraphFixtures.incremental26)
        let doc = try GraphFixtures.report(model).document
        XCTAssertEqual(doc.build.tasksReused, 39)
        XCTAssertEqual(doc.build.tasks, 18)
        XCTAssertEqual(try XCTUnwrap(doc.build.span), 1.6, accuracy: 0.2)
        let path = try XCTUnwrap(doc.criticalPath)
        XCTAssertEqual(path.basis, "inferred")
        XCTAssertLessThanOrEqual(path.span, try XCTUnwrap(doc.build.span))
        XCTAssertEqual(doc.build.kind, "incremental")
        // With the clean build's description (same signature 6f0b463d): the DAG holds for the 18 executed tasks.
        let description = try BuildDescription.load(directory: GraphFixtures.description26)
        let withDAG = try GraphFixtures.report(model, description: description).document
        XCTAssertEqual(withDAG.criticalPath?.basis == "inferred", false, "\(withDAG.graph.notes)")
        XCTAssertEqual(withDAG.validation.checks.first { $0.id == "V3" }?.status, "pass")
    }

    func testXCResultJSONIsInferenceOnly() throws {
        let model = try GraphFixtures.xcresultModel()
        XCTAssertEqual(model.tasks.filter { $0.taskKey != nil }.count, 0)
        let doc = try GraphFixtures.report(model, topN: 5).document
        XCTAssertEqual(doc.graph.basis, "none")
        let path = try XCTUnwrap(doc.criticalPath)
        XCTAssertEqual(path.basis, "inferred")
        XCTAssertNil(path.whatIf)
        XCTAssertEqual(path.span, 18.13, accuracy: 0.05)
        XCTAssertEqual(doc.build.kind, "clean")
    }

    func testDescriptionFromAnotherBuildIsDroppedByTheConsistencyCheck() throws {
        // The dd3 description against the dd clean log: different signature, mostly the same keys, other timing.
        let model = try GraphFixtures.model(GraphFixtures.cleanDD)
        var foreign = try BuildDescription.load(directory: GraphFixtures.descriptionDD)
        // Shift every command's outputs onto the next command: edges no longer follow the build's real order.
        let outputs = foreign.commands.map(\.outputs)
        for index in foreign.commands.indices {
            foreign.commands[index].outputs = outputs[(index + 1) % outputs.count]
                + foreign.commands[index].inputs.prefix(3)
        }
        let doc = try GraphFixtures.report(model, description: foreign, topN: 5).document
        XCTAssertTrue(doc.graph.notes.contains { $0.hasPrefix("dropped:") }, "\(doc.graph.notes)")
        XCTAssertEqual(doc.criticalPath?.basis, "inferred")
        XCTAssertTrue(doc.criticalPath?.notes.contains { $0.contains("dropped") } == true)
    }

    /// Code review v0.2 #3: the unmodified dd description against the 20E8B73D log covers 29 of 212 planned keyed
    /// tasks. Explicit or snapshot, it is dropped: basis none, inferred path, the coverage in the note.
    func testUnmodifiedForeignDescriptionIsDroppedByKeyCoverage() throws {
        let model = try GraphFixtures.model(GraphFixtures.clean26)
        let foreign = try BuildDescription.load(directory: GraphFixtures.descriptionDD)
        let doc = try GraphFixtures.report(model, description: foreign, topN: 5).document
        XCTAssertEqual(doc.graph.basis, "none")
        XCTAssertNil(doc.graph.signature)
        XCTAssertNil(doc.graph.path)
        XCTAssertNil(doc.graph.commands)
        XCTAssertTrue(doc.graph.notes.contains("dropped: 29 of 212 planned keyed tasks (14%) are commands of this "
            + "description, below 95%: it is not this build's"), "\(doc.graph.notes)")
        XCTAssertEqual(doc.criticalPath?.basis, "inferred")
        XCTAssertNil(doc.criticalPath?.whatIf)
        XCTAssertTrue(TextReporter.render(doc).contains("dropped: 29 of 212"), "the text report shows it")
        // Re-check R5: a description no executed task matches (a clean-action log) is reported the same way.
        let clean = try GraphFixtures.report(try GraphFixtures.model(GraphFixtures.cleanAction26),
                                             description: BuildDescription.load(directory: GraphFixtures.description26),
                                             topN: 5).document
        XCTAssertEqual(clean.graph.basis, "none")
        XCTAssertNil(clean.graph.path)
        XCTAssertTrue(clean.graph.notes.contains("dropped: no executed task is a command of this description"))
        // The matching pair is still accepted.
        let own = try GraphFixtures.report(model, description: BuildDescription.load(directory: GraphFixtures.description26),
                                           topN: 5).document
        XCTAssertEqual(own.graph.basis, "snapshot")
        XCTAssertEqual(own.criticalPath?.basis, "mixed")
    }

    /// A hand-built 6-node DAG with a known answer: A→B→E→F and A→C→D→F. Longest path A C D F = 8 s; B and E have
    /// 1 s slack; T0 (A, C) at 0 saves 3 s (half: 1.5), T2 (D, F) saves 2 s (half: 1.5), T1 (B, E) saves nothing.
    static func sixNodeDAG() -> (model: BuildModel, dag: TaskDAG) {
        let spans: [(start: Double, end: Double, target: Int)] = [(0, 2, 0), (2, 5, 1), (2, 3, 0), (3, 7, 2), (5, 6, 1),
                                                                  (7, 8, 2)]
        let tasks = spans.enumerated().map { TestModels.task($0.offset, target: $0.element.target, start: $0.element.start,
                                                              end: $0.element.end) }
        let model = TestModels.model(tasks, targets: (0..<3).map { TestModels.target($0, "T\($0)") }, start: 0, end: 8)
        let nodes = spans.enumerated().map { TaskDAG.Node(taskId: $0.offset, start: $0.element.start, end: $0.element.end,
                                                          targetId: $0.element.target, basis: "dag") }
        let dag = TaskDAG(nodes: nodes, preds: [[], [0], [0], [2], [1], [3, 4]], topo: [0, 1, 2, 3, 4, 5],
                          nodeOfTask: Dictionary(uniqueKeysWithValues: (0..<6).map { ($0, $0) }), matchedTasks: 6,
                          checkedEdges: 6, violations: 0, notes: [])
        return (model, dag)
    }

    func testHandBuiltDAGHasTheKnownLongestPathSlackAndWhatIf() throws {
        let (model, dag) = Self.sixNodeDAG()
        let (length, slack) = dag.longestPathAndSlack()
        XCTAssertEqual(length, 8)
        XCTAssertEqual(slack, [0, 1, 0, 0, 1, 0])
        let path = try XCTUnwrap(CriticalPath.fromDAG(dag, model: model))
        XCTAssertEqual(path.segments.flatMap(\.taskIds), [0, 2, 3, 5])
        XCTAssertEqual(path.span, 8)
        XCTAssertEqual(path.slack[1], 1)
        let rows = try XCTUnwrap(path.whatIf).map { "\($0.name) \($0.savingIfZero) \($0.savingIfHalf)" }
        XCTAssertEqual(rows, ["T0 3.0 1.5", "T2 2.0 1.5", "T1 0.0 0.0"])
        XCTAssertTrue(path.notes.contains { $0.hasPrefix("slack: 4 of 6 DAG tasks have zero slack") }, "\(path.notes)")
    }

    func testSegmentsAbsorbSmallGapsAndRecordWaits() {
        let steps = [
            CriticalPath.Step(taskId: 0, start: 0, end: 1, basis: "inferred", targetId: nil),
            CriticalPath.Step(taskId: 1, start: 1.02, end: 2, basis: "inferred", targetId: nil),
            CriticalPath.Step(taskId: 2, start: 2.5, end: 3, basis: "inferred", targetId: nil),
            CriticalPath.Step(taskId: 3, start: 2.9, end: 2.95, basis: "inferred", targetId: nil),
            CriticalPath.Step(taskId: 4, start: 2.96, end: 4, basis: "inferred", targetId: nil),
        ]
        let (segments, waits) = CriticalPath.segments(from: steps)
        XCTAssertEqual(segments.map(\.start), [0, 1, 2.5, 3])
        XCTAssertEqual(segments.map(\.taskIds), [[0], [1], [2, 3], [4]])
        XCTAssertEqual(waits.count, 1)
        XCTAssertEqual(waits.first?.start, 2)
        XCTAssertEqual(waits.first?.end, 2.5)
    }
}
