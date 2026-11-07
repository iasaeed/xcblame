import Foundation

/// The ordered truncation pass of DESIGN §8.2.3: drops rows until the serialized data fits `maxBytes - templateBytes`
/// and records each step in `document.truncation.steps`. It only removes rows: every `*Total`, headline number,
/// partition, `timing.utilization` and `criticalPath` stays as computed (V6, V13).
// ponytail: runs for html only in v0.2; `--format json` keeps V13 reporting an oversized report instead.
public enum ReportBudget {
    /// Output formats with a size budget and a redact default (DESIGN §3.1, §8.3; docs/SCHEMA-v0.4.md "Formats").
    /// `text` is the terminal format: no cap, never redacted by default. Lane A fills the truncation of the four v0.4
    /// text formats; the html pass below is unchanged.
    public enum Format: String, Sendable, CaseIterable {
        case text, json, html, markdown, github, junit, agent

        /// Default `--max-report-bytes`: json 2 MB (V13), html 8 MB (template included), markdown and github 64 KB,
        /// agent 8 KB, junit and text uncapped (`Int.max`).
        public var defaultMaxBytes: Int {
            switch self {
            case .text, .junit: return .max
            case .json: return Validator.defaultBudgetBytes
            case .html: return HTMLReporter.defaultMaxBytes
            case .markdown, .github: return 64 * 1024
            case .agent: return 8 * 1024
            }
        }

        /// `--redact` default: on for html, markdown, github and agent (they leave the machine), off for the rest.
        public var redactsByDefault: Bool {
            switch self {
            case .html, .markdown, .github, .agent: return true
            case .text, .json, .junit: return false
            }
        }

        /// The four formats the v0.4 text reporters render (`Reporters/Formats/`).
        public var isV04TextFormat: Bool {
            switch self {
            case .markdown, .github, .junit, .agent: return true
            case .text, .json, .html: return false
            }
        }
    }

    public static func apply(_ document: inout ReportDocument, taskIndex: inout TaskIndex?, maxBytes: Int,
                             templateBytes: Int) {
        var pass = Pass(document: document, taskIndex: taskIndex, budget: maxBytes - templateBytes)
        pass.run()
        document = pass.document
        taskIndex = pass.taskIndex
    }

    struct Pass {
        var document: ReportDocument
        var taskIndex: TaskIndex?
        let budget: Int

        /// Serialized blob size; a failed encode counts as over budget.
        var fits: Bool {
            ((try? HTMLReporter.dataBlob(document, taskIndex: taskIndex))?.utf8.count ?? .max) <= budget
        }

        mutating func run() {
            if fits { return }
            if topTasks() { return }
            if causeTasks() { return }
            if hotspots() { return }
            if files() { return }
            if taskIndexDetail() { return }
            // v0.5 lane C (begin): step 4, module graph (`HTMLReporter.collapsedModuleGraph`).
            if moduleGraph() { return }
            // v0.5 lane C (end)
            if rollups() { return }
            if findingsEvidence() { return }
            // Step 7 (diagnostics): v0.2 embeds only `diagnosticsSummary` counts, so there is nothing to drop.
            lastResort()
        }

        // MARK: - Steps

        /// 0. Top tasks: keep the top 500, then the top 25. Not a DESIGN §8.2.3 step: html runs with `--top all`, so
        /// `topTasks` repeats every task the `taskIndex` already holds, and no v0.2 section renders it. Left for step 5
        /// it is the last list trimmed, after every other list is at its floor.
        // ponytail: placed first by judgement; upgrade path is a DESIGN §8.2.3 amendment naming this step.
        mutating func topTasks() -> Bool {
            guard let rows = document.topTasks else { return false }
            let all = measureTotal(rows.reduce(0) { $0 + $1.seconds }, shown: document.topTasksShownShare)
            let stages: [([ReportDocument.TopTask]) -> [ReportDocument.TopTask]] = [
                { Array($0.prefix(500)) }, { Array($0.prefix(25)) },
            ]
            return thin(stages, step: "topTasks", total: document.topTasksTotal, rows: \.topTasks,
                        share: \.topTasksShownShare, measure: { $0.reduce(0) { $0 + $1.seconds } }, all: all)
        }

