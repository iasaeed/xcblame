import Foundation

/// CPU and memory aggregates from `TaskMetrics`, reported as "N of M tasks" and never extrapolated.
public struct MetricsAggregate: Codable, Sendable, Equatable {
    /// Tasks that entered timing.
    public var tasksTotal: Int
    /// Tasks with real (non-placeholder) CPU data.
    public var tasksWithCPU: Int
    /// Tasks whose metrics record is a placeholder (timing only).
    public var placeholders: Int
    /// Sum of user + system CPU seconds over `tasksWithCPU`; nil when no task has CPU data.
    public var cpuSeconds: Double?
    /// Tasks with a real `maxRSS` value.
    public var tasksWithRSS: Int
    public var maxRSSBytes: Int64?
}

public struct DiagnosticsSummary: Codable, Sendable, Equatable {
    /// Deduped diagnostics.
    public var unique: Int
    /// Sum of `occurrences`.
    public var occurrences: Int
    public var errors: Int
    public var warnings: Int
    public var analyzerWarnings: Int
    public var notices: Int
    public var unknown: Int
}

/// One row of the top-N task table.
public struct TaskRow: Codable, Sendable, Equatable {
    public var id: Int
    public var ruleName: String
    public var kind: TaskKind
    public var phase: Phase
    public var targetId: Int?
    public var target: String?
    public var seconds: Double
    /// Seconds from the session start to the task start (after clamping).
    public var startOffset: Double
    public var title: String
}

/// Result of the pure analysis over a `BuildModel` (DESIGN §6.1, §6.3, §6.4; no critical path in v0.1).
public struct Analysis: Codable, Sendable {
    public var sessionStart: Double
    public var sessionEnd: Double
    /// Log span: the session window length.
    public var span: Double
    /// Tasks in the model, before any exclusion.
    public var modelTaskCount: Int
    /// Tasks that entered timing (task time, busy, rollups).
    public var taskCount: Int
    /// Excluded as up to date: started more than 0.5 s before the window, or fetched from cache (§6.1 rule 2).
    public var reusedCount: Int
    /// Excluded because start, end or duration is NaN, infinite or negative (V1 reports them).
    public var invalidCount: Int
    /// Tasks the log gave no start or end for: counted in the model, never in timing, never reused.
    public var untimedTaskIds: [Int]
    /// No task (or, without tasks, no session) has timing: span, busy and task time are not measurements.
    public var noTiming: Bool
    /// Tasks whose interval was clamped to the session window.
    public var clampedCount: Int
    /// Counted tasks with zero length: in counts, not in interval math.
    public var zeroLengthCount: Int
    /// Sum of outermost task durations (never the sub-spans).
    public var taskTime: Double
    /// Union of task intervals.
    public var busy: Double
    /// `span - busy`, never negative.
    public var idle: Double
    public var peakParallelism: Int
    /// `taskTime / busy`; nil when nothing was busy.
    public var averageParallelism: Double?
    public var metrics: MetricsAggregate
    public var byKind: Rollup
    public var byPhase: Rollup
    public var byTarget: Rollup
    public var topTasks: [TaskRow]
    public var topN: Int
    public var diagnostics: DiagnosticsSummary
}

public enum Timing {
    /// A task start earlier than the window start by more than this is a reused task (§6.1).
    public static let reusedThreshold = 0.5

    /// Union length and peak concurrency of `intervals`. Zero-length intervals are ignored; intervals that only touch
    /// do not overlap. Sweep line, O(n log n).
    public static func sweep(_ intervals: [Interval]) -> (busy: Double, peak: Int) {
        var events: [(time: Double, delta: Int)] = []
        events.reserveCapacity(intervals.count * 2)
        for i in intervals where i.end > i.start {
            events.append((i.start, 1))
            events.append((i.end, -1))
        }
        // Ends before starts at the same instant, so touching intervals do not count as concurrent.
        events.sort { $0.time != $1.time ? $0.time < $1.time : $0.delta < $1.delta }
        var busy = 0.0
        var active = 0
        var peak = 0
        var previous = 0.0
        for event in events {
            if active > 0 { busy += event.time - previous }
            active += event.delta
            peak = max(peak, active)
            previous = event.time
        }
        return (busy, peak)
    }

