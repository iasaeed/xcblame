import Foundation

/// Which Xcode produced a log, derived from the log alone (DESIGN §5.9). Never reads the current `xcode-select`.
public struct InferredXcode: Codable, Sendable, Equatable {
    /// Xcode version, e.g. `26.0`.
    public var value: String
    public var source: String
    /// Human-readable findings, strongest first.
    public var evidence: [String]
}

public enum XcodeVersionInference {
    /// Evidence tiers, strongest first; the first tier with a version decides `value`.
    ///  1. SDK names in task commands and the SDK build in the stat-cache file name
    ///  2. the developer dir when it is not the default `Xcode.app` and its name carries a version
    ///  3. swift-frontend / clang version strings in emitted output (evidence only, they map to a range)
    ///  4. the SLF log format version (weakest: a lower bound; it overrides a lower value from 1-3)
    public static func infer(from model: BuildModel) -> InferredXcode? {
        var sdkVersions: [(xcode: String, evidence: String)] = []
        var sdkBuilds: [String] = []
        var developerDirs: [(version: String?, evidence: String)] = []
        var compilers: [String] = []
        var seen: Set<String> = []

        for task in model.tasks {
            if let text = task.commandDetails {
                for sdk in sdkNames(in: text) where seen.insert("sdk|" + sdk.name).inserted {
                    if let xcode = xcodeVersion(platform: sdk.platform, sdkVersion: sdk.version) {
                        sdkVersions.append((xcode, "SDK \(sdk.name).sdk in a task command -> Xcode \(xcode)"))
                    }
                }
                for cache in statCacheNames(in: text) where seen.insert("cache|" + cache.file).inserted {
                    if let xcode = xcodeVersion(platform: cache.platform, sdkVersion: cache.version) {
                        sdkVersions.append((xcode, "stat cache \(cache.file) -> Xcode \(xcode)"))
                    }
                    if let build = cache.build { sdkBuilds.append("SDK build \(build) (stat cache \(cache.platform)\(cache.version))") }
                }
                for app in nonDefaultXcodeApps(in: text) where seen.insert("dev|" + app).inserted {
                    developerDirs.append((versionInName(app), "developer dir \(app) is not the default Xcode.app"))
                }
            }
            if compilers.count < 2, let output = task.emittedOutput, !output.isEmpty {
                for line in compilerVersionLines(in: output) where seen.insert("cc|" + line).inserted {
                    compilers.append("compiler: \(line)")
                }
            }
        }

        var evidence = sdkVersions.map(\.evidence) + sdkBuilds + developerDirs.map(\.evidence) + compilers
        var value: String?
        if let best = sdkVersions.map(\.xcode).max(by: { compareVersions($0, $1) < 0 }) {
            value = best
        } else if let named = developerDirs.compactMap(\.version).max(by: { compareVersions($0, $1) < 0 }) {
            value = named
        }
        // The format version is a proven lower bound, so it also lifts a weaker SDK-derived value: a platform SDK
        // does not move with every Xcode minor (Xcode 27.1 beta still ships MacOSX27.0.sdk, but writes format 13).
        if let (version, lowerBound) = formatVersionBound(model.formatVersion),
           value.map({ compareVersions(lowerBound, $0) > 0 }) ?? true {
            value = lowerBound
            evidence.insert("log format version \(version) (written by Xcode >= \(lowerBound))", at: 0)
        }
        guard let value else { return nil }
        return InferredXcode(value: value, source: "inferred", evidence: evidence)
    }

    // MARK: - Version tables

    /// SLF format version -> oldest Xcode that writes it (weakest evidence).
    static func formatVersionBound(_ version: Int?) -> (Int, String)? {
        guard let version else { return nil }
        if version >= 13 { return (version, "27.1") }
        if version >= 11 { return (version, "26.0") }
        return nil
    }

    /// Platform SDK version -> Xcode version. Since Xcode 26 every platform SDK shares the Xcode major (26.0 ships
    /// `MacOSX26.0.sdk`, `iPhoneOS26.0.sdk`, ...). Before that only macOS and iOS SDKs map, via a small table;
    /// anything else is not evidence.
    static func xcodeVersion(platform: String, sdkVersion: String) -> String? {
        let parts = sdkVersion.split(separator: ".")
        guard let major = parts.first.flatMap({ Int($0) }) else { return nil }
        let tail = parts.dropFirst().joined(separator: ".")
        if major >= 26 { return sdkVersion }
        let table: [String: [Int: Int]] = [
            "macosx": [13: 14, 14: 15, 15: 16],
            "iphoneos": [16: 14, 17: 15, 18: 16],
            "iphonesimulator": [16: 14, 17: 15, 18: 16],
        ]
        guard let xcodeMajor = table[platform.lowercased()]?[major] else { return nil }
        return "\(xcodeMajor).\(tail.isEmpty ? "0" : tail)"
    }

