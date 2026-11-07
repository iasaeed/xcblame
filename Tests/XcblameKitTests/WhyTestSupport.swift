import Foundation
import XCTest
@testable import XcblameKit

/// The v0.5 probe fixtures of lane B (docs/research/probes-v0.5.md §MV-2, §MV-8): clean, zero-change and incremental
/// logs of the same AcmeApp scratch copy, with Task Backtraces (`*-why`) or driver remarks (`*-incremental-remarks`).
enum WhyFixtures {
    static let logs = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/logs")

    struct Set {
        var name: String
        var clean: URL
        var zeroChange: URL
        var incremental: URL
        var xcresultIncremental: URL?
        var xcode: String
    }

    static let why26 = Set(
        name: "26", clean: logs.appendingPathComponent("cli-xcode26-why/857BD95F-03FD-4CFE-88B9-F6A5A26CBD64.xcactivitylog"),
        zeroChange: logs.appendingPathComponent("cli-xcode26-why/CEEF88A0-5057-4971-91D3-A07C8E6E6536.xcactivitylog"),
        incremental: logs.appendingPathComponent("cli-xcode26-why/408C3D38-3634-4108-91B8-EBF7C67092E8.xcactivitylog"),
        xcresultIncremental: logs.appendingPathComponent("cli-xcode26-why/xcresult-buildlog-inc.json.gz"), xcode: "26")
    static let why27 = Set(
        name: "27.1", clean: logs.appendingPathComponent("cli-xcode27.1b-why/A4C1931D-E0A1-4E62-8CE7-4638BEE0AB76.xcactivitylog"),
        zeroChange: logs.appendingPathComponent("cli-xcode27.1b-why/CA2F66C2-23AC-45B9-8706-CF30D41B6C2F.xcactivitylog"),
        incremental: logs.appendingPathComponent("cli-xcode27.1b-why/DC6A2EEF-851B-495D-A7B6-775702F5E702.xcactivitylog"),
        xcresultIncremental: logs.appendingPathComponent("cli-xcode27.1b-why/xcresult-buildlog-inc.json.gz"), xcode: "27.1")
    /// Driver remarks: the interface-edit build is the incremental one (`F7EF…` on 26, `878805DE…` on 27.1).
    static let remarks26 = Set(
        name: "remarks 26",
        clean: logs.appendingPathComponent("cli-xcode26-incremental-remarks/CAFEC72B-3BF0-419B-BA3F-A06D8015B139.xcactivitylog"),
        zeroChange: logs.appendingPathComponent("cli-xcode26-incremental-remarks/B7E7D8C0-537E-45CC-B0B8-EB0D4310022B.xcactivitylog"),
        incremental: logs.appendingPathComponent("cli-xcode26-incremental-remarks/F7EF5469-BA72-4756-916B-1BC6F1E5D04B.xcactivitylog"),
        xcresultIncremental: nil, xcode: "26")
    static let remarks27 = Set(
        name: "remarks 27.1",
        clean: logs.appendingPathComponent("cli-xcode27.1b-incremental-remarks/6FD64673-02F9-4A6A-8097-72AFD44250D5.xcactivitylog"),
        zeroChange: logs.appendingPathComponent("cli-xcode27.1b-incremental-remarks/E682ED65-122F-4C00-A44F-04432EDC9E35.xcactivitylog"),
        incremental: logs.appendingPathComponent("cli-xcode27.1b-incremental-remarks/878805DE-2C65-4BF3-B26A-91B26AAD142D.xcactivitylog"),
        xcresultIncremental: nil, xcode: "27.1")

    static let all = [why26, why27, remarks26, remarks27]

    /// Model and pipeline document of a log, as `analyze` builds them (no build description, fixed time).
    static func report(_ url: URL, topN: Int = 15) throws -> (model: BuildModel, document: ReportDocument) {
        let model: BuildModel
        if url.lastPathComponent.hasSuffix(".json.gz") {
            model = BuildModelBuilder.build(try XCResultReader.read(jsonData: Data(GzipFile.inflate(contentsOf: url).bytes)),
                                            reader: .xcresult)
        } else {
            model = BuildModelBuilder.build(try SLFReader.read(url: url), reader: .slf)
        }
        let options = ReportPipeline.Options(topN: topN, generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                             inputPath: url.path)
        return (model, try ReportPipeline.run(model, options: options).document)
    }

