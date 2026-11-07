import Foundation

// v0.6 lane B (docs/SCHEMA-v0.6.md "`xcblame verify`", "Mechanisms in verify"): which plan steps are measured, as which
// units, with which kind and mechanism, and the xcodebuild arguments both arms share.

/// One measured unit: a rule (`--one-by-one`) or the batch of every selected rule.
public struct VerifyUnit: Sendable, Equatable {
    public var steps: [FixPlanDocument.Step]
    public var mechanism: FixPlanDocument.Mechanism
    public var kind: VerifyDocument.Kind
    /// Arm B's DerivedData label: `B-<RULE>` or `B-batch`.
    public var label: String

    public var ruleIds: [String] { steps.map(\.ruleId) }
}

public enum VerifySelection {
    /// The units of `plan` for `rules`, `kind`, `mechanism` and `oneByOne`, with a note per selected step left out.
    /// Usage errors (exit 2): a rule that is not a step of the plan, nothing to verify, a batch whose steps differ in
    /// kind or mechanism.
    public static func units(plan: FixPlanDocument, rules: [String]?, kind: VerifyDocument.Kind?,
                             mechanism: FixPlanDocument.Mechanism?, oneByOne: Bool) throws -> (units: [VerifyUnit], notes: [String]) {
        var notes: [String] = []
        var candidates = plan.steps
        if let rules {
            let missing = rules.filter { id in !plan.steps.contains { $0.ruleId == id } }
            if !missing.isEmpty {
                throw XcblameError.usage("plan \(plan.id) has no step for \(missing.joined(separator: ", ")) (xcblame fix "
                    + "--rules \(rules.joined(separator: ",")) makes one)")
            }
            candidates = plan.steps.filter { rules.contains($0.ruleId) }
        }
        var chosen: [(step: FixPlanDocument.Step, kind: VerifyDocument.Kind, mechanism: FixPlanDocument.Mechanism)] = []
        for step in candidates {
            guard !step.overlay.isEmpty else {
                if rules != nil {
                    notes.append("\(step.ruleId): no overlay lines (fix kind \(step.fixKind.rawValue), mechanism "
                        + "\(step.mechanism.rawValue)); v0.6 verifies overlay steps only")
                }
                continue
            }
            let delivered = mechanism ?? step.mechanism
            guard delivered == .hook || delivered == .cli else {
                notes.append("\(step.ruleId): planned mechanism \(step.mechanism.rawValue) is not verified in v0.6 "
                    + "(xcblame verify --mechanism cli measures its overlay lines on the command line)")
                continue
            }
            chosen.append((step, kind ?? VerifyDocument.Kind(rawValue: step.verifyKind) ?? .clean, delivered))
        }
        guard !chosen.isEmpty else {
            throw XcblameError.usage("nothing to verify: plan \(plan.id) has no step with overlay lines"
                + (rules.map { " among --rules \($0.joined(separator: ","))" } ?? "") + " that verify can deliver")
        }
        if oneByOne {
            return (chosen.map { VerifyUnit(steps: [$0.step], mechanism: $0.mechanism, kind: $0.kind, label: "B-\($0.step.ruleId)") },
                    notes)
        }
        let kinds = Set(chosen.map(\.kind))
        if kinds.count > 1 {
            throw XcblameError.usage("the selected steps are verified with different kinds ("
                + chosen.map { "\($0.step.ruleId) \($0.kind.rawValue)" }.joined(separator: ", ") + "): give --kind or --one-by-one")
        }
        if Set(chosen.map(\.mechanism)).count > 1 {
            throw XcblameError.usage("the selected steps use different mechanisms ("
                + chosen.map { "\($0.step.ruleId) \($0.mechanism.rawValue)" }.joined(separator: ", ")
                + "): give --mechanism or --one-by-one")
        }
        return ([VerifyUnit(steps: chosen.map(\.step), mechanism: chosen[0].mechanism, kind: chosen[0].kind, label: "B-batch")],
                notes)
    }

