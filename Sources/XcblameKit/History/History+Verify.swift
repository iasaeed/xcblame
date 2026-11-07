import Foundation

// v0.6 lane B (docs/SCHEMA-v0.6.md "Storage", Decision 17): `xcblame verify` documents as history verify entries,
// `<xcblame-dir>/history/verify/<id>.json.gz`. The subfolder keeps them out of `History.list` and everything built on
// it (previousIndex, trend, baseline, retention, `compare <id>`); `history prune` prunes it with the same limits.
extension History {
    /// A stored verify entry.
    public struct VerifyItem: Sendable, Equatable {
        /// `<yyyyMMdd-HHmmss>-verify` (`VerifyDocument.id`).
        public var id: String
        public var time: Date?
        public var url: URL
    }

    /// `<history>/verify`.
    public static func verifyDirectory(history: URL) -> URL { history.appendingPathComponent("verify") }

    /// Writes `document` gzipped as `<history>/verify/<id>.json.gz` (`-2`, `-3` … when the id is taken), then prunes
    /// to the retention limits. Throws when it cannot be written.
    @discardableResult
    public static func saveVerify(_ document: VerifyDocument, directory history: URL) throws -> URL {
        let fm = FileManager.default
        let directory = verifyDirectory(history: history)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if history.lastPathComponent == "history" { ensureStateIgnore(in: history.deletingLastPathComponent()) }
        var url = directory.appendingPathComponent(document.id + fileSuffix)
        var counter = 2
        while fm.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(document.id)-\(counter)" + fileSuffix)
            counter += 1
        }
        let staging = directory.appendingPathComponent(".\(UUID().uuidString).json")
        defer { try? fm.removeItem(at: staging) }
        try JSONReporter.render(document).write(to: staging)
        try gzip(staging, to: url)
        _ = try? pruneVerify(directory: history, keep: keepEntries, olderThanDays: keepDays)
        return url
    }

    /// Verify entries of `<history>/verify/`, newest first.
    public static func listVerify(directory history: URL) -> [VerifyItem] {
        let directory = verifyDirectory(history: history)
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return urls.filter { $0.lastPathComponent.hasSuffix(fileSuffix) && !$0.lastPathComponent.hasPrefix(".") }
            .map { url in
                let id = String(url.lastPathComponent.dropLast(fileSuffix.count))
                return VerifyItem(id: id, time: formatter.date(from: String(id.prefix(15))), url: url)
            }
            .sorted { $0.id > $1.id }
    }

    /// The verify entry `id` (or a unique prefix of it).
    public static func showVerify(id: String, directory history: URL) throws -> VerifyDocument {
        let items = listVerify(directory: history)
        let matches = items.contains { $0.id == id } ? items.filter { $0.id == id } : items.filter { $0.id.hasPrefix(id) }
        guard let item = matches.first else { throw HistoryError.notFound(id) }
        guard matches.count == 1 else { throw HistoryError.ambiguous(id, matches.map(\.id)) }
        do {
            let json = Data(try GzipFile.inflate(contentsOf: item.url).bytes)
            return try JSONReporter.decoder().decode(VerifyDocument.self, from: json)
        } catch {
            throw HistoryError.unreadable("\(item.url.lastPathComponent): \(error)")
        }
    }

    /// Deletes verify entries beyond the newest `keep` and older than `olderThanDays`; returns how many went.
    @discardableResult
    public static func pruneVerify(directory history: URL, keep: Int?, olderThanDays: Int?, now: Date = Date()) throws -> Int {
        var removed = 0
        for (index, item) in listVerify(directory: history).enumerated() {
            var doomed = keep.map { index >= $0 } ?? false
            if let olderThanDays, !doomed {
                let when = item.time ?? ((try? item.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? now)
                doomed = now.timeIntervalSince(when) > Double(olderThanDays) * 86_400
            }
            if doomed {
                try FileManager.default.removeItem(at: item.url)
                removed += 1
            }
        }
        return removed
    }
}
