import XCTest
@testable import XcblameKit

/// Build-level cache counters and per-task replay (docs/research/probes-v0.5.md MV-12) on the cache fixtures: a miss
/// build, a clean action, then a hit build in one DerivedData with compilation caching on.
final class CacheMetricsTests: XCTestCase {
    static let hit26 = SLFFixtures.root.appendingPathComponent(
        "cli-xcode26-cache/A7E5A79E-C4B5-4382-95EF-293E9E26150B.xcactivitylog")
    static let miss26 = SLFFixtures.root.appendingPathComponent(
        "cli-xcode26-cache/9D04F025-6076-4B13-B320-8134D90E7788.xcactivitylog")
    static let hit27 = SLFFixtures.root.appendingPathComponent(
        "cli-xcode27.1b-cache/134650AC-4CC4-4EAC-830F-C184D8A237A0.xcactivitylog")
    static let miss27 = SLFFixtures.root.appendingPathComponent(
        "cli-xcode27.1b-cache/63AF8C68-6671-4504-A4B9-68492EC26B69.xcactivitylog")

    private func xcresult(_ dir: String) throws -> BuildModel {
        let url = SLFFixtures.root.appendingPathComponent("\(dir)/xcresult-buildlog-clean2.json.gz")
        return BuildModelBuilder.build(try XCResultReader.read(jsonData: Data(try GzipFile.inflate(contentsOf: url).bytes)),
                                       reader: .xcresult)
    }

    private func cache(_ model: BuildModel) -> ReportDocument.BuildCache? {
        CacheMetrics.compute(model: model, counted: Timing.timeline(model).counted)
    }

