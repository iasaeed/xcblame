import Foundation

// v0.5 lane A (docs/SCHEMA-v0.5.md "Deep"): which §5.8 flags this toolchain accepts ([TM] BTA#61).
public enum ToolchainProbe {
    public struct Result: Sendable, Equatable, Codable {
        /// `xcrun swift-frontend -help` output (hidden frontend flags need `-help-hidden`); nil when the probe failed.
        public var swiftFrontendHelp: String?
        /// `xcrun clang --help` output; nil when the probe failed.
        public var clangHelp: String?
        public var notes: [String]

        public init(swiftFrontendHelp: String?, clangHelp: String?, notes: [String] = []) {
            self.swiftFrontendHelp = swiftFrontendHelp
            self.clangHelp = clangHelp
            self.notes = notes
        }
    }

    /// Frontend flags `--deep` may pass; all of them are hidden (`-help-hidden` only) on Swift 6.2.
    static let swiftFlags = ["-debug-time-function-bodies", "-debug-time-expression-type-checking", "-stats-output-dir",
                             "-warn-long-function-bodies", "-warn-long-expression-type-checking"]

    /// The real probe: 10 s per tool.
    public static let defaultProbe: EnvSnapshot.Probe = { runProbe($0, timeout: 10) }

    /// Runs both probes through `probe` (argv in, stdout out; `EnvSnapshot.Probe`, injectable), 10 s each. Never runs
    /// xcodebuild. `-help-hidden` runs only when `-help` lacks one of the `--deep` frontend flags; the result then holds
    /// both texts.
    public static func run(probe: @escaping EnvSnapshot.Probe) throws -> Result {
        var notes: [String] = []
        var swift = probe(["xcrun", "swift-frontend", "-help"])
        if swiftFlags.contains(where: { flag in swift.map { !mentions(flag, in: $0) } ?? true }) {
            if let hidden = probe(["xcrun", "swift-frontend", "-help-hidden"]) {
                swift = [swift, hidden].compactMap { $0 }.joined(separator: "\n")
            }
        }
        if swift == nil { notes.append("toolchain probe: `xcrun swift-frontend -help` failed") }
        let clang = probe(["xcrun", "clang", "--help"])
        if clang == nil { notes.append("toolchain probe: `xcrun clang --help` failed") }
        return Result(swiftFrontendHelp: swift, clangHelp: clang, notes: notes)
    }

    /// `run` cached per toolchain in `cacheDir/toolchain-<sha16>.json`, keyed by `xcodebuild -version` and
    /// `DEVELOPER_DIR`. A probe that failed is never cached; an unreadable cache file is probed again.
    public static func run(probe: @escaping EnvSnapshot.Probe, cacheDir: URL,
                           environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Result {
        guard let version = probe(["xcodebuild", "-version"]) else { return try run(probe: probe) }
        let key = SettingsCache.sha256(version + "\n" + (environment["DEVELOPER_DIR"] ?? "")).prefix(16)
        let file = cacheDir.appendingPathComponent("toolchain-\(key).json")
        if let data = try? Data(contentsOf: file), var cached = try? JSONDecoder().decode(Result.self, from: data) {
            cached.notes.append("toolchain probe: cached for \(version.split(separator: "\n").joined(separator: " "))")
            return cached
        }
        let result = try run(probe: probe)
        if result.swiftFrontendHelp != nil, result.clangHelp != nil, let data = try? JSONEncoder().encode(result) {
            try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            try? data.write(to: file, options: .atomic)
        }
        return result
    }

    /// True when `flag` (`-debug-time-function-bodies`, `-ftime-trace`, `-ftime-trace-granularity=500`) appears in the
    /// matching help text as a whole option name (`-ftime-trace` does not match `-ftime-trace-granularity`). The part
    /// after `=` is ignored. False when that probe failed.
    public static func supports(_ flag: String, scope: DeepScope, in result: Result) throws -> Bool {
        let text = scope == .swift ? result.swiftFrontendHelp : result.clangHelp
        guard let text else { return false }
        return mentions(flag, in: text)
    }

    /// Whole-option match: the name is preceded by start, whitespace or `,` and followed by end, whitespace, `=`,
    /// `<` or `,`.
    static func mentions(_ flag: String, in text: String) -> Bool {
        let name = flag.split(separator: "=", maxSplits: 1).first.map(String.init) ?? flag
        guard !name.isEmpty else { return false }
        var search = text.startIndex..<text.endIndex
        while let range = text.range(of: name, range: search) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            let startOK = before.map { $0.isWhitespace || $0 == "," } ?? true
            let endOK = after.map { $0.isWhitespace || $0 == "=" || $0 == "<" || $0 == "," } ?? true
            if startOK, endOK { return true }
            search = range.upperBound..<text.endIndex
        }
        return false
    }
}
