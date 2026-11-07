import XCTest
@testable import XcblameKit

/// Build kind, utilization, owners, files, hotspots, task index and V3/V4/V9/V11 on the AcmeApp fixtures.
final class GraphReportTests: XCTestCase {
    private func status(_ doc: ReportDocument, _ id: String) -> String? {
        doc.validation.checks.first { $0.id == id }?.status
    }

    // MARK: Build kind

    func testBuildKinds() throws {
        let cases: [(URL, String)] = [
            (GraphFixtures.clean26, "clean"), (GraphFixtures.cleanDD, "clean"), (GraphFixtures.cleanDD3, "clean"),
            (GraphFixtures.incremental26, "incremental"), (GraphFixtures.incrementalDD, "zero-change"),
            (GraphFixtures.cleanAction26, "clean-action"), (GraphFixtures.cleanActionDD3, "clean-action"),
            (GraphFixtures.cleanAction27, "clean-action"),
        ]
        for (log, kind) in cases {
            let doc = try GraphFixtures.report(try GraphFixtures.model(log), topN: 3).document
            XCTAssertEqual(doc.build.kind, kind, log.lastPathComponent)
            XCTAssertFalse(doc.build.kindEvidence.isEmpty, log.lastPathComponent)
            XCTAssertEqual(status(doc, "V11"), "pass", log.lastPathComponent)
        }
    }

    func testBuildRequestActionComesFirst() throws {
        let model = try GraphFixtures.model(GraphFixtures.cleanDD)
        var description = try BuildDescription.load(directory: GraphFixtures.descriptionDD)
        XCTAssertEqual(try GraphFixtures.report(model, description: description, topN: 3).document.build.kindEvidence.first,
                       "build-request.json action=build")
        description.buildRequest.enableIndexBuildArena = true
        XCTAssertEqual(try GraphFixtures.report(model, description: description, topN: 3).document.build.kind, "index")
        description.buildRequest.enableIndexBuildArena = false
        description.buildRequest.action = "archive"
        XCTAssertEqual(try GraphFixtures.report(model, description: description, topN: 3).document.build.kind, "archive")
    }

    func testV11FailsOnAnInconsistentKind() {
        let counts = BuildKindResult.Counts(executed: 5, reused: 2, compileExecuted: 3, descriptionTaskExecuted: true,
                                            descriptionCreated: true, cleanActionShape: false)
        let check = Validator.checkV11(BuildKindResult(kind: "clean", evidence: ["x"], reason: nil, counts: counts))
        XCTAssertTrue(check.status.isFail)
        XCTAssertEqual(Validator.checkV11(BuildKindResult(kind: nil, evidence: [], reason: "r", counts: counts)).status,
                       .notApplicable)
    }

    /// Code review v0.2 requirement gap: V9, V11 and V3's DAG clause can fail. Hand-built inputs for each.
    func testV9FailsWhenExactRowsExceedTheCompileTime() {
        let compile = TestModels.task(0, target: 0, start: 0, end: 2)
        let counted = [Timing.Counted(task: compile, interval: Interval(start: 0, end: 2))]
        func row(_ seconds: Double, _ granularity: String = "exact") -> FileRowValue {
            FileRowValue(path: "/a.swift", targetId: 0, seconds: seconds, granularity: granularity, members: nil,
                         onPath: false, typeCheckMs: nil, taskId: 0)
        }
        XCTAssertEqual(Validator.checkV9(files: [row(1.5), row(0.5)], counted: counted).status, .pass)
        // A batch's 2 s copied onto each of its files: 4 s of exact rows against 2 s of compiles.
        XCTAssertTrue(Validator.checkV9(files: [row(2), row(2)], counted: counted).status.isFail)
        // v0.5 lane A: `estimated` rows (`--deep`) are never summed with exact rows, so they cannot push V9 over.
        XCTAssertEqual(Validator.checkV9(files: [row(1.5), row(5, "estimated")], counted: counted).status, .pass)
        XCTAssertTrue(Validator.checkV9(files: [row(2.5), row(0.5, "estimated")], counted: counted).status.isFail)
    }

