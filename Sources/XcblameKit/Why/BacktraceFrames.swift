import Foundation

// v0.5 lane B (docs/research/probes-v0.5.md §MV-2 "Implications for the parser"): one task's Task Backtrace reduced to
// its root cause. Frames come from the `TaskBacktrace` attachment (category and frame-kind keys decide, never text) or,
// without one, from the `Build Backtrace:` block of the task's emitted output (the wording of Xcode 26 and 27 decides).
// The root cause is the LAST frame; the first frame is the task itself.
public struct BacktraceRoot: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `ruleHadInvalidValue` on a file (`file 'X' changed`).
        case fileChanged(String)
        /// `ruleHadInvalidValue` on a directory (`contents of 'X' changed`).
        case directoryChanged(String)
        /// `ruleSignatureChanged`.
        case signatureChanged
        /// `ruleNeverBuilt`.
        case neverBuilt
        /// `ruleHadInvalidValue` on a task configured to run in every incremental build (always out of date).
        case alwaysRuns
        /// `ruleHadInvalidValue` on a task whose outputs were missing or modified.
        case outputsInvalid
        /// `ruleForced`.
        case forced
        /// `dynamicTaskRequest` / `dynamicTaskRegistration`: scheduled by the Swift driver.
        case driverScheduled
        /// The chain stops on `ruleInputRebuilt` (no root frame recorded).
        case inputRebuilt
        /// A category this parser does not know.
        case other(String)
    }

    public var kind: Kind
    /// Description of the root frame (display only).
    public var description: String
    /// Task key of the deepest task frame after the first (the upstream task the chain runs through), when known.
    public var rootTaskKey: String?
    /// Title of that upstream task as the frame text names it (`an input of 'Compile Core (arm64)' changed`).
    public var rootTaskTitle: String?
    public var frameCount: Int
    /// `attachment` or `text`.
    public var origin: String

    public init(kind: Kind, description: String, rootTaskKey: String?, rootTaskTitle: String?, frameCount: Int,
                origin: String) {
        self.kind = kind
        self.description = description
        self.rootTaskKey = rootTaskKey
        self.rootTaskTitle = rootTaskTitle
        self.frameCount = frameCount
        self.origin = origin
    }

    /// The root of `task`'s backtrace: the attachment when there is one, else the emitted `Build Backtrace:` block.
    public static func of(_ task: BuildTask) -> BacktraceRoot? {
        if let frames = task.backtrace?.frames, !frames.isEmpty { return fromAttachment(frames) }
        return fromText(BacktraceAttachment.textFrames(in: task.emittedOutput))
    }

    /// Category and frame-kind keys decide; the description only splits `ruleHadInvalidValue` on a task (both Xcodes
    /// say `configured to run in every incremental build` for an always-run task) and names paths when the frame has
    /// no `BuildKey` identifier.
    public static func fromAttachment(_ frames: [Backtrace.Frame]) -> BacktraceRoot? {
        guard let root = frames.last else { return nil }
        let text = root.description ?? ""
        let path = root.identifier.flatMap(buildKeyPath) ?? quoted(text)
        let kind: Kind
        switch root.category ?? "" {
        case "ruleHadInvalidValue":
            switch root.frameKind {
            case "file": kind = path.map(Kind.fileChanged) ?? .other("ruleHadInvalidValue")
            case "directory": kind = path.map(Kind.directoryChanged) ?? .other("ruleHadInvalidValue")
            default: kind = text.contains("every incremental build") ? .alwaysRuns : .outputsInvalid
            }
        case "ruleSignatureChanged": kind = .signatureChanged
        case "ruleNeverBuilt": kind = .neverBuilt
        case "ruleForced": kind = .forced
        case "dynamicTaskRequest", "dynamicTaskRegistration": kind = .driverScheduled
        case "ruleInputRebuilt": kind = .inputRebuilt
        case let other: kind = .other(other.isEmpty ? "unknown" : other)
        }
        // The upstream task: the deepest task frame after the first one (the first is this task).
        var key: String?
        var title: String?
        for frame in frames.dropFirst().reversed() where frame.frameKind == "genericTask" || frame.identifier?.hasPrefix("task:") == true {
            key = frame.identifier.flatMap { $0.hasPrefix("task:") ? String($0.dropFirst(5)) : nil }
            title = frame.description.flatMap(quoted)
            break
        }
        return BacktraceRoot(kind: kind, description: text, rootTaskKey: key, rootTaskTitle: title,
                             frameCount: frames.count, origin: "attachment")
    }

    /// The text fallback: the last line is the root; the last `an input of '<task>' changed` line names the upstream
    /// task. Wording of Xcode 26.0.1 and 27.1 (probes-v0.5 §MV-2, "26.0.1 vs 27.1 differences").
    public static func fromText(_ lines: [String]) -> BacktraceRoot? {
        guard let root = lines.last else { return nil }
        let kind: Kind
        if root.hasPrefix("file '"), root.hasSuffix("' changed"), let path = quoted(root) {
            kind = .fileChanged(path)
        } else if root.hasPrefix("contents of '"), let path = quoted(root) {
            kind = .directoryChanged(path)
        } else if root.hasSuffix("had never run") {
            kind = .neverBuilt
        } else if root.contains("every incremental build") {
            kind = .alwaysRuns
        } else if root.hasSuffix("did not have up-to-date outputs") || root.hasSuffix("were missing or modified") {
            kind = .outputsInvalid
        } else if root.hasPrefix("signature of '") || root.contains("component of the signature of '") {
            kind = .signatureChanged
        } else if root.contains("scheduled by the Swift driver") {
            kind = .driverScheduled
        } else if root.hasPrefix("an input of ") || root.hasPrefix("the producer of ") || root.hasPrefix("the task producing ") {
            kind = .inputRebuilt
        } else {
            kind = .other("text")
        }
        var title: String?
        for line in lines.dropFirst().reversed() where line.hasPrefix("an input of '") {
            title = quoted(line)
            break
        }
        return BacktraceRoot(kind: kind, description: root, rootTaskKey: nil, rootTaskTitle: title,
                             frameCount: lines.count, origin: "text")
    }

    /// `key:<BuildKey.Node path=/a/b>` (also `DirectoryTreeSignature`, `DirectoryContents`) → `/a/b`.
    static func buildKeyPath(_ identifier: String) -> String? {
        guard identifier.hasPrefix("key:"), let start = identifier.range(of: "path=") else { return nil }
        var path = identifier[start.upperBound...]
        if path.hasSuffix(">") { path = path.dropLast() }
        // `DirectoryTreeSignature` keys carry ` filters=[…]` after the path.
        if let filters = path.range(of: " filters=") { path = path[..<filters.lowerBound] }
        return path.isEmpty ? nil : String(path)
    }

    /// The text between the first and the last single quote; nil when there is no such pair.
    static func quoted(_ text: String) -> String? {
        guard let first = text.firstIndex(of: "'"), let last = text.lastIndex(of: "'"), first < last else { return nil }
        let inner = text[text.index(after: first)..<last]
        return inner.isEmpty ? nil : String(inner)
    }
}
