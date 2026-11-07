import Foundation

extension ReportDocument {
    /// The `doctor` report (docs/SCHEMA-v0.3.md): project, doctor, findings, ruleDocs and fixPlan filled from the
    /// rule result; every build and timing member null or empty with the note "doctor runs no build".
    public static func makeDoctor(project: ProjectModel, settings: [String: EffectiveSettings], result: RuleResult,
                                  configurations: [String], environment: EnvSnapshot?, xcode: String?,
                                  generatedAt: Date, durationSeconds: Double?, offline: Bool, failOn: String?,
                                  notes extraNotes: [String] = []) -> ReportDocument {
        let noBuild = "doctor runs no build"
        let failed = failOnHit(result.findings, threshold: failOn)
        var notes = [noBuild + ": build, timing, targets, files, hotspots, criticalPath and validation are empty"]
        notes += result.notes + extraNotes
        return ReportDocument(
            schemaVersion: schemaVersion,
            tool: Tool(name: "xcblame", version: XcblameVersion.current, kindTable: KindTable.v1.version),
            generatedAt: generatedAt,
            input: Input(reader: "none", layout: "project", logFormatVersion: nil, path: project.container.url.path,
                         decodeWarnings: 0, excludedActions: []),
            xcode: Xcode(value: xcode, source: xcode == nil ? nil : "xcodebuild -version", evidence: [],
                         notes: xcode == nil ? ["value: xcodebuild -version unavailable"] : []),
            environment: environment,
            build: Build(kind: nil, kindEvidence: [], span: nil, taskTime: nil, busy: nil, idle: nil,
                         parallelism: Parallelism(average: nil, peak: nil), tasks: 0, tasksInModel: 0, tasksReused: 0,
                         tasksInvalid: 0, tasksClamped: 0, tasksWithoutTiming: [], tasksWithoutTimingTotal: 0,
                         notes: [noBuild]),
            metrics: Metrics(tasks: 0, tasksWithCPU: 0, placeholdersIgnored: 0, cpuSeconds: nil, tasksWithRSS: 0,
                             maxRSSBytes: nil, notes: [noBuild]),
            phases: nil, kinds: nil, targets: nil, targetsTotal: 0, targetsShownShare: nil,
            topTasks: nil, topTasksTotal: 0, topTasksShownShare: nil,
            diagnosticsSummary: DiagnosticsSummary(unique: 0, occurrences: 0, errors: 0, warnings: 0,
                                                   analyzerWarnings: 0, notices: 0, unknown: 0),
            validation: Validation(checks: [], degraded: false, notes: [noBuild]),
            degraded: false, degradations: [], decodeWarnings: [], decodeWarningsTotal: 0, notes: notes,
            topN: .max,
            graph: Graph(basis: "none", signature: nil, path: nil, commands: nil, keyedTasks: 0, unkeyedTasks: 0,
                         notes: [noBuild]),
            criticalPath: nil,
            timing: TimingSection(utilization: nil, serialStretches: nil, serialStretchesTotal: 0,
                                  serialStretchesShownShare: nil, serialThresholdLanes: nil, serialSeconds: nil,
                                  idleGaps: nil, idleGapsTotal: 0, idleGapsShownShare: nil, peakLanes: nil,
                                  processWall: nil, outsideLogSeconds: nil, notes: [noBuild]),
            files: nil, filesTotal: 0, filesShownShare: nil, hotspots: nil, hotspotsTotal: 0, hotspotsShownShare: nil,
            findings: result.findings, findingsTotal: result.findings.count, ruleDocs: result.ruleDocs,
            truncation: Truncation(steps: []), redacted: false,
            project: ProjectSection.make(project: project, settings: settings, configurations: configurations),
            doctor: DoctorSection(passed: result.passed, notApplicable: result.notApplicable,
                                  suppressed: result.suppressed, rulesEvaluated: result.rulesEvaluated,
                                  durationSeconds: durationSeconds.map(round6), offline: offline,
                                  failOn: failOn == "none" ? nil : failOn, failed: failed),
            fixPlan: fixPlan(result.findings))
    }

