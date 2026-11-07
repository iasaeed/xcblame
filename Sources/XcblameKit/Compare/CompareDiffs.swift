import Foundation

/// The build-vs-build diffs shared by `Compare.run` (the tables) and `Regression.evaluate(…reference:…)` (attribution).
/// Every delta is `b - a`; unknown stays nil, never 0.
enum CompareDiffs {
    typealias Row = CompareDocument.Row
    typealias Pair = CompareDocument.Pair

    /// Differences under half a millisecond are not differences.
    static let epsilon = 0.0005

    static func pair(_ a: Double?, _ b: Double?) -> Pair {
        guard let a, let b else {
            return Pair(a: a.map(Stats.round6), b: b.map(Stats.round6), delta: nil, deltaPct: nil)
        }
        let delta = b - a
        return Pair(a: Stats.round6(a), b: Stats.round6(b), delta: Stats.round6(delta),
                    deltaPct: a > 0 ? Stats.round6(delta / a) : nil)
    }

    // MARK: - Environment

    /// The listing order of `CompareDocument.EnvDiff.field`.
    static let envFields = ["kind", "scheme", "configuration", "destination", "xcode", "xcodeSelected", "macOS",
                            "hwModel", "cores", "memGB", "rosetta", "ciProvider", "branch", "commit", "dirty",
                            "toolVersion"]

    /// Known values of the compared fields (a field absent from the dictionary is unknown).
    static func envValues(_ doc: ReportDocument) -> [String: String] {
        var out: [String: String] = [:]
        func put(_ key: String, _ value: String?) { if let value, !value.isEmpty { out[key] = value } }
        put("kind", doc.build.kind)
        put("scheme", doc.build.scheme)
        put("configuration", doc.build.configuration)
        put("destination", doc.build.destination)
        put("xcode", doc.xcode.value)
        put("toolVersion", doc.tool.version)
        guard let env = doc.environment else { return out }
        let lines = (env.xcodebuildVersion ?? "").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if var version = lines.first(where: { $0.hasPrefix("Xcode ") }).map({ String($0.dropFirst(6)) }) {
            if let build = lines.first(where: { $0.hasPrefix("Build version ") }) {
                version += " (" + build.dropFirst("Build version ".count) + ")"
            }
            put("xcodeSelected", version)
        }
        if var macOS = env.macOSProductVersion {
            if let build = env.macOSBuildVersion { macOS += " (\(build))" }
            put("macOS", macOS)
        }
        put("hwModel", env.hwModel)
        put("cores", env.logicalCPUCount.map(String.init))
        put("memGB", env.memoryBytes.map { String($0 >> 30) })
        put("rosetta", env.processTranslated.map { $0 ? "yes" : "no" })
        put("ciProvider", env.ciProvider ?? "none")
        put("branch", env.git?.branch)
        put("commit", env.git?.commit)
        put("dirty", env.git?.dirty.map { $0 ? "true" : "false" })
        return out
    }

    /// The fields known on both sides and different, in listing order, and how many fields were comparable.
    static func envDiffs(a: ReportDocument, b: ReportDocument) -> (diffs: [CompareDocument.EnvDiff], compared: Int) {
        let x = envValues(a), y = envValues(b)
        var diffs: [CompareDocument.EnvDiff] = []
        var compared = 0
        for field in envFields {
            guard let left = x[field], let right = y[field] else { continue }
            compared += 1
            if left != right { diffs.append(.init(field: field, a: left, b: right)) }
        }
        return (diffs, compared)
    }

    // MARK: - Rows

    struct Entry {
        var key: String
        var seconds: Double
        var tasks: Int?
        var isOther: Bool
    }

    private static let otherKey = "\u{1}other"

    static func phaseEntries(_ doc: ReportDocument) -> [Entry]? {
        doc.phases?.map { Entry(key: $0.key, seconds: $0.taskTime, tasks: $0.tasks, isOther: $0.isOther) }
    }

    static func targetEntries(_ doc: ReportDocument) -> [Entry]? {
        doc.targets?.map { Entry(key: $0.name, seconds: $0.taskTime, tasks: $0.tasks, isOther: $0.isOther) }
    }

    /// On-path seconds per target (`criticalPath.segments`), plus the waits as `(waiting)`; nil without a path.
    static func pathEntries(_ doc: ReportDocument) -> [Entry]? {
        guard let path = doc.criticalPath else { return nil }
        var seconds: [String: Double] = [:]
        for segment in path.segments { seconds[segment.target ?? "(no target)", default: 0] += segment.seconds }
        var entries = seconds.map { Entry(key: $0.key, seconds: $0.value, tasks: nil, isOther: false) }
        let waits = path.waits.reduce(0) { $0 + $1.seconds }
        if waits > 0 { entries.append(Entry(key: "(waiting)", seconds: waits, tasks: nil, isOther: false)) }
        return entries
    }