    func testV11FailsWhenTheKindContradictsTheCounts() {
        func counts(reused: Int = 0, compile: Int = 3, created: Bool = true, cleanShape: Bool = false) -> BuildKindResult.Counts {
            .init(executed: 5, reused: reused, compileExecuted: compile, descriptionTaskExecuted: true,
                  descriptionCreated: created, cleanActionShape: cleanShape)
        }
        func check(_ kind: String, _ c: BuildKindResult.Counts, evidence: [String] = ["x"]) -> CheckStatus {
            Validator.checkV11(BuildKindResult(kind: kind, evidence: evidence, reason: nil, counts: c)).status
        }
        XCTAssertTrue(check("clean", counts(reused: 1)).isFail)
        XCTAssertTrue(check("zero-change", counts(compile: 2)).isFail)
        XCTAssertTrue(check("incremental", counts(reused: 0, created: true)).isFail)
        XCTAssertTrue(check("clean-action", counts()).isFail)
        XCTAssertTrue(check("archive", counts()).isFail, "no build-request evidence")
        XCTAssertEqual(check("zero-change", counts(compile: 0)), .pass)
    }

    func testV3FailsOnDAGEdgesThatContradictTheTiming() throws {
        var (model, dag) = GraphCriticalPathTests.sixNodeDAG()
        let path = try XCTUnwrap(CriticalPath.fromDAG(dag, model: model))
        let line = Timing.timeline(model)
        XCTAssertEqual(Validator.checkV3(path: path, dag: dag, counted: line.counted, window: line.window).status, .pass)
        dag.violations = 1   // 1 of 6 direct edges late: 16.7 % > 1 %
        let status = Validator.checkV3(path: path, dag: dag, counted: line.counted, window: line.window).status
        XCTAssertTrue(status.isFail, "\(status)")
        XCTAssertTrue(status.reason?.contains("16.67% of DAG edges contradict the timing") == true, "\(status)")
    }

    // MARK: Utilization

    func testUtilizationBucketsCoverTheSpanAndSumToTaskTime() throws {
        let doc = try GraphFixtures.report(try GraphFixtures.model(GraphFixtures.clean26), physicalCores: 28).document
        let utilization = try XCTUnwrap(doc.timing.utilization)
        let span = try XCTUnwrap(doc.build.span)
        XCTAssertLessThanOrEqual(utilization.lanes.count, 4000)
        XCTAssertGreaterThanOrEqual(Double(utilization.lanes.count) * utilization.bucketSeconds, span - 1e-9)
        let area = utilization.lanes.reduce(0, +) * utilization.bucketSeconds
        XCTAssertEqual(area, try XCTUnwrap(doc.build.taskTime), accuracy: 0.01 * (doc.build.taskTime ?? 0))
        XCTAssertEqual(doc.timing.serialThresholdLanes, 2)
        let serial = try XCTUnwrap(doc.timing.serialSeconds)
        XCTAssertLessThanOrEqual(serial, try XCTUnwrap(doc.build.busy))
        for stretch in try XCTUnwrap(doc.timing.serialStretches) {
            XCTAssertGreaterThanOrEqual(stretch.end - stretch.start, 1 - 1e-6)
            XCTAssertLessThanOrEqual(stretch.lanes, 2)
        }
        let gaps = try XCTUnwrap(doc.timing.idleGaps).reduce(0) { $0 + $1.end - $1.start }
        XCTAssertLessThanOrEqual(gaps, try XCTUnwrap(doc.build.idle) + 1e-6)
        XCTAssertEqual(doc.timing.peakLanes, doc.build.parallelism.peak)
    }

    /// Code review v0.2 #9: `span / (span / 4000)` rounds up to 4001 for this span; the cap holds exactly.
    func testUtilizationNeverExceeds4000Buckets() {
        for span in [3281.628180588076, 400.000001, 5399.99, 1e6] {
            let result = Utilization.compute(intervals: [Interval(start: 0, end: span)], span: span, peak: 1,
                                             physicalCores: nil)
            XCTAssertLessThanOrEqual(result.lanes.count, 4000, "\(span)")
            XCTAssertGreaterThanOrEqual(Double(result.lanes.count) * result.bucketSeconds, span, "\(span)")
        }
    }

    func testSerialThresholdFallsBackToPeakLanesWithANote() throws {
        let doc = try GraphFixtures.report(try GraphFixtures.model(GraphFixtures.cleanDD), topN: 3).document
        XCTAssertEqual(doc.timing.serialThresholdLanes, 2, "10% of 29 peak lanes")
        XCTAssertTrue(doc.timing.notes.contains { $0.contains("physical cores unknown") })
    }

