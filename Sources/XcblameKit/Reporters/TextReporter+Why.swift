import Foundation

// v0.5 lane B (docs/SCHEMA-v0.5.md "Text"): the INCREMENTAL CAUSES block and the `why` text report.
extension TextReporter {
    /// The `why` report: header, time, INCREMENTAL CAUSES, critical path, targets, DYN-002 (when found), validation.
    public static func renderWhy(_ document: ReportDocument, colors: Bool = false) -> String {
        TextReporter(colors: colors).renderWhy(document)
    }

    func renderWhy(_ doc: ReportDocument) -> String {
        var lines = [bold("xcblame why \(doc.tool.version)") + " · " + safe(doc.input.path ?? "(no input path)")]
        lines += headerLines(doc)
        lines += timeLines(doc)
        lines += procedureLines(doc)
        let causes = incrementalLines(doc)
        if causes.isEmpty {
            let why = doc.notes.first { $0.hasPrefix("incremental: null") || $0.hasPrefix("incremental: not applicable") } ?? "incremental: not attributed"
            lines.append(bold("INCREMENTAL CAUSES") + "  unavailable: " + safe(why))
        } else {
            lines += causes
        }
        lines += criticalPathLines(doc)
        if let targets = doc.targets { lines += targetTable(doc, targets) } else { lines.append(unavailable("TARGETS", doc)) }
        if !doc.findings.isEmpty { lines += findingsLines(doc) }
        lines += validationLines(doc)
        return lines.joined(separator: "\n") + "\n"
    }

    /// `why` builds: one line per xcodebuild run.
    func procedureLines(_ doc: ReportDocument) -> [String] {
        guard let procedure = doc.incremental?.procedure else { return [] }
        var head = "  why     " + (procedure.mode == "touch" ? "touch " + safe(procedure.touched ?? "?") + " (mtime only)"
                                                             : "zero-change") + " · backtraces \(procedure.backtraces)"
        if procedure.showIncremental { head += " · -driver-show-incremental" }
        let touchNote = procedure.mode == "touch" ? ["          note: " + CauseEngine.touchNote] : []
        return [head] + touchNote + procedure.builds.map { build in
            var line = "          \(build.role): exit \(build.exitCode)"
            if let wall = build.wall { line += " · " + Self.duration(wall) }
            if let tasks = build.executedTasks { line += " · \(tasks) tasks" }
            if let work = build.executedWorkTasks { line += " (\(work) compile/plan/link)" }
            if let id = build.historyId { line += " · history \(id)" }
            return line
        }
    }

    /// Causes ranked by task time (top `topN`, then the `unknown` row always), each with seconds, share and path
    /// seconds and its top tasks (the cause tree: class → cause → tasks), then the path-seconds ranking on its own line
    /// (never added to task time), the unknown share with the `why --backtraces` hint, V15 and the notes. Empty when
    /// `incremental` is null.
    func incrementalLines(_ doc: ReportDocument) -> [String] {
        guard let incremental = doc.incremental else { return [] }
        let executed = incremental.v15.executedSeconds
        let byId = Dictionary(incremental.causes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var head = bold("INCREMENTAL CAUSES") + "  basis: "
        if let previous = incremental.previousBuild {
            head += "previous build \(previous.id)"
        } else {
            head += "this log only (no previous build of this scheme in history)"
        }
        head += " · executed " + dur(executed) + " · \(incremental.causes.count) causes"
        var lines = [head]

        let ranked = incremental.byTaskTime.compactMap { byId[$0] }.filter { $0.id != "unknown" }
        let shown = Array(ranked.prefix(max(1, doc.topN))) + (byId["unknown"].map { [$0] } ?? [])
        let classWidth = min(17, shown.map(\.class.count).max() ?? 0)
        for cause in shown {
            var line = "  " + cause.class.padding(toLength: classWidth, withPad: " ", startingAt: 0) + "  "
            line += Self.duration(cause.seconds).leftPadded(8) + " " + pct(executed.flatMap { $0 > 0 ? cause.seconds / $0 : nil }).leftPadded(4)
            if let path = cause.pathSeconds { line += "  path " + Self.duration(path) }
            line += "  " + clip(safe(cause.cause), limit: 90)
            if cause.id != "unknown" { line += dim(" [\(cause.source)]") }
            if let rule = cause.ruleId { line += " " + rule }
            lines.append(cause.id == "unknown" && cause.seconds > 0 ? warn(line) : line)
            let tasks = cause.tasks.prefix(3).map { task -> String in
                var text = clip(safe(task.label), limit: 40) + " " + Self.duration(task.seconds)
                if let path = task.pathSeconds, path > 0 { text += " (path " + Self.duration(path) + ")" }
                return text
            }
            if !tasks.isEmpty {
                let more = cause.tasksTotal > tasks.count ? ", +\(cause.tasksTotal - tasks.count) more" : ""
                lines.append("  " + String(repeating: " ", count: classWidth) + "    " + tasks.joined(separator: ", ") + more)
            }
            if let todo = cause.whatToDo, !todo.hasPrefix("Nothing to change") {
                lines.append("  " + String(repeating: " ", count: classWidth) + "    " + dim("what to do: " + safe(todo)))
            }
        }
        if ranked.count > shown.count - 1 { lines.append("  … \(ranked.count - (shown.count - 1)) more causes (--top)") }
        let byPath = incremental.byPathSeconds.compactMap { byId[$0] }.filter { ($0.pathSeconds ?? 0) > 0 }
        if byPath.isEmpty {
            lines.append("  by path seconds: " + (incremental.byPathSeconds.isEmpty ? "no critical path" : "no cause on the critical path"))
        } else {
            lines.append("  by path seconds: " + byPath.prefix(5).map {
                clip(safe($0.cause), limit: 40) + " " + Self.duration($0.pathSeconds ?? 0)
            }.joined(separator: " · ") + " (not added to task time)")
        }
        lines.append("  unknown share " + Self.duration(incremental.unknownSeconds) + " (" + pct(incremental.unknownShare) + ")"
            + (incremental.unknownSeconds > 0 || incremental.notes.contains { $0.hasPrefix("backtraces: none") }
                ? " · for more evidence: " + CauseEngine.backtracesHint : ""))
        let v15 = incremental.v15
        let v15Text = "  V15 \(v15.status): causes " + dur(v15.sumOfCauses) + " of " + dur(v15.executedSeconds) + " executed"
        lines.append(v15.status == "fail" ? fail(v15Text) : v15Text)
        // The touch note sits with the procedure lines (`procedureLines`), not again here.
        lines += incremental.notes.filter { $0 != CauseEngine.touchNote }.map { "  note: " + safe($0) }
        return lines
    }
}

extension String {
    fileprivate func leftPadded(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