        /// 0b. The task lists inside `incremental.causes` and `fixedCosts` (v0.5): html runs with `--top all`, so
        /// together they repeat every executed task the `taskIndex` already holds. Keep the top 200 tasks per cause
        /// and per fixed-cost class, then the top 25. Floor: 25 per entry. No cause or class is ever dropped
        /// (`unknown` included), and each list's `tasksShownShare` is rescaled to the seconds its kept tasks cover;
        /// `tasksTotal`, `seconds` and V15 stay. One step is recorded per member that lost tasks.
        mutating func causeTasks() -> Bool {
            typealias Task = ReportDocument.Incremental.CauseTask
            func seconds(_ tasks: [Task]) -> Double { tasks.reduce(0) { $0 + $1.seconds } }
            // Measure of every task of each entry before any cut (the kept tasks cover `tasksShownShare` of it).
            let causeAll = document.incremental?.causes
                .map { measureTotal(seconds($0.tasks), shown: $0.tasksShownShare) } ?? []
            let costAll = document.fixedCosts?.map { measureTotal(seconds($0.tasks), shown: $0.tasksShownShare) } ?? []
            var cutCauses = false
            var cutCosts = false
            for keep in [200, 25] {
                var cut = false
                if var incremental = document.incremental {
                    for index in incremental.causes.indices where incremental.causes[index].tasks.count > keep {
                        incremental.causes[index].tasks = Array(incremental.causes[index].tasks.prefix(keep))
                        incremental.causes[index].tasksShownShare = Self.share(seconds(incremental.causes[index].tasks),
                                                                               of: causeAll[index])
                        cut = true
                        cutCauses = true
                    }
                    document.incremental = incremental
                }
                if var costs = document.fixedCosts {
                    for index in costs.indices where costs[index].tasks.count > keep {
                        costs[index].tasks = Array(costs[index].tasks.prefix(keep))
                        costs[index].tasksShownShare = Self.share(seconds(costs[index].tasks), of: costAll[index])
                        cut = true
                        cutCosts = true
                    }
                    document.fixedCosts = costs
                }
                if cut, fits { break }
            }
            if cutCauses, let causes = document.incremental?.causes {
                record("incrementalTasks", kept: causes.reduce(0) { $0 + $1.tasks.count },
                       total: causes.reduce(0) { $0 + $1.tasksTotal },
                       share: Self.share(causes.reduce(0) { $0 + seconds($1.tasks) }, of: causeAll.reduce(0, +)))
            }
            if cutCosts, let costs = document.fixedCosts {
                record("fixedCostTasks", kept: costs.reduce(0) { $0 + $1.tasks.count },
                       total: costs.reduce(0) { $0 + $1.tasksTotal },
                       share: Self.share(costs.reduce(0) { $0 + seconds($1.tasks) }, of: costAll.reduce(0, +)))
            }
            return (cutCauses || cutCosts) && fits
        }

        /// 1. Drop hotspots < 10 ms, then keep the top 500. Floor: the top 25.
        mutating func hotspots() -> Bool {
            guard let rows = document.hotspots else { return false }
            let stages: [([ReportDocument.Hotspot]) -> [ReportDocument.Hotspot]] = [
                { Self.floored($0.filter { $0.ms >= 10 }, from: $0, floor: 25) }, { Array($0.prefix(500)) },
                { Array($0.prefix(25)) },
            ]
            let all = measureTotal(rows.reduce(0) { $0 + $1.ms }, shown: document.hotspotsShownShare)
            return thin(stages, step: "hotspots", total: document.hotspotsTotal, rows: \.hotspots,
                        share: \.hotspotsShownShare, measure: { $0.reduce(0) { $0 + $1.ms } }, all: all)
        }

        /// 2. Drop files < 0.1 % of compile task time, then keep the top 1,000. Floor: the top 25.
        mutating func files() -> Bool {
            guard let rows = document.files else { return false }
            let all = measureTotal(rows.reduce(0) { $0 + $1.seconds }, shown: document.filesShownShare)
            let stages: [([ReportDocument.FileRow]) -> [ReportDocument.FileRow]] = [
                { Self.floored($0.filter { $0.seconds >= 0.001 * all }, from: $0, floor: 25) }, { Array($0.prefix(1000)) },
                { Array($0.prefix(25)) },
            ]
            return thin(stages, step: "files", total: document.filesTotal, rows: \.files, share: \.filesShownShare,
                        measure: { $0.reduce(0) { $0 + $1.seconds } }, all: all)
        }

