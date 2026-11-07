import Foundation

/// Build-kind classification of DESIGN §6.7: structural signals first (`build-request.json`), then counts of executed
/// and reused tasks. Never from titles.
struct BuildKindResult {
    /// One of `BuildKind.vocabulary`; nil when nothing decides.
    var kind: String?
    /// Strongest first; empty iff `kind` is nil.
    var evidence: [String]
    /// Why `kind` is nil.
    var reason: String?
    /// Counts V11 re-checks.
    var counts: Counts

    struct Counts {
        var executed: Int
        var reused: Int
        /// Executed compile, plan, emit-module, module-precompile or link tasks.
        var compileExecuted: Int
        var descriptionTaskExecuted: Bool
        /// The `Build description signature:` line: this build created its description.
        var descriptionCreated: Bool
        /// Every model task is planning, clean or gate (`BuildModelBuilder.isCleanAction`).
        var cleanActionShape: Bool
    }
}

enum BuildKind {
    /// Every kind a report may carry (DESIGN §6.7). `cached` and `previews` are v0.5 (lane C) and not produced until
    /// their signals are read; `previews`, `index` and `analyze` stay out of trends and baselines by default.
    static let vocabulary = ["clean", "incremental", "zero-change", "clean-action", "cached", "index", "previews",
                                    "analyze", "archive", "test"]

    /// Kinds that mean "the build compiled, planned or linked something" (§6.7 zero-change).
    static let workKinds: Set<TaskKind> = [.swiftCompile, .swiftPlan, .swiftEmitModule, .clangCompile, .link,
                                           .modulePrecompile]

    static func classify(model: BuildModel, counted: [Timing.Counted], reused: Int,
                         request: BuildDescription.BuildRequest?, cache: ReportDocument.BuildCache? = nil,
                         descriptionDirectory: URL? = nil) -> BuildKindResult {
        let descriptionTask = counted.first { $0.task.ruleName == "CreateBuildDescription" }?.task
        let created = descriptionTask.flatMap(BuildDescriptionLocator.createdSignature(of:))
        let counts = BuildKindResult.Counts(
            executed: counted.count, reused: reused,
            compileExecuted: counted.filter { workKinds.contains($0.task.kind) }.count,
            descriptionTaskExecuted: descriptionTask != nil, descriptionCreated: created != nil,
            cleanActionShape: BuildModelBuilder.isCleanAction(model))
        func result(_ kind: String, _ evidence: [String]) -> BuildKindResult {
            BuildKindResult(kind: kind, evidence: evidence, reason: nil, counts: counts)
        }

        var structural: [String] = []
        if let request {
            if request.enableIndexBuildArena == true {
                return result("index", ["build-request.json enableIndexBuildArena=true"])
            }
            if let action = request.action {
                let evidence = "build-request.json action=\(action)"
                switch action {
                case "analyze": return result("analyze", [evidence])
                case "archive", "install": return result("archive", [evidence])
                case _ where action.contains("test"): return result("test", [evidence])
                default: structural.append(evidence)
                }
            }
        }
        // v0.5 lane C (begin): `previews` (Previews arena, MV-17) and `cached` (build-level cache hits > 0).
        if let special = cachedOrPreviews(model: model, counts: counts, request: request, cache: cache,
                                          descriptionDirectory: descriptionDirectory) {
            return special
        }
        // v0.5 lane C (end)
        if counts.cleanActionShape {
            return result("clean-action", structural + ["\(model.tasks.count) task(s), all planning/clean/gate and "
                + "no build-description task"])
        }
        let reusedText = "\(reused) reused task(s)"
        if counts.compileExecuted == 0, !model.tasks.isEmpty {
            return result("zero-change", structural + ["0 compile, plan or link tasks executed", reusedText])
        }
        if reused > 0 { return result("incremental", structural + [reusedText]) }
        if let created {
            return result("clean", structural + ["build description created (signature \(created.prefix(8)))",
                                                 reusedText])
        }
        if counts.descriptionTaskExecuted {
            // SLF writes the signature line whenever the build creates its description (Xcode 26 corpus fixtures); its
            // absence means the description was reused. The xcresult JSON may not carry the line: no claim there.
            if model.readerKind == .slf {
                return result("incremental", structural + ["build description reused (no signature line)", reusedText])
            }
            return result("clean", structural + ["CreateBuildDescription executed", reusedText])
        }
        return BuildKindResult(kind: nil, evidence: [],
                               reason: model.tasks.isEmpty ? "no tasks in the log"
                                   : "nothing decides it (no build-description task, no up-to-date task)",
                               counts: counts)
    }

