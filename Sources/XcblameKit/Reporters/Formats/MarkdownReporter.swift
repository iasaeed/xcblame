import Foundation

/// `--format markdown`: the PR comment (docs/SCHEMA-v0.4.md "Formats", DESIGN §8.3). A pure function of the document
/// and `FormatOptions`; the CLI hands over an already redacted document. Renders analyze, build and doctor documents
/// (`render(_: ReportDocument)`) and compare documents (`render(_: CompareDocument)`).
public enum MarkdownReporter {
    /// The sticky-comment marker: a workflow updates the comment whose body starts with it.
    public static let marker = "<!-- xcblame:report -->"

    public static func render(_ document: ReportDocument, options: FormatOptions) throws -> String {
        let view = ReportMarkdown(document: document, options: options)
        return Fit.fit(cap: options.maxBytes, reproduce: view.reproduce, steps: view.steps, render: view.render)
    }

    /// A compare document: headline delta and the environment differences first, then the metrics, targets and the
    /// attribution; phases, critical path, tasks and settings in the collapsed details.
    public static func render(_ document: CompareDocument, options: FormatOptions) throws -> String {
        let view = CompareMarkdown(document: document, options: options)
        return Fit.fit(cap: options.maxBytes, reproduce: view.reproduce, steps: view.steps, render: view.render)
    }
}

// MARK: - Report

struct ReportMarkdown {
    let document: ReportDocument
    let options: FormatOptions

    var isDoctor: Bool { FormatText.isDoctor(document) }

    var reproduce: String {
        options.reproduceCommand ?? (isDoctor ? "xcblame doctor --format json" : "xcblame analyze <input> --format json --top all")
    }

    /// The order of DESIGN/SCHEMA-v0.4 "Budget", with the sections the contract's list does not name (hotspots,
    /// files, fix plan) first: they only exist to be dropped.
    var steps: [FitStep] {
        [
            .drop("hotspots", "files", "fixPlan", label: "hotspots, files, fix plan"),
            .cap("diagnostics", to: 5, label: "diagnostics rows beyond 5"),
            .cap("targets", to: 5, label: "targets rows beyond 5"),
            .drop("diagnostics", label: "diagnostics"),
            .drop("attribution", label: "attribution"),
            .drop("targets", label: "targets"),
            .drop("environment", label: "environment and validation"),
            .drop("evidence", label: "finding evidence beyond one line"),
            .cap("path", to: 3, label: "critical-path rows beyond 3"),
        ]
    }

