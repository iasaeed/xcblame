import Foundation

extension Validator {
    // MARK: - V5

    /// Per-rule sums against Xcode's own "Build Timing Summary". The summary rows are per rule name (`SwiftDriver`,
    /// `SwiftDriver Compilation`, ...), so "per kind" in DESIGN V5 reads "per summary row": the model's outermost
    /// executed tasks are grouped by `ruleName` and each group is compared to the row of the same name.
    /// `|delta| <= max(0.25 s, 2 %)` passes; a task-count difference warns with both counts.
    static func checkV5(_ model: BuildModel, analysis: Analysis) -> Check {
        guard let summary = model.timingSummary, !summary.rows.isEmpty else {
            return Check(id: "V5", title: "", status: .notApplicable, note: "no Build Timing Summary in the log")
        }
        var summarySeconds: [String: Double] = [:]
        var summaryCounts: [String: Int] = [:]
        for row in summary.rows {
            summarySeconds[row.ruleName, default: 0] += row.seconds
            let (sum, overflow) = summaryCounts[row.ruleName, default: 0].addingReportingOverflow(row.taskCount)
            summaryCounts[row.ruleName] = overflow ? .max : sum
        }
        var modelSeconds: [String: Double] = [:]
        var modelCounts: [String: Int] = [:]
        // Same population as timing: valid tasks that actually ran (reused / up-to-date ones are not in the summary).
        for task in model.tasks where task.hasTiming && Timing.isValid(task) {
            if task.slfOnly?.wasFetchedFromCache == true
                || task.start < analysis.sessionStart - Timing.reusedThreshold { continue }
            modelSeconds[task.ruleName, default: 0] += task.duration
            modelCounts[task.ruleName, default: 0] += 1
        }
        var problems: [String] = []
        for rule in summarySeconds.keys.sorted() {
            let expectedSeconds = summarySeconds[rule] ?? 0
            let expectedCount = summaryCounts[rule] ?? 0
            let seconds = modelSeconds[rule] ?? 0
            let count = modelCounts[rule] ?? 0
            let tolerance = max(summaryToleranceSeconds, summaryToleranceShare * expectedSeconds)
            if abs(seconds - expectedSeconds) > tolerance {
                problems.append(String(format: "%@: %.3f s vs summary %.3f s", rule, seconds, expectedSeconds))
            }
            if count != expectedCount {
                problems.append("\(rule): \(count) tasks vs summary \(expectedCount)")
            }
        }
        if problems.isEmpty {
            return Check(id: "V5", title: "", status: .pass, note: "\(summarySeconds.count) rule(s) compared")
        }
        let shown = problems.prefix(3).joined(separator: "; ")
        let more = problems.count > 3 ? " (+\(problems.count - 3) more)" : ""
        return Check(id: "V5", title: "", status: .warn(shown + more))
    }

    // MARK: - V6

    static func checkV6(_ analysis: Analysis) -> Check {
        var problems: [String] = []
        for rollup in [analysis.byKind, analysis.byPhase, analysis.byTarget] {
            if !rollup.hasOtherRow {
                problems.append("\(rollup.dimension): no other/unclassified row")
            }
            let delta = rollup.sumSeconds - rollup.total
            if abs(delta) > 1e-6 * max(1, abs(rollup.total)) {
                problems.append(String(format: "%@: rows sum to %.6f s, total is %.6f s", rollup.dimension,
                                       rollup.sumSeconds, rollup.total))
            }
            if rollup.sumTasks != rollup.totalTasks {
                problems.append("\(rollup.dimension): rows hold \(rollup.sumTasks) tasks, total is \(rollup.totalTasks)")
            }
            if abs(rollup.total - analysis.taskTime) > 1e-6 * max(1, abs(analysis.taskTime)) {
                problems.append("\(rollup.dimension): total differs from task time")
            }
        }
        return Check(id: "V6", title: "", status: problems.isEmpty ? .pass : .fail(problems.joined(separator: "; ")))
    }

    // MARK: - V8

    /// Real targets only: no duplicate identities, no empty names, none named after a build-system step (a rule
    /// name from the kind table), and every task points at a target that exists.
    static func checkV8(_ model: BuildModel, kindTable: KindTable = .v1) -> Check {
        var problems: [String] = []
        let real = model.targets.filter { !$0.isBucket }
        let identities = Set(real.map { "\($0.name)\u{1F}\($0.project ?? "")\u{1F}\($0.path ?? "")" })
        if real.count > identities.count {
            problems.append("\(real.count) targets but only \(identities.count) distinct target names")
        }
        let stepNamed = real.filter { target in
            target.name.isEmpty || kindTable.lookup(target.name) != nil
        }
        if !stepNamed.isEmpty {
            let names = stepNamed.prefix(3).map { "'\($0.name)'" }.joined(separator: ", ")
            problems.append("\(stepNamed.count) target(s) named after a build-system step or empty: \(names)")
        }
        let dangling = model.tasks.filter { task in
            guard let id = task.targetId else { return false }
            return !model.targets.indices.contains(id)
        }
        if !dangling.isEmpty { problems.append("\(dangling.count) task(s) reference a target that does not exist") }
        return Check(id: "V8", title: "", status: problems.isEmpty ? .pass : .fail(problems.joined(separator: "; ")))
    }

