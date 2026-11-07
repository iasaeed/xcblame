import Foundation
import XCTest
@testable import XcblameKit

/// Drift recovery (DESIGN §5.4): resync stays at the broken record's array depth, and probing is linear in nesting.
final class SLFDriftRecoveryTests: XCTestCase {
    /// Root -> [batch SwiftCompile 10 s with a 9 s per-file child, Ld 2 s]; the batch's head is corrupted by more
    /// unexpected values than alignment may skip, so only resync can recover (code review v0.1 row 4).
    func testResyncNeverPromotesANestedChild() throws {
        let raw = RawLog.decoded(SLFWriter.log(duration: 30) { w in
            w.section(cd: "SwiftCompile normal arm64 batch", start: 101, duration: 10,
                      head: { w in for _ in 0..<10 { w.json("{}") } },
                      children: { w in
                          w.section(cd: "SwiftCompile normal arm64 a.swift", start: 101.5, duration: 9)
                          return 1
                      })
            w.section(cd: "Ld b", start: 111, duration: 2)
            return 2
        })
        XCTAssertTrue(raw.decodeWarnings.contains { $0.kind == .resync }, "\(raw.decodeWarnings)")
        XCTAssertFalse(raw.decodeWarnings.contains { $0.detail.contains("after the root section") },
                       "siblings must not fall out as trailing tokens: \(raw.decodeWarnings)")
        let model = BuildModelBuilder.build(raw, reader: .slf)
        XCTAssertEqual(model.tasks.map(\.ruleName), ["SwiftCompile", "Ld"])
        XCTAssertEqual(model.tasks.map(\.duration), [10, 2])
        XCTAssertEqual(model.tasks.first?.subspans.count, 1, "the 9 s child stays a sub-span")
        let analysis = Timing.analyze(model)
        XCTAssertEqual(analysis.taskTime, 12, accuracy: 1e-9)
        XCTAssertEqual(Validator.validate(model, analysis: analysis).status("V14").label, "warn")
    }

    /// `depth` sections nested in a chain, each missing its `signature` slot (code review v0.1 row 5).
    func nestedDriftedLog(depth: Int) -> [UInt8] {
        func chain(_ w: inout SLFWriter, _ level: Int) -> Int {
            w.section(cd: "SwiftCompile level\(level)", start: 101, omitSignature: true, children: { w in
                level + 1 < depth ? chain(&w, level + 1) : 0
            })
            return 1
        }
        return SLFWriter.log(duration: 10) { w in chain(&w, 0) }
    }

    func decodeTime(depth: Int) -> (seconds: Double, raw: RawLog) {
        let bytes = nestedDriftedLog(depth: depth)
        let start = Date()
        let raw = SLFDecoder.decode(bytes: bytes)
        return (Date().timeIntervalSince(start), raw)
    }

    func testSixteenLevelDriftedNestingDecodesFast() {
        let (seconds, raw) = decodeTime(depth: 16)
        XCTAssertLessThan(seconds, 0.2)
        XCTAssertEqual(RawCounts(raw).maxDepth, 16)
        XCTAssertTrue(raw.decodeWarnings.contains { $0.kind == .schemaDrift })
    }

    func testFortyLevelDriftedNestingDecodesFast() {
        let (seconds, raw) = decodeTime(depth: 40)
        XCTAssertLessThan(seconds, 0.5)
        XCTAssertGreaterThan(RawCounts(raw).maxDepth, 0)
    }

    /// Arrays nested far beyond any real log are skipped iteratively instead of recursing (stack exhaustion).
    func testDeeplyNestedArraysDoNotRecurse() {
        var bytes = SLFTokenizer.header + Array("11#".utf8)
        bytes += Array(repeating: Array("1(".utf8), count: 200_000).flatMap { $0 } + Array("0(".utf8)
        let raw = SLFDecoder.decode(bytes: bytes)
        XCTAssertFalse(raw.decodeWarnings.isEmpty)
    }
}