    func render(_ plan: FitPlan, _ note: String?) -> String {
        var lines: [String] = [MarkdownReporter.marker]
        lines.append(title)
        lines.append("")
        lines += headline
        lines += isDoctor ? doctorSummary : metrics
        lines += isDoctor ? [] : criticalPath(plan)
        lines += findings(plan)
        lines += details(plan)
        if let note { lines += [note, ""] }
        lines.append(footer)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Header

    var title: String {
        if isDoctor {
            let container = document.project.map { URL(fileURLWithPath: $0.container).lastPathComponent }
                ?? document.input.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "project"
            return "## xcblame doctor: \(FormatText.markdown(container)), "
                + FormatText.count(document.findings.count, "finding")
        }
        var name = FormatText.markdown(document.build.scheme ?? "build")
        if let kind = document.build.kind { name += " " + FormatText.markdown(kind) }
        let wall = FormatText.wall(document).map { ", \(FormatText.seconds($0)) wall" } ?? ""
        return "## xcblame: \(name)\(wall)"
    }

    var headline: [String] {
        guard !isDoctor else { return [] }
        guard let regression = document.regression else {
            return ["No baseline: pass `--baseline .xcblame/baseline.json` to compare.", ""]
        }
        var lines = [FormatText.regressionSentence(regression)]
        if let failure = FormatText.regressionFailure(regression) { lines += ["", "**\(failure)**"] }
        return lines + [""]
    }

    var metrics: [String] {
        var lines: [String] = []
        if let regression = document.regression {
            func row(_ name: String, _ delta: ReportDocument.Regression.Delta) -> String? {
                guard delta.current != nil || delta.baseline != nil else { return nil }
                return FormatText.row([name, FormatText.seconds(delta.current), FormatText.seconds(delta.baseline),
                                       FormatText.deltaText(delta.delta, delta.deltaPct)])
            }
            let rows = [row("Wall", regression.wall), row("Busy", regression.busy),
                        row("Critical path", regression.criticalPath)].compactMap { $0 }
            if !rows.isEmpty { lines += FormatText.header(["Metric", "Now", "Baseline", "Delta"]) + rows + [""] }
        } else {
            let values: [(String, Double?)] = [("Wall", FormatText.wall(document)), ("Busy", FormatText.busy(document)),
                                               ("Critical path", FormatText.criticalPathSeconds(document))]
            let rows = values.compactMap { name, value in value.map { FormatText.row([name, FormatText.seconds($0)]) } }
            if !rows.isEmpty { lines += FormatText.header(["Metric", "Now"]) + rows + [""] }
        }
        let summary = document.diagnosticsSummary
        lines.append(FormatText.count(summary.errors, "error") + ", " + FormatText.count(summary.warnings, "warning"))
        return lines + [""]
    }

    var doctorSummary: [String] {
        var parts: [String] = []
        if let doctor = document.doctor {
            parts.append(FormatText.count(doctor.rulesEvaluated, "rule") + " evaluated")
            parts.append(FormatText.count(document.findings.count, "finding"))
            if !doctor.passed.isEmpty { parts.append("\(doctor.passed.count) passed") }
            if !doctor.notApplicable.isEmpty { parts.append("\(doctor.notApplicable.count) not applicable") }
            if let failOn = doctor.failOn {
                parts.append(doctor.failed ? "FAILED: a finding at or above \(failOn)" : "no finding at or above \(failOn)")
            }
        } else {
            parts.append(FormatText.count(document.findings.count, "finding"))
        }
        var lines = [parts.joined(separator: ", ")]
        if let xcode = document.xcode.value { lines[0] += "; Xcode \(FormatText.markdown(xcode))" }
        return lines + [""]
    }

    // MARK: Critical path

    func criticalPath(_ plan: FitPlan) -> [String] {
        guard let path = document.criticalPath else {
            let why = document.notes.first { $0.hasPrefix("criticalPath") } ?? "not computed"
            return ["### Critical path", "", "_Unavailable: \(FormatText.markdown(why))_", ""]
        }
        let ordered = path.segments.enumerated().sorted {
            $0.element.seconds != $1.element.seconds ? $0.element.seconds > $1.element.seconds : $0.offset < $1.offset
        }.map(\.element)
        let shown = Array(ordered.prefix(plan.limit("path", 5)))
        var lines = ["### Critical path", ""] + FormatText.header(["#", "Target", "Work", "Seconds", "Share"])
        for (index, segment) in shown.enumerated() {
            lines.append(FormatText.row([
                String(index + 1), FormatText.markdown(segment.target ?? "(no target)", limit: 80),
                FormatText.markdown(segment.label, limit: 120), FormatText.seconds(segment.seconds),
                FormatText.percent(segment.share)]))
        }
        let covered = shown.reduce(0) { $0 + $1.seconds }
        let share = path.span > 0 ? " " + FormatText.percent(covered / path.span) + " of the path" : ""
        lines += ["", "_\(shown.count) of \(path.segmentsTotal) segments,\(share)_", ""]
        return lines
    }

    // MARK: Findings

    func findings(_ plan: FitPlan) -> [String] {
        var lines = ["### Findings", ""]
        guard !document.findings.isEmpty else { return lines + ["No findings.", ""] }
        let limit = isDoctor ? 10 : 3
        let shown = Array(document.findings.prefix(limit))
        for (index, finding) in shown.enumerated() {
            var text = FormatText.markdown(finding.title, limit: 200)
            if let evidence = finding.evidence.first { text += ": " + FormatText.markdown(evidence, limit: 240) }
            if let fix = finding.fixCommands.first { text += (text.hasSuffix(".") ? " " : ". ") + "Fix: " + FormatText.code(fix, limit: 240) }
            let badge = FormatText.findingBadge(finding, document)
            lines.append("\(index + 1). **\(FormatText.markdown(finding.ruleId, limit: 40))**"
                + (badge.isEmpty ? "" : " (\(FormatText.markdown(badge, limit: 40)))") + " " + text)
            if plan.shows("evidence") {
                for evidence in finding.evidence.dropFirst().prefix(2) {
                    lines.append("   - " + FormatText.markdown(evidence, limit: 240))
                }
            }
        }
        lines.append("")
        if shown.count < document.findingsTotal {
            lines += ["_\(shown.count) of \(document.findingsTotal) findings_", ""]
        }
        return lines
    }

    // MARK: Details

    func details(_ plan: FitPlan) -> [String] {
        var sections: [[String]] = []
        func add(_ key: String, _ build: () -> [String]) {
            guard plan.shows(key) else { return }
            let lines = build()
            if !lines.isEmpty { sections.append(lines) }
        }
        add("targets") { targetsSection(plan.limit("targets", 10)) }
        add("hotspots") { hotspotsSection(plan.limit("hotspots", 5)) }
        add("files") { filesSection(plan.limit("files", 5)) }
        add("attribution") { attributionSection(plan.limit("attribution", 10)) }
        add("diagnostics") { diagnosticsSection(plan.limit("diagnostics", 20)) }
        add("fixPlan") { fixPlanSection(plan.limit("fixPlan", 10)) }
        add("environment") { environmentSection() }
        guard !sections.isEmpty else { return [] }
        return ["<details><summary>Details</summary>", ""] + sections.flatMap { $0 + [""] } + ["</details>", ""]
    }

    func targetsSection(_ limit: Int) -> [String] {
        let all = document.targets ?? []
        let rows = all.filter { !$0.isOther }
        guard !rows.isEmpty else { return [] }
        let shown = rows.prefix(limit)
        let total = max(document.targetsTotal - (all.count - rows.count), rows.count)
        var lines = ["#### Targets", ""] + FormatText.header(["Target", "Owner", "Task time", "On path"])
        for target in shown {
            lines.append(FormatText.row([
                FormatText.markdown(target.name, limit: 80), FormatText.markdown(target.owner ?? "n/a", limit: 30),
                FormatText.seconds(target.taskTime), target.onPathSeconds.map { $0 > 0 ? FormatText.seconds($0) : "-" } ?? "n/a"]))
        }
        return lines + ["", "_\(shown.count) of \(total) targets_"]
    }

    func place(_ file: String) -> String {
        FormatText.repoRelative(file, workspaceRoot: options.workspaceRoot) ?? file
    }

    func hotspotsSection(_ limit: Int) -> [String] {
        let rows = document.hotspots ?? []
        guard !rows.isEmpty else { return [] }
        let shown = rows.prefix(limit)
        var lines = ["#### Hotspots", ""] + FormatText.header(["Declaration", "Location", "Type-check"])
        for hotspot in shown {
            lines.append(FormatText.row([
                FormatText.markdown(hotspot.declaration, limit: 100),
                FormatText.markdown("\(place(hotspot.file)):\(hotspot.line)", limit: 120),
                String(format: "%.0f ms", hotspot.ms)]))
        }
        return lines + ["", "_\(shown.count) of \(document.hotspotsTotal) hotspots_"]
    }

    func filesSection(_ limit: Int) -> [String] {
        let rows = document.files ?? []
        guard !rows.isEmpty else { return [] }
        let shown = rows.prefix(limit)
        var lines = ["#### Files", ""] + FormatText.header(["File", "Target", "Seconds", "Granularity"])
        for file in shown {
            lines.append(FormatText.row([
                FormatText.markdown(place(file.path), limit: 120), FormatText.markdown(file.target ?? "n/a", limit: 60),
                FormatText.seconds(file.seconds), FormatText.markdown(file.granularity, limit: 20)]))
        }
        return lines + ["", "_\(shown.count) of \(document.filesTotal) files_"]
    }

    func attributionSection(_ limit: Int) -> [String] {
        guard let regression = document.regression, !regression.attribution.isEmpty else { return [] }
        let shown = regression.attribution.prefix(limit)
        var lines = ["#### Attribution", ""]
        for item in shown {
            lines.append("- **\(FormatText.markdown(item.kind, limit: 20))** \(FormatText.markdown(item.subject, limit: 80)): "
                + FormatText.markdown(item.detail, limit: 200))
        }
        if shown.count < regression.attribution.count {
            lines += ["", "_\(shown.count) of \(regression.attribution.count) reasons_"]
        }
        return lines
    }

    func diagnosticsSection(_ limit: Int) -> [String] {
        guard !document.diagnostics.isEmpty else { return [] }
        let shown = document.diagnostics.prefix(limit)
        var lines = ["#### Diagnostics", ""]
        for entry in shown {
            lines.append("- " + FormatText.markdown(FormatText.diagnosticLine(entry, workspaceRoot: options.workspaceRoot, messageLimit: 300), limit: 500))
        }
        if shown.count < document.diagnosticsTotal {
            lines += ["", "_\(shown.count) of \(document.diagnosticsTotal) diagnostics_"]
        }
        return lines
    }

    func fixPlanSection(_ limit: Int) -> [String] {
        guard isDoctor, !document.fixPlan.isEmpty else { return [] }
        let shown = document.fixPlan.prefix(limit)
        var lines = ["#### Fix plan", ""]
        if ReportDocument.planEditsProject(document.fixPlan) {
            lines += ["**Commit your changes first:** some steps edit the project file (`git checkout` undoes them).", ""]
        }
        if document.fixPlan.contains(where: { ReportDocument.isFutureCommand($0.command) }) {
            lines += ["`--edit-project` is not available yet: make those changes by hand (the steps marked by hand).", ""]
        }
        for step in shown {
            let text = step.kind == "manual" ? TextReporter.manualPrefix(step.command) + FormatText.markdown(step.command, limit: 240)
                : FormatText.code(step.command, limit: 240)
                    + (ReportDocument.isFutureCommand(step.command) ? " _(" + ReportDocument.futureNote + ")_" : "")
            lines.append("\(step.order). " + text + " (\(FormatText.markdown(step.ruleId, limit: 40)))")
        }
        if shown.count < document.fixPlan.count { lines += ["", "_\(shown.count) of \(document.fixPlan.count) steps_"] }
        return lines
    }

    func environmentSection() -> [String] {
        var lines = ["#### Environment and validation", ""]
        let xcode = document.xcode
        lines.append("- Xcode: " + (xcode.value.map { FormatText.markdown($0) + " (\(FormatText.markdown(xcode.source ?? "inferred")))" } ?? "unknown"))
        if let env = document.environment {
            var machine: [String] = []
            if let macOS = env.macOSProductVersion { machine.append("macOS \(macOS)") }
            if let model = env.hwModel { machine.append(model) }
            if let cpus = env.logicalCPUCount { machine.append("\(cpus) CPUs") }
            if let memory = env.memoryBytes { machine.append("\(memory / (1 << 30)) GB") }
            if env.processTranslated == true { machine.append("Rosetta") }
            if let ci = env.ciProvider { machine.append("CI \(ci)") }
            if !machine.isEmpty { lines.append("- Machine running xcblame: " + FormatText.markdown(machine.joined(separator: ", "))) }
            if let git = env.git {
                var text = git.branch ?? "detached HEAD"
                if let commit = git.commit { text += " @ " + String(commit.prefix(8)) }
                if git.dirty == true { text += ", dirty" }
                lines.append("- Git: " + FormatText.markdown(text))
            }
        }
        let checks = document.validation.checks
        if !checks.isEmpty {
            func count(_ status: String) -> Int { checks.filter { $0.status == status }.count }
            lines.append("- Validation: \(count("pass")) pass, \(count("warn")) warn, \(count("fail")) fail")
            for check in checks where check.status == "warn" || check.status == "fail" {
                lines.append("  - \(check.id) \(check.status): " + FormatText.markdown(check.detail ?? check.title, limit: 200))
            }
        }
        if document.degraded {
            for entry in document.degradations.prefix(5) {
                lines.append("- Degraded, \(FormatText.markdown(entry.kind, limit: 40)): " + FormatText.markdown(entry.detail, limit: 200))
            }
        }
        return lines
    }

    var footer: String {
        "<sub>xcblame \(FormatText.markdown(document.tool.version, limit: 40)), \(document.schemaVersion)"
            + (document.redacted ? ", redacted" : "") + "</sub>"
    }
}

// MARK: - Compare

struct CompareMarkdown {
    let document: CompareDocument
    let options: FormatOptions

