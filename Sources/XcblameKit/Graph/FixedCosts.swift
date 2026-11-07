import Foundation

// v0.5 lane C (docs/SCHEMA-v0.5.md "Fixed costs"): DESIGN §6.8.
public enum FixedCosts {
    typealias Row = ReportDocument.FixedCost
    typealias CauseTask = ReportDocument.Incremental.CauseTask

    /// `buildsPerDay` when neither history nor `.xcblame/config.json` gives one (a labelled assumption, [PP] §C).
    static let assumedBuildsPerDay = 50
    /// Builds per day from history look this far back.
    static let historyDays = 14
    /// Basis `historyFrequency`: in more than this share of the scheme's non-clean builds, of at least `minBuilds`.
    static let frequencyShare = 0.8
    static let minBuilds = 5
    /// History entries read at most (newest first), so a full history stays cheap to scan.
    static let historyScanLimit = 60
    /// Kinds whose tasks follow edits (compiles, links, module builds): never a fixed cost by frequency alone.
    static let editDrivenKinds: Set<TaskKind> = [.swiftCompile, .clangCompile, .link, .swiftEmitModule, .moduleScan,
                                                 .modulePrecompile, .gate]

    /// The §6.8 class of a task: by rule name first, then by kind; `macroBuilds` for tasks of a macro-plugin or
    /// swift-syntax target. `other` (open vocabulary) when nothing matches.
    static func fixedCostClass(rule: String, kind: TaskKind, macroTarget: Bool) -> String {
        switch rule {
        case "ProcessInfoPlistFile": return "infoPlist"
        case "ExtractAppIntentsMetadata", "AppIntentsSSUTraining": return "appIntents"
        case "RegisterExecutionPolicyException": return "executionPolicy"
        case "ProcessProductPackaging", "ProcessProductPackagingDER": return "codesign"
        case "SwiftDriver", "SwiftDriverJobDiscovery": return macroTarget ? "macroBuilds" : "swiftPlanning"
        default: break
        }
        if macroTarget, editDrivenKinds.contains(kind) || kind == .swiftPlan { return "macroBuilds" }
        switch kind {
        case .script: return "scripts"
        case .codesign: return "codesign"
        case .validate: return "validate"
        case .copy, .resources: return "embedCopy"
        case .planning: return "planning"
        case .sdkStatCache: return "sdkStatCache"
        case .packageResolution: return "packageResolution"
        case .swiftPlan: return "swiftPlanning"
        default: return "other"
        }
    }

    /// Classes from this build alone, per day on the assumed 50 builds (`applyingHistory` re-bases). A zero-change
    /// build: basis `zeroChange` for every executed task. Any other build: basis `static` for planning, the SDK stat
    /// cache and the script phases that declare no outputs (`scriptRunsEveryBuild`): a script with outputs ran
    /// because an input changed. Nil when nothing executed.
    static func compute(model: BuildModel, timeline: Timing.Timeline, kind: BuildKindResult,
                        path: PathResult?, project: ProjectModel? = nil) -> [ReportDocument.FixedCost]? {
        guard !timeline.counted.isEmpty else { return nil }
        let macroTargets = macroTargetIds(model)
        let onPath = path?.taskIds
        let zeroChange = kind.kind == "zero-change"
        var groups: [String: [CauseTask]] = [:]
        for item in timeline.counted {
            let task = item.task
            let macro = task.targetId.map(macroTargets.contains) ?? false
            let cls = fixedCostClass(rule: task.ruleName, kind: task.kind, macroTarget: macro)
            if !zeroChange, !["scripts", "planning", "sdkStatCache"].contains(cls) { continue }
            if !zeroChange, cls == "scripts", !scriptRunsEveryBuild(task, model: model, project: project) { continue }
            let seconds = item.interval.duration
            let target = task.targetId.flatMap { model.targets.indices.contains($0) ? model.targets[$0].name : nil }
            groups[cls, default: []].append(CauseTask(
                key: task.taskKey, label: Explain.label(task, model: model), target: target, kind: task.kind.rawValue,
                seconds: ReportDocument.round6(seconds),
                pathSeconds: onPath.map { $0.contains(task.id) ? ReportDocument.round6(seconds) : 0 }, taskId: task.id))
        }
        let rows = groups.map { cls, tasks in
            row(cls, tasks: tasks, basis: zeroChange ? "zeroChange" : "static", perDay: assumedBuildsPerDay,
                perDayBasis: "assumed")
        }
        return sorted(rows)
    }