        /// 3. Drop off-path tasks < 50 ms, then < 250 ms, then < 1 s. Floor: every on-path task plus each target's
        /// longest task. Dropped tasks are counted per target and lane.
        mutating func taskIndexDetail() -> Bool {
            guard let original = taskIndex, !original.start.isEmpty else { return false }
            let allMs = measureTotal(Double(original.dur.reduce(0, +)), shown: original.taskIndexShownShare)
            var changed = false
            for threshold in [50, 250, 1000] {
                guard let current = taskIndex else { break }
                // Thinning never removes a target's longest task, so it stays the longest in every stage.
                var longest: [Int: Int] = [:]
                for row in current.start.indices
                where current.dur[row] > longest[current.target[row]].map({ current.dur[$0] }) ?? -1 {
                    longest[current.target[row]] = row
                }
                let keepAlways = Set(longest.values)
                let keep = current.start.indices.filter { row in
                    current.onPath[row] != 0 || current.dur[row] >= threshold || keepAlways.contains(row)
                }
                guard keep.count < current.start.count else { continue }
                taskIndex = Self.thinned(current, keeping: keep, allMs: allMs)
                changed = true
                if fits { break }
            }
            if changed, let index = taskIndex {
                record("taskIndex", kept: index.start.count, total: index.taskIndexTotal,
                       share: index.taskIndexShownShare)
            }
            return changed && fits
        }

        /// 5. Targets and the other capped rollups (top tasks went first, see step 0). Targets keep the top 25 plus the `other` row, with removed rows
        /// folded into `other` so the partition stays (V6); the plain capped lists keep their top 25.
        mutating func rollups() -> Bool {
            if let rows = document.targets, rows.filter({ !$0.isOther }).count > 25 {
                let all = measureTotal(rows.reduce(0) { $0 + $1.taskTime }, shown: document.targetsShownShare)
                let (kept, keptTime) = Self.foldTargets(rows, keep: 25)
                document.targets = kept
                document.targetsShownShare = Self.share(keptTime, of: all)
                record("targets", kept: kept.count, total: document.targetsTotal, share: document.targetsShownShare)
                if fits { return true }
            }
            if let rows = document.timing.serialStretches, rows.count > 25 {
                let length = { (r: ArraySlice<ReportDocument.SerialStretch>) in r.reduce(0) { $0 + $1.end - $1.start } }
                let all = measureTotal(length(rows[...]), shown: document.timing.serialStretchesShownShare)
                let kept = Self.longest(rows, 25) { $0.end - $0.start }
                document.timing.serialStretches = kept
                document.timing.serialStretchesShownShare = Self.share(length(kept[...]), of: all)
                record("serialStretches", kept: 25, total: document.timing.serialStretchesTotal,
                       share: document.timing.serialStretchesShownShare)
                if fits { return true }
            }
            if let rows = document.timing.idleGaps, rows.count > 25 {
                let length = { (r: ArraySlice<ReportDocument.Gap>) in r.reduce(0) { $0 + $1.end - $1.start } }
                let all = measureTotal(length(rows[...]), shown: document.timing.idleGapsShownShare)
                let kept = Self.longest(rows, 25) { $0.end - $0.start }
                document.timing.idleGaps = kept
                document.timing.idleGapsShownShare = Self.share(length(kept[...]), of: all)
                record("idleGaps", kept: 25, total: document.timing.idleGapsTotal,
                       share: document.timing.idleGapsShownShare)
                if fits { return true }
            }
            if document.build.tasksWithoutTiming.count > 25 {
                document.build.tasksWithoutTiming = Array(document.build.tasksWithoutTiming.prefix(25))
                record("tasksWithoutTiming", kept: 25, total: document.build.tasksWithoutTimingTotal, share: nil)
                if fits { return true }
            }
            if document.decodeWarnings.count > 25 {
                document.decodeWarnings = Array(document.decodeWarnings.prefix(25))
                record("decodeWarnings", kept: 25, total: document.decodeWarningsTotal, share: nil)
                if fits { return true }
            }
            return false
        }

