import Foundation

/// Text reader for `.xcconfig` files (docs/SCHEMA-v0.3.md `XCConfigFile`). Read-only.
///
/// Supported: `KEY = value`, `KEY[sdk=…][arch=…] = value`, `//` comments (Xcode ends a value at the first `//`, URLs
/// included), an optional trailing `;`, `#include "…"` and `#include? "…"` (relative to the including file, or
/// absolute). Not supported: line continuations (a trailing `\` is reported in `Parsed.hasContinuation`), include paths
/// that start with a build-setting reference (`$(SRCROOT)/…`) or use `<…>`: those are listed in
/// `Parsed.unresolvedIncludes` and nowhere else.
enum XCConfigReader {
    enum Event {
        case assign(key: String, condition: String?, value: String)
        /// An include target that was resolved to a path (existing or not).
        case include(URL, optional: Bool)
    }

    struct Parsed {
        var file: XCConfigFile
        /// Assignments and includes in file order (what `flatten` replays).
        var events: [Event]
        /// Include paths as written that could not be resolved to a file (`$(SRCROOT)/…`, `<…>`).
        var unresolvedIncludes: [String]
        var hasContinuation: Bool
    }

    static func parse(url: URL) throws -> Parsed {
        let url = url.standardizedFileURL
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw XcblameError.projectUnreadable("xcconfig \(url.path) is not readable: \(error.localizedDescription)")
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return parse(text: text, url: url)
    }

    static func parse(text: String, url: URL) -> Parsed {
        let dir = url.deletingLastPathComponent()
        var file = XCConfigFile(url: url)
        var events: [Event] = []
        var unresolved: [String] = []
        var continuation = false
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("//") { continue }
            if line.hasPrefix("#include") {
                guard let (path, optional) = includePath(line) else { continue }
                guard let target = resolveInclude(path, relativeTo: dir) else {
                    unresolved.append(path)
                    continue
                }
                events.append(.include(target, optional: optional))
                if !FileManager.default.fileExists(atPath: target.path) {
                    file.missingIncludes.append(target)
                } else if optional {
                    file.optionalIncludes.append(target)
                } else {
                    file.includes.append(target)
                }
                continue
            }
            var body = Substring(line)
            if let comment = body.range(of: "//") { body = body[..<comment.lowerBound] }
            // The assignment `=` is the first one outside the condition brackets (`KEY[sdk=…] = value`).
            var depth = 0
            guard let eq = body.indices.first(where: { index in
                switch body[index] {
                case "[": depth += 1
                case "]": depth -= 1
                case "=" where depth == 0: return true
                default: break
                }
                return false
            }) else { continue }
            let rawKey = body[..<eq].trimmingCharacters(in: .whitespaces)
            var value = body[body.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.hasSuffix(";") { value = String(value.dropLast()).trimmingCharacters(in: .whitespaces) }
            if value.hasSuffix("\\") { continuation = true }
            guard let (key, condition) = splitConditionalKey(rawKey) else { continue }
            events.append(.assign(key: key, condition: condition, value: value))
            assign(&file.settings, key: key, condition: condition, value: value)
        }
        return Parsed(file: file, events: events, unresolvedIncludes: unresolved, hasContinuation: continuation)
    }

    /// `KEY[sdk=iphonesimulator*][arch=arm64]` → (`KEY`, `sdk=iphonesimulator*][arch=arm64`); nil for a malformed key.
    static func splitConditionalKey(_ raw: String) -> (key: String, condition: String?)? {
        let raw = raw.trimmingCharacters(in: .whitespaces)
        guard let bracket = raw.firstIndex(of: "[") else {
            return isSettingName(raw) ? (raw, nil) : nil
        }
        let key = String(raw[..<bracket]).trimmingCharacters(in: .whitespaces)
        var rest = raw[bracket...].trimmingCharacters(in: .whitespaces)
        guard isSettingName(key), rest.hasPrefix("["), rest.hasSuffix("]") else { return nil }
        rest = String(rest.dropFirst().dropLast())
        let parts = rest.components(separatedBy: "]").map {
            $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "["))
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        return (key, parts.isEmpty ? nil : parts.joined(separator: "]["))
    }

    static func assign(_ settings: inout [String: SettingValue], key: String, condition: String?, value: String) {
        var current = settings[key] ?? SettingValue(raw: nil)
        if let condition {
            var conditions = current.conditions ?? [:]
            conditions[condition] = value
            current.conditions = conditions
        } else {
            current.raw = value
        }
        settings[key] = current
    }

    /// Every setting the file defines once its includes are replayed in place, depth first: an assignment after an
    /// include overrides it, an include after an assignment overrides that (Xcode: later definitions win). Include
    /// cycles and chains deeper than 32 stop silently.
    static func flatten(url: URL) -> [String: SettingValue] {
        var settings: [String: SettingValue] = [:]
        var stack: [URL] = []
        replay(url.standardizedFileURL, into: &settings, stack: &stack)
        return settings
    }

    private static func replay(_ url: URL, into settings: inout [String: SettingValue], stack: inout [URL]) {
        guard !stack.contains(url), stack.count < 32, let parsed = try? parse(url: url) else { return }
        stack.append(url)
        defer { stack.removeLast() }
        for event in parsed.events {
            switch event {
            case let .assign(key, condition, value):
                assign(&settings, key: key, condition: condition, value: value)
            case let .include(target, _):
                replay(target, into: &settings, stack: &stack)
            }
        }
    }

    private static func isSettingName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else { return false }
        return s.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) }
    }

    /// `#include "path"` / `#include? "path"` / `#include <path>` → (path, optional).
    private static func includePath(_ line: String) -> (String, Bool)? {
        var rest = line.dropFirst("#include".count)
        let optional = rest.hasPrefix("?")
        if optional { rest = rest.dropFirst() }
        rest = rest.drop(while: \.isWhitespace)
        if rest.hasPrefix("\""), let end = rest.dropFirst().firstIndex(of: "\"") {
            return (String(rest[rest.index(after: rest.startIndex)..<end]), optional)
        }
        if rest.hasPrefix("<"), let end = rest.firstIndex(of: ">") {
            return ("<" + rest[rest.index(after: rest.startIndex)..<end] + ">", optional)
        }
        return nil
    }

    private static func resolveInclude(_ path: String, relativeTo dir: URL) -> URL? {
        if path.isEmpty || path.hasPrefix("<") || path.contains("$(") || path.contains("${") { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return dir.appendingPathComponent(path).standardizedFileURL
    }
}

extension XCConfigFile {
    /// The value `key` ends up with in this file once its includes are replayed in place (depth first, later
    /// definitions winning, so an assignment after an `#include` beats the included file). Re-reads this file and its
    /// includes from disk; falls back to `settings[key]` when the file is no longer readable. References such as
    /// `$(inherited)` stay unexpanded. Nil when neither the file nor its includes set the key.
    public func resolved(key: String) -> SettingValue? {
        guard FileManager.default.isReadableFile(atPath: url.path) else { return settings[key] }
        return XCConfigReader.flatten(url: url)[key]
    }
}