    /// A script phase that declares no outputs: so says the project (`ProjectModel`, when the pipeline has it), else
    /// Xcode's own "will be run during every build" warning on the task. Without either, the outputs are unknown and
    /// the phase is not a static fixed cost.
    static func scriptRunsEveryBuild(_ task: BuildTask, model: BuildModel, project: ProjectModel?) -> Bool {
        if let project, let name = scriptPhaseName(task),
           let target = task.targetId.flatMap({ model.targets.indices.contains($0) ? model.targets[$0].name : nil }),
           let owner = project.allTargets.first(where: { $0.name == target || $0.name.hasSuffix("/" + target) }) {
            for case let .shellScript(phase) in owner.phases where phase.name == name {
                return phase.outputPaths.isEmpty && phase.outputFileListPaths.isEmpty
            }
        }
        return task.diagnosticIds.contains { id in
            model.diagnostics.indices.contains(id) && model.diagnostics[id].text.contains("will be run during every build")
        }
    }

    /// Targets of macro plugins (`Owner`'s `-load-plugin-executable` names) and of the swift-syntax package.
    static func macroTargetIds(_ model: BuildModel) -> Set<Int> {
        let plugins = Owner.macroPluginNames(model)
        return Set(model.targets.filter { plugins.contains($0.name) || $0.project == "swift-syntax" }.map(\.id))
    }