    // v0.5 lane C (begin)
    /// `previews` or `cached` when their signal is present (DESIGN §6.7); nil otherwise (classification goes on by
    /// counts). `previews` first: a preview build may also hit the cache.
    static func cachedOrPreviews(model: BuildModel, counts: BuildKindResult.Counts,
                                 request: BuildDescription.BuildRequest?, cache: ReportDocument.BuildCache?,
                                 descriptionDirectory: URL?) -> BuildKindResult? {
        if let evidence = previewsSignal(request: request, descriptionDirectory: descriptionDirectory) {
            return BuildKindResult(kind: "previews", evidence: [evidence], reason: nil, counts: counts)
        }
        if let cache, let hits = cache.hits, hits > 0 {
            let source = cache.source == "buildOperationMetrics" ? "BuildOperationMetrics" : "task output \"Cache hit\""
            var evidence = ["\(source): \(hits) cache hit(s), \(cache.misses ?? 0) miss(es)"]
            // v0.5 integration: the exact per-task count next to the counters (27.1: 113 counted, 112 lines).
            if cache.source == "buildOperationMetrics", let replayed = cache.replayedTasks {
                let unmatched = hits - replayed
                evidence.append("task output \"Cache hit\": \(replayed) replayed task(s)" + (unmatched == 0 ? ""
                    : unmatched > 0 ? " (\(unmatched) counted hit(s) without a matching task line)"
                    : " (\(-unmatched) more than the counters)"))
            }
            return BuildKindResult(kind: "cached", evidence: evidence + ["\(counts.reused) reused task(s)"],
                                   reason: nil, counts: counts)
        }
        return nil
    }

    /// The Previews arena signals (MV-17 is open: no previews log was probed, so each row is the expected shape, not an
    /// observed one, and the evidence says it is a heuristic). A path counts only in Xcode's arena layout, with a path
    /// component exactly `Previews` under `Intermediates.noindex` or `UserData` (a user's own `~/Previews/dd` is
    /// not). First match wins; nil when none matches.
    static let previewsSignals: [(key: String, matches: @Sendable (String) -> Bool)] = [
        ("buildCommand.command", { $0 == "preview" }),
        ("parameters.arenaInfo.buildIntermediatesPath", { inPreviewsArena($0) }),
        ("parameters.arenaInfo.derivedDataPath", { inPreviewsArena($0) }),
    ]

    /// A component `Previews` right under `Intermediates.noindex` or `UserData`.
    static func inPreviewsArena(_ path: String) -> Bool {
        let parts = path.split(separator: "/")
        return parts.indices.dropFirst().contains { parts[$0] == "Previews"
            && (parts[$0 - 1] == "Intermediates.noindex" || parts[$0 - 1] == "UserData") }
    }

    static func previewsSignal(request: BuildDescription.BuildRequest?, descriptionDirectory: URL?) -> String? {
        let heuristic = " (heuristic: the Previews arena layout, MV-17 unconfirmed)"
        if let request {
            for signal in previewsSignals {
                if let value = request.raw[signal.key], signal.matches(value) {
                    return (signal.key == "buildCommand.command" ? "build-request.json buildCommand.command=\(value)"
                        : "build-request.json \(signal.key) is in the Previews arena") + heuristic
                }
            }
        }
        if let path = descriptionDirectory?.path, inPreviewsArena(path) {
            return "build description under the Previews arena (Intermediates.noindex/Previews)" + heuristic
        }
        return nil
    }
    // v0.5 lane C (end)
}
