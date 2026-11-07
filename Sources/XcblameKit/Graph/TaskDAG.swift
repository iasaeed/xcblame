import Foundation

/// The task DAG of DESIGN §6.2 over the tasks that entered timing. Edges come from the build description (an output
/// node of command A is an input node of command B; commands that did not run, phony gates included, stay in the
/// graph as zero-weight virtual nodes, so V and E stay manifest-sized), from the Swift
/// driver groups (planning → emit-module / compiles → the target's `SwiftDriver Compilation [Requirements]` command),
/// and, labelled `byTiming`, from timing where the manifest is silent (explicit-module tasks, build-system steps).
struct TaskDAG {
    struct Node {
        /// Model task id; nil for a virtual node (a command that did not run or a timing gate, weight 0). A virtual
        /// node's `start` and `end` are the latest end among its predecessors (when the gate opened), `-inf` when no
        /// task precedes it.
        var taskId: Int?
        var start: Double
        var end: Double
        var targetId: Int?
        /// `dag` (a manifest command or a Swift job attached to its driver command) or `byTiming`.
        var basis: String
        var weight: Double { taskId == nil ? 0 : end - start }
    }

    /// Edge tolerance of the consistency check (§6.2 step 5) and of every timing attachment.
    static let eps = 0.05
    /// More than this share of inconsistent edges means the description is not this build's.
    static let maxViolationShare = 0.01

    var nodes: [Node]
    /// Predecessor node indexes, sorted and unique.
    var preds: [[Int]]
    /// Node indexes in topological order.
    var topo: [Int]
    var nodeOfTask: [Int: Int]
    /// Counted tasks whose key is a manifest command.
    var matchedTasks: Int
    /// Direct manifest edges between two executed commands (no timing edge, no path through a gate), and how many of
    /// them break `end(A) ≤ start(B) + eps` (§6.2 step 5).
    var checkedEdges: Int
    var violations: Int
    var notes: [String]

    var violationShare: Double { checkedEdges > 0 ? Double(violations) / Double(checkedEdges) : 0 }
    var isConsistent: Bool { violationShare <= Self.maxViolationShare }

    // MARK: - Build

    /// Nil when the edges contain a cycle even without the timing edges (the description cannot be ordered).
    static func build(model: BuildModel, counted: [Timing.Counted], description: BuildDescription,
                      window: (start: Double, end: Double)) -> TaskDAG? {
        var builder = Builder(model: model, counted: counted, window: window)
        builder.addManifestEdges(description)
        builder.addSwiftDriverGroups()
        builder.addExplicitModuleTasks()
        builder.addRootsByTiming()
        return builder.finish()
    }

    /// Earliest finish per node with measured weights (used to break ties on the path walk); O(V + E).
    func earliestFinish() -> [Double] {
        var finish = [Double](repeating: 0, count: nodes.count)
        for v in topo {
            var start = 0.0
            for u in preds[v] { start = max(start, finish[u]) }
            finish[v] = start + nodes[v].weight
        }
        return finish
    }

    /// Longest path at measured weights (unlimited cores) and per-node slack (§6.2 step 4: latest start − earliest
    /// start), from one forward and one backward pass in topological order; O(V + E).
    func longestPathAndSlack() -> (length: Double, slack: [Double]) {
        let finish = earliestFinish()
        var tail = [Double](repeating: 0, count: nodes.count)
        var successors = [[Int]](repeating: [], count: nodes.count)
        for v in nodes.indices { for u in preds[v] { successors[u].append(v) } }
        for v in topo.reversed() {
            var after = 0.0
            for w in successors[v] { after = max(after, tail[w]) }
            tail[v] = after + nodes[v].weight
        }
        let length = finish.max() ?? 0
        let slack = nodes.indices.map { v in max(0, length - (finish[v] + tail[v] - nodes[v].weight)) }
        return (length, slack)
    }

    /// Longest path with every task of `target` at duration 0 and at half its duration, in one pass; O(V + E).
    func longestPath(shrinking target: Int) -> (zero: Double, half: Double) {
        var zero = [Double](repeating: 0, count: nodes.count)
        var half = zero
        var best = (zero: 0.0, half: 0.0)
        for v in topo {
            var startZero = 0.0, startHalf = 0.0
            for u in preds[v] {
                startZero = max(startZero, zero[u])
                startHalf = max(startHalf, half[u])
            }
            let weight = nodes[v].weight
            let mine = nodes[v].targetId == target
            zero[v] = startZero + (mine ? 0 : weight)
            half[v] = startHalf + (mine ? weight / 2 : weight)
            best = (max(best.zero, zero[v]), max(best.half, half[v]))
        }
        return best
    }

