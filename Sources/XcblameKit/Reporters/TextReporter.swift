import Foundation

/// Plain-text report (DESIGN §3.3 layout). Renders from a `ReportDocument` only, so every number is the JSON's
/// number. Column widths adapt to content; colors only when asked (the CLI asks only for a TTY without `NO_COLOR`).
public struct TextReporter: Sendable {
    public var colors: Bool
    /// Longest title shown in a table cell.
    static let titleLimit = 56

    public init(colors: Bool = false) { self.colors = colors }

    public static func render(_ document: ReportDocument, colors: Bool = false) -> String {
        TextReporter(colors: colors).render(document)
    }

    public func render(_ doc: ReportDocument) -> String {
        var lines: [String] = []
        lines.append(bold("xcblame \(doc.tool.version)") + " · " + safe(doc.input.path ?? "(no input path)"))
        lines.append(contentsOf: headerLines(doc))
        lines.append(contentsOf: timeLines(doc))
        lines.append(contentsOf: regressionLines(doc))
        lines.append(contentsOf: criticalPathLines(doc))
        if let targets = doc.targets {
            lines.append(contentsOf: targetTable(doc, targets))
        } else {
            lines.append(unavailable("TARGETS", doc))
        }
        lines.append(contentsOf: fileLines(doc))
        lines.append(contentsOf: hotspotLines(doc))
        // v0.5 (lanes B, C): empty while the members are null.
        lines.append(contentsOf: incrementalLines(doc))
        lines.append(contentsOf: fixedCostLines(doc))
        lines.append(contentsOf: moduleGraphLines(doc))
        lines.append(contentsOf: findingsLines(doc))
        if let kinds = doc.kinds {
            lines.append(contentsOf: kindTable(kinds))
        } else {
            lines.append(unavailable("KINDS", doc))
        }
        if let top = doc.topTasks {
            lines.append(contentsOf: topTaskTable(doc, top))
        } else {
            lines.append(unavailable("TOP TASKS", doc))
        }
        lines.append(diagnosticsLine(doc.diagnosticsSummary))
        lines.append(contentsOf: validationLines(doc))
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Sections

    func headerLines(_ doc: ReportDocument) -> [String] {
        var log = "reader \(doc.input.reader)"
        if let version = doc.input.logFormatVersion { log = "\(doc.input.reader == "slf" ? "SLF" : "format") v\(version) · " + log }
        log += " · layout \(doc.input.layout)"
        if doc.input.decodeWarnings > 0 { log += " · \(doc.input.decodeWarnings) decode warning(s)" }
        let diag = doc.diagnosticsSummary
        var build: String
        if let kind = doc.build.kind {
            build = kind.uppercased()
            if !doc.build.kindEvidence.isEmpty {
                build += " (" + doc.build.kindEvidence.prefix(3).map(safe).joined(separator: ", ") + ")"
            }
        } else {
            let reason = doc.build.notes.first { $0.hasPrefix("kind: ") }.map { String($0.dropFirst(6)) }
            build = "kind unknown (\(safe(reason ?? "not classified")))"
        }
        if diag.errors > 0 { build += " · " + plural(diag.errors, "error") }
        if diag.warnings > 0 { build += " · " + plural(diag.warnings, "warning") }
        return [
            "  log     " + log,
        ] + doc.input.excludedActions.map { "  input   " + $0 } + degradationLines(doc) + [
            "  xcode   " + xcodeText(doc.xcode),
            "  build   " + build,
        ] + graphLines(doc.graph) + environmentLines(doc.environment)
    }

    func graphLines(_ graph: ReportDocument.Graph) -> [String] {
        let dropped = graph.notes.filter { $0.hasPrefix("dropped:") }.map { "          " + safe($0) }
        guard graph.basis != "none" else {
            return ["  graph   none (no build description for this log; critical path inferred from timing)"] + dropped
        }
        var line = "  graph   build description " + (graph.signature.map { String($0.prefix(8)) + " " } ?? "")
            + "(\(graph.basis))"
        if let commands = graph.commands { line += " · \(commands) commands" }
        line += " · \(graph.keyedTasks) tasks keyed, \(graph.unkeyedTasks) unkeyed"
        return [line] + dropped
    }

    // MARK: - Critical path, files, hotspots

    func criticalPathLines(_ doc: ReportDocument) -> [String] {
        guard let path = doc.criticalPath else {
            let why = doc.notes.first { $0.hasPrefix("criticalPath") } ?? "not computed"
            return [bold("CRITICAL PATH") + "  unavailable: " + safe(why)]
        }
        let basis: String
        switch path.basis {
        case "dag": basis = "DAG"
        case "mixed": basis = "DAG for planned tasks, timing for dynamic tasks"
        default: basis = "inferred from timing"
        }
        var rows: [[String]] = []
        var index = 0
        let pieces = path.segments.map { (start: $0.start, segment: Optional($0)) }
            + path.waits.map { (start: $0.start, segment: ReportDocument.PathSegment?.none) }
        let ordered = pieces.sorted { $0.start < $1.start }
        while index < ordered.count {
            guard let first = ordered[index].segment else {
                let wait = path.waits.first { $0.start == ordered[index].start }!
                rows.append([range(wait.start, wait.end), "(waiting: nothing on the path ran)",
                             String(format: "%.1f", wait.seconds), pct(path.span > 0 ? wait.seconds / path.span : nil)])
                index += 1
                continue
            }
            var group = [first]
            while index + 1 < ordered.count, let next = ordered[index + 1].segment, next.targetId == first.targetId,
                  next.target == first.target {
                group.append(next)
                index += 1
            }
            index += 1
            let seconds = group.reduce(0) { $0 + $1.seconds }
            let top = group.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.start < $1.start }
            var text = (first.target ?? "(no target)") + ": "
                + top.prefix(2).map { "\($0.label) \(Self.duration($0.seconds))" }.joined(separator: ", ")
            if group.count > 2 { text += ", +\(group.count - 2) more" }
            rows.append([range(first.start, group[group.count - 1].end), clip(text, limit: 76),
                         String(format: "%.1f", seconds),
                         pct(path.span > 0 ? seconds / path.span : nil)])
        }
        var widths = [0, 0, 1, 5]
        for row in rows { for column in 0..<4 { widths[column] = max(widths[column], row[column].count) } }
        func pad(_ text: String, _ width: Int, left: Bool) -> String {
            let gap = String(repeating: " ", count: max(0, width - text.count))
            return left ? text + gap : gap + text
        }
        let head = bold("CRITICAL PATH") + " \(Self.duration(path.span))  basis: \(basis)"
        var lines = [head]
        for row in rows {
            lines.append(("  " + pad(row[0], widths[0], left: false) + "  " + pad(row[1], widths[1], left: true) + "  "
                + pad(row[2], widths[2], left: false) + "  " + pad(row[3], widths[3], left: false))
                .trimmingTrailingSpaces())
        }
        if path.whatIf == nil { lines.append(dim("  what-if needs the task DAG (a matching build description)")) }
        return lines
    }

