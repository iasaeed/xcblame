import Foundation

/// Every v0.2 "Explain" engine over one model, in dependency order: timeline → DAG (when a description matches) →
/// critical path (DAG, else inference) → utilization → kind → owners → hotspots → files. Pure; the report document
/// maps it to its members.
struct Explain {
    var timeline: Timing.Timeline
    var dag: TaskDAG?
    /// The description covered < 95 % of the log's planned keyed tasks: it is not this build's and was not used.
    var descriptionDropped = false
    /// `graph.notes` additions: match coverage, consistency result, why the DAG was not used.
    var graphNotes: [String]
    var path: PathResult?
    var utilization: UtilizationResult?
    var kind: BuildKindResult
    var owners: [Int: String]
    var hotspots: HotspotsResult
    var files: [FileRowValue]
    /// V3, V9, V11, computed here because they need the path, the file rows and the kind.
    var checks: [Check]
    /// Member name → why a failed check withheld it.
    var withheld: [String: String]
    // v0.5 lane C (begin): nil until the engines land (`FixedCosts`, `ModuleGraph`, `CacheMetrics`).
    var fixedCosts: [ReportDocument.FixedCost]? = nil
    var moduleGraph: ReportDocument.ModuleGraph? = nil
    var cache: ReportDocument.BuildCache? = nil
    // v0.5 lane C (end)
    // v0.5 lane A (begin): rows each hotspot reader produced; nil without `--deep`.
    var deepSources: ReportDocument.Deep.Sources? = nil
    /// Why a deep reader produced nothing (missing stats folder, cache-hit TUs without a trace).
    var deepNotes: [String] = []
    // v0.5 lane A (end)

    var windowStart: Double { timeline.window.start }

    static func run(model: BuildModel, analysis: Analysis, description: BuildDescription?,
                    physicalCores: Int?, deep: DeepRun? = nil, project: ProjectModel? = nil) -> Explain {
        let timeline = Timing.timeline(model)
        var graphNotes: [String] = []
        var dag: TaskDAG?
        var pathNotes: [String] = []
        var description = description
        var descriptionDropped = false
        var unmatched = false
        // §5.11: whatever its source (explicit, snapshot, live), a description must cover ≥ 95 % of the log's planned
        // keyed tasks; below that it belongs to another build and is dropped before anything reads it.
        if let candidate = description,
           case let cover = BuildDescriptionLocator.coverage(of: candidate, model: model),
           let share = cover.share, share < BuildDescriptionLocator.coverageThreshold {
            graphNotes.append(String(format: "dropped: %d of %d planned keyed tasks (%.0f%%) are commands of this "
                + "description, below 95%%: it is not this build's", cover.matched, cover.planned, share * 100))
            pathNotes.append(String(format: "build description dropped (key coverage %.0f%% < 95%%); path inferred",
                                    share * 100))
            description = nil
            descriptionDropped = true
        }
        if let description {
            if let built = TaskDAG.build(model: model, counted: timeline.counted, description: description,
                                         window: timeline.window) {
                graphNotes.append(contentsOf: built.notes)
                let summary = String(format: "%d executed task(s) are commands; consistency %d of %d edges late "
                    + "by > 50 ms (%.2f%%)", built.matchedTasks, built.violations, built.checkedEdges,
                    built.violationShare * 100)
                graphNotes.append(summary)
                if built.matchedTasks == 0 {
                    unmatched = true
                    graphNotes.append("dropped: no executed task is a command of this description")
                    pathNotes.append("build description dropped (no task matched a command); path inferred")
                } else if built.isConsistent {
                    dag = built
                } else {
                    graphNotes.append("dropped: more than 1% of DAG edges contradict the timing; the description "
                        + "does not belong to this build")
                    pathNotes.append("build description dropped by the consistency check; path inferred")
                }
            } else {
                graphNotes.append("dropped: the description's edges contain a cycle")
                pathNotes.append("build description dropped (cycle); path inferred")
            }
        }

        // Dropped like a coverage miss: nothing downstream reads it and `graph.basis` is `none`.
        if unmatched {
            description = nil
            descriptionDropped = true
        }

        let timed = !analysis.noTiming && !timeline.counted.isEmpty
        var path: PathResult?
        if timed {
            if let dag {
                path = CriticalPath.fromDAG(dag, model: model)
            }
            if path == nil {
                path = CriticalPath.inferred(counted: timeline.counted, model: model,
                                             targetGraph: description?.targetGraph ?? [],
                                             windowStart: timeline.window.start)
                if description == nil, !descriptionDropped {
                    pathNotes.append("no build description: path inferred from timing")
                }
            }
            if let basis = path?.basis, basis != "inferred" {
                path?.notes.append("DAG for planned tasks and Swift jobs; byTiming for explicit-module tasks and "
                    + "build-system steps the manifest does not name")
            }
            path?.notes.insert(contentsOf: pathNotes, at: 0)
        }

        let utilization: UtilizationResult? = timed ? Utilization.compute(
            intervals: timeline.counted.map {
                Interval(start: $0.interval.start - timeline.window.start, end: $0.interval.end - timeline.window.start)
            },
            span: analysis.span, peak: analysis.peakParallelism, physicalCores: physicalCores) : nil

        // V3, V9, V11 (§6.11): a failed check withholds its member ("unavailable because ...").
        var withheld: [String: String] = [:]
        let v3 = Validator.applyDrift(Validator.checkV3(path: path, dag: path?.basis == "inferred" ? nil : dag,
                                                        counted: timeline.counted, window: timeline.window),
                                      drift: Validator.timingDrift(in: model))
        if case let .fail(reason) = v3.status {
            path = nil
            withheld["criticalPath"] = "V3 failed: \(reason)"
        }
        // v0.5 lane C (begin): cache counters feed the `cached` kind.
        let cache = CacheMetrics.compute(model: model, counted: timeline.counted)
        // v0.5 lane C (end)
        var kind = BuildKind.classify(model: model, counted: timeline.counted, reused: timeline.reused,
                                      request: description?.buildRequest, cache: cache,
                                      descriptionDirectory: description?.directory)
        let v11 = Validator.checkV11(kind)
        if case let .fail(reason) = v11.status {
            kind = BuildKindResult(kind: nil, evidence: [], reason: "withheld because V11 failed: \(reason)",
                                   counts: kind.counts)
        }
        let pathTaskIds = path?.taskIds
        var hotspots = Hotspots.compute(counted: timeline.counted, model: model, pathTaskIds: pathTaskIds)
        // v0.5 lane A (begin): stats-dir and ftime-trace rows under `--deep`; `estimated` file rows from type-check text.
        let deepMerge = Hotspots.mergeDeep(hotspots, deep: deep, counted: timeline.counted, model: model,
                                           pathTaskIds: pathTaskIds)
        hotspots = deepMerge.result
        // v0.5 lane A (end)
        var files = FileAttribution.rows(counted: timeline.counted, model: model, pathTaskIds: pathTaskIds ?? [],
                                         typeCheckMs: Hotspots.typeCheckMsByFile(hotspots.rows))
        // v0.5 lane A (begin)
        // Interleaved by seconds (stable), so `--top` cuts estimated and measured rows alike.
        files = (files + FileAttribution.estimatedRows(counted: timeline.counted, model: model, hotspots: hotspots.rows,
                                                        pathTaskIds: pathTaskIds ?? []))
            .enumerated().sorted { $0.element.seconds != $1.element.seconds ? $0.element.seconds > $1.element.seconds
                : $0.offset < $1.offset }.map(\.element)
        // v0.5 lane A (end)
        let v9 = Validator.checkV9(files: files, counted: timeline.counted)
        if case let .fail(reason) = v9.status {
            files = []
            withheld["files"] = "V9 failed: \(reason)"
        }
        let owners = Owner.classify(model: model)
        var explain = Explain(timeline: timeline, dag: dag, descriptionDropped: descriptionDropped, graphNotes: graphNotes, path: path, utilization: utilization,
                              kind: kind, owners: owners, hotspots: hotspots, files: files,
                              checks: [v3, v9, v11], withheld: withheld)
        // v0.5 lane C (begin)
        explain.cache = cache
        explain.fixedCosts = FixedCosts.compute(model: model, timeline: timeline, kind: kind, path: path, project: project)
        explain.moduleGraph = ModuleGraph.compute(model: model, description: description, timeline: timeline,
                                                  path: path, owners: owners, project: project)
        // v0.5 lane C (end)
        // v0.5 lane A (begin)
        explain.deepSources = deepMerge.sources
        explain.deepNotes = deepMerge.notes
        // v0.5 lane A (end)
        return explain
    }

