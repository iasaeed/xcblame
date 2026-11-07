import Foundation

extension ReportDocument {
    /// Decode warnings listed in the report; the rest are only counted.
    public static let decodeWarningCap = 50

    /// Builds the report value from the model, its analysis and the validation. Numbers a failed check withholds are
    /// `null` with a note (V1 withholds every timing number; V6 the rollups; V3 the critical path; V9 the file rows;
    /// V11 the kind). The v0.2 engines (`Explain`) run here because they need the build description; V3, V9 and V11
    /// replace the placeholders `Validator.validate` left for them.
    public static func make(model: BuildModel, analysis: Analysis, validation input: ValidationReport,
                            generatedAt: Date, inputPath: String? = nil, xcode: InferredXcode? = nil,
                            environment: EnvSnapshot? = nil, buildDescription: BuildDescription? = nil,
                            physicalCores: Int? = nil, processWall: Double? = nil, deep: DeepRun? = nil) -> ReportDocument {
        make(model: model, analysis: analysis, validation: input, generatedAt: generatedAt, inputPath: inputPath,
             xcode: xcode, environment: environment, buildDescription: buildDescription, processWall: processWall,
             deep: deep,
             explain: Explain.run(model: model, analysis: analysis, description: buildDescription,
                                  physicalCores: physicalCores, deep: deep))
    }

