import Foundation
import XCTest
@testable import XcblameKit

final class SLFRobustnessTests: XCTestCase {
    private func log(_ body: (inout SLFWriter) -> Int) -> RawLog {
        var w = SLFWriter()
        w.int(11)
        w.section("IDECommandLineBuildLog", cd: nil, start: 100, children: body)
        return SLFDecoder.decode(bytes: w.bytes)
    }

    func testCleanSyntheticLog() {
        let raw = log { w in
            w.section(cd: "CompileC a", start: 101)
            w.section(cd: "Ld b", start: 102)
            return 2
        }
        XCTAssertEqual(raw.decodeWarnings, [])
        XCTAssertEqual(raw.root.subsections.map(\.commandDetails), ["CompileC a", "Ld b"])
        XCTAssertEqual(raw.root.subsections[0].start, 101 + 978_307_200)
        XCTAssertEqual(raw.root.subsections[0].end, 102 + 978_307_200)
    }

    func testKnownAlternateRowIsSwitchedSilently() {
        // Xcode 26.2-style extra int before the subtitle (XCLogParser 0.2.45) matches `section.v11-extraInt`.
        let raw = log { w in
            w.section(cd: "CompileC a", start: 101, beforeSubtitle: { $0.int(7) })
            w.section(cd: "Ld b", start: 102)
            return 2
        }
        XCTAssertEqual(raw.decodeWarnings, [])
        XCTAssertEqual(raw.root.subsections.map(\.commandDetails), ["CompileC a", "Ld b"])
    }

    func testUnexpectedSlotIsSkippedWithDriftWarning() {
        let raw = log { w in
            w.section(cd: "CompileC a", start: 101, afterCommand: { $0.dbl(1); $0.int(3) })
            w.section(cd: "Ld b", start: 102, afterCommand: { $0.dbl(1); $0.int(3) })
            return 2
        }
        XCTAssertEqual(raw.root.subsections.map(\.commandDetails), ["CompileC a", "Ld b"])
        XCTAssertEqual(raw.root.subsections.map { $0.slfOnly?.uniqueIdentifier }, ["UUID", "UUID"])
        XCTAssertEqual(raw.decodeWarnings.map(\.kind), [.schemaDrift])
        XCTAssertTrue(raw.decodeWarnings[0].detail.hasSuffix("(x2)"), raw.decodeWarnings[0].detail)
    }

    func testUnknownLocationSubclassIsAlignedAndWarnedOnce() {
        let raw = log { w in
            for (i, cd) in ["CompileC a", "Ld b"].enumerated() {
                w.section(cd: cd, start: 101 + Double(i), location: { w in
                    w.obj("FancyDocumentLocation"); w.str("file:///x"); w.dbl(0); w.int(1); w.int(2)
                })
            }
            return 2
        }
        XCTAssertEqual(raw.root.subsections.map(\.commandDetails), ["CompileC a", "Ld b"])
        XCTAssertEqual(raw.root.subsections.first?.location?.file, "file:///x")
        XCTAssertEqual(raw.decodeWarnings.filter { $0.kind == .unknownClass }.count, 1)
        XCTAssertEqual(raw.decodeWarnings.filter { $0.kind == .unknownClass }.first?.detail.hasSuffix("(x2)"), true)
    }

    func testOpaqueSiblingIsSkipped() {
        let raw = log { w in
            w.section(cd: "CompileC a", start: 101)
            w.obj("MysteryThing"); w.int(1); w.str("payload")
            w.section(cd: "Ld b", start: 102)
            return 3
        }
        XCTAssertEqual(raw.root.subsections.map(\.commandDetails), ["CompileC a", "Ld b"])
        XCTAssertEqual(raw.decodeWarnings.first?.kind, .unknownClass)
        XCTAssertFalse(raw.isTruncated)
    }

    // MARK: Truncation

    func testTruncatedGzipYieldsPartialTree() throws {
        let data = try Data(contentsOf: SLFFixtures.cli26Clean)
        let full = try GzipFile.inflate(data).bytes
        var cuts = [0.25, 0.5, 0.75, 0.99].map { Int(Double(data.count) * $0) }
        // A cut whose inflated bytes end inside a token (the tokenizer reports `truncated` mid-token).
        let midToken = try XCTUnwrap(stride(from: data.count * 3 / 5, to: data.count, by: 997).first { cut in
            let bytes = (try? GzipFile.inflate(data.prefix(cut)).bytes) ?? []
            let error = SLFTokenizer.tokenize(bytes).error
            return error?.reason == .truncated && (error?.offset ?? 0) < bytes.count
        })
        cuts.append(midToken)
        var previous = -1
        for cut in cuts {
            let raw = try SLFReader.read(data: data.prefix(cut))
            let counts = RawCounts(raw)
            print("cut \(cut)/\(data.count): sections=\(counts.sections) warnings=\(raw.decodeWarnings.map(\.detail))")
            XCTAssertTrue(raw.isTruncated, "cut \(cut)")
            XCTAssertEqual(raw.formatVersion, 11)
            XCTAssertEqual(raw.root.title, "Building project AcmeApp with scheme AcmeApp and configuration Debug")
            XCTAssertGreaterThan(raw.root.subsections.count, 0)
            XCTAssertLessThan(raw.root.subsections.count, 579)
            if cut != midToken {
                XCTAssertGreaterThanOrEqual(counts.sections, previous)
                previous = counts.sections
            }
            _ = BuildModelBuilder.build(raw, reader: .slf)
        }
        XCTAssertGreaterThan(full.count, 0)
    }