    func range(_ start: Double, _ end: Double) -> String { String(format: "%4.1f–%4.1f", start, end) }

    func fileLines(_ doc: ReportDocument) -> [String] {
        guard let files = doc.files else {
            let why = doc.notes.first { $0.contains("files") && ($0.contains("withheld") || $0.contains("unavailable")) }
            return [bold("FILES") + "  unavailable: " + safe(why ?? "not computed")]
        }
        guard !files.isEmpty else { return [bold("FILES") + "  no compile task names a source file"] }
        let rows = files.map { row -> [String] in
            var name = (row.path as NSString).lastPathComponent
            if let size = row.batchSize, size > 1 { name += " +\(size - 1)" }
            let badge = row.granularity == "batch" ? "batch(\(row.batchSize ?? 0))" : row.granularity
            return ["  " + clip(name), Self.duration(row.seconds), badge, clip(row.target ?? "-"),
                    row.typeCheckMs.map { Self.duration($0 / 1000) } ?? "", row.onPath ? "on path" : ""]
        }
        var lines = table(title: "FILES", headers: ["time", "granularity", "target", "type-check", ""], rows: rows,
                          leftAligned: [2, 3, 5])
        lines.append(dim("  shown \(files.count) of \(doc.filesTotal) files = \(pct(doc.filesShownShare)) of file "
            + "compile time"))
        if let totals = doc.notes.first(where: { $0.hasPrefix("files: ") }) {
            lines.append(dim("  " + safe(String(totals.dropFirst(7)))))
        }
        return lines
    }

