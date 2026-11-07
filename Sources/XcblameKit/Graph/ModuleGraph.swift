import Foundation

// v0.5 lane C (docs/SCHEMA-v0.5.md "Module graph"): DESIGN §6.9 and the §8.2.2 graph members.
enum ModuleGraph {
    typealias Graph = ReportDocument.ModuleGraph
    /// Top-N of the ranking views (`fanIn`, `fanOut`, `blockers`).
    static let rankingSize = 10

    /// The graph from `target-graph.txt` (else, for an `.xcodeproj` `project`, its target dependencies; else the log's
    /// targets, without edges), its metrics, macro plugins per module (from `-load-plugin-executable` in Swift command
    /// lines), `ModuleVariants`, and nodes collapsed by owner past `ReportDocument.ModuleGraph.nodeCap`. Nil when the
    /// build has no target.
    static func compute(model: BuildModel, description: BuildDescription?, timeline: Timing.Timeline,
                        path: PathResult?, owners: [Int: String], project: ProjectModel? = nil) -> Graph? {
        let real = model.targets.filter { !$0.isBucket }
        var notes: [String] = []
        var edges: [(from: String, to: String)] = []
        var names: [String] = []
        func add(_ name: String) { if !names.contains(name) { names.append(name) } }
        let source: String
        if let description, !description.targetGraph.isEmpty {
            source = "targetGraph"
            var selfLoops = 0
            for edge in description.targetGraph {
                add(edge.from)
                add(edge.to)
                if edge.from == edge.to { selfLoops += 1 } else { edges.append((edge.from, edge.to)) }
            }
            if selfLoops > 0 {
                notes.append("\(selfLoops) self-dependency line(s) of target-graph.txt left out (a package product "
                    + "depending on its own target)")
            }
            real.forEach { add($0.name) }
        } else if let project, !real.isEmpty, case let found = projectEdges(project, built: Set(real.map(\.name))),
                  !found.isEmpty {
            // v0.5 integration: an `.xcodeproj` named by --project or by the log's DerivedData, read-only.
            source = "project"
            real.forEach { add($0.name) }
            edges = found
            notes.append("no build description with target-graph.txt: dependency edges from \(project.container.url.lastPathComponent) "
                + "(PBXTargetDependency and linked package products between built targets, read-only); `swift package "
                + "show-dependencies` is not run because it writes into the package")
        } else if !real.isEmpty {
            source = "log"
            real.forEach { add($0.name) }
            notes.append(description == nil
                ? "no build description: targets from the log, no dependency edges (depth, chain, fan-in/out and "
                    + "blockers need target-graph.txt; use xcblame build or --build-description)"
                : "the build description has no target-graph.txt: targets from the log, no dependency edges")
        } else {
            return nil
        }

        let index = Dictionary(names.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var deps = [[Int]](repeating: [], count: names.count)
        var users = [[Int]](repeating: [], count: names.count)
        for edge in edges {
            guard let a = index[edge.from], let b = index[edge.to], !deps[a].contains(b) else { continue }
            deps[a].append(b)
            users[b].append(a)
        }
        let edgeCount = deps.reduce(0) { $0 + $1.count }

        // Model targets by name (a name can repeat per platform variant: their tasks add up).
        var taskTime = [Double](repeating: 0, count: names.count)
        var hasTasks = [Bool](repeating: false, count: names.count)
        var targetIdsOf = [[Int]](repeating: [], count: names.count)
        for target in real { if let n = index[target.name] { targetIdsOf[n].append(target.id) } }
        var nodeOfTarget: [Int: Int] = [:]
        for (n, ids) in targetIdsOf.enumerated() { for id in ids { nodeOfTarget[id] = n } }
        for item in timeline.counted {
            guard let target = item.task.targetId, let n = nodeOfTarget[target] else { continue }
            taskTime[n] += item.interval.duration
            hasTasks[n] = true
        }
        var onPath = [Double?](repeating: path == nil ? nil : 0, count: names.count)
        var chain: [Int] = []
        if let path {
            for segment in path.segments {
                guard let target = segment.targetId, let n = nodeOfTarget[target] else { continue }
                onPath[n] = (onPath[n] ?? 0) + (segment.end - segment.start)
                if chain.last != n, !chain.contains(n) { chain.append(n) }
            }
        }

        let cycles = stronglyConnected(deps).filter { $0.count > 1 }
        let depth = depths(deps)
        let fanIn = ranking(users.enumerated().map { ($0, $1.count) }, names: names)
        let fanOut = ranking(deps.enumerated().map { ($0, $1.count) }, names: names)
        let umbrellas = names.indices.filter { Double(users[$0].count) > 0.5 * Double(names.count) }.map { names[$0] }
        let longest = path == nil || edgeCount == 0 ? [] : longestChain(deps: deps, weight: onPath.map { $0 ?? 0 })
        let blockers = blockers(deps: deps, users: users, timeline: timeline, nodeOfTarget: nodeOfTarget, names: names)
        let macros = macroPlugins(model: model, names: names, nodeOfTarget: nodeOfTarget)
        let variants = ModuleVariants.compute(description: description, model: model, counted: timeline.counted)
        if variants == nil {
            notes.append(description == nil ? "variants: no build description, so no modules report"
                : "variants: no clangmodulesreport/ or swiftmodulesreport/ next to the build description (Xcode "
                    + "writes them when the build request asks for them)")
        }
        let variantCount = Dictionary((variants?.perModule ?? []).map { ($0.module, $0.variants) },
                                      uniquingKeysWith: { first, _ in first })
        let macroCount = Dictionary(macros.map { ($0.module, $0.plugins) }, uniquingKeysWith: { first, _ in first })
        if !cycles.isEmpty { notes.append("\(cycles.count) dependency cycle(s) in the target graph") }

        let nodes = names.indices.map { n -> Graph.Node in
            let owner = targetIdsOf[n].first.flatMap { owners[$0] }
            return Graph.Node(id: names[n], name: names[n], owner: owner, depth: depth[n],
                              variants: variantCount[names[n]], macroPlugins: macroCount[names[n]],
                              onPathSeconds: onPath[n].map(ReportDocument.round6),
                              taskTime: hasTasks[n] ? ReportDocument.round6(taskTime[n]) : nil, collapsed: 0)
        }
        let chainNames = chain.map { names[$0] }
        var criticalPairs = Set<String>()
        for (a, b) in zip(chainNames, chainNames.dropFirst()) {
            criticalPairs.insert(a + "\u{1F}" + b)
            criticalPairs.insert(b + "\u{1F}" + a)
        }
        let graphEdges = names.indices.flatMap { a in
            deps[a].map { b in
                Graph.Edge(from: names[a], to: names[b], critical: criticalPairs.contains(names[a] + "\u{1F}" + names[b]))
            }
        }
        let full = Graph(
            source: source, targets: names.count, depth: edgeCount == 0 ? nil : depth.max(),
            longestChain: longest.map { Graph.ChainLink(target: names[$0], seconds: ReportDocument.round6(onPath[$0] ?? 0)) },
            longestChainSeconds: longest.isEmpty ? nil : ReportDocument.round6(longest.reduce(0) { $0 + (onPath[$1] ?? 0) }),
            fanIn: fanIn, fanOut: fanOut, umbrellaCandidates: umbrellas, cycles: cycles.map { $0.map { names[$0] } },
            blockers: blockers, macroPluginsPerModule: macros, variants: variants, criticalChain: chainNames,
            nodes: nodes, nodesTotal: nodes.count, nodesShownShare: nodes.isEmpty ? nil : 1, edges: graphEdges,
            edgesTotal: graphEdges.count, edgesShownShare: graphEdges.isEmpty ? nil : 1, notes: notes)
        return collapsed(full, keep: Graph.nodeCap)
    }

    /// `from` depends on `to` for every target of an `.xcodeproj` project (`PBXTargetDependency` names and linked
    /// package product names) whose both ends are among `built`; empty for a workspace or a package (v0.5 integration).
    static func projectEdges(_ project: ProjectModel, built: Set<String>) -> [(from: String, to: String)] {
        guard case .xcodeproj = project.container else { return [] }
        var edges: [(from: String, to: String)] = []
        var seen = Set<String>()
        for target in project.projects.flatMap(\.targets) where built.contains(target.name) {
            for dependency in target.dependencies + target.packageProducts
            where dependency != target.name && built.contains(dependency) && seen.insert(target.name + "\u{1F}" + dependency).inserted {
                edges.append((target.name, dependency))
            }
        }
        return edges
    }

    // MARK: - Metrics

    /// Longest dependency path below each node, in edges (leaves 0). An edge back into the node being visited (a
    /// cycle) counts 0.
    static func depths(_ deps: [[Int]]) -> [Int] {
        var memo = [Int?](repeating: nil, count: deps.count)
        var visiting = [Bool](repeating: false, count: deps.count)
        func visit(_ start: Int) {
            // Iterative post-order so a deep graph cannot overflow the stack.
            var stack: [(node: Int, next: Int)] = [(start, 0)]
            visiting[start] = true
            while let top = stack.last {
                if top.next < deps[top.node].count {
                    stack[stack.count - 1].next += 1
                    let child = deps[top.node][top.next]
                    if memo[child] == nil, !visiting[child] {
                        visiting[child] = true
                        stack.append((child, 0))
                    }
                } else {
                    memo[top.node] = deps[top.node].map { (memo[$0] ?? -1) + 1 }.max() ?? 0
                    visiting[top.node] = false
                    stack.removeLast()
                }
            }
        }
        for node in deps.indices where memo[node] == nil { visit(node) }
        return memo.map { $0 ?? 0 }
    }

    /// Tarjan's strongly connected components (iterative), each sorted by index.
    static func stronglyConnected(_ deps: [[Int]]) -> [[Int]] {
        var index = 0
        var indices = [Int?](repeating: nil, count: deps.count)
        var low = [Int](repeating: 0, count: deps.count)
        var onStack = [Bool](repeating: false, count: deps.count)
        var stack: [Int] = []
        var components: [[Int]] = []
        for root in deps.indices where indices[root] == nil {
            var work: [(node: Int, next: Int)] = [(root, 0)]
            indices[root] = index; low[root] = index; index += 1
            stack.append(root); onStack[root] = true
            while let top = work.last {
                let v = top.node
                if top.next < deps[v].count {
                    work[work.count - 1].next += 1
                    let w = deps[v][top.next]
                    if indices[w] == nil {
                        indices[w] = index; low[w] = index; index += 1
                        stack.append(w); onStack[w] = true
                        work.append((w, 0))
                    } else if onStack[w] {
                        low[v] = min(low[v], indices[w]!)
                    }
                } else {
                    work.removeLast()
                    if let parent = work.last?.node { low[parent] = min(low[parent], low[v]) }
                    if low[v] == indices[v]! {
                        var component: [Int] = []
                        while let w = stack.popLast() {
                            onStack[w] = false
                            component.append(w)
                            if w == v { break }
                        }
                        components.append(component.sorted())
                    }
                }
            }
        }
        return components
    }

    static func ranking(_ counts: [(Int, Int)], names: [String]) -> [Graph.Degree] {
        counts.filter { $0.1 > 0 }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : names[$0.0] < names[$1.0] }
            .prefix(rankingSize).map { Graph.Degree(target: names[$0.0], count: $0.1) }
    }

