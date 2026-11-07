import Foundation

public enum CheckStatus: Sendable, Equatable {
    case pass
    case warn(String)
    case fail(String)
    case notApplicable

    public var label: String {
        switch self {
        case .pass: return "pass"
        case .warn: return "warn"
        case .fail: return "fail"
        case .notApplicable: return "notApplicable"
        }
    }

    public var isFail: Bool {
        if case .fail = self { return true }
        return false
    }

    public var reason: String? {
        switch self {
        case let .warn(reason), let .fail(reason): return reason
        case .pass, .notApplicable: return nil
        }
    }
}

public struct Check: Sendable, Equatable {
    /// `V1` ... `V15`.
    public var id: String
    public var title: String
    public var status: CheckStatus
    /// Extra context for `pass` and `notApplicable` (warn/fail carry their reason in the status).
    public var note: String?

    public init(id: String, title: String, status: CheckStatus, note: String? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.note = note
    }

    public var detail: String? { status.reason ?? note }

    /// Why this check degrades the report: a failure, or drift on timing fields (V14). A plain warn is shown with
    /// the checks but does not make the report `degraded`.
    var degradingReason: String? {
        status.isFail || (id == "V14" && status.reason != nil) ? status.reason : nil
    }
}

/// Result of the self-validation pass (DESIGN §6.11). A fail withholds the affected numbers in the report
/// ("unavailable because ...") and marks it degraded; a warn does not, except V14 (timing drift).
public struct ValidationReport: Sendable {
    public var checks: [Check]
    /// Degradations raised by the checks themselves; the model's own are merged in by the report document.
    public var degradations: [Degradation]

    public init(checks: [Check], degradations: [Degradation]) {
        self.checks = checks
        self.degradations = degradations
    }

    public func check(_ id: String) -> Check? { checks.first { $0.id == id } }

    public func status(_ id: String) -> CheckStatus { check(id)?.status ?? .notApplicable }

    public var passCount: Int { checks.filter { $0.status == .pass }.count }
    public var warnings: [Check] { checks.filter { if case .warn = $0.status { true } else { false } } }
    public var failures: [Check] { checks.filter { if case .fail = $0.status { true } else { false } } }
    public var notApplicableCount: Int { checks.filter { $0.status == .notApplicable }.count }
    public var hasFailure: Bool { !failures.isEmpty }
}

public enum Validator {
    /// Default JSON budget (DESIGN §3.1: 2 MB).
    public static let defaultBudgetBytes = 2_000_000
    /// Unclassified task time above this share of task time warns (V7).
    public static let unclassifiedLimit = 0.05
    /// V5 tolerance: `max(0.25 s, 2 %)`.
    public static let summaryToleranceSeconds = 0.25
    public static let summaryToleranceShare = 0.02

    static let titles: [String: String] = [
        "V1": "finite, non-negative durations", "V2": "intervals inside the session window",
        "V3": "critical path consistent", "V4": "busy, task time and parallelism ordered",
        "V5": "per-rule sums match Xcode's timing summary", "V6": "rollups are partitions",
        "V7": "unclassified task time within limit", "V8": "targets are real targets",
        "V9": "file rows within module compile time", "V10": "failed tasks are not cancelled",
        "V11": "build kind consistent with counts", "V12": "finding savings within measured cost",
        "V13": "report size within budget", "V14": "no schema drift on timing fields",
        "V15": "incremental causes partition task time",
    ]

    /// V3, V9 and V11 need the critical path, the file rows and the build kind, which `ReportDocument.make` computes
    /// with the build description; it replaces these placeholders.
    static let inDocument = "evaluated with the report document (needs the build description)"

