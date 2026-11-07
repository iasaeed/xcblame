import Foundation

/// The noise model and verdict of DESIGN §6.10 (docs/SCHEMA-v0.4.md "Regression"). The value it returns is
/// `ReportDocument.Regression`; this enum only holds the functions.
public enum Regression {
    public struct Options: Sendable, Equatable {
        /// `--fail-if-slower <pct>` as a fraction (5 % = 0.05); nil: never fails.
        public var thresholdPct: Double?
        /// Added to the threshold when the verdict is `indicative` (< 3 runs per side).
        public var allowancePct: Double
        /// Band = `madMultiplier × pooledMad`.
        public var madMultiplier: Double
        /// A delta under this fraction of the baseline wall is noise.
        public var minPct: Double
        /// Runs per side needed for the MAD band.
        public var minRunsForBand: Int

        public init(thresholdPct: Double? = nil, allowancePct: Double = 0.05, madMultiplier: Double = 3,
                    minPct: Double = 0.02, minRunsForBand: Int = 3) {
            self.thresholdPct = thresholdPct
            self.allowancePct = allowancePct
            self.madMultiplier = madMultiplier
            self.minPct = minPct
            self.minRunsForBand = minRunsForBand
        }
    }

    typealias Value = ReportDocument.Regression

    /// A baseline that cannot be used (unreadable, not a baseline, no wall time to compare): exit 1 with a
    /// `regression:` message, as docs/SCHEMA-v0.4.md "Exit codes" says.
    public struct NotEvaluable: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
        public var reason: String
        public init(_ reason: String) { self.reason = reason }
        public var description: String { "regression: \(reason)" }
        public var errorDescription: String? { description }
    }

    // MARK: - Against a baseline file

    /// Current run(s) against a baseline file. A mismatch of kind, scheme, configuration or destination (both known and
    /// different) throws `XcblameError.usage`; an Xcode or machine difference is attributed (`env`), not refused.
    public static func evaluate(current: [ReportDocument], baseline: Baseline,
                                options: Options = Options()) throws -> ReportDocument.Regression {
        try evaluate(current: current, baseline: baseline, baselineRef: nil, currentTaskRows: nil, options: options)
    }

    /// As above, plus the path the baseline came from (`regression.baseline.ref`) and the executed tasks of the current
    /// run (`Compare.taskRows`), which let a baseline with task digests name the tasks that are new.
    public static func evaluate(current: [ReportDocument], baseline: Baseline, baselineRef: String?,
                                currentTaskRows: [History.TaskIndexRow]?,
                                options: Options = Options()) throws -> ReportDocument.Regression {
        guard let first = current.first else { throw XcblameError.usage("regression: there is no current run to compare") }
        let key = try key(of: current, side: "current")
        var notes = try requireSameBuild(Key(kind: baseline.key.kind, scheme: baseline.key.scheme,
                                             configuration: baseline.key.configuration,
                                             destination: baseline.key.destination, xcode: baseline.key.xcode),
                                         key, "baseline", "current")
        var basis = "span"
        var baselineWall = baseline.wall.median
        if baseline.wallBasis == "processWall" {
            if current.allSatisfy({ $0.timing.processWall != nil }) {
                basis = "processWall"
            } else {
                baselineWall = nil
                notes.append("wall: the baseline measured the process wall (xcblame build) but the current run has none "
                    + "(a log analyzed afterwards); wall is not comparable, busy and critical path are")
            }
        }
        let walls = current.compactMap { $0.wall(basis: basis) }
        if walls.count < current.count { notes.append("wall: \(current.count - walls.count) current run(s) have no \(basis)") }
        let headline = headline(baselineWall: baselineWall, baselineMad: baseline.wall.mad, baselineRuns: baseline.runs,
                                currentWalls: walls, options: options)
        notes += headline.notes

        var attribution: [Value.Attribution] = []
        if let baselineXcode = baseline.key.xcode, let currentXcode = key.xcode, baselineXcode != currentXcode {
            attribution.append(.init(kind: "env", subject: "xcode", detail: "\(baselineXcode) -> \(currentXcode) (inferred)",
                                     deltaSeconds: nil))
        }
        if let before = machineParts(baseline.machine), let after = machineParts(first.machineSummary) {
            for (field, x, y) in [("hwModel", before.model, after.model), ("cores", before.cores, after.cores),
                                  ("memGB", before.memory, after.memory)] where x != y {
                attribution.append(.init(kind: "env", subject: field, detail: "\(x) -> \(y)", deltaSeconds: nil))
            }
        }
        if let digests = baseline.tasks {
            if let rows = currentTaskRows {
                attribution += digestAttribution(rows: rows, baseline: digests)
            } else {
                notes.append("attribution: the executed tasks of the current run are not available, so new tasks are not named")
            }
        } else {
            notes.append("attribution beyond the environment needs a reference report (xcblame compare) or a baseline "
                + "saved with --with-tasks")
        }
        return Value(
            baseline: .init(source: "file", ref: baselineRef, savedAt: baseline.savedAt, kind: baseline.key.kind,
                            scheme: baseline.key.scheme, configuration: baseline.key.configuration,
                            destination: baseline.key.destination, xcode: baseline.key.xcode, runs: baseline.runs),
            verdict: headline.verdict, wallBasis: basis, wall: headline.wall,
            busy: delta(baseline.busy.median, Stats.median(current.compactMap(\.build.busy))),
            criticalPath: delta(baseline.criticalPath.median, Stats.median(current.compactMap { $0.criticalPath?.span })),
            noiseBand: headline.noise, attribution: ordered(attribution), thresholdPct: options.thresholdPct,
            allowancePct: options.allowancePct, failed: headline.failed, notes: notes)
    }

    // MARK: - Against another report or log

    /// Current run(s) against the runs of another report or log (`compare`).
    public static func evaluate(current: [ReportDocument], reference: [ReportDocument], referenceRef: String?,
                                options: Options = Options()) throws -> ReportDocument.Regression {
        guard !current.isEmpty, !reference.isEmpty else {
            throw XcblameError.usage("regression: both sides need at least one run")
        }
        let currentKey = try key(of: current, side: "current")
        let referenceKey = try key(of: reference, side: "reference")
        var notes = try requireSameBuild(referenceKey, currentKey, "reference", "current")
        let basis = ReportDocument.wallBasis(of: current + reference)
        if basis == "span", (current + reference).contains(where: { $0.timing.processWall != nil }) {
            notes.append("wall: not every run measured the process wall, so every wall is the log span")
        }
        let referenceWalls = reference.compactMap { $0.wall(basis: basis) }
        let currentWalls = current.compactMap { $0.wall(basis: basis) }
        let headline = headline(baselineWall: Stats.median(referenceWalls), baselineMad: Stats.mad(referenceWalls),
                                baselineRuns: referenceWalls.count, currentWalls: currentWalls, options: options)
        notes += headline.notes

        let a = reference[CompareDiffs.representative(reference)], b = current[CompareDiffs.representative(current)]
        var attribution: [Value.Attribution] = []
        let env = CompareDiffs.envDiffs(a: a, b: b).diffs.filter { attributedEnv.contains($0.field) }
        for diff in env {
            let detail = "\(diff.a ?? "unknown") -> \(diff.b ?? "unknown")" + (diff.field == "xcode" ? " (inferred)" : "")
            attribution.append(.init(kind: "env", subject: diff.field, detail: detail, deltaSeconds: nil))
        }
        if let x = CompareDiffs.phaseEntries(a), let y = CompareDiffs.phaseEntries(b) {
            attribution += rowAttribution("phase", CompareDiffs.diffRows(x, y), unit: "task time")
        }
        if let x = CompareDiffs.targetEntries(a), let y = CompareDiffs.targetEntries(b) {
            attribution += rowAttribution("target", CompareDiffs.diffRows(x, y), unit: "task time")
        }
        if let x = CompareDiffs.pathEntries(a), let y = CompareDiffs.pathEntries(b) {
            attribution += rowAttribution("path", CompareDiffs.diffRows(x, y), unit: "on the critical path")
        }
        for setting in (CompareDiffs.settingDiffs(a: a, b: b) ?? []).prefix(settingLimit) {
            let before = setting.a.map { "\($0)" } ?? "not evidenced"
            let after = setting.b.map { "\($0)" } ?? "not evidenced"
            attribution.append(.init(kind: "setting", subject: setting.ref, detail: "\(before) -> \(after)", deltaSeconds: nil))
        }
        return Value(
            baseline: .init(source: "report", ref: referenceRef, savedAt: a.generatedAt, kind: referenceKey.kind,
                            scheme: referenceKey.scheme, configuration: referenceKey.configuration,
                            destination: referenceKey.destination, xcode: referenceKey.xcode, runs: reference.count),
            verdict: headline.verdict, wallBasis: basis, wall: headline.wall,
            busy: delta(Stats.median(reference.compactMap(\.build.busy)), Stats.median(current.compactMap(\.build.busy))),
            criticalPath: delta(Stats.median(reference.compactMap { $0.criticalPath?.span }),
                                Stats.median(current.compactMap { $0.criticalPath?.span })),
            noiseBand: headline.noise, attribution: ordered(attribution), thresholdPct: options.thresholdPct,
            allowancePct: options.allowancePct, failed: headline.failed, notes: notes)
    }

    // MARK: - The noise model

    struct Headline {
        var wall: Value.Delta
        var verdict: String
        var noise: Value.NoiseBand
        var failed: Bool
        var notes: [String]
    }

    /// DESIGN §6.10, frozen in docs/SCHEMA-v0.4.md "Noise model": with at least `minRunsForBand` runs on each side the
    /// verdict compares the medians against `max(3 × pooled MAD, 2 % of the baseline)`; with fewer it is `indicative`
    /// and only the threshold plus the allowance can fail. Decisions use the numbers as they are printed (6 decimals).
    static func headline(baselineWall: Double?, baselineMad: Double?, baselineRuns: Int, currentWalls: [Double],
                         options: Options) -> Headline {
        let wall = delta(baselineWall, Stats.median(currentWalls))
        let runsCurrent = currentWalls.count
        var notes: [String] = []
        var verdict = "indicative"
        var method = "threshold"
        var pooled: Double?
        var band: Double?
        if let base = wall.baseline, base > 0, let change = wall.delta {
            let enough = baselineRuns >= options.minRunsForBand && runsCurrent >= options.minRunsForBand
            if enough, let madBaseline = baselineMad, let madCurrent = Stats.mad(currentWalls) {
                method = "mad"
                let pooledMad = Stats.round6(Stats.pooled(madBaseline, madCurrent))
                let width = Stats.round6(max(options.madMultiplier * pooledMad, options.minPct * base))
                pooled = pooledMad
                band = width
                verdict = abs(change) > width ? (change > 0 ? "slower" : "faster") : "same"
            } else if enough {
                notes.append("the baseline holds no MAD, so no noise band: verdict indicative")
            } else {
                notes.append("indicative: \(runsCurrent) run(s) now against \(baselineRuns) in the baseline; "
                    + "a noise band needs \(options.minRunsForBand) or more on each side")
            }
        } else {
            notes.append("wall: the baseline median is \(wall.baseline == nil ? "unknown" : "0") or the current wall is "
                + "unknown, so there is no delta and the verdict is indicative")
        }
        var failed = false
        if let threshold = options.thresholdPct, let pct = wall.deltaPct {
            failed = verdict == "indicative" ? pct > threshold + options.allowancePct
                : verdict == "slower" && pct > threshold
        }
        if options.thresholdPct != nil, wall.delta == nil {
            notes.append("--fail-if-slower: the wall is not comparable (no baseline or current wall of the same basis), "
                + "so the threshold cannot fail this run")
        }
        let noise = Value.NoiseBand(method: method, pooledMad: pooled, madMultiplier: options.madMultiplier,
                                    minPct: options.minPct, band: band, runsBaseline: baselineRuns,
                                    runsCurrent: runsCurrent)
        return Headline(wall: wall, verdict: verdict, noise: noise, failed: failed, notes: notes)
    }

    static func delta(_ baseline: Double?, _ current: Double?) -> Value.Delta {
        guard let baseline, let current else {
            return .init(baseline: baseline.map(Stats.round6), current: current.map(Stats.round6), delta: nil, deltaPct: nil)
        }
        let change = current - baseline
        return .init(baseline: Stats.round6(baseline), current: Stats.round6(current), delta: Stats.round6(change),
                     deltaPct: baseline > 0 ? Stats.round6(change / baseline) : nil)
    }

    // MARK: - Key matching

    struct Key: Equatable {
        var kind: String?
        var scheme: String?
        var configuration: String?
        var destination: String?
        var xcode: String?
    }

    /// The build identity of one side: the first known value of each field. Runs of one side that disagree on kind,
    /// scheme, configuration or destination are a usage error. Destinations agree as `BuildContext.destinationsAgree`
    /// says, which is not transitive (`macOS` agrees with `macOS arm64` and with `macOS x86_64`, those two do not), so
    /// every run is checked against the merged destination of all of them, not against the first. `names` labels the
    /// runs in the message (history ids, by position); without them a run is `run N`.
    static func key(of documents: [ReportDocument], side: String, names: [String] = []) throws -> Key {
        func pick(_ field: String, _ value: (ReportDocument) -> String?,
                  agree: (String, String) -> Bool = { $0 == $1 }) throws -> String? {
            let known = documents.enumerated().compactMap { index, document in value(document).map { (index: index, value: $0) } }
            let merged = field == "destination" ? BuildContext.mergedDestination(known.map(\.value)) : known.first?.value
            if let merged, let other = known.first(where: { !agree($0.value, merged) }) {
                func label(_ index: Int) -> String { names.count == documents.count ? names[index] : "run \(index + 1)" }
                let anchor = known.first { $0.value == merged }
                throw XcblameError.usage("regression: the \(side) runs differ in \(field) (\(merged)\(anchor.map { " in " + label($0.index) } ?? "") "
                    + "and \(other.value) in \(label(other.index)))")
            }
            return merged
        }
        return Key(kind: try pick("kind") { $0.build.kind }, scheme: try pick("scheme") { $0.build.scheme },
                   configuration: try pick("configuration") { $0.build.configuration },
                   destination: try pick("destination", { $0.build.destination }, agree: BuildContext.destinationsAgree),
                   xcode: documents.compactMap { $0.xcode.value }.first)
    }

    /// Two known, different values of kind, scheme, configuration or destination never compare (destinations compare
    /// on the platform, and on the architecture only when both sides have one). A field that is unknown on either side
    /// is not compared: the returned notes name those fields, so a Release log is never silently compared with a Debug
    /// baseline.
    static func requireSameBuild(_ x: Key, _ y: Key, _ xName: String, _ yName: String) throws -> [String] {
        var skipped: [String] = []
        for (field, left, right) in [("kind", x.kind, y.kind), ("scheme", x.scheme, y.scheme),
                                     ("configuration", x.configuration, y.configuration),
                                     ("destination", x.destination, y.destination)] {
            guard let left, let right else {
                skipped.append(field)
                continue
            }
            if field == "destination" ? !BuildContext.destinationsAgree(left, right) : left != right {
                throw XcblameError.usage("regression: \(field) differs: \(xName) \(left), \(yName) \(right) "
                    + "(builds compare only when kind, scheme, configuration and destination agree)")
            }
        }
        return skipped.isEmpty ? [] : ["key: \(skipped.joined(separator: ", ")) unknown on the \(xName) or the \(yName) side, "
            + "so not compared; the builds may differ in \(skipped.count == 1 ? "it" : "them")"]
    }

    // MARK: - Attribution

    /// Environment fields that can move the wall time (the rest of the env diff is listed by `compare`, not blamed).
    private static let attributedEnv: Set<String> = ["xcode", "xcodeSelected", "macOS", "hwModel", "cores", "memGB", "rosetta"]
    private static let rowLimit = 5
    private static let settingLimit = 10
    /// A phase, target or path row moving less than this is not a reason.
    private static let minAttributedSeconds = 0.05

    static func machineParts(_ summary: String?) -> (model: String, cores: String, memory: String)? {
        guard let parts = summary?.split(separator: "/", omittingEmptySubsequences: false), parts.count == 3 else { return nil }
        return (String(parts[0]), String(parts[1]), String(parts[2]))
    }

    static func signed(_ seconds: Double) -> String { (seconds < 0 ? "-" : "+") + TextReporter.duration(abs(seconds)) }

    static func rowAttribution(_ kind: String, _ rows: [CompareDocument.Row], unit: String) -> [Value.Attribution] {
        let moved = rows.filter { !$0.isOther && abs($0.seconds.delta ?? 0) >= minAttributedSeconds }
            .sorted { abs($0.seconds.delta ?? 0) != abs($1.seconds.delta ?? 0)
                ? abs($0.seconds.delta ?? 0) > abs($1.seconds.delta ?? 0) : $0.key < $1.key }
        return moved.prefix(rowLimit).map { row in
            let change = row.seconds.delta ?? 0
            let state = row.status == "added" ? "new, " : row.status == "removed" ? "gone, " : ""
            return .init(kind: kind, subject: row.key,
                         detail: "\(state)\(signed(change)) \(unit) (\(TextReporter.duration(row.seconds.a ?? 0)) -> "
                             + "\(TextReporter.duration(row.seconds.b ?? 0)))", deltaSeconds: Stats.round6(change))
        }
    }

    /// New, removed and changed (paired by title) executed tasks, grouped by `target: rule`, largest first.
    static func taskAttribution(added: [CompareDocument.TaskRef], removed: [CompareDocument.TaskRef],
                                changed: [CompareDocument.TaskChange] = []) -> [Value.Attribution] {
        func group(_ refs: [CompareDocument.TaskRef], sign: Double, word: String) -> [Value.Attribution] {
            var totals: [String: (count: Int, seconds: Double)] = [:]
            for ref in refs {
                totals["\(ref.target ?? "(no target)"): \(ref.rule)", default: (0, 0)].count += 1
                totals["\(ref.target ?? "(no target)"): \(ref.rule)", default: (0, 0)].seconds += ref.seconds
            }
            return totals.map { subject, total in
                .init(kind: "task", subject: subject,
                      detail: "\(total.count) \(word) task\(total.count == 1 ? "" : "s"), \(signed(sign * total.seconds))",
                      deltaSeconds: Stats.round6(sign * total.seconds))
            }
        }
        var moved: [String: (count: Int, seconds: Double)] = [:]
        for change in changed {
            moved["\(change.target ?? "(no target)"): \(change.rule)", default: (0, 0)].count += 1
            moved["\(change.target ?? "(no target)"): \(change.rule)", default: (0, 0)].seconds += change.seconds.delta ?? 0
        }
        let changedRows: [Value.Attribution] = moved.compactMap { subject, total in
            abs(total.seconds) < minAttributedSeconds ? nil : .init(
                kind: "task", subject: subject,
                detail: "\(total.count) task\(total.count == 1 ? "" : "s") on both sides (paired by name; Xcode changed their "
                    + "command lines), net \(signed(total.seconds))", deltaSeconds: Stats.round6(total.seconds))
        }
        let all = group(added, sign: 1, word: "new") + group(removed, sign: -1, word: "removed") + changedRows
        return Array(all.sorted { abs($0.deltaSeconds ?? 0) != abs($1.deltaSeconds ?? 0)
            ? abs($0.deltaSeconds ?? 0) > abs($1.deltaSeconds ?? 0) : $0.subject < $1.subject }.prefix(rowLimit))
    }

    /// Tasks of the current run whose digest is not in the baseline (seconds known) and how many baseline digests are
    /// gone (no seconds: the baseline keeps none).
    static func digestAttribution(rows: [History.TaskIndexRow], baseline: Baseline.TaskDigests) -> [Value.Attribution] {
        let known = Set(baseline.ids)
        let current = Set(rows.map(Baseline.digest))
        let added = rows.filter { !known.contains(Baseline.digest($0)) }.map {
            CompareDocument.TaskRef(rule: $0.rule, target: $0.target, kind: $0.kind, seconds: Double($0.durationMs) / 1000,
                                    onPath: $0.onPath)
        }
        var out = taskAttribution(added: added, removed: [])
        let gone = known.subtracting(current).count
        if gone > 0 {
            out.append(.init(kind: "task", subject: "removed tasks",
                             detail: "\(gone) task\(gone == 1 ? "" : "s") of the baseline did not run (seconds unknown)",
                             deltaSeconds: nil))
        }
        return out
    }

    /// `env`, `phase`, `target`, `path`, `task`, `setting` (environment first, DESIGN §6.10), each by |seconds|
    /// descending; ties keep the order they were found in.
    static func ordered(_ items: [Value.Attribution]) -> [Value.Attribution] {
        let rank = ["env": 0, "phase": 1, "target": 2, "path": 3, "task": 4, "setting": 5]
        return items.enumerated().sorted { x, y in
            let rx = rank[x.element.kind] ?? 9, ry = rank[y.element.kind] ?? 9
            if rx != ry { return rx < ry }
            let dx = abs(x.element.deltaSeconds ?? 0), dy = abs(y.element.deltaSeconds ?? 0)
            return dx != dy ? dx > dy : x.offset < y.offset
        }.map(\.element)
    }
}
