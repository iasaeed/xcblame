import Foundation

/// A minimal JSON Schema validator for the subset `xcblame schema` emits: `type` (string or list), `const`, `enum`,
/// `required`, `properties`, `additionalProperties` (boolean or schema), `items`, `anyOf`, `oneOf`, `$ref` (local JSON
/// pointers) and `format: date-time`.
///
/// In `strict` mode an object member that its schema does not list is an error even though `additionalProperties` is
/// true: that is how the tests notice a document member the mirror table forgot.
struct MiniSchemaValidator {
    let root: [String: Any]
    var strict = true

    func errors(_ value: Any, schema: [String: Any]? = nil) -> [String] {
        var out: [String] = []
        validate(value, schema ?? root, path: "$", into: &out)
        return out
    }

    private func resolve(_ reference: String) -> [String: Any]? {
        guard reference.hasPrefix("#/") else { return nil }
        var node: Any = root
        for part in reference.dropFirst(2).split(separator: "/") {
            guard let next = (node as? [String: Any])?[String(part)] else { return nil }
            node = next
        }
        return node as? [String: Any]
    }

    private func isBool(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private func matches(type: String, _ value: Any) -> Bool {
        switch type {
        case "null": return value is NSNull
        case "string": return value is String
        case "boolean": return isBool(value)
        case "number": return value is NSNumber && !isBool(value)
        case "integer":
            guard let number = value as? NSNumber, !isBool(value) else { return false }
            return number.doubleValue == number.doubleValue.rounded() && !"\(number)".contains(".")
        case "array": return value is [Any]
        case "object": return value is [String: Any]
        default: return false
        }
    }

    private func validate(_ value: Any, _ schema: [String: Any], path: String, into out: inout [String]) {
        if let reference = schema["$ref"] as? String {
            guard let target = resolve(reference) else { return out.append("\(path): unresolved \(reference)") }
            return validate(value, target, path: path, into: &out)
        }
        if let any = schema["anyOf"] as? [[String: Any]] {
            let passes = any.contains { var local: [String] = []; validate(value, $0, path: path, into: &local); return local.isEmpty }
            if !passes { out.append("\(path): matches none of anyOf") }
            return
        }
        if let one = schema["oneOf"] as? [[String: Any]] {
            let passes = one.filter { var local: [String] = []; validate(value, $0, path: path, into: &local); return local.isEmpty }
            if passes.count != 1 { out.append("\(path): matches \(passes.count) of oneOf") }
            return
        }
        if let constant = schema["const"] as? String, (value as? String) != constant {
            out.append("\(path): expected const \(constant)")
        }
        if let types = (schema["type"] as? [String]) ?? (schema["type"] as? String).map({ [$0] }),
           !types.contains(where: { matches(type: $0, value) }) {
            return out.append("\(path): expected \(types.joined(separator: "|")), got \(type(of: value))")
        }
        if let allowed = schema["enum"] as? [Any] {
            let ok = allowed.contains { ($0 as? String) == (value as? String) && !(value is NSNull) || ($0 is NSNull && value is NSNull) }
            if !ok { out.append("\(path): \(value) not in enum") }
        }
        if schema["format"] as? String == "date-time", let text = value as? String {
            let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#
            if text.range(of: pattern, options: .regularExpression) == nil { out.append("\(path): \(text) is not a date-time") }
        }
        if let object = value as? [String: Any] {
            let properties = schema["properties"] as? [String: Any] ?? [:]
            for key in schema["required"] as? [String] ?? [] where object[key] == nil { out.append("\(path): missing required \(key)") }
            for (key, member) in object.sorted(by: { $0.key < $1.key }) {
                if let sub = properties[key] as? [String: Any] {
                    validate(member, sub, path: "\(path).\(key)", into: &out)
                } else if let extra = schema["additionalProperties"] as? [String: Any] {
                    validate(member, extra, path: "\(path).\(key)", into: &out)
                } else if schema["additionalProperties"] as? Bool == false {
                    out.append("\(path): unexpected \(key)")
                } else if strict, schema["properties"] != nil {
                    out.append("\(path): member \(key) is not in the schema")
                }
            }
        }
        if let array = value as? [Any], let items = schema["items"] as? [String: Any] {
            for (index, element) in array.enumerated() { validate(element, items, path: "\(path)[\(index)]", into: &out) }
        }
    }
}