    /// A fresh history folder holding `logs` (oldest first), removed after the test.
    static func history(_ logs: [URL], test: XCTestCase) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-why-\(UUID().uuidString)/history")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        test.addTeardownBlock { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        for (offset, log) in logs.enumerated() {
            var (model, document) = try report(log)
            // Recent: entries older than `History.keepDays` are pruned on save.
            document.generatedAt = Date().addingTimeInterval(-3_600 + Double(offset) * 60)
            _ = try History.save(document: document, model: model, directory: dir)
        }
        return dir
    }

    /// A small hand-made build for the provider tests: tasks run one after the other from a fixed epoch.
    struct Mini {
        var tasks: [BuildTask] = []
        var targets: [Target] = []
        var diagnostics: [Diagnostic] = []
        var clock = 1_700_000_000.0

        mutating func target(_ name: String) -> Int {
            if let found = targets.firstIndex(where: { $0.name == name }) { return found }
            targets.append(Target(id: targets.count, name: name, project: "P", path: nil, isPackage: false,
                                  isBucket: false, taskIds: []))
            return targets.count - 1
        }

        @discardableResult
        mutating func task(_ rule: String, target name: String?, seconds: Double = 1, title: String? = nil,
                           key: String? = nil, details: String? = nil, output: String? = nil,
                           frames: [Backtrace.Frame]? = nil, diagnostic: String? = nil) -> Int {
            let entry = KindTable.v1.lookup(rule)
            let targetId = name.map { target($0) }
            let id = tasks.count
            var diagnosticIds: [Int] = []
            if let diagnostic {
                diagnostics.append(Diagnostic(id: diagnostics.count, severity: .warning, text: diagnostic, category: nil,
                                              file: nil, line: nil, column: nil, endLine: nil, endColumn: nil,
                                              occurrences: 1, taskIds: [id]))
                diagnosticIds = [diagnostics.count - 1]
            }
            tasks.append(BuildTask(
                id: id, ruleName: rule, kind: entry?.kind ?? .other, kindSource: entry == nil ? .none : .rule,
                phase: entry?.phase ?? .other, targetId: targetId, start: clock, end: clock + seconds, duration: seconds,
                resultCode: 0, metrics: nil, backtrace: frames.map(Backtrace.init(frames:)), taskKey: key, subspans: [],
                commandDetails: details ?? (rule + " " + (title ?? rule) + (name.map { " (in target '\($0)' from project 'P')" } ?? "")),
                signature: nil, title: title ?? rule, emittedOutput: output, diagnosticIds: diagnosticIds, slfOnly: nil,
                unknownAttachments: []))
            if let targetId { targets[targetId].taskIds.append(id) }
            clock += seconds
            return id
        }

        func model() -> BuildModel {
            BuildModel(readerKind: .slf, formatVersion: 11, layout: .commandLine, sessionStart: 1_700_000_000,
                       sessionEnd: clock, tasks: tasks, targets: targets, diagnostics: diagnostics, decodeWarnings: [],
                       degradations: [], unclassifiedShare: 0, timingSummary: nil, buildAttachments: [],
                       kindTableVersion: KindTable.v1.version)
        }

        func document(_ model: BuildModel) throws -> ReportDocument {
            try ReportPipeline.run(model, options: .init(topN: .max, generatedAt: Date(timeIntervalSince1970: 0))).document
        }
    }

    /// One frame of an attachment.
    static func frame(_ category: String, _ kind: String, _ description: String, id: String? = nil) -> Backtrace.Frame {
        var frame = Backtrace.Frame(category: category, description: description)
        frame.frameKind = kind
        frame.identifier = id
        return frame
    }

    /// The incremental log of `set` attributed against its clean log's index.
    static func attributed(_ set: Set, test: XCTestCase, topN: Int = 15) throws -> (model: BuildModel, document: ReportDocument) {
        let history = try history([set.clean], test: test)
        let (model, document) = try report(set.incremental, topN: topN)
        return (model, CauseEngine.attach(to: document, model: model, historyDir: history, project: nil))
    }
}
