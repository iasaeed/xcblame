import Foundation

/// Finds the build description that belongs to a log (DESIGN §5.11), in this order: `explicit`
/// (`--build-description`), the snapshot `snapshotsDir/<log uuid>/`, then the live DerivedData description when the
/// log sits under `<DerivedData>/Logs/Build/`: the one named by the log's signature, else the newest one whose command
/// keys cover ≥ 95 % of the log's planned keyed tasks. An explicit folder counts as a `snapshot` (it is a copy the
/// user points at, not the live DerivedData state).
public enum BuildDescriptionLocator {
    /// Share of the log's planned keyed tasks a description must cover to match without a signature.
    public static let coverageThreshold = 0.95
    /// Live descriptions inspected at most when matching by coverage (newest first).
    static let liveCandidateLimit = 10

    /// An `explicit` folder that does not load (no manifest, a partial snapshot) falls through to the snapshot and
    /// live lookups; the description found there carries a note saying so.
    public static func find(model: BuildModel, logURL: URL?, explicit: URL?, snapshotsDir: URL?) -> BuildDescription? {
        let logSignature = signature(of: model)
        guard let explicit else {
            return located(model: model, logURL: logURL, snapshotsDir: snapshotsDir, logSignature: logSignature)
        }
        do {
            var description = try BuildDescription.load(directory: explicit)
            description.basis = "snapshot"
            description.notes = ["read from --build-description"] + matchNotes(description, model: model,
                                                                                   logSignature: logSignature)
            return description
        } catch {
            var description = located(model: model, logURL: logURL, snapshotsDir: snapshotsDir,
                                      logSignature: logSignature)
            description?.notes.insert("explicit build description \(explicit.path) did not load (\(error)); "
                + "fell back to the snapshot or live description", at: 0)
            return description
        }
    }

    /// The snapshot, then the live DerivedData description. A snapshot whose signature differs from the log's gives
    /// way to the live description that carries the log's signature, when there is one.
    static func located(model: BuildModel, logURL: URL?, snapshotsDir: URL?, logSignature: String?)
        -> BuildDescription? {
        let xcbuildData = logURL.flatMap(liveDescriptionsDir(for:))
        if let snapshotsDir, let logURL, logURL.pathExtension == "xcactivitylog" {
            let dir = snapshotsDir.appendingPathComponent(logURL.deletingPathExtension().lastPathComponent)
            if var description = try? BuildDescription.load(directory: dir) {
                if let own = description.signature, let logSignature, own != logSignature, let xcbuildData,
                   var live = liveBySignature(xcbuildData, model: model, logSignature: logSignature) {
                    live.notes.insert("snapshot \(dir.lastPathComponent) skipped: its signature \(own.prefix(8)) "
                        + "differs from the log's \(logSignature.prefix(8))", at: 0)
                    return live
                }
                description.basis = "snapshot"
                description.notes = ["snapshot of this log's build"] + matchNotes(description, model: model,
                                                                                    logSignature: logSignature)
                return description
            }
        }
        guard let xcbuildData else { return nil }
        if let logSignature, let live = liveBySignature(xcbuildData, model: model, logSignature: logSignature) {
            return live
        }
        for dir in newestDescriptions(in: xcbuildData).prefix(liveCandidateLimit) {
            guard var description = try? BuildDescription.load(directory: dir),
                  let share = coverage(of: description, model: model).share, share >= coverageThreshold else { continue }
            description.basis = "live"
            description.notes = [String(format: "matched by key coverage (%.0f%% of planned keyed tasks)", share * 100)]
            return description
        }
        return nil
    }

    /// The live `<logSignature>.xcbuilddata`, when it loads.
    static func liveBySignature(_ xcbuildData: URL, model: BuildModel, logSignature: String) -> BuildDescription? {
        let dir = xcbuildData.appendingPathComponent(logSignature + ".xcbuilddata")
        guard var description = try? BuildDescription.load(directory: dir) else { return nil }
        description.basis = "live"
        description.notes = ["matched by the log's description signature"]
            + matchNotes(description, model: model, logSignature: logSignature)
        return description
    }

