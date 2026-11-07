import ArgumentParser
import Foundation
import XcblameKit

/// `xcblame baseline save|show` (DESIGN §3.2; docs/SCHEMA-v0.4.md "Baseline"). Lane B.
struct BaselineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "baseline",
        abstract: "Write or show the committed baseline (.xcblame/baseline.json, summaries only).",
        subcommands: [Save.self, Show.self])

    struct StateOptions: ParsableArguments {
        @Option(name: .customLong("xcblame-dir"), help: "xcblame state folder (history, baseline.json).",
                completion: .directory)
        var xcblameDir: String = ".xcblame"

        var baselineURL: URL {
            URL(fileURLWithPath: NSString(string: xcblameDir).expandingTildeInPath).standardizedFileURL
                .appendingPathComponent(Baseline.fileName)
        }
    }

    struct Save: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "save",
            abstract: "Summarize builds into a baseline file: medians and MADs, no paths, no task commands.")

        @Option(help: "A saved JSON report, a build log or a history entry id; repeat it for one run each (3 or more give a noise band).")
        var from: [String] = []
        @Option(help: "Use the newest history entries of this build kind (clean, incremental, ...).") var kind: String?
        @Option(help: "How many of the newest matching history entries to use (default 1).") var last: Int?
        @Option(name: [.short, .long], help: "Write the baseline here (default: <xcblame-dir>/baseline.json).",
                completion: .file(extensions: ["json"]))
        var output: String?
        @Flag(name: .customLong("with-tasks"), help: "Also store task digests, so compare can name new and removed tasks without the log.")
        var withTasks = false
        @OptionGroup var state: StateOptions

        func validate() throws {
            if let last, last < 1 { throw ValidationError("--last must be 1 or greater") }
            if !from.isEmpty, kind != nil || last != nil { throw ValidationError("give either --from or --kind/--last, not both") }
        }

        func run() throws {
            // v0.4 lane B (begin): pick the runs, `Baseline.make`, `save(to: output ?? state.baselineURL)`.
            let stateURL = state.baselineURL.deletingLastPathComponent()
            var documents: [ReportDocument] = []
            var rows: [[History.TaskIndexRow]?] = []
            var refs: [String] = []
            var sourceKind = "history"
            var notes: [String] = []
            if from.isEmpty {
                let count = last ?? 1
                let runs = Baseline.selectHistory(directory: stateURL.appendingPathComponent("history"), kind: kind, count: count)
                guard !runs.entries.isEmpty else {
                    throw XcblameError.noBuildLog("no history entry" + (kind.map { " of kind \($0)" } ?? "") + " in "
                        + stateURL.appendingPathComponent("history").path
                        + " (run xcblame analyze or build first, or pass --from <report|log|id>)")
                }
                documents = runs.entries.map(\.document)
                rows = runs.entries.map { Optional($0.taskIndexRows) }
                refs = runs.entries.map(\.item.id)
                if runs.available < count {
                    notes.append("history: \(runs.available) matching entr\(runs.available == 1 ? "y" : "ies") for "
                        + "\(count) requested")
                }
                if runs.deep > 0 {
                    notes.append("history: \(runs.deep) build --deep entr\(runs.deep == 1 ? "y was" : "ies were") left out "
                        + "(timing flags in their own DerivedData)")
                }
                if runs.otherKey > 0 {
                    notes.append("history: \(runs.otherKey) entr\(runs.otherKey == 1 ? "y" : "ies") with another kind, scheme, "
                        + "configuration, destination or Xcode version than the newest were left out")
                }
            } else {
                let operands = try from.map { try loadCompareOperand($0, stateDir: stateURL) }
                documents = operands.flatMap(\.input.documents)
                rows = operands.map { $0.input.taskRows?.first }
                refs = operands.map(\.ref)
                sourceKind = operands.first?.kind.rawValue ?? "report"
                if Set(operands.map(\.kind)).count > 1 { notes.append("source: the runs come from different kinds of input") }
            }
            let median = Baseline.medianRunIndex(of: documents)
            var taskRows: [History.TaskIndexRow]?
            if withTasks {
                taskRows = rows.indices.contains(median) ? rows[median] : nil
                if taskRows == nil {
                    notes.append("tasks: the median run has no task rows (a saved report carries none; use a log or a history id)")
                }
            }
            var baseline = try Baseline.make(from: documents, source: Baseline.Source(kind: sourceKind, refs: refs),
                                             taskRows: taskRows)
            baseline.notes += notes
            let url = output.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) } ?? state.baselineURL
            try baseline.save(to: url)
            print("wrote \(url.path) (\(baseline.runs) run\(baseline.runs == 1 ? "" : "s") from \(baseline.source.kind)"
                + (baseline.wall.median.map { ", wall median " + TextReporter.duration($0) } ?? "") + ")")
            for note in baseline.notes { writeStderr("note: \(note)") }
            // v0.4 lane B (end)
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Show a baseline file.")

        @Argument(help: "Baseline file (default: <xcblame-dir>/baseline.json).", completion: .file(extensions: ["json"]))
        var file: String?
        @Flag(help: "Print the baseline JSON as stored.") var json = false
        @OptionGroup var state: StateOptions

        func run() throws {
            // v0.4 lane B (begin): `Baseline.load`, print the summary (or the JSON with --json).
            let url = file.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) } ?? state.baselineURL
            let baseline = try Baseline.load(from: url)
            if json {
                FileHandle.standardOutput.write(try Data(contentsOf: url))
            } else {
                print(baseline.textSummary(path: url.path), terminator: "")
            }
            // v0.4 lane B (end)
        }
    }
}