    /// Runs every check. `serializedBytes` is the encoded report size (V13); nil leaves V13 `notApplicable`.
    public static func validate(_ model: BuildModel, analysis: Analysis, serializedBytes: Int? = nil,
                                budgetBytes: Int = defaultBudgetBytes) -> ValidationReport {
        let drift = timingDrift(in: model)
        var checks = [
            checkV1(model),
            applyDrift(checkV2(analysis), drift: drift),
            notApplicable("V3", why: inDocument),
            applyDrift(checkV4(analysis), drift: drift),
            applyDrift(checkV5(model, analysis: analysis), drift: drift),
            checkV6(analysis),
            checkV7(analysis),
            checkV8(model),
            notApplicable("V9", why: inDocument),
            checkV10(model),
            notApplicable("V11", why: inDocument),
            notApplicable("V12", why: "no rule ran for this report"),
            checkV13(serializedBytes: serializedBytes, budgetBytes: budgetBytes),
            checkV14(drift: drift),
            notApplicable("V15", why: "evaluated only for incremental builds"),
        ]
        checks = checks.map { Check(id: $0.id, title: titles[$0.id] ?? $0.title, status: $0.status, note: $0.note) }

        var degradations: [Degradation] = []
        // Out-of-range times only warn V1, but the timing misses what they dropped: degraded, like NaN or inf.
        if let outOfRange = outOfRangeTimes(model) {
            degradations.append(Degradation(kind: .invalidTiming, detail: outOfRange))
        }
        let modelClassified = model.degradations.contains { $0.kind == .classification }
        for check in checks {
            guard let reason = check.degradingReason else { continue }
            if check.id == "V7", modelClassified { continue }
            degradations.append(Degradation(kind: Degradation.Kind(rawValue: "validation"),
                                            detail: "\(check.id): \(reason)"))
        }
        return ValidationReport(checks: checks, degradations: degradations)
    }

    static func notApplicable(_ id: String, why: String) -> Check {
        Check(id: id, title: titles[id] ?? id, status: .notApplicable, note: why)
    }

    // MARK: - V1, V2, V7, V13, V14

    static func checkV1(_ model: BuildModel) -> Check {
        var problems: [String] = []
        var outOfRange: [String] = []
        let sessionOK = model.sessionStart.isFinite && model.sessionEnd.isFinite && model.sessionEnd >= model.sessionStart
        if !sessionOK {
            problems.append("session window is not finite or ends before it starts")
        } else if !Timing.isPlausible(model.sessionStart) || !Timing.isPlausible(model.sessionEnd) {
            outOfRange.append("session window beyond ±1e12 s: derived from the tasks")
        }
        let timed = model.tasks.filter(\.hasTiming)
        let badTasks = timed.filter { !finiteTimes($0) || !metricsAreSane($0.metrics) }
        if !badTasks.isEmpty {
            let ids = badTasks.prefix(5).map { String($0.id) }.joined(separator: ", ")
            problems.append("\(badTasks.count) task(s) with NaN, infinite or negative time (ids \(ids))")
        }
        // Finite but absurd (a drifted slot read as 1e300): invalid and excluded from timing, never a failure.
        let huge = timed.filter { finiteTimes($0) && metricsAreSane($0.metrics) && !Timing.isValid($0) }
        if !huge.isEmpty {
            let ids = huge.prefix(5).map { String($0.id) }.joined(separator: ", ")
            outOfRange.append("\(huge.count) task(s) with times beyond ±1e12 s (ids \(ids)): invalid, excluded from timing")
        }
        let badRows = (model.timingSummary?.rows ?? []).filter { !$0.seconds.isFinite || $0.seconds < 0 }
        if !badRows.isEmpty { problems.append("\(badRows.count) timing summary row(s) with invalid seconds") }
        if !problems.isEmpty { return Check(id: "V1", title: "", status: .fail(problems.joined(separator: "; "))) }
        if Timing.hasNoTiming(model) {
            return Check(id: "V1", title: "", status: .warn("no timed tasks: the log has no start and end for any task"))
        }
        if !outOfRange.isEmpty { return Check(id: "V1", title: "", status: .warn(outOfRange.joined(separator: "; "))) }
        return Check(id: "V1", title: "", status: .pass)
    }

