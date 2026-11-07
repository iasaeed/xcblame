import Foundation

// v0.5 lane B (docs/SCHEMA-v0.5.md "Cause attribution", DESIGN §6.6): one provider per evidence source, in precedence
// order. Providers are pure: they read the context (model, rows, previous index, project, capture) and never run a
// process or touch the file system.

extension CauseContext {
    /// Target name of a task; nil for tasks without one.
    func targetName(_ task: BuildTask) -> String? {
        task.targetId.flatMap { model.targets.indices.contains($0) ? model.targets[$0].name : nil }
    }

    /// The executed tasks with their row index (`currentRows[row]` is the task's row, `matches[row]` its match).
    var executedRows: [(row: Int, task: BuildTask)] {
        executedTaskIds.enumerated().compactMap { row, id in
            model.tasks.indices.contains(id) ? (row, model.tasks[id]) : nil
        }
    }

    /// The previous build's row matched to current row `row`.
    func previousRow(_ row: Int) -> History.TaskIndexRow? {
        guard let previous, matches.indices.contains(row), let index = matches[row].previous,
              previous.rows.indices.contains(index) else { return nil }
        return previous.rows[index]
    }

    /// Xcode 26.x, from the inferred version (`26`, `26.0.1`).
    var isXcode26: Bool { xcode.map { $0 == "26" || $0.hasPrefix("26.") } ?? false }
    /// Xcode 27.0.x (the swift-driver#2214 false trigger, DYN-005).
    var isXcode270: Bool { xcode.map { $0 == "27.0" || $0.hasPrefix("27.0.") } ?? false }
}

/// Rules of the dynamic Swift tasks whose own backtrace only says "had never run" (or "did not have up-to-date
/// outputs") in an incremental build: their cause sits on the module's `SwiftDriver Compilation` task (MV-2).
let swiftModuleRules: Set<String> = ["SwiftCompile", "SwiftEmitModule", "EmitSwiftModule", "SwiftDriver",
                                     "SwiftDriverJobDiscovery", "SwiftDriver Compilation Requirements"]
let swiftModuleCompileRule = "SwiftDriver Compilation"

/// `Stamp` from a `PhaseScriptExecution` task: the quoted name of the title (`Run custom shell script 'Stamp'`),
/// else the first argument of the command line with its escaped spaces.
func scriptPhaseName(_ task: BuildTask) -> String? {
    if let name = BacktraceRoot.quoted(task.title) { return name }
    guard let details = task.commandDetails, details.hasPrefix("PhaseScriptExecution ") else { return nil }
    var name = ""
    var escaped = false
    for character in details.dropFirst("PhaseScriptExecution ".count) {
        if escaped { name.append(character); escaped = false; continue }
        if character == "\\" { escaped = true; continue }
        if character == " " || character == "\n" || character == "\r" { break }
        name.append(character)
    }
    return name.isEmpty ? nil : name
}

/// The module a DerivedData product belongs to: `…/Core.swiftmodule`, `Core.abi.json`, `Core.swiftsourceinfo`,
/// `Core.swiftdoc`, `Core.swiftinterface` under `Build/Intermediates.noindex` or `Build/Products`; nil otherwise.
func derivedModuleProduct(_ path: String) -> String? {
    guard path.contains("/Build/Intermediates.noindex/") || path.contains("/Build/Products/") else { return nil }
    for component in path.split(separator: "/").reversed() {
        for suffix in [".swiftmodule", ".abi.json", ".swiftsourceinfo", ".swiftdoc", ".swiftinterface"]
        where component.hasSuffix(suffix) && component.count > suffix.count {
            return String(component.dropLast(suffix.count))
        }
    }
    return nil
}

// MARK: - 1. Backtraces

/// Precedence 1: Task Backtraces (MV-2). The root (last frame) decides the class; a chain through other tasks points at
/// the upstream task (`rootTaskId`), so the task joins that task's cause; dynamic Swift tasks of a module join the
/// module's `SwiftDriver Compilation` task.
public struct BacktraceEvidenceProvider: CauseEvidenceProvider {
    public var source: EvidenceSource { .backtrace }
    public init() {}

