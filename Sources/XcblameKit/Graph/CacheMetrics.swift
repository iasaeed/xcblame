import Foundation

// v0.5 lane C (docs/SCHEMA-v0.5.md "Build kinds and cache"): build-level cache counters (DESIGN §6.7 `cached`,
// MV-12).
enum CacheMetrics {
    /// One `BuildOperationMetrics` attachment. 26.0.1 writes the flat legacy shape (`clangCacheHits`,
    /// `clangCacheMisses`, `swiftCacheHits`, `swiftCacheMisses`, zeros present); 27.1 writes `{"counters": {…},
    /// "taskCounters": {"<RuleName>": {"cacheHits"|"cacheMisses": n}}}` with zero keys omitted (probes-v0.5.md MV-12).
    struct Counters: Equatable {
        var hits: Int
        var misses: Int
        /// Per rule name, from `taskCounters` (27.1 shape only; empty for the legacy shape).
        var byRule: [String: (hits: Int, misses: Int)]

        static func == (lhs: Counters, rhs: Counters) -> Bool {
            lhs.hits == rhs.hits && lhs.misses == rhs.misses && lhs.byRule.mapValues { [$0.hits, $0.misses] }
                == rhs.byRule.mapValues { [$0.hits, $0.misses] }
        }
    }

    /// Per-task replay from task output: every cacheable task's emitted output is exactly `Cache hit` (replayed from
    /// the cache) or `Cache miss` (executed and stored), MV-12. Exact, not a heuristic.
    struct Replay: Equatable {
        var hits: Int
        var misses: Int
        var hitsByRule: [String: Int]
    }

    static let attachmentSuffix = "BuildOperationMetrics"

    /// Both shapes; nil when the data is not a metrics object or carries no cache key.
    static func decode(_ data: Data) -> Counters? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func number(_ object: [String: Any], _ key: String) -> Int? { (object[key] as? NSNumber)?.intValue }
        let keys = ["clangCacheHits", "clangCacheMisses", "swiftCacheHits", "swiftCacheMisses"]
        let counters = root["counters"] as? [String: Any] ?? root
        let present = keys.filter { number(counters, $0) != nil }
        var byRule: [String: (hits: Int, misses: Int)] = [:]
        for (rule, value) in root["taskCounters"] as? [String: Any] ?? [:] {
            guard let body = value as? [String: Any] else { continue }
            byRule[rule] = (number(body, "cacheHits") ?? 0, number(body, "cacheMisses") ?? 0)
        }
        // The 27.1 shape omits zero keys: `{"counters":{}}` is a build with caching on and nothing cacheable.
        guard !present.isEmpty || root["counters"] != nil || !byRule.isEmpty else { return nil }
        let hits = (number(counters, "clangCacheHits") ?? 0) + (number(counters, "swiftCacheHits") ?? 0)
        let misses = (number(counters, "clangCacheMisses") ?? 0) + (number(counters, "swiftCacheMisses") ?? 0)
        return Counters(hits: hits, misses: misses, byRule: byRule)
    }

    /// Σ over every `BuildOperationMetrics` attachment of the model (one per build in practice); nil when none decodes.
    static func counters(_ model: BuildModel) -> Counters? {
        let decoded = model.buildAttachments.filter { $0.identifier.hasSuffix(attachmentSuffix) }.compactMap { decode($0.data) }
        guard var total = decoded.first else { return nil }
        for more in decoded.dropFirst() {
            total.hits += more.hits
            total.misses += more.misses
            for (rule, value) in more.byRule {
                let old = total.byRule[rule] ?? (0, 0)
                total.byRule[rule] = (old.hits + value.hits, old.misses + value.misses)
            }
        }
        return total
    }

    /// Kinds the compilation cache can replay (compiles, emit-module, module scans and builds, links); a script phase
    /// that prints `Cache hit` is not a replay.
    static let cacheableKinds: Set<TaskKind> = [.swiftCompile, .swiftEmitModule, .moduleScan, .modulePrecompile,
                                                .clangCompile, .link]

    /// Cacheable tasks whose trimmed emitted output is exactly `Cache hit` / `Cache miss`.
    static func replay(_ model: BuildModel) -> Replay {
        var replay = Replay(hits: 0, misses: 0, hitsByRule: [:])
        for task in model.tasks where cacheableKinds.contains(task.kind) {
            guard let output = task.emittedOutput, output.count < 32 else { continue }
            switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "Cache hit":
                replay.hits += 1
                replay.hitsByRule[task.ruleName, default: 0] += 1
            case "Cache miss":
                replay.misses += 1
            default:
                break
            }
        }
        return replay
    }

    /// `BuildOperationMetrics` counters (source `buildOperationMetrics`), else the per-task `Cache hit` / `Cache miss`
    /// lines alone (source `casRemarks`); nil when the log has neither (compilation caching off: most builds).
    /// `replayedTasks` is the exact count of `Cache hit` task outputs (MV-12; null when no task printed either line);
    /// `replayedTasksHeuristic` stays nil, since the §6.7 heuristic is never needed when the exact count exists (and it
    /// needs the history task index, which v0.5 does not consult for it).
    static func compute(model: BuildModel, counted: [Timing.Counted]) -> ReportDocument.BuildCache? {
        let replay = replay(model)
        let exact = replay.hits + replay.misses > 0 ? replay.hits : nil
        if let counters = counters(model) {
            return ReportDocument.BuildCache(hits: counters.hits, misses: counters.misses, replayedTasks: exact,
                                             replayedTasksHeuristic: nil, source: "buildOperationMetrics")
        }
        guard exact != nil else { return nil }
        return ReportDocument.BuildCache(hits: replay.hits, misses: replay.misses, replayedTasks: exact,
                                         replayedTasksHeuristic: nil, source: "casRemarks")
    }

    /// `cache: 112 task(s) replayed from the compilation cache (output "Cache hit"), 0 executed and stored ("Cache
    /// miss")`; nil when no task printed either line.
    static func replayNote(_ model: BuildModel) -> String? {
        let replay = replay(model)
        guard replay.hits + replay.misses > 0 else { return nil }
        let rules = replay.hitsByRule.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        return "cache: \(replay.hits) task(s) replayed from the compilation cache (task output \"Cache hit\")"
            + (rules.isEmpty ? "" : " [\(rules)]") + ", \(replay.misses) executed and stored (\"Cache miss\"); exact "
            + "per task, not the duration heuristic"
    }
}