    // MARK: - V10

    /// A failed task (non-zero result code) must not also be marked cancelled. The manifest status cross-check needs
    /// the manifest, which the model does not carry; it is out of scope here.
    static func checkV10(_ model: BuildModel) -> Check {
        let contradictory = model.tasks.filter { task in
            guard let code = task.resultCode, code != 0 else { return false }
            return task.slfOnly?.wasCancelled == true
        }
        guard !contradictory.isEmpty else { return Check(id: "V10", title: "", status: .pass) }
        let ids = contradictory.prefix(5).map { String($0.id) }.joined(separator: ", ")
        return Check(id: "V10", title: "",
                     status: .fail("\(contradictory.count) task(s) are both failed and cancelled (ids \(ids))"))
    }
}

// MARK: - V3, V4, V9, V11 (v0.2)

extension Validator {
    /// Busy ≤ log span; task time ≥ busy; average parallelism ≤ peak lanes.
    static func checkV4(_ analysis: Analysis) -> Check {
        guard !analysis.noTiming, analysis.taskCount > 0 else {
            return Check(id: "V4", title: "", status: .notApplicable, note: "no timed tasks")
        }
        let tolerance = 1e-6 * max(1, analysis.span)
        var problems: [String] = []
        if analysis.busy > analysis.span + tolerance {
            problems.append(String(format: "busy %.6f s exceeds the log span %.6f s", analysis.busy, analysis.span))
        }
        if analysis.taskTime + tolerance < analysis.busy {
            problems.append(String(format: "task time %.6f s is below busy %.6f s", analysis.taskTime, analysis.busy))
        }
        if let average = analysis.averageParallelism, average > Double(analysis.peakParallelism) + 1e-9 {
            problems.append(String(format: "average parallelism %.3f exceeds the peak %d", average,
                                   analysis.peakParallelism))
        }
        return Check(id: "V4", title: "", status: problems.isEmpty ? .pass : .fail(problems.joined(separator: "; ")))
    }

    /// Path span ≤ log span; segments ordered and disjoint (waits too); Σ segments + Σ waits = span; the path ends at
    /// the last task end; DAG edges consistent with timing (§6.2 step 5).
    static func checkV3(path: PathResult?, dag: TaskDAG?, counted: [Timing.Counted],
                        window: (start: Double, end: Double)) -> Check {
        guard let path, !path.segments.isEmpty else {
            return Check(id: "V3", title: "", status: .notApplicable, note: "no critical path (no timed task)")
        }
        let tolerance = 1e-6
        var problems: [String] = []
        if path.span > (window.end - window.start) + tolerance {
            problems.append(String(format: "path span %.6f s exceeds the log span %.6f s", path.span,
                                   window.end - window.start))
        }
        var pieces = path.segments.map { (start: $0.start, end: $0.end, isWait: false) }
            + path.waits.map { (start: $0.start, end: $0.end, isWait: true) }
        pieces.sort { $0.start < $1.start }
        for (index, piece) in pieces.enumerated() {
            if !piece.isWait, piece.end <= piece.start {
                problems.append("a segment has no length")
                break
            }
            if index > 0, piece.start < pieces[index - 1].end - tolerance {
                problems.append("segments or waits overlap")
                break
            }
        }
        let covered = pieces.reduce(0) { $0 + $1.end - $1.start }
        if abs(covered - path.span) > tolerance * Double(max(1, pieces.count)) {
            problems.append(String(format: "segments + waits = %.6f s, path span %.6f s", covered, path.span))
        }
        let lastEnd = counted.filter { $0.interval.duration > 0 }.map(\.interval.end).max() ?? path.end
        if abs(path.end - lastEnd) > tolerance {
            problems.append(String(format: "path ends at %.6f s, the last task at %.6f s", path.end - window.start,
                                   lastEnd - window.start))
        }
        var note = "\(path.segments.count) segment(s), \(path.waits.count) wait(s), basis \(path.basis)"
        if let dag, path.basis != "inferred" {
            if !dag.isConsistent {
                problems.append(String(format: "%.2f%% of DAG edges contradict the timing", dag.violationShare * 100))
            }
            note += "; DAG edges late by > 50 ms: \(dag.violations) of \(dag.checkedEdges) (≤ 1% tolerated)"
        }
        return Check(id: "V3", title: "", status: problems.isEmpty ? .pass : .fail(problems.joined(separator: "; ")),
                     note: note)
    }