    func hotspotLines(_ doc: ReportDocument) -> [String] {
        guard let hotspots = doc.hotspots else {
            return [bold("HOTSPOTS") + "  none: no type-check timing in this log (-debug-time-function-bodies, "
                + "warn-long diagnostics)"]
        }
        let head = bold("HOTSPOTS") + "  type-check (from text already in this log) · user code · "
            + "\(hotspots.count) of \(doc.hotspotsTotal)"
        guard !hotspots.isEmpty else { return [head] }
        let rows = hotspots.map { row -> [String] in
            ["  " + clip((row.file as NSString).lastPathComponent + ":\(row.line)"), Self.duration(row.ms / 1000),
             clip(row.declaration), row.onPathWeight == 1 && doc.criticalPath != nil ? "inside on-path compile" : ""]
        }
        var lines = [head] + Array(table(title: "", headers: ["type-check", "declaration", ""], rows: rows,
                                         leftAligned: [2, 3]).dropFirst())
        lines.append(dim("  shown \(hotspots.count) of \(doc.hotspotsTotal) = \(pct(doc.hotspotsShownShare)) of "
            + "user-code type-check ms"))
        return lines
    }

    func xcodeText(_ xcode: ReportDocument.Xcode) -> String {
        guard let value = xcode.value else { return "unknown (no version evidence in the log)" }
        var text = "\(value) (\(xcode.source ?? "inferred")"
        if let first = xcode.evidence.first { text += ": " + safe(first) }
        return text + ")"
    }

    func environmentLines(_ env: EnvSnapshot?) -> [String] {
        guard let env else { return [] }
        var parts: [String] = []
        if let version = env.macOSProductVersion { parts.append("macOS " + version) }
        if let model = env.hwModel { parts.append(model) }
        if let cpus = env.logicalCPUCount {
            var cpu = "\(cpus) CPUs"
            if let p = env.performanceCores, let e = env.efficiencyCores { cpu += " (\(p)P+\(e)E)" }
            parts.append(cpu)
        }
        if let memory = env.memoryBytes { parts.append("\(memory / (1 << 30)) GB") }
        if env.processTranslated == true { parts.append("Rosetta") }
        if let ci = env.ciProvider { parts.append("CI " + ci) }
        let version = env.xcodebuildVersion?.split(whereSeparator: \.isNewline).first.map(String.init)
        let machine = parts.isEmpty ? "unknown" : parts.joined(separator: " · ")
        return ["  env     " + machine + " (this machine, now)"]
            + (version.map { ["          selected \($0) at \(env.developerDir ?? "unknown")"] } ?? [])
    }

    func timeLines(_ doc: ReportDocument) -> [String] {
        let b = doc.build
        var first = "TIME  log span \(dur(b.span)) · busy \(dur(b.busy)) · idle \(dur(b.idle))"
            + " · task time \(dur(b.taskTime)) in \(b.tasks) tasks"
        if let avg = b.parallelism.average { first += String(format: " (%.1fx avg)", avg) }
        let m = doc.metrics
        var second = "      CPU \(m.cpuSeconds.map(Self.duration) ?? "unavailable")"
        second += " (\(m.tasksWithCPU) of \(m.tasks) tasks with metrics"
        if m.placeholdersIgnored > 0 { second += "; \(m.placeholdersIgnored) placeholder records ignored" }
        second += ") · " + (b.parallelism.peak.map { "peak \($0) lanes" } ?? "peak unavailable")
        var lines = [bold("TIME") + String(first.dropFirst(4)), second]
        if let third = utilizationLine(doc) { lines.append(third) }
        var extra: [String] = []
        if b.tasksReused > 0 { extra.append("\(b.tasksReused) reused (up to date, excluded)") }
        if b.tasksInvalid > 0 { extra.append("\(b.tasksInvalid) invalid (excluded)") }
        if b.tasksClamped > 0 { extra.append("\(b.tasksClamped) clamped to the window") }
        if b.tasksWithoutTimingTotal > 0 { extra.append("\(b.tasksWithoutTimingTotal) without timing (excluded)") }
        if !extra.isEmpty { lines.append("      " + extra.joined(separator: " · ")) }
        if b.tasksWithoutTimingTotal > 0 {
            let shown = b.tasksWithoutTiming.map { "\(clip($0.rule)) \"\(clip($0.title))\"" }
            let more = b.tasksWithoutTimingTotal - shown.count
            lines.append("      tasks without timing (\(b.tasksWithoutTimingTotal)): " + shown.joined(separator: ", ")
                + (more > 0 ? " (+\(more) more)" : ""))
        }
        return lines
    }

