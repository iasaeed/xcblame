import Foundation

// v0.5 lane A (docs/SCHEMA-v0.5.md "Deep"): `estimated` file rows (DESIGN §6.4).
extension FileAttribution {
    /// For each batch compile with per-file type-check ms in `hotspots`: one `estimated` row per member file, the batch
    /// seconds split by the file's share of the batch's type-check ms. Never summed with `exact` rows (V9), and the
    /// batch row stays.
    ///
    /// Per-file type-check ms is the sum of the located rows (`line` > 0) of that file from ONE source: function
    /// bodies (`-debug-time-function-bodies`), else expressions, else warn-long. Expression times nest inside the
    /// function bodies and warn-long repeats debug-time locations, so adding sources would count the same work twice.
    /// The file-level stats-dir and ftime-trace rows do not count (a batch job's stats cover the whole batch). A batch
    /// whose members have no type-check ms at all gets no rows; members without ms get a 0 s row so the batch is
    /// complete. Rows carry the batch's members (`batchSize`), task and path flag; heaviest first.
    static func estimatedRows(counted: [Timing.Counted], model: BuildModel, hotspots: [HotspotValue],
                              pathTaskIds: Set<Int>) -> [FileRowValue] {
        let order = ["debugTimeFunctionBodies", "debugTimeExpression", "warnLong"]
        var bySource: [String: [Int: Double]] = [:]
        for row in hotspots where row.line > 0 {
            guard let rank = order.firstIndex(of: row.source) else { continue }
            bySource[row.file, default: [:]][rank, default: 0] += row.ms
        }
        let typeCheck = bySource.compactMapValues { sums in sums.min { $0.key < $1.key }?.value }
        guard !typeCheck.isEmpty else { return [] }
        let wmo = wholeModuleTargets(model)
        var rows: [FileRowValue] = []
        for item in counted where item.task.kind == .swiftCompile {
            if let target = item.task.targetId, wmo.contains(target) { continue }
            let files = files(of: item.task)
            guard files.count > 1 else { continue }
            let shares = files.map { typeCheck[$0] ?? 0 }
            let total = shares.reduce(0, +)
            guard total > 0 else { continue }
            let members = files.sorted()
            for (file, ms) in zip(files, shares) {
                rows.append(FileRowValue(path: file, targetId: item.task.targetId,
                                         seconds: item.interval.duration * ms / total, granularity: "estimated",
                                         members: members, onPath: pathTaskIds.contains(item.task.id),
                                         typeCheckMs: ms, taskId: item.task.id))
            }
        }
        return rows.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.path < $1.path }
    }
}