    /// Σ `exact` rows of a target ≤ that target's compile task time (Swift and C-family compiles by kind, plus Metal);
    /// no `estimated` row is summed with them. Fails when attribution copies a batch's time onto its files.
    static func checkV9(files: [FileRowValue], counted: [Timing.Counted]) -> Check {
        guard !files.isEmpty else {
            return Check(id: "V9", title: "", status: .notApplicable, note: "no file rows")
        }
        var compileTime: [Int: Double] = [:]
        for item in counted where FileAttribution.isFileCompile(item.task) {
            compileTime[item.task.targetId ?? -1, default: 0] += item.interval.duration
        }
        var exact: [Int: Double] = [:]
        for row in files where row.granularity == "exact" { exact[row.targetId ?? -1, default: 0] += row.seconds }
        var problems: [String] = []
        for (target, seconds) in exact.sorted(by: { $0.key < $1.key }) {
            let limit = compileTime[target] ?? 0
            if seconds > limit + 1e-6 * max(1, limit) {
                problems.append(String(format: "target %d: exact rows %.6f s exceed its compile time %.6f s", target,
                                       seconds, limit))
            }
        }
        func count(_ granularity: String) -> Int { files.filter { $0.granularity == granularity }.count }
        // v0.5 lane A (begin): `estimated` rows (`--deep`, FileAttribution.estimatedRows) are compared with nothing:
        // only exact rows are summed above.
        let note = "\(count("exact")) exact, \(count("batch")) batch, \(count("wmo")) wmo, \(count("estimated")) estimated row(s)"
        // v0.5 lane A (end)
        return Check(id: "V9", title: "", status: problems.isEmpty ? .pass : .fail(problems.joined(separator: "; ")),
                     note: note)
    }

    /// The kind agrees with the counts it was decided from (§6.7).
    static func checkV11(_ kind: BuildKindResult) -> Check {
        guard let value = kind.kind else {
            return Check(id: "V11", title: "", status: .notApplicable, note: kind.reason ?? "build kind not classified")
        }
        let counts = kind.counts
        var problem: String?
        switch value {
        case "clean":
            if counts.reused > 0 {
                problem = "clean build with \(counts.reused) reused task(s)"
            } else if counts.compileExecuted == 0 {
                problem = "clean build without compile, plan or link tasks"
            }
        case "incremental":
            if counts.reused == 0, counts.descriptionCreated {
                problem = "incremental build that created its description and reused nothing"
            } else if counts.compileExecuted == 0 {
                problem = "incremental build without compile, plan or link tasks"
            }
        case "zero-change":
            if counts.compileExecuted > 0 { problem = "zero-change build with \(counts.compileExecuted) compile tasks" }
        case "clean-action":
            if !counts.cleanActionShape { problem = "clean action with build tasks" }
        // v0.5 lane C (begin): `cached` stands on the cache counters, `previews` on the Previews arena (DESIGN §6.7).
        case "cached":
            if !kind.evidence.contains(where: { $0.contains("BuildOperationMetrics") || $0.contains("Cache hit") }) {
                problem = "cached build without cache-hit evidence"
            }
        case "previews":
            if !kind.evidence.contains(where: { $0.contains("Previews") || $0.contains("=preview") }) {
                problem = "previews build without Previews-arena evidence"
            }
        // v0.5 lane C (end)
        default:
            if !kind.evidence.contains(where: { $0.hasPrefix("build-request.json") }) {
                problem = "\(value) without build-request evidence"
            }
        }
        if let problem { return Check(id: "V11", title: "", status: .fail(problem)) }
        return Check(id: "V11", title: "", status: .pass, note: "\(value): " + kind.evidence.joined(separator: ", "))
    }
}

extension ValidationReport {
    /// This report with `checks` put in place of the same-id checks; their failures become degradations, as
    /// `Validator.validate` does for its own.
    func replacing(_ checks: [Check]) -> ValidationReport {
        var result = self
        for check in checks {
            let titled = Check(id: check.id, title: Validator.titles[check.id] ?? check.title, status: check.status,
                               note: check.note)
            if let index = result.checks.firstIndex(where: { $0.id == check.id }) {
                result.checks[index] = titled
            } else {
                result.checks.append(titled)
            }
            if let reason = check.degradingReason {
                result.degradations.append(Degradation(kind: Degradation.Kind(rawValue: "validation"),
                                                       detail: "\(check.id): \(reason)"))
            }
        }
        return result
    }
}