    public static func analyze(_ model: BuildModel, topN: Int = 15, kindTable: KindTable = .v1) -> Analysis {
        let cap = max(0, topN)
        let line = timeline(model)
        let (window, counted, reused, clamped) = (line.window, line.counted, line.reused, line.clamped)

        let taskTime = counted.reduce(0) { $0 + $1.interval.duration }
        let (busy, peak) = sweep(counted.map(\.interval))
        let span = window.end - window.start
        let topTasks = Self.topTasks(counted, model: model, window: window, cap: cap)

        return Analysis(
            sessionStart: window.start, sessionEnd: window.end, span: span,
            modelTaskCount: model.tasks.count, taskCount: counted.count, reusedCount: reused,
            invalidCount: line.invalid,
            untimedTaskIds: model.tasks.filter { !$0.hasTiming }.map(\.id), noTiming: hasNoTiming(model),
            clampedCount: clamped,
            zeroLengthCount: counted.filter { $0.interval.duration == 0 }.count,
            taskTime: taskTime, busy: busy, idle: max(0, span - busy), peakParallelism: peak,
            averageParallelism: busy > 0 ? taskTime / busy : nil,
            metrics: Self.metrics(counted),
            byKind: Self.rollupByKind(counted, total: taskTime),
            byPhase: Self.rollupByPhase(counted, total: taskTime),
            byTarget: Self.rollupByTarget(counted, model: model, total: taskTime),
            topTasks: topTasks, topN: cap, diagnostics: Self.diagnosticsSummary(model.diagnostics))
    }

    // MARK: - Internals

    struct Counted {
        var task: BuildTask
        var interval: Interval
    }

    /// §6.1 normalization shared by every engine: valid timed tasks that are not reused, clamped to the window, in
    /// model order. `invalid` counts timed tasks rejected by `isValid`.
    struct Timeline {
        var window: (start: Double, end: Double)
        var counted: [Counted]
        var reused: Int
        var clamped: Int
        var invalid: Int
    }

    static func timeline(_ model: BuildModel) -> Timeline {
        let timed = model.tasks.filter(\.hasTiming)
        let valid = timed.filter(Self.isValid)
        let window = Self.window(of: model, validTasks: valid)
        var counted: [Counted] = []
        var reused = 0
        var clamped = 0
        for task in valid {
            if task.slfOnly?.wasFetchedFromCache == true || task.start < window.start - reusedThreshold {
                reused += 1
                continue
            }
            let start = min(max(task.start, window.start), window.end)
            let end = min(max(task.end, window.start), window.end)
            if start != task.start || end != task.end { clamped += 1 }
            counted.append(Counted(task: task, interval: Interval(start: start, end: end)))
        }
        return Timeline(window: window, counted: counted, reused: reused, clamped: clamped,
                        invalid: timed.count - valid.count)
    }

    /// True when the model has tasks and none has timing, or has no tasks and no session timing.
    public static func hasNoTiming(_ model: BuildModel) -> Bool {
        !model.tasks.contains(where: \.hasTiming) && (!model.tasks.isEmpty || model.sessionTimingMissing == true)
    }

    static func isValid(_ task: BuildTask) -> Bool {
        isPlausible(task.start) && isPlausible(task.end) && task.duration.isFinite && task.duration >= 0
            && task.end >= task.start
    }

    /// Times beyond this magnitude (about 31,700 years in seconds) are not log times: a drifted slot read as a double
    /// can hold 1e300. They count as invalid, so no span, sum or millisecond conversion can overflow.
    static let maxAbsSeconds = 1e12

    static func isPlausible(_ seconds: Double) -> Bool { seconds.isFinite && abs(seconds) <= maxAbsSeconds }

    /// Seconds → whole milliseconds without trapping: NaN maps to 0, anything beyond ±2^53 ms clamps to it (plausible
    /// log times never get there; `isValid` rejects the rest first).
    static func millis(_ seconds: Double) -> Int {
        let ms = (seconds * 1000).rounded()
        guard !ms.isNaN else { return 0 }
        let limit = 9_007_199_254_740_992.0
        return Int(min(limit, max(-limit, ms)))
    }

