import Foundation

/// Sweep-line utilization of DESIGN §6.3, in seconds from the window start: average running tasks per bucket, serial
/// stretches and idle gaps.
struct UtilizationResult {
    struct Stretch {
        var start: Double
        var end: Double
        var lanes: Int
    }

    var bucketSeconds: Double
    var lanes: [Double]
    /// Nil when no threshold could be set (no lanes at all).
    var threshold: Int?
    /// Longest first.
    var stretches: [Stretch]
    var serialSeconds: Double
    /// Longest first.
    var gaps: [(start: Double, end: Double)]
    var notes: [String]
}

enum Utilization {
    static let maxBuckets = 4000.0
    static let minBucket = 0.1
    static let minStretch = 1.0
    static let minGap = 0.1

    /// `intervals` are relative to the window start and clamped to `[0, span]`. The serial threshold is
    /// `max(1, floor(0.10 × physicalCores))`; without the core count, `peak` stands in for it (with a note).
    static func compute(intervals: [Interval], span: Double, peak: Int, physicalCores: Int?) -> UtilizationResult {
        let span = span.isFinite ? span : 0
        var bucket = max(minBucket, span / maxBuckets)
        // `span / (span / 4000)` can round to 4000.0000001 (ceil 4001): widen the bucket by ulps until it cannot.
        while span / bucket > maxBuckets { bucket = bucket.nextUp }
        let count = span > 0 ? Int((span / bucket).rounded(.up)) : 0
        var lanes = [Double](repeating: 0, count: count)
        var full = [Double](repeating: 0, count: count + 1)
        for interval in intervals where interval.end > interval.start && count > 0 {
            let first = min(count - 1, Int(interval.start / bucket))
            let last = min(count - 1, Int(interval.end / bucket))
            if first == last {
                lanes[first] += interval.duration
                continue
            }
            lanes[first] += Double(first + 1) * bucket - interval.start
            lanes[last] += interval.end - Double(last) * bucket
            if last > first + 1 {
                full[first + 1] += bucket
                full[last] -= bucket
            }
        }
        var running = 0.0
        for index in 0..<count {
            running += full[index]
            lanes[index] = (lanes[index] + running) / bucket
        }

        var notes: [String] = []
        let threshold: Int?
        if let physicalCores, physicalCores > 0 {
            threshold = max(1, Int(0.10 * Double(physicalCores)))
        } else if peak > 0 {
            threshold = max(1, Int(0.10 * Double(peak)))
            notes.append("serialThresholdLanes: physical cores unknown, 10% of the peak lanes (\(peak)) used instead")
        } else {
            threshold = nil
            notes.append("serialThresholdLanes: no running tasks")
        }

        // Piecewise-constant concurrency from the interval ends (ends before starts at one instant).
        var events: [(time: Double, delta: Int)] = []
        events.reserveCapacity(intervals.count * 2)
        for interval in intervals where interval.end > interval.start {
            events.append((interval.start, 1))
            events.append((interval.end, -1))
        }
        events.sort { $0.time != $1.time ? $0.time < $1.time : $0.delta < $1.delta }
        var stretches: [UtilizationResult.Stretch] = []
        var gaps: [(start: Double, end: Double)] = []
        var active = 0
        var previous = 0.0
        var open: (start: Double, lanes: Int)?
        func closeStretch(at time: Double) {
            if let current = open, time - current.start >= minStretch {
                stretches.append(.init(start: current.start, end: time, lanes: current.lanes))
            }
            open = nil
        }
        func advance(to time: Double) {
            guard time > previous else { return }
            if active == 0 {
                if time - previous > minGap { gaps.append((previous, time)) }
            } else if let threshold, active <= threshold {
                let lanes = max(open?.lanes ?? 0, active)
                open = (open?.start ?? previous, lanes)
            }
            if active == 0 || threshold.map({ active > $0 }) ?? true { closeStretch(at: previous) }
            previous = time
        }
        for event in events {
            advance(to: event.time)
            active += event.delta
        }
        closeStretch(at: previous)
        if span > previous, span - previous > minGap { gaps.append((previous, span)) }

        stretches.sort { $0.end - $0.start != $1.end - $1.start ? $0.end - $0.start > $1.end - $1.start : $0.start < $1.start }
        gaps.sort { $0.end - $0.start != $1.end - $1.start ? $0.end - $0.start > $1.end - $1.start : $0.start < $1.start }
        return UtilizationResult(bucketSeconds: bucket, lanes: lanes, threshold: threshold, stretches: stretches,
                                 serialSeconds: stretches.reduce(0) { $0 + $1.end - $1.start }, gaps: gaps,
                                 notes: notes)
    }
}
