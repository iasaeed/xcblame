import ArgumentParser
import Foundation
import XcblameKit

/// `xcblame history list|show|prune` (DESIGN §3.2, §8.3). Lane B.
struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Manage the local build history.",
        subcommands: [List.self, Show.self, Prune.self])

    struct StateOptions: ParsableArguments {
        @Option(name: .customLong("xcblame-dir"), help: "xcblame state folder (snapshots, history, reports).",
                completion: .directory)
        var xcblameDir: String = ".xcblame"

        var historyDirectory: URL {
            URL(fileURLWithPath: NSString(string: xcblameDir).expandingTildeInPath).standardizedFileURL
                .appendingPathComponent("history")
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List recorded builds.")

        @OptionGroup var state: StateOptions

        func run() throws {
            let items = History.list(directory: state.historyDirectory)
            guard !items.isEmpty else {
                print("no history in \(state.historyDirectory.path)")
                return
            }
            let width = items.map(\.id.count).max() ?? 0
            print("ID".padding(toLength: width, withPad: " ", startingAt: 0) + "  TIME                 KIND          "
                + "SPAN      TASKS")
            for item in items {
                let time = item.time.map { Self.timeFormatter.string(from: $0) } ?? "unknown"
                let span = item.span.map { String(format: "%.1f s", $0) } ?? "-"
                print(item.id.padding(toLength: width, withPad: " ", startingAt: 0) + "  "
                    + time.padding(toLength: 19, withPad: " ", startingAt: 0) + "  "
                    + item.kind.padding(toLength: 12, withPad: " ", startingAt: 0) + "  "
                    + span.padding(toLength: 8, withPad: " ", startingAt: 0) + "  "
                    + (item.tasks.map(String.init) ?? "-"))
            }
        }

        private static var timeFormatter: DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return formatter
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Show one recorded build.")

        @Argument(help: "History entry id (from history list), or a unique prefix of it.") var id: String
        @Flag(help: "Print the stored entry as JSON (report plus taskIndexRows) instead of the text report.")
        var json = false
        @OptionGroup var state: StateOptions

        func run() throws {
            let shown: History.Shown
            do { shown = try History.show(id: id, directory: state.historyDirectory) } catch let error as History.HistoryError {
                writeStderr("error: \(error)")
                if case .notFound = error { throw ArgumentParser.ExitCode(XcblameExit.logNotFound.rawValue) }
                throw ArgumentParser.ExitCode(XcblameExit.internalError.rawValue)
            }
            if json {
                FileHandle.standardOutput.write(shown.json)
                print("")
                return
            }
            print("history entry \(shown.item.id) (\(shown.taskIndexRows.count) task index rows)")
            print(TextReporter.render(shown.document), terminator: "")
        }
    }

    struct Prune: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "prune",
            abstract: "Delete old history entries (default: keep the newest \(History.keepEntries) and drop "
                + "entries older than \(History.keepDays) days).")

        @Option(help: "Keep the newest n entries.") var keep: Int?
        @Option(name: .customLong("older-than"), help: "Delete entries older than this many days.") var olderThan: Int?
        @Flag(name: .customLong("oracle-cache"),
              help: "Also delete the whole settings-oracle cache (~/Library/Caches/xcblame/oracle); by default only entries unused for \(OracleCache.keepDays) days go.")
        var oracleCache = false
        @OptionGroup var state: StateOptions

        func validate() throws {
            if let keep, keep < 0 { throw ValidationError("--keep must be 0 or greater") }
            if let olderThan, olderThan < 0 { throw ValidationError("--older-than must be 0 or greater") }
        }

        func run() throws {
            let neither = keep == nil && olderThan == nil
            let removed = try History.prune(directory: state.historyDirectory,
                                            keep: neither ? History.keepEntries : keep,
                                            olderThanDays: neither ? History.keepDays : olderThan)
            // v0.4 lane C (begin): one entry per log, then the same 200 / 90 d policy for results, logs and reports.
            let duplicates = try Retention.dedupeHistory(directory: state.historyDirectory)
            let retained = try Retention.apply(stateDir: state.historyDirectory.deletingLastPathComponent())
            // v0.4 lane C (end)
            let left = History.list(directory: state.historyDirectory, details: false).count
            print("removed \(removed) history entries, \(left) kept")
            // v0.4 lane C (begin)
            if duplicates > 0 { print("removed \(duplicates) duplicate history entries (same log)") }
            for folder in Retention.folders where (retained.removed[folder] ?? 0) > 0 {
                print("removed \(retained.removed[folder] ?? 0) old entries from \(folder)/")
            }
            // v0.4 lane C (end)
            let oracle = OracleCache.prune(home: OracleCache.home(), olderThanDays: oracleCache ? nil : OracleCache.keepDays)
            if oracle > 0 || oracleCache { print("removed \(oracle) settings-oracle cache entries") }
            // v0.5 lane A (begin): `build --deep` DerivedData, same rules (30 days, 20 GiB).
            let deep = DeepDerivedData.prune(home: OracleCache.home(), olderThanDays: DeepDerivedData.keepDays)
            if deep > 0 { print("removed \(deep) deep DerivedData entries") }
            // v0.5 lane A (end)
            // v0.6 lane B (begin): `history/verify/` entries (`History.pruneVerify`) and per-arm verify DerivedData
            // (`VerifyDerivedData.prune`), same rules.
            let verifyEntries = try History.pruneVerify(directory: state.historyDirectory,
                                                        keep: neither ? History.keepEntries : keep,
                                                        olderThanDays: neither ? History.keepDays : olderThan)
            if verifyEntries > 0 { print("removed \(verifyEntries) verify history entries") }
            let verifyDerived = VerifyDerivedData.prune(home: OracleCache.home(), olderThanDays: VerifyDerivedData.keepDays)
            if verifyDerived > 0 { print("removed \(verifyDerived) verify DerivedData entries") }
            // v0.6 lane B (end)
        }
    }
}