    /// The dependency path with the most on-path seconds, root (the first built) first. Empty when no node has any.
    static func longestChain(deps: [[Int]], weight: [Double]) -> [Int] {
        guard weight.contains(where: { $0 > 0 }) else { return [] }
        let order = topologicalLeavesFirst(deps)
        var best = [Double](repeating: 0, count: deps.count)
        var next = [Int?](repeating: nil, count: deps.count)
        for node in order {
            var bestChild: Int?
            for child in deps[node] where child != node {
                if bestChild == nil || best[child] > best[bestChild!] { bestChild = child }
            }
            best[node] = weight[node] + (bestChild.map { best[$0] } ?? 0)
            next[node] = bestChild
        }
        guard var current = best.indices.max(by: { best[$0] != best[$1] ? best[$0] < best[$1] : $0 > $1 }) else { return [] }
        var chain = [current]
        var seen: Set<Int> = [current]
        while let child = next[current], seen.insert(child).inserted {
            chain.append(child)
            current = child
        }
        // Drop the zero-weight tail below the last target with path seconds: it is not part of the weighted chain.
        while let last = chain.last, weight[last] == 0, chain.count > 1 { chain.removeLast() }
        while let first = chain.first, weight[first] == 0, chain.count > 1 { chain.removeFirst() }
        return chain.reversed()
    }