    func testTruncatedInflatedBytesAtEveryTokenKind() throws {
        let bytes = try SLFFixtures.inflated(SLFFixtures.cli26Clean)
        let tokens = SLFTokenizer.tokenize(bytes).tokens
        for kind in SLFTokenKind.allCases {
            guard let token = tokens.dropFirst(10).first(where: { $0.kind == kind }) else { continue }
            let end = token.payloadRange.isEmpty ? token.payloadStart - 1 : token.payloadStart + Int(token.value) / 2
            for cut in Set([token.offset + 1, max(end, token.offset + 1)]) {
                let raw = try SLFReader.read(data: Data(bytes.prefix(cut)))
                XCTAssertTrue(raw.isTruncated, "\(kind) cut \(cut)")
                XCTAssertEqual(raw.layout, .commandLine)
            }
        }
    }

    // MARK: Integer overflow (code review v0.1 row 6; these trapped with exit 133)

    func testHugeFormatVersionIsRejectedNotTrapped() {
        let raw = SLFDecoder.decode(bytes: Array("SLF09223372036854775808#22%IDECommandLineBuildLog1@0#".utf8))
        XCTAssertNil(raw.formatVersion)
        XCTAssertTrue(raw.decodeWarnings.contains { $0.detail.contains("out of range") }, "\(raw.decodeWarnings)")
    }

    func testHugeClassRefDoesNotTrap() {
        let raw = SLFDecoder.decode(bytes: Array("SLF011#9223372036854775808@18446744073709551615@".utf8))
        XCTAssertEqual(raw.formatVersion, 11)
        XCTAssertFalse(raw.decodeWarnings.isEmpty)
    }

    func testHugeLineNumbersBecomeNil() throws {
        let location = RawLocation(file: "/a.swift", startLine: .max, startColumn: Int.max - 1, endLine: -5,
                                   endColumn: 3, numberBase: 0)
        let raw = RawLog(layout: .commandLine, root: RawSection(
            domainType: Locator.buildLogDomain, messages: [RawMessage(title: "w", severity: 1, location: location)]))
        let diagnostic = try XCTUnwrap(BuildModelBuilder.build(raw, reader: .slf).diagnostics.first)
        XCTAssertNil(diagnostic.line)
        XCTAssertNil(diagnostic.column)
        XCTAssertNil(diagnostic.endLine)
        XCTAssertEqual(diagnostic.endColumn, 4)

        let json = #"{"title":"Build","domainType":"Xcode.IDEActivityLogDomainType.BuildLog","messages":[{"title":"w","#
            + #""type":"warning","location":{"url":"file:///a.swift#StartingLineNumber=9223372036854775807&"#
            + #"StartingColumnNumber=1"}}]}"#
        let xc = BuildModelBuilder.build(try XCResultReader.read(jsonData: Data(json.utf8)), reader: .xcresult)
        XCTAssertNil(xc.diagnostics.first?.line)
        XCTAssertEqual(xc.diagnostics.first?.column, 2)
    }

    func testHugeTimingSummaryCountsDoNotTrap() {
        let rows = (0..<12).map { _ in TimingSummary.Row(ruleName: "Ld", taskCount: 999_999_999_999_999_999, seconds: 1) }
        let model = TestModels.model([TestModels.task(0, "Ld", kind: .link, start: 100, end: 101)],
                                     timingSummary: TimingSummary(rows: rows))
        XCTAssertEqual(TestModels.validate(model).status("V5").label, "warn")
        XCTAssertNil(BuildModelBuilder.parseTimingRow("Ld (9223372036854775808 tasks) | 1.0 seconds"))
        XCTAssertNil(BuildModelBuilder.parseTimingRow("Ld (1234567890123456789 tasks) | 1.0 seconds"))
    }

    /// Re-check N1: an array count of 2^64-1 below the array-depth cap saturates the structural skip; the next class
    /// ref (a known class with slots) used to overflow it and trap.
    func testSaturatedStructuralSkipThenClassRefDoesNotTrap() {
        var bytes = Array("SLF011#22%IDECommandLineBuildLog".utf8)
        bytes += Array(repeating: Array("1(".utf8), count: 140).flatMap { $0 }
        bytes += Array("18446744073709551615(1@0#".utf8)
        let raw = SLFDecoder.decode(bytes: bytes)
        XCTAssertTrue(raw.decodeWarnings.contains { $0.detail.contains("arrays nested deeper") }, "\(raw.decodeWarnings)")
    }
}
