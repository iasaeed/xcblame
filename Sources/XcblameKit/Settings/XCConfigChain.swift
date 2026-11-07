import Foundation

// ponytail: kept apart from Project/XCConfigReader (integration v0.3): provenance needs every assignment in order with
// the file that holds it, which the reader's `flatten` merges away; unifying is more than a small change. upgrade:
// let XCConfigReader.parse expose its ordered lines and build this chain from them.

/// One `KEY[cond] = value` line of an xcconfig, in evaluation order (includes flattened at their position).
struct XCConfigAssignment: Equatable {
    var key: String
    /// Condition text without the outer brackets (`sdk=iphonesimulator*`, several joined by `][`); nil when none.
    var condition: String?
    var value: String
    /// The file holding the line (the include chain's leaf).
    var file: URL
}

/// An xcconfig with its `#include` chain flattened: what the provenance resolver needs, nothing more.
struct XCConfigChain: Equatable {
    var assignments: [XCConfigAssignment] = []
    /// Every file read, the root first.
    var files: [URL] = []
    /// Include targets that do not exist, with whether the include was optional (`#include?`).
    var missing: [(url: URL, optional: Bool)] = []

    static func == (lhs: XCConfigChain, rhs: XCConfigChain) -> Bool {
        lhs.assignments == rhs.assignments && lhs.files == rhs.files
            && lhs.missing.map(\.url) == rhs.missing.map(\.url) && lhs.missing.map(\.optional) == rhs.missing.map(\.optional)
    }

    /// Reads `url` and its includes (relative to the including file; depth-limited, cycles skipped). A missing root
    /// is recorded in `missing` like a missing `#include`.
    static func load(_ url: URL) -> XCConfigChain {
        var chain = XCConfigChain()
        var visiting: Set<String> = []
        chain.read(url.standardizedFileURL, optional: false, depth: 0, visiting: &visiting)
        return chain
    }

    private mutating func read(_ url: URL, optional: Bool, depth: Int, visiting: inout Set<String>) {
        guard depth < 32, !visiting.contains(url.path) else { return }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            missing.append((url, optional))
            return
        }
        visiting.insert(url.path)
        defer { visiting.remove(url.path) }
        files.append(url)
        let dir = url.deletingLastPathComponent()
        for rawLine in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
            var line = Self.stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#include") {
                let isOptional = line.hasPrefix("#include?")
                guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close else { continue }
                let path = String(line[line.index(after: open)..<close])
                let target = path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
                read(target.standardizedFileURL, optional: isOptional, depth: depth + 1, visiting: &visiting)
                continue
            }
            // The first `=` outside `[cond=…]`.
            var depth = 0
            guard let eq = line.firstIndex(where: { c in
                if c == "[" { depth += 1 } else if c == "]" { depth -= 1 }
                return c == "=" && depth == 0
            }) else { continue }
            var lhs = line[..<eq].trimmingCharacters(in: .whitespaces)
            line = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if line.hasSuffix(";") { line = String(line.dropLast()).trimmingCharacters(in: .whitespaces) }
            var condition: String?
            if let bracket = lhs.firstIndex(of: "["), lhs.hasSuffix("]") {
                condition = String(lhs[lhs.index(after: bracket)..<lhs.index(before: lhs.endIndex)])
                lhs = String(lhs[..<bracket]).trimmingCharacters(in: .whitespaces)
            }
            guard Self.isIdentifier(lhs) else { continue }
            assignments.append(XCConfigAssignment(key: lhs, condition: condition, value: line, file: url))
        }
    }

    /// Drops a `//` comment (xcconfig has no string quoting, so `//` always starts one).
    static func stripComment(_ line: String) -> String {
        guard let range = line.range(of: "//") else { return line }
        return String(line[..<range.lowerBound])
    }

    static func isIdentifier<S: StringProtocol>(_ text: S) -> Bool {
        guard let first = text.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else { return false }
        return text.unicodeScalars.allSatisfy { $0 == "_" || CharacterSet.alphanumerics.contains($0) }
    }
}
