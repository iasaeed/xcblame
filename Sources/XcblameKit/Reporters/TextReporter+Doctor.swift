import Foundation

extension TextReporter {
    /// `doctor` text (DESIGN §3.4): header (container, format, Xcode, duration; generator and its consequence;
    /// settings source and counts; graph), PASS / N/A / SUPPRESSED lists, the FINDINGS table, the PLAN, the `--fail-on`
    /// verdict and notes. Unknown values print as "unknown", never 0; every list is capped by `topN` with "shown N of M".
    public static func renderDoctor(_ document: ReportDocument, colors: Bool = false) -> String {
        TextReporter(colors: colors).renderDoctor(document)
    }

    /// Total line width the doctor text wraps to.
    static let doctorWidth = 100

    public func renderDoctor(_ doc: ReportDocument) -> String {
        var lines = doctorHeader(doc)
        lines.append("")
        if let doctor = doc.doctor {
            lines += outcomeList("PASS", doctor.passed.map { "\($0.ruleId) \($0.detail)" }, topN: doc.topN)
            lines += outcomeList("N/A", groupedReasons(doctor.notApplicable), count: doctor.notApplicable.count, topN: doc.topN)
            if !doctor.suppressed.isEmpty {
                lines += outcomeList("SUPPRESSED", doctor.suppressed.map { "\($0.ruleId) \($0.detail)" }, topN: doc.topN)
            }
            lines.append("")
        }
        lines += doctorFindings(doc)
        lines += planLines(doc)
        if let doctor = doc.doctor, let threshold = doctor.failOn {
            let hits = doc.findings.filter {
                (RuleSpec.Severity(rawValue: $0.severity ?? "") ?? .info) >= (RuleSpec.Severity(rawValue: threshold) ?? .high)
            }.count
            let verdict = "fail-on \(threshold): " + (doctor.failed ? plural(hits, "finding") + " at or above \(threshold) → exit 4"
                                                                   : "no finding at or above \(threshold)")
            lines.append(doctor.failed ? fail(verdict) : verdict)
        }
        lines += noteLines(doc)
        return lines.map(rstrip).joined(separator: "\n") + "\n"
    }

    // MARK: - Header

    func doctorHeader(_ doc: ReportDocument) -> [String] {
        let project = doc.project
        let container = project.map { URL(fileURLWithPath: $0.container).lastPathComponent } ?? doc.input.path ?? "(no project)"
        var head = bold("xcblame \(doc.tool.version) doctor") + " · " + safe(container)
        if let project {
            head += " (" + ([project.objectVersion.map { "objectVersion \($0)" }, project.format].compactMap { $0 })
                .joined(separator: ", ") + ")"
        }
        head += " · " + (doc.xcode.value.map { "Xcode \(safe($0))" } ?? "Xcode unknown")
        if let seconds = doc.doctor?.durationSeconds { head += " · " + Self.duration(seconds) }
        var lines = [head]
        guard let project else { return lines + ["  project    not read (see notes)"] }
        if let generator = project.generator {
            let (name, source) = Self.generatorText(generator)
            lines.append("  generator  \(name) (\(source)) → project edits disabled; hook goes into \(source)")
        } else {
            lines.append("  generator  none → project edits allowed with --edit-project")
        }
        let configurations = "\(plural(project.configurations.count, "configuration"))"
            + (project.configurations.isEmpty ? "" : " (" + project.configurations.map(safe).joined(separator: ", ") + ")")
        if let source = project.settingsSource {
            let packages = project.packageTargets.map { " + " + plural($0, "package target") } ?? " + package targets unknown"
            lines.append("  settings   \(source): \(configurations) x \(plural(project.targets, "target"))\(packages)")
        } else {
            lines.append("  settings   none: no effective settings were read (see notes) · \(configurations)")
        }
        var graph = "  graph      \(plural(project.targets, "project target")), \(plural(project.localPackages, "local package")), "
            + plural(project.remotePackages, "remote package")
        if !project.dependencyManagers.isEmpty { graph += " · " + project.dependencyManagers.joined(separator: ", ") }
        graph += " · " + plural(project.schemes, "scheme")
        lines.append(graph)
        if doc.doctor?.offline == true {
            lines.append("  offline    --offline: settings from the offline resolver; every confidence one step lower")
        }
        return lines
    }