    /// Serial stretches, idle gaps and the process wall (§6.3), when timing is available.
    func utilizationLine(_ doc: ReportDocument) -> String? {
        let t = doc.timing
        guard t.utilization != nil else { return nil }
        var parts: [String] = []
        if let lanes = t.serialThresholdLanes, let serial = t.serialSeconds {
            let span = doc.build.span ?? 0
            let lanesText = "≤ \(lanes) lane\(lanes == 1 ? "" : "s")"
            parts.append(t.serialStretchesTotal == 0 ? "no serial stretch ≥ 1 s at \(lanesText)"
                : "\(lanesText) busy for \(Self.duration(serial)) (\(pct(span > 0 ? serial / span : nil)) of span, "
                    + "\(t.serialStretchesTotal) stretch\(t.serialStretchesTotal == 1 ? "" : "es") ≥ 1 s)")
        }
        if let gaps = t.idleGaps {
            let seconds = gaps.reduce(0) { $0 + $1.end - $1.start }
            parts.append("\(plural(t.idleGapsTotal, "idle gap")) > 100 ms"
                + (t.idleGapsTotal > 0 ? " (\(Self.duration(seconds))\(gaps.count < t.idleGapsTotal ? " shown" : ""))" : ""))
        }
        parts.append(t.processWall.map { "process wall \(Self.duration($0))" }
            ?? "process wall unknown (`xcblame build` measures it)")
        return "      " + parts.joined(separator: " · ")
    }

    func targetTable(_ doc: ReportDocument, _ targets: [ReportDocument.TargetRow]) -> [String] {
        let whatIf = doc.criticalPath?.whatIf != nil
        let rows = targets.map { row -> [String] in
            var cells = ["  " + clip(row.name), Self.duration(row.taskTime), pct(row.share), String(row.tasks),
                         row.onPathSeconds.map { $0 > 0 ? Self.duration($0) : "-" } ?? "n/a"]
            if whatIf { cells.append(row.whatIfSeconds.map { $0 > 0 ? Self.duration($0) : "-" } ?? "-") }
            cells.append(row.owner ?? "")
            return cells
        }
        var footer: [String] = []
        let hidden = doc.targetsTotal - targets.count
        if hidden > 0 {
            footer.append("  (\(hidden) more rows)  shown \(targets.count) of \(doc.targetsTotal) rows = "
                + "\(pct(doc.targetsShownShare)) of task time")
        }
        let headers = ["task time", "share", "tasks", "on path"] + (whatIf ? ["what-if"] : []) + ["owner"]
        return table(title: "TARGETS", headers: headers, rows: rows, leftAligned: [headers.count])
            + footer.map(dim)
    }

    func kindTable(_ kinds: [ReportDocument.Row]) -> [String] {
        let rows = kinds.map { ["  " + $0.key, Self.duration($0.taskTime), pct($0.share), String($0.tasks)] }
        return table(title: "KINDS", headers: ["task time", "share", "tasks"], rows: rows)
    }

    func topTaskTable(_ doc: ReportDocument, _ top: [ReportDocument.TopTask]) -> [String] {
        let rows = top.map { ["  " + clip($0.rule), Self.duration($0.seconds), clip($0.target ?? "-"), clip($0.title)] }
        var lines = table(title: "TOP TASKS", headers: ["time", "target", "title"], rows: rows,
                          leftAligned: [2, 3])
        lines.append(dim("  shown \(top.count) of \(doc.topTasksTotal) tasks = \(pct(doc.topTasksShownShare)) of task time"))
        return lines
    }

    func diagnosticsLine(_ d: DiagnosticsSummary) -> String {
        var parts = [plural(d.errors, "error"), plural(d.warnings, "warning")]
        if d.analyzerWarnings > 0 { parts.append(plural(d.analyzerWarnings, "analyzer warning")) }
        if d.notices > 0 { parts.append(plural(d.notices, "notice")) }
        if d.unknown > 0 { parts.append("\(d.unknown) of unknown severity") }
        return bold("DIAGNOSTICS") + "  " + parts.joined(separator: " · ")
            + " (\(d.unique) unique, \(d.occurrences) occurrences)"
    }