    public func evidence(in context: CauseContext) -> [CauseEvidence] {
        let executed = context.executedRows.map(\.task)
        var roots: [Int: BacktraceRoot] = [:]
        for task in executed { if let root = BacktraceRoot.of(task) { roots[task.id] = root } }
        guard !roots.isEmpty else { return [] }
        var byKey: [String: Int] = [:]
        var byTitle: [String: [Int]] = [:]
        var moduleCompile: [Int: Int] = [:]
        var emitModule: [String: Int] = [:]
        for task in executed {
            if let key = task.taskKey { byKey[key] = task.id }
            byTitle[task.title, default: []].append(task.id)
            if task.ruleName == swiftModuleCompileRule, let target = task.targetId { moduleCompile[target] = task.id }
            if task.kind == .swiftEmitModule, let name = context.targetName(task),
               emitModule[name] == nil || task.ruleName == "SwiftEmitModule" {
                emitModule[name] = task.id
            }
        }
        func upstream(_ root: BacktraceRoot, of id: Int) -> Int? {
            if let key = root.rootTaskKey, let found = byKey[key], found != id { return found }
            if let title = root.rootTaskTitle, let found = byTitle[title], found.count == 1, found[0] != id { return found[0] }
            return nil
        }
        func decides(_ root: BacktraceRoot) -> Bool {
            switch root.kind {
            case .neverBuilt, .outputsInvalid, .driverScheduled, .inputRebuilt, .other: return root.rootTaskKey != nil
            default: return true
            }
        }

        var out: [CauseEvidence] = []
        for task in executed {
            let root = roots[task.id]
            let target = context.targetName(task)
            // MV-2: a per-file compile (or another dynamic Swift task) only says "had never run"; its module's compile
            // task carries the real cause.
            if swiftModuleRules.contains(task.ruleName), root.map({ !decides($0) }) ?? true,
               let targetId = task.targetId, let compile = moduleCompile[targetId], compile != task.id,
               let compileRoot = roots[compile], decides(compileRoot) {
                let own = root.map { "own frame: \($0.description)" } ?? "no frame of its own"
                out.append(CauseEvidence(
                    source: .backtrace, cls: .firstBuild, taskId: task.id, rootTaskId: compile, subject: target,
                    detail: "dynamic Swift task (\(own)); the module task '\(context.model.tasks[compile].title)' decides"))
                continue
            }
            guard let root else { continue }
            var rootTask = upstream(root, of: task.id)
            let chain = "\(root.frameCount) frame\(root.frameCount == 1 ? "" : "s"), root: \(root.description)"
            let cls: CauseClass
            var subject: String?
            var ruleId: String?
            switch root.kind {
            case let .fileChanged(path), let .directoryChanged(path):
                if let module = derivedModuleProduct(path) {
                    cls = .upstreamInterface
                    subject = module
                    if rootTask == nil, let producer = emitModule[module], producer != task.id { rootTask = producer }
                } else {
                    cls = .inputChanged
                    subject = path
                }
            case .signatureChanged:
                cls = .settingsChanged
                subject = target ?? "build system"
            case .neverBuilt, .driverScheduled:
                cls = .firstBuild
                subject = target ?? "build system"
            case .alwaysRuns:
                if task.kind == .script {
                    cls = .scriptPhase
                    subject = (target ?? "(no target)") + "/" + (scriptPhaseName(task) ?? task.title)
                    ruleId = "PHASE-001"
                } else {
                    cls = .forced
                    subject = task.ruleName
                }
            case .outputsInvalid, .forced:
                cls = .forced
                subject = target ?? task.ruleName
            case .inputRebuilt, .other:
                guard rootTask != nil else { continue }
                cls = .inputChanged
                subject = target
            }
            out.append(CauseEvidence(source: .backtrace, cls: cls, taskId: task.id, rootTaskId: rootTask,
                                     subject: subject, detail: chain, ruleId: ruleId))
        }
        return out
    }
}

// MARK: - 2. Script phases