    static func generatorText(_ name: String) -> (String, String) {
        switch name {
        case "xcodegen": return ("XcodeGen", "project.yml")
        case "tuist": return ("Tuist", "Project.swift")
        default: return (name, "its source")
        }
    }

    // MARK: - Lists

    /// N/A outcomes grouped by reason: `no script phases (PHASE-001, PHASE-002)`.
    func groupedReasons(_ outcomes: [RuleOutcome]) -> [String] {
        var order: [String] = []
        var ids: [String: [String]] = [:]
        for outcome in outcomes {
            if ids[outcome.detail] == nil { order.append(outcome.detail) }
            ids[outcome.detail, default: []].append(outcome.ruleId)
        }
        return order.map { "\($0) (\(ids[$0]!.joined(separator: ", ")))" }
    }

    /// `PASS (12)  item · item · …` wrapped with a hanging indent; capped at `topN` items.
    func outcomeList(_ label: String, _ items: [String], count: Int? = nil, topN: Int) -> [String] {
        let total = count ?? items.count
        let head = "\(label) (\(total))"
        guard !items.isEmpty else { return [bold(head)] }
        let indent = max(11, head.count + 2)
        let shown = Array(items.prefix(topN)).map(safe)
        var text = shown.joined(separator: " · ")
        if shown.count < items.count { text += " · shown \(shown.count) of \(items.count)" }
        let wrapped = wrap(text, width: Self.doctorWidth - indent)
        return wrapped.enumerated().map { index, line in
            index == 0 ? bold(head) + String(repeating: " ", count: indent - head.count) + line
                : String(repeating: " ", count: indent) + line
        }
    }

    // MARK: - Findings and plan

    func doctorFindings(_ doc: ReportDocument) -> [String] {
        guard !doc.findings.isEmpty else {
            let evaluated = doc.doctor?.rulesEvaluated ?? 0
            return [bold("FINDINGS") + "  none: \(plural(evaluated, "rule")) evaluated, each passed, not applicable or suppressed"]
        }
        let shown = Array(doc.findings.prefix(doc.topN))
        let idWidth = max(7, shown.map(\.ruleId.count).max() ?? 7)
        let titleWidth = 58
        let fix = shown.map { fixText($0, doc) }
        var lines = [bold("FINDINGS") + String(repeating: " ", count: 2 + idWidth + 2 + titleWidth + 2 - 8)
            + dim("impact  conf    fix")]
        for (index, finding) in shown.enumerated() {
            let title = finding.title + (finding.needsMeasurement ? (finding.title.hasSuffix(".") ? " " : ". ") + "Needs measurement." : "")
            let wrapped = wrap(safe(title), width: titleWidth)
            for (row, text) in wrapped.enumerated() {
                let id = row == 0 ? finding.ruleId : ""
                var line = "  " + pad(id, idWidth) + "  " + pad(text, titleWidth)
                if row == 0 {
                    line += "  " + pad(Self.bandText(finding), 6) + "  " + pad(finding.confidence, 6) + "  " + fix[index]
                }
                lines.append(line)
            }
            let indent = String(repeating: " ", count: 2 + idWidth + 2)
            for change in finding.inXcode {
                lines += wrap(safe("where: " + change), width: Self.doctorWidth - indent.count).enumerated().map { row, text in
                    indent + (row == 0 ? "" : "  ") + dim(text)
                }
            }
        }
        if shown.count < doc.findings.count {
            lines.append(dim("  shown \(shown.count) of \(doc.findings.count) findings (--top)"))
        }
        return lines
    }

    /// `overlay +V`, `recommend`, `project` (the fix kind; `+V` when the rule applies only through verify).
    func fixText(_ finding: ReportDocument.Finding, _ doc: ReportDocument) -> String {
        (finding.fixKind ?? "recommend") + (doc.ruleDocs[finding.ruleId]?.verifyOnly == true && finding.fixKind != "recommend"
            ? " +V" : "")
    }

