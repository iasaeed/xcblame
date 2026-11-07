import Foundation

/// Build-vs-build diff (docs/SCHEMA-v0.4.md "CompareDocument", DESIGN §6.10, §8.2.4 #11). The CLI turns each operand
/// (report JSON, log, history id) into `Input`s; this builds the document.
public enum Compare {
    /// One side of the comparison: one or more runs of the same build.
    public struct Input: Sendable {
        /// Path, log path or history id, as shown in `Side.source`.
        public var source: String
        /// One report per run, oldest first.
        public var documents: [ReportDocument]
        /// Executed-task rows of the runs (history entries or a model), same order as `documents`; nil when unknown.
        public var taskRows: [[History.TaskIndexRow]]?

        public init(source: String, documents: [ReportDocument], taskRows: [[History.TaskIndexRow]]? = nil) {
            self.source = source
            self.documents = documents
            self.taskRows = taskRows
        }
    }

    public struct Options: Sendable, Equatable {
        /// `--threshold <pct>` as a fraction; sets `regression.thresholdPct` and `failed`.
        public var thresholdPct: Double?
        /// Rows per capped table of the JSON document (`--top`); `Int.max` for html.
        public var top: Int

        public init(thresholdPct: Double? = nil, top: Int = 25) {
            self.thresholdPct = thresholdPct
            self.top = top
        }
    }

    /// The executed tasks of `model` as history rows (the same `(rule, target, sigDigest)` ids a history entry holds),
    /// for `Input.taskRows` and for `Regression.evaluate(…currentTaskRows:…)`.
    public static func taskRows(document: ReportDocument, model: BuildModel) -> [History.TaskIndexRow] {
        History.taskIndexRows(document, model)
    }

    /// The note of a comparison between an ordinary build and a `build --deep` run (`side` is `a` or `b`).
    public static func deepNote(side: String) -> String {
        "\(side) is a build --deep run: timing flags were injected, so its task times can be slower than a normal build"
    }

    /// True for the note `deepNote` makes (the text headline and the html Start-here box pick it out of `notes`).
    public static func isDeepNote(_ note: String) -> Bool {
        note == deepNote(side: "a") || note == deepNote(side: "b")
    }