/// Precedence 2: a script phase that declares no outputs, is `alwaysOutOfDate`, or declares no inputs (ProjectModel),
/// or, without a project, Xcode's own "will be run during every build" warning on the task.
public struct ScriptEvidenceProvider: CauseEvidenceProvider {
    public var source: EvidenceSource { .script }
    public init() {}

    public func evidence(in context: CauseContext) -> [CauseEvidence] {
        var out: [CauseEvidence] = []
        let targets = context.project?.allTargets ?? []
        for (_, task) in context.executedRows where task.kind == .script || task.ruleName == "PhaseScriptExecution" {
            let target = context.targetName(task)
            let name = scriptPhaseName(task)
            let subject = (target ?? "(no target)") + "/" + (name ?? task.title)
            var reasons: [String] = []
            if let target, let name,
               let owner = targets.first(where: { $0.name == target || $0.name.hasSuffix("/" + target) }) {
                for case let .shellScript(phase) in owner.phases where phase.name == name {
                    if phase.outputPaths.isEmpty && phase.outputFileListPaths.isEmpty { reasons.append("declares no outputs") }
                    if phase.alwaysOutOfDate { reasons.append("is set to run on every build (alwaysOutOfDate)") }
                    if phase.inputPaths.isEmpty && phase.inputFileListPaths.isEmpty { reasons.append("declares no inputs") }
                    break
                }
            }
            if reasons.isEmpty {
                let warned = task.diagnosticIds.contains { id in
                    context.model.diagnostics.indices.contains(id)
                        && context.model.diagnostics[id].text.contains("will be run during every build")
                }
                if warned { reasons.append("Xcode warns it will be run during every build (no outputs)") }
            }
            guard !reasons.isEmpty else { continue }
            out.append(CauseEvidence(source: .script, cls: .scriptPhase, taskId: task.id, subject: subject,
                                     detail: "Run Script \"\(name ?? task.title)\" " + reasons.joined(separator: ", "),
                                     ruleId: "PHASE-001"))
        }
        return out
    }
}

// MARK: - 3. Signature digest

/// Precedence 3: the task key matched a previous row with a different command-line digest (settings or command line
/// changed). After a clean previous build, a keyed task with no counterpart is new (`firstBuild`).
public struct SignatureEvidenceProvider: CauseEvidenceProvider {
    public var source: EvidenceSource { .signature }
    public init() {}

    public func evidence(in context: CauseContext) -> [CauseEvidence] {
        guard let previous = context.previous else { return [] }
        let previousKeys = Set(previous.rows.compactMap { TaskIdentity.stableKey($0.key) })
        var out: [CauseEvidence] = []
        for (row, task) in context.executedRows where context.matches.indices.contains(row) {
            let match = context.matches[row]
            let target = context.targetName(task)
            // Swift planning and the driver gates list their inputs in a build-dependent order (same words, other
            // order, on both remarks fixtures), and a script's command text exports the build environment, which
            // differs per xcodebuild invocation (AcmeWhy); their digest is no settings signal.
            if match.signatureChanged, !task.ruleName.hasPrefix("SwiftDriver"), task.kind != .script {
                out.append(CauseEvidence(source: .signature, cls: .settingsChanged, taskId: task.id,
                                         subject: target ?? "build system",
                                         detail: "command line differs from build \(previous.id) (same task key)"))
            } else if match.previous == nil, previous.kind == "clean",
                      let key = TaskIdentity.stableKey(context.currentRows[row].key),
                      !previousKeys.contains(key) {
                out.append(CauseEvidence(source: .signature, cls: .firstBuild, taskId: task.id,
                                         subject: target ?? "build system",
                                         detail: "no task with this key in the clean build \(previous.id)"))
            }
        }
        return out
    }
}

// MARK: - 4. Upstream interface

/// Precedence 4: a dependency's emit-module ran and its output hash changed (needs the `why` capture on both builds).
/// On Xcode 27.0, an emit-module that re-ran with an unchanged output is the swift-driver#2214 false trigger (DYN-005).
public struct UpstreamInterfaceEvidenceProvider: CauseEvidenceProvider {
    public var source: EvidenceSource { .upstreamInterface }
    public init() {}