    static func compareVersions(_ a: String, _ b: String) -> Int {
        let (x, y) = (a.split(separator: ".").map { Int($0) ?? 0 }, b.split(separator: ".").map { Int($0) ?? 0 })
        for i in 0..<max(x.count, y.count) {
            let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }

    // MARK: - Scanners (linear, no regex)

    private static let sdkPlatforms: Set<String> = [
        "macosx", "iphoneos", "iphonesimulator", "watchos", "watchsimulator", "appletvos", "appletvsimulator",
        "xros", "xrsimulator",
    ]

    /// `MacOSX26.0.sdk` -> (name `MacOSX26.0`, platform `macosx`, version `26.0`).
    static func sdkNames(in text: String) -> [(name: String, platform: String, version: String)] {
        var result: [(String, String, String)] = []
        var search = text.startIndex..<text.endIndex
        while let hit = text.range(of: ".sdk", options: .literal, range: search) {
            search = hit.upperBound..<text.endIndex
            if let next = text[hit.upperBound...].first, next.isLetter || next.isNumber { continue }
            let token = text[..<hit.lowerBound].reversed().prefix { $0.isLetter || $0.isNumber || $0 == "." }
            guard let (platform, version) = splitPlatformVersion(String(token.reversed())) else { continue }
            result.append((platform + version, platform.lowercased(), version))
        }
        return result.map { (name: $0.0, platform: $0.1, version: $0.2) }
    }

    /// `...macosx26.0-25A352-<hash>.sdkstatcache` -> platform, version, SDK build.
    static func statCacheNames(in text: String) -> [(file: String, platform: String, version: String, build: String?)] {
        var result: [(String, String, String, String?)] = []
        var search = text.startIndex..<text.endIndex
        while let hit = text.range(of: ".sdkstatcache", options: .literal, range: search) {
            search = hit.upperBound..<text.endIndex
            let file = String(text[..<hit.lowerBound].reversed().prefix { $0 != "/" && !$0.isWhitespace }.reversed())
            let fields = file.split(separator: "-")
            guard let first = fields.first, let (platform, version) = splitPlatformVersion(String(first)) else { continue }
            let build = fields.count > 1 && isSDKBuild(fields[1]) ? String(fields[1]) : nil
            result.append((file, platform.lowercased(), version, build))
        }
        return result.map { (file: $0.0, platform: $0.1, version: $0.2, build: $0.3) }
    }

    /// `/Applications/Xcode-26.1.app/Contents/Developer` -> `/Applications/Xcode-26.1.app`, unless it is `Xcode.app`.
    static func nonDefaultXcodeApps(in text: String) -> [String] {
        var result: [String] = []
        var search = text.startIndex..<text.endIndex
        while let hit = text.range(of: ".app/Contents/Developer", options: .literal, range: search) {
            search = hit.upperBound..<text.endIndex
            let prefix = text[..<hit.lowerBound].reversed().prefix { !$0.isWhitespace && $0 != "'" && $0 != "\"" && $0 != "=" }
            // Drop a flag glued to the path (`-L/Applications/Xcode.app/...`).
            let full = String(prefix.reversed()) + ".app"
            let app = full.firstIndex(of: "/").map { String(full[$0...]) } ?? full
            if app != "/Applications/Xcode.app" { result.append(app) }
        }
        return result
    }

    /// `Xcode-26.1.app`, `Xcode_26.1.app`, `Xcode 26.1.app` -> `26.1`; `Xcode-beta.app` -> nil.
    static func versionInName(_ appPath: String) -> String? {
        guard let name = appPath.split(separator: "/").last else { return nil }
        let base = name.hasSuffix(".app") ? name.dropLast(4) : name
        var text = String(base.drop { !$0.isNumber }.prefix { $0.isNumber || $0 == "." })
        while text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? nil : text
    }

    /// Lines such as `Apple Swift version 6.2 (swiftlang-6.2.0.19.9 clang-1700.3.19.1)` and `Apple clang version ...`.
    static func compilerVersionLines(in text: String) -> [String] {
        var result: [String] = []
        for marker in ["Apple Swift version ", "Apple clang version "] {
            guard let hit = text.range(of: marker, options: .literal) else { continue }
            let line = text[hit.lowerBound...].prefix { !$0.isNewline }
            result.append(String(line.prefix(120)))
        }
        return result
    }

    // MARK: - Helpers

    /// `MacOSX26.0` / `macosx26.0` -> (`MacOSX`, `26.0`) when the letters are a known platform.
    private static func splitPlatformVersion(_ token: String) -> (String, String)? {
        let platform = token.prefix { $0.isLetter }
        let version = token.dropFirst(platform.count)
        guard sdkPlatforms.contains(platform.lowercased()), let first = version.first, first.isNumber,
              version.allSatisfy({ $0.isNumber || $0 == "." }), !version.hasSuffix(".") else { return nil }
        return (String(platform), String(version))
    }

    /// Apple build numbers: digits, one uppercase letter, digits and an optional trailing lowercase letter (25A352).
    private static func isSDKBuild(_ field: Substring) -> Bool {
        let chars = Array(field)
        guard chars.count >= 4, chars[0].isNumber, let letter = chars.firstIndex(where: { $0.isLetter }),
              chars[letter].isUppercase, letter >= 1 else { return false }
        return chars[(letter + 1)...].contains { $0.isNumber }
    }
}