    /// As above with the engines already run (`ReportPipeline` runs them once for both of its passes). `explain`
    /// must come from the same model, analysis, description and core count.
    static func make(model: BuildModel, analysis: Analysis, validation input: ValidationReport,
                     generatedAt: Date, inputPath: String? = nil, xcode: InferredXcode? = nil,
                     environment: EnvSnapshot? = nil, buildDescription: BuildDescription? = nil,
                     processWall: Double? = nil, deep: DeepRun? = nil, explain: Explain) -> ReportDocument {
        let validation = input.replacing(explain.checks)
        let v1Failed = validation.status("V1").isFail
        let v6Failed = validation.status("V6").isFail
        let v1Reason = validation.check("V1")?.detail ?? ""
        let v6Reason = validation.check("V6")?.detail ?? ""

        // `CauseEngine.attach` (analyze of a build log, build, why) replaces this with the member or its own reason.
        var notes = [CauseEngine.pendingNote]
        // v0.5 lane C (begin): a null fixed-cost or module-graph member says why (the cache reason is a build note).
        if explain.fixedCosts == nil || v1Failed || analysis.noTiming {
            notes.append(v1Failed || analysis.noTiming ? "fixedCosts: null because timing numbers are withheld"
                : "fixedCosts: null because no task executed")
        }
        if explain.moduleGraph == nil { notes.append("moduleGraph: null because the log has no target") }
        // v0.5 lane C (end)
        notes.append(environment == nil
            ? "environment: not captured (pass --env)"
            : "environment: captured when xcblame ran, on this machine; it is not what built the log")
        var buildNotes: [String] = []
        if let reason = explain.kind.reason { buildNotes.append("kind: " + reason) }
        if v1Failed { buildNotes.append("timing numbers withheld because V1 failed: \(v1Reason)") }
        // No timing at all: the zeros would read like measurements (§8.1 wants null with a reason).
        let withheld = v1Failed || analysis.noTiming
        let timingReason = v1Failed ? "withheld because V1 failed: \(v1Reason)"
            : "unavailable: no timing in the log (no task has a start and end)"
        if analysis.noTiming { buildNotes.append("timing numbers unavailable: no timing in the log (no task has a start and end)") }
        if !v1Failed, !analysis.noTiming, analysis.averageParallelism == nil {
            buildNotes.append("parallelism.average: no busy time")
        }
        if analysis.reusedCount > 0 {
            buildNotes.append("\(analysis.reusedCount) reused task(s) excluded from timing (up to date)")
        }
        if !analysis.untimedTaskIds.isEmpty {
            buildNotes.append("\(analysis.untimedTaskIds.count) task(s) without timing (start or end missing in the "
                + "log): counted, excluded from timing")
        }
        let untimed = analysis.untimedTaskIds.prefix(analysis.topN).compactMap { id -> UntimedTask? in
            guard model.tasks.indices.contains(id) else { return nil }
            let task = model.tasks[id]
            let target = task.targetId.flatMap { model.targets.indices.contains($0) ? model.targets[$0].name : nil }
            return UntimedTask(id: id, rule: task.ruleName, kind: task.kind.rawValue, target: target, title: task.title)
        }

        let criticalPath = withheld ? nil : criticalPathMember(explain, model: model)
        if withheld {
            notes.append("criticalPath, timing.utilization, files " + timingReason)
        } else if let why = explain.withheld["criticalPath"] {
            notes.append("criticalPath withheld because " + why)
        } else if criticalPath == nil {
            notes.append("criticalPath: no timed task")
        }

        let share: (Double) -> Double? = { seconds in analysis.taskTime > 0 ? round6(seconds / analysis.taskTime) : nil }
        let rollupAvailable = !v1Failed && !v6Failed
        let kinds: [Row]? = rollupAvailable ? rows(analysis.byKind, share: share) : nil
        let phases: [Row]? = rollupAvailable ? rows(analysis.byPhase, share: share) : nil
        let allTargets = targetRows(analysis.byTarget, model: model, share: share, explain: explain,
                                    criticalPath: criticalPath, timingAvailable: !withheld)
        let shownTargets = Array(allTargets.prefix(analysis.topN))
        let targetsAvailable = rollupAvailable
        if !rollupAvailable {
            let why = v1Failed ? "V1 failed: \(v1Reason)" : "V6 failed: \(v6Reason)"
            notes.append("kinds, phases, targets withheld because \(why)")
        }
        let allTop = analysis.topTasks.map { row in
            TopTask(id: row.id, rule: row.ruleName, kind: row.kind.rawValue, target: row.target,
                    seconds: round6(row.seconds), startOffset: round6(row.startOffset), title: row.title)
        }
        let topTotal = analysis.taskCount
        let topShown = analysis.topTasks.reduce(0) { $0 + $1.seconds }

        var metricsNotes: [String] = []
        if analysis.metrics.tasksWithCPU == 0 { metricsNotes.append("cpuSeconds: no task has CPU metrics") }
        if analysis.metrics.tasksWithRSS == 0 { metricsNotes.append("maxRSSBytes: no task has RSS metrics") }
        metricsNotes.append("aggregates cover only tasks with metrics; never extrapolated")

        var validationNotes: [String] = []
        if validation.checks.contains(where: { $0.status == .notApplicable }) {
            validationNotes.append("checks marked not applicable had nothing to check in this report (each one says why)")
        }
        let allDegradations = model.degradations.map { DegradationEntry(kind: $0.kind.rawValue, detail: $0.detail) }
            + validation.degradations.map { DegradationEntry(kind: $0.kind.rawValue, detail: $0.detail) }

        let warnings = model.decodeWarnings.prefix(decodeWarningCap).map {
            DecodeWarningEntry(kind: $0.kind.rawValue, detail: $0.detail, offset: $0.offset)
        }
        if model.decodeWarnings.count > decodeWarningCap {
            notes.append("decodeWarnings: showing \(decodeWarningCap) of \(model.decodeWarnings.count)")
        }

        let diagnostics = diagnosticMembers(model: model, topN: analysis.topN)
        let files = withheld ? nil : fileMembers(explain, model: model, topN: analysis.topN, deep: deep?.enabled == true,
                                                 notes: &notes)
        let hotspots = hotspotMembers(explain, model: model, topN: analysis.topN, notes: &notes)

        var document = ReportDocument(
            schemaVersion: schemaVersion,
            tool: Tool(name: "xcblame", version: XcblameVersion.current, kindTable: model.kindTableVersion),
            generatedAt: generatedAt,
            input: Input(reader: model.readerKind.rawValue, layout: model.layout.rawValue,
                         logFormatVersion: model.formatVersion, path: inputPath,
                         decodeWarnings: model.decodeWarnings.count, excludedActions: model.excludedActions ?? []),
            xcode: Xcode(value: xcode?.value, source: xcode?.source, evidence: xcode?.evidence ?? [],
                         notes: xcode == nil ? ["value: no Xcode version evidence in the log"] : []),
            environment: environment,
            build: Build(
                kind: explain.kind.kind, kindEvidence: explain.kind.evidence,
                span: withheld ? nil : round6(analysis.span),
                taskTime: withheld ? nil : round6(analysis.taskTime), busy: withheld ? nil : round6(analysis.busy),
                idle: withheld ? nil : round6(analysis.idle),
                parallelism: Parallelism(average: withheld ? nil : analysis.averageParallelism.map(round6),
                                         peak: withheld ? nil : analysis.peakParallelism),
                tasks: analysis.taskCount, tasksInModel: analysis.modelTaskCount, tasksReused: analysis.reusedCount,
                tasksInvalid: analysis.invalidCount, tasksClamped: analysis.clampedCount,
                tasksWithoutTiming: untimed, tasksWithoutTimingTotal: analysis.untimedTaskIds.count, notes: buildNotes),
            metrics: Metrics(
                tasks: analysis.metrics.tasksTotal, tasksWithCPU: analysis.metrics.tasksWithCPU,
                placeholdersIgnored: analysis.metrics.placeholders,
                cpuSeconds: v1Failed ? nil : analysis.metrics.cpuSeconds.map(round6),
                tasksWithRSS: analysis.metrics.tasksWithRSS, maxRSSBytes: analysis.metrics.maxRSSBytes,
                notes: metricsNotes),
            phases: phases, kinds: kinds,
            targets: targetsAvailable ? shownTargets : nil,
            targetsTotal: allTargets.count,
            targetsShownShare: targetsAvailable ? shownShare(shownTargets.reduce(0) { $0 + $1.taskTime },
                                                             of: analysis.taskTime) : nil,
            topTasks: v1Failed ? nil : allTop, topTasksTotal: topTotal,
            topTasksShownShare: v1Failed ? nil : shownShare(topShown, of: analysis.taskTime),
            diagnosticsSummary: analysis.diagnostics,
            validation: Validation(
                checks: validation.checks.map {
                    Check(id: $0.id, title: $0.title, status: $0.status.label, detail: $0.detail)
                },
                degraded: !allDegradations.isEmpty, notes: validationNotes),
            degraded: !allDegradations.isEmpty, degradations: allDegradations, decodeWarnings: Array(warnings),
            decodeWarningsTotal: model.decodeWarnings.count, notes: notes, topN: analysis.topN,
            graph: graph(model: model, description: buildDescription, explain: explain),
            criticalPath: criticalPath,
            timing: timingMember(explain, analysis: analysis, withheld: withheld, reason: timingReason,
                                 processWall: processWall),
            files: files?.rows, filesTotal: files?.total ?? 0, filesShownShare: files?.shownShare,
            hotspots: hotspots?.rows, hotspotsTotal: hotspots?.total ?? 0, hotspotsShownShare: hotspots?.shownShare,
            findings: [], findingsTotal: 0, ruleDocs: [:],
            truncation: Truncation(steps: []), redacted: false,
            diagnostics: diagnostics.rows, diagnosticsTotal: diagnostics.total,
            diagnosticsShownShare: diagnostics.shownShare)
        // v0.5 lane C (begin)
        if !withheld, var rows = explain.fixedCosts {
            // Out-of-log time (xcodebuild start-up, package resolution before the log) of a zero-change build.
            if explain.kind.kind == "zero-change", let outside = document.timing.outsideLogSeconds, outside > 0 {
                rows.append(FixedCosts.row("outsideLog", tasks: [], basis: "zeroChange",
                                           perDay: FixedCosts.assumedBuildsPerDay, perDayBasis: "assumed",
                                           seconds: outside))
            }
            document.fixedCosts = FixedCosts.capped(FixedCosts.sorted(rows), topN: analysis.topN)
        }
        if var graph = explain.moduleGraph {
            if var variants = graph.variants, variants.perModule.count > max(0, analysis.topN) {
                let all = variants.perModule.reduce(0) { $0 + ($1.redundantSeconds ?? 0) }
                variants.perModule = Array(variants.perModule.prefix(max(0, analysis.topN)))
                let kept = variants.perModule.reduce(0) { $0 + ($1.redundantSeconds ?? 0) }
                variants.perModuleShownShare = all > 0 ? round6(kept / all)
                    : round6(Double(variants.perModule.count) / Double(max(1, variants.perModuleTotal)))
                graph.variants = variants
            }
            document.moduleGraph = graph
        }
        document.build.cache = explain.cache
        if explain.cache == nil {
            document.build.notes.append("cache: null because the log has no build-level cache counter (compilation "
                + "caching off)")
        } else if let note = CacheMetrics.replayNote(model) {
            document.build.notes.append(note)
        }
        // v0.5 lane C (end)
        // v0.5 lane A (begin)
        document.deep = deep.map { $0.member(sources: explain.deepSources) }
        document.deep?.notes += explain.deepNotes
        // v0.5 lane A (end)
        return document
    }

