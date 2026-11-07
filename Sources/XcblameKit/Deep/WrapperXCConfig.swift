import Foundation

// v0.5 lane A (docs/SCHEMA-v0.5.md "Wrapper xcconfig"): command-line delivery of DESIGN §7.5, used by `--deep` now and
// by `--overlay` / `verify --mechanism cli` in v0.6.
public enum WrapperXCConfig {
    public struct Plan: Sendable, Equatable {
        /// `<xcblame-dir>/tmp/wrapper-<Config>.xcconfig` (`<Config>` = `-configuration`, else `Default`).
        public var url: URL
        /// The file: `#include` lines in §7.5 order (the user's `-xcconfig`, `XCODE_XCCONFIG_FILE`, the overlay), then
        /// the injected lines, each with a `// xcblame` comment.
        public var contents: String
        /// The xcodebuild arguments with the user's `-xcconfig <file>` removed and `-xcconfig <url>` added.
        public var arguments: [String]
        /// Variables to unset for the child (`XCODE_XCCONFIG_FILE` when it was included).
        public var unsetEnvironment: [String]

        public init(url: URL, contents: String, arguments: [String], unsetEnvironment: [String]) {
            self.url = url
            self.contents = contents
            self.arguments = arguments
            self.unsetEnvironment = unsetEnvironment
        }
    }

    /// Result of running the settings oracle without and with the wrapper (§5.8, §7.5).
    public struct OracleCheck: Sendable, Equatable {
        /// `<target>: <KEY>` whose effective value did not change: shadowed (command line did not win, MV-3).
        public var shadowed: [String]
        /// `<target>: <KEY> lost <flag>`: a pre-existing flag disappeared; `--deep` aborts when non-empty.
        public var lost: [String]

        public init(shadowed: [String], lost: [String]) {
            self.shadowed = shadowed
            self.lost = lost
        }
    }

    /// `<xcblameDir>/tmp/wrapper-<configuration>.xcconfig`.
    public static func url(xcblameDir: URL, configuration: String?) -> URL {
        xcblameDir.appendingPathComponent("tmp/wrapper-\(configuration ?? "Default").xcconfig")
    }

    /// The wrapper for `arguments` and `environment` (§7.5 order): `#include` of every `-xcconfig <file>` of the
    /// arguments (removed from them; relative paths resolved against `cwd`), of `$XCODE_XCCONFIG_FILE` (then unset
    /// for the child), of `overlay`, then `lines`, each ending with a `// xcblame` comment unless it has one.
    public static func plan(arguments: [String], environment: [String: String], overlay: URL?, lines: [String],
                            xcblameDir: URL) throws -> Plan {
        try plan(arguments: arguments, environment: environment, overlay: overlay, lines: lines, xcblameDir: xcblameDir,
                 cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    }

    static func plan(arguments: [String], environment: [String: String], overlay: URL?, lines: [String],
                     xcblameDir: URL, cwd: URL) throws -> Plan {
        var remaining: [String] = []
        var includes: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            if arguments[index] == "-xcconfig" {
                guard index + 1 < arguments.endIndex else {
                    throw XcblameError.usage("-xcconfig needs a file argument")
                }
                includes.append(absolute(arguments[index + 1], cwd: cwd))
                index += 2
                continue
            }
            remaining.append(arguments[index])
            index += 1
        }
        var unset: [String] = []
        if let file = environment["XCODE_XCCONFIG_FILE"], !file.isEmpty {
            includes.append(absolute(file, cwd: cwd))
            unset.append("XCODE_XCCONFIG_FILE")
        }
        if let overlay { includes.append(overlay.standardizedFileURL.path) }
        for include in includes { try requireExpressible(include, what: "the xcconfig to include") }
        let url = Self.url(xcblameDir: xcblameDir, configuration: XcodebuildRunner.value(of: "-configuration", in: arguments))
        var text = "// Written by xcblame for one command-line build (DESIGN §7.5); safe to delete.\n"
        for include in includes { text += "#include \"\(include)\"\n" }
        for line in lines { text += line.contains("//") ? line + "\n" : line + " // xcblame\n" }
        return Plan(url: url, contents: text, arguments: remaining + ["-xcconfig", url.path], unsetEnvironment: unset)
    }

