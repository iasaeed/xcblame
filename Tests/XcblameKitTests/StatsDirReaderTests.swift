import XCTest
@testable import XcblameKit

/// `-stats-output-dir` files per MV-6 (docs/research/probes-v0.5.md), on the Xcode 26.0.1 and 27.1 beta fixtures.
final class StatsDirReaderTests: XCTestCase {
    func testFileNamesGiveModuleInputTripleAndJobKind() {
        let compile = StatsDirReader.parseName(
            "stats-1793608454590408-swift-frontend-AcmeApp-StudioView.swift-arm64_apple_macos14.0-o-Onone-2835036085.json")
        XCTAssertEqual(compile?.module, "AcmeApp")
        XCTAssertEqual(compile?.input, "StudioView.swift")
        XCTAssertEqual(compile?.triple, "arm64_apple_macos14.0")
        XCTAssertEqual(compile?.arch, "arm64")
        XCTAssertEqual(compile?.outputType, "o")
        XCTAssertEqual(compile?.optimization, "Onone")
        let scan = StatsDirReader.parseName(
            "stats-1793608450972373-swift-frontend-AcmeApp-all-arm64_apple_macos14.0--Onone-3958402666.json")
        XCTAssertEqual(scan?.input, "all")
        XCTAssertEqual(scan?.outputType, "")
        // A file name with dashes stays whole; anything else is not a stats file.
        XCTAssertEqual(StatsDirReader.parseName(
            "stats-1-swift-frontend-App-My-View.swift-x86_64_apple_ios17.0_simulator-o-O-7.json")?.input, "My-View.swift")
        XCTAssertNil(StatsDirReader.parseName("App-OutputFileMap.json"))
    }

    func testXcode26JobsAndPhasesAreNotSummed() throws {
        let jobs = try StatsDirReader.jobs(in: DeepFixtures.stats26)
        XCTAssertEqual(jobs.map(\.outputType), ["", "o", "swiftmodule"])
        let compile = try XCTUnwrap(jobs.first { $0.isCompile })
        XCTAssertEqual(compile.wall ?? 0, 2.38533353805542, accuracy: 1e-12)
        // `Type checking and Semantic analysis` (1.16583…) wins over the nested `perform-sema` (1.16597…); nothing adds up.
        XCTAssertEqual(compile.typeCheck ?? 0, 1.1658320426940918, accuracy: 1e-12)
        XCTAssertEqual(compile.phases["silGen"] ?? 0, 0.1344001293182373, accuracy: 1e-12)
        XCTAssertEqual(compile.phases["irGen"] ?? 0, 0.2085580825805664, accuracy: 1e-12)
        XCTAssertEqual(compile.phases["silOptimization"] ?? 0, 0.07152628898620605, accuracy: 1e-12)
        XCTAssertNil(compile.phases["silAndLLVM"], "26.0.1 has no SIL-and-LLVM timer")
        // Phases are a selection of nested spans: their sum is no job time and is never used as one.
        XCTAssertLessThan(compile.phases.values.reduce(0, +), compile.wall!)
        let scan = try XCTUnwrap(jobs.first { $0.outputType.isEmpty })
        XCTAssertEqual(scan.wall ?? 0, 0.5017828941345215, accuracy: 1e-12)
        XCTAssertTrue(scan.phases.isEmpty)
    }

    func testXcode27KeysAreReadTheSameWay() throws {
        let jobs = try StatsDirReader.jobs(in: DeepFixtures.stats27)
        let compile = try XCTUnwrap(jobs.first { $0.isCompile })
        XCTAssertEqual(compile.input, "StudioView.swift")
        XCTAssertEqual(compile.wall ?? 0, 2.3156700134277344, accuracy: 1e-12)
        XCTAssertEqual(compile.typeCheck ?? 0, 1.0478787422180176, accuracy: 1e-12)
        XCTAssertEqual(compile.phases["silAndLLVM"] ?? 0, 1.0303101539611816, accuracy: 1e-12)
        let module = try XCTUnwrap(jobs.first { $0.outputType == "swiftmodule" })
        XCTAssertEqual(module.typeCheck ?? 0, 0.37103772163391113, accuracy: 1e-12)
    }

    func testCompileJobsBecomeFileLevelRowsOfTheMatchingTask() throws {
        let fixture = DeepFixtures.model()
        for directory in [DeepFixtures.stats26, DeepFixtures.stats27] {
            let rows = try StatsDirReader.read(directory: directory, model: fixture.model)
            XCTAssertEqual(rows.count, 1, "compile jobs only: \(rows.map(\.declaration))")
            let row = try XCTUnwrap(rows.first)
            XCTAssertEqual(row.file, "/src/AcmeApp/StudioView.swift")
            XCTAssertEqual(row.line, 0)
            XCTAssertEqual(row.col, 0)
            XCTAssertEqual(row.source, "statsDir")
            XCTAssertEqual(row.kind, "file")
            XCTAssertEqual(row.taskId, fixture.perFileTask)
            XCTAssertEqual(row.targetId, 1)
            XCTAssertTrue(row.declaration.hasPrefix("compile job (file, arm64): type-check; frontend "), row.declaration)
        }
        XCTAssertEqual(try StatsDirReader.read(directory: DeepFixtures.stats26, model: fixture.model).first?.ms ?? 0,
                       1165.8320426940918, accuracy: 1e-9)
    }

    func testUnmatchedJobsKeepTheBareNameAndBadJSONThrows() throws {
        let rows = try StatsDirReader.read(directory: DeepFixtures.stats26, model: SyntheticModel.make())
        XCTAssertEqual(rows.map(\.file), ["StudioView.swift"])
        XCTAssertFalse(Hotspots.isUserCode(rows[0].file), "a bare name never passes the user-code filter")

        let dir = try DeepFixtures.scratch(self)
        try Data("[1]".utf8).write(to: dir.appendingPathComponent(
            "stats-1-swift-frontend-App-A.swift-arm64_apple_macos14.0-o-Onone-1.json"))
        try Data("{}".utf8).write(to: dir.appendingPathComponent("unrelated.json"))
        XCTAssertThrowsError(try StatsDirReader.jobs(in: dir))
    }
}