    // MARK: - Diagnostics (v0.4)

    /// Rows kept of `diagnostics` at most, whatever `--top` says (html runs with `--top all`).
    public static let diagnosticRowCap = 100

    /// Deduped errors then warnings, each group by occurrences descending, then file, line, message.
    static func diagnosticMembers(model: BuildModel, topN: Int) -> (rows: [DiagnosticEntry], total: Int, shownShare: Double?) {
        let relevant = model.diagnostics.filter { $0.severity == .error || $0.severity == .warning }
        let ordered = relevant.sorted { lhs, rhs in
            if (lhs.severity == .error) != (rhs.severity == .error) { return lhs.severity == .error }
            if lhs.occurrences != rhs.occurrences { return lhs.occurrences > rhs.occurrences }
            if (lhs.file ?? "") != (rhs.file ?? "") { return (lhs.file ?? "") < (rhs.file ?? "") }
            if (lhs.line ?? 0) != (rhs.line ?? 0) { return (lhs.line ?? 0) < (rhs.line ?? 0) }
            return lhs.text < rhs.text
        }
        let shown = ordered.prefix(min(max(topN, 0), diagnosticRowCap))
        let rows = shown.map { diagnostic -> DiagnosticEntry in
            let first = diagnostic.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
                .map(String.init) ?? ""
            let message = first.count > 300 ? String(first.prefix(299)) + "…" : first
            return DiagnosticEntry(severity: diagnostic.severity == .error ? "error" : "warning", file: diagnostic.file,
                                   line: diagnostic.line, column: diagnostic.column, message: message,
                                   occurrences: diagnostic.occurrences)
        }
        let all = relevant.reduce(0) { $0 + $1.occurrences }
        let share = all > 0 ? round6(Double(shown.reduce(0) { $0 + $1.occurrences }) / Double(all)) : nil
        return (rows, relevant.count, share)
    }

