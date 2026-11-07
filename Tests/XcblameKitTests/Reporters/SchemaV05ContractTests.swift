import XCTest
@testable import XcblameKit

/// Sample values of the v0.5 report members, for the contract tests and the lanes' own tests (docs/SCHEMA-v0.5.md).
enum V05Samples {
    static let task = ReportDocument.Incremental.CauseTask(
        key: "target-Acme-abc:Debug:SwiftCompile normal arm64 /src/A.swift", label: "compile A.swift", target: "Acme",
        kind: "swiftCompile", seconds: 1.5, pathSeconds: 1.5, taskId: 12)

    static let incremental = ReportDocument.Incremental(
        basis: "previousIndex", previousBuild: .init(id: "20261102-101500-clean", time: V04Samples.date),
        causes: [
            .init(id: "inputChanged:/src/A.swift", class: "inputChanged", cause: "A.swift changed (touched)",
                  source: "backtrace", subject: "/src/A.swift", evidence: ["backtrace: ruleInputRebuilt A.swift"],
                  secondaryEvidence: ["mtimeChurn: newer than the previous build"], tasks: [task], tasksTotal: 1,
                  tasksShownShare: 1, seconds: 1.5, pathSeconds: 1.5, ruleId: nil),
            .init(id: "unknown", class: "unknown", cause: "no evidence (run why --backtraces)", source: "unknown",
                  subject: nil, evidence: [], secondaryEvidence: [], tasks: [], tasksTotal: 0, tasksShownShare: nil,
                  seconds: 0, pathSeconds: nil, ruleId: nil),
        ],
        unknownSeconds: 0, unknownShare: 0, byTaskTime: ["inputChanged:/src/A.swift", "unknown"],
        byPathSeconds: ["inputChanged:/src/A.swift"],
        v15: .init(status: "pass", executedSeconds: 1.5, sumOfCauses: 1.5),
        procedure: .init(mode: "touch", touched: "/src/A.swift",
                         builds: [.init(role: "settle", exitCode: 0, wall: 3, executedTasks: 10, executedWorkTasks: 2,
                                        historyId: "20261102-101500-clean"),
                                  .init(role: "measure", exitCode: 0, wall: 2, executedTasks: 4, executedWorkTasks: 1,
                                        historyId: nil)],
                         backtraces: "unavailable", showIncremental: false),
        notes: ["backtraces: unavailable (MV-2)"])

    static let fixedCosts = [
        ReportDocument.FixedCost(class: "planning", seconds: 1.83, perDay: 91.5, perDayAssumedBuilds: 50,
                                 perDayBasis: "assumed", basis: "zeroChange", tasks: [task], tasksTotal: 3,
                                 tasksShownShare: 0.8),
        ReportDocument.FixedCost(class: "scripts", seconds: nil, perDay: nil, perDayAssumedBuilds: 50,
                                 perDayBasis: "config", basis: "static", tasks: [], tasksTotal: 0, tasksShownShare: nil),
    ]

    static let moduleGraph = ReportDocument.ModuleGraph(
        source: "targetGraph", targets: 3, depth: 2,
        longestChain: [.init(target: "App", seconds: 2), .init(target: "Kit", seconds: 1)], longestChainSeconds: 3,
        fanIn: [.init(target: "Core", count: 2)], fanOut: [.init(target: "App", count: 2)],
        umbrellaCandidates: ["Core"], cycles: [], blockers: [.init(target: "Core", gatedSeconds: 4.2)],
        macroPluginsPerModule: [.init(module: "Kit", plugins: 2, names: ["MacroA", "MacroB"])],
        variants: .init(modules: 64, pcmTasks: 143, redundantTasks: 79, redundantSeconds: 7.59,
                        causes: ["languageMode", "swiftPackage"],
                        perModule: [.init(module: "Darwin", variants: 3, flags: ["__swift__=60200"],
                                          causes: ["languageMode"], pcmTasks: 3, redundantSeconds: 0.4)],
                        perModuleTotal: 62, perModuleShownShare: 0.1),
        criticalChain: ["App", "Kit", "Core"],
        nodes: [.init(id: "App", name: "App", owner: "app", depth: 2, variants: nil, macroPlugins: nil,
                      onPathSeconds: 2, taskTime: 5, collapsed: 0),
                .init(id: "more:remotePackage", name: "2 more modules (remotePackage)", owner: "remotePackage",
                      depth: 0, variants: nil, macroPlugins: nil, onPathSeconds: nil, taskTime: 1, collapsed: 2)],
        nodesTotal: 3, nodesShownShare: 0.333333, edges: [.init(from: "App", to: "more:remotePackage", critical: false)],
        edgesTotal: 2, edgesShownShare: 0.5, notes: [])

