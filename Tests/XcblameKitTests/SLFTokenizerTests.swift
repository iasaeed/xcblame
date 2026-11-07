import Foundation
import XCTest
@testable import XcblameKit

final class SLFTokenizerTests: XCTestCase {
    // Counts from `python3 tools/slftok.py <inflated log>` (18,735 for v11, 20,564 for v13; classDefs included).
    func testTokenCountsMatchPrototype() throws {
        for (url, expected) in [(SLFFixtures.cli26Clean, 18_735), (SLFFixtures.cli27Clean, 20_564)] {
            let result = SLFTokenizer.tokenize(try SLFFixtures.inflated(url))
            XCTAssertNil(result.error, url.lastPathComponent)
            XCTAssertEqual(result.tokens.count, expected, url.lastPathComponent)
            XCTAssertEqual(result.tokens.filter { $0.kind == .classDef }.count, 7)
        }
    }

    func testV11TokenKindHistogram() throws {
        let tokens = SLFTokenizer.tokenize(try SLFFixtures.inflated(SLFFixtures.cli26Clean)).tokens
        var histogram: [SLFTokenKind: Int] = [:]
        for token in tokens { histogram[token.kind, default: 0] += 1 }
        // slftok.py: int 4219, cls 7, inst 1484, str 5489, dbl 1728, arr 930, null 4412, json 466.
        XCTAssertEqual(histogram, [.int: 4219, .classDef: 7, .classRef: 1484, .string: 5489, .double: 1728,
                                   .array: 930, .null: 4412, .json: 466])
    }

    func testScalarsDecode() {
        let bytes = Array("SLF011#22%IDECommandLineBuildLog1@3e7760b5844ac841^4\"h\u{e9}!-2(18446744073709551615#".utf8)
        let (tokens, error) = SLFTokenizer.tokenize(bytes)
        XCTAssertNil(error)
        XCTAssertEqual(tokens.map(\.kind), [.int, .classDef, .classRef, .double, .string, .null, .array, .int])
        XCTAssertEqual(tokens[0].value, 11)
        let tokenizer = SLFTokenizer(bytes: bytes)
        XCTAssertEqual(tokenizer.string(tokens[1]), "IDECommandLineBuildLog")
        XCTAssertEqual(tokens[2].value, 1)
        // 0x41c84a84b560773e: 2001-epoch seconds of the v11 clean build start.
        XCTAssertEqual(tokens[3].doubleValue, 815_073_642.753, accuracy: 0.001)
        XCTAssertEqual(tokenizer.string(tokens[4]), "h\u{e9}!")
        XCTAssertEqual(tokens[6].value, 2)
        XCTAssertEqual(tokens[7].intValue, -1)
    }

    func testInvalidUTF8IsReplaced() {
        var bytes = Array("SLF03\"".utf8)
        bytes += [0x61, 0xff, 0x62]
        let (tokens, error) = SLFTokenizer.tokenize(bytes)
        XCTAssertNil(error)
        XCTAssertEqual(SLFTokenizer(bytes: bytes).string(tokens[0]), "a\u{fffd}b")
    }

    func testErrors() {
        XCTAssertEqual(SLFTokenizer.tokenize(Array("XLF011#".utf8)).error?.reason, .badHeader)
        XCTAssertEqual(SLFTokenizer.tokenize(Array("SL".utf8)).error?.reason, .truncated)
        let truncatedString = SLFTokenizer.tokenize(Array("SLF011#10\"abc".utf8))
        XCTAssertEqual(truncatedString.tokens.count, 1)
        XCTAssertEqual(truncatedString.error, SLFTokenError(reason: .truncated, offset: 7))
        XCTAssertEqual(SLFTokenizer.tokenize(Array("SLF011".utf8)).error?.reason, .truncated)
        XCTAssertEqual(SLFTokenizer.tokenize(Array("SLF0abc#".utf8)).error?.reason, .badNumber)
        XCTAssertEqual(SLFTokenizer.tokenize(Array("SLF0abc^".utf8)).error?.reason, .badNumber)
        XCTAssertEqual(SLFTokenizer.tokenize(Array("SLF012!".utf8)).error, SLFTokenError(reason: .unexpectedByte, offset: 6))
        XCTAssertEqual(SLFTokenizer.tokenize(Array("SLF0 ".utf8)).error?.reason, .unexpectedByte)
        XCTAssertEqual(SLFTokenizer.tokenize(Array("SLF099999999999999999999#".utf8)).error?.reason, .badNumber)
    }

    // MARK: Round trip

    private enum Generated: Equatable {
        case int(UInt64), double(UInt64), string([UInt8]), json([UInt8]), classDef(String), classRef(UInt64)
        case array(UInt64), null
    }

    private func encode(_ tokens: [Generated]) -> [UInt8] {
        var out = SLFTokenizer.header
        for token in tokens {
            switch token {
            case let .int(v): out += Array("\(v)#".utf8)
            case let .double(bits):
                out += Array(String(format: "%016llx", bits.byteSwapped).utf8) + [UInt8(ascii: "^")]
            case let .string(b): out += Array("\(b.count)\"".utf8) + b
            case let .json(b): out += Array("\(b.count)*".utf8) + b
            case let .classDef(name): out += Array("\(name.utf8.count)%".utf8) + Array(name.utf8)
            case let .classRef(v): out += Array("\(v)@".utf8)
            case let .array(v): out += Array("\(v)(".utf8)
            case .null: out.append(UInt8(ascii: "-"))
            }
        }
        return out
    }

    private func decode(_ token: SLFToken, _ tokenizer: SLFTokenizer) -> Generated {
        let payload = Array(tokenizer.bytes[token.payloadRange])
        switch token.kind {
        case .int: return .int(token.value)
        case .double: return .double(token.value)
        case .string: return .string(payload)
        case .json: return .json(payload)
        case .classDef: return .classDef(tokenizer.string(token))
        case .classRef: return .classRef(token.value)
        case .array: return .array(token.value)
        case .null: return .null
        }
    }

    func testRoundTripOfGeneratedStreams() {
        var rng = SplitMix64(seed: 0x5EED)
        // Payload bytes include the token delimiters, digits, CR, LF and NUL.
        let alphabet = Array("0123456789abcdef#^\"*%@(-\r\n\u{0} xyz".utf8) + [0xc3, 0xa9, 0xff]
        for _ in 0..<200 {
            var tokens: [Generated] = []
            for _ in 0..<Int(rng.next() % 64) {
                let payload = (0..<Int(rng.next() % 24)).map { _ in alphabet[Int(rng.next() % UInt64(alphabet.count))] }
                switch rng.next() % 8 {
                case 0: tokens.append(.int(rng.next() >> (rng.next() % 64)))
                case 1: tokens.append(.double(rng.next()))
                case 2: tokens.append(.string(payload))
                case 3: tokens.append(.json(payload))
                case 4: tokens.append(.classDef("Class\(rng.next() % 100)"))
                case 5: tokens.append(.classRef(rng.next() % 40))
                case 6: tokens.append(.array(rng.next() % 1000))
                default: tokens.append(.null)
                }
            }
            let bytes = encode(tokens)
            let (decoded, error) = SLFTokenizer.tokenize(bytes)
            XCTAssertNil(error)
            let tokenizer = SLFTokenizer(bytes: bytes)
            XCTAssertEqual(decoded.map { decode($0, tokenizer) }, tokens)
        }
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
