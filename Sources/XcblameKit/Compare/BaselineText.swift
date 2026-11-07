import Foundation

extension Baseline {
    /// `xcblame baseline show`: what the file says, in words. `path` is only printed (the file's own location).
    public func textSummary(path: String? = nil) -> String {
        var lines = ["baseline" + (path.map { "  " + $0 } ?? "")]
        let formatter = ISO8601DateFormatter()
        let refs = source.refs.prefix(5).joined(separator: ", ") + (source.refs.count > 5 ? ", +\(source.refs.count - 5) more" : "")
        lines.append("  saved    \(formatter.string(from: savedAt)) by xcblame \(tool.version) from \(source.kind)"
            + (refs.isEmpty ? "" : " (\(refs))"))
        let key = [self.key.kind, self.key.scheme, self.key.configuration, self.key.destination].compactMap { $0 }
        lines.append("  build    " + (key.isEmpty ? "kind unknown" : key.joined(separator: " · "))
            + " · xcode " + (self.key.xcode ?? "unknown"))
        lines.append("  runs     \(runs)" + (runs < 3 ? " (fewer than 3: builds compared with it get the verdict indicative)" : ""))
        lines.append("  wall     " + stat(wall) + " (\(wallBasis == "processWall" ? "process wall" : "log span"))")
        lines.append("  busy     " + stat(busy))
        lines.append("  path     " + stat(criticalPath))
        if let machine { lines.append("  machine  " + machine) }
        if let git {
            let parts = [git.branch, git.commit.map { String($0.prefix(10)) }, git.dirty.map { $0 ? "dirty" : "clean" }]
            lines.append("  git      " + parts.compactMap { $0 }.joined(separator: " "))
        }
        if let tasks {
            lines.append("  tasks    \(tasks.total) executed tasks, \(tasks.ids.count) unique digests")
        } else {
            lines.append("  tasks    no digests (baseline save --with-tasks stores them)")
        }
        for note in notes { lines.append("  note     " + note) }
        return lines.joined(separator: "\n") + "\n"
    }

    private func stat(_ value: Stat) -> String {
        guard let median = value.median else { return "unknown" }
        var text = "median " + TextReporter.duration(median)
        if let mad = value.mad { text += ", MAD " + TextReporter.duration(mad) }
        return text
    }
}
