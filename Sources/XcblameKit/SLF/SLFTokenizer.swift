import Foundation

/// SLF token kinds (DESIGN §5.3).
public enum SLFTokenKind: UInt8, Sendable, CaseIterable {
    /// `DEC+ "#"`
    case int
    /// `HEX{16} "^"`, little-endian IEEE-754 bits.
    case double
    /// `DEC+ "\"" BYTE{n}`
    case string
    /// `DEC+ "*" BYTE{n}`
    case json
    /// `DEC+ "%" BYTE{n}`: defines the next class-table entry.
    case classDef
    /// `DEC+ "@"`: 1-based class-table index; starts an instance.
    case classRef
    /// `DEC+ "("`: element count; elements follow.
    case array
    /// `"-"`
    case null
}

/// One token. Strings are not decoded here; `SLFTokenizer.string(_:)` decodes on demand.
public struct SLFToken: Sendable, Equatable {
    public var kind: SLFTokenKind
    /// int: the value; double: the IEEE-754 bit pattern; string/json/classDef: payload byte length;
    /// classRef: 1-based class index; array: element count; null: 0.
    public var value: UInt64
    /// Offset of the token's first byte in the inflated log.
    public var offset: Int
    /// Offset of the payload (string/json/classDef); the end of the token otherwise.
    public var payloadStart: Int

    public init(kind: SLFTokenKind, value: UInt64, offset: Int, payloadStart: Int) {
        self.kind = kind
        self.value = value
        self.offset = offset
        self.payloadStart = payloadStart
    }

    /// Payload byte range for string/json/classDef tokens; empty otherwise.
    public var payloadRange: Range<Int> {
        switch kind {
        case .string, .json, .classDef:
            guard let length = Int(exactly: value) else { return payloadStart..<payloadStart }
            let (end, overflow) = payloadStart.addingReportingOverflow(length)
            return overflow ? payloadStart..<payloadStart : payloadStart..<end
        default: return payloadStart..<payloadStart
        }
    }

    /// `int` as a signed value (`18446744073709551615` -> -1).
    public var intValue: Int { Int(truncatingIfNeeded: value) }
    public var doubleValue: Double { Double(bitPattern: value) }
}

public struct SLFTokenError: Error, Sendable, Equatable {
    public enum Reason: String, Sendable {
        /// The input does not start with `SLF0`.
        case badHeader
        /// A byte that cannot start or end a token.
        case unexpectedByte
        /// The input ends inside a token.
        case truncated
        /// A number that does not fit in 64 bits, or a malformed double.
        case badNumber
    }

    public var reason: Reason
    public var offset: Int

    public init(reason: Reason, offset: Int) {
        self.reason = reason
        self.offset = offset
    }
}

/// Linear byte tokenizer over an inflated SLF log. No regex, no backtracking: each token is a run of hex digits, one
/// type byte, and for strings/json/classDefs a payload skipped by its byte length.
public struct SLFTokenizer: Sendable {
    public static let header: [UInt8] = Array("SLF0".utf8)

    public let bytes: [UInt8]
    /// Offset of the next token.
    public private(set) var position: Int
    /// Set when tokenizing stopped before the end of the input.
    public private(set) var error: SLFTokenError?

    /// Starts after the `SLF0` header; a missing header sets `error` and yields no tokens.
    public init(bytes: [UInt8]) {
        self.bytes = bytes
        if bytes.starts(with: Self.header) {
            position = Self.header.count
        } else {
            position = bytes.count
            error = SLFTokenError(reason: bytes.count < Self.header.count && Self.header.starts(with: bytes)
                                  ? .truncated : .badHeader, offset: 0)
        }
    }

    public var isAtEnd: Bool { position >= bytes.count }

    /// The next token, or nil at the end of the input or on an error (see `error`).
    public mutating func next() -> SLFToken? {
        let n = bytes.count
        let start = position
        guard start < n, error == nil else { return nil }
        if bytes[start] == UInt8(ascii: "-") {
            position = start + 1
            return SLFToken(kind: .null, value: 0, offset: start, payloadStart: start + 1)
        }
        var j = start
        var decimal: UInt64 = 0
        var hex: UInt64 = 0
        var decimalOK = true
        var overflow = false
        while j < n {
            let b = bytes[j]
            let digit: UInt64
            if b >= 0x30 && b <= 0x39 {
                digit = UInt64(b - 0x30)
            } else if b >= 0x61 && b <= 0x66 {
                digit = UInt64(b - 0x61 + 10)
                decimalOK = false
            } else {
                break
            }
            if decimalOK, !overflow {
                let (m, o1) = decimal.multipliedReportingOverflow(by: 10)
                let (s, o2) = m.addingReportingOverflow(digit)
                decimal = s
                overflow = o1 || o2
            }
            hex = hex &<< 4 | digit
            j += 1
        }
        guard j > start else { return fail(.unexpectedByte, at: start) }
        guard j < n else { return fail(.truncated, at: start) }
        let digits = j - start
        let type = bytes[j]
        let afterType = j + 1
        let kind: SLFTokenKind
        var value = decimal
        switch type {
        case UInt8(ascii: "^"):
            guard digits == 16 else { return fail(.badNumber, at: start) }
            kind = .double
            value = hex.byteSwapped
        case UInt8(ascii: "-"):
            kind = .null
            value = 0
        case UInt8(ascii: "#"): kind = .int
        case UInt8(ascii: "\""): kind = .string
        case UInt8(ascii: "*"): kind = .json
        case UInt8(ascii: "%"): kind = .classDef
        case UInt8(ascii: "@"): kind = .classRef
        case UInt8(ascii: "("): kind = .array
        default: return fail(.unexpectedByte, at: j)
        }
        if kind != .double && kind != .null {
            guard decimalOK, !overflow else { return fail(.badNumber, at: start) }
        }
        var end = afterType
        if kind == .string || kind == .json || kind == .classDef {
            guard value <= UInt64(n - afterType) else { return fail(.truncated, at: start) }
            end = afterType + Int(value)
        }
        position = end
        return SLFToken(kind: kind, value: value, offset: start, payloadStart: afterType)
    }

    private mutating func fail(_ reason: SLFTokenError.Reason, at offset: Int) -> SLFToken? {
        error = SLFTokenError(reason: reason, offset: offset)
        return nil
    }

    /// Payload of a string/json/classDef token as UTF-8, invalid sequences replaced with U+FFFD.
    public func string(_ token: SLFToken) -> String { string(token.payloadRange) }

    public func string(_ range: Range<Int>) -> String {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return "" }
        return String(decoding: bytes[range], as: UTF8.self)
    }

    public func data(_ range: Range<Int>) -> Data {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return Data() }
        return Data(bytes[range])
    }

    /// Every token of `bytes`, plus the error that stopped tokenizing, if any.
    public static func tokenize(_ bytes: [UInt8]) -> (tokens: [SLFToken], error: SLFTokenError?) {
        var tokenizer = SLFTokenizer(bytes: bytes)
        var tokens: [SLFToken] = []
        while let token = tokenizer.next() { tokens.append(token) }
        return (tokens, tokenizer.error)
    }
}
