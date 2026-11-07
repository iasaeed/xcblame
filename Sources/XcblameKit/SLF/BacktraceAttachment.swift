import Foundation

// v0.5 lane B (docs/research/probes-v0.5.md §MV-2): the `TaskBacktrace` section attachment, read by its keys. One
// attachment per task, a JSON array of frames, the task itself first and the root cause last. Enum values are
// single-key objects (`{"ruleInputRebuilt":{}}`); `identifier.storage.task._0` is a byte array (a task key with a
// leading `\0`), `identifier.storage.key._0` a string (`<BuildKey.Node path=…>`). Text differs between Xcode 26 and 27,
// so nothing here keys on `description`. The same frames arrive as text in a `Build Backtrace:` block of the task's
// emitted output (SLF, xcresult, stdout): `textFrames(in:)` reads those when there is no attachment.
public enum BacktraceAttachment {
    /// Decodes the attachment JSON into frames, keeping category, frame kind and identifiers. Nil when it is not a
    /// frame array (or an object holding one under `frames`).
    public static func decode(_ data: Data) -> Backtrace? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let array = (object as? [Any]) ?? ((object as? [String: Any])?["frames"] as? [Any]) else { return nil }
        return Backtrace(frames: array.compactMap { $0 as? [String: Any] }.map(frame))
    }

    static func frame(_ raw: [String: Any]) -> Backtrace.Frame {
        var frame = Backtrace.Frame(category: enumKey(raw["category"]), description: raw["description"] as? String)
        frame.frameKind = enumKey(raw["frameKind"])
        frame.identifier = identifier(raw["identifier"])
        frame.previousFrameIdentifier = identifier(raw["previousFrameIdentifier"])
        return frame
    }

    /// `"x"` or `{"x": {}}` → `x`.
    static func enumKey(_ value: Any?) -> String? {
        (value as? String) ?? (value as? [String: Any]).flatMap { $0.keys.sorted().first }
    }

    /// `task:<key>` (bytes decoded as UTF-8, control prefix bytes stripped) or `key:<string>`; nil when absent.
    static func identifier(_ value: Any?) -> String? {
        guard let storage = (value as? [String: Any])?["storage"] as? [String: Any] else { return nil }
        if let task = storage["task"] as? [String: Any] {
            if let bytes = task["_0"] as? [Any] {
                let raw = bytes.compactMap { ($0 as? NSNumber)?.uint8Value }
                return "task:" + taskKey(String(decoding: raw, as: UTF8.self))
            }
            if let text = task["_0"] as? String { return "task:" + taskKey(text) }
        }
        if let key = storage["key"] as? [String: Any], let text = key["_0"] as? String { return "key:" + text }
        return nil
    }

    /// The task key of a frame identifier: the leading `\0`/`\u{1}`/`\u{2}` prefix byte dropped (§5.6).
    static func taskKey(_ text: String) -> String {
        String(text.drop { $0.unicodeScalars.allSatisfy { $0.value < 0x20 } })
    }

    /// The frame descriptions of the last `Build Backtrace:` block of an emitted output, first (the task) to last (the
    /// root). Frames read from text have no category; `BacktraceFrames` classifies them by the wording of both Xcodes.
    public static func textFrames(in emittedOutput: String?) -> [String] {
        guard let text = emittedOutput, let marker = text.range(of: "Build Backtrace:", options: .backwards) else {
            return []
        }
        return text[marker.upperBound...]
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