    /// Nodes ordered so every dependency comes before its users (cycle edges ignored).
    static func topologicalLeavesFirst(_ deps: [[Int]]) -> [Int] {
        var order: [Int] = []
        var state = [UInt8](repeating: 0, count: deps.count)
        for root in deps.indices where state[root] == 0 {
            var stack: [(node: Int, next: Int)] = [(root, 0)]
            state[root] = 1
            while let top = stack.last {
                if top.next < deps[top.node].count {
                    stack[stack.count - 1].next += 1
                    let child = deps[top.node][top.next]
                    if state[child] == 0 { state[child] = 1; stack.append((child, 0)) }
                } else {
                    state[top.node] = 2
                    order.append(top.node)
                    stack.removeLast()
                }
            }
        }
        return order
    }

    /// Per target: Σ task seconds of its (transitive) dependents' tasks that start after the target's gate closes:
    /// the end of its last emit-module task, else of its last task (§6.9). Top 10, > 0 only.
    ///
    /// One reverse-topological pass (users before their dependencies) collects each target's transitive dependents as
    /// a bitset, and each target's tasks are sorted by start once with suffix sums of their durations, so a gate is a
    /// binary search per dependent: O(T log T + E·V/64 + Σ dependents·log T) instead of a search and a scan of every
    /// dependent's tasks per target (seconds at 2k targets × 50k tasks). The topological order ignores cycle edges, so
    /// inside a cycle a dependent reached only through the back edge is not counted (cycles are reported on their own).
    static func blockers(deps: [[Int]], users: [[Int]], timeline: Timing.Timeline, nodeOfTarget: [Int: Int],
                         names: [String]) -> [Graph.Blocker] {
        let count = names.count
        var tasksOf = [[Timing.Counted]](repeating: [], count: count)
        for item in timeline.counted {
            if let target = item.task.targetId, let n = nodeOfTarget[target] { tasksOf[n].append(item) }
        }
        // Per target: task starts ascending and suffix sums of the durations (`after[i]` = Σ durations of i...).
        var starts = [[Double]](repeating: [], count: count)
        var after = [[Double]](repeating: [0], count: count)
        for node in 0..<count where !tasksOf[node].isEmpty {
            let sorted = tasksOf[node].sorted { $0.interval.start < $1.interval.start }
            starts[node] = sorted.map(\.interval.start)
            var sums = [Double](repeating: 0, count: sorted.count + 1)
            for index in sorted.indices.reversed() { sums[index] = sums[index + 1] + sorted[index].interval.duration }
            after[node] = sums
        }
        func seconds(of node: Int, startingFrom threshold: Double) -> Double {
            var low = 0
            var high = starts[node].count
            while low < high {
                let mid = (low + high) / 2
                if starts[node][mid] < threshold { low = mid + 1 } else { high = mid }
            }
            return after[node][low]
        }
        // Transitive dependents as bitsets, users first.
        let words = (count + 63) / 64
        var dependents = [[UInt64]](repeating: [UInt64](repeating: 0, count: words), count: count)
        for node in topologicalLeavesFirst(deps).reversed() {
            for user in users[node] where user != node {
                dependents[node][user >> 6] |= 1 << UInt64(user & 63)
                for word in 0..<words { dependents[node][word] |= dependents[user][word] }
            }
            dependents[node][node >> 6] &= ~(1 << UInt64(node & 63))
        }
        var rows: [Graph.Blocker] = []
        for node in names.indices where !tasksOf[node].isEmpty && !users[node].isEmpty {
            let emits = tasksOf[node].filter { $0.task.kind == .swiftEmitModule }
            let gate = (emits.isEmpty ? tasksOf[node] : emits).map(\.interval.end).max() ?? 0
            var gated = 0.0
            for word in 0..<words {
                var bits = dependents[node][word]
                while bits != 0 {
                    let user = word * 64 + bits.trailingZeroBitCount
                    bits &= bits - 1
                    gated += seconds(of: user, startingFrom: gate - TaskDAG.eps)
                }
            }
            if gated > 0 { rows.append(Graph.Blocker(target: names[node], gatedSeconds: ReportDocument.round6(gated))) }
        }
        return Array(rows.sorted { $0.gatedSeconds != $1.gatedSeconds ? $0.gatedSeconds > $1.gatedSeconds
            : $0.target < $1.target }.prefix(rankingSize))
    }