    /// What finite but implausible times (beyond ±1e12 s) left out of timing; nil when there are none.
    static func outOfRangeTimes(_ model: BuildModel) -> String? {
        var parts: [String] = []
        let sessionFinite = model.sessionStart.isFinite && model.sessionEnd.isFinite
        if sessionFinite, !Timing.isPlausible(model.sessionStart) || !Timing.isPlausible(model.sessionEnd) {
            parts.append("session window beyond ±1e12 s, derived from the tasks")
        }
        let huge = model.tasks.filter { $0.hasTiming && finiteTimes($0) && !Timing.isValid($0) }.count
        if huge > 0 { parts.append("\(huge) task(s) with times beyond ±1e12 s left out of timing") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// Finite, non-negative and ordered times (V1's own rule; `Timing.isValid` also bounds the magnitude).
    static func finiteTimes(_ task: BuildTask) -> Bool {
        task.start.isFinite && task.end.isFinite && task.duration.isFinite && task.duration >= 0 && task.end >= task.start
    }

    static func metricsAreSane(_ metrics: TaskMetrics?) -> Bool {
        guard let metrics else { return true }
        let values = [metrics.duration, metrics.userCPU, metrics.systemCPU].compactMap { $0 }
        return values.allSatisfy { $0.isFinite && $0 >= 0 }
    }

    static func checkV2(_ analysis: Analysis) -> Check {
        if analysis.clampedCount > 0 {
            let reused = analysis.reusedCount > 0 ? "; \(analysis.reusedCount) reused task(s) excluded" : ""
            return Check(id: "V2", title: "",
                         status: .warn("\(analysis.clampedCount) of \(analysis.taskCount) task intervals clamped to "
                             + "the session window\(reused)"))
        }
        let reused = analysis.reusedCount > 0 ? "\(analysis.reusedCount) reused task(s) excluded" : nil
        return Check(id: "V2", title: "", status: .pass, note: reused)
    }

    static func checkV7(_ analysis: Analysis) -> Check {
        guard analysis.taskTime > 0 else {
            return Check(id: "V7", title: "", status: .notApplicable, note: "no task time")
        }
        let other = analysis.byKind.rows.first { $0.isOther }?.seconds ?? 0
        let share = other / analysis.taskTime
        if share > unclassifiedLimit {
            return Check(id: "V7", title: "",
                         status: .warn(String(format: "%.1f%% of task time is unclassified (limit %.0f%%)",
                                              share * 100, unclassifiedLimit * 100)))
        }
        return Check(id: "V7", title: "", status: .pass)
    }

    static func checkV13(serializedBytes: Int?, budgetBytes: Int) -> Check {
        guard let serializedBytes else {
            return Check(id: "V13", title: "", status: .notApplicable, note: "report not serialized")
        }
        if serializedBytes > budgetBytes {
            return Check(id: "V13", title: "",
                         status: .fail("report is \(serializedBytes) bytes, budget is \(budgetBytes) bytes"))
        }
        return Check(id: "V13", title: "", status: .pass, note: "\(serializedBytes) of \(budgetBytes) bytes")
    }

    // MARK: - V14

    /// Timing-relevant drift, from the reader's structured fields only (never the wording of `detail`): schema drift
    /// on a timing field, and every resync (whole records may be lost).
    static func timingDrift(in model: BuildModel) -> [DecodeWarning] {
        model.decodeWarnings.filter { ($0.kind == .schemaDrift && $0.affectsTiming) || $0.kind == .resync }
    }

    static func checkV14(drift: [DecodeWarning]) -> Check {
        guard let first = drift.first else { return Check(id: "V14", title: "", status: .pass) }
        let more = drift.count > 1 ? " (+\(drift.count - 1) more)" : ""
        return Check(id: "V14", title: "",
                     status: .warn("schema drift on timing fields: \(first.detail)\(more); V2-V5 downgraded"))
    }

    /// V14: a passing timing check becomes a warn when timing fields drifted; fails and n/a stay.
    static func applyDrift(_ check: Check, drift: [DecodeWarning]) -> Check {
        guard !drift.isEmpty, check.status == .pass else { return check }
        return Check(id: check.id, title: check.title,
                     status: .warn("passed, but timing fields drifted from the known schema (V14)"))
    }
}
