import Foundation

/// Retention for the state folder's `results/`, `logs/` and `reports/` plus history dedupe (DESIGN §8.3; v0.2 review
/// open items). `History.prune` keeps handling `history/` and `snapshots/`.
public enum Retention {
    public struct Policy: Sendable, Equatable {
        public var keepEntries: Int
        public var keepDays: Int

        public init(keepEntries: Int = History.keepEntries, keepDays: Int = History.keepDays) {
            self.keepEntries = keepEntries
            self.keepDays = keepDays
        }
    }

    /// Entries removed per folder name (`results`, `logs`, `reports`, `history`).
    public struct Outcome: Sendable, Equatable {
        public var removed: [String: Int]

        public init(removed: [String: Int] = [:]) { self.removed = removed }

        public var total: Int { removed.values.reduce(0, +) }
    }

    /// The folders of the state folder that grow with every build (`snapshots/` and `history/` have their own rules).
    public static let folders = ["results", "logs", "reports"]

    // ponytail: the policy is the history constants (200 entries, 90 days); upgrade: read `retention` from
    // `.xcblame/config.json` once that file has a reader.
    /// Prunes `results/`, `logs/` and `reports/` of `stateDir` to the newest `keepEntries` and `keepDays` (by file
    /// time, per folder). Only entries xcblame names itself (`<yyyyMMdd-HHmmss>…`) are touched, so a file somebody
    /// put there stays. Nothing outside the three folders is ever read or removed: a folder that is a symbolic link
    /// is skipped, entries are examined with `lstat` (never followed), and a link entry goes as the link only.
    public static func apply(stateDir: URL, policy: Policy = Policy(), now: Date = Date()) throws -> Outcome {
        var outcome = Outcome()
        for name in folders {
            let folder = stateDir.appendingPathComponent(name, isDirectory: true)
            guard attributes(of: folder)?[.type] as? FileAttributeType == .typeDirectory else { continue }
            outcome.removed[name] = prune(folder, policy: policy, now: now)
        }
        return outcome
    }

    /// Removes history entries whose log (its identity, `History.logIdentity`; never the file name) an older entry
    /// already covers, keeping the oldest.
    /// Returns how many went. `History.save` only looks at the newest entry, so analyzing log A, then B, then A again
    /// leaves two entries for A; this finds those.
    @discardableResult
    public static func dedupeHistory(directory: URL) throws -> Int {
        var seen = Set<String>()
        var removed = 0
        // `History.list` is newest first; the oldest entry of a log is the one to keep.
        for entry in History.list(directory: directory, details: false).reversed() {
            guard let log = History.logIdentity(of: entry.url) else { continue }
            if seen.insert(log).inserted { continue }
            try FileManager.default.removeItem(at: entry.url)
            removed += 1
        }
        return removed
    }

    // MARK: - Folder pruning

    /// `yyyyMMdd-HHmmss` at the start of a name: what `XcodebuildRunner.timestamp` and `HTMLOutput` write.
    static func isXcblameName(_ name: String) -> Bool {
        let stamp = Array(name.utf8.prefix(15))
        guard stamp.count == 15 else { return false }
        return stamp.enumerated().allSatisfy { index, byte in
            index == 8 ? byte == UInt8(ascii: "-") : (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
    }

    private static func attributes(of url: URL) -> [FileAttributeKey: Any]? {
        // `attributesOfItem` is `lstat`: a symbolic link reports `.typeSymbolicLink`, never its target.
        try? FileManager.default.attributesOfItem(atPath: url.path)
    }

    private static func prune(_ folder: URL, policy: Policy, now: Date) -> Int {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
        let entries: [(url: URL, name: String, modified: Date)] = names.filter(isXcblameName).compactMap { name in
            let url = folder.appendingPathComponent(name)
            return attributes(of: url).map { (url, name, ($0[.modificationDate] as? Date) ?? now) }
        }.sorted { ($0.modified, $0.name) > ($1.modified, $1.name) }
        var removed = 0
        for (index, entry) in entries.enumerated() {
            let tooMany = index >= policy.keepEntries
            let tooOld = now.timeIntervalSince(entry.modified) > Double(policy.keepDays) * 86_400
            guard tooMany || tooOld else { continue }
            // One entry that cannot go (read-only, in use) must not keep the others.
            if (try? fm.removeItem(at: entry.url)) != nil { removed += 1 }
        }
        return removed
    }
}
