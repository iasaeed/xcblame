import XCTest
@testable import XcblameKit

final class ReportersTextTests: XCTestCase {
    private func document(topN: Int = 5, path: String? = "synthetic") throws -> ReportDocument {
        try ReportPipeline.run(SyntheticModel.make(), options: .init(
            topN: topN, generatedAt: ReportersJSONTests.date, inputPath: path)).document
    }

    func testSnapshotOnSyntheticModel() throws {
        let text = TextReporter.render(try document())
        XCTAssertEqual(text, expectedSnapshot)
    }

    func testNoAnsiWithoutColorsAndAnsiWithColors() throws {
        let doc = try document()
        XCTAssertFalse(TextReporter.render(doc, colors: false).contains("\u{1B}["))
        let colored = TextReporter.render(doc, colors: true)
        XCTAssertTrue(colored.contains("\u{1B}[1m"))
        XCTAssertEqual(colored.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression),
                       TextReporter.render(doc, colors: false))
    }

    func testEnvironmentLinesOnlyWhenCaptured() throws {
        XCTAssertFalse(TextReporter.render(try document()).contains("  env "))
        var env = EnvSnapshot()
        env.macOSProductVersion = "26.0"
        env.logicalCPUCount = 10
        env.xcodebuildVersion = "Xcode 26.0.1\nBuild version 17A400"
        let doc = try ReportPipeline.run(SyntheticModel.make(), options: .init(
            generatedAt: ReportersJSONTests.date, environment: env)).document
        let text = TextReporter.render(doc)
        XCTAssertTrue(text.contains("  env     macOS 26.0 · 10 CPUs (this machine, now)"), text)
        XCTAssertTrue(text.contains("selected Xcode 26.0.1"), text)
    }

    func testDurationFormatting() {
        XCTAssertEqual(TextReporter.duration(0.845), "845 ms")
        XCTAssertEqual(TextReporter.duration(12.34), "12.3 s")
        XCTAssertEqual(TextReporter.duration(1.0), "1.0 s")
        XCTAssertEqual(TextReporter.duration(0), "0 ms")
        XCTAssertEqual(TextReporter.duration(0.9996), "1.0 s")
    }

    func testEveryNumberComesFromTheDocument() throws {
        let doc = try document()
        let text = TextReporter.render(doc)
        XCTAssertTrue(text.contains("task time \(TextReporter.duration(try XCTUnwrap(doc.build.taskTime))) in \(doc.build.tasks) tasks"))
        XCTAssertTrue(text.contains("log span \(TextReporter.duration(try XCTUnwrap(doc.build.span)))"))
        for row in try XCTUnwrap(doc.targets) {
            XCTAssertTrue(text.contains(TextReporter.duration(row.taskTime)), row.name)
        }
    }

    func testCappedTargetsStateRowsAndShownShare() throws {
        let text = TextReporter.render(try document(topN: 2))
        XCTAssertTrue(text.contains("(3 more rows)  shown 2 of 5 rows = "), text)
        XCTAssertTrue(text.contains("shown 2 of 50 tasks = "), text)
    }

    func testWithheldSectionsPrintTheReason() {
        var nan = TestModels.task(1, start: 100, end: 101)
        nan.duration = .nan
        let model = TestModels.model([TestModels.task(0, start: 100, end: 102), nan])
        let doc = try? ReportPipeline.run(model, options: .init(generatedAt: ReportersJSONTests.date)).document
        let text = doc.map { TextReporter.render($0) } ?? ""
        XCTAssertTrue(text.contains("unavailable"), text)
        XCTAssertTrue(text.contains("V1 fail:"), text)
        XCTAssertFalse(text.contains("0 ms in"), text)
    }

    func testDegradationsAreShown() {
        var model = SyntheticModel.make()
        model.degradations = [Degradation(kind: .classification, detail: "9.0% of task time unclassified")]
        let text = (try? ReportPipeline.run(model, options: .init(generatedAt: ReportersJSONTests.date)))
            .map { TextReporter.render($0.document) } ?? ""
        XCTAssertTrue(text.contains("DEGRADED"), text)
        XCTAssertTrue(text.contains("classification: 9.0% of task time unclassified"), text)
    }

    func testLogTextCannotInjectTerminalEscapes() throws {
        var model = SyntheticModel.make()
        model.tasks[0].title = "evil\u{1B}]52;c;cHduZWQ=\u{07}\u{9B}31m title"
        model.tasks[0].ruleName = "Rule\u{1B}[2J"
        if !model.targets.isEmpty { model.targets[0].name = "T\u{1B}[31m" }
        let doc = try ReportPipeline.run(model, options: .init(topN: 50, generatedAt: ReportersJSONTests.date,
                                                               inputPath: "/p\u{1B}[0m")).document
        let text = TextReporter.render(doc)
        XCTAssertFalse(text.unicodeScalars.contains { $0.value == 0x1B || $0.value == 0x07 || $0.value == 0x9B }, text)
    }

    func testPeakIsWithheldWhenV1Fails() throws {
        var nan = TestModels.task(1, start: 100, end: 101)
        nan.duration = .nan
        let doc = try ReportPipeline.run(TestModels.model([TestModels.task(0, start: 100, end: 102), nan]),
                                         options: .init(generatedAt: ReportersJSONTests.date)).document
        XCTAssertNil(doc.build.parallelism.peak)
        XCTAssertTrue(TextReporter.render(doc).contains("peak unavailable"))
    }

    private let expectedSnapshot = """
    xcblame 0.6.0 · synthetic
      log     SLF v11 · reader slf · layout commandLine
      xcode   26.0 (inferred: log format version 11 (written by Xcode >= 26.0))
      build   CLEAN (build description created (signature 01234567), 0 reused task(s)) · 1 warning
      graph   none (no build description for this log; critical path inferred from timing)
    TIME  log span 40.0 s · busy 33.2 s · idle 6.8 s · task time 92.5 s in 50 tasks (2.8x avg)
          CPU 37.0 s (15 of 50 tasks with metrics; 5 placeholder records ignored) · peak 7 lanes
          ≤ 1 lane busy for 7.2 s (18% of span, 4 stretches ≥ 1 s) · 3 idle gaps > 100 ms (6.8 s) · process wall unknown (`xcblame build` measures it)
    CRITICAL PATH 33.8 s  basis: inferred from timing
       0.0– 2.5  (no target): CreateBuildDescription 1.2 s, ClangStatCache 1.0 s, +1 more  2.5     7%
       2.5– 3.0  (waiting: nothing on the path ran)                                        0.5     1%
       3.0– 5.0  explicit modules: PCM Module2 2.0 s                                       2.0     6%
       5.0–13.5  NetKit: compile NetKit 3.0 s, compile NetKit 3.0 s, +2 more               8.5    25%
      13.5–15.8  CoreKit: emit-module CoreKit 1.5 s, Libtool 750 ms                        2.2     7%
      15.8–16.5  (waiting: nothing on the path ran)                                        0.8     2%
      16.5–19.0  App: compile App 2.5 s                                                    2.5     7%
      19.0–19.5  (waiting: nothing on the path ran)                                        0.5     1%
      19.5–22.0  App: compile App 2.5 s                                                    2.5     7%
      22.0–22.5  (waiting: nothing on the path ran)                                        0.5     1%
      22.5–25.0  App: compile App 2.5 s                                                    2.5     7%
      25.0–25.5  (waiting: nothing on the path ran)                                        0.5     1%
      25.5–28.0  App: compile App 2.5 s                                                    2.5     7%
      28.0–29.0  (waiting: nothing on the path ran)                                        1.0     3%
      29.0–31.5  App: Ld 2.5 s                                                             2.5     7%
      31.5–31.8  (waiting: nothing on the path ran)                                        0.2     1%
      31.8–33.2  App: CodeSign 1.5 s                                                       1.5     4%
      33.2–33.5  (waiting: nothing on the path ran)                                        0.2     1%
      33.5–33.8  App: Touch 250 ms                                                         0.2     1%
      what-if needs the task DAG (a matching build description)
    TARGETS             task time  share  tasks  on path  owner
      App                  42.8 s    46%     23   14.2 s  unknown
      CoreKit              21.8 s    24%     10    2.2 s  unknown
      NetKit               16.5 s    18%      8    8.5 s  unknown
      explicit modules      9.0 s    10%      6    2.0 s  systemModules
      (unattributed)        2.5 s     3%      3    2.5 s
    FILES  no compile task names a source file
    HOTSPOTS  none: no type-check timing in this log (-debug-time-function-bodies, warn-long diagnostics)
    FIXED COSTS  work that runs on (nearly) every build · per day (assumption: 50 builds/day)
      planning        1.5 s  75.0 s  static  2 tasks
      sdkStatCache    1.0 s  50.0 s  static   1 task
      Σ 2.5 s per build across classes (what runs anyway, not a saving)
    MODULE GRAPH  3 targets · source log
      no build description: targets from the log, no dependency edges (depth, chain, fan-in/out and blockers need target-graph.txt; use xcblame build or --build-description)
    KINDS               task time  share  tasks
      swiftCompile         64.5 s    70%     26
      modulePrecompile      9.0 s    10%      6
      link                  3.8 s     4%      3
      assets                3.5 s     4%      1
      swiftEmitModule       2.5 s     3%      2
      script                2.0 s     2%      1
      codesign              1.5 s     2%      1
      planning              1.5 s     2%      2
      clangCompile          1.2 s     1%      1
      aux                   1.0 s     1%      4
      sdkStatCache          1.0 s     1%      1
      other                750 ms     1%      1
      resources            250 ms    <1%      1
    TOP TASKS                      time  target   title
      CompileAssetCatalogVariant  3.5 s  App      Compile Assets.xcassets
      SwiftCompile                3.0 s  CoreKit  Compile CoreKit2.swift
      SwiftCompile                3.0 s  NetKit   Compile NetKit2.swift
      SwiftCompile                3.0 s  CoreKit  Compile CoreKit5.swift
      SwiftCompile                3.0 s  NetKit   Compile NetKit5.swift
      shown 5 of 50 tasks = 17% of task time
    DIAGNOSTICS  0 errors · 1 warning (1 unique, 1 occurrences)
    checks 12 pass, 0 warn, 0 fail, 3 n/a

    """
}
