import CryptoKit
import Foundation

extension Baseline {
    /// Summarizes `documents` (one per run, same build key) into a baseline: medians and MADs over the runs, the runs
    /// count and, when `taskRows` is given (the executed tasks of the median-wall run, `medianRunIndex`), the task
    /// digests. Throws `XcblameError.usage` when the runs do not share kind, scheme, configuration, destination and
    /// inferred Xcode version.
    public static func make(from documents: [ReportDocument], source: Source,
                            taskRows: [History.TaskIndexRow]? = nil, now: Date = Date()) throws -> Baseline {
        guard let first = documents.first else { throw XcblameError.usage("baseline: there is no run to summarize") }
        let key: Regression.Key
        do { key = try Regression.key(of: documents, side: "baseline", names: source.refs) } catch XcblameError.usage(let why) {
            throw XcblameError.usage(why.replacingOccurrences(of: "regression: the baseline runs", with: "baseline: the runs"))
        }
        let versions = Set(documents.compactMap { $0.xcode.value })
        if versions.count > 1 {
            throw XcblameError.usage("baseline: the runs differ in the inferred Xcode version (\(versions.sorted().joined(separator: " and "))); "
                + "a baseline is one Xcode version")
        }
        let basis = ReportDocument.wallBasis(of: documents)
        var notes: [String] = []
        if basis == "span", documents.contains(where: { $0.timing.processWall != nil }) {
            notes.append("wall: not every run measured the process wall, so the medians are of the log span")
        }
        func stat(_ values: [Double], _ name: String) -> Stat {
            if values.count < documents.count { notes.append("\(name): \(documents.count - values.count) of \(documents.count) runs have no value") }
            return Stat(median: Stats.median(values).map(Stats.round6), mad: Stats.mad(values).map(Stats.round6))
        }
        let wall = stat(documents.compactMap { $0.wall(basis: basis) }, "wall")
        let busy = stat(documents.compactMap(\.build.busy), "busy")
        let path = stat(documents.compactMap { $0.criticalPath?.span }, "criticalPath")
        if documents.count < 3 {
            notes.append("\(documents.count) run\(documents.count == 1 ? "" : "s"): a build compared with this baseline gets "
                + "the verdict indicative; save 3 or more runs for a noise band")
        }
        let tasks = taskRows.map { rows in
            TaskDigests(total: rows.count, ids: Array(Set(rows.map(digest))).sorted())
        }
        let refs = source.refs.map { ($0 as NSString).lastPathComponent }
        return Baseline(
            tool: ReportDocument.Tool(name: "xcblame", version: XcblameVersion.current, kindTable: first.tool.kindTable),
            savedAt: now, source: Source(kind: source.kind, refs: refs),
            key: Key(kind: key.kind, scheme: key.scheme, configuration: key.configuration, destination: key.destination,
                     xcode: documents.compactMap { $0.xcode.value }.first),
            wallBasis: basis, runs: documents.count, wall: wall, busy: busy, criticalPath: path,
            git: first.environment?.git, machine: first.machineSummary, tasks: tasks, notes: notes)
    }

    /// Index of the run whose wall (`wallBasis`) is closest to the median: the run whose tasks stand for the baseline.
    public static func medianRunIndex(of documents: [ReportDocument]) -> Int {
        let basis = ReportDocument.wallBasis(of: documents)
        let walls = documents.map { $0.wall(basis: basis) ?? 0 }
        guard let middle = Stats.median(walls) else { return 0 }
        return documents.indices.min { abs(walls[$0] - middle) < abs(walls[$1] - middle) } ?? 0
    }