    func testUtilizationArithmetic() {
        let result = Utilization.compute(intervals: [Interval(start: 0, end: 2), Interval(start: 0.5, end: 1.5),
                                                     Interval(start: 3.2, end: 4.5)],
                                         span: 5, peak: 2, physicalCores: 10)
        XCTAssertEqual(result.bucketSeconds, 0.1)
        XCTAssertEqual(result.lanes.count, 50)
        XCTAssertEqual(result.lanes.reduce(0, +) * 0.1, 4.3, accuracy: 1e-9)
        XCTAssertEqual(result.lanes[7], 2, accuracy: 1e-9)
        XCTAssertEqual(result.threshold, 1)
        XCTAssertEqual(result.stretches.map { [$0.start, $0.end] }, [[3.2, 4.5]], "0-0.5 and 1.5-2 are < 1 s")
        XCTAssertEqual(result.gaps.map { [$0.start, $0.end] }, [[2, 3.2], [4.5, 5]])
    }

    // MARK: Targets

    func testTargetRowsCarryOwnerPathBusyAndKinds() throws {
        let description = try BuildDescription.load(directory: GraphFixtures.descriptionDD)
        let doc = try GraphFixtures.report(try GraphFixtures.model(GraphFixtures.cleanDD), description: description)
            .document
        let targets = try XCTUnwrap(doc.targets)
        let owners = Dictionary(uniqueKeysWithValues: targets.map { ($0.name, $0.owner) })
        XCTAssertEqual(owners["AcmeApp"], "app")
        XCTAssertEqual(owners["LocalizeCore"], "localPackage")
        XCTAssertEqual(owners["SwiftSyntax"], "remotePackage")
        XCTAssertEqual(owners["_SwiftSyntaxCShims"], "remotePackage")
        XCTAssertEqual(owners[Target.explicitModulesBucket], "systemModules")
        XCTAssertEqual(owners[Target.buildSystemBucket], "buildSystem")
        let path = try XCTUnwrap(doc.criticalPath)
        let onPath = targets.compactMap(\.onPathSeconds).reduce(0, +)
        XCTAssertLessThanOrEqual(onPath, path.span + 1e-6)
        for row in targets {
            if let busy = row.busy {
                XCTAssertLessThanOrEqual(busy, row.taskTime + 1e-6, row.name)
                XCTAssertLessThanOrEqual(busy, try XCTUnwrap(doc.build.busy) + 1e-6, row.name)
            }
            let kinds = try XCTUnwrap(row.kinds)
            XCTAssertEqual(kinds.reduce(0) { $0 + $1.taskTime }, row.taskTime, accuracy: 1e-5, row.name)
            XCTAssertEqual(kinds.reduce(0) { $0 + $1.tasks }, row.tasks, row.name)
            XCTAssertTrue(kinds.contains { $0.isOther }, row.name)
            if let id = row.id, let saving = path.whatIf?.first(where: { $0.targetId == id })?.savingIfZero {
                XCTAssertEqual(row.whatIfSeconds, saving, row.name)
            }
        }
        XCTAssertNil(targets.first { $0.isOther }?.owner)
    }

    // MARK: Files