    /// `b` against `a`; every delta is `b - a`. Throws `XcblameError.usage` when the two builds do not compare (kind,
    /// scheme, configuration or destination known on both sides and different).
    public static func run(a: Input, b: Input, options: Options = Options()) throws -> CompareDocument {
        guard !a.documents.isEmpty, !b.documents.isEmpty else {
            throw XcblameError.usage("compare: each side needs at least one report")
        }
        let top = max(1, options.top)
        let indexA = CompareDiffs.representative(a.documents), indexB = CompareDiffs.representative(b.documents)
        let docA = a.documents[indexA], docB = b.documents[indexB]
        var regression = try Regression.evaluate(current: b.documents, reference: a.documents, referenceRef: a.source,
                                                 options: Regression.Options(thresholdPct: options.thresholdPct))
        var notes: [String] = []
        var steps: [ReportDocument.TruncationStep] = []
        if a.documents.count > 1 || b.documents.count > 1 {
            notes.append("tables and task diffs are those of the run closest to the median wall of each side "
                + "(a: run \(indexA + 1) of \(a.documents.count), b: run \(indexB + 1) of \(b.documents.count))")
        }

        // v0.5: a `build --deep` run injects timing flags (type-check times, stats-dir, ftime-trace), so it is compared
        // with an ordinary build only with this warning; two deep runs compare like with like.
        let deepA = a.documents.contains { $0.deep?.enabled == true }, deepB = b.documents.contains { $0.deep?.enabled == true }
        if deepA != deepB { notes.append(deepNote(side: deepA ? "a" : "b")) }

        let env = CompareDiffs.envDiffs(a: docA, b: docB)

        // Phases.
        var phases: [CompareDocument.Row]?
        if let x = CompareDiffs.phaseEntries(docA), let y = CompareDiffs.phaseEntries(docB) {
            phases = CompareDiffs.diffRows(x, y)
        } else {
            notes.append("phases: not compared, \(missing(docA.phases == nil, docB.phases == nil)) withheld the phase rollup")
        }

        // Targets.
        var targets: [CompareDocument.Row]?
        var targetsTotal = 0
        var targetsShare: Double?
        if let x = CompareDiffs.targetEntries(docA), let y = CompareDiffs.targetEntries(docB) {
            let all = CompareDiffs.diffRows(x, y)
            let capped = CompareDiffs.capped(all, keep: top)
            targets = capped.rows
            targetsTotal = all.count
            targetsShare = capped.shownShare
            if capped.rows.count < all.count {
                steps.append(.init(step: "targets", kept: capped.rows.count, total: all.count, shownShare: capped.shownShare))
            }
            for (label, doc) in [("a", docA), ("b", docB)] where doc.targetsTotal > (doc.targets?.count ?? 0) {
                notes.append("targets: \(label) lists \(doc.targets?.count ?? 0) of \(doc.targetsTotal) target rows; a target "
                    + "folded into its other row there can show as added or removed")
            }
        } else {
            notes.append("targets: not compared, \(missing(docA.targets == nil, docB.targets == nil)) withheld the target rollup")
        }

        // Critical path composition.
        var criticalPath: CompareDocument.CriticalPathDiff?
        if let x = CompareDiffs.pathEntries(docA), let y = CompareDiffs.pathEntries(docB),
           let spanA = docA.criticalPath?.span, let spanB = docB.criticalPath?.span {
            // One row per target on either path: never capped (no truncation step names it).
            let all = CompareDiffs.diffRows(x, y)
            let capped = CompareDiffs.capped(all, keep: .max)
            var pathNotes: [String] = []
            for (label, doc) in [("a", docA), ("b", docB)] {
                if let path = doc.criticalPath, path.segmentsTotal > path.segments.count {
                    pathNotes.append("\(label) lists \(path.segments.count) of \(path.segmentsTotal) path segments, so its composition is partial")
                }
            }
            criticalPath = .init(span: CompareDiffs.pair(spanA, spanB), byTarget: capped.rows, byTargetTotal: all.count,
                                 byTargetShownShare: capped.shownShare, notes: pathNotes)
        } else {
            notes.append("criticalPath: not compared, \(missing(docA.criticalPath == nil, docB.criticalPath == nil)) has no critical path")
        }

        // Tasks.
        let tasks = taskDiff(a: a, b: b, indexA: indexA, indexB: indexB, top: top, steps: &steps)
        if tasks.available {
            // The attribution names the tasks too (uncapped lists, grouped by target and rule).
            let all = CompareDiffs.taskDiff(a: a.taskRows?[indexA] ?? [], b: b.taskRows?[indexB] ?? [])
            regression.attribution = Regression.ordered(regression.attribution + Regression.taskAttribution(
                added: all.added, removed: all.removed, changed: all.changed))
        }

        // Settings.
        var settings = CompareDiffs.settingDiffs(a: docA, b: docB)
        if let all = settings {
            if all.count > top {
                steps.append(.init(step: "settings", kept: top, total: all.count, shownShare: nil))
                settings = Array(all.prefix(top))
            }
        } else {
            notes.append("settings: not compared, neither side carries setting evidence (findings with settings come from a "
                + "report made with rules, not from a log)")
        }

        return CompareDocument(
            tool: ReportDocument.Tool(name: "xcblame", version: XcblameVersion.current, kindTable: docB.tool.kindTable),
            generatedAt: docB.generatedAt, a: side("a", a, docA), b: side("b", b, docB),
            regression: regression, env: env.diffs, envCompared: env.compared, phases: phases, targets: targets,
            targetsTotal: targetsTotal, targetsShownShare: targetsShare, criticalPath: criticalPath, tasks: tasks,
            settings: settings, notes: notes, truncation: ReportDocument.Truncation(steps: steps), redacted: false)
    }

