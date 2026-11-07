/// Encodes `nil` as an explicit JSON `null` (synthesized `Codable` drops the key), so "unknown" is always visible
/// in the report and never silently absent (DESIGN §8.1: unknown values are `null` with a note, never `0`).
@propertyWrapper
public struct Null<Wrapped: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    public var wrappedValue: Wrapped?

    public init(wrappedValue: Wrapped?) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? nil : try container.decode(Wrapped.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue { try container.encode(wrappedValue) } else { try container.encodeNil() }
    }
}

/// A member added after a report format shipped (schema v0.3, docs/SCHEMA-v0.3.md): it always serializes (an
/// optional as an explicit `null`), and a saved report written before it existed decodes with the default (`nil`,
/// `[]`) instead of failing re-rendering.
@propertyWrapper
public struct Added<Value: AddedDefault & Sendable>: Codable, Sendable, Equatable {
    public var wrappedValue: Value

    public init(wrappedValue: Value) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        wrappedValue = try decoder.singleValueContainer().decode(Value.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

/// The value an `@Added` member takes when the key is absent.
public protocol AddedDefault: Codable, Equatable {
    static var addedDefault: Self { get }
}

extension Optional: AddedDefault where Wrapped: Codable & Equatable {
    public static var addedDefault: Self { nil }
}

extension Int: AddedDefault {
    public static var addedDefault: Self { 0 }
}

extension Array: AddedDefault where Element: Codable & Equatable {
    public static var addedDefault: Self { [] }
}

extension KeyedDecodingContainer {
    /// Synthesized `Decodable` calls this for every `@Added` member; an absent key yields the default.
    public func decode<Value>(_ type: Added<Value>.Type, forKey key: Key) throws -> Added<Value> {
        try decodeIfPresent(type, forKey: key) ?? Added(wrappedValue: Value.addedDefault)
    }
}