    /// An xcconfig line cannot carry `"` inside a quoted path, and the parser expands `$(`…`)` in any value, so a
    /// path with either (or a line break) would include or point at another file: a usage error instead.
    static func requireExpressible(_ path: String, what: String) throws {
        guard path.contains("\"") || path.contains("$(") || path.contains("${") || path.contains(where: \.isNewline) else {
            return
        }
        throw XcblameError.usage("\(what) \(path) cannot be written into an xcconfig (it holds a quote, a $( or ${, or "
            + "a line break); rename or move it")
    }

    private static func absolute(_ path: String, cwd: URL) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : cwd.appendingPathComponent(expanded)
        return url.standardizedFileURL.path
    }

    /// The xcblame wrapper `arguments` already pass (`-xcconfig <xcblameDir>/tmp/wrapper-*.xcconfig`, e.g. the one
    /// `--deep` wrote), else nil (v0.5 integration).
    public static func existing(in arguments: [String], xcblameDir: URL) -> URL? {
        let tmp = xcblameDir.standardizedFileURL.appendingPathComponent("tmp").path + "/"
        for (index, argument) in arguments.enumerated() where argument == "-xcconfig" && index + 1 < arguments.count {
            let url = URL(fileURLWithPath: NSString(string: arguments[index + 1]).expandingTildeInPath).standardizedFileURL
            if url.path.hasPrefix(tmp), url.lastPathComponent.hasPrefix("wrapper-"), url.pathExtension == "xcconfig" {
                return url
            }
        }
        return nil
    }

    /// Appends each of `lines` the wrapper at `url` does not hold yet, with a `// xcblame` comment unless it has one.
    public static func append(_ lines: [String], to url: URL) throws {
        var text = try String(contentsOf: url, encoding: .utf8)
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        for line in lines {
            let written = line.contains("//") ? line : line + " // xcblame"
            let body = written.components(separatedBy: " //").first ?? written
            if text.split(separator: "\n").contains(where: { $0.hasPrefix(body) }) { continue }
            text += written + "\n"
        }
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Writes `plan.contents` to `plan.url` atomically (creating `tmp/`).
    public static func write(_ plan: Plan) throws {
        try FileManager.default.createDirectory(at: plan.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(plan.contents.utf8).write(to: plan.url, options: .atomic)
    }

    /// Compares effective settings without (`before`) and with (`after`) the wrapper for every `keys` entry of every
    /// target `after` lists. `injected` maps a key to the flags the wrapper adds (`OTHER_SWIFT_FLAGS` →
    /// `-Xfrontend -debug-time-function-bodies ...`): a target whose `after` value lacks one of them is shadowed; a
    /// flag of `before` missing from `after` is lost. Keys without an `injected` entry are only checked for losses.
    public static func check(keys: [String], before: EffectiveSettings, after: EffectiveSettings,
                             injected: [String: String]) throws -> OracleCheck {
        var shadowed: [String] = []
        var lost: [String] = []
        for target in after.targets.keys.sorted() {
            let afterValues = after.targets[target] ?? [:]
            let beforeValues = before.targets[target] ?? [:]
            for key in keys {
                let afterTokens = tokens(afterValues[key] ?? "")
                if let flags = injected[key], !tokens(flags).isEmpty,
                   !contains(afterTokens, sequence: tokens(flags)) {
                    shadowed.append("\(target): \(key)")
                }
                guard before.targets[target] != nil else { continue }
                var remaining = afterTokens
                for token in tokens(beforeValues[key] ?? "") {
                    if let at = remaining.firstIndex(of: token) {
                        remaining.remove(at: at)
                    } else {
                        lost.append("\(target): \(key) lost \(token)")
                    }
                }
            }
        }
        return OracleCheck(shadowed: shadowed, lost: lost)
    }

    /// Whitespace-separated words; `"..."` quotes are kept together and dropped.
    static func tokens(_ value: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quoted = false
        var has = false
        for character in value {
            if character == "\"" {
                quoted.toggle()
                has = true
            } else if character.isWhitespace, !quoted {
                if has { out.append(current) }
                current = ""
                has = false
            } else {
                current.append(character)
                has = true
            }
        }
        if has { out.append(current) }
        return out
    }

    private static func contains(_ tokens: [String], sequence: [String]) -> Bool {
        guard sequence.count <= tokens.count else { return false }
        for start in 0...(tokens.count - sequence.count) where Array(tokens[start..<start + sequence.count]) == sequence {
            return true
        }
        return false
    }
}