    // MARK: - Graph

    static func graph(model: BuildModel, description: BuildDescription?, explain: Explain) -> Graph {
        let keyed = model.tasks.filter { $0.taskKey != nil }.count
        guard let description else {
            return Graph(basis: "none", signature: nil, path: nil, commands: nil, keyedTasks: keyed,
                         unkeyedTasks: model.tasks.count - keyed,
                         notes: ["basis: no build description matched this log (no snapshot, no live description "
                             + "with its signature or ≥ 95% key coverage); critical path inferred from timing"])
        }
        if explain.descriptionDropped {
            return Graph(basis: "none", signature: nil, path: nil, commands: nil, keyedTasks: keyed,
                         unkeyedTasks: model.tasks.count - keyed, notes: description.notes + explain.graphNotes)
        }
        var notes = description.notes
        var signature = description.signature
        if signature == nil, let logSignature = BuildDescriptionLocator.signature(of: model) {
            signature = logSignature
            notes.append("signature: from the log (the description folder names none)")
        }
        if description.basis == "snapshot" {
            notes.append("basis: snapshot covers .xcblame/snapshots copies and --build-description folders")
        }
        return Graph(basis: description.basis, signature: signature, path: description.directory.path,
                     commands: description.commands.count, keyedTasks: keyed, unkeyedTasks: model.tasks.count - keyed,
                     notes: notes + explain.graphNotes)
    }

    // MARK: - Critical path

