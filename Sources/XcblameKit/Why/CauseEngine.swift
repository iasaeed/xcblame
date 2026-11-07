import Foundation

// v0.5 lane B (docs/SCHEMA-v0.5.md "Cause attribution"): DESIGN §6.6.
public enum CauseEngine {
    /// The providers in precedence order (`EvidenceSource`).
    public static let providers: [any CauseEvidenceProvider] = [
        BacktraceEvidenceProvider(), ScriptEvidenceProvider(), SignatureEvidenceProvider(),
        UpstreamInterfaceEvidenceProvider(), MtimeChurnEvidenceProvider(), PlanningEvidenceProvider(),
        DriverRemarkEvidenceProvider(),
    ]

    /// The note `ReportDocument.make` leaves (a pipeline report without the command step: `--model-json`, selftest, a
    /// synthetic model); `attach` replaces it with the member or its own reason.
    static let pendingNote = "incremental: null because cause attribution runs only in analyze of a build log, build "
        + "and why (against history)"
    /// The report note of a clean build, which has no previous work to compare (`incremental` null).
    static let cleanNote = "incremental: not applicable — this is a clean build (no previous work to compare)"
    /// The report note when no previous build of the key is in history (`basis` `currentLogOnly`).
    static let noPreviousNote = "incremental: no previous build recorded for this scheme, configuration and "
        + "destination; only backtraces and script phases are attributed, the rest is unknown"
    /// The hint shown with the `unknown` cause.
    public static let backtracesHint = "xcblame why --backtraces -- <xcodebuild args>"
    /// v0.5: what `why --touch` really simulates. Swift decides by content hash, so a bare timestamp change recompiles
    /// the touched file only and its dependents stay; carried by `incremental.notes`, the text WHY section and the
    /// html Start-here box (`report.html` repeats the wording).
    public static let touchNote = "--touch changes only the file's timestamp, so Swift recompiled just this file. To see "
        + "what one real edit rebuilds, add a line to the file and run: xcblame why --backtraces -- <args>"

