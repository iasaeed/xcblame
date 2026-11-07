import Foundation

// Dependency-manager manifests read as text: Package.swift, Podfile, Podfile.lock, Cartfile. Read-only, never runs a
// tool (`swift package dump-package` may write `.build/`, `pod` may touch the network).

/// What the rules need from a Podfile beyond `ProjectModel.DependencyManager` (RULES.md SET-006/SET-010, DEP-004/005).
struct PodfileFacts: Sendable, Equatable {
    /// `pod 'Name'` names in file order.
    var pods: [String]
    var useFrameworks: Bool
    /// Body of the `post_install do |installer| … end` block, without its first and last lines; nil when absent.
    var postInstall: String?
    /// `build_settings['KEY'] = value` assignments inside `post_install` (key as written, conditions included; value
    /// without surrounding quotes), later assignments winning.
    var postInstallSettings: [String: String]
}

struct CartfileFacts: Sendable, Equatable {
    /// Non-comment lines (`github "ReactiveX/RxSwift" ~> 6.6`) in file order.
    var entries: [String]
}

enum ManifestReaders {
    // MARK: - Package.swift

    struct ParsedPackage {
        var manifest: ProjectModel.PackageManifest
        /// `products: [...]` names (to match `XCSwiftPackageProductDependency` entries without a `package` key).
        var products: [String]
        var notes: [String]
    }

