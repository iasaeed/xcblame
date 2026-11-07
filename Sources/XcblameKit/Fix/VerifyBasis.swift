import CryptoKit
import Foundation

// v0.6 fix round 1 (review gap 2): what a verify verdict was measured against. `verify` records it with each verdict
// (`VerifyState.basis`, `UnitResult.basis`); `FixPlanner.carryOver` reuses a verdict only when the new plan's step
// gives the same value, else the step stays `unverified` with the note "project changed since verify".
public enum VerifyBasis {
    /// 16 hex of SHA-256 over the contents of the project's settings inputs (`SettingsCache.inputs`: project files,
    /// xcconfigs and their includes, schemes, manifests, lockfiles) in path order. Files inside `xcblameDir` (the
    /// overlay) are left out and the two xcblame hook lines are dropped, so `fix --apply` and `--install-hook` do not
    /// change it; a missing file counts as missing.
    public static func projectDigest(_ model: ProjectModel, xcblameDir: URL) -> String {
        let state = FixPaths.canonical(xcblameDir).path + "/"
        var text = ""
        // Sorted: the inputs come from dictionaries, whose order differs between two loads of one project.
        let paths = Set(SettingsCache.inputs(project: model).map { FixPaths.canonical($0).path }).sorted()
        for path in paths where !path.hasPrefix(state) {
            let url = URL(fileURLWithPath: path)
            text += path + "\n"
            guard let data = FileManager.default.contents(atPath: url.path) else {
                text += "missing\n"
                continue
            }
            var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            for marker in [HookInstaller.marker, HookInstaller.legacyMarker] {
                while let index = lines.firstIndex(of: marker) {
                    lines.remove(at: index)
                    if index < lines.count, lines[index].hasPrefix("#include? ") { lines.remove(at: index) }
                }
            }
            // The newline `--install-hook` adds to an unterminated last line (and the legacy hook's blank line) are
            // not a change either (fix round 2, finding 6): trailing empty lines are dropped.
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
            text += hex(Data(lines.joined(separator: "\n").utf8)) + "\n"
        }
        return String(hex(Data(text.utf8)).prefix(16))
    }

    /// The project digest of `container` (empty when the project cannot be read: then only another unreadable state
    /// matches).
    public static func projectDigest(container: String, xcblameDir: URL) -> String {
        guard let model = try? ProjectModel.load(container: URL(fileURLWithPath: container), scheme: nil) else { return "" }
        return projectDigest(model, xcblameDir: xcblameDir)
    }

    /// 16 hex over the step's rule id, overlay assignments, the container, its planned verify kind and mechanism, its
    /// scope rows (target, configuration, key, mechanism, reached) and `projectDigest`.
    public static func value(step: FixPlanDocument.Step, container: String, projectDigest: String) -> String {
        var text = [step.ruleId, container, step.verifyKind, step.mechanism.rawValue, projectDigest].joined(separator: "\n")
        for line in step.overlay { text += "\n\(line.configuration)|\(line.key)\(line.condition ?? "") = \(line.value)" }
        for row in step.scope {
            text += "\n\(row.target)|\(row.configuration)|\(row.key)|\(row.mechanism.rawValue)|\(row.reached)"
        }
        return String(hex(Data(text.utf8)).prefix(16))
    }

    /// One value for a verify unit: its steps' values in rule order (nil when a rule has no step).
    public static func combined(ruleIds: [String], plan: FixPlanDocument, projectDigest: String) -> String? {
        var parts: [String] = []
        for rule in ruleIds {
            guard let step = plan.steps.first(where: { $0.ruleId == rule }) else { return nil }
            parts.append(value(step: step, container: plan.project.container, projectDigest: projectDigest))
        }
        return String(hex(Data(parts.joined(separator: "\n").utf8)).prefix(16))
    }

    private static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