    /// Adds a rule run to an `analyze` document: findings, ruleDocs and fixPlan replace the (empty) v0.2 values;
    /// `project` when a project was read; `doctor` (passed / N/A / suppressed, no duration) when any rule ran.
    public mutating func merge(rules result: RuleResult, project model: ProjectModel?,
                               settings: [String: EffectiveSettings], configurations: [String], offline: Bool) {
        findings = result.findings
        findingsTotal = result.findings.count
        ruleDocs = result.ruleDocs
        fixPlan = Self.fixPlan(result.findings)
        notes += result.notes
        if let model {
            project = ProjectSection.make(project: model, settings: settings, configurations: configurations)
        }
        if result.rulesEvaluated > 0 {
            validation.checks = validation.checks.map { $0.id == "V12" ? Self.checkV12(findings, build: build) : $0 }
            doctor = DoctorSection(passed: result.passed, notApplicable: result.notApplicable,
                                   suppressed: result.suppressed, rulesEvaluated: result.rulesEvaluated,
                                   durationSeconds: nil, offline: offline, failOn: nil, failed: false)
        }
    }

    /// The fix plan (v0.5 clarity, `RulePlan`): findings in fix-plan order with every guard moved before the edits
    /// that assume it; each finding's commands in order, a `verify --mechanism cli` step before a build-setting
    /// `--edit-project` that has none, a "record a build first" check before any other project edit, and one manual
    /// step per `inXcode` line of a recommendation (a script phase that runs on every build). Numbered from 1.
    public static func fixPlan(_ findings: [Finding]) -> [FixPlanStep] {
        var steps: [FixPlanStep] = []
        func add(_ finding: Finding, _ command: String, kind: String, note: String? = nil) {
            steps.append(FixPlanStep(order: steps.count + 1, ruleId: finding.ruleId, command: command, note: note, kind: kind))
        }
        for finding in RulePlan.ordered(findings) {
            let verified = finding.fixCommands.contains { $0.hasPrefix("xcblame verify ") }
            // `--edit-project` is not in 0.6: the change by hand in Xcode is the step you can run today. A script-phase
            // edit is measured against a recorded build: record it before any change, by hand or not.
            let needsCheck = !verified && finding.ruleId.hasPrefix("PHASE-") && finding.fixCommands.contains { $0.contains("--edit-project") }
            if needsCheck {
                add(finding, "xcblame build -- <your xcodebuild args>", kind: "check",
                    note: "records a build to compare against: run it again after the edit, then xcblame compare")
            }
            if finding.fixCommands.contains(where: isFutureCommand) {
                for line in finding.inXcode { add(finding, line, kind: "manual", note: "a change you make by hand today") }
            }
            for command in finding.fixCommands {
                if command.hasPrefix("xcblame verify ") {
                    add(finding, command, kind: "verify", note: "builds with and without the change and keeps it only if it is faster")
                    continue
                }
                if command.contains("--edit-project"), !verified {
                    if finding.ruleId.hasPrefix("SET-") || finding.ruleId.hasPrefix("SRC-") {
                        add(finding, "xcblame verify --rules \(finding.ruleId) --mechanism cli", kind: "verify",
                            note: "measures the setting through the command line before the project file changes")
                    }
                }
                add(finding, command, kind: command.hasPrefix("xcblame fix ") ? "fix" : "command",
                    note: isFutureCommand(command) ? futureNote : nil)
            }
            if finding.fixKind == "overlay", finding.mechanism?.hasPrefix("shadowed by") == true {
                // The hook cannot reach a fully shadowed key (cli can): Xcode builds need the change by hand.
                for line in finding.inXcode {
                    add(finding, line, kind: "manual", note: "for Xcode builds: the project's value wins over the overlay")
                }
            }
            if finding.fixCommands.isEmpty, finding.fixKind == "recommend" {
                for line in finding.inXcode { add(finding, line, kind: "manual", note: "a change you make by hand in Xcode") }
            }
        }
        return steps
    }

    /// v0.6: marks the `verify` and `fix` steps of each rule in `labels` (`FixPlanner.verifyLabels`) with its verify
    /// state, so the analyze and doctor pages show which steps verify kept or reverted.
    public mutating func markVerified(_ labels: [String: String]) {
        guard !labels.isEmpty else { return }
        for index in fixPlan.indices where fixPlan[index].kind == "verify" || fixPlan[index].kind == "fix" {
            fixPlan[index].verifyStatus = labels[fixPlan[index].ruleId]
        }
    }

    /// A command this xcblame cannot run yet: `--edit-project` (project-file edits wait for v0.7, docs/SCHEMA-v0.6.md
    /// Decision 13). Outputs label it, keep it out of copy buttons, and point at the manual step instead. `xcblame
    /// verify` and `xcblame fix` ship in 0.6 and are ordinary, copyable commands.
    public static func isFutureCommand(_ command: String) -> Bool {
        command.contains("--edit-project")
    }

    /// The label of a step whose command is not available yet.
    public static let futureNote = "not available yet: make the change by hand"

