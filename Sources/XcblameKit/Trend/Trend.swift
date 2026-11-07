import Foundation

/// `xcblame trend` over `<xcblame-dir>/history` (docs/SCHEMA-v0.4.md "TrendDocument", DESIGN §3.2, §8.2.4 #12).
public enum Trend {
    public struct Options: Sendable, Equatable {
        public var kind: String?
        public var scheme: String?
        /// `--since` already parsed (a date, or `<n>d` resolved against `now`; see `parseSince`).
        public var since: Date?
        public var by: TrendDocument.By?

        public init(kind: String? = nil, scheme: String? = nil, since: Date? = nil, by: TrendDocument.By? = nil) {
            self.kind = kind
            self.scheme = scheme
            self.since = since
            self.by = by
        }
    }

    /// The members of a history entry trend reads. Entries are summaries; the task rows and report tables stay
    /// undecoded, so reading 200 entries stays cheap.
    private struct Light: Decodable {
        struct Build: Decodable {
            var kind: String?
            var span: Double?
            var busy: Double?
            var scheme: String?
        }

        struct Xcode: Decodable { var value: String? }

        struct Environment: Decodable {
            var hwModel: String?
            var logicalCPUCount: Int?
            var memoryBytes: Int64?
            var git: GitInfo?
        }

        var generatedAt: Date?
        var build: Build?
        var xcode: Xcode?
        var environment: Environment?
        /// Present on `build --deep` entries (instrumented, in their own DerivedData): never a trend point.
        var deep: History.DeepMarker?
    }

    private struct Row {
        var point: TrendDocument.Point
        var kind: String
        var scheme: String?
    }

    /// Reads every entry of `history`, filters, groups and computes percentiles. A missing or empty folder is not an
    /// error: the document has no groups and says so in `notes`.
    public static func run(history: URL, options: Options = Options(), now: Date = Date()) throws -> TrendDocument {
        let items = History.list(directory: history, details: false)
        var notes: [String] = []
        var rows: [Row] = []
        var unreadable = 0, untimed = 0, withoutScheme = 0, tooOld = 0, otherKind = 0, otherScheme = 0, untimedEntries = 0
        var deepBuilds = 0
        for item in items {
            guard let light = load(item.url) else {
                unreadable += 1
                continue
            }
            if light.deep != nil {
                deepBuilds += 1
                continue
            }
            let kind = light.build?.kind ?? item.kind
            let time = light.generatedAt ?? item.time
            if let wanted = options.kind, kind != wanted {
                otherKind += 1
                continue
            }
            if let wanted = options.scheme, light.build?.scheme != wanted {
                if light.build?.scheme == nil { withoutScheme += 1 } else { otherScheme += 1 }
                continue
            }
            if let since = options.since, time.map({ $0 < since }) ?? true {
                if time == nil { untimedEntries += 1 } else { tooOld += 1 }
                continue
            }
            // `wall` is `build.span` (never `processWall`), so entries of `analyze` and of `build` stay comparable.
            if light.build?.span == nil, light.build?.busy == nil {
                untimed += 1
                continue
            }
            let git = light.environment?.git
            let point = TrendDocument.Point(
                id: item.id, time: time, wall: light.build?.span, busy: light.build?.busy, xcode: light.xcode?.value,
                commit: git?.commit, branch: git?.branch, machine: machine(light.environment))
            rows.append(Row(point: point, kind: kind, scheme: light.build?.scheme))
        }
        rows.sort { ($0.point.time ?? .distantPast, $0.point.id) < ($1.point.time ?? .distantPast, $1.point.id) }

        if items.isEmpty { notes.append("no history entries in \(history.path); run xcblame build or analyze first") }
        if unreadable > 0 { notes.append("\(unreadable) of \(items.count) history entries could not be read and were skipped") }
        if untimed > 0 { notes.append("\(untimed) entries have no timing (no span and no busy time) and were skipped") }
        if deepBuilds > 0 {
            notes.append("\(deepBuilds) build --deep entr\(deepBuilds == 1 ? "y" : "ies") left out (timing flags in their own "
                + "DerivedData; not comparable with ordinary builds)")
        }
        if let since = options.since, tooOld > 0 {
            notes.append("\(tooOld) entries older than --since (\(ISO8601DateFormatter().string(from: since))) left out")
        }
        if options.since != nil, untimedEntries > 0 {
            notes.append("\(untimedEntries) entries have no time and are left out by --since")
        }
        if options.kind != nil, otherKind > 0 { notes.append("\(otherKind) entries of another kind left out by --kind") }
        if options.scheme != nil {
            if otherScheme > 0 { notes.append("\(otherScheme) entries of another scheme left out by --scheme") }
            if withoutScheme > 0 {
                notes.append("\(withoutScheme) entries have no scheme (analyzed without the log manifest) and are left "
                    + "out by --scheme")
            }
        } else {
            let schemes = Set(rows.compactMap(\.scheme))
            if schemes.count > 1 {
                notes.append("the entries cover \(schemes.count) schemes (\(schemes.sorted().joined(separator: ", "))); "
                    + "pass --scheme to compare like with like")
            }
            let unscoped = rows.filter { $0.scheme == nil }.count
            if unscoped > 0, !schemes.isEmpty { notes.append("\(unscoped) entries have no scheme (analyzed without the log manifest)") }
        }
        let withoutGit = rows.filter { $0.point.commit == nil && $0.point.branch == nil }.count
        if withoutGit > 0 {
            notes.append("\(withoutGit) of \(rows.count) entries carry no git commit or branch: they were built outside a git "
                + "checkout, or recorded by an xcblame older than 0.4, which did not read git")
        }

        return TrendDocument(
            tool: ReportDocument.Tool(name: "xcblame", version: XcblameVersion.current, kindTable: KindTable.v1.version),
            generatedAt: now,
            filter: TrendDocument.Filter(kind: options.kind, scheme: options.scheme, since: options.since, by: options.by),
            entriesTotal: items.count, entriesUsed: rows.count, groups: groups(rows, by: options.by), notes: notes,
            redacted: false)
    }