    static func criticalPathMember(_ explain: Explain, model: BuildModel) -> CriticalPath? {
        guard let path = explain.path, !path.segments.isEmpty else { return nil }
        let origin = explain.windowStart
        let span = round6(path.span)
        let segments = path.segments.map { segment -> PathSegment in
            let seconds = round6(segment.end - segment.start)
            let target = segment.targetId.flatMap { model.targets.indices.contains($0) ? model.targets[$0] : nil }
            let longest = segment.taskIds.max {
                model.tasks[$0].duration != model.tasks[$1].duration
                    ? model.tasks[$0].duration < model.tasks[$1].duration : $0 > $1
            } ?? segment.taskIds[0]
            var label = Explain.label(model.tasks[longest], model: model)
            if segment.taskIds.count > 1 { label += " +\(segment.taskIds.count - 1)" }
            return PathSegment(start: round6(segment.start - origin), end: round6(segment.end - origin),
                               seconds: seconds, share: span > 0 ? round6(seconds / span) : nil, basis: segment.basis,
                               target: target?.name, targetId: target?.id, label: label, taskIds: segment.taskIds)
        }
        let total = segments.reduce(0) { $0 + $1.seconds }
        var notes = path.notes
        if path.whatIf == nil { notes.append("whatIf: computed only from the task DAG (not under inference)") }
        return CriticalPath(
            span: span, basis: path.basis, segments: segments, segmentsTotal: segments.count,
            segmentsShownShare: total > 0 ? 1.0 : nil,
            waits: path.waits.map {
                PathWait(start: round6($0.start - origin), end: round6($0.end - origin), seconds: round6($0.end - $0.start))
            },
            whatIf: path.whatIf?.map {
                WhatIf(target: $0.name, targetId: $0.targetId, savingIfZero: round6($0.savingIfZero),
                       savingIfHalf: round6($0.savingIfHalf))
            },
            notes: notes)
    }

    // MARK: - Timing

    static func timingMember(_ explain: Explain, analysis: Analysis, withheld: Bool, reason: String,
                             processWall: Double?) -> TimingSection {
        var notes: [String] = []
        if processWall == nil { notes.append("processWall: only measured by `xcblame build`") }
        guard !withheld, let utilization = explain.utilization else {
            notes.insert("utilization, serialStretches, idleGaps \(reason)", at: 0)
            return TimingSection(
                utilization: nil, serialStretches: nil, serialStretchesTotal: 0, serialStretchesShownShare: nil,
                serialThresholdLanes: nil, serialSeconds: nil, idleGaps: nil, idleGapsTotal: 0,
                idleGapsShownShare: nil, peakLanes: withheld ? nil : analysis.peakParallelism,
                processWall: processWall.map(round6), outsideLogSeconds: nil, notes: notes)
        }
        notes = utilization.notes + notes
        let topN = analysis.topN
        // The `topN` longest of each, shown in time order.
        let stretches = utilization.threshold == nil ? nil : utilization.stretches.prefix(topN)
            .sorted { $0.start < $1.start }
            .map { SerialStretch(start: round6($0.start), end: round6($0.end), lanes: $0.lanes) }
        let shownSerial = utilization.stretches.prefix(topN).reduce(0) { $0 + $1.end - $1.start }
        let gaps = utilization.gaps.prefix(topN).sorted { $0.start < $1.start }
            .map { Gap(start: round6($0.start), end: round6($0.end)) }
        let allGapSeconds = utilization.gaps.reduce(0) { $0 + $1.end - $1.start }
        let shownGapSeconds = utilization.gaps.prefix(topN).reduce(0) { $0 + $1.end - $1.start }
        return TimingSection(
            utilization: Utilization(bucketSeconds: round6(utilization.bucketSeconds),
                                     lanes: utilization.lanes.map(round6)),
            serialStretches: stretches,
            serialStretchesTotal: utilization.threshold == nil ? 0 : utilization.stretches.count,
            serialStretchesShownShare: stretches == nil ? nil : shownShare(shownSerial, of: utilization.serialSeconds),
            serialThresholdLanes: utilization.threshold,
            serialSeconds: utilization.threshold == nil ? nil : round6(utilization.serialSeconds),
            idleGaps: gaps, idleGapsTotal: utilization.gaps.count,
            idleGapsShownShare: shownShare(shownGapSeconds, of: allGapSeconds),
            peakLanes: analysis.peakParallelism, processWall: processWall.map(round6),
            outsideLogSeconds: processWall.map { round6(max(0, $0 - analysis.span)) }, notes: notes)
    }

    // MARK: - Files and hotspots

