import XCTest
@testable import XcblameKit

/// Module graph (DESIGN §6.9, docs/SCHEMA-v0.5.md "Module graph") on the cli-xcode26-dd snapshot and synthetic graphs.
final class ModuleGraphTests: XCTestCase {
    typealias Graph = ReportDocument.ModuleGraph

    private func ddDocument() throws -> ReportDocument {
        try GraphFixtures.report(try GraphFixtures.model(GraphFixtures.cleanDD),
                                 description: try BuildDescription.load(directory: GraphFixtures.descriptionDD)).document
    }

    func testDDSnapshotGraphMetrics() throws {
        let document = try ddDocument()
        let graph = try XCTUnwrap(document.moduleGraph)
        XCTAssertEqual(graph.source, "targetGraph")
        // target-graph.txt says "13 targets" (platform variants repeat); 10 distinct names.
        XCTAssertEqual(graph.targets, 10)
        XCTAssertEqual(graph.nodesTotal, 10)
        XCTAssertEqual(graph.depth, 4, "AcmeApp → LocalizeCore → SwiftParser → SwiftSyntax → SwiftSyntax5xx")
        XCTAssertEqual(graph.cycles, [])
        XCTAssertTrue(graph.notes.contains { $0.hasPrefix("3 self-dependency line(s)") }, "\(graph.notes)")
        XCTAssertEqual(graph.edgesTotal, 16)
        XCTAssertEqual(graph.fanIn.first, .init(target: "SwiftSyntax", count: 2))
        XCTAssertEqual(graph.fanOut.first, .init(target: "SwiftParser", count: 7))
        XCTAssertEqual(graph.umbrellaCandidates, [])
        XCTAssertEqual(graph.nodes.first { $0.id == "AcmeApp" }?.depth, 4)
        XCTAssertEqual(graph.nodes.first { $0.id == "SwiftSyntax602" }?.depth, 0)
        XCTAssertEqual(graph.nodes.first { $0.id == "LocalizeCore" }?.owner, "localPackage")
        XCTAssertEqual(graph.nodes.first { $0.id == "SwiftSyntax" }?.owner, "remotePackage")
        XCTAssertEqual(graph.nodes.first { $0.id == "_SwiftSyntaxCShims" }?.variants, 3, "the (Clang) module of the target")
    }

    func testLongestChainFollowsTheCriticalPathTargets() throws {
        let document = try ddDocument()
        let graph = try XCTUnwrap(document.moduleGraph)
        let path = try XCTUnwrap(document.criticalPath)
        XCTAssertEqual(graph.criticalChain, ["SwiftSyntax510", "SwiftSyntax", "SwiftParser", "LocalizeCore", "AcmeApp"])
        XCTAssertEqual(graph.longestChain.map(\.target), ["SwiftSyntax510", "SwiftSyntax", "SwiftParser", "LocalizeCore",
                                                          "AcmeApp"])
        // Every chain link is a target of the critical path, and its seconds are that target's on-path seconds.
        let pathTargets = Set(path.segments.compactMap(\.target))
        XCTAssertTrue(graph.longestChain.allSatisfy { pathTargets.contains($0.target) })
        let sum = graph.longestChain.reduce(0) { $0 + $1.seconds }
        XCTAssertEqual(graph.longestChainSeconds ?? 0, sum, accuracy: 1e-5)
        XCTAssertEqual(graph.longestChainSeconds ?? 0, 7.052, accuracy: 0.001)
        XCTAssertEqual(graph.edges.filter(\.critical).count, 4)
        XCTAssertTrue(graph.edges.contains(.init(from: "AcmeApp", to: "LocalizeCore", critical: true)))
        // Blockers: the swift-syntax leaves gate everything built after them.
        XCTAssertEqual(graph.blockers.first?.gatedSeconds ?? 0, 107.3, accuracy: 0.1)
        XCTAssertTrue(graph.blockers.contains { $0.target == "LocalizeCore" })
    }

    func testWithoutADescriptionTheGraphHasLogTargetsAndNoEdges() throws {
        let graph = try XCTUnwrap(try GraphFixtures.report(try GraphFixtures.model(GraphFixtures.cleanDD)).document.moduleGraph)
        XCTAssertEqual(graph.source, "log")
        XCTAssertEqual(graph.targets, 10, "buckets are not targets")
        XCTAssertNil(graph.depth)
        XCTAssertEqual(graph.edges, [])
        XCTAssertEqual(graph.longestChain, [])
        XCTAssertNil(graph.variants)
        XCTAssertFalse(graph.criticalChain.isEmpty)
        XCTAssertTrue(graph.notes.contains { $0.hasPrefix("no build description") })
    }

