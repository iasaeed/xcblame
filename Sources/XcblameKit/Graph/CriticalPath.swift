import Foundation

/// Critical path over the session window (DESIGN §6.2): from the task DAG when a matching description passed the
/// consistency check, else by timing inference. Times are absolute (Unix seconds, clamped to the window).
struct PathResult {
    struct Segment {
        var start: Double
        var end: Double
        /// `dag` / `byTiming` / `inferred`.
        var basis: String
        var targetId: Int?
        var taskIds: [Int]
    }

    struct WhatIf {
        var targetId: Int?
        var name: String
        var savingIfZero: Double
        var savingIfHalf: Double
    }

    var segments: [Segment]
    var waits: [(start: Double, end: Double)]
    /// `dag` / `inferred` / `mixed`.
    var basis: String
    var whatIf: [WhatIf]?
    var notes: [String]
    /// Slack (§6.2 step 4: latest start − earliest start at unlimited cores) per DAG task id; empty under inference.
    // ponytail: no schema member carries per-task slack; kept here and summarized in `notes`.
    var slack: [Int: Double] = [:]

    var start: Double { segments.first?.start ?? 0 }
    var end: Double { segments.last?.end ?? 0 }
    var span: Double { end - start }
    var taskIds: Set<Int> { Set(segments.flatMap(\.taskIds)) }
}

enum CriticalPath {
    static let eps = TaskDAG.eps
    /// Latest finishers looked at per inference step (§6.2).
    static let window = 64

    struct Step {
        var taskId: Int
        var start: Double
        var end: Double
        var basis: String
        var targetId: Int?
    }

    // MARK: - DAG

    /// Walks back from the latest-ending task, each time to the predecessor that ended last (the one that gated
    /// the start); ties go to the longer weighted chain. Virtual gates and zero-length tasks are walked through.
    static func fromDAG(_ dag: TaskDAG, model: BuildModel) -> PathResult? {
        let finish = dag.earliestFinish()
        func better(_ a: Int, than b: Int) -> Bool {
            let x = dag.nodes[a], y = dag.nodes[b]
            if x.end != y.end { return x.end > y.end }
            if finish[a] != finish[b] { return finish[a] > finish[b] }
            return a < b
        }
        let timed = dag.nodes.indices.filter { dag.nodes[$0].weight > 0 }
        guard var current = timed.max(by: { a, b in
            let x = dag.nodes[a], y = dag.nodes[b]
            if x.end != y.end { return x.end < y.end }
            if x.weight != y.weight { return x.weight < y.weight }
            return a > b
        }) else { return nil }
        var steps: [Step] = []
        var visited = Set<Int>()
        while visited.insert(current).inserted {
            let node = dag.nodes[current]
            if let id = node.taskId, node.weight > 0 {
                steps.append(Step(taskId: id, start: node.start, end: node.end, basis: node.basis,
                                  targetId: node.targetId))
            }
            guard let next = dag.preds[current].filter({ !visited.contains($0) }).max(by: { better($1, than: $0) })
            else { break }
            current = next
        }
        let (segments, waits) = segments(from: steps.reversed())
        let bases = Set(segments.map(\.basis))
        let basis = bases == ["dag"] ? "dag" : "mixed"
        let (length, slack) = dag.longestPathAndSlack()
        var taskSlack: [Int: Double] = [:]
        for (v, node) in dag.nodes.enumerated() { if let id = node.taskId { taskSlack[id] = slack[v] } }
        let tolerance = 1e-9 * max(1, length)
        let critical = Set(dag.nodes.indices.filter { slack[$0] <= tolerance }.compactMap { dag.nodes[$0].targetId })
        let onPath = Set(segments.compactMap(\.targetId))
        let zeroSlack = taskSlack.values.filter { $0 <= tolerance }.count
        return PathResult(segments: segments, waits: waits, basis: basis,
                          whatIf: whatIf(dag, model: model, length: length,
                                         span: segments.isEmpty ? 0 : segments[segments.count - 1].end - segments[0].start,
                                         compute: critical.union(onPath)),
                          notes: [String(format: "slack: %d of %d DAG tasks have zero slack (on a longest path at "
                              + "unlimited cores, %.3f s)", zeroSlack, taskSlack.count, length)],
                          slack: taskSlack)
    }

    /// Per target: the weighted longest path with that target's tasks at 0 and at half their duration. Savings are
    /// `L - L'` with `L` the longest path at measured weights (unlimited cores), capped at the path span. One pass
    /// per target in `compute` (those with a zero-slack or on-path node); any other target lies on no longest path,
    /// so shrinking it saves exactly 0.
    static func whatIf(_ dag: TaskDAG, model: BuildModel, length full: Double, span: Double,
                       compute: Set<Int>) -> [PathResult.WhatIf] {
        let targets = Set(dag.nodes.compactMap { $0.taskId == nil ? nil : $0.targetId })
        var rows: [PathResult.WhatIf] = []
        for target in targets.sorted() where model.targets.indices.contains(target) {
            var savingZero = 0.0, savingHalf = 0.0
            if compute.contains(target) {
                let shrunk = dag.longestPath(shrinking: target)
                savingZero = min(span, max(0, full - shrunk.zero))
                savingHalf = min(savingZero, max(0, full - shrunk.half))
            }
            rows.append(PathResult.WhatIf(targetId: target, name: model.targets[target].name,
                                          savingIfZero: savingZero, savingIfHalf: savingHalf))
        }
        return rows.sorted {
            $0.savingIfZero != $1.savingIfZero ? $0.savingIfZero > $1.savingIfZero : $0.name < $1.name
        }
    }