    struct Builder {
        let model: BuildModel
        let window: (start: Double, end: Double)
        var nodes: [Node] = []
        var preds: [Set<Int>] = []
        /// Timing edges, dropped first if the graph has a cycle.
        var timingPreds: [Set<Int>] = []
        var nodeOfTask: [Int: Int] = [:]
        var commandNode: [Int: Int] = [:]
        var matched = 0
        var checked = 0
        var violations = 0
        var notes: [String] = []

        init(model: BuildModel, counted: [Timing.Counted], window: (start: Double, end: Double)) {
            self.model = model
            self.window = window
            for item in counted {
                nodeOfTask[item.task.id] = nodes.count
                nodes.append(Node(taskId: item.task.id, start: item.interval.start, end: item.interval.end,
                                  targetId: item.task.targetId, basis: "byTiming"))
            }
            preds = Array(repeating: [], count: nodes.count)
            timingPreds = preds
        }

        func task(_ node: Int) -> BuildTask? { nodes[node].taskId.map { model.tasks[$0] } }

        mutating func addNode(_ node: Node) -> Int {
            nodes.append(node)
            preds.append([])
            timingPreds.append([])
            return nodes.count - 1
        }

        // MARK: Manifest

        /// Edge A → B when an output of A is an input of B; commands that did not run pass their executed ancestors
        /// through (weight 0).
        mutating func addManifestEdges(_ description: BuildDescription) {
            let commands = description.commands
            var keyIndex: [String: Int] = [:]
            keyIndex.reserveCapacity(commands.count)
            for (index, command) in commands.enumerated() { keyIndex[command.key] = index }
            for node in nodes.indices {
                guard let key = task(node)?.taskKey, let command = keyIndex[key], commandNode[command] == nil else {
                    continue
                }
                commandNode[command] = node
                nodes[node].basis = "dag"
                matched += 1
            }
            // Directory nodes are spelled with a trailing slash on the input side only (`X.swiftmodule/` consumed,
            // `X.swiftmodule` produced, Xcode 26 corpus manifests): compare without it.
            func node(_ name: String) -> Substring {
                name.count > 1 && name.hasSuffix("/") ? name.dropLast() : Substring(name)
            }
            var producer: [Substring: Int] = [:]
            for (index, command) in commands.enumerated() {
                for output in command.outputs where producer[node(output)] == nil { producer[node(output)] = index }
            }
            let commandPreds: [[Int]] = commands.map { command in
                Array(Set(command.inputs.compactMap { producer[node($0)] }))
            }
            // Commands that did not run (up to date, phony gates) become zero-weight virtual nodes with their direct
            // edges: no collapsed ancestor sets, which grew quadratic on gate-heavy manifests (code review v0.2 #4).
            for command in commands.indices where commandNode[command] == nil {
                commandNode[command] = addNode(Node(taskId: nil, start: -.infinity, end: -.infinity, targetId: nil,
                                                    basis: "dag"))
            }
            for command in commands.indices {
                let node = commandNode[command]!
                for p in commandPreds[command] where p != command {
                    let upstream = commandNode[p]!
                    preds[node].insert(upstream)
                    // Consistency (§6.2 step 5) over direct edges between executed commands only: timing edges hold by
                    // construction, and gate paths mostly reach long-finished tasks, diluting real contradictions.
                    if nodes[node].taskId != nil, nodes[upstream].taskId != nil {
                        checked += 1
                        if nodes[upstream].end > nodes[node].start + eps { violations += 1 }
                    }
                }
            }
        }

        // MARK: Swift driver groups