    // MARK: - Loading

    private static func load(_ url: URL) -> Light? {
        guard let inflated = try? GzipFile.inflate(contentsOf: url), !inflated.truncated else { return nil }
        return try? JSONReporter.decoder().decode(Light.self, from: Data(inflated.bytes))
    }

    /// `Mac15,14/28c/96g`: model, logical cores, memory in GB; a part the entry lacks is left out, nil without a model.
    private static func machine(_ environment: Light.Environment?) -> String? {
        guard let model = environment?.hwModel, !model.isEmpty else { return nil }
        var parts = [model]
        if let cores = environment?.logicalCPUCount { parts.append("\(cores)c") }
        if let bytes = environment?.memoryBytes { parts.append("\(Int((Double(bytes) / 1_073_741_824).rounded()))g") }
        return parts.joined(separator: "/")
    }

    // MARK: - Grouping

    private static func key(_ point: TrendDocument.Point, _ by: TrendDocument.By) -> String? {
        switch by {
        case .xcode: return point.xcode
        case .branch: return point.branch
        case .commit: return point.commit
        case .machine: return point.machine
        }
    }

    private static func groups(_ rows: [Row], by: TrendDocument.By?) -> [TrendDocument.Group] {
        guard !rows.isEmpty else { return [] }
        guard let by else { return [group(key: nil, rows: rows, by: nil)] }
        var buckets: [String: [Row]] = [:]
        for row in rows { buckets[key(row.point, by) ?? unknownKey, default: []].append(row) }
        let keys = buckets.keys.sorted { lhs, rhs in
            if lhs == unknownKey || rhs == unknownKey { return rhs == unknownKey && lhs != unknownKey }
            // A commit hash has no order of its own: commit groups run oldest first (rows are time-sorted).
            if by == .commit {
                let (a, b) = (buckets[lhs]?.first?.point, buckets[rhs]?.first?.point)
                if let ta = a?.time, let tb = b?.time, ta != tb { return ta < tb }
                return lhs < rhs
            }
            // Numeric aware, so Xcode 9.4 sorts before 26.0.
            let order = lhs.compare(rhs, options: [.numeric])
            return order == .orderedSame ? lhs < rhs : order == .orderedAscending
        }
        return keys.map { group(key: $0, rows: buckets[$0] ?? [], by: by) }
    }