    /// `-load-plugin-executable <path>#<Module>` in the Swift planning, compile and emit-module command lines of each
    /// target; plugin names are the part after `#` (else the executable's file name). Most plugins first.
    static func macroPlugins(model: BuildModel, names: [String], nodeOfTarget: [Int: Int]) -> [Graph.MacroPlugins] {
        var plugins = [Set<String>](repeating: [], count: names.count)
        let kinds: Set<TaskKind> = [.swiftPlan, .swiftCompile, .swiftEmitModule]
        for task in model.tasks where kinds.contains(task.kind) {
            guard let target = task.targetId, let n = nodeOfTarget[target], let text = task.commandDetails,
                  text.contains("-load-plugin-executable") else { continue }
            plugins[n].formUnion(pluginNames(in: text))
        }
        return names.indices.filter { !plugins[$0].isEmpty }
            .map { Graph.MacroPlugins(module: names[$0], plugins: plugins[$0].count, names: plugins[$0].sorted()) }
            .sorted { $0.plugins != $1.plugins ? $0.plugins > $1.plugins : $0.module < $1.module }
    }

    static func pluginNames(in text: String) -> Set<String> {
        let tokens = text.split(whereSeparator: { $0 == " " || $0.isNewline })
        var names = Set<String>()
        for (index, token) in tokens.enumerated() where token == "-load-plugin-executable" && index + 1 < tokens.count {
            let value = tokens[index + 1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let parts = value.split(separator: "#", maxSplits: 1)
            if parts.count == 2, !parts[1].isEmpty {
                names.insert(String(parts[1]))
            } else if let path = parts.first {
                names.insert((String(path) as NSString).lastPathComponent)
            }
        }
        return names
    }

    // MARK: - Collapse

    /// `graph` with at most `keep` plain nodes: the critical chain and its direct neighbours stay (then the rest by
    /// task time), every other node folds into one `more:<owner>` node per owner; edges are re-pointed, merged and
    /// self-edges inside a group dropped. Totals never change. Floor: the critical chain.
    static func collapsed(_ graph: Graph, keep: Int) -> Graph {
        let plain = graph.nodes.filter { $0.collapsed == 0 }
        guard plain.count > keep else { return graph }
        let chain = Set(graph.criticalChain)
        var neighbours = Set<String>()
        for edge in graph.edges {
            if chain.contains(edge.from) { neighbours.insert(edge.to) }
            if chain.contains(edge.to) { neighbours.insert(edge.from) }
        }
        func rank(_ a: Graph.Node, _ b: Graph.Node) -> Bool {
            let x = a.taskTime ?? 0, y = b.taskTime ?? 0
            return x != y ? x > y : a.id < b.id
        }
        let chainNodes = plain.filter { chain.contains($0.id) }
        let near = plain.filter { !chain.contains($0.id) && neighbours.contains($0.id) }.sorted(by: rank)
        let rest = plain.filter { !chain.contains($0.id) && !neighbours.contains($0.id) }.sorted(by: rank)
        let room = max(0, keep - chainNodes.count)
        let kept = Set(chainNodes.map(\.id) + (near + rest).prefix(room).map(\.id))

        var groupOf: [String: String] = [:]
        var groups: [String: Graph.Node] = [:]
        var groupOrder: [String] = []
        for node in graph.nodes where !kept.contains(node.id) {
            let owner = node.owner ?? "unknown"
            let id = node.collapsed > 0 ? node.id : "more:" + owner
            groupOf[node.id] = id
            let count = max(1, node.collapsed)
            if var group = groups[id] {
                group.collapsed += count
                group.depth = max(group.depth, node.depth)
                group.taskTime = sum(group.taskTime, node.taskTime)
                group.onPathSeconds = sum(group.onPathSeconds, node.onPathSeconds)
                groups[id] = group
            } else {
                groupOrder.append(id)
                groups[id] = Graph.Node(id: id, name: "", owner: owner, depth: node.depth, variants: nil,
                                        macroPlugins: nil, onPathSeconds: node.onPathSeconds, taskTime: node.taskTime,
                                        collapsed: count)
            }
        }
        let groupNodes = groupOrder.compactMap { id -> Graph.Node? in
            guard var group = groups[id] else { return nil }
            group.name = "\(group.collapsed) more modules (\(group.owner ?? "unknown"))"
            group.taskTime = group.taskTime.map(ReportDocument.round6)
            group.onPathSeconds = group.onPathSeconds.map(ReportDocument.round6)
            return group
        }
        var seen = Set<String>()
        var edges: [Graph.Edge] = []
        for edge in graph.edges {
            let from = groupOf[edge.from] ?? edge.from, to = groupOf[edge.to] ?? edge.to
            guard from != to, seen.insert(from + "\u{1F}" + to).inserted else { continue }
            edges.append(Graph.Edge(from: from, to: to, critical: edge.critical && from == edge.from && to == edge.to))
        }
        var out = graph
        out.nodes = graph.nodes.filter { kept.contains($0.id) } + groupNodes
        let plainEdges = edges.filter { groups[$0.from] == nil && groups[$0.to] == nil }
        out.edges = edges
        out.nodesShownShare = graph.nodesTotal > 0 ? ReportDocument.round6(Double(kept.count) / Double(graph.nodesTotal)) : nil
        out.edgesShownShare = graph.edgesTotal > 0 ? ReportDocument.round6(Double(plainEdges.count) / Double(graph.edgesTotal))
            : nil
        let note = "nodes: \(graph.nodesTotal - kept.count) of \(graph.nodesTotal) targets folded into one node per owner "
            + "(more than \(keep) to draw); the critical chain and its neighbours stay"
        out.notes = graph.notes.filter { !$0.hasPrefix("nodes: ") } + [note]
        return out
    }

    private static func sum(_ a: Double?, _ b: Double?) -> Double? {
        a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0)
    }
}

// v0.5 integration: the project fallback of `moduleGraph` (docs/SCHEMA-v0.5.md "Integration notes").
extension ReportPipeline {
    /// The `.xcodeproj` whose target dependencies give `moduleGraph` its edges (`source` `project`): `explicit`
    /// (`--project`, xcodebuild's `-project`), else the container the log's DerivedData names (`info.plist`
    /// `WorkspacePath`). Read with `ProjectModel.load`, which never writes. Nil when `description` already has a
    /// target graph, when the container is a workspace or a package, or when it does not load.
    public static func moduleGraphProject(explicit: URL?, logURL: URL?, description: BuildDescription?) -> ProjectModel? {
        if let description, !description.targetGraph.isEmpty { return nil }
        guard let container = explicit ?? logURL.flatMap({ ProjectLocator.find(forBuildLog: $0, derivedData: nil) }),
              container.pathExtension == "xcodeproj" else { return nil }
        return try? ProjectModel.load(container: container, scheme: nil)
    }
}
