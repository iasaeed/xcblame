import Foundation

/// Plain-text `xcblame compare` (DESIGN §3.3 style): headline delta with noise band and verdict, the environment
/// differences first, then the diverging tables. Renders from the `CompareDocument` only, so the numbers are the
/// JSON's numbers.
public enum CompareTextReporter {
    public static func render(_ doc: CompareDocument, colors: Bool = false) -> String {
        let t = TextReporter(colors: colors)
        var lines: [String] = []
        lines.append(t.bold("xcblame \(doc.tool.version) compare") + " · a " + t.safe(doc.a.source) + " · b " + t.safe(doc.b.source))
        lines.append(sideLine(doc.a, t))
        lines.append(sideLine(doc.b, t))
        for note in doc.notes where Compare.isDeepNote(note) { lines.append(t.warn("  note: " + t.safe(note))) }
        lines.append(contentsOf: t.regressionBlock(doc.regression, title: "RESULT", against: "a"))
        lines.append(contentsOf: environment(doc, t))
        if let rows = doc.phases {
            lines.append(contentsOf: rowTable("PHASES", rows, t, tasks: true))
        }
        if let rows = doc.targets {
            var table = rowTable("TARGETS", rows, t, tasks: true)
            if rows.count < doc.targetsTotal {
                table.append(t.dim("  shown \(rows.count) of \(doc.targetsTotal) rows = "
                    + t.pct(doc.targetsShownShare) + " of the total change"))
            }
            lines.append(contentsOf: table)
        }
        if let path = doc.criticalPath {
            lines.append(t.bold("CRITICAL PATH") + "  span \(span(path.span, t))")
            lines.append(contentsOf: rowTable("", path.byTarget, t, tasks: false))
            for note in path.notes { lines.append(t.dim("  " + t.safe(note))) }
        }
        lines.append(contentsOf: taskLines(doc.tasks, t))
        lines.append(contentsOf: settingLines(doc, t))
        let notes = doc.notes.filter { !Compare.isDeepNote($0) }
        if !notes.isEmpty {
            lines.append(t.bold("NOTES"))
            for note in notes { lines.append("  " + t.safe(note)) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Sections

    static func sideLine(_ side: CompareDocument.Side, _ t: TextReporter) -> String {
        var parts: [String] = []
        parts.append(side.kind ?? "kind unknown")
        for value in [side.scheme, side.configuration, side.destination] { if let value { parts.append(t.safe(value)) } }
        parts.append("xcode " + (side.xcode ?? "unknown"))
        parts.append("\(side.runs) run\(side.runs == 1 ? "" : "s")")
        parts.append("wall " + t.dur(side.wall))
        parts.append("\(side.tasks) tasks")
        parts.append(t.plural(side.errors, "error") + ", " + t.plural(side.warnings, "warning"))
        if side.degraded { parts.append(t.warn("DEGRADED")) }
        return "  \(side.label)  " + parts.joined(separator: " · ")
    }

    static func environment(_ doc: CompareDocument, _ t: TextReporter) -> [String] {
        let head = t.bold("ENVIRONMENT") + "  \(doc.env.count) of \(doc.envCompared) compared fields differ"
        guard !doc.env.isEmpty else { return [head + " (no environment differences)"] }
        var lines = [head]
        let width = doc.env.map(\.field.count).max() ?? 0
        for diff in doc.env {
            let label = diff.field.padding(toLength: width, withPad: " ", startingAt: 0)
            lines.append("  \(label)  \(t.safe(shortened(diff)))")
        }
        return lines
    }

    private static func shortened(_ diff: CompareDocument.EnvDiff) -> String {
        func show(_ value: String?) -> String {
            guard let value else { return "unknown" }
            return diff.field == "commit" ? String(value.prefix(10)) : value
        }
        return "\(show(diff.a)) -> \(show(diff.b))" + (diff.field == "xcode" ? " (inferred)" : "")
    }

    static func span(_ pair: CompareDocument.Pair, _ t: TextReporter) -> String {
        "\(t.dur(pair.a)) -> \(t.dur(pair.b)) (\(change(pair)))"
    }

    private static func change(_ pair: CompareDocument.Pair) -> String {
        guard let delta = pair.delta else { return "unknown" }
        var text = Regression.signed(delta)
        if let share = pair.deltaPct { text += String(format: " %+.1f %%", share * 100) }
        return text
    }

    static func rowTable(_ title: String, _ rows: [CompareDocument.Row], _ t: TextReporter, tasks: Bool) -> [String] {
        var headers = ["a", "b", "delta", "change"]
        if tasks { headers += ["tasks a", "tasks b"] }
        let body = rows.map { row -> [String] in
            var change = row.seconds.deltaPct.map { String(format: "%+.0f%%", $0 * 100) } ?? "n/a"
            if row.status == "added" { change = "new" } else if row.status == "removed" { change = "gone" }
            var cells = ["  " + t.clip(row.key), t.dur(row.seconds.a), t.dur(row.seconds.b),
                         row.seconds.delta.map(Regression.signed) ?? "n/a", change]
            if tasks {
                cells += [row.tasks?.a.map { String(Int($0)) } ?? "", row.tasks?.b.map { String(Int($0)) } ?? ""]
            }
            return cells
        }
        return t.table(title: title, headers: headers, rows: body)
    }

    /// Task rows per list in the text report; the JSON and html carry up to `--top`.
    static let textRows = 10

    static func taskLines(_ tasks: CompareDocument.TaskDiff, _ t: TextReporter) -> [String] {
        guard tasks.available else {
            return [t.bold("TASKS") + "  not compared: " + t.safe(tasks.notes.first ?? "no task rows")]
        }
        var lines: [String] = []
        for (title, rows, total, share) in [("NEW TASKS", tasks.added, tasks.addedTotal, tasks.addedShownShare),
                                            ("REMOVED TASKS", tasks.removed, tasks.removedTotal, tasks.removedShownShare)] {
            guard total > 0 else {
                lines.append(t.bold(title) + "  none")
                continue
            }
            let body = rows.prefix(textRows).map { ["  " + t.clip($0.rule), t.dur($0.seconds), t.clip($0.target ?? "-"), $0.onPath ? "on path" : ""] }
            lines += t.table(title: title, headers: ["time", "target", ""], rows: body, leftAligned: [2, 3])
            lines.append(t.dim("  shown \(min(rows.count, textRows)) of \(total) tasks"
                + (rows.count <= textRows ? " = \(t.pct(share)) of their time" : "") + " (--format json lists \(rows.count))"))
        }
        if tasks.changedTotal > 0 {
            let net = tasks.changed.reduce(0) { $0 + ($1.seconds.delta ?? 0) }
            lines.append(t.bold("CHANGED TASKS") + "  \(tasks.changedTotal) ran on both sides with another command line "
                + "(paired by name), net " + Regression.signed(net) + (tasks.changed.count < tasks.changedTotal ? " for the \(tasks.changed.count) listed" : ""))
        }
        return lines
    }

    static func settingLines(_ doc: CompareDocument, _ t: TextReporter) -> [String] {
        guard let settings = doc.settings else { return [] }
        guard !settings.isEmpty else { return [t.bold("SETTINGS") + "  no setting differs"] }
        var lines = [t.bold("SETTINGS") + "  \(settings.count) differ"]
        for setting in settings {
            lines.append("  " + t.clip(setting.ref, limit: 70) + "  " + t.safe(setting.a ?? "not evidenced") + " -> "
                + t.safe(setting.b ?? "not evidenced"))
        }
        return lines
    }
}
