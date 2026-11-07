import Foundation

/// Reads and writes Xcode user defaults; tests inject a fake (never `defaults write` in tests).
public protocol DefaultsRunning: Sendable {
    func read(domain: String, key: String) -> Backups.Prior
    func write(domain: String, key: String, type: String, value: String) throws
    func delete(domain: String, key: String) throws
}

// v0.6 lane A (docs/SCHEMA-v0.6.md "Defaults"): `fix --apply-defaults` writes the `defaults` steps (v0.6: only
// `IDEBuildOperationMaxNumberOfConcurrentCompileTasks`), the prior state first going to `backup/defaults.json`;
// `--revert <plan>` restores it exactly (deleting a key that did not exist).
public enum DefaultsApplier {
    /// The only key v0.6 writes (ENV-002; probes-v0.6 Q8).
    public static let writableKeys: Set<String> = ["IDEBuildOperationMaxNumberOfConcurrentCompileTasks"]

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    /// Applies `changes` for `planId`. A key already backed up for this plan keeps its first prior value (re-applying
    /// is idempotent). Throws after restoring what this call wrote when a write fails.
    public static func apply(_ changes: [FixPlanDocument.DefaultsChange], planId: String, xcblameDir: URL,
                             runner: DefaultsRunning) throws -> [String] {
        var rows = Backups.defaults(xcblameDir: xcblameDir)
        var written: [(change: FixPlanDocument.DefaultsChange, prior: Backups.Prior)] = []
        for change in changes where writableKeys.contains(change.key) {
            let prior = runner.read(domain: change.domain, key: change.key)
            if !rows.contains(where: { $0.planId == planId && $0.domain == change.domain && $0.key == change.key }) {
                rows.append(Backups.Defaults(planId: planId, domain: change.domain, key: change.key, prior: prior))
                // The prior value is on disk before the first write.
                try Backups.saveDefaults(rows, xcblameDir: xcblameDir)
            }
            do {
                if let value = change.value {
                    try runner.write(domain: change.domain, key: change.key, type: change.type ?? "string", value: value)
                } else if prior.exists {
                    try runner.delete(domain: change.domain, key: change.key)
                }
                written.append((change, prior))
            } catch {
                for item in written.reversed() { try? restore(item.prior, domain: item.change.domain, key: item.change.key, runner: runner) }
                try? restore(prior, domain: change.domain, key: change.key, runner: runner)
                throw Failure(description: "defaults \(change.key) could not be written (\(error)); prior values restored")
            }
        }
        return written.map(\.change.key)
    }

    /// Restores every key backed up for `planId` and drops its rows; returns the keys restored.
    public static func revert(planId: String, xcblameDir: URL, runner: DefaultsRunning) throws -> [String] {
        var rows = Backups.defaults(xcblameDir: xcblameDir)
        let mine = rows.filter { $0.planId == planId }
        guard !mine.isEmpty else { return [] }
        for row in mine.reversed() {
            try restore(row.prior, domain: row.domain, key: row.key, runner: runner)
            rows.removeAll { $0 == row }
            try Backups.saveDefaults(rows, xcblameDir: xcblameDir)
        }
        return mine.map(\.key)
    }

    static func restore(_ prior: Backups.Prior, domain: String, key: String, runner: DefaultsRunning) throws {
        if prior.exists, let value = prior.value {
            try runner.write(domain: domain, key: key, type: prior.type ?? "string", value: value)
        } else if runner.read(domain: domain, key: key).exists {
            try runner.delete(domain: domain, key: key)
        }
    }
}

/// `/usr/bin/defaults` (`read-type`, `read`, `write -<type>`, `delete`).
public struct SystemDefaults: DefaultsRunning {
    public init() {}

    public func read(domain: String, key: String) -> Backups.Prior {
        guard let typeOut = runProcess(["defaults", "read-type", domain, key], timeout: 10), typeOut.succeeded else {
            return .absent
        }
        let words = typeOut.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        let type: String
        switch words.last.map(String.init) {
        case "integer": type = "int"
        case "boolean": type = "bool"
        case "float": type = "float"
        default: type = "string"
        }
        let value = runProcess(["defaults", "read", domain, key], timeout: 10)?.stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Backups.Prior(exists: true, type: type, value: value)
    }

    public func write(domain: String, key: String, type: String, value: String) throws {
        let output = runProcess(["defaults", "write", domain, key, "-" + type, value], timeout: 10)
        guard output?.succeeded == true else {
            throw DefaultsApplier.Failure(description: output?.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "defaults write did not run")
        }
    }

    public func delete(domain: String, key: String) throws {
        let output = runProcess(["defaults", "delete", domain, key], timeout: 10)
        guard output?.succeeded == true else {
            throw DefaultsApplier.Failure(description: output?.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "defaults delete did not run")
        }
    }
}
