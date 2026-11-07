import Foundation
import XCTest
@testable import XcblameKit

final class SLFDecoderTests: XCTestCase {
    private func summary(_ url: URL, _ log: RawLog, _ model: BuildModel) -> String {
        let counts = RawCounts(log)
        let swift = model.tasks.filter { $0.kind == .swiftCompile }.reduce(0) { $0 + $1.duration }
        return "\(url.deletingLastPathComponent().lastPathComponent)/\(url.lastPathComponent.prefix(8)): "
            + "v\(log.formatVersion.map(String.init) ?? "?") \(log.layout.rawValue) sections=\(counts.sections) "
            + "tasks=\(model.tasks.count) swiftCompile=\(String(format: "%.3f", swift))s "
            + "metricsTasks=\(model.tasks.filter { $0.metrics != nil }.count) "
            + "attachments=\(counts.attachments.values.reduce(0, +)) messages=\(counts.messages) "
            + "diagnostics=\(model.diagnostics.count) warnings=\(log.decodeWarnings.count)"
    }

    /// All 11 fixture logs decode with zero reader warnings; every warning (reader or builder) is printed.
    func testAllFixturesDecodeWithoutErrors() throws {
        let logs = SLFFixtures.allLogs
        XCTAssertEqual(logs.count, 11)
        for url in logs {
            let log = try SLFReader.read(url: url)
            let model = BuildModelBuilder.build(log, reader: .slf)
            print(summary(url, log, model))
            for warning in log.decodeWarnings {
                print("  reader warning \(warning.kind.rawValue) @\(warning.offset ?? -1): \(warning.detail)")
            }
            for warning in model.decodeWarnings.dropFirst(log.decodeWarnings.count) {
                print("  builder warning \(warning.kind.rawValue): \(warning.detail)")
            }
            XCTAssertEqual(log.decodeWarnings, [], url.lastPathComponent)
            XCTAssertFalse(log.isTruncated)
            XCTAssertGreaterThan(log.root.end, log.root.start)
        }
    }

    func testXcode26CleanBuildThroughBuilder() throws {
        let log = try SLFReader.read(url: SLFFixtures.cli26Clean)
        XCTAssertEqual(log.formatVersion, 11)
        XCTAssertEqual(log.layout, .commandLine)
        XCTAssertEqual(log.root.title, "Building project AcmeApp with scheme AcmeApp and configuration Debug")
        XCTAssertEqual(log.root.subsections.count, 579)
        // Manifest timeStartedRecording 815073642.753639 (2001 epoch) -> Unix.
        XCTAssertEqual(log.root.start, 815_073_642.753_639 + 978_307_200, accuracy: 0.001)

        let counts = RawCounts(log)
        XCTAssertEqual(counts.messages, 54)
        XCTAssertEqual(counts.attachments, ["com.apple.dt.ActivityLogSectionAttachment.TaskMetrics": 466])

        let model = BuildModelBuilder.build(log, reader: .slf)
        print(summary(SLFFixtures.cli26Clean, log, model))
        // 577 = 579 depth-1 sections minus `Prepare packages` and `Build Timing Summary` (DESIGN §5.5). The xcresult
        // count of 580 also covers the `Cleaning ...` planning tasks, which SLF writes to a separate log.
        XCTAssertEqual(model.tasks.count, 577)
        // Outermost SwiftCompile sections by their own start/stop doubles: 109.28 s (the xcresult figure, OBS-10).
        let sectionSwift = log.root.subsections.filter { $0.commandDetails?.hasPrefix("SwiftCompile ") == true }
            .reduce(0) { $0 + ($1.end - $1.start) }
        XCTAssertEqual(sectionSwift, 109.28, accuracy: 0.05)
        // The builder prefers TaskMetrics wcDuration (microseconds), reproducing Xcode's summary row (109.343 s).
        let swiftTasks = model.tasks.filter { $0.kind == .swiftCompile }
        XCTAssertEqual(swiftTasks.count, 87)
        XCTAssertEqual(swiftTasks.reduce(0) { $0 + $1.duration }, 109.343, accuracy: 0.001)
        XCTAssertEqual(model.timingSummary?.rows.first { $0.ruleName == "SwiftCompile" }?.seconds, 109.343)
        XCTAssertEqual(model.tasks.filter { $0.metrics != nil }.count, 466)
        // 54 raw messages fold (sub-messages) and dedupe into 7 diagnostics.
        XCTAssertEqual(model.diagnostics.count, 7)
        XCTAssertEqual(model.timingSummary?.rows.count, 22)
        XCTAssertTrue(model.degradations.isEmpty, "\(model.degradations)")
    }