    func testDecodesTheLegacyFlatShapeWithZeros() throws {
        let counters = try XCTUnwrap(CacheMetrics.decode(Data(
            #"{"clangCacheHits":13,"clangCacheMisses":0,"swiftCacheHits":99,"swiftCacheMisses":0}"#.utf8)))
        XCTAssertEqual(counters.hits, 112)
        XCTAssertEqual(counters.misses, 0)
        XCTAssertTrue(counters.byRule.isEmpty)
    }

    func testDecodesThe27ShapeWithZeroKeysOmitted() throws {
        let json = #"{"counters":{"clangCacheMisses":14,"swiftCacheMisses":250},"taskCounters":{"CompileC":{"cacheMisses":1},"#
            + #""SwiftCompile":{"cacheMisses":87},"SwiftExplicitDependencyGeneratePcm":{"cacheHits":2,"cacheMisses":149}}}"#
        let counters = try XCTUnwrap(CacheMetrics.decode(Data(json.utf8)))
        XCTAssertEqual(counters.hits, 0)
        XCTAssertEqual(counters.misses, 264)
        XCTAssertEqual(counters.byRule["SwiftCompile"]?.misses, 87)
        XCTAssertEqual(counters.byRule["SwiftCompile"]?.hits, 0)
        XCTAssertEqual(counters.byRule["SwiftExplicitDependencyGeneratePcm"]?.hits, 2)
        // Caching on with nothing cacheable: the 27.1 shape with every key omitted still says "caching on".
        XCTAssertEqual(CacheMetrics.decode(Data(#"{"counters":{}}"#.utf8))?.hits, 0)
        XCTAssertNil(CacheMetrics.decode(Data(#"{"wcStartTime":1}"#.utf8)))
        XCTAssertNil(CacheMetrics.decode(Data("not json".utf8)))
    }

    func testXcode26FixturesMatchTheProbe() throws {
        let hit = try GraphFixtures.model(Self.hit26)
        XCTAssertEqual(cache(hit), .init(hits: 112, misses: 0, replayedTasks: 112, replayedTasksHeuristic: nil,
                                         source: "buildOperationMetrics"))
        let replay = CacheMetrics.replay(hit)
        XCTAssertEqual(replay.hits, 112, "13 clang + 99 swift, each with the output line Cache hit")
        XCTAssertEqual(replay.misses, 0)
        XCTAssertEqual(replay.hitsByRule, ["SwiftCompile": 87, "PrecompileModule": 12, "SwiftEmitModule": 9,
                                           "SwiftExplicitDependencyGeneratePcm": 3, "CompileC": 1])
        let miss = try GraphFixtures.model(Self.miss26)
        XCTAssertEqual(cache(miss), .init(hits: 0, misses: 252, replayedTasks: 0, replayedTasksHeuristic: nil,
                                          source: "buildOperationMetrics"))
        XCTAssertEqual(CacheMetrics.replay(miss).misses, 252)
    }

    func testXcode27FixturesMatchTheProbe() throws {
        let hit = try GraphFixtures.model(Self.hit27)
        XCTAssertEqual(cache(hit)?.hits, 113, "counters: 14 clang + 99 swift")
        XCTAssertEqual(cache(hit)?.misses, 0)
        // One SwiftCompile counted as a hit prints no "Cache hit" line: per task 112 of the 113.
        XCTAssertEqual(CacheMetrics.replay(hit).hits, 112)
        XCTAssertEqual(CacheMetrics.counters(hit)?.byRule["SwiftCompile"]?.hits, 87)
        let miss = try GraphFixtures.model(Self.miss27)
        XCTAssertEqual(cache(miss)?.hits, 0)
        XCTAssertEqual(cache(miss)?.misses, 264)
    }

    func testXCResultBuildLogsCarryTheSameCounters() throws {
        XCTAssertEqual(cache(try xcresult("cli-xcode26-cache"))?.hits, 112)
        XCTAssertEqual(CacheMetrics.replay(try xcresult("cli-xcode26-cache")).hits, 112)
        XCTAssertEqual(cache(try xcresult("cli-xcode27.1b-cache"))?.hits, 113)
    }

    func testABuildWithoutCachingHasNoCacheAndANote() throws {
        let model = try GraphFixtures.model(GraphFixtures.clean26)
        XCTAssertNil(cache(model))
        let document = try GraphFixtures.report(model).document
        XCTAssertNil(document.build.cache)
        XCTAssertTrue(document.build.notes.contains { $0.hasPrefix("cache: null because") }, "\(document.build.notes)")
        XCTAssertFalse(document.notes.contains { $0.contains("not produced yet: fixedCosts") })
    }

    func testOutputLinesAloneGiveCASRemarks() throws {
        var model = SyntheticModel.make()
        model.tasks[10].emittedOutput = "Cache hit\r"
        model.tasks[11].emittedOutput = "Cache miss\n"
        model.tasks[12].emittedOutput = "error: Cache hit is not this line"
        XCTAssertEqual(cache(model), .init(hits: 1, misses: 1, replayedTasks: 1, replayedTasksHeuristic: nil,
                                           source: "casRemarks"))
        XCTAssertTrue(CacheMetrics.replayNote(model)?.hasPrefix("cache: 1 task(s) replayed") ?? false)
        XCTAssertNil(CacheMetrics.replayNote(SyntheticModel.make()))
    }

    func testTheHitBuildReportIsCachedWithTheReplayNote() throws {
        let document = try GraphFixtures.report(try GraphFixtures.model(Self.hit26)).document
        XCTAssertEqual(document.build.kind, "cached")
        XCTAssertEqual(document.build.kindEvidence.first, "BuildOperationMetrics: 112 cache hit(s), 0 miss(es)")
        XCTAssertEqual(document.build.cache?.hits, 112)
        XCTAssertNil(document.build.cache?.replayedTasksHeuristic)
        XCTAssertTrue(document.build.notes.contains { $0.hasPrefix("cache: 112 task(s) replayed") }, "\(document.build.notes)")
        XCTAssertEqual(document.validation.checks.first { $0.id == "V11" }?.status, "pass")
        let miss = try GraphFixtures.report(try GraphFixtures.model(Self.miss26)).document
        XCTAssertEqual(miss.build.kind, "clean", "misses only: a clean build that filled the cache")
        XCTAssertEqual(miss.build.cache?.replayedTasks, 0, "252 Cache miss lines, no hit")
        XCTAssertEqual(document.build.cache?.replayedTasks, 112, "exact: 112 Cache hit lines (13 clang + 99 swift)")
    }

    /// v0.5 integration (DESIGN §6.7): the 27.1 hit build counts 113 hits but prints 112 `Cache hit` lines.
    func testXcode27HitBuildKeepsTheExactReplayCountAndNotesTheUnmatchedHit() throws {
        let document = try GraphFixtures.report(try GraphFixtures.model(Self.hit27)).document
        XCTAssertEqual(document.build.kind, "cached")
        XCTAssertEqual(document.build.cache?.hits, 113)
        XCTAssertEqual(document.build.cache?.replayedTasks, 112)
        XCTAssertNil(document.build.cache?.replayedTasksHeuristic, "never the heuristic when the exact count exists")
        XCTAssertEqual(document.build.cache?.source, "buildOperationMetrics")
        let v11 = try XCTUnwrap(document.validation.checks.first { $0.id == "V11" })
        XCTAssertEqual(v11.status, "pass")
        XCTAssertTrue(v11.detail?.contains("112 replayed task(s) (1 counted hit(s) without a matching task line)") == true, "\(v11)")
        XCTAssertTrue(document.build.kindEvidence.contains("task output \"Cache hit\": 112 replayed task(s) (1 counted hit(s) "
            + "without a matching task line)"), "\(document.build.kindEvidence)")
    }

    /// Code review v0.5: `Cache hit` / `Cache miss` count only on cacheable tasks; a script that prints the line is
    /// no replay.
    func testOnlyCacheableTasksCountAsReplayed() {
        var mini = WhyFixtures.Mini()
        mini.task("SwiftCompile", target: "Core", title: "Compiling A.swift", output: "Cache hit\r")
        mini.task("CompileC", target: "Core", title: "Compile B.m", output: "Cache miss")
        mini.task("PhaseScriptExecution", target: "App", title: "Run custom shell script 'Echo'", output: "Cache hit")
        mini.task("PhaseScriptExecution", target: "App", title: "Run custom shell script 'Echo2'", output: "Cache miss")
        let replay = CacheMetrics.replay(mini.model())
        XCTAssertEqual(replay.hits, 1)
        XCTAssertEqual(replay.misses, 1)
        XCTAssertEqual(replay.hitsByRule, ["SwiftCompile": 1])
    }
}
