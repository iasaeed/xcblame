import Foundation

// v0.6 lane A (docs/SCHEMA-v0.6.md "`fix --apply` rules", "Defaults"): the writes `fix` makes with a plan and their
// revert. Every write either completes or is rolled back to the exact bytes before it.
public enum FixApply {
    public struct Result: Sendable {
        public var plan: FixPlanDocument
        /// One line per step written, skipped or restored.
        public var messages: [String]
        /// A write failed and was rolled back, or a file was edited by hand (exit 1).
        public var failed = false
        /// Repository-relative files written or restored.
        public var files: [String] = []
    }

    // MARK: - Overlay

    /// Writes the overlay lines of the plan's `overlay` steps that may be written (rule 2: `kept`, or `unverified`
    /// and not `+V` with `forceUnverified`; rule 4: a key another plan's block sets is skipped). Steps already in the
    /// overlay stay `applied`. Rule 3 (fix round 1): a step planned `cli`, or kept through `cli` while its hook and
    /// cli scope differ, is recorded `applied-cli` and nothing is written: `xcblame build --overlay <plan-id>`
    /// delivers it.
    public static func apply(_ plan: FixPlanDocument, root: URL, xcblameDir: URL, forceUnverified: Bool,
                             now: Date) -> Result {
        var result = Result(plan: plan, messages: [])
        var texts: [String: String?] = [:]
        var owners: [String: [String: (planId: String, ruleId: String, temporary: Bool)]] = [:]
        let configurations = Set(plan.steps.flatMap { $0.overlay.map(\.configuration) })
        for configuration in configurations.sorted() {
            let url = OverlayFile.url(xcblameDir: xcblameDir, configuration: configuration)
            let text = try? String(contentsOf: url, encoding: .utf8)
            texts[configuration] = text
            do {
                owners[configuration] = try text.map { try OverlayFile.owners(in: $0, path: url.path) } ?? [:]
            } catch {
                result.failed = true
                result.messages.append("error: \(error); nothing written")
                return result
            }
        }
        let original = texts
        var applied: [String] = []
        var skipped: [String] = []
        var delivered: [String] = []
        for index in result.plan.steps.indices where result.plan.steps[index].fixKind == .overlay {
            let step = result.plan.steps[index]
            if let reason = skipReason(step, forceUnverified: forceUnverified) {
                if step.state != .applied { result.plan.steps[index].state = .skipped }
                result.plan.steps[index].stateReason = reason
                result.messages.append("skipped \(step.ruleId): \(reason)")
                skipped.append(step.ruleId)
                continue
            }
            if deliversThroughCLI(step) {
                let commands = buildOverlayCommands(plan, step: step)
                result.plan.steps[index].state = .appliedCLI
                result.plan.steps[index].stateReason = "nothing written (a cli step: the hook does not reach it); deliver "
                    + "with " + commands.joined(separator: "; ")
                result.messages.append("\(step.ruleId) is a cli step, recorded applied-cli (nothing written): deliver it "
                    + "with " + commands.joined(separator: "; "))
                delivered.append(step.ruleId)
                continue
            }
            let byConfiguration = Dictionary(grouping: step.overlay, by: \.configuration)
            let present = byConfiguration.keys.allSatisfy { configuration in
                owners[configuration]?.values.contains {
                    $0.planId == plan.id && $0.ruleId == step.ruleId && !$0.temporary
                } == true
            }
            if present {
                result.plan.steps[index].state = .applied
                result.plan.steps[index].stateReason = nil
                result.messages.append("\(step.ruleId) is already in the overlay (plan \(plan.id))")
                continue
            }
            let conflict = step.overlay.lazy.compactMap { line -> String? in
                guard let owner = owners[line.configuration]?[line.key] else { return nil }
                if owner.temporary {
                    return "key \(line.key) is set by a temporary block an interrupted verify of plan \(owner.planId) "
                        + "(\(owner.ruleId)) left in overlay-\(line.configuration).xcconfig: xcblame fix --revert "
                        + "\(owner.planId) removes it"
                }
                return "key \(line.key) is set by plan \(owner.planId) (\(owner.ruleId)) in overlay-\(line.configuration)"
                    + ".xcconfig: xcblame fix --revert \(owner.planId) first"
            }.first
            if let conflict {
                result.plan.steps[index].state = .skipped
                result.plan.steps[index].stateReason = conflict
                result.messages.append("skipped \(step.ruleId): \(conflict)")
                skipped.append(step.ruleId)
                continue
            }
            for (configuration, lines) in byConfiguration.sorted(by: { $0.key < $1.key }) {
                texts[configuration] = OverlayFile.appending(planId: plan.id, ruleId: step.ruleId, lines: lines.map(\.line),
                                                             to: texts[configuration] ?? nil, configuration: configuration)
                for line in lines { owners[configuration, default: [:]][line.key] = (plan.id, step.ruleId, false) }
            }
            result.plan.steps[index].state = .applied
            result.plan.steps[index].stateReason = nil
            applied.append(step.ruleId)
        }
        let changed = texts.filter { original[$0.key] != $0.value }.keys.sorted()
        do {
            for configuration in changed {
                let url = OverlayFile.url(xcblameDir: xcblameDir, configuration: configuration)
                try FileManager.default.createDirectory(at: xcblameDir, withIntermediateDirectories: true)
                try Data(((texts[configuration] ?? nil) ?? "").utf8).write(to: url, options: .atomic)
                result.files.append(FixPaths.display(url, root: root))
            }
        } catch {
            restore(original, keys: changed, xcblameDir: xcblameDir)
            result.plan = plan
            result.failed = true
            result.files = []
            result.messages.append("error: writing the overlay failed (\(error)); every overlay file was restored")
            return result
        }
        if applied.isEmpty {
            if delivered.isEmpty {
                let pending = plan.steps.filter {
                    $0.fixKind == .overlay && ($0.verify.status == .unverified || $0.verify.status == .indicative)
                        && skipped.contains($0.ruleId)
                }.map { FixPlanner.verifyCommand($0) }
                result.messages.append("nothing written" + (skipped.isEmpty ? "" : ": every overlay step was skipped (reasons above)")
                    + (pending.isEmpty ? "" : "; verify first: " + pending.joined(separator: "; ")))
            }
        } else {
            result.messages.append("wrote \(applied.joined(separator: ", ")) into " + result.files.joined(separator: ", "))
            result.plan.events.append(.init(at: now, action: "apply", ruleIds: applied, files: result.files, defaultsKeys: []))
            let written = Set(plan.steps.filter { applied.contains($0.ruleId) }.flatMap { $0.overlay.map(\.configuration) })
            for state in plan.hook where written.contains(state.configuration) && state.status != "installed" {
                result.messages.append("warning: the hook is not installed for \(state.configuration)"
                    + (state.reason.map { " (\($0))" } ?? "") + ": Xcode and xcodebuild do not read overlay-"
                    + "\(state.configuration).xcconfig until xcblame fix --install-hook (or deliver it with xcblame build "
                    + "--overlay \(plan.id))")
            }
        }
        return result
    }