    func testFileRowsArePartitionedByGranularity() throws {
        let model = try GraphFixtures.model(GraphFixtures.clean26)
        let doc = try GraphFixtures.report(model).document
        let files = try XCTUnwrap(doc.files)
        XCTAssertEqual(files.count, doc.filesTotal)
        XCTAssertEqual(doc.filesShownShare, 1)
        XCTAssertEqual(files.filter { $0.granularity == "exact" }.count, 42, "the asset catalog is not a file row")
        XCTAssertEqual(files.filter { $0.granularity == "batch" }.count, 46)
        XCTAssertFalse(files.contains { $0.granularity == "estimated" })
        // Every AcmeApp file compiles alone (DESIGN §6.4: 18 LocalizeCore + 8 AcmeApp frontends; in this log the
        // 8th AcmeApp one is the generated GeneratedAssetSymbols.swift in DerivedData).
        let user = files.filter { $0.path.hasPrefix("/Users/ciuser/Projects/acmeapp/Sources/") }
        XCTAssertEqual(user.count, 25)
        XCTAssertEqual(user.filter { $0.target == "LocalizeCore" }.count, 18)
        XCTAssertTrue(user.allSatisfy { $0.granularity == "exact" && $0.members == nil })
        XCTAssertEqual(files.first { $0.path.hasSuffix("/GeneratedAssetSymbols.swift") }?.granularity, "exact")
        for row in files where row.granularity == "batch" {
            XCTAssertEqual(row.batchSize, row.members?.count)
            XCTAssertEqual(row.members, row.members?.sorted())
            XCTAssertEqual(row.path, row.members?.first)
        }
        var exact: [Int: Double] = [:]
        for row in files where row.granularity == "exact" { exact[row.targetId ?? -1, default: 0] += row.seconds }
        let timeline = Timing.timeline(model)
        for (target, seconds) in exact {
            let compile = timeline.counted.filter { ($0.task.targetId ?? -1) == target
                && FileAttribution.isFileCompile($0.task) }.reduce(0) { $0 + $1.interval.duration }
            XCTAssertLessThanOrEqual(seconds, compile + 1e-5)
        }
        XCTAssertEqual(status(doc, "V9"), "pass")
        let studio = try XCTUnwrap(files.first { $0.path.hasSuffix("/StudioView.swift") })
        XCTAssertTrue(studio.onPath)
        XCTAssertNotNil(studio.typeCheckMs)
    }

    /// Verifier v0.2 #6: only source compiles are file rows, and V9 holds against the target's compile time by kind
    /// (AcmeApp: Σ exact ≤ its swiftCompile + clangCompile time).
    func testFileRowsAreSourceCompilesOnlyAndFitTheCompileTime() throws {
        let model = try GraphFixtures.model(GraphFixtures.clean26)
        let doc = try GraphFixtures.report(model).document
        let files = try XCTUnwrap(doc.files)
        XCTAssertFalse(files.contains { $0.path.hasSuffix(".xcassets") }, "asset catalogs are not files")
        XCTAssertTrue(files.allSatisfy { FileAttribution.sourceExtensions.contains(($0.path as NSString).pathExtension) })
        let acmeapp = try XCTUnwrap(model.targets.first { $0.name == "AcmeApp" }).id
        let exact = files.filter { $0.targetId == acmeapp && $0.granularity == "exact" }.reduce(0) { $0 + $1.seconds }
        let compile = Timing.timeline(model).counted.filter {
            $0.task.targetId == acmeapp && ($0.task.kind == .swiftCompile || $0.task.kind == .clangCompile)
        }.reduce(0) { $0 + $1.interval.duration }
        XCTAssertGreaterThan(exact, 0)
        XCTAssertLessThanOrEqual(exact, compile + 1e-6)
        XCTAssertEqual(status(doc, "V9"), "pass")
    }

    /// Verifier v0.2 #7 and #10: no 0 ms hotspot; serial stretches and idle gaps in time order.
    func testZeroMillisecondHotspotsAreDroppedAndStretchesAreInTimeOrder() throws {
        let doc = try GraphFixtures.report(try GraphFixtures.model(GraphFixtures.clean26), physicalCores: 14).document
        XCTAssertFalse(try XCTUnwrap(doc.hotspots).contains { $0.ms == 0 })
        let stretches = try XCTUnwrap(doc.timing.serialStretches).map(\.start)
        XCTAssertGreaterThan(stretches.count, 1)
        XCTAssertEqual(stretches, stretches.sorted())
        let gaps = try XCTUnwrap(doc.timing.idleGaps).map(\.start)
        XCTAssertEqual(gaps, gaps.sorted())
        let rows = (0..<40).map { ReportDocument.Gap(start: Double($0), end: Double($0) + Double($0 % 7) / 10) }
        let kept = ReportBudget.Pass.longest(rows, 25) { $0.end - $0.start }
        XCTAssertEqual(kept.count, 25)
        XCTAssertEqual(kept.map(\.start), kept.map(\.start).sorted(), "the budget keeps the longest, in time order")
        XCTAssertFalse(kept.contains { $0.end - $0.start < 0.15 }, "the shortest rows go first")
    }

