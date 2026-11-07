import Foundation

/// Columnar task table for the HTML timeline (DESIGN §8.2.2). HTML only: `--format json` leaves it out. Every column
/// has one entry per shown task; `target`, `kind` and `label` index the string tables. Lane A builds it.
public struct TaskIndex: Codable, Sendable, Equatable {
    /// Tasks left out by truncation (§8.2.3 step 3), per target and lane.
    public struct Dropped: Codable, Sendable, Equatable {
        /// Index into `targets`.
        public var target: Int
        public var lane: Int
        public var tasks: Int
        public var seconds: Double
    }

    /// Milliseconds from the session window start.
    public var start: [Int]
    /// Milliseconds.
    public var dur: [Int]
    /// Greedy lane packing, 0-based.
    public var lane: [Int]
    public var target: [Int]
    public var kind: [Int]
    public var label: [Int]
    /// 1 when the task is on the critical path, else 0.
    public var onPath: [UInt8]
    public var targets: [String]
    public var kinds: [String]
    public var labels: [String]
    public var dropped: [Dropped]
    public var taskIndexTotal: Int
    @Null public var taskIndexShownShare: Double?

    /// One row per task that entered timing (`build.tasks`; reused, invalid and untimed tasks are left out), sorted
    /// by start then task id, packed greedily into the lowest free lane (in whole milliseconds, so rendered rows never
    /// overlap). Labels are the rule plus the title with paths cut to their basename.
    public static func make(model: BuildModel, analysis: Analysis, document: ReportDocument) -> TaskIndex {
        let timeline = Timing.timeline(model)
        let origin = timeline.window.start
        let onPath = Set(document.criticalPath?.segments.flatMap(\.taskIds) ?? [])
        let rows = timeline.counted.map { item -> (id: Int, start: Int, dur: Int, task: BuildTask) in
            let start = Timing.millis(item.interval.start - origin)
            let end = Timing.millis(item.interval.end - origin)
            return (item.task.id, start, max(0, end - start), item.task)
        }.sorted { $0.start != $1.start ? $0.start < $1.start : $0.id < $1.id }

        var index = TaskIndex(start: [], dur: [], lane: [], target: [], kind: [], label: [], onPath: [], targets: [],
                              kinds: [], labels: [], dropped: [], taskIndexTotal: rows.count, taskIndexShownShare: nil)
        var tables: [String: Int] = [:]
        func intern(_ value: String, into column: WritableKeyPath<TaskIndex, [String]>, prefix: String) -> Int {
            if let id = tables[prefix + value] { return id }
            let id = index[keyPath: column].count
            index[keyPath: column].append(value)
            tables[prefix + value] = id
            return id
        }
        var laneEnds: [Int] = []
        for row in rows {
            let lane = laneEnds.firstIndex { $0 <= row.start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(0) }
            laneEnds[lane] = row.start + row.dur
            let target = row.task.targetId.flatMap { model.targets.indices.contains($0) ? model.targets[$0].name : nil }
            index.start.append(row.start)
            index.dur.append(row.dur)
            index.lane.append(lane)
            index.target.append(intern(target ?? "(no target)", into: \.targets, prefix: "t:"))
            index.kind.append(intern(row.task.kind.rawValue, into: \.kinds, prefix: "k:"))
            index.label.append(intern(label(row.task), into: \.labels, prefix: "l:"))
            index.onPath.append(onPath.contains(row.id) ? 1 : 0)
        }
        index.taskIndexShownShare = rows.contains { $0.dur > 0 } ? 1 : nil
        return index
    }

    /// `rule title` with every path-like word cut to its basename; no command line, key or signature.
    static func label(_ task: BuildTask) -> String {
        let words = task.title.split(separator: " ").map { word -> String in
            word.contains("/") ? (String(word) as NSString).lastPathComponent : String(word)
        }
        let title = words.joined(separator: " ")
        let text = title.isEmpty || title == task.ruleName ? task.ruleName : task.ruleName + " " + title
        return text.count > 120 ? String(text.prefix(119)) + "…" : text
    }
}
