import XCTest
@testable import XcblameKit

/// clang `-ftime-trace` per MV-7: the trace sits next to the `.o`, the flag hides in a response file, and the
/// "dumped to" line is never printed.
final class FTimeTraceReaderTests: XCTestCase {
    func testSummaryOfTheXcode26Trace() throws {
        let summary = try FTimeTraceReader.summarize(Data(contentsOf: DeepFixtures.trace26))
        XCTAssertEqual(summary.frontendMs ?? 0, 3.059, accuracy: 1e-9)
        XCTAssertEqual(summary.backendMs ?? 0, 1.392, accuracy: 1e-9)
        XCTAssertEqual(summary.totalMs ?? 0, 9.313, accuracy: 1e-9)
        // `Source` comes as a `b`/`e` pair (4441 → 5285 µs).
        XCTAssertEqual(summary.includes.count, 1)
        XCTAssertTrue(summary.includes[0].path.hasSuffix("/usr/include/stdlib.h"), summary.includes[0].path)
        XCTAssertEqual(summary.includes[0].ms, 0.844, accuracy: 1e-9)
        XCTAssertEqual(summary.instantiationMs, 0)
    }

    func testSummaryOfTheXcode27Trace() throws {
        let summary = try FTimeTraceReader.summarize(Data(contentsOf: DeepFixtures.trace27))
        XCTAssertEqual(summary.frontendMs ?? 0, 3.169, accuracy: 1e-9)
        XCTAssertEqual(summary.totalMs ?? 0, 12.010, accuracy: 1e-9, "the Total event wins over the X event (12011 µs)")
        XCTAssertEqual(summary.includes.first?.ms ?? 0, 0.979, accuracy: 1e-9)
    }

    func testCompleteEventsAndInstantiationsAreAggregated() throws {
        let trace = """
        {"traceEvents":[
          {"ph":"X","name":"Source","ts":0,"dur":4000,"args":{"detail":"/src/A.h"}},
          {"ph":"X","name":"Source","ts":5000,"dur":1000,"args":{"detail":"/src/A.h"}},
          {"ph":"X","name":"InstantiateFunction","ts":0,"dur":2500,"args":{"detail":"std::sort<int*>"}},
          {"ph":"X","name":"InstantiateClass","ts":0,"dur":500,"args":{"detail":"std::vector<int>"}},
          {"ph":"X","name":"Frontend","ts":0,"dur":9000},
          {"ph":"M","name":"process_name","args":{"name":"clang"}}
        ]}
        """
        let summary = try FTimeTraceReader.summarize(Data(trace.utf8))
        XCTAssertEqual(summary.includes.map(\.path), ["/src/A.h"])
        XCTAssertEqual(summary.includes[0].ms, 5, accuracy: 1e-9)
        XCTAssertEqual(summary.instantiations.map(\.name), ["std::sort<int*>", "std::vector<int>"])
        XCTAssertEqual(summary.instantiationMs, 3, accuracy: 1e-9)
        XCTAssertEqual(summary.frontendMs ?? 0, 9, accuracy: 1e-9)
        XCTAssertThrowsError(try FTimeTraceReader.summarize(Data("{}".utf8)))
    }

    func testTheFlagLivesInTheResponseFileNotOnTheCommandLine() throws {
        // MV-7: Xcode moves `-ftime-trace` into `<hash>-common-args.resp`; the CompileC command line shows only `@…resp`,
        // so the reader keys on the object file, never on the flag or a "dumped to" line.
        let resp = try String(contentsOf: DeepFixtures.commonArgs26, encoding: .utf8)
        XCTAssertTrue(resp.contains("-ftime-trace '-ftime-trace-granularity=500'"))
        let fixture = DeepFixtures.model()
        let task = fixture.model.tasks[fixture.clangTask]
        XCTAssertFalse(task.commandDetails!.contains("-ftime-trace"))
        XCTAssertEqual(FTimeTraceReader.objectFile(of: task), "/dd/Objects-normal/arm64/Bridge.o")
        XCTAssertEqual(FTimeTraceReader.traceURL(forObject: "/dd/Objects-normal/arm64/Bridge.o").path,
                       "/dd/Objects-normal/arm64/Bridge.json")
    }