    /// The key of entries that carry no value for `--by`.
    public static let unknownKey = "unknown"

    private static func group(key: String?, rows: [Row], by: TrendDocument.By?) -> TrendDocument.Group {
        var byKind: [String: [Row]] = [:]
        for row in rows { byKind[row.kind, default: []].append(row) }
        let series = byKind.keys.sorted().map { kind -> TrendDocument.Series in
            let points = (byKind[kind] ?? []).map(\.point)
            return TrendDocument.Series(
                kind: kind, points: points, wall: percentiles(points.compactMap(\.wall)),
                busy: percentiles(points.compactMap(\.busy)),
                xcodeChangeMarkers: by == .xcode ? [] : markers(points))
        }
        return TrendDocument.Group(key: key, entries: rows.count, series: series)
    }

    /// Between consecutive points whose Xcode differs and is known on both sides.
    static func markers(_ points: [TrendDocument.Point]) -> [TrendDocument.XcodeChange] {
        zip(points, points.dropFirst()).compactMap { previous, next in
            guard let from = previous.xcode, let to = next.xcode, from != to else { return nil }
            return TrendDocument.XcodeChange(atId: next.id, from: from, to: to, time: next.time)
        }
    }

    // MARK: - Statistics

    /// R-7 percentiles (`h = (n - 1) p`, linear between order statistics), so `p50` is the median.
    static func percentiles(_ values: [Double]) -> TrendDocument.Percentiles {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return TrendDocument.Percentiles(n: 0, p50: nil, p75: nil, p95: nil) }
        func at(_ p: Double) -> Double {
            let h = Double(sorted.count - 1) * p
            let low = Int(h.rounded(.down))
            guard low + 1 < sorted.count else { return ReportDocument.round6(sorted[low]) }
            return ReportDocument.round6(sorted[low] + (h - Double(low)) * (sorted[low + 1] - sorted[low]))
        }
        return TrendDocument.Percentiles(n: sorted.count, p50: at(0.5), p75: at(0.75), p95: at(0.95))
    }

    /// Median of the newest `window` walls against the median of the `window` before them, as a fraction (0.08 is
    /// 8 % slower). Nil without at least one point before the newest window.
    public static func recentChange(_ points: [TrendDocument.Point], window: Int = 5) -> (previous: Double, last: Double, change: Double)? {
        let walls = points.compactMap(\.wall)
        guard walls.count > 1 else { return nil }
        let last = Array(walls.suffix(window))
        let previous = Array(walls.dropLast(last.count).suffix(window))
        guard !previous.isEmpty, let before = percentiles(previous).p50, let now = percentiles(last).p50, before > 0 else { return nil }
        return (before, now, (now - before) / before)
    }

    // MARK: - --since

    /// `YYYY-MM-DD` (local midnight) or `<n>d` (n days before `now`); nil when it is neither.
    public static func parseSince(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("d"), let days = Int(trimmed.dropLast()), days >= 0 {
            return now.addingTimeInterval(-Double(days) * 86_400)
        }
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return calendar.startOfDay(for: date)
    }

    // MARK: - Output

    /// `--format json`: pretty, sorted keys, one trailing newline (the same encoder as every other document).
    public static func renderJSON(_ document: TrendDocument) throws -> Data {
        try JSONReporter.encoder().encode(document) + Data("\n".utf8)
    }
}
