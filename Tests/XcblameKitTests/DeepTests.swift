import XCTest
@testable import XcblameKit

/// Lane A engines (docs/SCHEMA-v0.5.md "Deep"): toolchain probe, flag plan, deep DerivedData, `--exact-files`,
/// `estimated` file rows and the hotspot merge.
final class DeepTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/tmp/xcblame-home")

    func testScopeParsingIsCanonicalAndStrict() throws {
        XCTAssertEqual(try DeepScope.parse("clang,swift"), [.swift, .clang])
        XCTAssertEqual(try DeepScope.parse("swift,swift"), [.swift])
        XCTAssertThrowsError(try DeepScope.parse("swift,rust"))
    }

    func testPathsOfTheDeepDerivedDataAndTheWrapper() {
        let dir = DeepDerivedData.directory(for: URL(fileURLWithPath: "/src/App.xcodeproj"), home: home)
        XCTAssertEqual(dir.deletingLastPathComponent().path, "/tmp/xcblame-home/deep")
        XCTAssertEqual(dir.lastPathComponent.count, 16)
        XCTAssertEqual(DeepDerivedData.keepDays, OracleCache.keepDays)
        XCTAssertEqual(DeepDerivedData.statsDirectory(in: dir).deletingLastPathComponent().path, dir.path)
        XCTAssertEqual(WrapperXCConfig.url(xcblameDir: URL(fileURLWithPath: "/r/.xcblame"), configuration: "Debug").path,
                       "/r/.xcblame/tmp/wrapper-Debug.xcconfig")
    }

    // MARK: - Toolchain probe

    func testProbeParsesTheSavedHelpTexts() throws {
        let probe = try DeepFixtures.probe26()
        for flag in ["-debug-time-function-bodies", "-debug-time-expression-type-checking", "-stats-output-dir",
                     "-warn-long-function-bodies"] {
            XCTAssertTrue(try ToolchainProbe.supports(flag, scope: .swift, in: probe), flag)
        }
        // Dead flags (DESIGN §5.8) are not in the help text; a prefix of a longer option is no match.
        XCTAssertFalse(try ToolchainProbe.supports("-debug-time-compilation", scope: .swift, in: probe))
        XCTAssertFalse(try ToolchainProbe.supports("-debug-time", scope: .swift, in: probe))
        XCTAssertTrue(try ToolchainProbe.supports("-ftime-trace", scope: .clang, in: probe))
        XCTAssertTrue(try ToolchainProbe.supports("-ftime-trace-granularity=500", scope: .clang, in: probe))
        XCTAssertFalse(try ToolchainProbe.supports("-ftime", scope: .clang, in: probe))
        XCTAssertFalse(try ToolchainProbe.supports("-ftime-trace", scope: .swift, in: probe), "scopes use their own text")
        // `-help` alone (Swift 6.2) lists none of the frontend timing flags: they are hidden.
        let visibleOnly = ToolchainProbe.Result(swiftFrontendHelp: try DeepFixtures.text("xcode26-swift-frontend-help.txt"),
                                                clangHelp: nil)
        XCTAssertFalse(try ToolchainProbe.supports("-debug-time-function-bodies", scope: .swift, in: visibleOnly))
        XCTAssertFalse(try ToolchainProbe.supports("-ftime-trace", scope: .clang, in: visibleOnly), "probe failed")
    }

    func testProbeAsksForHiddenHelpOnlyWhenNeededAndCaches() throws {
        let help = try DeepFixtures.text("xcode26-swift-frontend-help.txt")
        let hidden = try DeepFixtures.text("xcode26-swift-frontend-help-hidden-excerpt.txt")
        let clang = try DeepFixtures.text("xcode26-clang-help-excerpt.txt")
        let calls = CallLog()
        let probe: EnvSnapshot.Probe = { argv in
            calls.append(argv.joined(separator: " "))
            switch argv.last {
            case "-version": return "Xcode 26.0.1\nBuild version 17A400"
            case "-help": return help
            case "-help-hidden": return hidden
            case "--help": return clang
            default: return nil
            }
        }
        let result = try ToolchainProbe.run(probe: probe)
        XCTAssertEqual(calls.all, ["xcrun swift-frontend -help", "xcrun swift-frontend -help-hidden", "xcrun clang --help"])
        XCTAssertTrue(try ToolchainProbe.supports("-stats-output-dir", scope: .swift, in: result))
        XCTAssertTrue(result.notes.isEmpty)

        let cache = try DeepFixtures.scratch(self)
        calls.reset()
        let first = try ToolchainProbe.run(probe: probe, cacheDir: cache, environment: [:])
        XCTAssertEqual(calls.all.count, 4, "xcodebuild -version, then the three probes")
        calls.reset()
        let second = try ToolchainProbe.run(probe: probe, cacheDir: cache, environment: [:])
        XCTAssertEqual(calls.all, ["xcodebuild -version"], "cached per xcodebuild build")
        XCTAssertEqual(second.swiftFrontendHelp, first.swiftFrontendHelp)
        XCTAssertTrue(second.notes.last?.contains("cached for Xcode 26.0.1 Build version 17A400") == true)
        calls.reset()
        _ = try ToolchainProbe.run(probe: probe, cacheDir: cache, environment: ["DEVELOPER_DIR": "/Applications/Beta.app"])
        XCTAssertEqual(calls.all.count, 4, "another DEVELOPER_DIR is another toolchain")

        let failed = try ToolchainProbe.run(probe: { _ in nil })
        XCTAssertNil(failed.swiftFrontendHelp)
        XCTAssertEqual(failed.notes.count, 2)
    }

    // MARK: - Flag plan

    func testPlanInjectsEverySupportedFlagAndDropsWarnLong() throws {
        let stats = URL(fileURLWithPath: "/c/deep/abc/xcblame-stats")
        let flags = try DeepFlags.plan(scope: [.swift, .clang], exactFiles: true, probe: try DeepFixtures.probe26(),
                                       statsDir: stats)
        XCTAssertEqual(flags.injected, ["-Xfrontend -debug-time-function-bodies",
                                        "-Xfrontend -debug-time-expression-type-checking",
                                        "-Xfrontend -stats-output-dir -Xfrontend /c/deep/abc/xcblame-stats",
                                        "-ftime-trace", "-ftime-trace-granularity=500"])
        XCTAssertEqual(flags.lines, [
            "OTHER_SWIFT_FLAGS = $(inherited) -Xfrontend -debug-time-function-bodies -Xfrontend "
                + "-debug-time-expression-type-checking -Xfrontend -stats-output-dir -Xfrontend /c/deep/abc/xcblame-stats",
            "OTHER_CFLAGS = $(inherited) -ftime-trace -ftime-trace-granularity=500",
        ])
        XCTAssertEqual(flags.dropped, [], "every flag of the scope is supported: nothing dropped")
        XCTAssertEqual(flags.notInjected.map(\.flag), ["-Xfrontend -warn-long-function-bodies=<ms>",
                                                       "-Xfrontend -warn-long-expression-type-checking=<ms>"])
        XCTAssertTrue(flags.notInjected.allSatisfy { $0.reason.hasPrefix("off by default") })
        let member = DeepRun(flags: flags, enabled: true, derivedData: home, derivedDataBytes: nil, statsDir: stats,
                             wrapper: nil, shadowed: [], exactFiles: nil, notes: []).member(sources: nil)
        XCTAssertEqual(member.flagsDropped, [])
        XCTAssertEqual(member.flagsNotInjected, flags.notInjected)
        XCTAssertTrue(flags.exactFiles)
    }

    func testPlanDropsWhatTheToolchainLacks() throws {
        let probe = ToolchainProbe.Result(swiftFrontendHelp: "  -debug-time-function-bodies  Dumps\n",
                                          clangHelp: "  -ftime-trace-granularity=<value>\n")
        let flags = try DeepFlags.plan(scope: [.swift, .clang], exactFiles: false, probe: probe,
                                       statsDir: URL(fileURLWithPath: "/My Cache/stats"))
        XCTAssertEqual(flags.injected, ["-Xfrontend -debug-time-function-bodies"])
        XCTAssertEqual(flags.lines, ["OTHER_SWIFT_FLAGS = $(inherited) -Xfrontend -debug-time-function-bodies"])
        let dropped = Dictionary(uniqueKeysWithValues: flags.dropped.map { ($0.flag, $0.reason) })
        XCTAssertEqual(dropped["-Xfrontend -stats-output-dir -Xfrontend \"/My Cache/stats\""],
                       "not supported by this toolchain: not in swift-frontend (-help, -help-hidden)")
        XCTAssertEqual(dropped["-ftime-trace"], "not supported by this toolchain: not in clang (--help)")
        XCTAssertEqual(dropped["-ftime-trace-granularity=500"], "-ftime-trace itself is not supported")

        let none = try DeepFlags.plan(scope: [.clang], exactFiles: false,
                                      probe: ToolchainProbe.Result(swiftFrontendHelp: nil, clangHelp: nil),
                                      statsDir: home)
        XCTAssertTrue(none.lines.isEmpty)
        XCTAssertTrue(none.dropped.allSatisfy { $0.reason.hasPrefix("toolchain probe failed") })
        XCTAssertFalse(flags.dropped.contains { $0.reason.hasPrefix("off by default") }, "unsupported only")
        XCTAssertEqual(flags.notInjected.count, 2)
    }

    // MARK: - Deep DerivedData

    func testPrepareMarksAndPruneRemovesOnlyMarkedOldEntries() throws {
        let home = try DeepFixtures.scratch(self)
        let a = try DeepDerivedData.prepare(for: URL(fileURLWithPath: "/src/A.xcodeproj"), home: home)
        let b = try DeepDerivedData.prepare(for: URL(fileURLWithPath: "/src/B.xcworkspace"), home: home)
        XCTAssertEqual(a.path, DeepDerivedData.directory(for: URL(fileURLWithPath: "/src/A.xcodeproj"), home: home).path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.appendingPathComponent(DeepDerivedData.marker).path))
        let stranger = home.appendingPathComponent("deep/not-ours")
        try FileManager.default.createDirectory(at: stranger, withIntermediateDirectories: true)
        let old = Date().addingTimeInterval(-40 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: a.path)
        XCTAssertEqual(DeepDerivedData.prune(home: home, olderThanDays: 30), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stranger.path), "unmarked folders are never removed")
        XCTAssertEqual(DeepDerivedData.prune(home: home, olderThanDays: nil), 1)
    }

    // MARK: - --exact-files

    private func fileRow(_ path: String, target: String?, seconds: Double, granularity: String = "batch")
        -> ReportDocument.FileRow {
        ReportDocument.FileRow(path: path, target: target, targetId: nil, seconds: seconds, granularity: granularity,
                               batchSize: granularity == "batch" ? 2 : nil, members: nil, onPath: false,
                               typeCheckMs: nil, taskId: nil)
    }

    func testExactFilesPicksTheTargetsOfTheLongestBatches() throws {
        let files = [
            fileRow("/a", target: "Kit", seconds: 9), fileRow("/b", target: "App", seconds: 7),
            fileRow("/c", target: "Kit", seconds: 6), fileRow("/d", target: "My-Lib", seconds: 5),
            fileRow("/e", target: "Late", seconds: 1), fileRow("/x", target: "Exact", seconds: 50, granularity: "exact"),
        ]
        let plan = try ExactFiles.plan(files: files, topK: 4)
        XCTAssertEqual(plan.targets, ["Kit", "App", "My-Lib"], "top 4 batches, targets once, exact rows ignored")
        XCTAssertEqual(plan.lines, [
            "SWIFT_ENABLE_BATCH_MODE = $(XCBLAME_BATCH_MODE_$(TARGET_NAME:c99extidentifier):default=$(inherited))",
            "XCBLAME_BATCH_MODE_Kit = NO", "XCBLAME_BATCH_MODE_App = NO", "XCBLAME_BATCH_MODE_My_Lib = NO",
        ])
        XCTAssertTrue(plan.note.contains("the build shape changed"), plan.note)
        XCTAssertEqual(try ExactFiles.plan(files: files).targets, ["Kit", "App", "My-Lib", "Late"])
        XCTAssertEqual(ExactFiles.c99Identifier("3D Engine"), "_3D_Engine")

        let empty = try ExactFiles.plan(files: [fileRow("/x", target: "A", seconds: 1, granularity: "exact")])
        XCTAssertTrue(empty.targets.isEmpty)
        XCTAssertTrue(empty.lines.isEmpty)
        XCTAssertTrue(empty.note.contains("nothing was rebuilt"), empty.note)

        // Code review v0.5: `My-Lib` and `My_Lib` share XCBLAME_BATCH_MODE_My_Lib, so the switch would hit both.
        let clash = try ExactFiles.plan(files: files + [fileRow("/f", target: "My_Lib", seconds: 0.5, granularity: "exact")],
                                        topK: 4)
        XCTAssertEqual(clash.targets, ["Kit", "App"])
        XCTAssertFalse(clash.lines.contains { $0.contains("My_Lib") }, "\(clash.lines)")
        XCTAssertTrue(clash.note.contains("not rebuilt: My-Lib (its setting name XCBLAME_BATCH_MODE_My_Lib is also My_Lib's)"),
                      clash.note)
        let only = try ExactFiles.plan(files: [fileRow("/a", target: "My-Lib", seconds: 2),
                                               fileRow("/b", target: "My_Lib", seconds: 1, granularity: "exact")])
        XCTAssertTrue(only.targets.isEmpty)
        XCTAssertTrue(only.note.hasSuffix("the build shape did not change"), only.note)
    }

    // MARK: - estimated rows

    private func hotspot(_ file: String, line: Int, ms: Double, source: String = "debugTimeFunctionBodies") -> HotspotValue {
        HotspotValue(file: file, line: line, col: 1, declaration: "f()", kind: "functionBody", ms: ms, source: source,
                     onPathWeight: 1, occurrences: 1, targetId: nil, taskId: nil)
    }

    func testEstimatedRowsSplitTheBatchByTypeCheckShare() throws {
        let fixture = DeepFixtures.model()
        let counted = Timing.timeline(fixture.model).counted
        let batch = try XCTUnwrap(counted.first { $0.task.id == fixture.batchTask })
        let hotspots = [hotspot("/src/NetKit/A.swift", line: 3, ms: 30), hotspot("/src/NetKit/A.swift", line: 9, ms: 30),
                        hotspot("/src/NetKit/B.swift", line: 1, ms: 20),
                        // File-level deep rows never count (a batch job's stats cover the whole batch).
                        hotspot("/src/NetKit/C.swift", line: 0, ms: 500, source: "statsDir")]
        let rows = FileAttribution.estimatedRows(counted: counted, model: fixture.model, hotspots: hotspots,
                                                 pathTaskIds: [fixture.batchTask])
        XCTAssertEqual(rows.map(\.path), ["/src/NetKit/A.swift", "/src/NetKit/B.swift", "/src/NetKit/C.swift"])
        XCTAssertEqual(rows[0].seconds, batch.interval.duration * 0.75, accuracy: 1e-12)
        XCTAssertEqual(rows[1].seconds, batch.interval.duration * 0.25, accuracy: 1e-12)
        XCTAssertEqual(rows[2].seconds, 0)
        XCTAssertEqual(rows.reduce(0) { $0 + $1.seconds }, batch.interval.duration, accuracy: 1e-12)
        XCTAssertTrue(rows.allSatisfy { $0.granularity == "estimated" && $0.taskId == fixture.batchTask && $0.onPath })
        XCTAssertEqual(rows[0].members, fixture.batchFiles)
        XCTAssertEqual(rows[0].typeCheckMs, 60)
        XCTAssertTrue(FileAttribution.estimatedRows(counted: counted, model: fixture.model,
                                                    hotspots: [hotspot("/src/Other.swift", line: 1, ms: 5)],
                                                    pathTaskIds: []).isEmpty, "no member with type-check ms")
    }

    /// v0.5 integration: the `files` note names the estimated rows, or says why a batch has none (no phase-1 text).
    func testFilesNoteNamesEstimatedRowsOrWhyThereAreNone() throws {
        var fixture = DeepFixtures.model()
        func filesNote() throws -> String {
            let notes = try ReportPipeline.run(fixture.model, options: .init(generatedAt: Date(timeIntervalSince1970: 0)))
                .document.notes
            return try XCTUnwrap(notes.first { $0.hasPrefix("files: ") }, "\(notes)")
        }
        let none = try filesNote()
        XCTAssertTrue(none.contains("batch 1 rows"), none)
        XCTAssertTrue(none.contains("no estimated rows (no per-file type-check ms for the batches; build --deep records it)"), none)
        XCTAssertFalse(none.contains("not produced"), none)
        let batch = try XCTUnwrap(fixture.model.tasks.firstIndex { $0.id == fixture.batchTask })
        fixture.model.tasks[batch].emittedOutput = "30.0ms\t/src/NetKit/A.swift:3:1\tf()\r20.0ms\t/src/NetKit/B.swift:1:1\tg()\r"
        let some = try filesNote()
        XCTAssertTrue(some.contains("estimated 3 rows (1 batches split by type-check ms, not added to exact)"), some)
        XCTAssertFalse(some.contains("no estimated rows"), some)
    }

    /// Code review v0.5: one type-check source per file (expression ms nest inside function bodies, warn-long repeats
    /// debug-time locations), so a file is not weighted by the number of sources that saw it.
    func testEstimatedRowsUseOneTypeCheckSourcePerFile() throws {
        let fixture = DeepFixtures.model()
        let counted = Timing.timeline(fixture.model).counted
        let hotspots = [hotspot("/src/NetKit/A.swift", line: 3, ms: 30),
                        hotspot("/src/NetKit/A.swift", line: 4, ms: 25, source: "debugTimeExpression"),
                        hotspot("/src/NetKit/A.swift", line: 3, ms: 30, source: "warnLong"),
                        hotspot("/src/NetKit/B.swift", line: 1, ms: 10, source: "debugTimeExpression"),
                        hotspot("/src/NetKit/B.swift", line: 2, ms: 99, source: "warnLong")]
        let rows = FileAttribution.estimatedRows(counted: counted, model: fixture.model, hotspots: hotspots,
                                                 pathTaskIds: [])
        XCTAssertEqual(rows.first { $0.path.hasSuffix("/A.swift") }?.typeCheckMs, 30, "function bodies only")
        XCTAssertEqual(rows.first { $0.path.hasSuffix("/B.swift") }?.typeCheckMs, 10, "expressions, no function body")
    }

    /// Verifier V1: under --deep the files note never suggests build --deep; it names the batches without per-file
    /// type-check ms. Code review v0.5: estimated rows are interleaved by seconds and stay out of the shown share.
    func testDeepFilesNoteAndEstimatedRowsInTheTable() throws {
        var fixture = DeepFixtures.model()
        let stats = try DeepFixtures.scratch(self)
        func document(topN: Int = 15) throws -> ReportDocument {
            var options = ReportPipeline.Options(topN: topN, generatedAt: Date(timeIntervalSince1970: 0))
            options.deep = DeepFixtures.deepRun(statsDir: stats)
            return try ReportPipeline.run(fixture.model, options: options).document
        }
        let none = try XCTUnwrap(try document().notes.first { $0.hasPrefix("files: ") })
        XCTAssertFalse(none.contains("build --deep records it"), none)
        XCTAssertTrue(none.contains("1 of 1 batch rows not estimated (no per-file type-check ms): 1 with no debug-time "
            + "row for any member (NetKit)"), none)

        let batch = try XCTUnwrap(fixture.model.tasks.firstIndex { $0.id == fixture.batchTask })
        fixture.model.tasks[batch].emittedOutput = "30.0ms\t/src/NetKit/A.swift:3:1\tf()\r20.0ms\t/src/NetKit/B.swift:1:1\tg()\r"
        // A per-file compile shorter than any estimated share: it must sort below them, not above.
        let perFile = try XCTUnwrap(fixture.model.tasks.firstIndex { $0.id == fixture.perFileTask })
        fixture.model.tasks[perFile].end = fixture.model.tasks[perFile].start + 0.001
        fixture.model.tasks[perFile].duration = 0.001
        let full = try document(topN: .max)
        let rows = try XCTUnwrap(full.files)
        XCTAssertGreaterThan(try XCTUnwrap(rows.firstIndex { $0.path == "/src/AcmeApp/StudioView.swift" }),
                             try XCTUnwrap(rows.firstIndex { $0.granularity == "estimated" }), "\(rows.map(\.path))")
        XCTAssertTrue(try XCTUnwrap(full.notes.first { $0.hasPrefix("files: ") }).contains("estimated 3 rows"))
        XCTAssertFalse(full.notes.contains { $0.contains("not estimated") }, "\(full.notes)")
        XCTAssertEqual(rows.map(\.seconds), rows.map(\.seconds).sorted(by: >), "one table ordered by seconds")
        XCTAssertEqual(full.filesShownShare, 1)
        let measured = rows.filter { $0.granularity != "estimated" }.reduce(0) { $0 + $1.seconds }
        for topN in 1..<rows.count {
            let cut = try document(topN: topN)
            let shown = try XCTUnwrap(cut.files).filter { $0.granularity != "estimated" }.reduce(0) { $0 + $1.seconds }
            XCTAssertEqual(try XCTUnwrap(cut.filesShownShare), shown / measured, accuracy: 1e-5, "top \(topN)")
        }
    }

    func testV9ComparesExactRowsOnlyNextToEstimatedRows() {
        let fixture = DeepFixtures.model()
        let counted = Timing.timeline(fixture.model).counted
        let hotspots = [hotspot("/src/NetKit/A.swift", line: 3, ms: 30)]
        var files = FileAttribution.rows(counted: counted, model: fixture.model, pathTaskIds: [], typeCheckMs: [:])
        files += FileAttribution.estimatedRows(counted: counted, model: fixture.model, hotspots: hotspots, pathTaskIds: [])
        let check = Validator.checkV9(files: files, counted: counted)
        XCTAssertEqual(check.status, .pass)
        XCTAssertTrue(check.note?.contains("3 estimated row(s)") == true, check.note ?? "")
    }

    // MARK: - merge

    func testMergeAddsDeepRowsFilteredDedupedAndRanked() throws {
        let dir = try DeepFixtures.scratch(self)
        for name in try FileManager.default.contentsOfDirectory(atPath: DeepFixtures.stats26.path) {
            try FileManager.default.copyItem(at: DeepFixtures.stats26.appendingPathComponent(name),
                                             to: dir.appendingPathComponent(name))
        }
        // The same job on a second arch: deduped into one row with two occurrences, the larger ms kept.
        let arm = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.contains("-o-") })
        try FileManager.default.copyItem(at: dir.appendingPathComponent(arm), to: dir.appendingPathComponent(
            arm.replacingOccurrences(of: "arm64_apple", with: "x86_64_apple").replacingOccurrences(of: "-2835", with: "-9")))
        let object = dir.appendingPathComponent("obj/Bridge.o")
        try FileManager.default.createDirectory(at: object.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: DeepFixtures.trace26, to: FTimeTraceReader.traceURL(forObject: object.path))
        let fixture = DeepFixtures.model(object: object.path)
        let counted = Timing.timeline(fixture.model).counted
        let base = Hotspots.compute(counted: counted, model: fixture.model, pathTaskIds: nil)

        let none = Hotspots.mergeDeep(base, deep: nil, counted: counted, model: fixture.model, pathTaskIds: nil)
        XCTAssertNil(none.sources)
        XCTAssertEqual(none.result.rows.count, base.rows.count)

        let merged = Hotspots.mergeDeep(base, deep: DeepFixtures.deepRun(statsDir: dir), counted: counted,
                                        model: fixture.model, pathTaskIds: [fixture.perFileTask])
        XCTAssertEqual(merged.sources, ReportDocument.Deep.Sources(debugTime: base.rawLines, warnLong: base.warnLong,
                                                                   statsDir: 2, ftimeTrace: 2))
        XCTAssertTrue(merged.result.hasSource)
        let stats = merged.result.rows.filter { $0.source == "statsDir" }
        XCTAssertEqual(stats.count, 1)
        XCTAssertEqual(stats[0].occurrences, 2)
        XCTAssertEqual(stats[0].onPathWeight, 1, "its compile task is on the path")
        let trace = merged.result.rows.filter { $0.source == "ftimeTrace" }
        XCTAssertEqual(trace.map(\.kind), ["frontend"], "the SDK header row is not user code")
        XCTAssertEqual(trace[0].onPathWeight, Hotspots.offPathWeight)
        XCTAssertEqual(merged.result.rows.first?.source, "statsDir", "ranked by ms × weight")
        XCTAssertTrue(merged.notes.isEmpty, "\(merged.notes)")

        // Hotspot type-check sums per file ignore the file-level rows.
        XCTAssertNil(Hotspots.typeCheckMsByFile(merged.result.rows)["/src/AcmeApp/StudioView.swift"])

        let missing = Hotspots.mergeDeep(base, deep: DeepFixtures.deepRun(statsDir: dir.appendingPathComponent("nope"),
                                                                          scope: [.swift]),
                                         counted: counted, model: fixture.model, pathTaskIds: nil)
        XCTAssertEqual(missing.sources?.statsDir, 0)
        XCTAssertTrue(missing.notes.first?.contains("does not exist") == true, "\(missing.notes)")
        XCTAssertNil(Hotspots.mergeDeep(base, deep: DeepFixtures.deepRun(statsDir: dir, enabled: false), counted: counted,
                                        model: fixture.model, pathTaskIds: nil).sources)
    }

    func testDeepRunMapsToTheMemberAndTheReportCarriesReaderNotes() throws {
        let dir = try DeepFixtures.scratch(self)
        let run = DeepFixtures.deepRun(statsDir: dir.appendingPathComponent("missing"), scope: [.swift])
        var options = ReportPipeline.Options(generatedAt: Date(timeIntervalSince1970: 0))
        options.deep = run
        let document = try ReportPipeline.run(DeepFixtures.model().model, options: options).document
        let deep = try XCTUnwrap(document.deep)
        XCTAssertTrue(deep.enabled)
        XCTAssertEqual(deep.scope, ["swift"])
        XCTAssertEqual(deep.derivedData, dir.path)
        XCTAssertEqual(deep.sources?.statsDir, 0)
        XCTAssertTrue(deep.notes.contains { $0.contains("stats-dir:") }, "\(deep.notes)")
        XCTAssertNil(try ReportPipeline.run(SyntheticModel.make(), options: .init(generatedAt: Date())).document.deep)
    }
}

/// Probe calls recorded from a `@Sendable` closure.
final class CallLog: @unchecked Sendable {
    private var calls: [String] = []
    private let lock = NSLock()

    func append(_ call: String) {
        lock.lock()
        calls.append(call)
        lock.unlock()
    }

    func reset() {
        lock.lock()
        calls = []
        lock.unlock()
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}