    var reproduce: String { options.reproduceCommand ?? "xcblame compare <a> <b> --format json" }

    var steps: [FitStep] {
        [
            .drop("settings", "tasks", label: "settings, tasks"),
            .drop("phases", "path", label: "phases, critical path"),
            .cap("targets", to: 5, label: "targets rows beyond 5"),
            .drop("attribution", label: "attribution"),
            .drop("targets", label: "targets"),
            .cap("env", to: 5, label: "environment rows beyond 5"),
        ]
    }

    func render(_ plan: FitPlan, _ note: String?) -> String {
        var lines: [String] = [MarkdownReporter.marker, title, ""]
        lines += [FormatText.regressionSentence(document.regression, reference: "reference")]
        if let failure = FormatText.regressionFailure(document.regression) { lines += ["", "**\(failure)**"] }
        lines.append("")
        lines += environment(plan)
        lines += metrics
        lines += attribution(plan)
        lines += targets(plan)
        lines += details(plan)
        if let note { lines += [note, ""] }
        lines.append(footer)
        return lines.joined(separator: "\n") + "\n"
    }

    var title: String {
        let side = document.b
        var name = FormatText.markdown(side.scheme ?? document.a.scheme ?? "build")
        if let kind = side.kind ?? document.a.kind { name += " " + FormatText.markdown(kind) }
        return "## xcblame compare: \(name), \(FormatText.seconds(side.wall)) wall (reference \(FormatText.seconds(document.a.wall)))"
    }

