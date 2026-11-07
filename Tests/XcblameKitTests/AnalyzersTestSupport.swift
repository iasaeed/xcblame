import Foundation
@testable import XcblameKit

/// Hand-built models for analyzer and reporter tests. Window is [100, 200] unless a test says otherwise.
enum TestModels {
    static func task(_ id: Int, _ rule: String = "SwiftCompile", kind: TaskKind = .swiftCompile,
                     phase: Phase = .compile, target: Int? = nil, start: Double, end: Double,
                     metrics: TaskMetrics? = nil) -> BuildTask {
        BuildTask(
            id: id, ruleName: rule, kind: kind, kindSource: .rule, phase: phase, targetId: target, start: start,
            end: end, duration: end - start, resultCode: 0, metrics: metrics, backtrace: nil, taskKey: nil,
            subspans: [], commandDetails: nil, signature: nil, title: "\(rule) \(id)", emittedOutput: nil,
            diagnosticIds: [], slfOnly: nil, unknownAttachments: [])
    }

    static func target(_ id: Int, _ name: String, project: String? = nil, bucket: Bool = false) -> Target {
        Target(id: id, name: name, project: project, path: nil, isPackage: false, isBucket: bucket, taskIds: [])
    }

    static func model(_ tasks: [BuildTask], targets: [Target] = [], start: Double = 100, end: Double = 200,
                      timingSummary: TimingSummary? = nil, decodeWarnings: [DecodeWarning] = []) -> BuildModel {
        BuildModel(
            readerKind: .slf, formatVersion: 11, layout: .commandLine, sessionStart: start, sessionEnd: end,
            tasks: tasks, targets: targets, diagnostics: [], decodeWarnings: decodeWarnings, degradations: [],
            unclassifiedShare: 0, timingSummary: timingSummary, buildAttachments: [], kindTableVersion: "test")
    }

    /// Intervals [100,104] [102,106] [108,110] [110,112] [105,105]: union 10 s, task time 12 s, peak 2.
    static func overlapping() -> BuildModel {
        model([
            task(0, start: 100, end: 104), task(1, start: 102, end: 106), task(2, start: 108, end: 110),
            task(3, start: 110, end: 112), task(4, start: 105, end: 105),
        ], start: 100, end: 120)
    }

    static func analyze(_ model: BuildModel, topN: Int = 15) -> Analysis { Timing.analyze(model, topN: topN) }

    static func validate(_ model: BuildModel, serializedBytes: Int? = nil,
                         budget: Int = Validator.defaultBudgetBytes) -> ValidationReport {
        Validator.validate(model, analysis: analyze(model), serializedBytes: serializedBytes, budgetBytes: budget)
    }
}