    /// True when a step of `plan` edits the project file: the plan then starts with "commit your changes first".
    public static func planEditsProject(_ plan: [FixPlanStep]) -> Bool {
        plan.contains { step in
            step.command.contains("--edit-project")
                || (step.kind == "manual" && ["Target ", "Build Settings", "Project ›", "Edit "].contains { step.command.hasPrefix($0) })
        }
    }

    /// V12 on a report with rules: no finding claims to save more than the measured cost it is based on. Rules
    /// measure task time (WMO compile seconds, a package's tasks) as well as path seconds, so the bound is the build's
    /// task time; without task time, the log span.
    static func checkV12(_ findings: [Finding], build: Build) -> Check {
        let title = "finding savings within measured cost"
        let claims = findings.compactMap { finding in finding.impactSeconds.map { (finding.ruleId, $0) } }
        guard !claims.isEmpty else {
            return Check(id: "V12", title: title, status: "notApplicable",
                         detail: findings.isEmpty ? "no finding" : "no finding has a measured saving yet")
        }
        guard let span = build.taskTime ?? build.span else {
            return Check(id: "V12", title: title, status: "notApplicable", detail: "the build has no measured task time")
        }
        let what = build.taskTime != nil ? "s of task time" : "s build"
        let over = claims.filter { $0.1 > span + 1e-6 }
        return over.isEmpty
            ? Check(id: "V12", title: title, status: "pass",
                    detail: "\(claims.count) measured finding(s), none over the build's \(String(format: "%.3f", span)) \(what)")
            : Check(id: "V12", title: title, status: "warn",
                    detail: over.map { "\($0.0) claims \(String(format: "%.3f", $0.1)) s" }.joined(separator: ", ")
                        + " of the build's \(String(format: "%.3f", span)) \(what)")
    }

    /// `--fail-on`: true when a finding's severity is at or above `threshold` (`low` / `medium` / `high`). `none`,
    /// nil and an unknown threshold never fail; a finding without a severity counts as `info`.
    public static func failOnHit(_ findings: [Finding], threshold: String?) -> Bool {
        guard let threshold, let minimum = RuleSpec.Severity(rawValue: threshold) else { return false }
        return findings.contains { (RuleSpec.Severity(rawValue: $0.severity ?? "") ?? .info) >= minimum }
    }
}

extension ReportDocument.ProjectSection {
    /// Counts from the project model; `packageTargets` from the first configuration's oracle output (targets it
    /// lists that are not project targets), nil without settings.
    public static func make(project: ProjectModel, settings: [String: EffectiveSettings],
                            configurations: [String]) -> Self {
        let format: String
        var objectVersion: Int?
        switch project.format {
        case let .pbxproj(version):
            format = "pbxproj"
            objectVersion = version
        case .xcproj: format = "xcproj"
        case .package: format = "package"
        }
        let projectTargets = Set(project.allTargets.map(\.name))
        let first = configurations.lazy.compactMap { settings[$0] }.first
        let sources = Set(configurations.compactMap { settings[$0]?.source })
        var notes = project.notes
        if sources.count > 1 { notes.append("settingsSource: configurations used different sources") }
        if first == nil { notes.append("packageTargets, settingsSource: no effective settings were read") }
        // The oracle's own notes (fallback reasons, cache hits, checkouts used), once each, prefixed by configuration.
        // The write guard's notes describe the whole run, not a configuration: once, unprefixed.
        for configuration in configurations {
            for note in settings[configuration]?.notes ?? [] {
                let runWide = note.hasPrefix("removed empty folders xcodebuild created: ")
                    || (note.hasPrefix("xcodebuild wrote ") && note.hasSuffix(" (left in place)"))
                let text = runWide ? note : "\(configuration): \(note)"
                if !notes.contains(text) { notes.append(text) }
            }
        }
        return Self(
            container: project.container.url.path, format: format, objectVersion: objectVersion,
            generator: project.generator?.name, targets: project.allTargets.count,
            packageTargets: first.map { Set($0.targets.keys).subtracting(projectTargets).count },
            localPackages: project.packages.filter { $0.requirement == .local }.count,
            remotePackages: project.packages.filter { $0.requirement != .local }.count,
            dependencyManagers: project.dependencyManagers.map(\.name), schemes: project.schemes.count,
            settingsSource: sources.count == 1 ? sources.first?.label
                : (sources.isEmpty ? nil : EffectiveSettings.Source.offlineResolver.label),
            configurations: configurations, notes: notes)
    }
}