    static func fileMembers(_ explain: Explain, model: BuildModel, topN: Int, deep: Bool = false,
                            notes: inout [String]) -> (rows: [FileRow], total: Int, shownShare: Double?)? {
        if let why = explain.withheld["files"] {
            notes.append("files withheld because " + why)
            return nil
        }
        let all = explain.files
        let shown = all.prefix(topN).map { row -> FileRow in
            let target = row.targetId.flatMap { model.targets.indices.contains($0) ? model.targets[$0] : nil }
            return FileRow(path: row.path, target: target?.name, targetId: target?.id, seconds: round6(row.seconds),
                           granularity: row.granularity, batchSize: row.members?.count, members: row.members,
                           onPath: row.onPath, typeCheckMs: row.typeCheckMs.map(round6), taskId: row.taskId)
        }
        var totals: [String] = []
        for granularity in ["exact", "batch", "estimated", "wmo"] {
            let rows = all.filter { $0.granularity == granularity }
            guard !rows.isEmpty else { continue }
            let seconds = rows.reduce(0) { $0 + $1.seconds }
            let members = rows.reduce(0) { $0 + ($1.members?.count ?? 1) }
            switch granularity {
            case "batch": totals.append(String(format: "batch %d rows (%d files) %.1f s", rows.count, members, seconds))
            case "estimated":
                // FileAttribution.estimatedRows: batch seconds split by type-check ms, never summed with exact (V9).
                let batches = Set(rows.compactMap(\.taskId)).count
                totals.append(String(format: "estimated %d rows (%d batches split by type-check ms, not added to exact) "
                    + "%.1f s", rows.count, batches, seconds))
            default: totals.append(String(format: "%@ %d rows %.1f s", granularity, rows.count, seconds))
            }
        }
        let batches = all.filter { $0.granularity == "batch" }
        if deep {
            // Under --deep the type-check ms was recorded: name the batches it did not cover.
            let estimated = Set(all.filter { $0.granularity == "estimated" }.compactMap(\.taskId))
            let bare = batches.filter { !($0.taskId.map(estimated.contains) ?? false) }
            if !bare.isEmpty {
                func isForeign(_ row: FileRowValue) -> Bool {
                    !(row.members ?? [row.path]).contains(where: Hotspots.isUserCode)
                }
                let foreign = bare.filter(isForeign)
                func targets(_ rows: [FileRowValue]) -> String {
                    let names = Set(rows.compactMap { row in
                        row.targetId.flatMap { model.targets.indices.contains($0) ? model.targets[$0].name : nil }
                    }).sorted()
                    return names.isEmpty ? "" : " (" + names.prefix(5).joined(separator: ", ")
                        + (names.count > 5 ? ", \(names.count - 5) more" : "") + ")"
                }
                var parts: [String] = []
                if !foreign.isEmpty {
                    parts.append("\(foreign.count) of targets whose files are not user code" + targets(foreign))
                }
                let silent = bare.filter { !isForeign($0) }
                if !silent.isEmpty {
                    parts.append("\(silent.count) with no debug-time row for any member" + targets(silent))
                }
                totals.append("\(bare.count) of \(batches.count) batch rows not estimated (no per-file type-check ms): "
                    + parts.joined(separator: "; "))
            }
        } else if !batches.isEmpty, !all.contains(where: { $0.granularity == "estimated" }) {
            totals.append("no estimated rows (no per-file type-check ms for the batches; build --deep records it)")
        }
        notes.append("files: " + (totals.isEmpty ? "no compile task names a source file" : totals.joined(separator: " · ")))
        // `estimated` rows split batch seconds the batch rows already hold: never in the shown share (V9).
        let measured = all.filter { $0.granularity != "estimated" }
        let allSeconds = measured.reduce(0) { $0 + $1.seconds }
        let shownSeconds = all.prefix(topN).filter { $0.granularity != "estimated" }.reduce(0) { $0 + $1.seconds }
        return (Array(shown), all.count, shownShare(shownSeconds, of: allSeconds))
    }

