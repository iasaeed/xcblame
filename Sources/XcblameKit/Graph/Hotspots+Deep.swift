import Foundation

// v0.5 lane A (docs/SCHEMA-v0.5.md "Deep"): stats-dir and ftime-trace rows merged into the hotspot ranking.
extension Hotspots {
    /// `base` plus the rows of `StatsDirReader` and `FTimeTraceReader` (sources `statsDir`, `ftimeTrace`), deduped and
    /// ranked like the debug-time rows (§6.5), and the per-reader row counts for `deep.sources`. Without `deep` the
    /// result is `base` and `sources` nil. A reader that fails adds nothing; why is in `notes` (for `deep.notes`).
    ///
    /// The debug-time and warn-long rows are `base`'s (already filtered and deduped by `compute`). The deep rows go
    /// through the same user-code filter and weight (1 when the row's task is on the critical path, else 0.25), then
    /// dedupe: located rows by `file:line:col`, file-level rows (`line` 0) by `file:0:0:source:kind` — the larger `ms`
    /// wins and occurrences add up (two archs, several TUs including one header). Ranked by `ms × weight`.
    static func mergeDeep(_ base: HotspotsResult, deep: DeepRun?, counted: [Timing.Counted], model: BuildModel,
                          pathTaskIds: Set<Int>?)
        -> (result: HotspotsResult, sources: ReportDocument.Deep.Sources?, notes: [String]) {
        guard let deep, deep.enabled else { return (base, nil, []) }
        var notes: [String] = []
        var statsRows: [HotspotValue] = []
        var traceRows: [HotspotValue] = []
        if deep.flags.scope.contains(.swift) {
            if FileManager.default.fileExists(atPath: deep.statsDir.path) {
                do { statsRows = try StatsDirReader.read(directory: deep.statsDir, model: model) } catch {
                    notes.append("stats-dir: not read (\(error))")
                }
                if statsRows.isEmpty, notes.isEmpty { notes.append("stats-dir: no compile job files in \(deep.statsDir.path)") }
            } else if deep.flags.injected.contains(where: { $0.contains("-stats-output-dir") }) {
                notes.append("stats-dir: \(deep.statsDir.path) does not exist (no Swift frontend job ran)")
            }
        }
        if deep.flags.scope.contains(.clang), deep.flags.injected.contains("-ftime-trace") {
            do { traceRows = try FTimeTraceReader.read(counted: counted, model: model, notes: &notes) } catch {
                notes.append("ftime-trace: not read (\(error))")
            }
        }
        let sources = ReportDocument.Deep.Sources(debugTime: base.rawLines, warnLong: base.warnLong,
                                                  statsDir: statsRows.count, ftimeTrace: traceRows.count)
        func weight(_ taskId: Int?) -> Double {
            guard let pathTaskIds else { return 1 }
            return taskId.map(pathTaskIds.contains) == true ? 1 : offPathWeight
        }
        func key(_ row: HotspotValue) -> String {
            row.line == 0 ? "\(row.file):0:0:\(row.source):\(row.kind)" : row.key
        }
        var merged: [String: HotspotValue] = [:]
        for row in base.rows { merged[key(row)] = row }
        for var row in statsRows + traceRows where isUserCode(row.file) && row.ms > 0 {
            row.onPathWeight = weight(row.taskId)
            let k = key(row)
            guard var existing = merged[k] else {
                merged[k] = row
                continue
            }
            let occurrences = existing.occurrences + row.occurrences
            if row.ms > existing.ms { existing = row }
            existing.occurrences = occurrences
            merged[k] = existing
        }
        let rows = merged.values.sorted {
            let a = $0.ms * $0.onPathWeight, b = $1.ms * $1.onPathWeight
            if a != b { return a > b }
            if $0.ms != $1.ms { return $0.ms > $1.ms }
            return key($0) < key($1)
        }
        var result = base
        result.rows = rows
        result.hasSource = base.hasSource || !statsRows.isEmpty || !traceRows.isEmpty
        return (result, sources, notes)
    }
}