        /// Swift jobs of target T are not commands: planning → emit-module → T's `SwiftDriver Compilation
        /// Requirements` command, planning → compiles → T's `SwiftDriver Compilation` command, and planning after
        /// the executed ancestors of both commands. Order by rule (the driver plans before it runs jobs).
        // ponytail: `dynamicTaskRequest` backtrace frames could order jobs inside a group; no fixture has them.
        mutating func addSwiftDriverGroups() {
            var groups: [Int: SwiftGroup] = [:]
            for node in nodes.indices {
                guard let task = task(node), let target = task.targetId else { continue }
                switch task.ruleName {
                case "SwiftDriver Compilation Requirements" where nodes[node].basis == "dag":
                    groups[target, default: SwiftGroup()].requirements.append(node)
                case "SwiftDriver Compilation" where nodes[node].basis == "dag":
                    groups[target, default: SwiftGroup()].compilation.append(node)
                case "SwiftDriver": groups[target, default: SwiftGroup()].planning.append(node)
                case "SwiftEmitModule", "EmitSwiftModule": groups[target, default: SwiftGroup()].emit.append(node)
                case "SwiftCompile": groups[target, default: SwiftGroup()].compiles.append(node)
                case "SwiftDriverJobDiscovery": groups[target, default: SwiftGroup()].discovery.append(node)
                default: break
                }
            }
            for target in groups.keys.sorted() {
                let group = groups[target]!
                guard !group.requirements.isEmpty || !group.compilation.isEmpty else { continue }
                var base = Set<Int>()
                for gate in group.requirements + group.compilation { base.formUnion(preds[gate]) }
                for plan in group.planning {
                    preds[plan].formUnion(base)
                    nodes[plan].basis = "dag"
                }
                let afterPlanning = group.planning.isEmpty ? base : Set(group.planning)
                for job in group.emit + group.compiles + group.discovery {
                    preds[job].formUnion(afterPlanning)
                    nodes[job].basis = "dag"
                }
                // Job discovery (sub-millisecond) follows planning and gates nothing the path needs: keeping it off
                // the gates' inputs lets the path reach the job that actually finished last.
                for gate in group.requirements {
                    preds[gate].formUnion(group.emit.isEmpty ? afterPlanning : Set(group.emit))
                }
                for gate in group.compilation {
                    preds[gate].formUnion(group.compiles.isEmpty ? afterPlanning : Set(group.compiles))
                }
                for gate in group.requirements + group.compilation { preds[gate].remove(gate) }
            }
        }

        struct SwiftGroup {
            var requirements: [Int] = []
            var compilation: [Int] = []
            var planning: [Int] = []
            var emit: [Int] = []
            var compiles: [Int] = []
            var discovery: [Int] = []
        }

        // MARK: Explicit modules

        /// PCM and interface tasks name no target: each attaches (byTiming) to every target whose planning it follows
        /// and whose first compile it precedes, through a per-target gate, and to the explicit-module task that ended
        /// last before it started (the module chain the manifest does not record).
        mutating func addExplicitModuleTasks() {
            let moduleNodes = nodes.indices.filter { node in
                guard nodes[node].basis != "dag", let task = task(node) else { return false }
                return task.kind == .modulePrecompile || task.kind == .moduleScan
            }
            guard !moduleNodes.isEmpty else { return }
            var planEnd: [Int: Double] = [:]
            var plans: [Int: [Int]] = [:]
            var firstCompile: [Int: Double] = [:]
            var compiles: [Int: [Int]] = [:]
            for node in nodes.indices {
                guard let task = task(node), let target = task.targetId,
                      model.targets.indices.contains(target), !model.targets[target].isBucket else { continue }
                switch task.kind {
                case .swiftPlan where task.ruleName == "SwiftDriver":
                    planEnd[target] = max(planEnd[target] ?? -.infinity, nodes[node].end)
                    plans[target, default: []].append(node)
                case .swiftCompile, .swiftEmitModule, .clangCompile:
                    firstCompile[target] = min(firstCompile[target] ?? .infinity, nodes[node].start)
                    compiles[target, default: []].append(node)
                default: break
                }
            }
            var gates: [Int: Int] = [:]
            for node in moduleNodes {
                let item = nodes[node]
                for target in planEnd.keys.sorted() {
                    guard let end = planEnd[target], let first = firstCompile[target],
                          end <= item.start + eps, item.end <= first + eps else { continue }
                    for plan in plans[target] ?? [] { timingPreds[node].insert(plan) }
                    let gate: Int
                    if let existing = gates[target] {
                        gate = existing
                    } else {
                        gate = addNode(Node(taskId: nil, start: item.end, end: item.end, targetId: target,
                                            basis: "byTiming"))
                        gates[target] = gate
                        for job in compiles[target] ?? [] { timingPreds[job].insert(gate) }
                    }
                    timingPreds[gate].insert(node)
                    nodes[gate].start = max(nodes[gate].start, item.end)
                    nodes[gate].end = nodes[gate].start
                }
            }
            let byEnd = moduleNodes.sorted { nodes[$0].end != nodes[$1].end ? nodes[$0].end < nodes[$1].end : $0 < $1 }
            let ends = byEnd.map { nodes[$0].end }
            for node in moduleNodes {
                if let q = latestFinisher(before: nodes[node], among: byEnd, ends: ends, excluding: node) {
                    timingPreds[node].insert(q)
                }
            }
        }

