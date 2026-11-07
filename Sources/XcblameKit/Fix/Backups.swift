import CryptoKit
import Foundation

// v0.6 lane A (docs/SCHEMA-v0.6.md "Storage"): `<xcblame-dir>/backup/` holds the exact bytes of every xcconfig before
// the hook was appended (`<sha16>.orig`, indexed in `hooks.json`) and the prior Xcode defaults values
// (`defaults.json`). Git-ignored (`StateFiles`); a revert reads them back.
public enum Backups {
    /// One `hooks.json` row.
    public struct Hook: Codable, Sendable, Equatable {
        /// The hooked xcconfig (the file written, symlinks resolved), relative to the project root (the folder holding
        /// the container).
        public var path: String
        /// The symlink the project names when the base xcconfig is one (`path` is its target); nil for a plain file.
        public var link: String?
        public var configuration: String
        /// SHA-256 (hex) of the file before and after the hook was appended.
        public var originalSHA256: String
        public var hookedSHA256: String
        /// The backup file, relative to the xcblame dir (`backup/<sha16>.orig`).
        public var backup: String

        public init(path: String, link: String? = nil, configuration: String, originalSHA256: String, hookedSHA256: String,
                    backup: String) {
            self.path = path
            self.link = link
            self.configuration = configuration
            self.originalSHA256 = originalSHA256
            self.hookedSHA256 = hookedSHA256
            self.backup = backup
        }
    }

    /// A defaults key's state before `fix --apply-defaults` wrote it.
    public struct Prior: Codable, Sendable, Equatable {
        public var exists: Bool
        /// `bool` / `int` / `float` / `string`; nil when the key did not exist.
        @Null public var type: String?
        @Null public var value: String?

        public init(exists: Bool, type: String?, value: String?) {
            self.exists = exists
            self.type = type
            self.value = value
        }

        public static let absent = Prior(exists: false, type: nil, value: nil)
    }

    /// One `defaults.json` row.
    public struct Defaults: Codable, Sendable, Equatable {
        public var planId: String
        public var domain: String
        public var key: String
        public var prior: Prior

        public init(planId: String, domain: String, key: String, prior: Prior) {
            self.planId = planId
            self.domain = domain
            self.key = key
            self.prior = prior
        }
    }

    public static func directory(xcblameDir: URL) -> URL { xcblameDir.appendingPathComponent("backup") }
    static func hooksURL(xcblameDir: URL) -> URL { directory(xcblameDir: xcblameDir).appendingPathComponent("hooks.json") }
    static func defaultsURL(xcblameDir: URL) -> URL { directory(xcblameDir: xcblameDir).appendingPathComponent("defaults.json") }

    public static func hooks(xcblameDir: URL) -> [Hook] { read(hooksURL(xcblameDir: xcblameDir)) }
    public static func saveHooks(_ rows: [Hook], xcblameDir: URL) throws { try write(rows, to: hooksURL(xcblameDir: xcblameDir)) }
    public static func defaults(xcblameDir: URL) -> [Defaults] { read(defaultsURL(xcblameDir: xcblameDir)) }
    public static func saveDefaults(_ rows: [Defaults], xcblameDir: URL) throws {
        try write(rows, to: defaultsURL(xcblameDir: xcblameDir))
    }

    /// Writes `data` to `backup/<sha16>.orig` (the first 16 hex of its SHA-256); returns the path relative to the
    /// xcblame dir.
    public static func storeBytes(_ data: Data, xcblameDir: URL) throws -> String {
        let relative = "backup/" + String(sha256(data).prefix(16)) + ".orig"
        let url = xcblameDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        ensureStateIgnore(in: xcblameDir)
        try data.write(to: url, options: .atomic)
        return relative
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func read<T: Decodable>(_ url: URL) -> [T] {
        guard let data = FileManager.default.contents(atPath: url.path) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    private static func write<T: Encodable>(_ rows: [T], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(rows) + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}

/// Path helpers of the fix lane.
enum FixPaths {
    /// `to` relative to the folder `from` (both absolute, symlinks resolved), e.g. `../.xcblame/overlay-Debug.xcconfig`.
    static func relative(to target: URL, fromDirectory base: URL) -> String {
        let targetParts = canonical(target).pathComponents
        let baseParts = canonical(base).pathComponents
        var common = 0
        while common < min(targetParts.count, baseParts.count), targetParts[common] == baseParts[common] { common += 1 }
        let ups = Array(repeating: "..", count: baseParts.count - common)
        return (ups + targetParts[common...]).joined(separator: "/")
    }

    /// The path with symlinks resolved, keeping a `/private` prefix out of the comparison (Foundation drops it for
    /// `/var` and `/tmp` but not always for the parent of a missing file).
    static func canonical(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for part in missing { resolved.appendPathComponent(part) }
        var path = resolved.path
        if path.hasPrefix("/private/") { path = String(path.dropFirst("/private".count)) }
        return URL(fileURLWithPath: path)
    }

    /// `url` relative to `root` when inside it, else the absolute path.
    static func display(_ url: URL, root: URL) -> String {
        let path = canonical(url).path
        let base = canonical(root).path + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.standardizedFileURL.path
    }

    /// `display` of a path whose last component is kept as named (a symlink is not followed).
    static func displayLink(_ url: URL, root: URL) -> String {
        let folder = canonical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent).path
        let base = canonical(root).path + "/"
        return folder.hasPrefix(base) ? String(folder.dropFirst(base.count)) : url.standardizedFileURL.path
    }

    /// True when `url` itself (not its folder) is a symbolic link (`lstat`).
    static func isSymlink(_ url: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}