    public func evidence(in context: CauseContext) -> [CauseEvidence] {
        guard let capture = context.capture, context.previous != nil else { return [] }
        var changed: [String] = []
        var unchangedEmits: [(task: BuildTask, module: String)] = []
        for (row, task) in context.executedRows where task.kind == .swiftEmitModule {
            guard let module = context.targetName(task), let key = context.currentRows[row].key,
                  let now = capture.outputs[key], let before = context.previousRow(row)?.outputHash else { continue }
            if now.hash != before { changed.append(module) } else { unchangedEmits.append((task, module)) }
        }
        var out: [CauseEvidence] = []
        if context.isXcode270 {
            for (task, module) in unchangedEmits {
                out.append(CauseEvidence(source: .upstreamInterface, cls: .upstreamInterface, taskId: task.id,
                                         subject: module,
                                         detail: "emit-module of \(module) re-ran with an unchanged interface (Xcode 27.0, swift-driver#2214)",
                                         ruleId: "DYN-005"))
            }
        }
        let changedSet = Set(changed)
        guard !changedSet.isEmpty else { return out }
        let fallback = changed.sorted().first!
        for (_, task) in context.executedRows
        where [.swiftCompile, .swiftPlan, .swiftEmitModule].contains(task.kind) {
            guard let target = context.targetName(task), !changedSet.contains(target) else { continue }
            let deps = context.targetDependencies[target] ?? []
            let module = changed.sorted().first { deps.contains($0) } ?? (deps.isEmpty ? fallback : nil)
            guard let module else { continue }
            out.append(CauseEvidence(source: .upstreamInterface, cls: .upstreamInterface, taskId: task.id,
                                     subject: module,
                                     detail: "the emitted module of \(module) changed (output hash differs from the previous build)"))
        }
        return out
    }
}

// MARK: - 5. Timestamp churn

/// Precedence 5: the task re-ran although every input it read has the content hash recorded by the previous `why`
/// capture, and at least one of them has a modification time newer than the previous build's start (§6.6 step 5):
/// something rewrote (or touched) the file without changing it (DYN-002). The subject is that file. A task whose
/// inputs are all older than the previous build re-ran for another reason (an upstream module, say) and gets no
/// evidence here.
public struct MtimeChurnEvidenceProvider: CauseEvidenceProvider {
    public var source: EvidenceSource { .mtimeChurn }
    public init() {}

    public func evidence(in context: CauseContext) -> [CauseEvidence] {
        guard let capture = context.capture, let since = context.previous?.start?.timeIntervalSince1970 else { return [] }
        var out: [CauseEvidence] = []
        for (row, task) in context.executedRows {
            guard let key = context.currentRows[row].key, let now = capture.inputs[key], !now.isEmpty,
                  let before = context.previousRow(row)?.inputHashes, !before.isEmpty,
                  now.allSatisfy({ before[$0.key] == $0.value }) else { continue }
            let mtimes = capture.inputMtimes[key] ?? [:]
            let newer = now.keys.filter { (mtimes[$0] ?? -.infinity) > since }.sorted()
            guard let first = newer.first else { continue }
            out.append(CauseEvidence(source: .mtimeChurn, cls: .timestampChurn, taskId: task.id, subject: first,
                                     detail: "re-ran: \(newer.count) of its \(now.count) input(s) have a modification time "
                                        + "newer than the previous build's start but the same content",
                                     ruleId: "DYN-002"))
        }
        return out
    }
}

// MARK: - 6. Planning

/// Precedence 6: build-system planning that runs on every build, the SDK stat cache, and Swift planning of a module
/// that compiled nothing (2+ macro plugins per module on Xcode 26.x: ENV-008).
public struct PlanningEvidenceProvider: CauseEvidenceProvider {
    public var source: EvidenceSource { .planning }
    public init() {}