    func environment(_ plan: FitPlan) -> [String] {
        var lines = ["### Environment", ""]
        guard !document.env.isEmpty else {
            return lines + ["No environment differences (\(document.envCompared) fields compared).", ""]
        }
        let shown = document.env.prefix(plan.limit("env", 20))
        lines += FormatText.header(["Field", "Reference (a)", "This build (b)"])
        for diff in shown {
            lines.append(FormatText.row([FormatText.markdown(diff.field, limit: 30), FormatText.markdown(diff.a ?? "unknown", limit: 80),
                                         FormatText.markdown(diff.b ?? "unknown", limit: 80)]))
        }
        return lines + ["", "_\(shown.count) of \(document.env.count) differ, \(document.envCompared) fields compared_", ""]
    }

    var metrics: [String] {
        let regression = document.regression
        func row(_ name: String, _ delta: ReportDocument.Regression.Delta) -> String? {
            guard delta.current != nil || delta.baseline != nil else { return nil }
            return FormatText.row([name, FormatText.seconds(delta.baseline), FormatText.seconds(delta.current),
                                   FormatText.deltaText(delta.delta, delta.deltaPct)])
        }
        let rows = [row("Wall", regression.wall), row("Busy", regression.busy),
                    row("Critical path", regression.criticalPath)].compactMap { $0 }
        guard !rows.isEmpty else { return [] }
        return FormatText.header(["Metric", "Reference (a)", "This build (b)", "Delta"]) + rows + [""]
    }