    /// Parses `Package.swift` text. ponytail: a heuristic over the literal `Package(...)` call (balanced brackets and
    /// strings, comments stripped); targets or dependencies built in variables or appended later are not seen and
    /// produce a note.
    static func package(manifest url: URL) throws -> ParsedPackage {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            throw XcblameError.projectUnreadable("\(url.path) is not readable: \(error.localizedDescription)")
        }
        return package(text: String(decoding: data, as: UTF8.self), manifest: url)
    }

    static func package(text: String, manifest url: URL) -> ParsedPackage {
        let dir = url.deletingLastPathComponent()
        var notes: [String] = []
        let source = SwiftText(stripComments: text)
        guard let packageArgs = source.callArguments(named: "Package") else {
            return ParsedPackage(manifest: .init(name: nil), products: [],
                                 notes: ["\(url.path): no literal Package(...) call; manifest not parsed"])
        }
        let args = SwiftText.labeled(packageArgs)
        let name = args.first { $0.label == "name" }.flatMap { SwiftText.string($0.value) }
        let products = (args.first { $0.label == "products" }.flatMap { SwiftText.array($0.value) } ?? [])
            .compactMap { SwiftText.call($0).flatMap { SwiftText.stringArgument("name", in: $0.args) } }

        var dependencies: [ProjectModel.PackageReference] = []
        var identities: [String] = []
        for element in args.first(where: { $0.label == "dependencies" }).flatMap({ SwiftText.array($0.value) }) ?? [] {
            guard let call = SwiftText.call(element), call.name == "package" else {
                notes.append("\(url.lastPathComponent): dependency not understood: \(element.prefix(80))")
                continue
            }
            guard let (reference, identity) = packageDependency(call.args, dir: dir) else {
                notes.append("\(url.lastPathComponent): dependency requirement not understood: \(element.prefix(80))")
                continue
            }
            dependencies.append(reference)
            identities.append(identity)
        }

        var targets: [ProjectModel.PackageManifest.PackageTarget] = []
        let kinds = ["target": "regular", "executableTarget": "executable", "testTarget": "test", "macro": "macro",
                     "plugin": "plugin", "binaryTarget": "binary", "systemLibrary": "system"]
        let targetElements = args.first { $0.label == "targets" }.flatMap { SwiftText.array($0.value) }
        if targetElements == nil { notes.append("\(url.lastPathComponent): no literal targets: [...] array") }
        for element in targetElements ?? [] {
            guard let call = SwiftText.call(element), let type = kinds[call.name],
                  let targetName = SwiftText.stringArgument("name", in: call.args) else {
                notes.append("\(url.lastPathComponent): target not understood: \(element.prefix(80))")
                continue
            }
            var target = ProjectModel.PackageManifest.PackageTarget(name: targetName, type: type)
            for dep in call.args.first(where: { $0.label == "dependencies" }).flatMap({ SwiftText.array($0.value) }) ?? [] {
                if let literal = SwiftText.string(dep) {
                    target.dependencies.append(literal)
                } else if let depCall = SwiftText.call(dep), let depName = SwiftText.stringArgument("name", in: depCall.args) {
                    target.dependencies.append(depName)
                    if depCall.name == "product" {
                        let package = SwiftText.stringArgument("package", in: depCall.args)?.lowercased()
                        if let index = identities.firstIndex(where: { $0 == package }) {
                            addUnique(depName, to: &dependencies[index].products)
                            addUnique(targetName, to: &dependencies[index].consumers)
                        }
                    }
                }
            }
            for plugin in call.args.first(where: { $0.label == "plugins" }).flatMap({ SwiftText.array($0.value) }) ?? [] {
                if let literal = SwiftText.string(plugin) {
                    target.plugins.append(literal)
                } else if let pluginCall = SwiftText.call(plugin),
                          let pluginName = SwiftText.stringArgument("name", in: pluginCall.args) {
                    target.plugins.append(pluginName)
                }
            }
            targets.append(target)
        }
        return ParsedPackage(manifest: .init(name: name, dependencies: dependencies, targets: targets),
                             products: products, notes: notes)
    }

    /// `.package(url:…, from:/exact:/branch:/revision:/.upToNextMajor(from:)/"a"..<"b")` or `.package(path:)`;
    /// returns the reference and its identity (lowercased last URL or path component, or `name:`).
    private static func packageDependency(_ args: [SwiftText.Argument], dir: URL)
        -> (ProjectModel.PackageReference, String)? {
        if let path = SwiftText.stringArgument("path", in: args) {
            let url = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)).standardizedFileURL
            let identity = (SwiftText.stringArgument("name", in: args) ?? url.lastPathComponent).lowercased()
            return (ProjectModel.PackageReference(url: nil, path: url, requirement: .local), identity)
        }
        guard let location = SwiftText.stringArgument("url", in: args) ?? SwiftText.stringArgument("id", in: args)
        else { return nil }
        var identity = String(location.split(separator: "/").last ?? Substring(location)).lowercased()
        if identity.hasSuffix(".git") { identity.removeLast(4) }
        if let name = SwiftText.stringArgument("name", in: args) { identity = name.lowercased() }
        var requirement: ProjectModel.PackageReference.Requirement?
        for arg in args {
            switch arg.label {
            case "from": requirement = SwiftText.string(arg.value).map { .upToNextMajor($0) }
            case "exact": requirement = SwiftText.string(arg.value).map { .exact($0) }
            case "branch": requirement = SwiftText.string(arg.value).map { .branch($0) }
            case "revision": requirement = SwiftText.string(arg.value).map { .revision($0) }
            case nil: requirement = unlabeledRequirement(arg.value) ?? requirement
            default: continue
            }
        }
        guard let requirement else { return nil }
        return (ProjectModel.PackageReference(url: location, path: nil, requirement: requirement), identity)
    }

    private static func unlabeledRequirement(_ value: String) -> ProjectModel.PackageReference.Requirement? {
        if let call = SwiftText.call(value) {
            let first = call.args.first.flatMap { SwiftText.string($0.value) }
            switch call.name {
            case "upToNextMajor": return first.map { .upToNextMajor($0) }
            case "upToNextMinor": return first.map { .upToNextMinor($0) }
            case "exact": return first.map { .exact($0) }
            case "branch": return first.map { .branch($0) }
            case "revision": return first.map { .revision($0) }
            default: return nil
            }
        }
        for op in ["..<", "..."] {
            if let range = value.range(of: op),
               let lower = SwiftText.string(String(value[..<range.lowerBound])),
               let upper = SwiftText.string(String(value[range.upperBound...])) {
                return .range(from: lower, to: upper)
            }
        }
        return nil
    }

    private static func addUnique(_ value: String, to list: inout [String]) {
        if !list.contains(value) { list.append(value) }
    }

    // MARK: - CocoaPods

    static func podfile(_ url: URL) -> PodfileFacts? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var facts = PodfileFacts(pods: [], useFrameworks: false, postInstall: nil, postInstallSettings: [:])
        let lines = text.components(separatedBy: .newlines)
        let pod = try? NSRegularExpression(pattern: #"^\s*pod\s+['"]([^'"]+)['"]"#)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let code = rubyCode(line)
            if let name = pod.flatMap({ firstGroup($0, in: code) }) { facts.pods.append(name) }
            if code.hasPrefix("use_frameworks!") { facts.useFrameworks = true }
            if facts.postInstall == nil, code.hasPrefix("post_install"), code.range(of: #"\bdo\b"#, options: .regularExpression) != nil {
                var depth = 1
                var body: [String] = []
                index += 1
                while index < lines.count {
                    let inner = rubyCode(lines[index])
                    depth += rubyOpens(inner) - rubyCloses(inner)
                    if depth <= 0 { break }
                    body.append(lines[index])
                    index += 1
                }
                facts.postInstall = body.joined(separator: "\n")
            }
            index += 1
        }
        if let body = facts.postInstall,
           let assignment = try? NSRegularExpression(
               pattern: #"build_settings\[\s*['"]([^'"]+)['"]\s*\]\s*=\s*(?:'([^']*)'|"([^"]*)"|([^\s}]+))"#) {
            let ns = body as NSString
            for match in assignment.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
                guard let group = (2...4).first(where: { match.range(at: $0).location != NSNotFound }) else { continue }
                facts.postInstallSettings[ns.substring(with: match.range(at: 1))] = ns.substring(with: match.range(at: group))
            }
        }
        return facts
    }

    /// Distinct root pods of the `PODS:` section (`Firebase/Core` and `Firebase/Analytics` are one pod); nil when the
    /// file is unreadable or has no such section.
    static func podCount(lockfile url: URL) -> Int? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var inPods = false
        var roots: Set<String> = []
        var sawSection = false
        for line in text.components(separatedBy: .newlines) {
            if line == "PODS:" { inPods = true; sawSection = true; continue }
            guard inPods else { continue }
            if !line.isEmpty, !line.hasPrefix(" ") { break }
            guard line.hasPrefix("  - ") else { continue }
            let entry = line.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let name = entry.prefix { $0 != " " && $0 != ":" }
            roots.insert(String(name.prefix { $0 != "/" }))
        }
        return sawSection ? roots.count : nil
    }

    static func cartfile(_ url: URL) -> CartfileFacts? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let entries = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        return CartfileFacts(entries: entries)
    }

    /// The line without a trailing `# comment` (outside quotes) and surrounding whitespace.
    private static func rubyCode(_ line: String) -> String {
        var quote: Character?
        var out = ""
        for ch in line {
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "'" || ch == "\"" {
                quote = ch
            } else if ch == "#" {
                break
            }
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    private static func rubyOpens(_ code: String) -> Int {
        var opens = code.components(separatedBy: .whitespaces).filter { $0 == "do" || $0.hasPrefix("do|") }.count
        let keyword = code.split(separator: " ").first.map(String.init) ?? ""
        if ["if", "unless", "while", "until", "case", "begin", "def", "class", "module", "for"].contains(keyword) {
            opens += 1
        }
        return opens
    }

    private static func rubyCloses(_ code: String) -> Int {
        code == "end" || code.hasPrefix("end ") || code.hasPrefix("end.") || code.hasPrefix("end)") ? 1 : 0
    }

    private static func firstGroup(_ regex: NSRegularExpression, in text: String) -> String? {
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}

/// Just enough Swift lexing for `Package.swift`: comments removed, string literals and (), [], {} balanced.
struct SwiftText {
    struct Argument {
        var label: String?
        var value: String
    }

    let chars: [Character]

    init(stripComments text: String) {
        chars = SwiftText.removeComments(Array(text))
    }

    /// Arguments text of the first `Name(` call whose name is not part of a longer identifier.
    func callArguments(named name: String) -> String? {
        let needle = Array(name)
        var i = 0
        while i + needle.count < chars.count {
            if chars[i] == "\"" { i = SwiftText.skipString(chars, from: i); continue }
            if Array(chars[i..<(i + needle.count)]) == needle,
               i == 0 || !SwiftText.isIdentifier(chars[i - 1]) {
                var j = i + needle.count
                while j < chars.count, chars[j].isWhitespace { j += 1 }
                if j < chars.count, chars[j] == "(", let close = SwiftText.matchingClose(chars, from: j) {
                    return String(chars[(j + 1)..<close])
                }
            }
            i += 1
        }
        return nil
    }

    /// Top-level, comma-separated arguments with their labels.
    static func labeled(_ text: String) -> [Argument] {
        splitTopLevel(Array(text)).map { part in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            let scalars = Array(trimmed)
            var i = 0
            while i < scalars.count, isIdentifier(scalars[i]) { i += 1 }
            var j = i
            while j < scalars.count, scalars[j].isWhitespace { j += 1 }
            if i > 0, j < scalars.count, scalars[j] == ":", j + 1 >= scalars.count || scalars[j + 1] != ":" {
                return Argument(label: String(scalars[..<i]),
                                value: String(scalars[(j + 1)...]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return Argument(label: nil, value: trimmed)
        }.filter { !$0.value.isEmpty }
    }

    /// `"text"` → `text` (no interpolation); nil for anything else.
    static func string(_ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard v.count >= 2, v.first == "\"", v.last == "\"", !v.hasPrefix("\"\"\"") else { return nil }
        let inner = v.dropFirst().dropLast()
        guard !inner.contains("\"") || inner.contains("\\\"") else { return nil }
        return inner.replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// `[a, b]` → elements; nil when the value is not an array literal.
    static func array(_ value: String) -> [String]? {
        let v = Array(value.trimmingCharacters(in: .whitespacesAndNewlines))
        guard v.first == "[", let close = matchingClose(v, from: 0), close == v.count - 1 else { return nil }
        return splitTopLevel(Array(v[1..<close])).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// `.name(args)` or `name(args)` → (name, labeled args); nil otherwise.
    static func call(_ value: String) -> (name: String, args: [Argument])? {
        let v = Array(value.trimmingCharacters(in: .whitespacesAndNewlines))
        var i = v.first == "." ? 1 : 0
        let start = i
        while i < v.count, isIdentifier(v[i]) { i += 1 }
        guard i > start else { return nil }
        let name = String(v[start..<i])
        while i < v.count, v[i].isWhitespace { i += 1 }
        guard i < v.count, v[i] == "(", let close = matchingClose(v, from: i), close == v.count - 1 else { return nil }
        return (name, labeled(String(v[(i + 1)..<close])))
    }

    static func stringArgument(_ label: String, in args: [Argument]) -> String? {
        args.first { $0.label == label }.flatMap { string($0.value) }
    }

    // MARK: Lexing

    static func isIdentifier(_ c: Character) -> Bool { c == "_" || c.isLetter || c.isNumber }

    /// Index just past the string literal starting at `start` (a `"`); handles `"""` blocks and `\` escapes.
    static func skipString(_ c: [Character], from start: Int) -> Int {
        if start + 2 < c.count, c[start + 1] == "\"", c[start + 2] == "\"" {
            var i = start + 3
            while i + 2 < c.count {
                if c[i] == "\\" { i += 2; continue }
                if c[i] == "\"", c[i + 1] == "\"", c[i + 2] == "\"" { return i + 3 }
                i += 1
            }
            return c.count
        }
        var i = start + 1
        while i < c.count {
            if c[i] == "\\" { i += 2; continue }
            if c[i] == "\"" || c[i] == "\n" { return i + 1 }
            i += 1
        }
        return c.count
    }

    static func matchingClose(_ c: [Character], from open: Int) -> Int? {
        var depth = 0
        var i = open
        while i < c.count {
            switch c[i] {
            case "\"": i = skipString(c, from: i); continue
            case "(", "[", "{": depth += 1
            case ")", "]", "}":
                depth -= 1
                if depth == 0 { return i }
            default: break
            }
            i += 1
        }
        return nil
    }

    static func splitTopLevel(_ c: [Character]) -> [String] {
        var parts: [String] = []
        var depth = 0
        var start = 0
        var i = 0
        while i < c.count {
            switch c[i] {
            case "\"": i = skipString(c, from: i); continue
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth -= 1
            case "," where depth == 0:
                parts.append(String(c[start..<i]))
                start = i + 1
            default: break
            }
            i += 1
        }
        if start < c.count { parts.append(String(c[start...])) }
        return parts
    }

    private static func removeComments(_ c: [Character]) -> [Character] {
        var out: [Character] = []
        out.reserveCapacity(c.count)
        var i = 0
        while i < c.count {
            if c[i] == "\"" {
                let end = skipString(c, from: i)
                out.append(contentsOf: c[i..<end])
                i = end
            } else if c[i] == "/", i + 1 < c.count, c[i + 1] == "/" {
                while i < c.count, c[i] != "\n" { i += 1 }
            } else if c[i] == "/", i + 1 < c.count, c[i + 1] == "*" {
                i += 2
                while i + 1 < c.count, !(c[i] == "*" && c[i + 1] == "/") { i += 1 }
                i += 2
                out.append(" ")
            } else {
                out.append(c[i])
                i += 1
            }
        }
        return out
    }
}