    /// Rule 3: the step reaches the build only through the command-line wrapper: planned `cli` (fully hook-shadowed,
    /// CI, no hook possible), or kept through `cli` while its hook and cli scope differ.
    static func deliversThroughCLI(_ step: FixPlanDocument.Step) -> Bool {
        step.mechanism == .cli || (step.verify.status == .kept && step.verify.mechanism == .cli && !sameScope(step))
    }

    /// `xcblame build --overlay <plan-id> [--overlay-unverified] -- -scheme <S> -configuration <C> build`, one per
    /// configuration of the step's lines (the scheme of the plan's analysis when known).
    public static func buildOverlayCommands(_ plan: FixPlanDocument, step: FixPlanDocument.Step) -> [String] {
        let unverified = step.verify.status == .unverified ? " --overlay-unverified" : ""
        let scheme = plan.project.scheme.map { "-scheme \(FixPlanner.shellWord($0)) " } ?? "-scheme <scheme> "
        return Set(step.overlay.map(\.configuration)).sorted().map {
            "xcblame build --overlay \(plan.id)\(unverified) -- \(scheme)-configuration \(FixPlanner.shellWord($0)) build"
        }
    }

    /// Why `--apply` leaves a step out, nil when it may be written (or, for a cli step, recorded `applied-cli`).
    static func skipReason(_ step: FixPlanDocument.Step, forceUnverified: Bool) -> String? {
        let verify = FixPlanner.verifyCommand(step)
        switch step.verify.status {
        case .kept:
            return nil
        case .reverted:
            let label = FixVerifyWords.stateLabel(step.verify)
            let date = step.verify.verifiedAt.map { " on " + FixApply.day($0) } ?? ""
            return "\(step.ruleId) was \(label)\(date): not applied; re-verify with \(verify)"
        case .indicative:
            return "verify measured too few samples (indicative): \(verify) --runs 5"
        case .unverified:
            if step.verifyOnly { return "+V rule: written only after verify keeps it (\(verify))" }
            return forceUnverified ? nil : "not verified yet: \(verify), or pass --force-unverified"
        }
    }