    func attribution(_ plan: FitPlan) -> [String] {
        guard plan.shows("attribution"), !document.regression.attribution.isEmpty else { return [] }
        var lines = ["### Attribution", ""]
        for item in document.regression.attribution.prefix(10) {
            lines.append("- **\(FormatText.markdown(item.kind, limit: 20))** \(FormatText.markdown(item.subject, limit: 80)): "
                + FormatText.markdown(item.detail, limit: 200))
        }
        return lines + [""]
    }

    func pair(_ pair: CompareDocument.Pair) -> String {
        "\(FormatText.seconds(pair.a)) → \(FormatText.seconds(pair.b)), " + FormatText.deltaText(pair.delta, pair.deltaPct)
    }

    func rows(_ title: String, _ rows: [CompareDocument.Row], limit: Int, total: Int, noun: String) -> [String] {
        let real = rows.filter { !$0.isOther }
        guard !real.isEmpty else { return [] }
        let shown = real.prefix(limit)
        var lines = [title, ""] + FormatText.header(["Name", "Status", "Reference (a)", "This build (b)", "Delta"])
        for row in shown {
            lines.append(FormatText.row([
                FormatText.markdown(row.key, limit: 80), row.status, FormatText.seconds(row.seconds.a),
                FormatText.seconds(row.seconds.b), FormatText.deltaText(row.seconds.delta, row.seconds.deltaPct)]))
        }
        return lines + ["", "_\(shown.count) of \(max(total, real.count)) \(noun)_"]
    }