    /// First 8 bytes (16 hex digits) of SHA256(`rule \t target \t sigDigest`): the id of an executed task that survives
    /// a rebuild and carries no command line.
    static func digest(_ row: History.TaskIndexRow) -> String {
        SHA256.hash(data: Data("\(row.rule)\t\(row.target ?? "")\t\(row.sigDigest)".utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Files

    /// Reads a baseline file: a file that cannot be read is `XcblameError.logNotFound` (exit 5), one that is not a
    /// `xcblame.baseline/1` document is `Regression.NotEvaluable` (exit 1).
    public static func load(from url: URL) throws -> Baseline {
        guard let data = try? Data(contentsOf: url) else { throw XcblameError.logNotFound(url.path) }
        struct Probe: Decodable { var schemaVersion: String? }
        let version = (try? JSONDecoder().decode(Probe.self, from: data))?.schemaVersion
        guard let version, version.hasPrefix("xcblame.baseline/") else {
            throw Regression.NotEvaluable("\(url.lastPathComponent) is not an xcblame baseline (no schemaVersion xcblame.baseline/1)")
        }
        guard version == schemaVersion else {
            throw Regression.NotEvaluable("\(url.lastPathComponent) is \(version); this xcblame reads \(schemaVersion). Update xcblame")
        }
        do { return try JSONReporter.decoder().decode(Baseline.self, from: data) } catch {
            throw Regression.NotEvaluable("\(url.lastPathComponent) is not a complete \(schemaVersion) document (\(error))")
        }
    }

    /// Writes the baseline atomically: sorted keys, pretty-printed, trailing newline (so a committed file diffs well).
    public func save(to url: URL) throws {
        let data = try JSONReporter.encoder().encode(self) + Data("\n".utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - From the local history

    /// The runs a history-based baseline aggregates: the newest entry (of `kind` when given) fixes the build key (kind,
    /// scheme, configuration, destination, inferred Xcode version, all exactly equal), and the newest `count` entries
    /// with that key are taken, oldest first. Entries that cannot be decoded are skipped. Fewer than `count` matching
    /// entries is not an error: the caller reads `skipped` and `available`.
    public struct HistoryRuns: Sendable {
        public var entries: [History.Shown]
        /// Entries with another key than the newest one (left out).
        public var otherKey: Int
        /// Entries of the right kind that matched, including those beyond `count`.
        public var available: Int
        /// `build --deep` entries left out (instrumented builds in their own DerivedData).
        public var deep = 0
    }

    public static func selectHistory(directory: URL, kind: String?, count: Int) -> HistoryRuns {
        struct Rows: Decodable { var taskIndexRows: [History.TaskIndexRow]? }
        var chosen: [History.Shown] = []
        var otherKey = 0
        var available = 0
        var deep = 0
        var key: Regression.Key?
        for item in History.list(directory: directory, details: false) {
            guard let inflated = try? GzipFile.inflate(contentsOf: item.url) else { continue }
            let json = Data(inflated.bytes)
            guard let document = try? JSONReporter.decoder().decode(ReportDocument.self, from: json) else { continue }
            if let kind, document.build.kind != kind { continue }
            if document.deep != nil {
                deep += 1
                continue
            }
            let entryKey = Regression.Key(kind: document.build.kind, scheme: document.build.scheme,
                                          configuration: document.build.configuration,
                                          destination: document.build.destination, xcode: document.xcode.value)
            if key == nil { key = entryKey }
            // Destinations agree as `BuildContext.destinationsAgree` says, so the `build` and `analyze` entries of one
            // build (`macOS` and `macOS arm64`) are one group.
            guard let key, entryKey.kind == key.kind, entryKey.scheme == key.scheme,
                  entryKey.configuration == key.configuration, entryKey.xcode == key.xcode,
                  (entryKey.destination == nil) == (key.destination == nil),
                  BuildContext.destinationsAgree(entryKey.destination, key.destination) else { otherKey += 1; continue }
            available += 1
            if chosen.count < count {
                let rows = (try? JSONDecoder().decode(Rows.self, from: json))?.taskIndexRows ?? []
                chosen.append(History.Shown(item: item, document: document, taskIndexRows: rows, json: json))
            }
        }
        return HistoryRuns(entries: chosen.reversed(), otherKey: otherKey, available: available, deep: deep)
    }
}