    /// `yyyy-MM-dd` in the local time zone.
    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// Rule 3: the reached `(target, configuration, key, after)` sets of the hook and cli rows are identical.
    static func sameScope(_ step: FixPlanDocument.Step) -> Bool {
        func set(_ mechanism: FixPlanDocument.Mechanism) -> Set<String>? {
            let rows = step.scope.filter { $0.mechanism == mechanism && $0.reached }
            guard !rows.contains(where: { $0.after == nil }) else { return nil }
            return Set(rows.map { "\($0.target)\u{1}\($0.configuration)\u{1}\($0.key)\u{1}\(FixPlanner.normalized($0.after ?? ""))" })
        }
        guard let hook = set(.hook), let cli = set(.cli), !hook.isEmpty else { return false }
        return hook == cli
    }

    private static func restore(_ texts: [String: String?], keys: [String], xcblameDir: URL) {
        for configuration in keys {
            let url = OverlayFile.url(xcblameDir: xcblameDir, configuration: configuration)
            if let text = texts[configuration] ?? nil {
                try? Data(text.utf8).write(to: url, options: .atomic)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Defaults

    /// Writes the `defaults` steps (the flag is the consent; `+V` ones need `kept`), prior values saved first.
    public static func applyDefaults(_ plan: FixPlanDocument, xcblameDir: URL, runner: DefaultsRunning, now: Date) -> Result {
        var result = Result(plan: plan, messages: [])
        var changes: [FixPlanDocument.DefaultsChange] = []
        var rules: [String] = []
        for index in plan.steps.indices where plan.steps[index].mechanism == .defaults {
            let step = plan.steps[index]
            if step.verifyOnly, step.verify.status != .kept {
                result.plan.steps[index].state = .skipped
                result.plan.steps[index].stateReason = "+V rule: written only after verify keeps it"
                result.messages.append("skipped \(step.ruleId): +V rule, verify has not kept it")
                continue
            }
            changes += step.defaults
            rules.append(step.ruleId)
        }
        guard !changes.isEmpty else {
            result.messages.append("nothing to write: the plan has no defaults step")
            return result
        }
        do {
            let keys = try DefaultsApplier.apply(changes, planId: plan.id, xcblameDir: xcblameDir, runner: runner)
            for index in result.plan.steps.indices where rules.contains(result.plan.steps[index].ruleId) {
                result.plan.steps[index].state = .applied
                result.plan.steps[index].stateReason = nil
            }
            result.messages.append("wrote defaults " + keys.joined(separator: ", ") + " (prior values in backup/defaults.json)")
            result.plan.events.append(.init(at: now, action: "applyDefaults", ruleIds: rules, files: [], defaultsKeys: keys))
        } catch {
            result.failed = true
            result.messages.append("error: \(error)")
        }
        return result
    }

    // MARK: - Revert

    /// The newest stored plan with a step still `applied` (an overlay block or a defaults write). Per step, not per
    /// event: an auto-revert of one rule leaves the plan's other applied steps revertable (fix round 1, minor 1).
    public static func newestApplied(xcblameDir: URL) -> FixPlanDocument? {
        FixPlanStore.list(xcblameDir: xcblameDir).first { plan in
            plan.steps.contains { $0.state == .applied || $0.state == .appliedCLI }
        }
    }

    /// Removes `planId`'s blocks from every overlay file (deleting a file apply created) and restores the defaults
    /// it wrote. Works without the stored plan (a teammate's checkout): the blocks carry the id. Hand-edited overlay
    /// files make it refuse before anything is written.
    public static func revert(planId: String, plan: FixPlanDocument?, root: URL, xcblameDir: URL, runner: DefaultsRunning,
                              now: Date) -> Result {
        var result = Result(plan: plan ?? placeholder(planId), messages: [])
        var changes: [(url: URL, before: String, after: String?, rules: [String], temporary: [String])] = []
        for url in OverlayFile.all(xcblameDir: xcblameDir) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            do {
                let removed = try OverlayFile.removing(planId: planId, from: text,
                                                       configuration: OverlayFile.configuration(of: url), path: url.path)
                if !removed.removed.isEmpty {
                    changes.append((url, text, removed.text, removed.removed.filter { !$0.temporary }.map(\.ruleId),
                                    removed.removed.filter(\.temporary).map(\.ruleId)))
                }
            } catch {
                result.failed = true
                result.messages.append("error: \(error); nothing reverted")
                return result
            }
        }
        var written: [(url: URL, before: String)] = []
        do {
            for change in changes {
                if let after = change.after {
                    try Data(after.utf8).write(to: change.url, options: .atomic)
                } else {
                    try FileManager.default.removeItem(at: change.url)
                }
                written.append((change.url, change.before))
                result.files.append(FixPaths.display(change.url, root: root))
            }
        } catch {
            for item in written { try? Data(item.before.utf8).write(to: item.url, options: .atomic) }
            result.failed = true
            result.files = []
            result.messages.append("error: reverting the overlay failed (\(error)); every overlay file was restored")
            return result
        }
        var keys: [String] = []
        do {
            keys = try DefaultsApplier.revert(planId: planId, xcblameDir: xcblameDir, runner: runner)
        } catch {
            result.failed = true
            result.messages.append("error: restoring defaults failed (\(error)); backup/defaults.json keeps the prior values")
        }
        let rules = changes.flatMap(\.rules)
        let temporary = changes.flatMap(\.temporary)
        if !temporary.isEmpty {
            result.messages.append("removed the temporary verify block(s) of \(temporary.joined(separator: ", ")) an "
                + "interrupted verify of plan \(planId) left")
        }
        // `applied-cli` steps have no block: reverting the plan stops `build --overlay` delivering them (fix round 2,
        // finding 4).
        let cliRules = result.plan.steps.filter { $0.state == .appliedCLI }.map(\.ruleId)
        if rules.isEmpty, keys.isEmpty, cliRules.isEmpty {
            if temporary.isEmpty { result.messages.append("nothing to revert for plan \(planId)") }
            return result
        }
        if !rules.isEmpty { result.messages.append("removed \(rules.joined(separator: ", ")) of plan \(planId) from "
            + result.files.joined(separator: ", ")) }
        if !keys.isEmpty { result.messages.append("restored defaults " + keys.joined(separator: ", ")) }
        if !cliRules.isEmpty {
            result.messages.append("\(cliRules.joined(separator: ", ")) of plan \(planId) reverted (applied-cli: nothing "
                + "was written; xcblame build --overlay no longer delivers them)")
        }
        let defaultsRules = result.plan.steps.filter { $0.mechanism == .defaults && $0.state == .applied }.map(\.ruleId)
        for index in result.plan.steps.indices
            where rules.contains(result.plan.steps[index].ruleId) || cliRules.contains(result.plan.steps[index].ruleId)
                || (!keys.isEmpty && defaultsRules.contains(result.plan.steps[index].ruleId)) {
            result.plan.steps[index].state = .reverted
            result.plan.steps[index].stateReason = nil
        }
        result.plan.events.append(.init(at: now, action: "revert",
                                        ruleIds: rules + cliRules + (keys.isEmpty ? [] : defaultsRules),
                                        files: result.files, defaultsKeys: keys))
        return result
    }

    /// A stand-in when the plan is not stored here (only its overlay blocks are).
    static func placeholder(_ id: String) -> FixPlanDocument {
        FixPlanDocument(tool: ReportDocument.Tool(name: "xcblame", version: XcblameVersion.current, kindTable: KindTable.v1.version),
                        generatedAt: Date(timeIntervalSince1970: 0), id: id,
                        generatedFrom: .init(analysisId: nil, analysisPath: nil, analysisKind: nil, doctorConfigurations: [],
                                             settingsSource: "offline", rulesFilter: []),
                        project: .init(container: "", generator: nil, configurations: [], scheme: nil), steps: [])
    }
}