    /// Header banner when the report is degraded (`degradations` non-empty, as JSON `degraded` and the html badge):
    /// the model's own degradations (truncated input, schema drift, classification) are listed here, the validation
    /// ones with the checks.
    func degradationLines(_ doc: ReportDocument) -> [String] {
        guard !doc.degradations.isEmpty else { return [] }
        let own = doc.degradations.filter { $0.kind != "validation" }
        return ["  status  " + warn("DEGRADED") + " (partial or uncertain analysis"
            + (own.count < doc.degradations.count ? "; see the failed checks)" : ")")]
            + own.map { "          \(safe($0.kind)): \(safe($0.detail))" }
    }

    func validationLines(_ doc: ReportDocument) -> [String] {
        let checks = doc.validation.checks
        func count(_ status: String) -> Int { checks.filter { $0.status == status }.count }
        let fails = count("fail")
        let warns = count("warn")
        var head = "checks \(count("pass")) pass, \(warns) warn, \(fails) fail, \(count("notApplicable")) n/a"
        if fails > 0 { head = fail(head) } else if warns > 0 { head = warn(head) }
        var lines = [head]
        for check in checks where check.status == "warn" || check.status == "fail" {
            let line = "  \(check.id) \(check.status): \(safe(check.detail ?? check.title))"
            lines.append(check.status == "fail" ? fail(line) : warn(line))
        }
        return lines
    }

    func unavailable(_ title: String, _ doc: ReportDocument) -> String {
        let why = doc.notes.first { $0.contains("withheld") } ?? "withheld by validation"
        return bold(title) + "  unavailable: " + why
    }

    // MARK: - Table and formatting

    /// Left column is the row label (first cell of each row), the rest right-aligned except `leftAligned` indexes
    /// (counted over all columns, label = 0).
    func table(title: String, headers: [String], rows: [[String]], leftAligned: Set<Int> = []) -> [String] {
        let headerRow = [title] + headers
        let columns = headerRow.count
        var widths = headerRow.map(\.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < columns { widths[index] = max(widths[index], cell.count) }
        }
        func line(_ cells: [String], header: Bool) -> String {
            var out = ""
            for index in 0..<columns {
                let cell = index < cells.count ? cells[index] : ""
                let styled = header ? (index == 0 ? bold(cell) : dim(cell)) : cell
                let gap = String(repeating: " ", count: max(0, widths[index] - cell.count))
                let left = index == 0 || leftAligned.contains(index)
                out += (index == 0 ? "" : "  ") + (left ? styled + gap : gap + styled)
            }
            return out.trimmingTrailingSpaces()
        }
        return [line(headerRow, header: true)] + rows.map { line($0, header: false) }
    }

    /// Log-derived text with C0/C1 control characters (ESC, OSC, CR, newline, ...) replaced by spaces, so a crafted
    /// log cannot drive the terminal.
    func safe(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            scalars.append(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value) ? " " : scalar)
        }
        return String(scalars)
    }

    func clip(_ text: String, limit: Int = titleLimit) -> String {
        let single = safe(text)
        return single.count > limit ? String(single.prefix(limit - 1)) + "…" : single
    }

    func pct(_ share: Double?) -> String {
        guard let share else { return "n/a" }
        return share > 0 && share < 0.005 ? "<1%" : String(format: "%.0f%%", share * 100)
    }

    func dur(_ seconds: Double?) -> String { seconds.map(Self.duration) ?? "unavailable" }

    func plural(_ count: Int, _ noun: String) -> String { "\(count) \(noun)" + (count == 1 ? "" : "s") }

    /// `12.3 s` from one second up, `845 ms` below.
    public static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "unavailable" }
        let millis = (seconds * 1000).rounded()
        if millis < 1000 { return String(format: "%.0f ms", millis) }
        return String(format: "%.1f s", seconds)
    }

    // MARK: - Colors

    func style(_ code: String, _ text: String) -> String { colors ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text }
    func bold(_ text: String) -> String { style("1", text) }
    func dim(_ text: String) -> String { style("2", text) }
    func warn(_ text: String) -> String { style("33", text) }
    func fail(_ text: String) -> String { style("31", text) }
}

extension String {
    fileprivate func trimmingTrailingSpaces() -> String {
        var s = self
        while s.last == " " { s.removeLast() }
        return s
    }
}