    /// Verifier v0.2 #8: a plain warn (V5 count mismatch on the clean log) does not make the report degraded; text,
    /// JSON and html agree. A truncated log still is (DegradedInputTests).
    func testPlainWarnsDoNotDegradeTheReport() throws {
        let doc = try GraphFixtures.report(try GraphFixtures.model(GraphFixtures.clean26)).document
        XCTAssertEqual(doc.validation.checks.filter { $0.status == "warn" }.map(\.id), ["V5"])
        XCTAssertFalse(doc.degraded)
        XCTAssertFalse(doc.validation.degraded)
        XCTAssertTrue(doc.degradations.isEmpty, "\(doc.degradations)")
        let text = TextReporter.render(doc)
        XCTAssertFalse(text.contains("DEGRADED"), text)
        XCTAssertTrue(text.contains("1 warn"), text)
        var failed = doc
        failed.degradations = [.init(kind: "validation", detail: "V9: x")]
        XCTAssertTrue(TextReporter.render(failed).contains("status  DEGRADED (partial or uncertain analysis; see the failed checks)"))
    }

    func testFilesParsedFromCommandDetails() {
        var task = TestModels.task(0, start: 100, end: 101)
        task.commandDetails = "SwiftCompile normal arm64 Compiling\\ A\\ B.swift,\\ C.swift /p/A\\ B.swift /p/C.swift "
            + "(in target 'T' from project 'P')\r    cd /p"
        XCTAssertEqual(FileAttribution.files(of: task), ["/p/A B.swift", "/p/C.swift"])
        task.commandDetails = "CompileAssetCatalogVariant thinned /out/Resources /p/Assets.xcassets (in target 'App')"
        XCTAssertEqual(FileAttribution.files(of: task), [], "an asset catalog is not a source file")
        task.ruleName = "CompileAssetCatalogVariant"
        task.kind = .assets
        XCTAssertFalse(FileAttribution.isFileCompile(task))
        task.ruleName = "CompileMetalFile"
        task.kind = .other
        XCTAssertTrue(FileAttribution.isFileCompile(task))
    }

    // MARK: Hotspots