    func testXcode27CleanBuildThroughBuilder() throws {
        let log = try SLFReader.read(url: SLFFixtures.cli27Clean)
        XCTAssertEqual(log.formatVersion, 13)
        XCTAssertEqual(log.layout, .commandLine)
        let counts = RawCounts(log)
        XCTAssertEqual(counts.messages, 57)
        XCTAssertEqual(counts.attachments.values.reduce(0, +), 473)
        let model = BuildModelBuilder.build(log, reader: .slf)
        print(summary(SLFFixtures.cli27Clean, log, model))
        XCTAssertGreaterThan(model.tasks.count, 500)
        XCTAssertEqual(model.tasks.count, 587)
        let swift = model.tasks.filter { $0.kind == .swiftCompile }.reduce(0) { $0 + $1.duration }
        XCTAssertEqual(swift, 116.663, accuracy: 0.001)
        XCTAssertEqual(model.tasks.filter { $0.metrics != nil }.count, 473)
        XCTAssertEqual(model.diagnostics.count, 7)
        // v13 extra ints: resultCode (uncertain position) is 0 on every section of this successful build.
        XCTAssertEqual(log.root.resultCode, 0)
        XCTAssertTrue(model.tasks.allSatisfy { $0.resultCode == 0 })
    }

    func testMessageLocationAndSLFOnlyFields() throws {
        let log = try SLFReader.read(url: SLFFixtures.cli26Clean)
        var found: RawMessage?
        var keyed: RawSection?
        func visit(_ section: RawSection) {
            for message in section.messages where message.title.hasPrefix("Expression took 62ms") { found = message }
            if keyed == nil, section.slfOnly?.xcbuildSignatureHex?.hasPrefix("0050303A") == true { keyed = section }
            section.subsections.forEach(visit)
        }
        visit(log.root)
        let message = try XCTUnwrap(found)
        XCTAssertEqual(message.severity, 1)
        XCTAssertEqual(message.categoryIdent, "Swift Compiler Warning")
        XCTAssertEqual(message.location?.file, "file:///Users/ciuser/Projects/acmeapp/Sources/AcmeApp/StudioView.swift")
        XCTAssertEqual(message.location?.startLine, 393)
        XCTAssertEqual(message.location?.startColumn, 8)
        XCTAssertEqual(message.location?.numberBase, 0)

        let section = try XCTUnwrap(keyed)
        XCTAssertEqual(section.slfOnly?.wasCancelled, false)
        XCTAssertEqual(section.slfOnly?.wasFetchedFromCache, false)
        XCTAssertNotNil(section.slfOnly?.uniqueIdentifier)
        let key = section.slfOnly?.xcbuildSignatureHex.flatMap(BuildModelBuilder.taskKey(fromSignatureHex:))
        XCTAssertEqual(key?.hasPrefix("P0:"), true)
    }

    func testIDEPackageLogs() throws {
        for url in SLFFixtures.logs(in: "ide-xcode26") {
            let log = try SLFReader.read(url: url)
            XCTAssertEqual(log.layout, .ide)
            XCTAssertEqual(log.formatVersion, 11)
            XCTAssertEqual(log.root.title, "Resolve Packages")
            XCTAssertEqual(log.root.domainType, "Xcode.IDEActivityLogDomainType.PackageLog")
            XCTAssertEqual(log.root.subsections.count, 2)
            XCTAssertEqual(log.root.subsections.first?.location?.file?.hasPrefix("x-xcode-log://"), true)
            XCTAssertEqual(log.root.slfOnly?.uniqueIdentifier, String(url.lastPathComponent.prefix(36)))
        }
    }

    func testRejectsNonSLF() {
        XCTAssertThrowsError(try SLFReader.read(data: Data("hello".utf8))) { error in
            XCTAssertEqual(error as? SLFReadError, .notSLF)
        }
    }
}
