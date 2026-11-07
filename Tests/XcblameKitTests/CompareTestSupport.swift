import Foundation
import XCTest
@testable import XcblameKit

/// Reports for the regression, baseline and compare tests: hand-made numbers on the synthetic report, and the two
/// AcmeApp clean builds (Xcode 26.0 and 27.1 beta) of the fixtures with every row.
enum CompareFixtures {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    /// A report with the given wall (span), busy and critical path, same build key unless overridden.
    static func report(span: Double, busy: Double? = nil, path: Double? = nil, processWall: Double? = nil,
                       kind: String? = "clean", scheme: String? = "App", configuration: String? = "Debug",
                       destination: String? = "macOS arm64", xcode: String? = "26.0",
                       generatedAt: Date = date) throws -> ReportDocument {
        var doc = try syntheticReport()
        doc.build.span = span
        doc.build.busy = busy ?? span - 0.1
        doc.build.kind = kind
        doc.build.scheme = scheme
        doc.build.configuration = configuration
        doc.build.destination = destination
        doc.xcode.value = xcode
        doc.timing.processWall = processWall
        doc.generatedAt = generatedAt
        if var criticalPath = doc.criticalPath { criticalPath.span = path ?? span; doc.criticalPath = criticalPath }
        return doc
    }

    static func reports(_ walls: [Double], processWalls: [Double]? = nil, xcode: String? = "26.0") throws -> [ReportDocument] {
        try walls.enumerated().map { index, wall in
            try report(span: wall, processWall: processWalls?[index], xcode: xcode)
        }
    }

    struct Build {
        var document: ReportDocument
        var rows: [History.TaskIndexRow]
        var index: TaskIndex
    }

    private static func build(_ url: URL) -> Build {
        let model = BuildModelBuilder.build(try! SLFReader.read(url: url), reader: .slf)
        let result = try! ReportPipeline.run(model, options: .init(topN: .max, generatedAt: date, inputPath: url.path))
        return Build(document: result.document, rows: Compare.taskRows(document: result.document, model: model),
                     index: TaskIndex.make(model: model, analysis: result.analysis, document: result.document))
    }

    static let xcode26 = build(SLFFixtures.cli26Clean)
    static let xcode27 = build(SLFFixtures.cli27Clean)

    static func tempDirectory(_ test: XCTestCase) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-compare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    static func row(_ rule: String, _ target: String?, _ sig: String, ms: Int, onPath: Bool = false) -> History.TaskIndexRow {
        .init(key: nil, rule: rule, target: target, kind: "swiftCompile", sigDigest: sig, durationMs: ms, onPath: onPath)
    }
}
