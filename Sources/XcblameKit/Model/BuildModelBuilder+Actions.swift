import Foundation

// MARK: - Actions in one xcresult log

extension BuildModelBuilder {
    /// Kinds that do not make a build: a log or action holding only these is a clean action or a planning stub.
    public static let nonBuildKinds: Set<TaskKind> = [.planning, .clean, .gate]

    /// Rule names that only a build plans: an action holding none of them never described a build.
    static let buildDescriptionRules: Set<String> = ["CreateBuildDescription", "ComputeTargetDependencyGraph"]

    /// An action left out of the model, with its own model (its tasks and span) for the note and for tests.
    struct ExcludedAction {
        var log: RawLog
        var model: BuildModel

        var note: String {
            let seconds = String(format: "%.2f", model.sessionSpan)
            return "clean action (\(model.tasks.count) tasks, \(seconds) s) excluded, same as a separate SLF log; "
                + "identified by its tasks (clean evidence, no build description), the xcresult log has no action type"
        }
    }

    /// True for a clean action: at least one task, only non-build kinds, and clean evidence: a `clean`-kind task, a
    /// `Clean...` rule name, or (the shape Xcode 26 and 27.1 write, with no clean-kind task at all) no build-description
    /// task, which every build action has, even an up-to-date one (all SLF fixtures: clean logs hold exactly
    /// CreateBuildRequest, SendProjectDescription, CreateBuildOperation).
    static func isCleanAction(_ model: BuildModel) -> Bool {
        guard !model.tasks.isEmpty, model.tasks.allSatisfy({ nonBuildKinds.contains($0.kind) }) else { return false }
        let explicitClean = model.tasks.contains { $0.kind == .clean || $0.ruleName.hasPrefix("Clean") }
        return explicitClean || !model.tasks.contains { buildDescriptionRules.contains($0.ruleName) }
    }

    /// SLF writes one action per log file; the xcresult build log holds every action of the invocation (`clean build`
    /// gives two root children). The containers have the same `domainType` (`Xcode.IDEActivityLogDomainType.BuildLog`),
    /// the same keys and no action-type or command field, so there is NO structural signal on the container itself
    /// (checked on fixtures/logs/cli-xcode26/xcresult-buildlog.json.gz). Every container is classified by its tasks
    /// (`isCleanAction`, rule names only); clean actions are excluded, as separate SLF logs would be, as long as at
    /// least one action remains, and the window becomes the remaining actions' span. Titles are never read.
    static func splitActions(_ raw: RawLog, kindTable: KindTable) -> (build: RawLog, excluded: [ExcludedAction]) {
        guard raw.layout == .xcresult else { return (raw, []) }
        let containers = raw.root.subsections.indices.filter { role(of: raw.root.subsections[$0].domainType) == .container }
        guard containers.count >= 2 else { return (raw, []) }
        var excluded: [(index: Int, action: ExcludedAction)] = []
        for index in containers {
            let action = RawLog(layout: .xcresult, root: raw.root.subsections[index])
            let model = buildModel(action, reader: .xcresult, kindTable: kindTable)
            if isCleanAction(model) { excluded.append((index, ExcludedAction(log: action, model: model))) }
        }
        guard !excluded.isEmpty, excluded.count < containers.count else { return (raw, []) }
        var rest = raw
        for item in excluded.reversed() { rest.root.subsections.remove(at: item.index) }
        let timed = rest.root.subsections.filter { role(of: $0.domainType) == .container && !$0.timingMissing }
        if let start = timed.map(\.start).min(), let end = timed.map(\.end).max() {
            (rest.root.start, rest.root.end, rest.root.timingMissing) = (start, end, false)
        }
        return (rest, excluded.map(\.action))
    }
}