    /// The plan to verify: `id` (a plan id or unique prefix), else the newest stored plan with a step for every one of
    /// `rules` (any plan when nil), else nil (the caller makes one through `FixPlanning`).
    public static func storedPlan(id: String?, rules: [String]?, xcblameDir: URL) throws -> FixPlanDocument? {
        if let id { return try FixPlanStore.load(id: id, xcblameDir: xcblameDir) }
        return FixPlanStore.list(xcblameDir: xcblameDir).first { plan in
            (rules ?? []).allSatisfy { id in plan.steps.contains { $0.ruleId == id } }
                && plan.steps.contains { !$0.overlay.isEmpty }
        }
    }
}

/// The xcodebuild arguments of both arms (docs/SCHEMA-v0.6.md "Mechanisms in verify", last bullet).
public enum VerifyArguments {
    public struct Resolved: Sendable, Equatable {
        public var arguments: [String]
        public var scheme: String?
        public var configuration: String?
        public var notes: [String]
    }

    /// `given` (after `--`) when not empty, else `-workspace|-project <container> -scheme <s> -configuration <c>
    /// -destination <d> build` from the plan's analysis (a history entry in `historyDirectory`, or the report JSON of
    /// `fix --from`); a missing part is a usage error naming it. `-derivedDataPath` is refused: verify gives each arm
    /// its own.
    public static func resolve(given: [String], plan: FixPlanDocument, historyDirectory: URL) throws -> Resolved {
        if given.contains("-derivedDataPath") {
            throw XcblameError.usage("verify builds each arm in its own DerivedData under the cache folder; remove "
                + "-derivedDataPath from the xcodebuild arguments")
        }
        if !given.isEmpty {
            return Resolved(arguments: given, scheme: XcodebuildRunner.value(of: "-scheme", in: given),
                            configuration: XcodebuildRunner.value(of: "-configuration", in: given), notes: [])
        }
        var build: ReportDocument.Build?
        var source = "the plan has no analysis (fix ran without history)"
        if let id = plan.generatedFrom.analysisId {
            do {
                build = try History.show(id: id, directory: historyDirectory).document.build
                source = "history entry \(id)"
            } catch {
                source = "history entry \(id) is not readable (\(error))"
            }
        } else if let path = plan.generatedFrom.analysisPath {
            do {
                build = try JSONReporter.decoder().decode(ReportDocument.self, from: Data(contentsOf: URL(fileURLWithPath: path))).build
                source = path
            } catch {
                source = "\(path) is not readable (\(error))"
            }
        }
        let scheme = build?.scheme ?? plan.project.scheme
        let configuration = build?.configuration
        let destination = build?.destination.flatMap(destinationSpecifier(of:))
        let missing = [("scheme", scheme), ("configuration", configuration), ("destination", destination)]
            .filter { $0.1 == nil }.map(\.0)
        guard missing.isEmpty, let scheme, let configuration, let destination else {
            throw XcblameError.usage("verify needs the \(missing.joined(separator: ", ")) to build, and \(source) has none: "
                + "pass the xcodebuild arguments after -- (xcblame verify … -- -project … -scheme … -configuration … "
                + "-destination …)")
        }
        let container = plan.project.container
        let flag = container.hasSuffix(".xcworkspace") ? "-workspace" : "-project"
        return Resolved(arguments: [flag, container, "-scheme", scheme, "-configuration", configuration,
                                    "-destination", destination, "build"],
                        scheme: scheme, configuration: configuration,
                        notes: ["xcodebuild arguments from \(source) (scheme, configuration and destination)"])
    }

    /// An `-destination` specifier for a normalized destination (`BuildContext.humanDestination`): `macOS arm64` is
    /// `platform=macOS,arch=arm64`, `iOS Simulator` is `generic/platform=iOS Simulator`, `iOS` is `generic/platform=iOS`,
    /// `Mac Catalyst` is `platform=macOS,variant=Mac Catalyst`.
    public static func destinationSpecifier(of destination: String) -> String? {
        let (platform, arch) = BuildContext.parts(ofDestination: destination)
        guard !platform.isEmpty else { return nil }
        switch platform {
        case "macOS":
            return "platform=macOS" + (arch.map { ",arch=\($0)" } ?? "")
        case "Mac Catalyst", "Designed for iPad":
            return "platform=macOS,variant=\(platform)" + (arch.map { ",arch=\($0)" } ?? "")
        default:
            return "generic/platform=\(platform)"
        }
    }
}
