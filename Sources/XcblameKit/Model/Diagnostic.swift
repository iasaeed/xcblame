import Foundation

/// A compiler/build diagnostic, deduped across tasks (DESIGN §5.10).
public struct Diagnostic: Codable, Sendable, Identifiable {
    public enum Severity: String, Codable, Sendable, CaseIterable {
        case error, warning, analyzerWarning, notice, unknown

        /// From the SLF int (0 notice, 1 warning, 2 error) or the xcresult `type` string; never from categoryIdent.
        public init(int: Int?, type: String?) {
            if let int {
                switch int {
                case 0: self = .notice
                case 1: self = .warning
                case 2: self = .error
                default: self = .unknown
                }
                return
            }
            switch type?.lowercased() {
            case "error": self = .error
            case "warning": self = .warning
            case "analyzer warning", "analyzerwarning": self = .analyzerWarning
            case "notice", "note", "remark": self = .notice
            default: self = .unknown
            }
        }
    }

    public var id: Int
    public var severity: Severity
    /// Title followed by sub-messages (notes, fix-its), newline-separated.
    public var text: String
    /// Display/grouping only.
    public var category: String?
    /// Path (file URL scheme and fragment removed).
    public var file: String?
    /// 1-based.
    public var line: Int?
    /// 1-based.
    public var column: Int?
    public var endLine: Int?
    public var endColumn: Int?
    /// How many times this diagnostic was emitted (across tasks and repeats).
    public var occurrences: Int
    /// Tasks that emitted it, in first-seen order; empty for diagnostics on non-task sections.
    public var taskIds: [Int]

    public var key: DiagnosticKey {
        DiagnosticKey(severity: severity, file: file, line: line, column: column, text: DiagnosticKey.normalize(text))
    }
}

/// Dedupe key: `(severity, file, line, column, normalized message)`.
public struct DiagnosticKey: Hashable, Sendable {
    public var severity: Diagnostic.Severity
    public var file: String?
    public var line: Int?
    public var column: Int?
    public var text: String

    /// Trims and collapses whitespace runs to one space.
    public static func normalize(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for ch in text {
            if ch.isWhitespace {
                pendingSpace = !out.isEmpty
            } else {
                if pendingSpace { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            }
        }
        return out
    }
}

/// Accumulates `RawMessage`s into deduped `Diagnostic`s.
public struct DiagnosticCollector: Sendable {
    public private(set) var diagnostics: [Diagnostic] = []
    private var index: [DiagnosticKey: Int] = [:]

    public init() {}

    /// Adds one message (with its sub-messages folded into the text); returns the diagnostic id.
    @discardableResult
    public mutating func add(_ message: RawMessage, taskId: Int?, interner: inout StringInterner) -> Int {
        var text = message.title
        Self.appendSubmessages(message.submessages, to: &text)
        let loc = message.location
        let base = loc?.numberBase ?? 0
        // Values outside 0...Int32.max are not line numbers (a crafted log or URL can hold Int.max): nil, never a trap.
        let oneBased: (Int?) -> Int? = { value in
            guard let value, (0...Int(Int32.max)).contains(value), (0...1).contains(base) else { return nil }
            return value + 1 - base
        }
        let candidate = Diagnostic(
            id: diagnostics.count,
            severity: Diagnostic.Severity(int: message.severity, type: message.type),
            text: text,
            category: interner.intern(message.categoryIdent),
            file: interner.intern(loc?.file.map(Self.path(fromFileReference:))),
            line: oneBased(loc?.startLine), column: oneBased(loc?.startColumn),
            endLine: oneBased(loc?.endLine), endColumn: oneBased(loc?.endColumn),
            occurrences: 1, taskIds: taskId.map { [$0] } ?? [])
        let key = candidate.key
        if let existing = index[key] {
            diagnostics[existing].occurrences += 1
            if let taskId, !diagnostics[existing].taskIds.contains(taskId) {
                diagnostics[existing].taskIds.append(taskId)
            }
            return existing
        }
        index[key] = candidate.id
        diagnostics.append(candidate)
        return candidate.id
    }

    private static func appendSubmessages(_ messages: [RawMessage], to text: inout String) {
        for sub in messages {
            text += "\n" + sub.title
            appendSubmessages(sub.submessages, to: &text)
        }
    }

    /// `file:///a%20b/c.swift#StartingLineNumber=3` -> `/a b/c.swift`; plain paths pass through.
    static func path(fromFileReference ref: String) -> String {
        guard ref.hasPrefix("file://") else { return ref }
        var s = Substring(ref).dropFirst("file://".count)
        if let hash = s.firstIndex(of: "#") { s = s[..<hash] }
        return s.removingPercentEncoding ?? String(s)
    }
}
