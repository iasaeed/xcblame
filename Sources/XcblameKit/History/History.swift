import CryptoKit
import Foundation

/// Local build history (DESIGN §8.3): one `<yyyyMMdd-HHmmss>-<kind>.json.gz` entry per build in `directory`, holding
/// the report (files, hotspots and top tasks cut to 25 rows) plus the task index rows. Lane B.
public enum History {
    // ponytail: retention is two constants (DESIGN §8.3 says "config"); upgrade: read them from a config file.
    public static let keepEntries = 200
    public static let keepDays = 90
    /// Rows kept of `files`, `hotspots` and `topTasks` in an entry.
    public static let topRows = 25
    static let fileSuffix = ".json.gz"

    public enum HistoryError: Error, Sendable, CustomStringConvertible {
        case notFound(String)
        case ambiguous(String, [String])
        case unreadable(String)

        public var description: String {
            switch self {
            case let .notFound(id): return "no history entry \(id) (xcblame history list shows the ids)"
            case let .ambiguous(id, ids): return "\(id) matches several entries: \(ids.joined(separator: ", "))"
            case let .unreadable(why): return "history entry unreadable: \(why)"
            }
        }
    }

    /// One compact row per executed task. Serialized as an array, in this order:
    /// `[key, rule, target, kind, sigDigest, durationMs, onPath]` (`key` and `target` may be null, `onPath` is 0/1),
    /// plus, only when `why` captured any of them (v0.5, docs/SCHEMA-v0.5.md "History task index"), three trailing
    /// elements `outputHash, outputBytes, inputHashes` (each may be null). Rows without them stay 7 elements long.
    public struct TaskIndexRow: Codable, Sendable, Equatable {
        public var key: String?
        public var rule: String
        public var target: String?
        public var kind: String
        /// First 16 hex digits of SHA256(commandDetails ?? title) with the machine-specific paths normalized
        /// (`History.portable`).
        public var sigDigest: String
        public var durationMs: Int
        public var onPath: Bool
        // v0.5 (lane B fills them from `OutputHashes.Capture`).
        /// First 16 hex of SHA256 of the emitted `.swiftmodule` (or `.abi.json`) of an emit-module task.
        public var outputHash: String? = nil
        public var outputBytes: Int? = nil
        /// Portable input path (`History.portable`) → first 16 hex of SHA256 of its content.
        public var inputHashes: [String: String]? = nil
        /// The task's title with machine paths normalized (`Compiling Models.swift`, `Compiling Clang module Darwin`):
        /// what it produces, which stays the same when Xcode changes the command line. In memory only (rows made from
        /// a model): it is not stored in history entries, so their rows keep the documented layout.
        public var title: String? = nil

        public init(key: String?, rule: String, target: String?, kind: String, sigDigest: String, durationMs: Int,
                    onPath: Bool, outputHash: String? = nil, outputBytes: Int? = nil,
                    inputHashes: [String: String]? = nil, title: String? = nil) {
            self.title = title
            self.key = key
            self.rule = rule
            self.target = target
            self.kind = kind
            self.sigDigest = sigDigest
            self.durationMs = durationMs
            self.onPath = onPath
            self.outputHash = outputHash
            self.outputBytes = outputBytes
            self.inputHashes = inputHashes
        }

        public init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()
            key = try row.decodeNil() ? nil : row.decode(String.self)
            rule = try row.decode(String.self)
            target = try row.decodeNil() ? nil : row.decode(String.self)
            kind = try row.decode(String.self)
            sigDigest = try row.decode(String.self)
            durationMs = try row.decode(Int.self)
            onPath = try row.decode(Int.self) != 0
            if !row.isAtEnd { outputHash = try row.decodeNil() ? nil : row.decode(String.self) }
            if !row.isAtEnd { outputBytes = try row.decodeNil() ? nil : row.decode(Int.self) }
            if !row.isAtEnd { inputHashes = try row.decodeNil() ? nil : row.decode([String: String].self) }
        }