    /// v0.5 integration: without a target graph, an `.xcodeproj` (read-only) gives the edges (`source` `project`);
    /// a workspace or no project keeps the log fallback.
    func testProjectFallbackForAnXcodeprojOnly() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/projects/AcmeWhy/AcmeWhy.xcodeproj")
        let project = try ProjectModel.load(container: fixture, scheme: nil)
        let names = ["AcmeWhyApp", "WhyKit", "WhyCore", "WhyUtils"]
        let targets = names.enumerated().map { TestModels.target($0.offset, $0.element) }
        let tasks = names.indices.map { TestModels.task($0, target: $0, start: 100 + Double(3 - $0), end: 101 + Double(3 - $0)) }
        let model = TestModels.model(tasks, targets: targets, start: 100, end: 110)
        let timeline = Timing.timeline(model)
        let graph = try XCTUnwrap(ModuleGraph.compute(model: model, description: nil, timeline: timeline, path: nil,
                                                      owners: [:], project: project))
        XCTAssertEqual(graph.source, "project")
        XCTAssertEqual(Set(graph.edges.map { "\($0.from)>\($0.to)" }),
                       ["AcmeWhyApp>WhyKit", "WhyKit>WhyCore", "WhyKit>WhyUtils"], "\(graph.edges)")
        XCTAssertEqual(graph.depth, 2)
        XCTAssertTrue(graph.notes.contains { $0.contains("AcmeWhy.xcodeproj") && $0.contains("show-dependencies") },
                      "\(graph.notes)")
        XCTAssertEqual(ModuleGraph.projectEdges(project, built: ["WhyKit"]).count, 0, "both ends must be built")
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try JSONSchema.render(.report).utf8)) as? [String: Any])
        var document = try ReportPipeline.run(model, options: .init(generatedAt: Date(timeIntervalSince1970: 0))).document
        XCTAssertEqual(document.moduleGraph?.source, "log")
        document.moduleGraph = graph
        let tree = try JSONSerialization.jsonObject(with: try JSONReporter.encoder().encode(document))
        XCTAssertEqual(MiniSchemaValidator(root: schema).errors(tree), [], "project is in the closed enum")

        var workspace = project
        workspace.container = .xcworkspace(fixture.deletingPathExtension().appendingPathExtension("xcworkspace"))
        XCTAssertEqual(ModuleGraph.compute(model: model, description: nil, timeline: timeline, path: nil, owners: [:],
                                           project: workspace)?.source, "log")
        XCTAssertNil(ReportPipeline.moduleGraphProject(explicit: fixture.deletingLastPathComponent(), logURL: nil,
                                                       description: nil), "a folder is not an .xcodeproj")
        XCTAssertEqual(ReportPipeline.moduleGraphProject(explicit: fixture, logURL: nil, description: nil)?.projects.count, 1)
        let dd = try BuildDescription.load(directory: GraphFixtures.descriptionDD)
        XCTAssertNil(ReportPipeline.moduleGraphProject(explicit: fixture, logURL: nil, description: dd),
                     "a target graph wins; the project is not even read")
    }

    func testNoTargetMeansNoGraphAndANote() throws {
        let model = TestModels.model([TestModels.task(0, start: 0, end: 1)], start: 0, end: 10)
        XCTAssertNil(ModuleGraph.compute(model: model, description: nil, timeline: Timing.timeline(model), path: nil, owners: [:]))
        let document = try ReportPipeline.run(model, options: .init(generatedAt: Date(timeIntervalSince1970: 0))).document
        XCTAssertNil(document.moduleGraph)
        XCTAssertTrue(document.notes.contains("moduleGraph: null because the log has no target"), "\(document.notes)")
    }

    func testDepthCyclesAndChainOnSmallGraphs() {
        // 0 → 1 → 2, 0 → 2, 3 ↔ 4
        let deps = [[1, 2], [2], [], [4], [3]]
        XCTAssertEqual(ModuleGraph.depths(deps).prefix(3), [2, 1, 0])
        XCTAssertEqual(ModuleGraph.stronglyConnected(deps).filter { $0.count > 1 }, [[3, 4]])
        XCTAssertEqual(ModuleGraph.longestChain(deps: deps, weight: [1, 5, 2, 0, 0]), [2, 1, 0], "root first")
        XCTAssertEqual(ModuleGraph.longestChain(deps: deps, weight: [0, 0, 0, 0, 0]), [])
        // A deep chain does not recurse.
        let chain = (0..<20_000).map { $0 + 1 < 20_000 ? [$0 + 1] : [] }
        XCTAssertEqual(ModuleGraph.depths(chain).first, 19_999)
    }

    func testCyclesAreReportedFromTheTargetGraph() throws {
        let model = TestModels.model([TestModels.task(0, target: 0, start: 0, end: 1), TestModels.task(1, target: 1, start: 1, end: 2)],
                                     targets: [TestModels.target(0, "A"), TestModels.target(1, "B")], start: 0, end: 10)
        let description = BuildDescription(signature: nil, directory: URL(fileURLWithPath: "/nonexistent"), commands: [],
                                           targetGraph: [.init(from: "A", to: "B"), .init(from: "B", to: "A")],
                                           buildRequest: .init(action: nil, enableIndexBuildArena: nil, raw: [:]))
        let graph = try XCTUnwrap(ModuleGraph.compute(model: model, description: description,
                                                      timeline: Timing.timeline(model), path: nil, owners: [:]))
        XCTAssertEqual(graph.cycles, [["A", "B"]])
        XCTAssertTrue(graph.notes.contains("1 dependency cycle(s) in the target graph"))
    }

    func testMacroPluginsFromSwiftCommandLines() throws {
        var tasks = [TestModels.task(0, "SwiftDriver", kind: .swiftPlan, target: 0, start: 0, end: 1),
                     TestModels.task(1, "SwiftCompile", kind: .swiftCompile, target: 0, start: 1, end: 2),
                     TestModels.task(2, "SwiftCompile", kind: .swiftCompile, target: 1, start: 1, end: 2)]
        tasks[0].commandDetails = "SwiftDriver Kit\n    cd /p\n    swiftc -module-name Kit -load-plugin-executable "
            + "/DD/Build/Products/Debug/MacroA-tool#MacroA -load-plugin-executable /DD/MacroB-tool#MacroB"
        tasks[1].commandDetails = "swift-frontend -load-plugin-executable /DD/MacroA-tool#MacroA"
        tasks[2].commandDetails = "swift-frontend -load-plugin-executable /DD/Tools/OnlyPath"
        let model = TestModels.model(tasks, targets: [TestModels.target(0, "Kit"), TestModels.target(1, "App")], start: 0, end: 10)
        let graph = try XCTUnwrap(ModuleGraph.compute(model: model, description: nil, timeline: Timing.timeline(model),
                                                      path: nil, owners: [:]))
        XCTAssertEqual(graph.macroPluginsPerModule, [.init(module: "Kit", plugins: 2, names: ["MacroA", "MacroB"]),
                                                     .init(module: "App", plugins: 1, names: ["OnlyPath"])])
        XCTAssertEqual(graph.nodes.first { $0.id == "Kit" }?.macroPlugins, 2)
    }

    /// Planted cause 4 of AcmeWhy (docs/SCHEMA-v0.5.md, DESIGN §11 v0.5) is static: `Packages/WhyMacros` declares two
    /// `.macro` targets (never built offline), and a WhyKit Swift command line loading both counts 2 plugins.
    func testAcmeWhyMacroPluginsArePlantedStatically() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("fixtures/projects/AcmeWhy")
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("expected.json")))
            as? [[String: Any]])
        let scenario = try XCTUnwrap(expected.first { $0["scenario"] as? String == "macroPlugins" })
        XCTAssertEqual(scenario["static"] as? Bool, true)
        let package = try ProjectModel.load(container: root.appendingPathComponent("Packages/WhyMacros/Package.swift"), scheme: nil)
        let manifest = try XCTUnwrap(package.packages.compactMap(\.manifest).first)
        let macros = manifest.targets.filter { $0.type == "macro" }.map(\.name)
        XCTAssertEqual(macros, ["WhyMacrosA", "WhyMacrosB"])
        XCTAssertEqual(macros.count, scenario["plugins"] as? Int)

        let module = try XCTUnwrap(scenario["module"] as? String)
        var task = TestModels.task(0, "SwiftDriver", kind: .swiftPlan, target: 0, start: 0, end: 1)
        task.commandDetails = "swiftc -module-name \(module) " + macros.map { "-load-plugin-executable /DD/\($0)-tool#\($0)" }
            .joined(separator: " ")
        let model = TestModels.model([task], targets: [TestModels.target(0, module)], start: 0, end: 2)
        let graph = try XCTUnwrap(ModuleGraph.compute(model: model, description: nil, timeline: Timing.timeline(model),
                                                      path: nil, owners: [:]))
        XCTAssertEqual(graph.macroPluginsPerModule, [.init(module: module, plugins: 2, names: macros)])
    }

    /// 400 targets in 4 owners, a 3-target critical chain: past 300 the rest folds by owner; totals stay.
    func testCollapseByOwnerPast300Nodes() {
        var nodes: [Graph.Node] = []
        var edges: [Graph.Edge] = []
        let owners = ["app", "localPackage", "remotePackage", "pods"]
        for i in 0..<400 {
            nodes.append(.init(id: "T\(i)", name: "T\(i)", owner: owners[i % 4], depth: i < 3 ? 2 - i : 0, variants: nil,
                               macroPlugins: nil, onPathSeconds: i < 3 ? 1 : 0, taskTime: Double(400 - i) / 10, collapsed: 0))
            if i >= 3 { edges.append(.init(from: "T\(i % 3)", to: "T\(i)", critical: false)) }
        }
        edges += [.init(from: "T0", to: "T1", critical: true), .init(from: "T1", to: "T2", critical: true)]
        let full = Graph(source: "targetGraph", targets: 400, depth: 2, longestChain: [], longestChainSeconds: nil,
                         fanIn: [], fanOut: [], umbrellaCandidates: [], cycles: [], blockers: [],
                         macroPluginsPerModule: [], variants: nil, criticalChain: ["T2", "T1", "T0"], nodes: nodes,
                         nodesTotal: 400, nodesShownShare: 1, edges: edges, edgesTotal: edges.count, edgesShownShare: 1,
                         notes: [])
        let cut = ModuleGraph.collapsed(full, keep: Graph.nodeCap)
        let plain = cut.nodes.filter { $0.collapsed == 0 }
        XCTAssertEqual(plain.count, 300)
        XCTAssertTrue(["T0", "T1", "T2"].allSatisfy { id in plain.contains { $0.id == id } })
        let groups = cut.nodes.filter { $0.collapsed > 0 }
        XCTAssertEqual(groups.reduce(0) { $0 + $1.collapsed }, 100)
        XCTAssertTrue(groups.allSatisfy { $0.id == "more:" + ($0.owner ?? "") && $0.name.hasSuffix("more modules (\($0.owner!))") })
        XCTAssertEqual(cut.nodesTotal, 400)
        XCTAssertEqual(cut.edgesTotal, edges.count)
        XCTAssertEqual(cut.nodesShownShare ?? 0, 0.75, accuracy: 1e-9)
        XCTAssertEqual(Set(cut.edges.map { "\($0.from)>\($0.to)" }).count, cut.edges.count, "merged, no duplicates")
        XCTAssertTrue(cut.edges.allSatisfy { $0.from != $0.to })
        XCTAssertEqual(cut.edges.filter(\.critical).count, 2)
        XCTAssertTrue(cut.notes.contains { $0.hasPrefix("nodes: 100 of 400 targets folded") })

        // The HTML budget folds further down to its floor, the critical chain; groups absorb groups.
        let tiny = HTMLReporter.collapsedModuleGraph(cut, keep: 1)
        XCTAssertEqual(tiny.nodes.filter { $0.collapsed == 0 }.map(\.id).sorted(), ["T0", "T1", "T2"])
        XCTAssertEqual(tiny.nodes.reduce(0) { $0 + max(1, $1.collapsed) }, 400)
        XCTAssertEqual(ModuleGraph.collapsed(tiny, keep: 1), tiny, "idempotent at the floor")
        XCTAssertEqual(HTMLReporter.collapsedModuleGraph(V05Samples.moduleGraph, keep: 300), V05Samples.moduleGraph)
    }

    // MARK: - Blockers (code review v0.5)

    /// A random acyclic graph: node i depends on up to `fanout` lower nodes; tasks at random starts, every fifth an
    /// emit-module task.
    private func randomGraph(nodes: Int, tasks: Int, fanout: Int, seed: UInt64)
        -> (deps: [[Int]], users: [[Int]], timeline: Timing.Timeline, names: [String]) {
        var rng = SplitMix(seed: seed)
        var deps = [[Int]](repeating: [], count: nodes)
        var users = [[Int]](repeating: [], count: nodes)
        for node in 1..<nodes {
            for dep in Set((0..<Int(rng.next() % UInt64(fanout + 1))).map { _ in Int(rng.next() % UInt64(node)) }) {
                deps[node].append(dep)
                users[dep].append(node)
            }
        }
        let counted = (0..<tasks).map { id -> Timing.Counted in
            let kind: TaskKind = id % 5 == 0 ? .swiftEmitModule : .swiftCompile
            let start = Double(rng.next() % 1_000_000) / 1000
            let task = BuildTask(
                id: id, ruleName: kind == .swiftEmitModule ? "SwiftEmitModule" : "SwiftCompile", kind: kind,
                kindSource: .rule, phase: .compile, targetId: Int(rng.next() % UInt64(nodes)), start: start,
                end: start + 1, duration: 1, resultCode: 0, metrics: nil, backtrace: nil, taskKey: nil, subspans: [],
                commandDetails: nil, signature: nil, title: "t\(id)", emittedOutput: nil, diagnosticIds: [], slfOnly: nil,
                unknownAttachments: [])
            return Timing.Counted(task: task, interval: Interval(start: start, end: start + Double(rng.next() % 2000) / 1000))
        }
        let timeline = Timing.Timeline(window: (0, 1_002), counted: counted, reused: 0, clamped: 0, invalid: 0)
        return (deps, users, timeline, (0..<nodes).map { "T\($0)" })
    }

    /// The former definition, a search and a task scan per target: the reference the single pass must equal.
    private func referenceBlockers(users: [[Int]], timeline: Timing.Timeline, names: [String]) -> [Graph.Blocker] {
        var tasksOf = [[Timing.Counted]](repeating: [], count: names.count)
        for item in timeline.counted { if let target = item.task.targetId { tasksOf[target].append(item) } }
        var rows: [Graph.Blocker] = []
        for node in names.indices where !tasksOf[node].isEmpty && !users[node].isEmpty {
            let emits = tasksOf[node].filter { $0.task.kind == .swiftEmitModule }
            let gate = (emits.isEmpty ? tasksOf[node] : emits).map(\.interval.end).max() ?? 0
            var dependents = Set<Int>()
            var queue = users[node]
            while let next = queue.popLast() {
                if next != node, dependents.insert(next).inserted { queue.append(contentsOf: users[next]) }
            }
            let gated = dependents.reduce(0.0) { sum, user in
                sum + tasksOf[user].filter { $0.interval.start >= gate - TaskDAG.eps }.reduce(0) { $0 + $1.interval.duration }
            }
            if gated > 0 { rows.append(Graph.Blocker(target: names[node], gatedSeconds: ReportDocument.round6(gated))) }
        }
        return Array(rows.sorted { $0.gatedSeconds != $1.gatedSeconds ? $0.gatedSeconds > $1.gatedSeconds
            : $0.target < $1.target }.prefix(ModuleGraph.rankingSize))
    }

    func testBlockersMatchThePerTargetSearchAndScale() {
        for seed in [1, 2, 3] as [UInt64] {
            let g = randomGraph(nodes: 80, tasks: 1_500, fanout: 4, seed: seed)
            let fast = ModuleGraph.blockers(deps: g.deps, users: g.users, timeline: g.timeline,
                                            nodeOfTarget: Dictionary(uniqueKeysWithValues: g.names.indices.map { ($0, $0) }),
                                            names: g.names)
            let slow = referenceBlockers(users: g.users, timeline: g.timeline, names: g.names)
            XCTAssertEqual(fast.map(\.target), slow.map(\.target), "seed \(seed)")
            for (a, b) in zip(fast, slow) { XCTAssertEqual(a.gatedSeconds, b.gatedSeconds, accuracy: 1e-5, "seed \(seed)") }
        }
        let big = randomGraph(nodes: 2_000, tasks: 50_000, fanout: 6, seed: 9)
        let started = Date()
        let rows = ModuleGraph.blockers(deps: big.deps, users: big.users, timeline: big.timeline,
                                        nodeOfTarget: Dictionary(uniqueKeysWithValues: big.names.indices.map { ($0, $0) }),
                                        names: big.names)
        XCTAssertEqual(rows.count, ModuleGraph.rankingSize)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "2k targets x 50k tasks")
    }
}
