import Foundation

// MARK: - Walk state

extension BuildModelBuilder {
    enum PendingTarget {
        case signature(name: String, project: String, path: String?)
        case path(String)
        case bucket(String)
    }

    struct State {
        let kindTable: KindTable
        var interner = StringInterner()
        var tasks: [BuildTask] = []
        var targets: [Target] = []
        var collector = DiagnosticCollector()
        var warnings: [DecodeWarning] = []
        var warned: Set<String> = []
        var timingRows: [TimingSummary.Row] = []
        var buildAttachments: [KeptAttachment] = []
        /// Index = task id.
        var pending: [PendingTarget] = []
        var targetByKey: [String: Int] = [:]
        var targetByName: [String: Int] = [:]

        init(kindTable: KindTable) { self.kindTable = kindTable }

        mutating func warnOnce(_ kind: DecodeWarning.Kind, key: String, detail: String, affectsTiming: Bool = false) {
            guard warned.insert(kind.rawValue + "|" + key).inserted else { return }
            warnings.append(DecodeWarning(kind: kind, detail: detail, affectsTiming: affectsTiming))
        }

        mutating func visit(_ section: RawSection, eligible: Bool) {
            let role = BuildModelBuilder.role(of: section.domainType)
            switch role {
            case .timingAggregate:
                // Known exception to "titles never decide" (§4.3 rule 7): xcresult carries the aggregate row only in
                // its title. The row feeds V5's reference numbers, never task structure.
                let text = section.commandDetails ?? section.signature ?? section.title
                if let row = BuildModelBuilder.parseTimingRow(text) {
                    timingRows.append(TimingSummary.Row(ruleName: interner.intern(row.ruleName),
                                                        taskCount: row.taskCount, seconds: row.seconds))
                } else {
                    warnOnce(.timingSummaryRow, key: text, detail: "unparsed timing aggregate row: \(text.prefix(120))")
                }
                return
            case .unknown:
                let domain = section.domainType ?? ""
                warnOnce(.unknownDomain, key: domain, detail: "unknown section domain \(domain)")
            case .container, .task, .nonTask:
                break
            }
            if eligible, role == .task || role == .unknown, let rule = BuildModelBuilder.ruleName(of: section) {
                if BuildModelBuilder.hasTaskEvidence(section) {
                    makeTask(section, rule: rule)
                    return
                }
                // No command and no target suffix, but children with rule names: walking through would count the
                // per-file children as outermost tasks. Keep the outermost unit (children stay sub-spans) and warn.
                if section.subsections.contains(where: { BuildModelBuilder.ruleName(of: $0) != nil }) {
                    warnOnce(.schemaDrift, key: "no-command|" + rule, detail: "\(rule) section without commandDetails "
                        + "counted as one task by its signature; its children are sub-spans")
                    makeTask(section, rule: rule)
                    return
                }
            }
            for message in section.messages { collector.add(message, taskId: nil, interner: &interner) }
            for attachment in section.attachments { keepBuildAttachment(attachment) }
            let childEligible = eligible && role != .nonTask
            for child in section.subsections { visit(child, eligible: childEligible) }
        }

        mutating func makeTask(_ section: RawSection, rule: String) {
            let id = tasks.count
            let kind: TaskKind, phase: Phase, source: BuildTask.KindSource
            if let entry = kindTable.lookup(rule) {
                (kind, phase, source) = (entry.kind, entry.phase, .rule)
            } else if let tool = BuildModelBuilder.toolKind(commandDetails: section.commandDetails,
                                                             emittedOutput: section.emittedOutput) {
                (kind, phase, source) = (tool, KindTable.defaultPhase(for: tool), .tool)
            } else {
                (kind, phase, source) = (.other, .other, .none)
            }
            var task = BuildTask(
                id: id, ruleName: interner.intern(rule), kind: kind, kindSource: source, phase: phase, targetId: nil,
                start: section.start, end: section.end, duration: section.end - section.start,
                resultCode: section.resultCode, metrics: nil, backtrace: nil, taskKey: nil, subspans: [],
                commandDetails: section.commandDetails, signature: section.signature, title: section.title,
                emittedOutput: section.emittedOutput, diagnosticIds: [], slfOnly: section.slfOnly,
                unknownAttachments: [])
            for attachment in section.attachments { decode(attachment, into: &task) }
            // TaskMetrics carry µs-precise timing; the section's doubles are the fallback.
            if let m = task.metrics, let start = m.start, let duration = m.duration, start.isFinite,
               duration.isFinite, duration >= 0 {
                task.start = start
                task.end = start + duration
                task.duration = duration
            } else if section.timingMissing {
                (task.start, task.end, task.duration, task.timingMissing) = (0, 0, 0, true)
            }
            if let hex = section.slfOnly?.xcbuildSignatureHex, !hex.isEmpty {
                task.taskKey = BuildModelBuilder.taskKey(fromSignatureHex: hex)
                if task.taskKey == nil {
                    warnOnce(.invalidSignature, key: "hex", detail: "task signature slot is not prefixed hex")
                }
            }
            var seen = Set<Int>()
            addMessages(section.messages, task: &task, seen: &seen)
            addSubspans(section.subsections, task: &task, seen: &seen)
            pending.append(pendingTarget(section, kind: kind))
            tasks.append(task)
        }

