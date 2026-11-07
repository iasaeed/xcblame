import Foundation

// v0.5 lane A (docs/SCHEMA-v0.5.md "Deep"): `--deep` builds in their own DerivedData, outside the repository, because
// the injected flags change every Swift task signature (DESIGN §5.8).
public enum DeepDerivedData {
    /// Entries untouched for longer than this are pruned (the oracle cache rule, `OracleCache.keepDays`).
    public static let keepDays = OracleCache.keepDays
    /// All deep DerivedData together may hold at most this much; least recently used first.
    public static let maxBytes: Int64 = 20 << 30

    /// `<home>/deep/<first 16 hex of sha256(container path)>`; `home` is `OracleCache.home()` (honours
    /// `XCBLAME_CACHE_DIR`, falls back to `$TMPDIR/xcblame`).
    public static func directory(for container: URL, home: URL) -> URL {
        home.appendingPathComponent("deep/" + SettingsCache.sha256(container.standardizedFileURL.path).prefix(16))
    }

    /// The file that marks a folder as a deep DerivedData entry (pruning never touches anything else).
    static let marker = ".xcblame-deep"

    /// Creates the folder, writes its marker and touches it (mtime drives pruning). Returns the folder, which is the
    /// `-derivedDataPath` of the deep build.
    public static func prepare(for container: URL, home: URL) throws -> URL {
        let dir = directory(for: container, home: home)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(marker)
        if !fm.fileExists(atPath: file.path) {
            try Data("xcblame build --deep DerivedData for \(container.standardizedFileURL.path)\n".utf8).write(to: file)
        }
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
        return dir
    }

    /// `-stats-output-dir` of a deep build: inside the deep DerivedData, emptied before each build.
    public static func statsDirectory(in derivedData: URL) -> URL {
        derivedData.appendingPathComponent("xcblame-stats")
    }

    /// Marked entries of `<home>/deep/`, least recently used first.
    static func entries(home: URL) -> [(url: URL, modified: Date)] {
        let fm = FileManager.default
        let root = home.appendingPathComponent("deep")
        return ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { fm.fileExists(atPath: $0.appendingPathComponent(marker).path) }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.modified < $1.modified }
    }

    /// The oracle cache's prune rules on `<home>/deep/` (marked entries only): entries older than `olderThanDays`
    /// (every entry when nil), then the least recently used ones until the rest fit in `maxBytes`. Returns how many
    /// went.
    @discardableResult
    public static func prune(home: URL, olderThanDays: Int?, maxBytes: Int64? = DeepDerivedData.maxBytes,
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
        guard let maxBytes else { return removed }
        var sizes = kept.map { ($0, OracleCache.size(of: $0)) }
        var total = sizes.reduce(0) { $0 + $1.1 }
        // The newest entry (the one a running build uses) always stays.
        while total > maxBytes, sizes.count > 1, let (url, bytes) = sizes.first {
            sizes.removeFirst()
            if (try? fm.removeItem(at: url)) != nil {
                removed += 1
                total -= bytes
            }
        }
        return removed
    }
}