    static func hotspotMembers(_ explain: Explain, model: BuildModel, topN: Int,
                               notes: inout [String]) -> (rows: [Hotspot], total: Int, shownShare: Double?)? {
        let result = explain.hotspots
        guard result.hasSource else {
            notes.append("hotspots: no type-check timing in this log (no -debug-time-function-bodies output, no "
                + "warn-long diagnostics)")
            return nil
        }
        notes.append("hotspots: \(result.rawLines) debug-time line(s) and \(result.warnLong) warn-long diagnostic(s) "
            + "read; \(result.rows.count) user-code row(s) after dedupe by file:line:col")
        let shown = result.rows.prefix(topN).map { row -> Hotspot in
            let target = row.targetId.flatMap { model.targets.indices.contains($0) ? model.targets[$0].name : nil }
            return Hotspot(file: row.file, line: row.line, col: row.col, declaration: row.declaration, kind: row.kind,
                           ms: round6(row.ms), source: row.source, onPathWeight: row.onPathWeight,
                           occurrences: row.occurrences, target: target, taskId: row.taskId)
        }
        let allMs = result.rows.reduce(0) { $0 + $1.ms }
        let shownMs = result.rows.prefix(topN).reduce(0) { $0 + $1.ms }
        return (Array(shown), result.rows.count, shownShare(shownMs, of: allMs))
    }

    // MARK: - Shared

    /// Rounded to 6 decimals; a value too large to scale (over about 1.8e302) is returned as is rather than as inf.
    static func round6(_ value: Double) -> Double {
        let scaled = value * 1_000_000
        return scaled.isFinite ? scaled.rounded() / 1_000_000 : value
    }

    /// Share of `total` covered by `part`; nil (not 0) when there is no total.
    static func shownShare(_ part: Double, of total: Double) -> Double? {
        total > 0 ? round6(min(1, part / total)) : nil
    }

    static func rows(_ rollup: Rollup, share: (Double) -> Double?) -> [Row] {
        rollup.rows.map { Row(key: $0.key, tasks: $0.taskCount, taskTime: round6($0.seconds),
                              share: share($0.seconds), isOther: $0.isOther) }
    }

    /// v1 target rows plus owner, on-path seconds, what-if, busy and the kind mix (§6.4). The `other` row gathers
    /// the tasks without a model target, as in the rollup.
    static func targetRows(_ rollup: Rollup, model: BuildModel, share: (Double) -> Double?, explain: Explain,
                           criticalPath: CriticalPath?, timingAvailable: Bool) -> [TargetRow] {
        func key(_ targetId: Int?) -> Int? { targetId.flatMap { model.targets.indices.contains($0) ? $0 : nil } }
        var intervals: [Int?: [Interval]] = [:]
        var kindEntries: [Int?: [Rollup.Entry]] = [:]
        for item in explain.timeline.counted {
            let target = key(item.task.targetId)
            intervals[target, default: []].append(item.interval)
            kindEntries[target, default: []].append(Rollup.Entry(key: item.task.kind.rawValue,
                                                                 name: item.task.kind.rawValue, targetId: nil,
                                                                 seconds: item.interval.duration))
        }
        var onPath: [Int?: Double] = [:]
        for segment in criticalPath?.segments ?? [] { onPath[key(segment.targetId), default: 0] += segment.seconds }
        var whatIf: [Int: Double] = [:]
        for entry in criticalPath?.whatIf ?? [] { if let id = entry.targetId { whatIf[id] = entry.savingIfZero } }

        return rollup.rows.map { row in
            let target = row.isOther ? nil : key(row.targetId)
            let model = target.map { model.targets[$0] }
            let entries = kindEntries[target] ?? []
            let total = entries.reduce(0) { $0 + $1.seconds }
            let kinds = Rollup.build(dimension: "kind", entries: entries,
                                     other: (TaskKind.other.rawValue, TaskKind.other.rawValue), total: total,
                                     totalTasks: entries.count)
                .rows.map { Row(key: $0.key, tasks: $0.taskCount, taskTime: round6($0.seconds),
                                share: total > 0 ? round6($0.seconds / total) : nil, isOther: $0.isOther) }
            return TargetRow(
                id: row.targetId, name: row.name, project: model?.project, isPackage: model?.isPackage,
                isBucket: model?.isBucket, tasks: row.taskCount, taskTime: round6(row.seconds),
                share: share(row.seconds), isOther: row.isOther,
                owner: target.flatMap { explain.owners[$0] },
                onPathSeconds: criticalPath == nil ? nil : round6(onPath[target] ?? 0),
                whatIfSeconds: target.flatMap { whatIf[$0] },
                busy: timingAvailable ? round6(Timing.sweep(intervals[target] ?? []).busy) : nil,
                kinds: kinds)
        }
    }
}
