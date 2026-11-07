import Foundation

// v0.5 lane B (docs/SCHEMA-v0.5.md "Why"): matching a task of this build to the same task of the previous build.
public struct TaskIdentity: Hashable, Sendable {
    public var rule: String
    public var target: String?
    /// Task key when the task has one (§5.6); the strongest identity.
    public var key: String?
    /// `History.TaskIndexRow.sigDigest` (portable command-line digest).
    public var sigDigest: String

    public init(rule: String, target: String?, key: String?, sigDigest: String) {
        self.rule = rule
        self.target = target
        self.key = key
        self.sigDigest = sigDigest
    }

    public init(_ row: History.TaskIndexRow) {
        self.init(rule: row.rule, target: row.target, key: row.key, sigDigest: row.sigDigest)
    }

    /// One current row and the previous row it matched (nil: no previous counterpart, so `ruleNeverBuilt` or new).
    public struct Match: Sendable, Equatable {
        public var current: Int
        public var previous: Int?
        /// The match was by key with a different digest (the signature-changed signal, source `signature`).
        public var signatureChanged: Bool

        public init(current: Int, previous: Int?, signatureChanged: Bool) {
            self.current = current
            self.previous = previous
            self.signatureChanged = signatureChanged
        }
    }

    /// Matches by key first (DESIGN §5.7: the SLF task key is the strongest identity; a different digest under the same
    /// key is the signature-changed signal), then the rest by `(rule, target, sigDigest)` as a multiset. Each previous
    /// row matches at most one current row; one `Match` per current row, in order.
    public static func match(current: [History.TaskIndexRow], previous: [History.TaskIndexRow]) throws -> [Match] {
        var byKey: [String: [Int]] = [:]
        var byShape: [Shape: [Int]] = [:]
        for (index, row) in previous.enumerated() {
            if let key = stableKey(row.key) { byKey[key, default: []].append(index) }
            byShape[Shape(row), default: []].append(index)
        }
        var used = Set<Int>()
        var matches = current.indices.map { Match(current: $0, previous: nil, signatureChanged: false) }
        func take(_ candidates: [Int]?) -> Int? {
            guard let found = candidates?.first(where: { !used.contains($0) }) else { return nil }
            used.insert(found)
            return found
        }
        // Keyed rows first, so a shape match never steals the row a key names.
        for (index, row) in current.enumerated() {
            guard let key = stableKey(row.key), let found = take(byKey[key]) else { continue }
            matches[index] = Match(current: index, previous: found, signatureChanged: previous[found].sigDigest != row.sigDigest)
        }
        for (index, row) in current.enumerated() where matches[index].previous == nil {
            if let found = take(byShape[Shape(row)]) {
                matches[index] = Match(current: index, previous: found, signatureChanged: false)
            }
        }
        return matches
    }

    /// `key` unless it names a dynamic task: the keys of driver jobs and PCMs are (or end in `:`) 32 hex digits
    /// (`P2:target-…:Debug:<hex>`, probes-v0.5 §MV-2) handed out per build, so the same key names another job in the
    /// next build (seen on both remarks fixtures). Those rows match by shape only.
    public static func stableKey(_ key: String?) -> String? {
        guard let key else { return nil }
        let tail = key.lastIndex(of: ":").map { key[key.index(after: $0)...] } ?? key[...]
        let dynamic = tail.count == 32 && tail.allSatisfy { $0.isHexDigit }
        return dynamic ? nil : key
    }

    /// The second fallback when keys and command-line digests both differ (a new Xcode changes every command line):
    /// rule, target and the task's primary output as its title names it (`Compiling Models.swift`). Nil without a title
    /// (rows read from history entries carry none).
    public static func outputShape(_ row: History.TaskIndexRow) -> String? {
        guard let title = row.title, !title.isEmpty else { return nil }
        return row.rule + "\u{1}" + (row.target ?? "") + "\u{1}" + title
    }

    /// Pairs rows left over on each side: by stable task key first (two Run Script phases named "Run Script" in one
    /// target keep their own key, while their command text differs per invocation), then by `outputShape` as a
    /// multiset (longest first on both sides, so the pairing is stable). Returns the pairs and the unpaired rows.
    public static func pairByOutput(_ a: [History.TaskIndexRow], _ b: [History.TaskIndexRow])
        -> (pairs: [(a: History.TaskIndexRow, b: History.TaskIndexRow)], a: [History.TaskIndexRow], b: [History.TaskIndexRow]) {
        func longest(_ x: History.TaskIndexRow, _ y: History.TaskIndexRow) -> Bool {
            x.durationMs != y.durationMs ? x.durationMs > y.durationMs : x.onPath && !y.onPath
        }
        var pairs: [(a: History.TaskIndexRow, b: History.TaskIndexRow)] = []
        var byKey: [String: [Int]] = [:]
        for (index, row) in b.enumerated() {
            if let key = stableKey(row.key) { byKey[row.rule + "\u{1}" + key, default: []].append(index) }
        }
        var takenB = Set<Int>()
        var leftA: [History.TaskIndexRow] = []
        for row in a {
            if let key = stableKey(row.key), let found = byKey[row.rule + "\u{1}" + key]?.first(where: { !takenB.contains($0) }) {
                takenB.insert(found)
                pairs.append((row, b[found]))
            } else {
                leftA.append(row)
            }
        }
        let leftB = b.indices.filter { !takenB.contains($0) }.map { b[$0] }
        var right: [String: [History.TaskIndexRow]] = [:]
        var restB: [History.TaskIndexRow] = []
        for row in leftB.sorted(by: longest) {
            if let shape = outputShape(row) { right[shape, default: []].append(row) } else { restB.append(row) }
        }
        var restA: [History.TaskIndexRow] = []
        for row in leftA.sorted(by: longest) {
            if let shape = outputShape(row), var candidates = right[shape], !candidates.isEmpty {
                pairs.append((row, candidates.removeFirst()))
                right[shape] = candidates
            } else {
                restA.append(row)
            }
        }
        restB += right.keys.sorted().flatMap { right[$0] ?? [] }
        return (pairs, restA, restB)
    }

    /// The fallback identity of §5.7 without a key: rule, target and the portable command-line digest.
    private struct Shape: Hashable {
        var rule: String
        var target: String?
        var sigDigest: String

        init(_ row: History.TaskIndexRow) {
            rule = row.rule
            target = row.target
            sigDigest = row.sigDigest
        }
    }
}