    func planLines(_ doc: ReportDocument) -> [String] {
        guard !doc.findings.isEmpty else { return [] }
        guard !doc.fixPlan.isEmpty else {
            return [bold("PLAN") + "  nothing xcblame applies: the findings above are recommendations"]
        }
        let shown = Array(doc.fixPlan.prefix(doc.topN))
        var lines = shown.enumerated().map { index, step in
            (index == 0 && !ReportDocument.planEditsProject(doc.fixPlan) ? bold("PLAN") + "  " : "      ") + planStepText(step)
        }
        if ReportDocument.planEditsProject(doc.fixPlan) { lines.insert(Self.commitFirst, at: 0) }
        if shown.count < doc.fixPlan.count { lines.append(dim("      shown \(shown.count) of \(doc.fixPlan.count) steps")) }
        if doc.fixPlan.contains(where: { ReportDocument.isFutureCommand($0.command) }) { lines.append(Self.futureLine) }
        var hooks: [String] = []
        for finding in doc.findings where finding.fixKind == "overlay" {
            guard let mechanism = finding.mechanism, mechanism.hasPrefix("hook ("),
                  let close = mechanism.firstIndex(of: ")") else { continue }
            let hook = String(mechanism[mechanism.index(mechanism.startIndex, offsetBy: 6)..<close])
            if !hooks.contains(hook) { hooks.append(hook) }
        }
        lines += hooks.map { "      the hook is printed, not applied: " + safe($0) }
        return lines
    }

    /// "by hand in Xcode: " for a change in Xcode's editors, "by hand: " for Terminal, System Settings or a file.
    static func manualPrefix(_ command: String) -> String {
        ["Build Settings", "Target ", "Project ›", "Xcode ›"].contains { command.hasPrefix($0) } ? "by hand in Xcode: " : "by hand: "
    }

    /// The line under a plan with a step this xcblame cannot run (`--edit-project`).
    static let futureLine = "      --edit-project is not available yet: make those changes by hand (the 'by hand' steps)"

    /// The line above a plan that edits the project file.
    static let commitFirst = "PLAN  Commit your changes first: some steps below edit the project file (git checkout undoes them)"

    /// `3. \`xcblame fix …\``, or `3. by hand in Xcode: …` for a manual step.
    func planStepText(_ step: ReportDocument.FixPlanStep) -> String {
        guard step.kind == "manual" else {
            return "\(step.order). `\(safe(step.command))`"
                + (ReportDocument.isFutureCommand(step.command) ? " (" + ReportDocument.futureNote + ")" : "")
        }
        let head = "\(step.order). "
        return wrap(Self.manualPrefix(step.command) + safe(step.command), width: Self.doctorWidth - 6 - head.count).enumerated()
            .map { $0.offset == 0 ? head + $0.element : String(repeating: " ", count: 6 + head.count) + $0.element }
            .joined(separator: "\n")
    }

    func noteLines(_ doc: ReportDocument) -> [String] {
        let notes = doc.notes.filter { !$0.hasPrefix("doctor runs no build") } + (doc.project?.notes ?? [])
        guard !notes.isEmpty else { return [] }
        let shown = notes.prefix(doc.topN)
        return shown.map { dim("note: " + safe($0)) }
            + (shown.count < notes.count ? [dim("note: shown \(shown.count) of \(notes.count) notes")] : [])
    }

    // MARK: - Text helpers

    /// Greedy word wrap; a word longer than `width` stays whole on its own line.
    func wrap(_ text: String, width: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: true) {
            if current.isEmpty { current = String(word) } else if current.count + 1 + word.count <= width {
                current += " " + word
            } else {
                lines.append(current)
                current = String(word)
            }
        }
        if !current.isEmpty || lines.isEmpty { lines.append(current) }
        return lines
    }

    func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    func rstrip(_ text: String) -> String {
        var text = text
        while text.last == " " { text.removeLast() }
        return text
    }
}