    /// Short label of a path task: kind or rule plus the file or module, never a command line.
    static func label(_ task: BuildTask, model: BuildModel) -> String {
        let target = task.targetId.flatMap { model.targets.indices.contains($0) ? model.targets[$0].name : nil }
        let file = FileAttribution.files(of: task).first.map { ($0 as NSString).lastPathComponent }
        switch task.ruleName {
        case "SwiftCompile", "CompileC": return "compile " + (file ?? target ?? task.ruleName)
        case "SwiftEmitModule", "EmitSwiftModule": return "emit-module " + (target ?? "")
        case "SwiftDriver": return "planning " + (target ?? "")
        case "SwiftDriverJobDiscovery": return "job discovery " + (target ?? "")
        case "SwiftDriver Compilation Requirements", "SwiftDriver Compilation": return "driver gate " + (target ?? "")
        default: break
        }
        if task.kind == .modulePrecompile || task.kind == .moduleScan {
            return task.ruleName == "ScanDependencies" ? "scan dependencies" : "PCM " + moduleName(task)
        }
        if let file { return task.ruleName + " " + file }
        if task.kind == .link, let output = firstPathToken(task) { return "link " + output }
        return task.ruleName
    }

    /// `SwiftShims` from `.../SwiftShims-2427RXV5PFL7BUOTJAJY7PQ6Z.pcm` (or `.scan`).
    static func moduleName(_ task: BuildTask) -> String {
        guard let path = firstPathToken(task) else {
            return task.title.split(separator: " ").last.map(String.init) ?? task.ruleName
        }
        let base = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if let dash = base.lastIndex(of: "-") { return String(base[..<dash]) }
        return base
    }

    /// Basename of the first absolute path on the first line of `commandDetails`.
    static func firstPathToken(_ task: BuildTask) -> String? {
        guard let details = task.commandDetails else { return nil }
        let line = details.prefix { !$0.isNewline }
        guard let token = line.split(separator: " ").first(where: { $0.hasPrefix("/") }) else { return nil }
        return (String(token) as NSString).lastPathComponent
    }
}