        public func encode(to encoder: Encoder) throws {
            var row = encoder.unkeyedContainer()
            if let key { try row.encode(key) } else { try row.encodeNil() }
            try row.encode(rule)
            if let target { try row.encode(target) } else { try row.encodeNil() }
            try row.encode(kind)
            try row.encode(sigDigest)
            try row.encode(durationMs)
            try row.encode(onPath ? 1 : 0)
            guard outputHash != nil || outputBytes != nil || inputHashes != nil else { return }
            if let outputHash { try row.encode(outputHash) } else { try row.encodeNil() }
            if let outputBytes { try row.encode(outputBytes) } else { try row.encodeNil() }
            if let inputHashes { try row.encode(inputHashes) } else { try row.encodeNil() }
        }
    }

    /// What is stored: the report's own members at top level (so an entry still decodes as a `ReportDocument`) plus
    /// `taskIndexRows`, `logId` (the identity of the log, see `logIdentity(path:)`; absent when unknown) and
    /// `buildStart` (when the build started; absent when the log has no plausible time).
    private struct Entry: Encodable {
        var document: ReportDocument
        var rows: [TaskIndexRow]
        var logId: String?
        /// When the build started (`ReportDocument.Previous.buildStart`); absent when the log has no plausible time.
        var buildStart: Date?

        private enum Key: String, CodingKey { case taskIndexRows, logId, buildStart }

        func encode(to encoder: Encoder) throws {
            try document.encode(to: encoder)
            var container = encoder.container(keyedBy: Key.self)
            try container.encode(rows, forKey: .taskIndexRows)
            try container.encodeIfPresent(logId, forKey: .logId)
            try container.encodeIfPresent(buildStart, forKey: .buildStart)
        }
    }

    /// A listed entry.
    public struct Item: Sendable, Equatable {
        /// File name without `.json.gz`: `<yyyyMMdd-HHmmss>-<kind>`.
        public var id: String
        public var time: Date?
        public var kind: String
        public var url: URL
        /// Log span in seconds, nil when the entry has none or cannot be read.
        public var span: Double?
        public var tasks: Int?
    }

    public struct Shown: Sendable {
        public var item: Item
        public var document: ReportDocument
        public var taskIndexRows: [TaskIndexRow]
        /// The entry's JSON as stored.
        public var json: Data
    }

    // MARK: - Save

    /// Writes the entry, then prunes to the retention limits. Throws when the entry cannot be written; the caller
    /// treats that as a note, never as a failed build.
    public static func save(document: ReportDocument, model: BuildModel, directory: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if directory.lastPathComponent == "history" { ensureStateIgnore(in: directory.deletingLastPathComponent()) }
        // One entry per log: analyzing the same log again does not count that build twice (code review v0.2 #14). The
        // log is told by its identity, never by its file name (`build.log` is many builds).
        let identity = document.input.path.flatMap(logIdentity(path:))
        if let identity, let newest = list(directory: directory, details: false).first,
           logIdentity(of: newest.url) == identity {
            return directory.appendingPathComponent(newest.url.lastPathComponent)
        }

        let kind = sanitized(document.build.kind ?? "unknown")
        var date = document.generatedAt
        var url = directory.appendingPathComponent(entryName(date, kind) + fileSuffix)
        // Second resolution: a second build in the same second takes the next free second.
        while fm.fileExists(atPath: url.path) {
            date = date.addingTimeInterval(1)
            url = directory.appendingPathComponent(entryName(date, kind) + fileSuffix)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(Entry(document: trimmed(document), rows: taskIndexRows(document, model), logId: identity,
                                               buildStart: ReportDocument.Previous.buildStart(of: model)))
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).json")
        defer { try? fm.removeItem(at: staging) }
        try json.write(to: staging)
        try gzip(staging, to: url)
        _ = try? prune(directory: directory, keep: keepEntries, olderThanDays: keepDays)
        return url
    }

    /// The report with `files`, `hotspots` and `topTasks` cut to `topRows`, and the tasks of each
    /// `incremental.causes` and `fixedCosts` entry too (the task index rows already hold every task). Totals stay;
    /// each cut list's shown share is rescaled to what the kept rows cover.
    static func trimmed(_ document: ReportDocument) -> ReportDocument {
        var out = document
        if var incremental = out.incremental {
            for index in incremental.causes.indices where incremental.causes[index].tasks.count > topRows {
                let tasks = incremental.causes[index].tasks
                incremental.causes[index].tasksShownShare = rescaled(
                    incremental.causes[index].tasksShownShare, kept: tasks.prefix(topRows).map(\.seconds),
                    shown: tasks.map(\.seconds))
                incremental.causes[index].tasks = Array(tasks.prefix(topRows))
            }
            out.incremental = incremental
        }
        if var costs = out.fixedCosts {
            for index in costs.indices where costs[index].tasks.count > topRows {
                let tasks = costs[index].tasks
                costs[index].tasksShownShare = rescaled(costs[index].tasksShownShare,
                                                        kept: tasks.prefix(topRows).map(\.seconds),
                                                        shown: tasks.map(\.seconds))
                costs[index].tasks = Array(tasks.prefix(topRows))
            }
            out.fixedCosts = costs
        }
        if let rows = out.files, rows.count > topRows {
            out.filesShownShare = rescaled(out.filesShownShare, kept: rows.prefix(topRows).map(\.seconds),
                                           shown: rows.map(\.seconds))
            out.files = Array(rows.prefix(topRows))
        }
        if let rows = out.hotspots, rows.count > topRows {
            out.hotspotsShownShare = rescaled(out.hotspotsShownShare, kept: rows.prefix(topRows).map(\.ms),
                                              shown: rows.map(\.ms))
            out.hotspots = Array(rows.prefix(topRows))
        }
        if let rows = out.topTasks, rows.count > topRows {
            out.topTasksShownShare = rescaled(out.topTasksShownShare, kept: rows.prefix(topRows).map(\.seconds),
                                              shown: rows.map(\.seconds))
            out.topTasks = Array(rows.prefix(topRows))
        }
        return out
    }

    private static func rescaled(_ share: Double?, kept: [Double], shown: [Double]) -> Double? {
        let shownSum = shown.reduce(0, +)
        guard let share, shownSum > 0 else { return nil }
        return min(1, share * kept.reduce(0, +) / shownSum)
    }

    /// Executed tasks only: reused (started before the window), cache-fetched, untimed and invalid tasks are not rows.
    /// Durations are the clamped intervals of `Timing.timeline`, in whole milliseconds.
    static func taskIndexRows(_ document: ReportDocument, _ model: BuildModel) -> [TaskIndexRow] {
        let onPath = Set(document.criticalPath?.segments.flatMap(\.taskIds) ?? [])
        let roots = projectRoots(of: model)
        let developerDir = document.environment?.developerDir
        return Timing.timeline(model).counted.map { item in
            let task = item.task
            let target = task.targetId.flatMap { model.targets.indices.contains($0) ? model.targets[$0].name : nil }
            return TaskIndexRow(key: task.taskKey, rule: task.ruleName, target: target, kind: task.kind.rawValue,
                                sigDigest: digest(portable(task.commandDetails ?? task.title, roots: roots, developerDir: developerDir)),
                                durationMs: Timing.millis(item.interval.duration), onPath: onPath.contains(task.id),
                                title: String(portable(task.title, roots: roots, developerDir: developerDir).prefix(200)))
        }
    }

    /// `text` without what differs between machines and checkouts: every project root (`roots`) becomes `$REPO`, the
    /// Xcode developer dir (`/Applications/<name>.app/Contents/Developer`, and `developerDir` when known)
    /// `$DEVELOPER_DIR`, a DerivedData folder (the folder above `Build/Intermediates.noindex` or `Build/Products`,
    /// wherever it is) `$DERIVED_DATA`, any home folder's user name `$USER` (the Redactor's path rules), so a digest
    /// made on a developer's Mac matches the same task on a CI runner.
    static func portable(_ text: String, roots: [String], developerDir: String? = nil) -> String {
        var text = text
        for root in roots.sorted(by: { ($0.count, $0) > ($1.count, $1) }) where root.count > 1 {
            text = text.replacingOccurrences(of: root, with: "$REPO")
        }
        if let developerDir, developerDir.count > 1 { text = text.replacingOccurrences(of: developerDir, with: "$DEVELOPER_DIR") }
        text = replacing(developerDirectory, in: text, with: "\\$DEVELOPER_DIR")
        let redacted = Redactor.redact(string: text, context: Redactor.Context(home: "", user: "", host: "", repoRoot: nil))
        // Compiler flags glue a path to the flag (`-I/Users/x/...`), which the Redactor's path-start rule leaves alone.
        return replacing(derivedDataFolder, in: replacing(homeFolder, in: redacted, with: "$1\\$USER"),
                         with: "\\$DERIVED_DATA/Build/$1")
    }

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static let homeFolder = try! NSRegularExpression(pattern: #"(/(?:Users|home)/)(?!Shared(?:/|$))[^/\s"'<>()\[\],:=]+"#)

    private static let developerDirectory = try! NSRegularExpression(pattern: #"/Applications/[^/\s"']+\.app/Contents/Developer"#)

    private static let derivedDataFolder = try! NSRegularExpression(
        pattern: #"(?:\$REPO|~)?/[^\s"'<>()\[\],:=]+?/Build/(Intermediates\.noindex|Products)(?=/|$)"#)

    private static let workingDirectory = try! NSRegularExpression(pattern: "(?:^|[\r\n])[ \t]*cd (/[^\r\n]+)")

    /// Every folder a task ran in: the distinct `cd <dir>` of the first tasks' command lines (the folder holding the
    /// `.xcodeproj` or `.xcworkspace`, whose name is dropped), so sibling projects and local packages are covered.
    static func projectRoots(of model: BuildModel) -> [String] {
        var roots = Set<String>()
        for task in model.tasks.prefix(200) {
            guard let details = task.commandDetails, details.contains("cd /") else { continue }
            let whole = NSRange(details.startIndex..., in: details)
            for match in workingDirectory.matches(in: details, range: whole) {
                guard var root = Range(match.range(at: 1), in: details).map({ String(details[$0]) }) else { continue }
                if root.hasSuffix(".xcodeproj") || root.hasSuffix(".xcworkspace") { root = (root as NSString).deletingLastPathComponent }
                if root.count > 1 { roots.insert(root) }
            }
        }
        return roots.sorted()
    }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - List, show, prune

    /// Entries newest first. A file that does not look like an entry is skipped; one that cannot be decoded is listed
    /// without span and tasks.
    public static func list(directory: URL, details: Bool = true) -> [Item] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent.hasSuffix(fileSuffix) && !$0.lastPathComponent.hasPrefix(".") }
            .map { item(at: $0, details: details) }
            .sorted { $0.id > $1.id }
    }

    /// `id` is an entry id or a unique prefix of one (the time stamp alone is enough).
    public static func show(id: String, directory: URL) throws -> Shown {
        let items = list(directory: directory)
        let matches = items.contains { $0.id == id } ? items.filter { $0.id == id } : items.filter { $0.id.hasPrefix(id) }
        guard !matches.isEmpty else { throw HistoryError.notFound(id) }
        guard matches.count == 1, let item = matches.first else { throw HistoryError.ambiguous(id, matches.map(\.id)) }
        let json: Data
        do { json = Data(try GzipFile.inflate(contentsOf: item.url).bytes) } catch {
            throw HistoryError.unreadable("\(item.url.lastPathComponent): \(error)")
        }
        struct Rows: Decodable { var taskIndexRows: [TaskIndexRow]? }
        do {
            let document = try JSONReporter.decoder().decode(ReportDocument.self, from: json)
            let rows = try JSONDecoder().decode(Rows.self, from: json).taskIndexRows ?? []
            return Shown(item: item, document: document, taskIndexRows: rows, json: json)
        } catch {
            throw HistoryError.unreadable("\(item.url.lastPathComponent): \(error)")
        }
    }

    /// Deletes entries beyond the newest `keep` and entries older than `olderThanDays`; returns how many went. When
    /// `directory` is `<xcblame-dir>/history`, also prunes `<xcblame-dir>/snapshots/` (`pruneSnapshots`).
    @discardableResult
    public static func prune(directory: URL, keep: Int?, olderThanDays: Int?, now: Date = Date()) throws -> Int {
        let removed = try pruneEntries(directory: directory, keep: keep, olderThanDays: olderThanDays, now: now)
        if directory.lastPathComponent == "history" {
            try pruneSnapshots(directory.deletingLastPathComponent().appendingPathComponent("snapshots"),
                               history: directory, now: now)
        }
        return removed
    }

    // ponytail: a snapshot goes only when no surviving history entry names its log (entry `input.path` basename ==
    // snapshot uuid) AND it is older than `keepDays` or beyond the newest `keepEntries` by mtime; so a kept entry
    // never loses its snapshot. upgrade: store the snapshot uuid in the entry instead of matching log names.
    /// Deletes `<snapshots>/<uuid>/` folders no surviving entry in `history` needs, past the retention limits.
    /// Returns how many went.
    @discardableResult
    static func pruneSnapshots(_ snapshots: URL, history: URL, now: Date = Date()) throws -> Int {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: [.contentModificationDateKey,
                                                                                                  .isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        guard !folders.isEmpty else { return 0 }
        let needed = Set(list(directory: history, details: false).compactMap { logName(of: $0.url) })
        let dated = folders.map { url in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now)
        }.sorted { $0.1 > $1.1 }
        var removed = 0
        for (index, (url, date)) in dated.enumerated() where !needed.contains(url.lastPathComponent) {
            guard index >= keepEntries || now.timeIntervalSince(date) > Double(keepDays) * 86_400 else { continue }
            try fm.removeItem(at: url)
            removed += 1
        }
        return removed
    }

    /// The log file name without extension (the snapshot uuid) of the entry's `input.path`; nil when unreadable.
    static func logName(of entry: URL) -> String? {
        struct Light: Decodable {
            struct Input: Decodable { var path: String? }
            var input: Input?
        }
        guard let inflated = try? GzipFile.inflate(contentsOf: entry),
              let path = (try? JSONDecoder().decode(Light.self, from: Data(inflated.bytes)))?.input?.path else { return nil }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// What tells one build log from another: `uuid:<UUID>` when the log's file name is a UUID (Xcode names its logs
    /// that way, and the snapshot folder shares it), else `sha256:<hex>-<size>` over the first 1 MiB, the last 64 KiB
    /// and the size of the file (the bundle's `Info.plist` for a folder such as an `.xcresult`). Nil when the log cannot be read.
    static func logIdentity(path: String) -> String? {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        if let uuid = UUID(uuidString: name) { return "uuid:" + uuid.uuidString }
        var target = path
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            target = (path as NSString).appendingPathComponent("Info.plist")
        }
        guard let handle = FileHandle(forReadingAtPath: target) else { return nil }
        defer { try? handle.close() }
        guard var head = try? handle.read(upToCount: 1 << 20),
              let size = (try? FileManager.default.attributesOfItem(atPath: target))?[.size] as? NSNumber else { return nil }
        if size.intValue > head.count {
            let tail = max(size.intValue - (1 << 16), head.count)
            guard (try? handle.seek(toOffset: UInt64(tail))) != nil, let end = try? handle.readToEnd() else { return nil }
            head.append(end)
        }
        return "sha256:" + SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined() + "-\(size)"
    }

    /// The identity an entry stores (`logId`); an entry written before it existed has its log's UUID name, else none.
    static func logIdentity(of entry: URL) -> String? {
        struct Light: Decodable {
            struct Input: Decodable { var path: String? }
            var input: Input?
            var logId: String?
        }
        guard let inflated = try? GzipFile.inflate(contentsOf: entry),
              let light = try? JSONDecoder().decode(Light.self, from: Data(inflated.bytes)) else { return nil }
        if let id = light.logId { return id }
        guard let path = light.input?.path else { return nil }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return UUID(uuidString: name).map { "uuid:" + $0.uuidString }
    }

    private static func pruneEntries(directory: URL, keep: Int?, olderThanDays: Int?, now: Date) throws -> Int {
        var removed = 0
        for (index, entry) in list(directory: directory, details: false).enumerated() {
            var doomed = keep.map { index >= $0 } ?? false
            if let olderThanDays, !doomed {
                let when = entry.time ?? ((try? entry.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? now)
                doomed = now.timeIntervalSince(when) > Double(olderThanDays) * 86_400
            }
            if doomed {
                try FileManager.default.removeItem(at: entry.url)
                removed += 1
            }
        }
        return removed
    }

    // MARK: - Names

    private static func entryName(_ date: Date, _ kind: String) -> String {
        "\(XcodebuildRunner.timestamp(date))-\(kind)"
    }

    private static func sanitized(_ kind: String) -> String {
        let clean = String(kind.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "-" })
        return clean.isEmpty ? "unknown" : clean
    }

    private static func item(at url: URL, details: Bool) -> Item {
        let id = String(url.lastPathComponent.dropLast(fileSuffix.count))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let time = formatter.date(from: String(id.prefix(15)))
        let kind = id.count > 16 ? String(id.dropFirst(16)) : "unknown"

        struct Light: Decodable {
            struct Build: Decodable { var span: Double?; var tasks: Int? }
            var build: Build?
        }
        let light = (details ? try? GzipFile.inflate(contentsOf: url) : nil).flatMap {
            try? JSONDecoder().decode(Light.self, from: Data($0.bytes))
        }
        return Item(id: id, time: time, kind: kind, url: url, span: light?.build?.span, tasks: light?.build?.tasks)
    }
}