        // v0.5 lane C (begin)
        /// 4. Module graph: collapse nodes outside the critical chain and its neighbours by owner, to 100 then 25
        /// plain nodes (floor: the critical chain). Totals never change.
        mutating func moduleGraph() -> Bool {
            guard let graph = document.moduleGraph else { return false }
            var changed = false
            for keep in [100, 25] {
                guard let current = document.moduleGraph,
                      current.nodes.filter({ $0.collapsed == 0 }).count > max(keep, current.criticalChain.count) else {
                    continue
                }
                document.moduleGraph = HTMLReporter.collapsedModuleGraph(current, keep: keep)
                changed = true
                if fits { break }
            }
            if changed, let kept = document.moduleGraph {
                record("moduleGraph", kept: kept.nodes.filter { $0.collapsed == 0 }.count, total: graph.nodesTotal,
                       share: kept.nodesShownShare)
            }
            return changed && fits
        }
        // v0.5 lane C (end)

        /// 6. Evidence floor: 3 items per finding. Findings themselves are never dropped.
        mutating func findingsEvidence() -> Bool {
            let total = document.findings.reduce(0) { $0 + $1.evidence.count }
            guard document.findings.contains(where: { $0.evidence.count > 3 }) else { return false }
            for index in document.findings.indices {
                document.findings[index].evidence = Array(document.findings[index].evidence.prefix(3))
                // `evidenceDetails` is the structured form of `evidence`: same order and count (SCHEMA-v0.3).
                document.findings[index].evidenceDetails = Array(document.findings[index].evidenceDetails.prefix(3))
            }
            record("findingsEvidence", kept: document.findings.reduce(0) { $0 + $1.evidence.count }, total: total,
                   share: nil)
            return fits
        }

        /// 8. Drop `taskIndex`; if that is not enough, keep only the header, findings and validation (the lists
        /// become null with their `*Total` kept: computed, then withheld).
        mutating func lastResort() {
            if let index = taskIndex {
                taskIndex = nil
                record("lastResort", kept: 0, total: index.taskIndexTotal, share: nil)
                if fits { return }
            }
            document.hotspots = nil
            document.hotspotsShownShare = nil
            document.files = nil
            document.filesShownShare = nil
            document.targets = nil
            document.targetsShownShare = nil
            document.topTasks = nil
            document.topTasksShownShare = nil
            document.phases = nil
            document.kinds = nil
            document.criticalPath = nil
            document.timing.utilization = nil
            document.timing.serialStretches = nil
            document.timing.serialStretchesShownShare = nil
            document.timing.idleGaps = nil
            document.timing.idleGapsShownShare = nil
            document.build.tasksWithoutTiming = []
            document.decodeWarnings = []
            let note = "report truncated to header, findings and validation: the data did not fit "
                + "--max-report-bytes; rerun with --format json --top all for every row"
            document.notes.append(note)
            document.timing.notes.append(note)
            record("lastResort", kept: 0, total: document.build.tasks, share: nil)
        }

        // MARK: - Helpers

        /// Runs `stages` on the list at `rows` until the blob fits; records one step when rows were removed.
        mutating func thin<Row>(_ stages: [([Row]) -> [Row]], step: String, total: Int,
                                rows: WritableKeyPath<ReportDocument, [Row]?>,
                                share: WritableKeyPath<ReportDocument, Double?>,
                                measure: ([Row]) -> Double, all: Double) -> Bool {
            guard let start = document[keyPath: rows] else { return false }
            var current = start
            for stage in stages {
                let next = stage(current)
                guard next.count < current.count else { continue }
                current = next
                document[keyPath: rows] = current
                if fits { break }
            }
            guard current.count < start.count else { return false }
            document[keyPath: share] = Self.share(measure(current), of: all)
            record(step, kept: current.count, total: total, share: document[keyPath: share])
            return fits
        }

        mutating func record(_ step: String, kept: Int, total: Int, share: Double?) {
            document.truncation.steps.append(.init(step: step, kept: kept, total: total, shownShare: share))
        }

        /// Measure of the whole list before any capping: the embedded rows cover `shown` of it.
        func measureTotal(_ embedded: Double, shown: Double?) -> Double {
            guard let shown, shown > 0 else { return embedded }
            return embedded / shown
        }

        /// The `count` longest rows, kept in their (time) order; ties keep the earlier row.
        static func longest<Row>(_ rows: [Row], _ count: Int, length: (Row) -> Double) -> [Row] {
            let keep = Set(rows.indices.sorted { length(rows[$0]) != length(rows[$1]) ? length(rows[$0]) > length(rows[$1])
                                                    : $0 < $1 }.prefix(count))
            return rows.indices.filter(keep.contains).map { rows[$0] }
        }