    static let deep = ReportDocument.Deep(
        enabled: true, scope: ["swift", "clang"],
        flagsInjected: ["-Xfrontend -debug-time-function-bodies", "-ftime-trace"],
        flagsDropped: [.init(flag: "-ftime-trace-granularity=500", reason: "-ftime-trace itself is not supported")],
        flagsNotInjected: [.init(flag: "-Xfrontend -warn-long-function-bodies=<ms>", reason: "off by default")],
        shadowed: ["Acme: OTHER_CFLAGS"], derivedData: "/cache/deep/0123456789abcdef", derivedDataBytes: 1_000_000,
        wrapper: ".xcblame/tmp/wrapper-Debug.xcconfig",
        exactFiles: .init(rebuiltTargets: ["Acme"], note: "rebuilt without batch mode: the build shape changed"),
        sources: .init(debugTime: 120, warnLong: 0, statsDir: 9, ftimeTrace: 4), notes: [])

    static let cache = ReportDocument.BuildCache(hits: 10, misses: 2, replayedTasks: 9, replayedTasksHeuristic: nil,
                                                 source: "buildOperationMetrics")

    /// The synthetic pipeline report with every v0.5 member filled.
    static func populatedReport() throws -> ReportDocument {
        var document = try ReportPipeline.run(SyntheticModel.make(), options: .init(generatedAt: V04Samples.date)).document
        document.incremental = incremental
        document.fixedCosts = fixedCosts
        document.moduleGraph = moduleGraph
        document.deep = deep
        document.build.cache = cache
        return document
    }
}