    func testHotspotsFromDebugTimeTextAndWarnLong() throws {
        let model = try GraphFixtures.model(GraphFixtures.clean26)
        let doc = try GraphFixtures.report(model).document
        let timeline = Timing.timeline(model)
        let raw = Hotspots.compute(counted: timeline.counted, model: model, pathTaskIds: nil)
        // 20,960 debug-time lines in SwiftCompile output (the 23,983 of DESIGN §5.8 counted an earlier capture; the
        // other 4,187 lines of this log sit in SwiftEmitModule output, not read).
        XCTAssertEqual(raw.rawLines, 20_960)
        XCTAssertEqual(raw.warnLong, 1, "one `Expression took 62ms to type-check` diagnostic in this log")
        let hotspots = try XCTUnwrap(doc.hotspots)
        XCTAssertEqual(hotspots.count, doc.hotspotsTotal)
        XCTAssertGreaterThan(doc.hotspotsTotal, 0)
        XCTAssertFalse(hotspots.contains { $0.file.contains("/checkouts/") || $0.file.contains("swift-syntax") })
        XCTAssertFalse(hotspots.contains { $0.file.contains("/Build/Intermediates.noindex/") })
        XCTAssertEqual(Set(hotspots.map { "\($0.file):\($0.line):\($0.col)" }).count, hotspots.count, "deduped")
        let top = try XCTUnwrap(hotspots.first)
        XCTAssertTrue(top.file.hasSuffix("/StudioView.swift"))
        XCTAssertEqual(top.line, 399)
        XCTAssertEqual(top.onPathWeight, 1)
        XCTAssertEqual(top.ms, 425, accuracy: 1)
        let warn = try XCTUnwrap(hotspots.first { $0.source == "warnLong" })
        XCTAssertEqual(warn.line, 394)
        XCTAssertEqual(warn.ms, 62)
        XCTAssertEqual(warn.kind, "expression")
        XCTAssertTrue(hotspots.contains { $0.onPathWeight == 0.25 })
        for pair in zip(hotspots, hotspots.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.0.ms * pair.0.onPathWeight, pair.1.ms * pair.1.onPathWeight)
        }
    }

    func testHotspotLineParsing() throws {
        let body = try XCTUnwrap(Hotspots.parse("12.5ms\t/a:b/File.swift:399:25\tStringsView._@/a:b/File.swift:399:25"))
        XCTAssertEqual(body.file, "/a:b/File.swift")
        XCTAssertEqual(body.line, 399)
        XCTAssertEqual(body.col, 25)
        XCTAssertEqual(body.declaration, "StringsView._")
        XCTAssertEqual(body.kind, "functionBody")
        let expression = try XCTUnwrap(Hotspots.parse("3.0ms\t/p/F.swift:9:2"))
        XCTAssertEqual(expression.kind, "expression")
        XCTAssertEqual(expression.source, "debugTimeExpression")
        XCTAssertNil(Hotspots.parse("warning: something\tx"))
        XCTAssertNil(Hotspots.parse("1.0ms\t/p/F.swift:x:2\tf"))
    }

    func testNoHotspotSourceGivesNull() throws {
        let doc = try GraphFixtures.report(try GraphFixtures.model(GraphFixtures.cleanDD), topN: 3).document
        XCTAssertNil(doc.hotspots)
        XCTAssertEqual(doc.hotspotsTotal, 0)
        XCTAssertTrue(doc.notes.contains { $0.hasPrefix("hotspots: no type-check timing") })
    }

    // MARK: Task index

    func testTaskIndexIsDeterministicAndMarksThePath() throws {
        let model = try GraphFixtures.model(GraphFixtures.cleanDD)
        let description = try BuildDescription.load(directory: GraphFixtures.descriptionDD)
        let result = try GraphFixtures.report(model, description: description, topN: 5)
        let first = TaskIndex.make(model: model, analysis: result.analysis, document: result.document)
        let second = TaskIndex.make(model: model, analysis: result.analysis, document: result.document)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.taskIndexTotal, result.document.build.tasks)
        XCTAssertEqual(first.start.count, first.taskIndexTotal)
        for column in [first.dur.count, first.lane.count, first.target.count, first.kind.count, first.label.count,
                       first.onPath.count] {
            XCTAssertEqual(column, first.start.count)
        }
        let pathIds = try XCTUnwrap(result.document.criticalPath).segments.flatMap(\.taskIds)
        XCTAssertEqual(first.onPath.filter { $0 == 1 }.count, pathIds.count)
        XCTAssertEqual(first.taskIndexShownShare, 1)
        XCTAssertTrue(first.dropped.isEmpty)
        var laneEnd: [Int: Int] = [:]
        for row in first.start.indices {
            XCTAssertGreaterThanOrEqual(first.start[row], laneEnd[first.lane[row]] ?? 0, "lane overlap at row \(row)")
            laneEnd[first.lane[row]] = first.start[row] + first.dur[row]
            if row > 0 { XCTAssertLessThanOrEqual(first.start[row - 1], first.start[row]) }
        }
        XCTAssertFalse(first.labels.contains { $0.contains("/tmp/") || $0.contains("/Users/") })
        XCTAssertEqual(Set(first.lane).count, result.document.build.parallelism.peak)
    }

    // MARK: Validators on the fixtures

    func testV3V4V9V11OnTheFixtures() throws {
        let description = try BuildDescription.load(directory: GraphFixtures.descriptionDD)
        let dd = try GraphFixtures.report(try GraphFixtures.model(GraphFixtures.cleanDD), description: description,
                                          topN: 3).document
        for id in ["V3", "V4", "V9", "V11"] { XCTAssertEqual(status(dd, id), "pass", id) }
        let cleanAction = try GraphFixtures.report(try GraphFixtures.model(GraphFixtures.cleanAction26), topN: 3)
            .document
        XCTAssertEqual(status(cleanAction, "V3"), "pass")
        XCTAssertEqual(status(cleanAction, "V9"), "notApplicable", "no compile tasks")
        XCTAssertEqual(status(cleanAction, "V11"), "pass")
    }

    /// The pipeline's own validation carries the engine checks (V3, V9, V11), so `analyze`'s exit code and the
    /// document agree.
    func testResultValidationMatchesTheDocumentChecks() throws {
        let description = try BuildDescription.load(directory: GraphFixtures.descriptionDD)
        let result = try GraphFixtures.report(try GraphFixtures.model(GraphFixtures.cleanDD), description: description,
                                              topN: 3)
        XCTAssertEqual(result.validation.checks.map(\.id), result.document.validation.checks.map(\.id))
        XCTAssertEqual(result.validation.checks.map(\.status.label), result.document.validation.checks.map(\.status))
        for id in ["V3", "V9", "V11"] { XCTAssertEqual(result.validation.status(id), .pass, id) }
    }

    func testV3FailureWithholdsThePath() {
        var path = PathResult(segments: [.init(start: 0, end: 2, basis: "inferred", targetId: nil, taskIds: [0]),
                                         .init(start: 1, end: 3, basis: "inferred", targetId: nil, taskIds: [1])],
                              waits: [], basis: "inferred", whatIf: nil, notes: [])
        let counted = [Timing.Counted(task: TestModels.task(0, start: 0, end: 2), interval: Interval(start: 0, end: 2)),
                       Timing.Counted(task: TestModels.task(1, start: 1, end: 3), interval: Interval(start: 1, end: 3))]
        let check = Validator.checkV3(path: path, dag: nil, counted: counted, window: (0, 3))
        XCTAssertTrue(check.status.isFail, "\(check.status)")
        path.segments[1].start = 2
        XCTAssertEqual(Validator.checkV3(path: path, dag: nil, counted: counted, window: (0, 3)).status, .pass)
    }

    // MARK: Performance

    /// 50k tasks, no description: the whole pipeline (twice through Explain, plus the JSON size pass) and the task
    /// index stay under 2 s in release builds, like `SLFPerformanceTests`. Run with
    /// `swift test -c release -Xswiftc -enable-testing --filter testLargeSyntheticModel`.
    func testLargeSyntheticModelRunsTheWholePipelineQuickly() throws {
        let model = SyntheticModel.large()
        XCTAssertEqual(model.tasks.count, 50_000)
        let start = Date()
        let result = try ReportPipeline.run(model, options: .init(topN: 15, generatedAt: Date(timeIntervalSince1970: 0)))
        let index = TaskIndex.make(model: model, analysis: result.analysis, document: result.document)
        let elapsed = Date().timeIntervalSince(start)
        print(String(format: "perf 50k synthetic: pipeline + task index %.3f s", elapsed))
        #if !DEBUG
        XCTAssertLessThan(elapsed, 2.0)
        #endif
        let doc = result.document
        XCTAssertEqual(doc.criticalPath?.basis, "inferred")
        XCTAssertEqual(index.taskIndexTotal, 50_000)
        XCTAssertGreaterThan(doc.filesTotal, 40_000)
        XCTAssertGreaterThan(doc.hotspotsTotal, 5_000)
        XCTAssertLessThanOrEqual(try XCTUnwrap(doc.timing.utilization).lanes.count, 4000)
        XCTAssertFalse(doc.validation.checks.contains { $0.status == "fail" }, "\(doc.validation.checks)")
    }

    /// Code review v0.2 #4: 8,000 tasks with a matching gate-heavy manifest: DAG, critical path, what-if and slack
    /// stay linear. Release: < 1 s and < 150 MB peak. Run with
    /// `swift test -c release -Xswiftc -enable-testing --filter testGatedSyntheticWithADescription`.
    func testGatedSyntheticWithADescriptionStaysLinear() throws {
        let (model, description) = GatedSynthetic.make()
        XCTAssertEqual(model.tasks.count, 8_000)
        let start = Date()
        let result = try ReportPipeline.run(model, options: .init(topN: 15, generatedAt: Date(timeIntervalSince1970: 0),
                                                                  buildDescription: description))
        let elapsed = Date().timeIntervalSince(start)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let megabytes = Double(usage.ru_maxrss) / 1_048_576
        print(String(format: "perf 8k gated synthetic with description: pipeline %.3f s, maxRSS %.1f MB", elapsed,
                     megabytes))
        #if !DEBUG
        XCTAssertLessThan(elapsed, 1.0)
        XCTAssertLessThan(megabytes, 150)
        #endif
        let doc = result.document
        XCTAssertEqual(doc.graph.basis, "snapshot", "\(doc.graph.notes)")
        let path = try XCTUnwrap(doc.criticalPath)
        XCTAssertEqual(path.basis, "dag")
        XCTAssertEqual(try XCTUnwrap(path.segments.last).end, 79.9, accuracy: 1e-6, "the last link ends the path")
        XCTAssertEqual(try XCTUnwrap(path.segments.first).target, "T0", "the path reaches back to T0")
        XCTAssertEqual(path.segments.filter { $0.label.hasPrefix("Ld") || $0.label.hasPrefix("link") }.count, 80)
        XCTAssertEqual(try XCTUnwrap(path.whatIf).count, 80)
        XCTAssertFalse(doc.validation.checks.contains { $0.status == "fail" }, "\(doc.validation.checks)")
    }
}