        static func floored<Row>(_ filtered: [Row], from rows: [Row], floor: Int) -> [Row] {
            filtered.count >= floor ? filtered : Array(rows.prefix(max(floor, filtered.count)))
        }

        static func share(_ part: Double, of total: Double) -> Double? {
            total > 0 ? ReportDocument.round6(min(1, part / total)) : nil
        }

        /// Keeps the first `keep` non-other rows in their order; the rest fold into the `other` row (created when the
        /// list has none). Returns the rows and the task time of the kept original rows.
        static func foldTargets(_ rows: [ReportDocument.TargetRow], keep: Int) -> ([ReportDocument.TargetRow], Double) {
            var kept: [ReportDocument.TargetRow] = []
            var folded: [ReportDocument.TargetRow] = []
            var other: ReportDocument.TargetRow?
            for row in rows {
                if row.isOther { other = row } else if kept.count < keep { kept.append(row) } else { folded.append(row) }
            }
            let keptTime = kept.reduce(0) { $0 + $1.taskTime } + (other?.taskTime ?? 0)
            var bucket = other ?? ReportDocument.TargetRow(
                id: nil, name: "other", project: nil, isPackage: nil, isBucket: nil, tasks: 0, taskTime: 0, share: 0,
                isOther: true, owner: nil, onPathSeconds: nil, whatIfSeconds: nil, busy: nil, kinds: nil)
            bucket.tasks += folded.reduce(0) { $0 + $1.tasks }
            bucket.taskTime = ReportDocument.round6(bucket.taskTime + folded.reduce(0) { $0 + $1.taskTime })
            if let share = bucket.share { bucket.share = ReportDocument.round6(share + folded.reduce(0) { $0 + ($1.share ?? 0) }) }
            if bucket.onPathSeconds != nil || folded.contains(where: { $0.onPathSeconds != nil }) {
                bucket.onPathSeconds = ReportDocument.round6((bucket.onPathSeconds ?? 0)
                    + folded.reduce(0) { $0 + ($1.onPathSeconds ?? 0) })
            }
            // The folded rows' kinds and busy cannot be merged without the tasks: unknown on the bucket.
            if !folded.isEmpty { bucket.kinds = nil; bucket.busy = nil; bucket.whatIfSeconds = nil }
            return (kept + [bucket], keptTime)
        }

        /// The index restricted to `keep` (rows of `index`), with the removed rows added to `dropped` per target and
        /// lane and unused labels pruned from the string table.
        static func thinned(_ index: TaskIndex, keeping keep: [Int], allMs: Double) -> TaskIndex {
            let kept = Set(keep)
            var dropped: [Pair: (tasks: Int, ms: Int)] = [:]
            for row in index.start.indices where !kept.contains(row) {
                let pair = Pair(target: index.target[row], lane: index.lane[row])
                dropped[pair, default: (0, 0)].tasks += 1
                dropped[pair, default: (0, 0)].ms += index.dur[row]
            }
            for old in index.dropped {
                let pair = Pair(target: old.target, lane: old.lane)
                dropped[pair, default: (0, 0)].tasks += old.tasks
                dropped[pair, default: (0, 0)].ms += Timing.millis(old.seconds)
            }
            var labelMap: [Int: Int] = [:]
            var labels: [String] = []
            let label = keep.map { row -> Int in
                let old = index.label[row]
                if let new = labelMap[old] { return new }
                labelMap[old] = labels.count
                labels.append(index.labels[old])
                return labels.count - 1
            }
            let shownMs = keep.reduce(0) { $0 + index.dur[$1] }
            var out = index
            out.start = keep.map { index.start[$0] }
            out.dur = keep.map { index.dur[$0] }
            out.lane = keep.map { index.lane[$0] }
            out.target = keep.map { index.target[$0] }
            out.kind = keep.map { index.kind[$0] }
            out.onPath = keep.map { index.onPath[$0] }
            out.label = label
            out.labels = labels
            out.dropped = dropped.keys.sorted().map {
                TaskIndex.Dropped(target: $0.target, lane: $0.lane, tasks: dropped[$0]!.tasks,
                                  seconds: Double(dropped[$0]!.ms) / 1000)
            }
            out.taskIndexShownShare = share(Double(shownMs), of: allMs)
            return out
        }

        struct Pair: Hashable, Comparable {
            var target: Int
            var lane: Int
            static func < (a: Pair, b: Pair) -> Bool { (a.target, a.lane) < (b.target, b.lane) }
        }
    }
}