    /// `--format json`: the same encoder as every document (sorted keys, ISO 8601 dates), trailing newline.
    public static func renderJSON(_ document: CompareDocument) throws -> Data {
        try JSONReporter.encoder().encode(document) + Data("\n".utf8)
    }

    // MARK: - Pieces

    private static func missing(_ a: Bool, _ b: Bool) -> String {
        a && b ? "both sides" : a ? "a" : "b"
    }

    private static func side(_ label: String, _ input: Input, _ doc: ReportDocument) -> CompareDocument.Side {
        let documents = input.documents
        let basis = ReportDocument.wallBasis(of: documents)
        func first(_ value: (ReportDocument) -> String?) -> String? { documents.compactMap(value).first }
        return CompareDocument.Side(
            label: label, source: input.source, runs: documents.count, generatedAt: doc.generatedAt,
            toolVersion: doc.tool.version, kind: first { $0.build.kind }, scheme: first { $0.build.scheme },
            configuration: first { $0.build.configuration }, destination: first { $0.build.destination },
            xcode: first { $0.xcode.value },
            wall: Stats.median(documents.compactMap { $0.wall(basis: basis) }).map(Stats.round6),
            busy: Stats.median(documents.compactMap(\.build.busy)).map(Stats.round6),
            criticalPath: Stats.median(documents.compactMap { $0.criticalPath?.span }).map(Stats.round6),
            tasks: doc.build.tasks, errors: doc.diagnosticsSummary.errors, warnings: doc.diagnosticsSummary.warnings,
            degraded: doc.degraded, git: doc.environment?.git, machine: doc.machineSummary)
    }

    private static func taskDiff(a: Input, b: Input, indexA: Int, indexB: Int, top: Int,
                                 steps: inout [ReportDocument.TruncationStep]) -> CompareDocument.TaskDiff {
        func rows(_ input: Input, _ index: Int) -> [History.TaskIndexRow]? {
            guard let all = input.taskRows, all.indices.contains(index) else { return nil }
            let rows = all[index]
            // A history entry written before task indexes existed has none: not "no executed task".
            return rows.isEmpty && input.documents[index].build.tasks > 0 ? nil : rows
        }
        let x = rows(a, indexA), y = rows(b, indexB)
        guard let x, let y else {
            let who = [x == nil ? "a" : nil, y == nil ? "b" : nil].compactMap { $0 }.joined(separator: " and ")
            return .init(available: false, added: [], addedTotal: 0, addedShownShare: nil, removed: [], removedTotal: 0,
                         removedShownShare: nil,
                         notes: ["task diff needs the executed tasks of both builds; \(who) has none "
                             + "(a saved report carries no task rows: pass a log or a history entry id)"])
        }
        let all = CompareDiffs.taskDiff(a: x, b: y)
        let added = CompareDiffs.capped(all.added, keep: top)
        let removed = CompareDiffs.capped(all.removed, keep: top)
        let changed = CompareDiffs.capped(all.changed, keep: top)
        if added.rows.count < all.added.count || removed.rows.count < all.removed.count || changed.rows.count < all.changed.count {
            steps.append(.init(step: "tasks", kept: added.rows.count + removed.rows.count + changed.rows.count,
                               total: all.added.count + all.removed.count + all.changed.count, shownShare: nil))
        }
        var notes: [String] = []
        if x.contains(where: { $0.title == nil }) || y.contains(where: { $0.title == nil }) {
            notes.append("tasks: a side comes from a history entry, which stores no task titles, so tasks whose key and "
                + "command line changed (a new Xcode) are paired by command digest only and may show as new and removed")
        }
        if !all.changed.isEmpty {
            notes.append("tasks: \(all.changed.count) task(s) ran on both sides with another key and command line (a new Xcode "
                + "rewrites them); they are paired by rule, target and title and listed as changed, not as new and removed")
        }
        return .init(available: true, added: added.rows, addedTotal: all.added.count, addedShownShare: added.share,
                     removed: removed.rows, removedTotal: all.removed.count, removedShownShare: removed.share, notes: notes,
                     changed: changed.rows, changedTotal: all.changed.count, changedShownShare: changed.share)
    }
}