    static func row(_ cls: String, tasks: [CauseTask], basis: String, perDay builds: Int, perDayBasis: String,
                    seconds: Double? = nil) -> Row {
        let ordered = tasks.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.label < $1.label }
        let total = seconds ?? ordered.reduce(0) { $0 + $1.seconds }
        return Row(class: cls, seconds: ReportDocument.round6(total), perDay: ReportDocument.round6(total * Double(builds)),
                   perDayAssumedBuilds: builds, perDayBasis: perDayBasis, basis: basis, tasks: ordered,
                   tasksTotal: ordered.count, tasksShownShare: ordered.isEmpty ? nil : 1)
    }

    /// Largest `seconds` first, null seconds last, then class order.
    static func sorted(_ rows: [Row]) -> [Row] {
        rows.sorted { a, b in
            switch (a.seconds, b.seconds) {
            case let (x?, y?) where x != y: return x > y
            case (nil, _?): return false
            case (_?, nil): return true
            default:
                let order = Row.classes
                return (order.firstIndex(of: a.class) ?? order.count, a.class)
                    < (order.firstIndex(of: b.class) ?? order.count, b.class)
            }
        }
    }

    /// `tasks` capped at `topN` per row, `tasksShownShare` = kept seconds / row seconds. Totals unchanged.
    static func capped(_ rows: [Row], topN: Int) -> [Row] {
        rows.map { row in
            guard row.tasks.count > max(0, topN) else { return row }
            var out = row
            out.tasks = Array(row.tasks.prefix(max(0, topN)))
            let all = row.tasks.reduce(0) { $0 + $1.seconds }
            out.tasksShownShare = all > 0 ? ReportDocument.round6(out.tasks.reduce(0) { $0 + $1.seconds } / all) : nil
            return out
        }
    }

    // MARK: - History

    /// What `applyingHistory` reads of one history entry.
    struct HistoryEntry {
        var time: Date?
        var scheme: String?
        var kind: String?
        var rows: [History.TaskIndexRow]
    }

    /// Adds basis `historyFrequency` classes (tasks in > 80 % of this scheme's incremental builds in `historyDir`) and
    /// re-bases `perDay` on `buildsPerDay` from `configURL`, else this scheme's builds per day in history, else 50.
    /// Called by `analyze` and `build` after the pipeline. Never throws.
    public static func applyingHistory(to document: ReportDocument, historyDir: URL, configURL: URL?) -> ReportDocument {
        guard document.fixedCosts != nil else { return document }
        let entries = loadHistory(historyDir)
        return applying(entries: entries, configBuildsPerDay: configURL.flatMap(buildsPerDay(config:)), to: document)
    }

    /// Pure part of `applyingHistory`, for tests.
    static func applying(entries: [HistoryEntry], configBuildsPerDay: Int?, to document: ReportDocument) -> ReportDocument {
        guard var rows = document.fixedCosts else { return document }
        var out = document
        let scheme = document.build.scheme
        let mine = entries.filter { $0.scheme == scheme }

        // historyFrequency: tasks in > 80 % of the scheme's non-clean builds (≥ 5), by rule, target and key.
        let incremental = Array(mine.filter { $0.kind == "incremental" || $0.kind == "zero-change" }.prefix(historyScanLimit))
        if incremental.count >= minBuilds {
            var seen: [String: Int] = [:]
            var sample: [String: History.TaskIndexRow] = [:]
            var durations: [String: [Int]] = [:]
            for entry in incremental {
                var once = Set<String>()
                for row in entry.rows {
                    let id = identity(row)
                    durations[id, default: []].append(row.durationMs)
                    if once.insert(id).inserted { seen[id, default: 0] += 1 }
                    sample[id] = sample[id] ?? row
                }
            }
            let threshold = frequencyShare * Double(incremental.count)
            var byClass: [String: [CauseTask]] = [:]
            for (id, count) in seen where Double(count) > threshold {
                guard let row = sample[id], let kind = TaskKind(rawValue: row.kind), !editDrivenKinds.contains(kind)
                else { continue }
                let cls = fixedCostClass(rule: row.rule, kind: kind, macroTarget: false)
                let ms = median(durations[id] ?? [])
                byClass[cls, default: []].append(CauseTask(key: row.key, label: row.rule, target: row.target,
                                                           kind: row.kind, seconds: ReportDocument.round6(ms / 1000),
                                                           pathSeconds: nil, taskId: nil))
            }
            for (cls, tasks) in byClass {
                if let at = rows.firstIndex(where: { $0.class == cls }) {
                    // A measured row of this build wins; a static row that did not run here takes the history seconds.
                    guard rows[at].seconds == nil else { continue }
                    rows[at] = row(cls, tasks: tasks, basis: "historyFrequency", perDay: assumedBuildsPerDay,
                                   perDayBasis: "assumed")
                } else {
                    rows.append(row(cls, tasks: tasks, basis: "historyFrequency", perDay: assumedBuildsPerDay,
                                    perDayBasis: "assumed"))
                }
            }
            if !byClass.isEmpty {
                out.notes.append("fixedCosts: historyFrequency rows from \(incremental.count) non-clean build(s) of "
                    + "scheme \(scheme ?? "(none)") in history; seconds are the median per build of each task")
            }
        }

        // Builds per day: config, then history, then the assumption.
        let perDay: (builds: Int, basis: String)
        if let configured = configBuildsPerDay {
            perDay = (configured, "config")
        } else if let fromHistory = buildsPerDay(entries: mine, now: document.generatedAt) {
            perDay = (fromHistory, "history")
        } else {
            perDay = (assumedBuildsPerDay, "assumed")
        }
        rows = rows.map { row in
            var row = row
            row.perDayAssumedBuilds = perDay.builds
            row.perDayBasis = perDay.basis
            row.perDay = row.seconds.map { ReportDocument.round6($0 * Double(perDay.builds)) }
            return row
        }
        out.fixedCosts = sorted(rows)
        return out
    }

    /// Task identity across builds: rule, target and task key (else the signature digest).
    static func identity(_ row: History.TaskIndexRow) -> String {
        [row.rule, row.target ?? "", row.key ?? row.sigDigest].joined(separator: "\u{1F}")
    }

    static func median(_ values: [Int]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? Double(sorted[mid]) : Double(sorted[mid - 1] + sorted[mid]) / 2
    }

    /// Builds per active day: the builds in the `historyDays` days up to `now` divided by the calendar days that had
    /// at least one (a scheme built on 3 of 14 days costs its fixed work on those 3 days; the text and html label it
    /// "per active day"); nil with fewer than `minBuilds` builds in that window.
    static func buildsPerDay(entries: [HistoryEntry], now: Date, calendar: Calendar = .current) -> Int? {
        guard let start = calendar.date(byAdding: .day, value: -historyDays, to: now) else { return nil }
        var perDay: [Date: Int] = [:]
        for entry in entries {
            guard let time = entry.time, time > start, time <= now.addingTimeInterval(60) else { continue }
            perDay[calendar.startOfDay(for: time), default: 0] += 1
        }
        let builds = perDay.values.reduce(0, +)
        guard builds >= minBuilds else { return nil }
        return max(1, Int((Double(builds) / Double(perDay.count)).rounded()))
    }

    /// `buildsPerDay` (a positive integer) of `<xcblame-dir>/config.json`; nil when absent or invalid.
    static func buildsPerDay(config url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let number = root["buildsPerDay"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == number.doubleValue.rounded(), number.intValue > 0 else { return nil }
        return number.intValue
    }

    /// The newest `historyScanLimit` entries: time, scheme, kind and task index rows. Unreadable entries and
    /// `build --deep` entries (instrumented, in their own DerivedData) are skipped.
    static func loadHistory(_ directory: URL) -> [HistoryEntry] {
        struct Light: Decodable {
            struct Build: Decodable { var scheme: String?; var kind: String? }
            var build: Build?
            var taskIndexRows: [History.TaskIndexRow]?
            var deep: History.DeepMarker?
        }
        return History.list(directory: directory, details: false).prefix(historyScanLimit).compactMap { item in
            guard let inflated = try? GzipFile.inflate(contentsOf: item.url),
                  let light = try? JSONDecoder().decode(Light.self, from: Data(inflated.bytes)),
                  light.deep == nil else { return nil }
            return HistoryEntry(time: item.time, scheme: light.build?.scheme, kind: light.build?.kind ?? item.kind,
                                rows: light.taskIndexRows ?? [])
        }
    }
}