    /// One primary cause per executed task, ranked two ways, with V15. Without a previous index (`currentLogOnly`)
    /// only backtraces and static script I/O apply (§6.6). Throws when the context does not belong to the document.
    public static func attribute(document: ReportDocument, context: CauseContext) throws -> ReportDocument.Incremental {
        guard context.currentRows.count == context.executedTaskIds.count,
              context.matches.isEmpty || context.matches.count == context.currentRows.count else {
            throw XcblameError.usage("cause attribution: \(context.currentRows.count) rows for "
                + "\(context.executedTaskIds.count) executed tasks")
        }
        let model = context.model
        let executed = context.executedTaskIds
        let executedSet = Set(executed)
        let currentLogOnly = context.previous == nil
        let active = providers.filter { !currentLogOnly || $0.source == .backtrace || $0.source == .script }

        // Evidence per task, strongest first (precedence, then provider order).
        var evidence: [Int: [CauseEvidence]] = [:]
        for provider in active {
            for item in provider.evidence(in: context) where executedSet.contains(item.taskId) {
                evidence[item.taskId, default: []].append(item)
            }
        }
        for key in evidence.keys { evidence[key]?.sort { $0.source.precedence < $1.source.precedence } }

        // Resolution: the strongest evidence; one pointing at an upstream task (`rootTaskId`) takes that task's
        // resolution, so a `ruleInputRebuilt` chain rolls up to its root.
        var memo: [Int: Resolved] = [:]
        var visiting = Set<Int>()
        func resolve(_ id: Int) -> Resolved? {
            if let done = memo[id] { return done }
            guard !visiting.contains(id) else { return nil }
            visiting.insert(id)
            defer { visiting.remove(id) }
            if let item = evidence[id]?.first {
                var result: Resolved
                // An upstream task that is not executed, has no evidence, or closes a cycle: the evidence's own class.
                if let root = item.rootTaskId, root != id, executedSet.contains(root), let upstream = resolve(root) {
                    result = upstream
                    result.lines = ["\(item.source.rawValue): \(item.detail) → joins '\(Self.label(model, root))'"]
                } else {
                    result = Resolved(cls: item.cls, subject: item.subject, source: item.source, ruleId: item.ruleId,
                                      lines: ["\(item.source.rawValue): \(item.detail)"], secondary: [])
                }
                result.secondary = (evidence[id] ?? []).dropFirst().map { "\($0.source.rawValue): \($0.detail)" }
                memo[id] = result
                return result
            }
            return nil
        }

        // Per-task seconds (the clamped intervals of the timeline: Σ == build.taskTime) and path seconds.
        let timeline = Timing.timeline(model)
        var seconds: [Int: Double] = [:]
        for item in timeline.counted { seconds[item.task.id] = item.interval.duration }
        let pathSeconds = Self.pathSeconds(document.criticalPath, model: model)

        struct Group {
            var resolved: Resolved
            var taskIds: [Int] = []
            var lines: [String] = []
            var secondary: [String] = []
        }
        var groups: [String: Group] = [:]
        var unknownIds: [Int] = []
        for id in executed {
            guard let resolved = resolve(id) else { unknownIds.append(id); continue }
            let causeId = resolved.id
            var group = groups[causeId] ?? Group(resolved: resolved)
            group.taskIds.append(id)
            if resolved.source < group.resolved.source { group.resolved.source = resolved.source }
            if group.resolved.ruleId == nil { group.resolved.ruleId = resolved.ruleId }
            for line in resolved.lines where !group.lines.contains(line) && group.lines.count < 10 { group.lines.append(line) }
            for line in resolved.secondary where !group.secondary.contains(line) && group.secondary.count < 10 {
                group.secondary.append(line)
            }
            groups[causeId] = group
        }

        let rowIndex = Dictionary(executed.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        let hasPath = document.criticalPath != nil
        let topN = max(1, document.topN)
        func causeTasks(_ ids: [Int]) -> (tasks: [ReportDocument.Incremental.CauseTask], total: Double, path: Double?, shown: Double?) {
            let sorted = ids.sorted { (seconds[$0] ?? 0, $1) > (seconds[$1] ?? 0, $0) }
            let total = sorted.reduce(0) { $0 + (seconds[$1] ?? 0) }
            let path = hasPath ? sorted.reduce(0) { $0 + (pathSeconds[$1] ?? 0) } : nil
            let kept = Array(sorted.prefix(topN))
            let keptSeconds = kept.reduce(0) { $0 + (seconds[$1] ?? 0) }
            let tasks = kept.map { id -> ReportDocument.Incremental.CauseTask in
                let task = model.tasks[id]
                let row = rowIndex[id].map { context.currentRows[$0] }
                return .init(key: row?.key ?? task.taskKey, label: Self.label(model, id),
                             target: task.targetId.flatMap { model.targets.indices.contains($0) ? model.targets[$0].name : nil },
                             kind: task.kind.rawValue, seconds: ReportDocument.round6(seconds[id] ?? 0),
                             pathSeconds: hasPath ? ReportDocument.round6(pathSeconds[id] ?? 0) : nil, taskId: id)
            }
            return (tasks, total, path, total > 0 ? ReportDocument.round6(keptSeconds / total) : nil)
        }

        var causes: [ReportDocument.Incremental.Cause] = groups.map { id, group in
            let made = causeTasks(group.taskIds)
            let resolved = group.resolved
            let rebuilt = resolved.cls == .inputChanged ? Self.recompiled(group.taskIds, subject: resolved.subject, model: model) : nil
            return .init(id: id, class: resolved.cls.rawValue,
                         cause: Self.causeText(resolved, previous: context.previous, recompiled: rebuilt),
                         source: resolved.source.rawValue, subject: resolved.subject, evidence: group.lines,
                         secondaryEvidence: group.secondary, tasks: made.tasks, tasksTotal: group.taskIds.count,
                         tasksShownShare: made.shown, seconds: ReportDocument.round6(made.total),
                         pathSeconds: made.path.map(ReportDocument.round6), ruleId: resolved.ruleId,
                         whatToDo: Self.whatToDo(resolved, recompiled: rebuilt))
        }
        causes.sort { ($0.seconds, $1.id) > ($1.seconds, $0.id) }
        let unknownMade = causeTasks(unknownIds)
        let unknownText = currentLogOnly
            ? "No previous build of this scheme, configuration and destination is recorded, and no backtrace or "
                + "script phase explains these tasks; run \(backtracesHint)"
            : "No evidence explains these tasks; run \(backtracesHint)"
        causes.append(.init(id: "unknown", class: CauseClass.unknown.rawValue, cause: unknownText,
                            source: EvidenceSource.unknown.rawValue, subject: nil, evidence: [],
                            secondaryEvidence: [], tasks: unknownMade.tasks, tasksTotal: unknownIds.count,
                            tasksShownShare: unknownMade.shown, seconds: ReportDocument.round6(unknownMade.total),
                            pathSeconds: unknownMade.path.map(ReportDocument.round6), ruleId: nil,
                            whatToDo: unknownIds.isEmpty ? nil : "Run \(backtracesHint) to get Xcode's own reason for each task."))

        let executedSeconds = document.build.taskTime
        let sum = causes.reduce(0) { $0 + $1.seconds }
        let unknownSeconds = causes.last?.seconds ?? 0
        let byTaskTime = causes.sorted { ($0.seconds, $1.id) > ($1.seconds, $0.id) }.map(\.id)
        let byPath = hasPath
            ? causes.sorted { ($0.pathSeconds ?? 0, $1.id) > ($1.pathSeconds ?? 0, $0.id) }.map(\.id) : []

        var notes: [String] = []
        if currentLogOnly {
            notes.append("basis: no previous build of the same scheme, configuration and destination in history; only "
                + "backtraces and script phases count, everything else is unknown (no previous build recorded)")
        }
        let withBacktraces = executed.filter { BacktraceRoot.of(model.tasks[$0]) != nil }.count
        if withBacktraces == 0 {
            notes.append("backtraces: none in this log (run \(backtracesHint) to record Task Backtraces)")
        } else {
            notes.append("backtraces: \(withBacktraces) of \(executed.count) executed tasks carry one")
        }
        if !currentLogOnly {
            if context.capture == nil {
                notes.append("upstreamInterface, mtimeChurn: no output or input hashes captured for this build (only "
                    + "xcblame why captures them)")
            } else if let previous = context.previous,
                      !previous.rows.contains(where: { $0.outputHash != nil || $0.inputHashes != nil }) {
                notes.append("upstreamInterface, mtimeChurn: the previous build \(previous.id) recorded no hashes")
            }
        }
        if let previous = context.previous { notes += limitNotes(context, previous: previous) }
        if executedSeconds == nil { notes.append("v15: executed task time unknown (timing withheld)") }

        return ReportDocument.Incremental(
            basis: currentLogOnly ? "currentLogOnly" : "previousIndex",
            previousBuild: context.previous.map { .init(id: $0.id, time: $0.time) },
            causes: causes, unknownSeconds: unknownSeconds,
            unknownShare: (executedSeconds ?? 0) > 0 ? ReportDocument.round6(unknownSeconds / executedSeconds!) : nil,
            byTaskTime: byTaskTime, byPathSeconds: byPath,
            v15: V15.evaluate(sumOfCauses: ReportDocument.round6(sum), executedSeconds: executedSeconds),
            procedure: nil, notes: notes)
    }

    /// Rules of the Swift driver's per-file jobs, whose task keys may be handed out per build.
    static let driverJobRules: Set<String> = ["SwiftCompile", "SwiftDriverJobDiscovery"]

    /// The three limits of the previous-index comparison (docs/SCHEMA-v0.5.md "Integration notes"), one note each and
    /// only when this build has tasks they touch.
    static func limitNotes(_ context: CauseContext, previous: PreviousIndex) -> [String] {
        var notes: [String] = []
        let rows = context.executedRows
        let unmatched = rows.filter { context.matches.indices.contains($0.row) && context.matches[$0.row].previous == nil }
        if !unmatched.isEmpty {
            notes.append("limit: \(unmatched.count) executed task(s) have no counterpart in build \(previous.id), whose "
                + "task index holds only the tasks that build ran; a settings change on them is invisible")
        }
        // Swift driver jobs (per-file compiles, job discovery) can carry per-build keys (32 hex, MV-2): no key match.
        let previousKeys = Set(previous.rows.compactMap { TaskIdentity.stableKey($0.key) })
        let driverJobs = rows.filter { row in
            guard Self.driverJobRules.contains(row.task.ruleName) else { return false }
            return TaskIdentity.stableKey(context.currentRows[row.row].key).map { !previousKeys.contains($0) } ?? true
        }
        if !driverJobs.isEmpty {
            notes.append("limit: \(driverJobs.count) per-file Swift compile or driver job task(s) cannot be matched to build "
                + "\(previous.id) by key (their keys change between builds); they are matched by rule, target and command "
                + "digest only, and a per-file compile takes its module task's cause")
        }
        let scripts = rows.filter { $0.task.kind == .script }
        if !scripts.isEmpty {
            notes.append("limit: \(scripts.count) script task(s) are left out of the signature signal (a script's command "
                + "exports the build environment, which differs per xcodebuild run)")
        }
        return notes
    }

    /// The command-level step (`analyze`, `build`; `why` passes its capture): for a non-clean build, the previous
    /// index of the same build key from `historyDir` (before this build is saved), attribution, and
    /// `document.applying(incremental:)`; a clean build or a failure leaves `incremental` null with a note. Never
    /// throws.
    public static func attach(to document: ReportDocument, model: BuildModel, historyDir: URL,
                              project: ProjectModel?) -> ReportDocument {
        attach(to: document, model: model, historyDir: historyDir, project: project, capture: nil)
    }

    /// `attach` with the `why` capture of this build (`OutputHashes.capture`).
    public static func attach(to document: ReportDocument, model: BuildModel, historyDir: URL, project: ProjectModel?,
                              capture: OutputHashes.Capture?) -> ReportDocument {
        var document = document
        document.notes.removeAll { $0 == pendingNote }
        func null(_ reason: String) -> ReportDocument { nullNote("incremental: null because " + reason) }
        func nullNote(_ note: String) -> ReportDocument {
            if !document.notes.contains(note) { document.notes.append(note) }
            return document.applying(incremental: nil)
        }
        // A doctor document is a project audit (`input.layout == "project"`, `FormatSupport.isDoctor`); `doctor` alone
        // is the rules section every analyze and build document with rules carries.
        if document.input.layout == "project" { return null("this is a doctor document") }
        if document.build.kind == "clean" { return nullNote(cleanNote) }
        if document.build.kind == "clean-action" { return null("build kind is clean-action") }
        guard document.build.taskTime != nil else { return null("timing numbers were withheld") }
        guard document.build.tasks > 0 else { return null("no task executed") }
        do {
            let logEnd = Timing.isPlausible(model.sessionEnd) ? Date(timeIntervalSince1970: model.sessionEnd) : nil
            let lookup = History.previousLookup(for: document, directory: historyDir, logEnd: logEnd)
            let context = try makeContext(document: document, model: model, previous: lookup.index,
                                          project: project ?? scriptProject(document: document, model: model),
                                          capture: capture)
            var incremental = try attribute(document: document, context: context)
            incremental.notes += lookup.notes
            if incremental.basis == "currentLogOnly", !document.notes.contains(noPreviousNote) {
                document.notes.append(noPreviousNote)
            }
            return document.applying(incremental: incremental)
        } catch {
            return null("attribution failed (\(error))")
        }
    }

    /// The context for `document`'s build: rows, matches against `previous`, dependencies, inferred Xcode.
    public static func makeContext(document: ReportDocument, model: BuildModel, previous: PreviousIndex?,
                                   project: ProjectModel?, capture: OutputHashes.Capture?) throws -> CauseContext {
        let rows = History.taskIndexRows(document, model)
        let executed = Timing.timeline(model).counted.map(\.task.id)
        let matches = try previous.map { try TaskIdentity.match(current: rows, previous: $0.rows) } ?? []
        var context = CauseContext(model: model, executedTaskIds: executed, currentRows: rows, previous: previous,
                                   matches: matches, project: project, capture: capture, xcode: document.xcode.value)
        context.targetDependencies = dependencies(document: document, project: project)
        return context
    }

    /// Module graph edges (`from` depends on `to`), else the project's target dependencies.
    static func dependencies(document: ReportDocument, project: ProjectModel?) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        if let graph = document.moduleGraph {
            let names = Dictionary(graph.nodes.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            for edge in graph.edges {
                guard let from = names[edge.from], let to = names[edge.to] else { continue }
                result[from, default: []].insert(to)
            }
        }
        if result.isEmpty, let project {
            for target in project.allTargets {
                result[target.name] = Set(target.dependencies + target.packageProducts)
            }
        }
        return result
    }

    /// Best effort: the project that built the log (DerivedData `info.plist`), read only when a script task ran.
    static func scriptProject(document: ReportDocument, model: BuildModel) -> ProjectModel? {
        let scripts = Timing.timeline(model).counted.contains { $0.task.kind == .script }
        guard scripts, let path = document.input.path,
              let container = ProjectLocator.find(forBuildLog: URL(fileURLWithPath: path), derivedData: nil) else { return nil }
        return try? ProjectModel.load(container: container, scheme: document.build.scheme)
    }

    // MARK: - Pieces

    /// A task's resolved primary cause.
    struct Resolved {
        var cls: CauseClass
        var subject: String?
        var source: EvidenceSource
        var ruleId: String?
        var lines: [String]
        var secondary: [String]

        var id: String { subject.map { cls.rawValue + ":" + $0 } ?? cls.rawValue }
    }

    static func label(_ model: BuildModel, _ id: Int) -> String {
        model.tasks.indices.contains(id) ? Explain.label(model.tasks[id], model: model) : "task \(id)"
    }

    /// Critical-path seconds per task: each segment's seconds split over its tasks by duration.
    static func pathSeconds(_ path: ReportDocument.CriticalPath?, model: BuildModel) -> [Int: Double] {
        guard let path else { return [:] }
        var result: [Int: Double] = [:]
        for segment in path.segments where !segment.taskIds.isEmpty {
            let durations = segment.taskIds.map { model.tasks.indices.contains($0) ? max(0, model.tasks[$0].duration) : 0 }
            let sum = durations.reduce(0, +)
            for (index, id) in segment.taskIds.enumerated() {
                let share = sum > 0 ? durations[index] / sum : 1 / Double(segment.taskIds.count)
                result[id, default: 0] += segment.seconds * share
            }
        }
        return result
    }

    /// What an edit to `subject` recompiled besides the file itself: other files of its own module (the target whose
    /// Swift compile names the file) and files of other modules (its interface changed). Files are counted from the
    /// compile titles (`Compiling A.swift, B.swift` counts 2). Nil when the edited file's module is not found or
    /// nothing else recompiled.
    struct Recompiled: Equatable {
        var module: String
        var files: Int
        var otherModules: Int
    }

    static func recompiled(_ ids: [Int], subject: String?, model: BuildModel) -> Recompiled? {
        guard let subject else { return nil }
        let name = (subject as NSString).lastPathComponent
        guard name.hasSuffix(".swift") else { return nil }
        var module: String?
        var perTarget: [String: Int] = [:]
        for id in ids where model.tasks.indices.contains(id) {
            let task = model.tasks[id]
            guard task.kind == .swiftCompile, let target = task.targetId, model.targets.indices.contains(target) else { continue }
            let names = task.title.components(separatedBy: ".swift").count - 1
            let ownFile = task.title.contains(name)
            if ownFile, module == nil { module = model.targets[target].name }
            perTarget[model.targets[target].name, default: 0] += max(1, names) - (ownFile ? 1 : 0)
        }
        guard let module else { return nil }
        let own = perTarget[module] ?? 0
        let others = perTarget.filter { $0.key != module }.values.reduce(0, +)
        guard own + others > 0 else { return nil }
        return Recompiled(module: module, files: own, otherModules: others)
    }

    /// One line on what to do about a cause (`Cause.whatToDo`).
    static func whatToDo(_ resolved: Resolved, recompiled: Recompiled?) -> String? {
        let subject = resolved.subject ?? ""
        let name = (subject as NSString).lastPathComponent
        switch resolved.cls {
        case .inputChanged:
            guard let recompiled else { return "Nothing to change: an edited file compiles again, as expected." }
            var text = "Files in the same module that depend on \(name) were recompiled; splitting \(recompiled.module) or "
                + "reducing dependencies on this file shrinks the blast radius."
            if recompiled.otherModules > 0 {
                text += " Other modules recompiled too because the interface of \(recompiled.module) changed: keep its public "
                    + "declarations stable (edit function bodies, not signatures)."
            }
            return text
        case .scriptPhase:
            return "Declare the script's input and output files in its Run Script phase, so Xcode can skip it (PHASE-001)."
        case .settingsChanged: return "Expected after a settings change; nothing to do if you changed them on purpose."
        case .upstreamInterface:
            return resolved.ruleId == "DYN-005" ? "Nothing to change in your code: a known Xcode 27.0 issue (DYN-005)."
                : "Keep the public interface of \(subject) stable (edit function bodies, not signatures) so its dependents can skip."
        case .timestampChurn:
            return "Find the script or tool that rewrites \(name.isEmpty ? subject : name) on every build and make it write "
                + "only when the content changes (DYN-002)."
        case .planning, .forced: return "Nothing to change: Xcode does this on every build."
        case .firstBuild: return "Nothing to change: these tasks had not run in this DerivedData before."
        case .driverRemark: return "Nothing to change unless the list of files keeps growing; the Swift driver chose them."
        case .unknown: return nil
        }
    }

    /// One line for humans per class.
    static func causeText(_ resolved: Resolved, previous: PreviousIndex?, recompiled: Recompiled? = nil) -> String {
        let subject = resolved.subject ?? ""
        let name = (subject as NSString).lastPathComponent
        let since = previous.map { " since build \($0.id)" } ?? ""
        switch resolved.cls {
        case .inputChanged:
            guard let recompiled else { return "\(name.isEmpty ? subject : name) changed\(since)" }
            let file = name.isEmpty ? subject : name
            var parts: [String] = []
            if recompiled.files > 0 {
                parts.append("\(recompiled.files) other file\(recompiled.files == 1 ? "" : "s") of module \(recompiled.module)")
            }
            if recompiled.otherModules > 0 {
                parts.append("\(recompiled.otherModules) file\(recompiled.otherModules == 1 ? "" : "s") of other modules (the "
                    + "interface of \(recompiled.module) changed)")
            }
            return "Your edit to \(file) recompiled " + parts.joined(separator: " and ")
                + (since.isEmpty ? "" : " (\(since.dropFirst()))")
                + (recompiled.files > 0 ? ": files in the same module that depend on it were recompiled" : "")
        case .scriptPhase:
            let parts = subject.split(separator: "/", maxSplits: 1).map(String.init)
            let phase = parts.count == 2 ? "Run Script \"\(parts[1])\" (\(parts[0]))" : "Run Script \"\(subject)\""
            return "\(phase) runs on every build: no outputs declared, always out of date, or no inputs (PHASE-001)"
        case .settingsChanged: return "Settings or command lines of \(subject) changed\(since)"
        case .upstreamInterface:
            return resolved.ruleId == "DYN-005"
                ? "\(subject) re-emitted an unchanged module (Xcode 27.0 false trigger, DYN-005)"
                : "The emitted module of \(subject) changed, so its dependents rebuilt"
        case .timestampChurn:
            return "\(name.isEmpty ? subject : name) got a newer modification time with the same content, so the tasks "
                + "reading it re-ran (DYN-002)"
        case .planning:
            return subject == "build planning"
                ? "Build planning (build request, description, dependency graph) runs on every build"
                : "Swift planning of \(subject) re-ran without compiling anything"
        case .firstBuild: return "Tasks of \(subject) had never run in this DerivedData (or were not in the previous build)"
        case .forced: return "\(subject) runs on every incremental build or had missing outputs"
        case .driverRemark: return "The Swift driver scheduled compiles for \(name.isEmpty ? subject : name)"
        case .unknown: return "No evidence explains these tasks; run \(backtracesHint)"
        }
    }
}
