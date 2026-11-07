import Foundation

// v0.6 lane B (docs/SCHEMA-v0.6.md "Storage"; DESIGN §7.8 step 3): one DerivedData per arm, outside the repository,
// because toggling a setting changes task signatures and would turn the other arm's next build into a rebuild. The
// `DeepDerivedData` pattern: a marker file, mtime touched on use, pruned after 30 days unused.
public enum VerifyDerivedData {
    public static let keepDays = OracleCache.keepDays
    /// All verify DerivedData together may hold at most this much; least recently used arm first.
    public static let maxBytes: Int64 = 20 << 30
    static let marker = ".xcblame-verify"

    /// `<home>/verify/<plan>/<label>/` (`A`, `B-<RULE>`, `B-batch`).
    public static func directory(home: URL, plan: String, label: String) -> URL {
        home.appendingPathComponent("verify/\(plan)/\(label)")
    }

    /// Creates the folder, writes its marker and touches it. Returns it (the arm's `-derivedDataPath`).
    public static func prepare(home: URL, plan: String, label: String) throws -> URL {
        let dir = directory(home: home, plan: plan, label: label)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(marker)
        if !fm.fileExists(atPath: file.path) {
            try Data("xcblame verify DerivedData of plan \(plan), arm \(label)\n".utf8).write(to: file)
        }
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
        return dir
    }

    /// Marked arm folders of `<home>/verify/*/`, least recently used first.
    static func entries(home: URL) -> [(url: URL, modified: Date)] {
        let fm = FileManager.default
        let root = home.appendingPathComponent("verify")
        let plans = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return plans.flatMap { plan in
            ((try? fm.contentsOfDirectory(at: plan, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .filter { fm.fileExists(atPath: $0.appendingPathComponent(marker).path) }
        }
        .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
        .sorted { $0.modified < $1.modified }
    }

    /// `DeepDerivedData.prune`'s rules on the verify arms: older than `olderThanDays` (every arm when nil), then least
    /// recently used until the rest fit `maxBytes`. Empty plan folders go too. Returns how many arms went.
    @discardableResult
    public static func prune(home: URL, olderThanDays: Int?, maxBytes: Int64? = VerifyDerivedData.maxBytes,
                             now: Date = Date()) -> Int {
        let fm = FileManager.default
        var removed = 0
        var kept: [URL] = []
        for entry in entries(home: home) {
            if let days = olderThanDays, now.timeIntervalSince(entry.modified) <= Double(days) * 86_400 {
                kept.append(entry.url)
                continue
            }
            if (try? fm.removeItem(at: entry.url)) != nil { removed += 1 }
        }
        if let maxBytes {
            var sizes = kept.map { ($0, OracleCache.size(of: $0)) }
            var total = sizes.reduce(0) { $0 + $1.1 }
            while total > maxBytes, sizes.count > 1, let (url, bytes) = sizes.first {
                sizes.removeFirst()
                if (try? fm.removeItem(at: url)) != nil {
                    removed += 1
                    total -= bytes
                }
            }
        }
        let root = home.appendingPathComponent("verify")
        for plan in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        where ((try? fm.contentsOfDirectory(atPath: plan.path)) ?? ["?"]).isEmpty {
            try? fm.removeItem(at: plan)
        }
        return removed
    }
}
