import Foundation

// v0.6 fix round 1 (review gap 1; DESIGN §3.2, §7.5 "Command-line delivery"): `xcblame build --overlay [<plan-id>]`.
// The plan's kept overlay lines (with `--overlay-unverified` also its unverified non-+V ones; never reverted,
// indicative or `fix --revert`ed steps) go into `<xcblame-dir>/tmp/build-overlay-<C>.xcconfig`, which the wrapper
// `-xcconfig` includes after the user's `-xcconfig` and `XCODE_XCCONFIG_FILE` file; the oracle run with the wrapper
// before the build must show every key won.
public enum OverlayDelivery {
    /// What one `build --overlay` delivers for one configuration.
    public struct Selection: Sendable, Equatable {
        public var planId: String
        public var configuration: String
        public var ruleIds: [String]
        public var lines: [FixPlanDocument.OverlayLine]
        /// Overlay steps left out, one `RULE: why` each.
        public var left: [String]
        /// Per rule, the targets its cli scope rows name (the oracle check's targets).
        public var targets: [String: [String]]
    }

    /// `<xcblame-dir>/tmp/build-overlay-<Configuration>.xcconfig`.
    public static func url(xcblameDir: URL, configuration: String) -> URL {
        xcblameDir.appendingPathComponent("tmp/build-overlay-\(configuration).xcconfig")
    }

    /// Why `step` is not delivered, nil when it is: an `overlay` step whose verdict is `kept` (or, with `unverified`,
    /// `unverified` and not `+V`), not reverted by `fix --revert`.
    public static func leftOut(_ step: FixPlanDocument.Step, unverified: Bool) -> String? {
        guard step.fixKind == .overlay else { return "not an overlay step" }
        if step.state == .reverted { return "reverted with xcblame fix --revert" }
        switch step.verify.status {
        case .kept:
            // SCHEMA rule 3, the other way round (fix round 2, finding 5): kept through the hook, delivered through cli
            // only when cli reaches the same (target, configuration, key) rows the hook reached. Values are not compared
            // here: the plan's cli `after` comes from the generated-scheme oracle (it reports ONLY_ACTIVE_ARCH = NO
            // whatever the project says); `build --overlay`'s oracle with the build's own arguments checks them (fix
            // round 3).
            if step.verify.mechanism == .hook, !sameTargets(step) {
                return "kept through hook, but cli reaches other targets than the hook rows verify measured: "
                    + "xcblame verify --rules \(step.ruleId) --mechanism cli"
            }
            return nil
        case .unverified:
            if step.verifyOnly { return "+V rule: delivered only after verify keeps it" }
            return unverified ? nil : "not verified yet (--overlay-unverified delivers it)"
        case .reverted: return "verify reverted it (\(FixVerifyWords.stateLabel(step.verify)))"
        case .indicative: return "verify measured too few samples (indicative)"
        }
    }

    /// `id` (or a unique prefix) from the store, else the newest stored plan of `container` (any when nil) with a
    /// step to deliver.
    public static func plan(id: String?, container: String?, unverified: Bool, xcblameDir: URL) throws -> FixPlanDocument? {
        if let id { return try FixPlanStore.load(id: id, xcblameDir: xcblameDir) }
        let wanted = container.map(normalized)
        return FixPlanStore.list(xcblameDir: xcblameDir).first { plan in
            (wanted == nil || normalized(plan.project.container) == wanted)
                && plan.steps.contains { leftOut($0, unverified: unverified) == nil }
        }
    }

    /// The hook's reached `(target, configuration, key)` rows equal every cli row's (cli reaches by construction,
    /// Decision 2); false without hook rows.
    static func sameTargets(_ step: FixPlanDocument.Step) -> Bool {
        func rows(_ mechanism: FixPlanDocument.Mechanism, reachedOnly: Bool) -> Set<String> {
            Set(step.scope.filter { $0.mechanism == mechanism && (!reachedOnly || $0.reached) }
                .map { "\($0.target)\u{1}\($0.configuration)\u{1}\($0.key)" })
        }
        let hook = rows(.hook, reachedOnly: true)
        return !hook.isEmpty && hook == rows(.cli, reachedOnly: false)
    }

    /// Why each overlay step of the newest plan of `container` is not delivered (for the "nothing to deliver" error).
    public static func reasons(container: String, unverified: Bool, xcblameDir: URL) -> (planId: String, left: [String])? {
        let wanted = normalized(container)
        guard let plan = FixPlanStore.list(xcblameDir: xcblameDir).first(where: { normalized($0.project.container) == wanted })
        else { return nil }
        return (plan.id, plan.steps.compactMap { step in leftOut(step, unverified: unverified).map { "\(step.ruleId): \($0)" } })
    }

    /// `/var/…` and `/private/var/…` are one folder.
    static func normalized(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    public static func select(_ plan: FixPlanDocument, configuration: String, unverified: Bool) -> Selection {
        var selection = Selection(planId: plan.id, configuration: configuration, ruleIds: [], lines: [], left: [], targets: [:])
        var keys = Set<String>()
        for step in plan.steps where step.fixKind == .overlay {
            if let why = leftOut(step, unverified: unverified) {
                selection.left.append("\(step.ruleId): \(why)")
                continue
            }
            let lines = step.overlay.filter { $0.configuration == configuration && !keys.contains($0.key + ($0.condition ?? "")) }
            guard !lines.isEmpty else { continue }
            for line in lines { keys.insert(line.key + (line.condition ?? "")) }
            selection.ruleIds.append(step.ruleId)
            selection.lines += lines
            selection.targets[step.ruleId] = Array(Set(step.scope.filter { $0.mechanism == .cli && $0.configuration == configuration }
                .map(\.target))).sorted()
        }
        return selection
    }

    /// The overlay file the wrapper includes: a comment naming the plan, then the lines as the plan writes them.
    public static func text(_ selection: Selection) -> String {
        "// Written by xcblame build --overlay \(selection.planId) for configuration \(selection.configuration) "
            + "(rules \(selection.ruleIds.joined(separator: ", "))); safe to delete.\n"
            + selection.lines.map { $0.line + "\n" }.joined()
    }

    /// `<target>: <KEY> is <effective>, not <written>` for every unconditioned line whose value did not win on a
    /// target the oracle lists (targets it does not list, e.g. package targets, are not judged).
    public static func misses(_ selection: Selection, after: EffectiveSettings, plan: FixPlanDocument) -> [String] {
        var out: [String] = []
        for line in selection.lines where line.condition == nil {
            let rule = plan.steps.first { $0.overlay.contains(line) }?.ruleId
            let named = rule.flatMap { selection.targets[$0] } ?? []
            let targets = named.isEmpty ? after.targets.keys.sorted() : named
            for target in targets {
                guard let effective = after.targets[target]?[line.key] else { continue }
                if !FixPlanner.matches(effective: effective, written: line.value) {
                    out.append("\(target): \(line.key) is \(effective.isEmpty ? "empty" : effective), not \(line.value)")
                }
            }
        }
        return out
    }

    /// `KEY=VALUE` build arguments naming an overlay key (they lose to the `-xcconfig` wrapper, probes Q1).
    public static func overridden(_ selection: Selection, arguments: [String]) -> [String] {
        let keys = Set(selection.lines.map(\.key))
        return arguments.filter { argument in
            guard let eq = argument.firstIndex(of: "="), !argument.hasPrefix("-") else { return false }
            var key = String(argument[..<eq])
            if let bracket = key.firstIndex(of: "[") { key = String(key[..<bracket]) }
            return keys.contains(key)
        }
    }
}