        /// Latest-ending node of `sorted` (by end) that ends by `item.start + eps`, starts before it and has a length.
        // ponytail: scans back at most 4096 nodes; a log with more tasks finishing inside one eps would need an
        // interval index.
        func latestFinisher(before item: Node, among sorted: [Int], ends: [Double], excluding: Int) -> Int? {
            var high = upperBound(ends, item.start + eps)
            var scanned = 0
            while high > 0, scanned < 4096 {
                high -= 1
                scanned += 1
                let candidate = sorted[high]
                if candidate != excluding, nodes[candidate].start < item.start, nodes[candidate].end > nodes[candidate].start {
                    return candidate
                }
            }
            return nil
        }

        // MARK: Roots

        /// A task node with no predecessor that starts after the window start attaches (byTiming) to the task that
        /// ended last before it: build-system steps outside the manifest, and commands whose inputs were all up to
        /// date.
        mutating func addRootsByTiming() {
            let reach = reachesTask()
            let taskNodes = nodes.indices.filter { nodes[$0].taskId != nil }
            let byEnd = taskNodes.sorted { nodes[$0].end != nodes[$1].end ? nodes[$0].end < nodes[$1].end : $0 < $1 }
            let ends = byEnd.map { nodes[$0].end }
            for node in taskNodes where !reach[node] {
                guard nodes[node].start > window.start + eps else { continue }
                if let q = latestFinisher(before: nodes[node], among: byEnd, ends: ends, excluding: node) {
                    timingPreds[node].insert(q)
                }
            }
        }

        /// Per node: some task precedes it, directly or through virtual nodes. Iterative DFS, O(V + E); a node met
        /// again while in progress (a cycle) counts as reaching nothing.
        func reachesTask() -> [Bool] {
            var reach = [Bool?](repeating: nil, count: nodes.count)
            for root in nodes.indices where reach[root] == nil {
                var stack: [(node: Int, expanded: Bool)] = [(root, false)]
                while let (node, expanded) = stack.popLast() {
                    let inputs = preds[node].union(timingPreds[node])
                    if expanded {
                        reach[node] = inputs.contains { nodes[$0].taskId != nil || reach[$0] == true }
                        continue
                    }
                    if reach[node] != nil { continue }
                    reach[node] = false
                    stack.append((node, true))
                    for p in inputs where reach[p] == nil { stack.append((p, false)) }
                }
            }
            return reach.map { $0 ?? false }
        }

        // MARK: Finish

        mutating func finish() -> TaskDAG? {
            var all = zip(preds, timingPreds).map { $0.union($1) }
            var order = topologicalOrder(all)
            if order == nil {
                notes.append("timing edges formed a cycle and were dropped")
                all = preds
                order = topologicalOrder(all)
            }
            guard let topo = order else { return nil }
            let sortedPreds = all.map { $0.sorted() }
            for v in topo where nodes[v].taskId == nil {
                let opened = sortedPreds[v].map { nodes[$0].end }.max() ?? -.infinity
                nodes[v].start = opened
                nodes[v].end = opened
            }
            return TaskDAG(nodes: nodes, preds: sortedPreds, topo: topo, nodeOfTask: nodeOfTask, matchedTasks: matched,
                           checkedEdges: checked, violations: violations, notes: notes)
        }

        func topologicalOrder(_ preds: [Set<Int>]) -> [Int]? {
            var indegree = preds.map(\.count)
            var successors = [[Int]](repeating: [], count: preds.count)
            for (v, set) in preds.enumerated() { for u in set { successors[u].append(v) } }
            var ready = indegree.indices.filter { indegree[$0] == 0 }
            var order: [Int] = []
            order.reserveCapacity(preds.count)
            var head = 0
            while head < ready.count {
                let u = ready[head]
                head += 1
                order.append(u)
                for v in successors[u] {
                    indegree[v] -= 1
                    if indegree[v] == 0 { ready.append(v) }
                }
            }
            return order.count == preds.count ? order : nil
        }
    }
}

/// First index whose value is greater than `value` in an ascending array.
func upperBound(_ values: [Double], _ value: Double) -> Int {
    var low = 0
    var high = values.count
    while low < high {
        let mid = (low + high) / 2
        if values[mid] <= value { low = mid + 1 } else { high = mid }
    }
    return low
}