    /// The log's description signature: the `Build description signature: <hex>` line a build that creates the
    /// description logs, else the key of the `CreateBuildDescription` task (its signature slot holds the signature
    /// even when the description was reused, Xcode 26 corpus fixtures).
    public static func signature(of model: BuildModel) -> String? {
        guard let task = model.tasks.first(where: { $0.ruleName == "CreateBuildDescription" }) else { return nil }
        if let line = createdSignature(of: task) { return line }
        if let key = task.taskKey, BuildDescription.isHexSignature(key) { return key }
        return nil
    }

    /// The signature from the `Build description signature:` line, present only when this build created it.
    static func createdSignature(of task: BuildTask) -> String? {
        let marker = "Build description signature: "
        for text in [task.emittedOutput, task.commandDetails].compactMap({ $0 }) {
            guard let range = text.range(of: marker) else { continue }
            let hex = text[range.upperBound...].prefix { $0.isHexDigit }
            if BuildDescription.isHexSignature(String(hex)) { return String(hex) }
        }
        return nil
    }

    /// Dynamic tasks: requested by a planned command at run time, never manifest commands (DESIGN §5.6).
    static let dynamicRules: Set<String> = [
        "SwiftCompile", "SwiftEmitModule", "EmitSwiftModule", "SwiftDriver", "SwiftDriverJobDiscovery",
        "SwiftExplicitDependencyGeneratePcm", "SwiftExplicitDependencyCompileModuleFromInterface", "PrecompileModule",
    ]

    /// Tasks whose key should be a manifest command: keyed with the `0x00` signature prefix (when the reader kept
    /// it) and not a dynamic rule.
    static func isPlannedKeyed(_ task: BuildTask) -> Bool {
        guard task.taskKey != nil, !dynamicRules.contains(task.ruleName) else { return false }
        if let hex = task.slfOnly?.xcbuildSignatureHex { return hex.hasPrefix("00") }
        return true
    }

    /// Planned keyed tasks of the log and how many of them are commands of `description`.
    public static func coverage(of description: BuildDescription, model: BuildModel) -> (matched: Int, planned: Int,
                                                                                         share: Double?) {
        let keys = Set(description.commands.map(\.key))
        let planned = model.tasks.filter(isPlannedKeyed)
        let matched = planned.filter { keys.contains($0.taskKey ?? "") }.count
        return (matched, planned.count, planned.isEmpty ? nil : Double(matched) / Double(planned.count))
    }

    static func matchNotes(_ description: BuildDescription, model: BuildModel, logSignature: String?) -> [String] {
        var notes: [String] = []
        let cover = coverage(of: description, model: model)
        if let share = cover.share {
            notes.append(String(format: "%d of %d planned keyed tasks are commands of this description (%.0f%%)",
                                cover.matched, cover.planned, share * 100))
        }
        if let own = description.signature, let logSignature, own != logSignature {
            notes.append("description signature \(own.prefix(8)) differs from the log's \(logSignature.prefix(8))")
        }
        return notes
    }

    /// `<DerivedData>/Build/Intermediates.noindex/XCBuildData` for a log under `<DerivedData>/Logs/Build/`.
    static func liveDescriptionsDir(for logURL: URL) -> URL? {
        let path = logURL.standardizedFileURL.path
        guard let range = path.range(of: "/Logs/Build/") else { return nil }
        let derivedData = URL(fileURLWithPath: String(path[..<range.lowerBound]))
        let dir = derivedData.appendingPathComponent("Build/Intermediates.noindex/XCBuildData")
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue ? dir : nil
    }

    static func newestDescriptions(in dir: URL) -> [URL] {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]))
            ?? []
        let dated = urls.filter { $0.pathExtension == "xcbuilddata" }.map { url -> (URL, Date) in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            return (url, date ?? .distantPast)
        }
        return dated.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.path < $1.0.path }.map(\.0)
    }
}
