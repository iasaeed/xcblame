import Foundation

/// A rollup of task time over one dimension. It is always a partition of the tasks that entered timing: row seconds
/// sum to `total`, row task counts sum to `totalTasks`, and a catch-all row (`isOther`) is present even when empty
/// (DESIGN §6.11 V6).
public struct Rollup: Codable, Sendable {
    public struct Row: Codable, Sendable {
        /// Stable machine key: `TaskKind`/`Phase` raw value, `t<targetId>`, or `unclassified`.
        public var key: String
        public var name: String
        /// Set on target rows that map to a model target.
        public var targetId: Int?
        public var taskCount: Int
        public var seconds: Double
        /// The `other` / `unclassified` catch-all row.
        public var isOther: Bool

        public init(key: String, name: String, targetId: Int? = nil, taskCount: Int, seconds: Double,
                    isOther: Bool) {
            self.key = key
            self.name = name
            self.targetId = targetId
            self.taskCount = taskCount
            self.seconds = seconds
            self.isOther = isOther
        }
    }

    public var dimension: String
    public var total: Double
    public var totalTasks: Int
    /// Sorted by seconds descending, then key.
    public var rows: [Row]

    public init(dimension: String, total: Double, totalTasks: Int, rows: [Row]) {
        self.dimension = dimension
        self.total = total
        self.totalTasks = totalTasks
        self.rows = rows
    }

    public var sumSeconds: Double { rows.reduce(0) { $0 + $1.seconds } }
    public var sumTasks: Int { rows.reduce(0) { $0 + $1.taskCount } }
    public var hasOtherRow: Bool { rows.contains { $0.isOther } }

    /// Share of `total` (0...1); nil when there is no task time (never 0 for "unknown").
    public func share(of seconds: Double) -> Double? { total > 0 ? seconds / total : nil }

    /// Rows sum to the total (within float noise) and the catch-all row exists.
    public var isPartition: Bool {
        let tolerance = 1e-6 * max(1, abs(total))
        return hasOtherRow && abs(sumSeconds - total) <= tolerance && sumTasks == totalTasks
    }

    /// Builds a rollup from `(key, name, targetId, seconds)` entries; `other` gets its row even with no entries.
    static func build(dimension: String, entries: [Entry], other: (key: String, name: String), total: Double,
                      totalTasks: Int) -> Rollup {
        var rows: [Row] = []
        var otherRow = Row(key: other.key, name: other.name, taskCount: 0, seconds: 0, isOther: true)
        var grouped: [String: Row] = [:]
        var order: [String] = []
        for e in entries {
            if e.key == other.key {
                otherRow.taskCount += 1
                otherRow.seconds += e.seconds
            } else if var row = grouped[e.key] {
                row.taskCount += 1
                row.seconds += e.seconds
                grouped[e.key] = row
            } else {
                grouped[e.key] = Row(key: e.key, name: e.name, targetId: e.targetId, taskCount: 1, seconds: e.seconds,
                                     isOther: false)
                order.append(e.key)
            }
        }
        rows = order.compactMap { grouped[$0] }
        rows.append(otherRow)
        rows.sort { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.key < $1.key }
        return Rollup(dimension: dimension, total: total, totalTasks: totalTasks, rows: rows)
    }

    struct Entry {
        var key: String
        var name: String
        var targetId: Int?
        var seconds: Double
    }
}