    func targets(_ plan: FitPlan) -> [String] {
        guard plan.shows("targets"), let rows = document.targets else { return [] }
        let lines = self.rows("### Targets", rows, limit: plan.limit("targets", 10), total: document.targetsTotal, noun: "targets")
        return lines.isEmpty ? [] : lines + [""]
    }

    func details(_ plan: FitPlan) -> [String] {
        var sections: [[String]] = []
        if plan.shows("phases"), let phases = document.phases {
            let lines = rows("#### Phases", phases, limit: 20, total: phases.count, noun: "phases")
            if !lines.isEmpty { sections.append(lines) }
        }
        if plan.shows("path"), let path = document.criticalPath {
            var lines = ["#### Critical path", "", "- span: " + pair(path.span)]
            let body = rows("", path.byTarget, limit: 10, total: path.byTargetTotal, noun: "targets on the path")
            if !body.isEmpty { lines += [""] + body.dropFirst(2) }
            sections.append(lines)
        }
        if plan.shows("tasks") {
            let tasks = document.tasks
            if tasks.available, !(tasks.added.isEmpty && tasks.removed.isEmpty) {
                var lines = ["#### Tasks", ""]
                for (name, list, total) in [("added", tasks.added, tasks.addedTotal), ("removed", tasks.removed, tasks.removedTotal)] {
                    guard !list.isEmpty else { continue }
                    lines.append("- \(name) (\(min(list.count, 5)) of \(total)):")
                    for task in list.prefix(5) {
                        lines.append("  - \(FormatText.markdown(task.rule, limit: 60)) in \(FormatText.markdown(task.target ?? "(no target)", limit: 60)), "
                            + FormatText.seconds(task.seconds) + (task.onPath ? ", on the path" : ""))
                    }
                }
                sections.append(lines)
            }
        }
        if plan.shows("settings"), let settings = document.settings, !settings.isEmpty {
            var lines = ["#### Settings", ""]
            for setting in settings.prefix(10) {
                lines.append("- \(FormatText.code(setting.ref, limit: 120)): \(FormatText.markdown(setting.a ?? "unset", limit: 80)) → "
                    + FormatText.markdown(setting.b ?? "unset", limit: 80))
            }
            sections.append(lines)
        }
        guard !sections.isEmpty else { return [] }
        return ["<details><summary>Details</summary>", ""] + sections.flatMap { $0 + [""] } + ["</details>", ""]
    }

    var footer: String {
        "<sub>xcblame \(FormatText.markdown(document.tool.version, limit: 40)), \(document.schemaVersion)"
            + (document.redacted ? ", redacted" : "") + "</sub>"
    }
}
