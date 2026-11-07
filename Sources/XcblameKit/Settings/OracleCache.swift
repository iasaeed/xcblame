import Foundation

/// Where the settings oracle keeps its heavy scratch (DESIGN §5.8 pattern): the generated workspace, one DerivedData
/// per configuration and package clones live in `<home>/oracle/<sha16(container path)>/`, outside the user's
/// repository. `<home>` is `~/Library/Caches/xcblame`, `$TMPDIR/xcblame` when that is not writable, or
/// `XCBLAME_CACHE_DIR` (tests, CI). Only the small settings JSON stays in `<xcblame-dir>/cache/settings`.
public enum OracleCache {
    /// Entries untouched for longer than this are pruned by `doctor` and `history prune`.
    public static let keepDays = 30

    public static func home(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let custom = environment["XCBLAME_CACHE_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: NSString(string: custom).expandingTildeInPath).standardizedFileURL
        }
        let fm = FileManager.default
        let caches = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/xcblame")
        if (try? fm.createDirectory(at: caches, withIntermediateDirectories: true)) != nil, fm.isWritableFile(atPath: caches.path) {
            return caches
        }
        return fm.temporaryDirectory.appendingPathComponent("xcblame")
    }

    /// `<home>/oracle/<first 16 hex of sha256(container path)>`.
    public static func directory(for container: URL, home: URL) -> URL {
        home.appendingPathComponent("oracle/" + SettingsCache.sha256(container.standardizedFileURL.path).prefix(16))
    }

    /// Bytes under `url` (allocated size, symlinks not followed); 0 when it does not exist.
    public static func size(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in walker {
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// The whole oracle home may hold at most this much; the least recently used entries go first.
    public static let maxBytes: Int64 = 5 << 30

    /// The oracle's own entries (marker or `Settings.xcworkspace`; never anything else in a custom
    /// `XCBLAME_CACHE_DIR`), least recently used first.
    public static func entries(home: URL) -> [(url: URL, modified: Date)] {
        let fm = FileManager.default
        let root = home.appendingPathComponent("oracle")
        return ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent(marker).path)
                    || fm.fileExists(atPath: $0.appendingPathComponent("Settings.xcworkspace").path)
            }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast) }
            .sorted { $0.modified < $1.modified }
    }

    /// Removes oracle entries whose mtime is older than `olderThanDays` (every entry when nil), then, with
    /// `maxBytes`, the least recently used ones until the rest fit. Returns how many went. The runs touch their
    /// entry's folder, so an entry in use is never old.
    @discardableResult
    public static func prune(home: URL, olderThanDays: Int?, maxBytes: Int64? = nil, now: Date = Date()) -> Int {
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
        var sizes = kept.map { ($0, size(of: $0)) }
        var total = sizes.reduce(0) { $0 + $1.1 }
        while total > maxBytes, sizes.count > 1, let (url, bytes) = sizes.first {
            sizes.removeFirst()
            if (try? fm.removeItem(at: url)) != nil {
                removed += 1
                total -= bytes
            }
        }
        return removed
    }

    /// The file that marks a folder as an oracle entry.
    static let marker = ".xcblame-oracle"

    /// Marks an entry as the oracle's and as used (its mtime drives pruning).
    static func touch(_ dir: URL) {
        let file = dir.appendingPathComponent(marker)
        if !FileManager.default.fileExists(atPath: file.path) { try? Data("xcblame settings oracle\n".utf8).write(to: file) }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
    }
}