    /// One row per key of either side (the `other` rows match each other whatever their names), by |delta| descending
    /// with the `other` row last.
    static func diffRows(_ a: [Entry], _ b: [Entry]) -> [Row] {
        func index(_ list: [Entry]) -> [String: Entry] {
            var out: [String: Entry] = [:]
            for entry in list {
                let key = entry.isOther ? otherKey : entry.key
                if var current = out[key] {
                    current.seconds += entry.seconds
                    if let tasks = entry.tasks { current.tasks = (current.tasks ?? 0) + tasks }
                    out[key] = current
                } else { out[key] = entry }
            }
            return out
        }
        let left = index(a), right = index(b)
        let rows = Set(left.keys).union(right.keys).map { key -> Row in
            let x = left[key], y = right[key]
            let isOther = key == otherKey
            let name = isOther ? (y?.key ?? x?.key ?? "other") : key
            let seconds = pair(x?.seconds ?? 0, y?.seconds ?? 0)
            let hasTasks = (x ?? y)?.tasks != nil
            let tasks = hasTasks ? pair(Double(x?.tasks ?? 0), Double(y?.tasks ?? 0)) : nil
            return Row(key: name, status: status(x != nil, y != nil, seconds: seconds, tasks: tasks), seconds: seconds,
                       tasks: tasks, isOther: isOther)
        }
        return sorted(rows)
    }

    private static func status(_ inA: Bool, _ inB: Bool, seconds: Pair, tasks: Pair?) -> String {
        if !inA { return "added" }
        if !inB { return "removed" }
        let moved = abs(seconds.delta ?? 0) >= epsilon || abs(tasks?.delta ?? 0) >= 0.5
        return moved ? "changed" : "same"
    }

    static func sorted(_ rows: [Row]) -> [Row] {
        rows.sorted { x, y in
            if x.isOther != y.isOther { return !x.isOther }
            let dx = abs(x.seconds.delta ?? 0), dy = abs(y.seconds.delta ?? 0)
            return dx != dy ? dx > dy : x.key < y.key
        }
    }

    /// Keeps the `keep` rows with the largest |delta| and folds the rest into the `other` row (created when there is
    /// none), so the partition stays. `shownShare` is the share of the total |delta| the kept rows cover.
    static func capped(_ rows: [Row], keep: Int) -> (rows: [Row], shownShare: Double?) {
        let normal = rows.filter { !$0.isOther }
        let other = rows.first { $0.isOther }
        let total = rows.reduce(0) { $0 + abs($1.seconds.delta ?? 0) }
        guard normal.count > keep else { return (rows, total > 0 ? 1 : nil) }
        let kept = Array(normal.prefix(keep))
        let folded = normal.dropFirst(keep)
        var a = other?.seconds.a ?? 0, b = other?.seconds.b ?? 0
        var tasksA = other?.tasks?.a ?? 0, tasksB = other?.tasks?.b ?? 0
        for row in folded {
            a += row.seconds.a ?? 0
            b += row.seconds.b ?? 0
            tasksA += row.tasks?.a ?? 0
            tasksB += row.tasks?.b ?? 0
        }
        let hasTasks = rows.contains { $0.tasks != nil }
        let seconds = pair(a, b)
        let tasks = hasTasks ? pair(tasksA, tasksB) : nil
        let bucket = Row(key: other?.key ?? "other", status: status(true, true, seconds: seconds, tasks: tasks),
                         seconds: seconds, tasks: tasks, isOther: true)
        let shown = kept.reduce(0) { $0 + abs($1.seconds.delta ?? 0) } + abs(other?.seconds.delta ?? 0)
        return (kept + [bucket], total > 0 ? Stats.round6(min(1, shown / total)) : nil)
    }

    // MARK: - Tasks