/// Tripwire for docs/SCHEMA-v0.5.md: member names of the v0.5 report members and the history row layout. Renaming,
/// removing or retyping one breaks the contract; a lane that needs a change stops and asks.
final class SchemaV05ContractTests: XCTestCase {
    private func keys<T: Encodable>(_ value: T) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: try JSONReporter.encoder().encode(value))
        return try XCTUnwrap(object as? [String: Any]).keys.sorted()
    }

    func testVersionAndNullMembersOfAPipelineReport() throws {
        XCTAssertEqual(XcblameVersion.current, "0.6.0")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONReporter.render(try syntheticReport()))
            as? [String: Any])
        // v0.5 integration: the lanes fill fixedCosts and moduleGraph inside the pipeline; incremental needs the
        // command step (CauseEngine.attach) and says so; deep is null without a note when --deep was not given; the
        // synthetic log has no cache counter (a build note says why).
        for key in ["incremental", "deep"] { XCTAssertTrue(json[key] is NSNull, key) }
        XCTAssertFalse((json["fixedCosts"] as? [Any])?.isEmpty ?? true, "fixedCosts filled by the pipeline")
        XCTAssertEqual((json["moduleGraph"] as? [String: Any])?["source"] as? String, "log", "no build description")
        let build = try XCTUnwrap(json["build"] as? [String: Any])
        XCTAssertTrue(build["cache"] is NSNull)
        XCTAssertTrue((build["notes"] as? [String] ?? []).contains { $0.hasPrefix("cache: null because") }, "\(build)")
        let notes = try XCTUnwrap(json["notes"] as? [String])
        XCTAssertTrue(notes.contains(CauseEngine.pendingNote), "\(notes)")
        XCTAssertFalse(notes.contains { $0.hasPrefix("not produced yet") || $0.contains("not produced (batches") },
                       "no phase-1 placeholder note survives: \(notes)")
        XCTAssertFalse(notes.contains { $0.hasPrefix("deep") }, "deep is null without a note")
    }

    func testIncrementalKeys() throws {
        let value = V05Samples.incremental
        XCTAssertEqual(try keys(value), ["basis", "byPathSeconds", "byTaskTime", "causes", "notes", "previousBuild",
                                         "procedure", "unknownSeconds", "unknownShare", "v15"])
        XCTAssertEqual(try keys(value.causes[0]), ["cause", "class", "evidence", "id", "pathSeconds", "ruleId",
                                                   "secondaryEvidence", "seconds", "source", "subject", "tasks",
                                                   "tasksShownShare", "tasksTotal", "whatToDo"])
        XCTAssertEqual(try keys(V05Samples.task), ["key", "kind", "label", "pathSeconds", "seconds", "target", "taskId"])
        XCTAssertEqual(try keys(value.v15), ["executedSeconds", "status", "sumOfCauses"])
        XCTAssertEqual(try keys(value.previousBuild!), ["id", "time"])
        XCTAssertEqual(try keys(value.procedure!), ["backtraces", "builds", "mode", "showIncremental", "touched"])
        XCTAssertEqual(try keys(value.procedure!.builds[0]), ["executedTasks", "executedWorkTasks", "exitCode",
                                                              "historyId", "role", "wall"])
        XCTAssertEqual(ReportDocument.Incremental.sources, EvidenceSource.allCases.map(\.rawValue))
        XCTAssertEqual(ReportDocument.Incremental.classes, CauseClass.allCases.map(\.rawValue))
    }

    func testFixedCostModuleGraphDeepAndCacheKeys() throws {
        XCTAssertEqual(try keys(V05Samples.fixedCosts[0]), ["basis", "class", "perDay", "perDayAssumedBuilds",
                                                            "perDayBasis", "seconds", "tasks", "tasksShownShare",
                                                            "tasksTotal"])
        let graph = V05Samples.moduleGraph
        XCTAssertEqual(try keys(graph), ["blockers", "criticalChain", "cycles", "depth", "edges", "edgesShownShare",
                                         "edgesTotal", "fanIn", "fanOut", "longestChain", "longestChainSeconds",
                                         "macroPluginsPerModule", "nodes", "nodesShownShare", "nodesTotal", "notes",
                                         "source", "targets", "umbrellaCandidates", "variants"])
        XCTAssertEqual(try keys(graph.variants!), ["causes", "modules", "pcmTasks", "perModule", "perModuleShownShare",
                                                   "perModuleTotal", "redundantSeconds", "redundantTasks"])
        XCTAssertEqual(try keys(graph.variants!.perModule[0]), ["causes", "flags", "module", "pcmTasks",
                                                                "redundantSeconds", "variants"])
        XCTAssertEqual(try keys(graph.nodes[0]), ["collapsed", "depth", "id", "macroPlugins", "name", "onPathSeconds",
                                                  "owner", "taskTime", "variants"])
        XCTAssertEqual(try keys(graph.edges[0]), ["critical", "from", "to"])
        XCTAssertEqual(ReportDocument.ModuleGraph.nodeCap, 300)
        XCTAssertEqual(try keys(V05Samples.deep), ["derivedData", "derivedDataBytes", "enabled", "exactFiles",
                                                   "flagsDropped", "flagsInjected", "flagsNotInjected", "notes",
                                                   "scope", "shadowed", "sources", "wrapper"])
        XCTAssertEqual(try keys(V05Samples.deep.sources!), ["debugTime", "ftimeTrace", "statsDir", "warnLong"])
        XCTAssertEqual(try keys(V05Samples.cache), ["hits", "misses", "replayedTasks", "replayedTasksHeuristic", "source"])
        XCTAssertEqual(ReportDocument.ModuleGraph.sources, ["targetGraph", "project", "log", "none"])
    }

    func testPopulatedReportValidatesAgainstTheSchemaAndRoundTrips() throws {
        let document = try V05Samples.populatedReport()
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try JSONSchema.render(.report).utf8))
            as? [String: Any])
        let tree = try JSONSerialization.jsonObject(with: try JSONReporter.encoder().encode(document))
        XCTAssertEqual(MiniSchemaValidator(root: schema).errors(tree), [])
        let decoded = try JSONReporter.decoder().decode(ReportDocument.self, from: try JSONReporter.render(document))
        XCTAssertEqual(decoded.incremental, document.incremental)
        XCTAssertEqual(decoded.moduleGraph, document.moduleGraph)
        XCTAssertEqual(decoded.deep, document.deep)
        XCTAssertEqual(decoded.build.cache, document.build.cache)
        XCTAssertEqual(decoded.fixedCosts, document.fixedCosts)
    }

    /// Code review v0.5: the strict validation also runs on documents a real run emits, not only on `V05Samples`:
    /// the why-26 incremental log attributed against its clean build (`incremental`, `fixedCosts`, `moduleGraph`),
    /// the same log through a deep run over the stats-dir fixtures (`deep`), and the 27.1 cache-hit log (`build.cache`).
    func testRealV05MembersValidateAgainstTheSchema() throws {
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try JSONSchema.render(.report).utf8))
            as? [String: Any])
        let validator = MiniSchemaValidator(root: schema)
        func errors(_ document: ReportDocument) throws -> [String] {
            validator.errors(try JSONSerialization.jsonObject(with: try JSONReporter.encoder().encode(document)))
        }

        let (model, attributed) = try WhyFixtures.attributed(WhyFixtures.why26, test: self, topN: .max)
        let incremental = try XCTUnwrap(attributed.incremental)
        XCTAssertGreaterThan(incremental.causes.count, 2)
        XCTAssertNotNil(attributed.fixedCosts)
        XCTAssertNotNil(attributed.moduleGraph)
        XCTAssertEqual(try errors(attributed), [])

        var options = ReportPipeline.Options(topN: .max, generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                             inputPath: WhyFixtures.why26.incremental.path)
        options.deep = DeepFixtures.deepRun(statsDir: DeepFixtures.stats26)
        let deep = try ReportPipeline.run(model, options: options).document
        XCTAssertNotNil(deep.deep?.sources)
        XCTAssertEqual(try errors(deep), [])

        let cached = try GraphFixtures.report(try GraphFixtures.model(CacheMetricsTests.hit27)).document
        XCTAssertEqual(cached.build.cache?.replayedTasks, 112)
        XCTAssertEqual(cached.build.kind, "cached")
        XCTAssertEqual(try errors(cached), [])
    }

    func testAV04ReportDecodesWithTheV05MembersNull() throws {
        var tree = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONReporter.render(try V05Samples.populatedReport()))
            as? [String: Any])
        for key in ["incremental", "fixedCosts", "moduleGraph", "deep"] { tree[key] = nil }
        var build = try XCTUnwrap(tree["build"] as? [String: Any])
        build["cache"] = nil
        tree["build"] = build
        let old = try JSONReporter.decoder().decode(ReportDocument.self,
                                                   from: try JSONSerialization.data(withJSONObject: tree))
        XCTAssertNil(old.incremental)
        XCTAssertNil(old.fixedCosts)
        XCTAssertNil(old.moduleGraph)
        XCTAssertNil(old.deep)
        XCTAssertNil(old.build.cache)
    }

    /// v0.5 integration members (`build.cache.replayedTasks`, `deep.flagsNotInjected`) are additive: a report written
    /// by the lanes before they existed decodes with them null / empty.
    func testIntegrationMembersAreAdditive() throws {
        var tree = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONReporter.render(try V05Samples.populatedReport()))
            as? [String: Any])
        var deep = try XCTUnwrap(tree["deep"] as? [String: Any])
        XCTAssertNotNil(deep.removeValue(forKey: "flagsNotInjected"))
        tree["deep"] = deep
        var build = try XCTUnwrap(tree["build"] as? [String: Any])
        var cache = try XCTUnwrap(build["cache"] as? [String: Any])
        XCTAssertEqual(cache.removeValue(forKey: "replayedTasks") as? Int, 9)
        build["cache"] = cache
        tree["build"] = build
        let old = try JSONReporter.decoder().decode(ReportDocument.self,
                                                   from: try JSONSerialization.data(withJSONObject: tree))
        XCTAssertEqual(old.deep?.flagsNotInjected, [])
        XCTAssertNil(old.build.cache?.replayedTasks)
        XCTAssertEqual(old.build.cache?.hits, 10)
    }

    func testHistoryRowsStaySevenElementsUnlessWhyCapturedHashes() throws {
        let plain = History.TaskIndexRow(key: "k", rule: "SwiftEmitModule", target: "Kit", kind: "swiftEmitModule",
                                         sigDigest: "0011223344556677", durationMs: 120, onPath: true)
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self),
                       #"["k","SwiftEmitModule","Kit","swiftEmitModule","0011223344556677",120,1]"#)
        var captured = plain
        captured.outputHash = "8899aabbccddeeff"
        captured.outputBytes = 4096
        let data = try JSONEncoder().encode(captured)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       #"["k","SwiftEmitModule","Kit","swiftEmitModule","0011223344556677",120,1,"8899aabbccddeeff",4096,null]"#)
        XCTAssertEqual(try JSONDecoder().decode(History.TaskIndexRow.self, from: data), captured)
        XCTAssertEqual(try JSONDecoder().decode(History.TaskIndexRow.self, from: try JSONEncoder().encode(plain)), plain)
    }

    func testApplyingIncrementalReplacesTheV15Row() throws {
        let document = try syntheticReport().applying(incremental: V05Samples.incremental)
        XCTAssertEqual(document.incremental, V05Samples.incremental)
        let v15 = try XCTUnwrap(document.validation.checks.first { $0.id == "V15" })
        // Lane B: the row is `Validator.checkV15` over the member against `build.taskTime`.
        let expected = Validator.checkV15(V05Samples.incremental, executedSeconds: document.build.taskTime)
        XCTAssertEqual(v15.status, expected.status.label)
        XCTAssertEqual(v15.detail, expected.detail)
        XCTAssertNotEqual(v15.status, "notApplicable")
    }
}