    func testRowsPerTranslationUnitAndNotesForMissingTraces() throws {
        let dir = try DeepFixtures.scratch(self)
        let object = dir.appendingPathComponent("Objects-normal/arm64/Bridge.o")
        try FileManager.default.createDirectory(at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: DeepFixtures.trace26, to: FTimeTraceReader.traceURL(forObject: object.path))
        let fixture = DeepFixtures.model(object: object.path)
        let counted = Timing.timeline(fixture.model).counted
        var notes: [String] = []
        let rows = try FTimeTraceReader.read(counted: counted, model: fixture.model, notes: &notes)
        XCTAssertEqual(rows.map(\.kind), ["frontend", "include"])
        XCTAssertEqual(rows[0].file, "/src/App/Bridge.m")
        XCTAssertEqual(rows[0].ms, 3.059, accuracy: 1e-9)
        XCTAssertEqual(rows[0].source, "ftimeTrace")
        XCTAssertEqual(rows[0].taskId, fixture.clangTask)
        XCTAssertEqual(rows[1].declaration, "included from Bridge.m")
        XCTAssertTrue(rows.allSatisfy { $0.line == 0 && $0.col == 0 })
        XCTAssertTrue(notes.isEmpty, "\(notes)")

        // No trace: a cache hit is named as such (MV-7), anything else as missing.
        var missing = DeepFixtures.model(object: dir.appendingPathComponent("none/Bridge.o").path)
        notes = []
        XCTAssertTrue(try FTimeTraceReader.read(counted: Timing.timeline(missing.model).counted, model: missing.model,
                                                notes: &notes).isEmpty)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].contains("no trace next to the object file of 1 of 1"), notes[0])
        missing.model.tasks[missing.clangTask].emittedOutput = "Cache hit\r"
        notes = []
        _ = try FTimeTraceReader.read(counted: Timing.timeline(missing.model).counted, model: missing.model, notes: &notes)
        XCTAssertTrue(notes[0].contains("compilation-cache hits and wrote no trace"), notes[0])
    }

    /// Code review v0.5: the deep DerivedData persists, so a trace next to the object may be an earlier build's.
    /// A cache hit never reads it, a trace older than the build start is ignored, and an oversized one is not parsed.
    func testCacheHitsStaleAndOversizedTracesAreNotRead() throws {
        let dir = try DeepFixtures.scratch(self)
        let object = dir.appendingPathComponent("Objects-normal/arm64/Bridge.o")
        try FileManager.default.createDirectory(at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
        let trace = FTimeTraceReader.traceURL(forObject: object.path)
        try FileManager.default.copyItem(at: DeepFixtures.trace26, to: trace)
        var fixture = DeepFixtures.model(object: object.path)
        func read() throws -> (rows: [HotspotValue], notes: [String]) {
            var notes: [String] = []
            let rows = try FTimeTraceReader.read(counted: Timing.timeline(fixture.model).counted, model: fixture.model,
                                                 notes: &notes)
            return (rows, notes)
        }
        fixture.model.tasks[fixture.clangTask].emittedOutput = "Cache hit\r"
        let hit = try read()
        XCTAssertTrue(hit.rows.isEmpty, "the trace of an earlier miss is not this build's")
        XCTAssertTrue(hit.notes.first?.contains("compilation-cache hits") == true, "\(hit.notes)")

        fixture.model.tasks[fixture.clangTask].emittedOutput = nil
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: fixture.model.sessionStart - 3_600)],
                                              ofItemAtPath: trace.path)
        let stale = try read()
        XCTAssertTrue(stale.rows.isEmpty)
        XCTAssertTrue(stale.notes.contains { $0.contains("older than this build") }, "\(stale.notes)")

        let handle = try FileHandle(forWritingTo: trace)
        try handle.truncate(atOffset: UInt64(FTimeTraceReader.maxTraceBytes + 1))
        try handle.close()
        let big = try read()
        XCTAssertTrue(big.rows.isEmpty)
        XCTAssertTrue(big.notes.contains { $0.contains("over 64 MB not read") }, "\(big.notes)")
    }
}