    /// Executed tasks only on one side, matched as a multiset on `(rule, target, sigDigest)`: within a key the longer
    /// runs are paired rank by rank, so the leftover (the shortest) is the one reported. Leftovers on both sides are
    /// then paired by `TaskIdentity.outputShape` (rule, target, title): a new Xcode changes every command line, and
    /// those pairs are `changed`, not one new and one removed. Each list is by seconds (|b − a| for changed) descending.
    static func taskDiff(a: [History.TaskIndexRow], b: [History.TaskIndexRow])
        -> (added: [CompareDocument.TaskRef], removed: [CompareDocument.TaskRef], changed: [CompareDocument.TaskChange]) {
        func groups(_ rows: [History.TaskIndexRow]) -> [String: [History.TaskIndexRow]] {
            Dictionary(grouping: rows) { "\($0.rule)\u{1}\($0.target ?? "")\u{1}\($0.sigDigest)" }
                .mapValues { $0.sorted { $0.durationMs != $1.durationMs ? $0.durationMs > $1.durationMs : $0.onPath && !$1.onPath } }
        }
        let left = groups(a), right = groups(b)
        var onlyB: [History.TaskIndexRow] = [], onlyA: [History.TaskIndexRow] = []
        for key in Set(left.keys).union(right.keys).sorted() {
            let x = left[key] ?? [], y = right[key] ?? []
            if y.count > x.count { onlyB += y[x.count...] }
            if x.count > y.count { onlyA += x[y.count...] }
        }
        let paired = TaskIdentity.pairByOutput(onlyA, onlyB)
        func ref(_ row: History.TaskIndexRow) -> CompareDocument.TaskRef {
            .init(rule: row.rule, target: row.target, kind: row.kind, seconds: Double(row.durationMs) / 1000, onPath: row.onPath,
                  title: row.title)
        }
        let changed = paired.pairs.map { pair in
            CompareDocument.TaskChange(rule: pair.b.rule, target: pair.b.target, kind: pair.b.kind, title: pair.b.title,
                                       seconds: Self.pair(Double(pair.a.durationMs) / 1000, Double(pair.b.durationMs) / 1000),
                                       onPath: pair.a.onPath || pair.b.onPath)
        }.sorted { x, y in
            let dx = abs(x.seconds.delta ?? 0), dy = abs(y.seconds.delta ?? 0)
            if dx != dy { return dx > dy }
            if x.rule != y.rule { return x.rule < y.rule }
            if x.target != y.target { return (x.target ?? "") < (y.target ?? "") }
            return (x.title ?? "") < (y.title ?? "")
        }
        func order(_ x: CompareDocument.TaskRef, _ y: CompareDocument.TaskRef) -> Bool {
            if x.seconds != y.seconds { return x.seconds > y.seconds }
            if x.rule != y.rule { return x.rule < y.rule }
            if x.target != y.target { return (x.target ?? "") < (y.target ?? "") }
            if x.title != y.title { return (x.title ?? "") < (y.title ?? "") }
            // Equal in every other member: the order must not depend on the dictionary's, or two runs differ.
            return x.kind != y.kind ? x.kind < y.kind : x.onPath && !y.onPath
        }
        return (paired.b.map(ref).sorted(by: order), paired.a.map(ref).sorted(by: order), changed)
    }

    /// The first `keep` changed tasks and the share of the |b − a| seconds they hold.
    static func capped(_ changes: [CompareDocument.TaskChange], keep: Int) -> (rows: [CompareDocument.TaskChange], share: Double?) {
        let shown = Array(changes.prefix(keep))
        let total = changes.reduce(0) { $0 + abs($1.seconds.delta ?? 0) }
        return (shown, total > 0 ? Stats.round6(min(1, shown.reduce(0) { $0 + abs($1.seconds.delta ?? 0) } / total)) : nil)
    }

    /// The first `keep` of a by-seconds-descending list and the share of the list's seconds they hold.
    static func capped(_ refs: [CompareDocument.TaskRef], keep: Int) -> (rows: [CompareDocument.TaskRef], share: Double?) {
        let shown = Array(refs.prefix(keep))
        let total = refs.reduce(0) { $0 + $1.seconds }
        return (shown, total > 0 ? Stats.round6(min(1, shown.reduce(0) { $0 + $1.seconds } / total)) : nil)
    }

    // MARK: - Settings

    /// `findings[].evidenceDetails` of kind `setting`, first occurrence per `ref`.
    static func settingEvidence(_ doc: ReportDocument) -> [String: (value: String?, provenance: String?)] {
        var out: [String: (value: String?, provenance: String?)] = [:]
        for finding in doc.findings {
            for item in finding.evidenceDetails where item.kind == "setting" && out[item.ref] == nil {
                out[item.ref] = (item.value, item.provenance)
            }
        }
        return out
    }

    /// Settings whose value or provenance differs (or that only one side evidences); nil when neither side has setting
    /// evidence.
    static func settingDiffs(a: ReportDocument, b: ReportDocument) -> [CompareDocument.SettingDiff]? {
        let x = settingEvidence(a), y = settingEvidence(b)
        guard !x.isEmpty || !y.isEmpty else { return nil }
        return Set(x.keys).union(y.keys).sorted().compactMap { ref in
            let left = x[ref], right = y[ref]
            guard left?.value != right?.value || left?.provenance != right?.provenance || left == nil || right == nil
            else { return nil }
            return .init(ref: ref, a: left?.value, b: right?.value, provenanceA: left?.provenance,
                         provenanceB: right?.provenance)
        }
    }

    // MARK: - Choosing the run that stands for a side

    /// Index of the run whose log span is closest to the median span (the first on a tie).
    static func representative(_ documents: [ReportDocument]) -> Int {
        let spans = documents.map { $0.build.span ?? 0 }
        guard let middle = Stats.median(spans) else { return 0 }
        return documents.indices.min { abs(spans[$0] - middle) < abs(spans[$1] - middle) } ?? 0
    }
}
