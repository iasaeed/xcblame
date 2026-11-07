import Foundation
import XcblameKit

/// What a `compare` operand or a `baseline save --from` value turned into: a saved report, a build log analyzed on the
/// spot, or a history entry (docs/SCHEMA-v0.4.md "CompareDocument").
struct CompareOperand {
    enum Kind: String { case report, log, history }

    var kind: Kind
    var input: Compare.Input
    /// The task index of a log operand (the compare html draws both timelines from it); nil for reports and history.
    var taskIndex: TaskIndex?
    /// Basename of the file or the history id: what a baseline records as its source ref.
    var ref: String
}

/// Resolves one operand with the loaders `analyze` uses: an existing path goes through `loadModelOrReport` (saved
/// report JSON, `.xcactivitylog`, `.xcresult`, DerivedData and `Logs/Build` folders); anything else is a history entry
/// id (or unique prefix) in `<xcblame-dir>/history`.
func loadCompareOperand(_ operand: String, stateDir: URL, verbose: Bool = false, quiet: Bool = false) throws -> CompareOperand {
    let url = URL(fileURLWithPath: NSString(string: operand).expandingTildeInPath).standardizedFileURL
    if FileManager.default.fileExists(atPath: url.path) {
        switch try loadModelOrReport(at: url, options: LoadOptions(verbose: verbose, quiet: quiet)) {
        case let .report(document, path):
            return CompareOperand(kind: .report, input: Compare.Input(source: path, documents: [document]), taskIndex: nil,
                                  ref: url.lastPathComponent)
        case let .model(loaded):
            if let note = loaded.note, !quiet { writeStderr("note: \(note)") }
            return try analyzeOperand(loaded, stateDir: stateDir)
        }
    }
    do {
        let shown = try History.show(id: operand, directory: stateDir.appendingPathComponent("history"))
        return CompareOperand(kind: .history,
                              input: Compare.Input(source: shown.item.id, documents: [shown.document],
                                                   taskRows: [shown.taskIndexRows]),
                              taskIndex: nil, ref: shown.item.id)
    } catch let error as History.HistoryError {
        switch error {
        case .notFound:
            throw XcblameError.noBuildLog("\(operand) is not a file, and no history entry in "
                + "\(stateDir.appendingPathComponent("history").path) matches it (xcblame history list shows the ids)")
        case .ambiguous: throw XcblameError.usage("\(error)")
        case .unreadable: throw XcblameError.readerFailure("\(error)")
        }
    }
}

/// A log becomes a report with every row (`--top all`), the build description when one is found, its build context, and
/// no environment snapshot: this machine is not necessarily the one that built the log, so it must not show up as a difference.
private func analyzeOperand(_ loaded: LoadedModel, stateDir: URL) throws -> CompareOperand {
    let logURL = URL(fileURLWithPath: loaded.path)
    let description = BuildDescriptionLocator.find(model: loaded.model, logURL: logURL, explicit: nil,
                                                   snapshotsDir: stateDir.appendingPathComponent("snapshots"))
    var options = ReportPipeline.Options(topN: .max, generatedAt: Date(), inputPath: loaded.path,
                                         buildDescription: description)
    options.checksSize = false
    // The same build context `analyze` records (scheme from the log manifest, configuration and destination from the
    // build request), so a log operand has a baseline key and `compare` / `baseline save` match on it.
    options.buildContext = BuildContext.from(manifestScheme: loaded.scheme).filling(
        from: description.map { BuildContext.from(buildRequest: $0.buildRequest.raw) } ?? BuildContext())
    let result = try ReportPipeline.run(loaded.model, options: options)
    return CompareOperand(
        kind: .log,
        input: Compare.Input(source: loaded.path, documents: [result.document],
                             taskRows: [Compare.taskRows(document: result.document, model: loaded.model)]),
        taskIndex: TaskIndex.make(model: loaded.model, analysis: result.analysis, document: result.document),
        ref: logURL.lastPathComponent)
}