    public func evidence(in context: CauseContext) -> [CauseEvidence] {
        let rows = context.executedRows
        let compiled = Set(rows.filter { $0.task.kind == .swiftCompile }.compactMap { $0.task.targetId })
        let idlePlans = rows.filter { $0.task.kind == .swiftPlan && !($0.task.targetId.map(compiled.contains) ?? false) }
        var out: [CauseEvidence] = []
        for (_, task) in rows {
            switch task.kind {
            case .planning:
                out.append(CauseEvidence(source: .planning, cls: .planning, taskId: task.id, subject: "build planning",
                                         detail: "\(task.ruleName) runs on every build (build request, description, dependency graph)"))
            case .sdkStatCache:
                out.append(CauseEvidence(source: .planning, cls: .forced, taskId: task.id, subject: task.ruleName,
                                         detail: "the SDK stat cache is checked on every build"))
            case .swiftPlan where idlePlans.contains(where: { $0.task.id == task.id }):
                let target = context.targetName(task) ?? "(no target)"
                let plugins = Self.macroPlugins(of: task.targetId, in: context)
                let ruleId = context.isXcode26 && plugins >= 2 ? "ENV-008" : (idlePlans.count >= 5 ? "DYN-003" : nil)
                var detail = "Swift planning of \(target) ran but compiled nothing"
                if plugins >= 2 { detail += " (\(plugins) macro plugins on the module)" }
                out.append(CauseEvidence(source: .planning, cls: .planning, taskId: task.id, subject: target,
                                         detail: detail, ruleId: ruleId))
            default:
                continue
            }
        }
        return out
    }

    /// Distinct `-load-plugin-executable <path>#<Name>` plugins on the Swift command lines of a target.
    static func macroPlugins(of targetId: Int?, in context: CauseContext) -> Int {
        guard let targetId else { return 0 }
        var names = Set<String>()
        for task in context.model.tasks where task.targetId == targetId && task.ruleName.hasPrefix("Swift") {
            guard let details = task.commandDetails, details.contains("-load-plugin-executable") else { continue }
            let words = details.split(whereSeparator: { $0 == " " || $0 == "\n" })
            for (index, word) in words.enumerated() where word == "-load-plugin-executable" && index + 1 < words.count {
                names.insert(String(words[index + 1]))
            }
        }
        return names.count
    }
}

// MARK: - 7. Driver remarks

/// Precedence 7: `-driver-show-incremental` remarks on the `Planning Swift module X` task (MV-8: the only place they
/// reach the SLF and xcresult). `Scheduling changed input`, `Invalidated externally`, `Queuing …` name the files.
public struct DriverRemarkEvidenceProvider: CauseEvidenceProvider {
    public var source: EvidenceSource { .driverRemark }
    public init() {}

    /// What a module's planning remarks say.
    struct Remarks: Equatable {
        var changed: [String] = []
        var external: Set<String> = []
        var imports: [String] = []
        var queued: Set<String> = []
        var cascaded: Set<String> = []
        /// `May skip current input` / `Skipping input`: skipped at planning; compiled anyway means a cascade the
        /// SLF does not record (MV-8: `Queuing because of dependencies discovered later` reaches only 26's stdout).
        var skipped: Set<String> = []
        var isEmpty: Bool {
            changed.isEmpty && external.isEmpty && imports.isEmpty && queued.isEmpty && cascaded.isEmpty && skipped.isEmpty
        }
    }

