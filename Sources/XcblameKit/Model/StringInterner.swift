/// Deduplicates repeated strings (rule names, target names, file paths) so the model shares one storage buffer per
/// distinct value. Value type; each `BuildModelBuilder.build` call owns one.
public struct StringInterner: Sendable {
    private var table: [String: String] = [:]

    public init() {}

    public var count: Int { table.count }

    public mutating func intern(_ string: String) -> String {
        if let existing = table[string] { return existing }
        table[string] = string
        return string
    }

    public mutating func intern(_ string: Substring) -> String {
        intern(String(string))
    }

    public mutating func intern(_ string: String?) -> String? {
        string.map { intern($0) }
    }
}
