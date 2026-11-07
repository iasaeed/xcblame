import Foundation

/// JSON cannot hold NaN or ±infinity. Before any reporter or the Redactor encodes a document, each non-finite number
/// becomes `null` with a note in the nearest enclosing `notes` (DESIGN §8.1: unknown is null with a note, never 0).
/// A non-finite number in a member that cannot be null leaves no safe document: that throws `outputAborted`.
public enum DocumentSanitizer {
    // ponytail: the same generic JSON round trip as the Redactor (encode with string sentinels → walk the `Any` tree →
    // decode), so every member, present and future, is covered; it only runs when the plain encode fails.
    public static func sanitize<T: Codable>(_ value: T) throws -> T {
        if (try? JSONReporter.encoder().encode(value)) != nil { return value }
        do {
            let encoder = JSONReporter.encoder()
            encoder.nonConformingFloatEncodingStrategy = .convertToString(
                positiveInfinity: Sentinel.positiveInfinity, negativeInfinity: Sentinel.negativeInfinity, nan: Sentinel.nan)
            let tree = try JSONSerialization.jsonObject(with: try encoder.encode(value), options: [.fragmentsAllowed])
            var replaced: [String] = []
            let (clean, _) = walk(tree, path: "", replaced: &replaced)
            let data = try JSONSerialization.data(withJSONObject: clean, options: [.fragmentsAllowed])
            do {
                return try JSONReporter.decoder().decode(T.self, from: data)
            } catch {
                throw XcblameError.outputAborted("the report holds a non-finite number where null is not allowed ("
                    + replaced.sorted().joined(separator: ", ") + ")")
            }
        } catch let error as XcblameError {
            throw error
        } catch {
            throw XcblameError.outputAborted("the report could not be encoded (\(error))")
        }
    }

    private enum Sentinel {
        static let positiveInfinity = "\u{1}xcblame-non-finite:+inf"
        static let negativeInfinity = "\u{1}xcblame-non-finite:-inf"
        static let nan = "\u{1}xcblame-non-finite:nan"

        static func label(_ string: String) -> String? {
            switch string {
            case positiveInfinity: return "+inf"
            case negativeInfinity: return "-inf"
            case nan: return "nan"
            default: return nil
            }
        }
    }

    /// Returns the cleaned value and the notes still looking for a `notes` array (they go to the nearest ancestor
    /// object that has one).
    private static func walk(_ value: Any, path: String, replaced: inout [String]) -> (Any, [String]) {
        switch value {
        case let string as String:
            guard let label = Sentinel.label(string) else { return (string, []) }
            replaced.append(path)
            return (NSNull(), ["\(path): not a finite number (\(label)), reported as null"])
        case let array as [Any]:
            var notes: [String] = []
            let out = array.enumerated().map { index, element -> Any in
                let (clean, pending) = walk(element, path: "\(path)[\(index)]", replaced: &replaced)
                notes += pending
                return clean
            }
            return (out, notes)
        case let object as [String: Any]:
            var notes: [String] = []
            var out: [String: Any] = [:]
            for (key, child) in object {
                let (clean, pending) = walk(child, path: path.isEmpty ? key : "\(path).\(key)", replaced: &replaced)
                out[key] = clean
                notes += pending
            }
            if !notes.isEmpty, let existing = out["notes"] as? [Any] {
                out["notes"] = existing + notes.sorted()
                return (out, [])
            }
            return (out, notes)
        default:
            return (value, [])
        }
    }
}