    public func evidence(in context: CauseContext) -> [CauseEvidence] {
        let rows = context.executedRows
        var remarks: [Int: Remarks] = [:]
        for (_, task) in rows where task.kind == .swiftPlan || task.ruleName == "SwiftDriver" {
            guard let target = task.targetId else { continue }
            let texts = task.diagnosticIds.compactMap { id in
                context.model.diagnostics.indices.contains(id) ? context.model.diagnostics[id].text : nil
            } + (task.emittedOutput.map { [$0] } ?? [])
            let parsed = Self.parse(texts)
            if !parsed.isEmpty { remarks[target] = parsed }
        }
        guard !remarks.isEmpty else { return [] }
        var out: [CauseEvidence] = []
        // Full paths of the files the remarks name, from the module's compile command lines.
        var paths: [String: String] = [:]
        for (_, task) in rows where task.ruleName == "SwiftCompile" {
            for file in FileAttribution.files(of: task) where file.hasSuffix(".swift") {
                paths[(file as NSString).lastPathComponent] = paths[(file as NSString).lastPathComponent] ?? file
            }
        }
        for (_, task) in rows {
            guard let target = task.targetId, let module = remarks[target] else { continue }
            let firstChanged = module.changed.first.map { paths[$0] ?? $0 }
            let external = module.imports.first.map { $0 + " (newer incremental import)" }
            if task.kind == .swiftPlan || task.ruleName == "SwiftDriver" {
                guard let subject = firstChanged ?? external else { continue }
                out.append(CauseEvidence(source: .driverRemark, cls: .driverRemark, taskId: task.id, subject: subject,
                                         detail: "the driver re-planned \(context.targetName(task) ?? "the module") for \(subject)"))
                continue
            }
            guard task.ruleName == "SwiftCompile" else { continue }
            let files = FileAttribution.files(of: task).map { ($0 as NSString).lastPathComponent }
            if let file = files.first(where: { module.changed.contains($0) }) {
                out.append(CauseEvidence(source: .driverRemark, cls: .driverRemark, taskId: task.id,
                                         subject: paths[file] ?? file, detail: "Scheduling changed input \(file)"))
            } else if let file = files.first(where: { module.external.contains($0) }), let external {
                out.append(CauseEvidence(source: .driverRemark, cls: .driverRemark, taskId: task.id, subject: external,
                                         detail: "Invalidated externally: \(file) depends on \(external)"))
            } else if let file = files.first(where: { module.cascaded.contains($0) || module.queued.contains($0) }),
                      let subject = firstChanged ?? external {
                out.append(CauseEvidence(source: .driverRemark, cls: .driverRemark, taskId: task.id, subject: subject,
                                         detail: "Queuing \(file) after \(subject) changed"))
            } else if let file = files.first(where: { module.skipped.contains($0) }), let subject = firstChanged {
                out.append(CauseEvidence(source: .driverRemark, cls: .driverRemark, taskId: task.id, subject: subject,
                                         detail: "\(file) was skipped at planning and compiled after the dependencies "
                                            + "of \(subject) were discovered"))
            }
        }
        return out
    }

    /// Remark lines (`note: `/`remark: ` prefix and ` (in target …)` suffix optional) of one module.
    static func parse(_ texts: [String]) -> Remarks {
        var remarks = Remarks()
        let marker = "Incremental compilation: "
        for text in texts {
            for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                guard let start = raw.range(of: marker) else { continue }
                var line = String(raw[start.upperBound...])
                if let suffix = line.range(of: " (in target '") { line = String(line[..<suffix.lowerBound]) }
                let file = compiledFile(line)
                if line.hasPrefix("Scheduling changed input"), let file {
                    if !remarks.changed.contains(file) { remarks.changed.append(file) }
                } else if line.hasPrefix("Invalidated externally"), let file {
                    remarks.external.insert(file)
                } else if line.hasPrefix("Integrating newer incremental import: ") {
                    let module = String(line.dropFirst("Integrating newer incremental import: ".count))
                        .trimmingCharacters(in: .whitespaces)
                    if !remarks.imports.contains(module) { remarks.imports.append(module) }
                } else if line.hasPrefix("May skip current input") || line.hasPrefix("Skipping input"), let file {
                    remarks.skipped.insert(file)
                } else if line.hasPrefix("Queuing (initial)"), let file {
                    remarks.queued.insert(file)
                } else if line.hasPrefix("Queuing because of dependencies discovered later")
                            || line.hasPrefix("Scheduling invalidated"), let file {
                    remarks.cascaded.insert(file)
                }
            }
        }
        return remarks
    }

    /// `… {compile: Models.o <= Models.swift}` → `Models.swift`.
    static func compiledFile(_ line: String) -> String? {
        guard let open = line.range(of: "{compile: "), let arrow = line.range(of: " <= ", range: open.upperBound..<line.endIndex),
              let close = line.range(of: "}", range: arrow.upperBound..<line.endIndex) else { return nil }
        let file = line[arrow.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
        return file.isEmpty ? nil : file
    }
}
