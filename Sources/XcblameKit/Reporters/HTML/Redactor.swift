import Foundation

/// Replaces `$HOME`, user name, host name, repo-root prefix and DerivedData hash with tokens (DESIGN §3.1, §8.2.6).
public enum Redactor {
    public struct Context: Sendable {
        public var home: String
        public var user: String
        public var host: String
        public var repoRoot: String?
        public var derivedDataHash: String?

        public init(home: String, user: String, host: String, repoRoot: String? = nil, derivedDataHash: String? = nil) {
            self.home = home
            self.user = user
            self.host = host
            self.repoRoot = repoRoot
            self.derivedDataHash = derivedDataHash
        }

        /// This process's home, user and host (`gethostname`, no DNS lookup), plus the git work tree that holds the
        /// current directory (the nearest ancestor with a `.git` entry) as the repo root.
        public static func current() -> Context {
            var buffer = [CChar](repeating: 0, count: 256)
            let host = gethostname(&buffer, buffer.count) == 0
                ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
            let home = NSHomeDirectory()
            return Context(home: home, user: NSUserName(), host: host,
                           repoRoot: gitRoot(from: FileManager.default.currentDirectoryPath, home: home))
        }

        /// Nearest ancestor of `path` holding `.git`; nil at `/` or when it is `home` itself (that is `~` already).
        static func gitRoot(from path: String, home: String) -> String? {
            var url = URL(fileURLWithPath: path).standardizedFileURL
            while url.path != "/" {
                if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                    return url.path == home ? nil : url.path
                }
                url.deleteLastPathComponent()
            }
            return nil
        }
    }

    /// Every string value of the document (never a key) goes through `redact(string:context:)`; numbers and
    /// structure are untouched. `redacted` becomes true. Non-finite numbers become null with a note first
    /// (`DocumentSanitizer`). Fails closed: when the round trip still fails it throws `outputAborted`, so the caller
    /// writes nothing; it never hands back an unredacted document.
    // ponytail: generic JSON round trip (encode → walk the `Any` tree → decode) instead of a per-field walk, so a
    // member added later is covered for free; costs one extra encode/decode of the document. Doubles survive because
    // JSONSerialization writes 17 significant digits.
    public static func redact(_ document: ReportDocument, context: Context) throws -> ReportDocument {
        var marked = document
        marked.redacted = true
        return try roundTrip(marked, context: context)
    }

    /// Compare and trend documents (docs/SCHEMA-v0.4.md): the same string rules, `redacted` set to true. Fails closed
    /// like the report overload.
    public static func redact(_ document: CompareDocument, context: Context) throws -> CompareDocument {
        var marked = document
        marked.redacted = true
        return try roundTrip(marked, context: context)
    }

    public static func redact(_ document: TrendDocument, context: Context) throws -> TrendDocument {
        var marked = document
        marked.redacted = true
        return try roundTrip(marked, context: context)
    }

    /// Shared with the fix plan and verify overloads (`Redactor+FixVerify.swift`).
    static func roundTrip<T: Codable>(_ value: T, context: Context) throws -> T {
        let clean = try DocumentSanitizer.sanitize(value)
        do {
            let data = try JSONReporter.encoder().encode(clean)
            let tree = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let out = try JSONSerialization.data(withJSONObject: walk(tree, context), options: [.fragmentsAllowed])
            return try JSONReporter.decoder().decode(T.self, from: out)
        } catch {
            throw XcblameError.outputAborted("redaction failed (\(error))")
        }
    }

    /// The task index's string tables (target names, labels) with the same tokens as the document, so the drawer's
    /// target names still match the redacted `targets[].name`. Kinds are enum names and stay.
    public static func redact(_ index: TaskIndex, context: Context) -> TaskIndex {
        var out = index
        out.targets = index.targets.map { redact(string: $0, context: context) }
        out.labels = index.labels.map { redact(string: $0, context: context) }
        return out
    }

    private static func walk(_ value: Any, _ context: Context) -> Any {
        switch value {
        case let string as String: return redact(string: string, context: context)
        case let array as [Any]: return array.map { walk($0, context) }
        case let object as [String: Any]:
            // `environment.git.remoteHost` (and `git` of a compare side) names the origin's host: a self-hosted one is
            // internal, so it leaves with the other identifiers. Branch names and commits are not secrets and stay.
            return object.reduce(into: [String: Any]()) { out, pair in
                out[pair.key] = pair.key == "remoteHost" && pair.value is String ? "$REMOTE" : walk(pair.value, context)
            }
        default: return value
        }
    }

    /// Order matters: the DerivedData hash and repo root before home (both usually sit under it), host before user
    /// (host names often contain the user name).
    public static func redact(string: String, context: Context) -> String {
        var text = string
        if text.contains("/DerivedData/") {
            text = derivedData.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "/DerivedData/$1-\\$DDHASH")
        }
        if let hash = context.derivedDataHash, !hash.isEmpty { text = text.replacingOccurrences(of: hash, with: "$DDHASH") }
        if let root = context.repoRoot, root.count > 1 { text = text.replacingOccurrences(of: root, with: "$REPO") }
        if context.home.count > 1 { text = text.replacingOccurrences(of: context.home, with: "~") }
        var hosts = [context.host]
        if context.host.hasSuffix(".local") { hosts.append(String(context.host.dropLast(".local".count))) }
        for host in hosts { text = replaceBounded(host, with: "$HOST", in: text) }
        // Any other home folder (a CI runner's, a colleague's log re-rendered here) loses its user name too.
        if text.contains("/Users/") || text.contains("/home/") {
            text = otherHome.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                      withTemplate: "$1\\$USER")
        }
        // Digits may follow the user name (`/Volumes/ann2/`), letters may not (`ann` leaves `annie` alone).
        return replaceBounded(context.user, with: "$USER", in: text, digitsMayFollow: true)
    }

    /// `/Users/<name>` or `/home/<name>` (any name but `Shared` and the token itself), only where a path starts: at
    /// the string start or after whitespace, `"`, `'`, `=`, `(`, `[`, `,` or `:`. Not inside a URL
    /// (`https://example.com/Users/guide`) or a deeper path (`/opt/home/x`).
    private static let otherHome = try! NSRegularExpression(
        pattern: #"(?<![^\s"'=(\[,:])(/(?:Users|home)/)(?!Shared(?:/|$))(?!\$USER(?:/|$))[^/\s"'<>()\[\],:=]+"#)

    /// `/DerivedData/<Name>-<28 lowercase letters>`: Xcode's per-workspace hash.
    private static let derivedData = try! NSRegularExpression(pattern: "/DerivedData/([^/]+?)-[a-z]{28}(?=/|$)")

    /// Replaces `needle` where it is not glued to a letter or digit on either side, so the user `ann` leaves
    /// `planning` alone but `/Users/ann/` and `ann's Mac` are replaced.
    // ponytail: word-bounded matching keeps short user names from mangling ordinary words; a user name glued to
    // letters (`annie`) survives, one glued to digits does not when `digitsMayFollow`. Upgrade: exact
    // path-component matching per field if that ever matters.
    static func replaceBounded(_ needle: String, with token: String, in text: String,
                               digitsMayFollow: Bool = false) -> String {
        guard !needle.isEmpty, text.contains(needle) else { return text }
        var result = ""
        var rest = text[...]
        while let range = rest.range(of: needle) {
            let before = range.lowerBound > rest.startIndex ? rest[rest.index(before: range.lowerBound)] : nil
            let after = range.upperBound < rest.endIndex ? rest[range.upperBound] : nil
            let glued = after.map { digitsMayFollow ? $0.isLetter : isWordCharacter($0) } ?? false
            let bounded = !(before.map(isWordCharacter) ?? false) && !glued
            result += rest[..<range.lowerBound]
            result += bounded ? token : String(rest[range])
            rest = rest[range.upperBound...]
        }
        return result + rest
    }

    private static func isWordCharacter(_ character: Character) -> Bool { character.isLetter || character.isNumber }
}