    /// The model's session window, or one derived from the valid tasks when the stored one is unusable.
    static func window(of model: BuildModel, validTasks: [BuildTask]) -> (start: Double, end: Double) {
        if isPlausible(model.sessionStart), isPlausible(model.sessionEnd), model.sessionEnd >= model.sessionStart {
            return (model.sessionStart, model.sessionEnd)
        }
        let start = validTasks.map(\.start).min() ?? 0
        let end = validTasks.map(\.end).max() ?? start
        return (start, end)
    }

    static func rollupByKind(_ counted: [Counted], total: Double) -> Rollup {
        Rollup.build(
            dimension: "kind",
            entries: counted.map { Rollup.Entry(key: $0.task.kind.rawValue, name: $0.task.kind.rawValue, targetId: nil,
                                                seconds: $0.interval.duration) },
            other: (TaskKind.other.rawValue, TaskKind.other.rawValue), total: total, totalTasks: counted.count)
    }

    static func rollupByPhase(_ counted: [Counted], total: Double) -> Rollup {
        Rollup.build(
            dimension: "phase",
            entries: counted.map { Rollup.Entry(key: $0.task.phase.rawValue, name: $0.task.phase.rawValue,
                                                targetId: nil, seconds: $0.interval.duration) },
            other: (Phase.other.rawValue, Phase.other.rawValue), total: total, totalTasks: counted.count)
    }

    static let unclassifiedKey = "unclassified"

    static func rollupByTarget(_ counted: [Counted], model: BuildModel, total: Double) -> Rollup {
        let entries = counted.map { item -> Rollup.Entry in
            if let id = item.task.targetId, model.targets.indices.contains(id) {
                return Rollup.Entry(key: "t\(id)", name: model.targets[id].name, targetId: id,
                                    seconds: item.interval.duration)
            }
            return Rollup.Entry(key: unclassifiedKey, name: "(unattributed)", targetId: nil,
                                seconds: item.interval.duration)
        }
        return Rollup.build(dimension: "target", entries: entries, other: (unclassifiedKey, "(unattributed)"),
                            total: total, totalTasks: counted.count)
    }

    static func topTasks(_ counted: [Counted], model: BuildModel, window: (start: Double, end: Double),
                         cap: Int) -> [TaskRow] {
        let ranked = counted.sorted {
            if $0.interval.duration != $1.interval.duration { return $0.interval.duration > $1.interval.duration }
            if $0.interval.start != $1.interval.start { return $0.interval.start < $1.interval.start }
            return $0.task.id < $1.task.id
        }
        return ranked.prefix(cap).map { item in
            let target = item.task.targetId.flatMap { model.targets.indices.contains($0) ? model.targets[$0].name : nil }
            return TaskRow(
                id: item.task.id, ruleName: item.task.ruleName, kind: item.task.kind, phase: item.task.phase,
                targetId: item.task.targetId, target: target, seconds: item.interval.duration,
                startOffset: item.interval.start - window.start, title: item.task.title)
        }
    }

    static func metrics(_ counted: [Counted]) -> MetricsAggregate {
        var withCPU = 0
        var placeholders = 0
        var cpu = 0.0
        var withRSS = 0
        var maxRSS: Int64?
        for item in counted {
            guard let m = item.task.metrics else { continue }
            if m.isPlaceholder {
                placeholders += 1
                continue
            }
            if let user = m.userCPU, let system = m.systemCPU, user.isFinite, system.isFinite {
                withCPU += 1
                cpu += user + system
            }
            if let rss = m.maxRSS {
                withRSS += 1
                maxRSS = max(maxRSS ?? rss, rss)
            }
        }
        return MetricsAggregate(
            tasksTotal: counted.count, tasksWithCPU: withCPU, placeholders: placeholders,
            cpuSeconds: withCPU > 0 ? cpu : nil, tasksWithRSS: withRSS, maxRSSBytes: maxRSS)
    }

    static func diagnosticsSummary(_ diagnostics: [Diagnostic]) -> DiagnosticsSummary {
        func count(_ severity: Diagnostic.Severity) -> Int { diagnostics.filter { $0.severity == severity }.count }
        return DiagnosticsSummary(
            unique: diagnostics.count, occurrences: diagnostics.reduce(0) { $0 + $1.occurrences },
            errors: count(.error), warnings: count(.warning), analyzerWarnings: count(.analyzerWarning),
            notices: count(.notice), unknown: count(.unknown))
    }
}