    // MARK: - Inference

    /// §6.2 fallback: from the latest-ending task, repeatedly step to the latest finisher among the 64 tasks that end
    /// by `cur.start + eps`; among finishers within `eps` of that latest end, a constraint predecessor (same target,
    /// earlier step; or a dependency target's emit-module or link) wins.
    static func inferred(counted: [Timing.Counted], model: BuildModel, targetGraph: [BuildDescription.Edge],
                         windowStart: Double) -> PathResult? {
        let tasks = counted.filter { $0.interval.duration > 0 }.sorted {
            if $0.interval.end != $1.interval.end { return $0.interval.end < $1.interval.end }
            if $0.interval.duration != $1.interval.duration { return $0.interval.duration < $1.interval.duration }
            return $0.task.id > $1.task.id
        }
        guard var current = tasks.indices.last else { return nil }
        let ends = tasks.map(\.interval.end)
        let deps = dependencies(targetGraph, model: model)
        var steps: [Step] = []
        var used = Set<Int>()
        while true {
            let item = tasks[current]
            used.insert(current)
            steps.append(Step(taskId: item.task.id, start: item.interval.start, end: item.interval.end,
                              basis: "inferred", targetId: item.task.targetId))
            guard item.interval.start > windowStart + eps else { break }
            let high = upperBound(ends, item.interval.start + eps)
            var candidates: [Int] = []
            var index = high
            while index > 0, candidates.count < window {
                index -= 1
                if used.contains(index) || tasks[index].interval.start >= item.interval.start { continue }
                candidates.append(index)
            }
            guard let latest = candidates.first else { break }
            let near = candidates.filter { tasks[$0].interval.end >= tasks[latest].interval.end - eps }
            let constrained = near.first { isConstraint(tasks[$0].task, before: item.task, deps: deps) }
            current = constrained ?? latest
        }
        let (segments, waits) = segments(from: steps.reversed())
        return PathResult(segments: segments, waits: waits, basis: "inferred", whatIf: nil,
                          notes: ["inferred from timing (eps 50 ms, 64 latest finishers per step)"])
    }

    /// Target id → ids of the targets it depends on, by name from `target-graph.txt`.
    static func dependencies(_ edges: [BuildDescription.Edge], model: BuildModel) -> [Int: Set<Int>] {
        guard !edges.isEmpty else { return [:] }
        var byName: [String: [Int]] = [:]
        for target in model.targets where !target.isBucket { byName[target.name, default: []].append(target.id) }
        var deps: [Int: Set<Int>] = [:]
        for edge in edges where edge.from != edge.to {
            for from in byName[edge.from] ?? [] { deps[from, default: []].formUnion(byName[edge.to] ?? []) }
        }
        return deps
    }

    static func isConstraint(_ candidate: BuildTask, before task: BuildTask, deps: [Int: Set<Int>]) -> Bool {
        guard let target = task.targetId, let other = candidate.targetId else { return false }
        if other == target { return rank(candidate.kind) < rank(task.kind) }
        return deps[target]?.contains(other) == true
            && (candidate.kind == .swiftEmitModule || candidate.kind == .link)
    }

    /// Order of steps inside one target.
    static func rank(_ kind: TaskKind) -> Int {
        switch kind {
        case .planning, .packageResolution: return 0
        case .sdkStatCache: return 1
        case .moduleScan, .swiftPlan: return 2
        case .modulePrecompile: return 3
        case .swiftEmitModule: return 4
        case .swiftCompile, .clangCompile: return 5
        case .gate: return 6
        case .link: return 7
        case .codesign, .validate: return 9
        case .script, .assets, .resources, .copy, .metadata, .aux, .clean, .other: return 8
        }
    }

    // MARK: - Segments

    /// Steps in time order → disjoint segments and waits. A gap > eps is a wait; a smaller gap or an overlap moves
    /// the segment start to the previous end, so Σ segments + Σ waits equals the path span exactly. A step fully
    /// covered by the previous one joins that segment.
    static func segments(from steps: some Sequence<Step>) -> ([PathResult.Segment], [(start: Double, end: Double)]) {
        var segments: [PathResult.Segment] = []
        var waits: [(start: Double, end: Double)] = []
        for step in steps {
            var start = step.start
            if let last = segments.last {
                if start - last.end > eps {
                    waits.append((last.end, start))
                } else {
                    start = last.end
                }
                if step.end <= start {
                    segments[segments.count - 1].taskIds.append(step.taskId)
                    continue
                }
            }
            guard step.end > start else { continue }
            segments.append(PathResult.Segment(start: start, end: step.end, basis: step.basis,
                                               targetId: step.targetId, taskIds: [step.taskId]))
        }
        return (segments, waits)
    }
}
