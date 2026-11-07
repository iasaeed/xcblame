import Foundation

// v0.5 lane C (docs/SCHEMA-v0.5.md "Text"): FIXED COSTS and MODULE GRAPH blocks.
extension TextReporter {
    /// Fixed-cost classes with seconds per build, per day and basis; the builds/day assumption labelled. Empty when
    /// `fixedCosts` is null.
    func fixedCostLines(_ doc: ReportDocument) -> [String] {
        guard let rows = doc.fixedCosts else { return [] }
        guard let first = rows.first else { return [bold("FIXED COSTS") + "  none"] }
        let builds = first.perDayAssumedBuilds
        let label: String
        switch first.perDayBasis {
        case "assumed": label = "(assumption: \(builds) builds/day)"
        case "config": label = "(\(builds) builds/day from config.json)"
        default: label = "(\(builds) builds per active day from history)"
        }
        let head = bold("FIXED COSTS") + "  work that runs on (nearly) every build · per day " + label
        let table = rows.map { row -> [String] in
            ["  " + row.class, dur(row.seconds), row.perDay.map(Self.duration) ?? "not run here", row.basis,
             row.tasksTotal > 0 ? plural(row.tasksTotal, "task") : ""]
        }
        var lines = [head] + Array(self.table(title: "", headers: ["s/build", "s/day", "basis", "tasks"], rows: table,
                                              leftAligned: [3]).dropFirst())
        let total = rows.compactMap(\.seconds).reduce(0, +)
        lines.append(dim("  Σ \(Self.duration(total)) per build across classes (what runs anyway, not a saving)"))
        return lines
    }

    /// Targets, depth, longest chain, blockers, umbrella candidates, variants summary. Empty when `moduleGraph` is
    /// null.
    func moduleGraphLines(_ doc: ReportDocument) -> [String] {
        guard let graph = doc.moduleGraph else { return [] }
        var head = bold("MODULE GRAPH") + "  \(plural(graph.targets, "target")) · source \(graph.source)"
        if let depth = graph.depth { head += " · depth \(depth)" }
        if !graph.cycles.isEmpty { head += " · " + warn(plural(graph.cycles.count, "cycle")) }
        var lines = [head]
        if !graph.longestChain.isEmpty {
            let chain = graph.longestChain.map { clip($0.target, limit: 28) + " " + Self.duration($0.seconds) }
                .joined(separator: " → ")
            lines.append("  longest chain  " + chain + (graph.longestChainSeconds.map { " = " + Self.duration($0) } ?? ""))
        }
        if !graph.blockers.isEmpty {
            lines.append("  blockers       " + graph.blockers.prefix(3).map {
                clip($0.target, limit: 28) + " gates " + Self.duration($0.gatedSeconds)
            }.joined(separator: " · "))
        }
        if !graph.fanIn.isEmpty {
            lines.append("  fan-in         " + graph.fanIn.prefix(3).map { clip($0.target, limit: 28) + " \($0.count)" }
                .joined(separator: " · "))
        }
        if !graph.umbrellaCandidates.isEmpty {
            lines.append("  umbrella       " + graph.umbrellaCandidates.prefix(5).map { clip($0, limit: 28) }
                .joined(separator: ", ") + " (fan-in > 50 % of targets)")
        }
        if !graph.macroPluginsPerModule.isEmpty {
            lines.append("  macro plugins  " + graph.macroPluginsPerModule.prefix(3).map {
                clip($0.module, limit: 28) + " \($0.plugins)"
            }.joined(separator: " · "))
        }
        if let variants = graph.variants {
            var text = "  variants       \(variants.modules) modules, \(variants.redundantTasks ?? 0) redundant PCM tasks"
            if let seconds = variants.redundantSeconds { text += ", " + Self.duration(seconds) }
            if !variants.causes.isEmpty { text += " (" + variants.causes.joined(separator: ", ") + ")" }
            lines.append(text)
        } else if graph.source == "targetGraph", let note = graph.notes.first(where: { $0.hasPrefix("variants: ") }) {
            lines.append(dim("  " + safe(note)))
        }
        if graph.source != "targetGraph", let note = graph.notes.first {
            lines.append(dim("  " + safe(note)))
        }
        return lines
    }
}
