import Foundation
@testable import XcblameKit

/// AcmeApp fixtures with build descriptions, read once per test run.
enum GraphFixtures {
    static let clean26 = SLFFixtures.root.appendingPathComponent(
        "cli-xcode26/20E8B73D-96FE-4232-8A33-311BFD02F961.xcactivitylog")
    static let incremental26 = SLFFixtures.root.appendingPathComponent(
        "cli-xcode26/D822889B-3D9A-478F-BB03-AB98C3967FD1.xcactivitylog")
    static let cleanAction26 = SLFFixtures.root.appendingPathComponent(
        "cli-xcode26/F49B68E8-5662-416D-A441-2F16BAF5D402.xcactivitylog")
    static let description26 = SLFFixtures.root.appendingPathComponent("cli-xcode26/xcbuilddata")
    static let cleanDD = SLFFixtures.root.appendingPathComponent(
        "cli-xcode26-dd/5E3BDB3A-008A-466D-A419-CB4D4E8CED29.xcactivitylog")
    static let incrementalDD = SLFFixtures.root.appendingPathComponent(
        "cli-xcode26-dd/1724F45E-EE25-4BC4-B219-B6D39E144D71.xcactivitylog")
    static let descriptionDD = SLFFixtures.root.appendingPathComponent("cli-xcode26-dd/xcbuilddata")
    static let cleanDD3 = SLFFixtures.root.appendingPathComponent(
        "cli-xcode26-dd3/71374EE4-5BCF-41B2-9D29-9CF459EB4E44.xcactivitylog")
    static let cleanActionDD3 = SLFFixtures.root.appendingPathComponent(
        "cli-xcode26-dd3/B3F9A630-E7E7-4CB9-BABA-A141351BD516.xcactivitylog")
    static let descriptionDD3 = SLFFixtures.root.appendingPathComponent("cli-xcode26-dd3/xcbuilddata")
    static let cleanAction27 = SLFFixtures.root.appendingPathComponent(
        "cli-xcode27.1b/C272AB0A-5EFB-4584-BE0C-F4B16803F890.xcactivitylog")
    static let xcresultJSON = SLFFixtures.root.appendingPathComponent("cli-xcode26/xcresult-buildlog.json.gz")

    static func model(_ url: URL) throws -> BuildModel {
        BuildModelBuilder.build(try SLFReader.read(url: url), reader: .slf)
    }

    static func xcresultModel() throws -> BuildModel {
        let data = Data(try GzipFile.inflate(contentsOf: xcresultJSON).bytes)
        return BuildModelBuilder.build(try XCResultReader.read(jsonData: data), reader: .xcresult)
    }

    static func report(_ model: BuildModel, description: BuildDescription? = nil, topN: Int = .max,
                       physicalCores: Int? = nil) throws -> ReportPipeline.Result {
        try ReportPipeline.run(model, options: .init(topN: topN, generatedAt: Date(timeIntervalSince1970: 0),
                                                     buildDescription: description, physicalCores: physicalCores))
    }

    /// The DAG path and the inferred path of one log with its description.
    static func bothPaths(_ log: URL, description dir: URL) throws -> (model: BuildModel, dag: PathResult,
                                                                         inferred: PathResult, graph: TaskDAG) {
        let model = try model(log)
        let description = try BuildDescription.load(directory: dir)
        let line = Timing.timeline(model)
        guard let graph = TaskDAG.build(model: model, counted: line.counted, description: description,
                                        window: line.window),
              let dag = CriticalPath.fromDAG(graph, model: model),
              let inferred = CriticalPath.inferred(counted: line.counted, model: model,
                                                   targetGraph: description.targetGraph,
                                                   windowStart: line.window.start) else {
            throw XcblameError.readerFailure("no path for \(log.lastPathComponent)")
        }
        return (model, dag, inferred, graph)
    }
}

/// A gate-heavy synthetic build with a matching manifest (code review v0.2 #4): `targets` targets in a chain, each
/// with `perTarget - 1` compiles and one link. Phony gates chain the targets (`<t-begin>` ← `<t-1-end>`, `<t-end>` ←
/// every output of t and `<t-begin>`), the shape that made collapsed gate edges quadratic. Timing follows the edges.
enum GatedSynthetic {
    static func make(targets: Int = 80, perTarget: Int = 100) -> (model: BuildModel, description: BuildDescription) {
        var tasks: [BuildTask] = []
        var commands: [BuildDescription.Command] = []
        func task(_ rule: String, _ kind: TaskKind, target: Int, key: String, start: Double, end: Double) -> BuildTask {
            var task = TestModels.task(tasks.count, rule, kind: kind, target: target, start: start, end: end)
            task.taskKey = key
            return task
        }
        for t in 0..<targets {
            let base = Double(t) + 0.1
            commands.append(.init(key: "gate-\(t)-begin", tool: "phony", inputs: t == 0 ? [] : ["<\(t - 1)-end>"],
                                  outputs: ["<\(t)-begin>"]))
            var objects: [String] = []
            for c in 0..<(perTarget - 1) {
                let key = "P0:t\(t):compile\(c)"
                let start = base + 0.001 * Double(c % 50)
                tasks.append(task("CompileC", .clangCompile, target: t, key: key, start: start,
                                  end: start + 0.05 + 0.4 * Double((c * 7919) % 100) / 100))
                objects.append("/obj/\(t)/\(c).o")
                commands.append(.init(key: key, tool: "ccompile", inputs: ["<\(t)-begin>", "/src/\(t)/\(c).c"],
                                      outputs: [objects[c]]))
            }
            let link = "P0:t\(t):link"
            tasks.append(task("Ld", .link, target: t, key: link, start: base + 0.6, end: base + 0.8))
            commands.append(.init(key: link, tool: "shell", inputs: objects, outputs: ["/bin/\(t)"]))
            commands.append(.init(key: "gate-\(t)-end", tool: "phony", inputs: objects + ["/bin/\(t)", "<\(t)-begin>"],
                                  outputs: ["<\(t)-end>"]))
        }
        let model = TestModels.model(tasks, targets: (0..<targets).map { TestModels.target($0, "T\($0)") },
                                     start: 0, end: Double(targets) + 0.1)
        let description = BuildDescription(signature: nil, directory: URL(fileURLWithPath: "/synthetic"),
                                           commands: commands, targetGraph: [],
                                           buildRequest: .init(action: "build", enableIndexBuildArena: nil, raw: [:]))
        return (model, description)
    }
}