        mutating func addMessages(_ messages: [RawMessage], task: inout BuildTask, seen: inout Set<Int>) {
            for message in messages {
                let diagnosticId = collector.add(message, taskId: task.id, interner: &interner)
                if seen.insert(diagnosticId).inserted { task.diagnosticIds.append(diagnosticId) }
            }
        }

        mutating func addSubspans(_ sections: [RawSection], task: inout BuildTask, seen: inout Set<Int>) {
            for section in sections {
                task.subspans.append(Subspan(
                    ruleName: interner.intern(BuildModelBuilder.ruleName(of: section)),
                    commandDetails: section.commandDetails, title: section.title,
                    interval: Interval(start: section.start, end: section.end)))
                addMessages(section.messages, task: &task, seen: &seen)
                addSubspans(section.subsections, task: &task, seen: &seen)
            }
        }

        mutating func decode(_ attachment: RawAttachment, into task: inout BuildTask) {
            let id = attachment.identifier
            if id.hasSuffix("TaskMetrics") {
                task.metrics = BuildModelBuilder.decodeMetrics(attachment.data)
                if let m = task.metrics, m.start == nil || m.duration == nil {
                    warnOnce(.schemaDrift, key: "metrics-timing|" + id, detail: "\(id) without wcStartTime/wcDuration",
                             affectsTiming: true)
                }
                if task.metrics == nil { warnOnce(.invalidAttachment, key: id, detail: "undecodable \(id)") }
            } else if id.hasSuffix("TaskBacktrace") {
                task.backtrace = BuildModelBuilder.decodeBacktrace(attachment.data)
                if task.backtrace == nil { warnOnce(.invalidAttachment, key: id, detail: "undecodable \(id)") }
            } else if id.hasSuffix("BuildOperationMetrics") {
                buildAttachments.append(KeptAttachment(identifier: id, data: attachment.data, truncated: false))
            } else {
                task.unknownAttachments.append(Self.capped(attachment))
                warnOnce(.unknownAttachment, key: id, detail: "unknown attachment \(id) kept raw")
            }
        }

        mutating func keepBuildAttachment(_ attachment: RawAttachment) {
            let id = attachment.identifier
            if id.hasSuffix("BuildOperationMetrics") {
                buildAttachments.append(KeptAttachment(identifier: id, data: attachment.data, truncated: false))
                return
            }
            buildAttachments.append(Self.capped(attachment))
            if !(id.hasSuffix("TaskMetrics") || id.hasSuffix("TaskBacktrace")) {
                warnOnce(.unknownAttachment, key: id, detail: "unknown attachment \(id) kept raw")
            }
        }

        static func capped(_ attachment: RawAttachment) -> KeptAttachment {
            let limit = BuildModelBuilder.keptAttachmentLimit
            return KeptAttachment(identifier: attachment.identifier, data: Data(attachment.data.prefix(limit)),
                                  truncated: attachment.data.count > limit)
        }

        func pendingTarget(_ section: RawSection, kind: TaskKind) -> PendingTarget {
            for text in [section.signature, section.commandDetails] {
                if let text, let t = BuildModelBuilder.targetSuffix(in: BuildModelBuilder.firstLine(text)) {
                    return .signature(name: t.name, project: t.project, path: t.path)
                }
            }
            if let text = section.commandDetails ?? section.signature,
               let name = BuildModelBuilder.pathTargetName(in: BuildModelBuilder.firstLine(text)) {
                return .path(name)
            }
            let explicitModules = kind == .moduleScan || kind == .modulePrecompile
            return .bucket(explicitModules ? Target.explicitModulesBucket : Target.buildSystemBucket)
        }

        /// Signature targets first (they carry the project), then path-derived names (matched to a signature target
        /// of the same name when one exists), then buckets. Deterministic ids in task order within each pass.
        mutating func attributeTargets() {
            for (taskId, p) in pending.enumerated() {
                guard case let .signature(name, project, path) = p else { continue }
                let key = name + "\u{0}" + project
                let id = targetByKey[key] ?? addTarget(name: name, project: project, path: path, isBucket: false)
                targetByKey[key] = id
                if targets[id].path == nil, let path { targets[id].path = path; targets[id].isPackage = true }
                tasks[taskId].targetId = id
            }
            for (taskId, p) in pending.enumerated() {
                guard case let .path(name) = p else { continue }
                tasks[taskId].targetId = targetByName[name]
                    ?? addTarget(name: name, project: nil, path: nil, isBucket: false)
            }
            for (taskId, p) in pending.enumerated() {
                guard case let .bucket(name) = p else { continue }
                let key = "\u{1}" + name
                let id = targetByKey[key] ?? addTarget(name: name, project: nil, path: nil, isBucket: true)
                targetByKey[key] = id
                tasks[taskId].targetId = id
            }
            for task in tasks { if let id = task.targetId { targets[id].taskIds.append(task.id) } }
        }

        mutating func addTarget(name: String, project: String?, path: String?, isBucket: Bool) -> Int {
            let id = targets.count
            targets.append(Target(id: id, name: interner.intern(name), project: interner.intern(project),
                                  path: path, isPackage: path != nil, isBucket: isBucket, taskIds: []))
            if !isBucket, targetByName[name] == nil { targetByName[name] = id }
            return id
        }
    }
}
