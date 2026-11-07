import Foundation

/// Type-check hotspots from text already in the log (DESIGN §5.8, §6.5): `-debug-time-function-bodies` /
/// `-debug-time-expression-type-checking` lines in Swift compile output and `took Nms to type-check` diagnostics.
/// Filtered to user code, deduped by `file:line:col`. Never touches sources.
struct HotspotValue {
    var file: String
    var line: Int
    var col: Int
    var declaration: String
    var kind: String
    var ms: Double
    var source: String
    var onPathWeight: Double
    var occurrences: Int
    var targetId: Int?
    var taskId: Int?

    var key: String { "\(file):\(line):\(col)" }
}

struct HotspotsResult {
    /// Ranked by `ms × onPathWeight`, user code only, deduped.
    var rows: [HotspotValue]
    /// Raw debug-time lines and warn-long diagnostics read (before filtering and dedupe).
    var rawLines: Int
    var warnLong: Int
    /// False when the log has neither source: `hotspots` is then null, not empty.
    var hasSource: Bool
}

enum Hotspots {
    static let offPathWeight = 0.25

    /// Paths of code the project does not own.
    static func isUserCode(_ path: String) -> Bool {
        let foreign = ["/checkouts/", "/SourcePackages/", "/DerivedData/", "/Build/Intermediates.noindex/",
                       "/Build/Products/", "/Library/Developer/"]
        if foreign.contains(where: { path.contains($0) }) { return false }
        return !path.hasPrefix("/Applications/Xcode") && path.hasPrefix("/")
    }

    /// `pathTaskIds` nil (no critical path): every weight is 1.
    static func compute(counted: [Timing.Counted], model: BuildModel, pathTaskIds: Set<Int>?) -> HotspotsResult {
        var merged: [String: HotspotValue] = [:]
        var raw = 0
        func weight(_ taskId: Int?) -> Double {
            guard let pathTaskIds else { return 1 }
            return taskId.map(pathTaskIds.contains) == true ? 1 : offPathWeight
        }
        func merge(_ row: HotspotValue) {
            guard var existing = merged[row.key] else {
                merged[row.key] = row
                return
            }
            // Across tasks (batch sub-jobs, emit-module and compile): keep the larger timing, count every line.
            let occurrences = existing.occurrences + row.occurrences
            if row.ms > existing.ms { existing = row }
            existing.occurrences = occurrences
            merged[row.key] = existing
        }
        for item in counted where item.task.kind == .swiftCompile {
            guard var output = item.task.emittedOutput, output.contains("ms\t") else { continue }
            // A bridged string (xcresult JSON) copies its whole buffer on every slice conversion: go native once.
            output.makeContiguousUTF8()
            // Within one task, lines at one location (a property's accessors) add up.
            var local: [String: HotspotValue] = [:]
            var order: [String] = []
            // Split on bytes: `\r\n` is one Character, so a Character split would miss CRLF output (xcresult).
            for bytes in output.utf8.split(whereSeparator: { $0 == 10 || $0 == 13 }) {
                let line = Substring(bytes)
                guard let row = parse(line) else {
                    // A timer line without a usable location (`<invalid loc>`) still counts as read.
                    if isTimerLine(line) { raw += 1 }
                    continue
                }
                raw += 1
                guard isUserCode(row.file) else { continue }
                var value = row
                value.targetId = item.task.targetId
                value.taskId = item.task.id
                value.onPathWeight = weight(item.task.id)
                if var existing = local[value.key] {
                    existing.ms += value.ms
                    existing.occurrences += 1
                    local[value.key] = existing
                } else {
                    local[value.key] = value
                    order.append(value.key)
                }
            }
            for key in order { merge(local[key]!) }
        }
        var warnLong = 0
        for diagnostic in model.diagnostics {
            guard let row = parseWarnLong(diagnostic) else { continue }
            warnLong += 1
            guard isUserCode(row.file) else { continue }
            var value = row
            value.taskId = diagnostic.taskIds.first
            value.targetId = value.taskId.flatMap { model.tasks.indices.contains($0) ? model.tasks[$0].targetId : nil }
            value.onPathWeight = weight(value.taskId)
            merge(value)
        }
        // A 0 ms timer is no hotspot.
        let rows = merged.values.filter { $0.ms > 0 }.sorted {
            let a = $0.ms * $0.onPathWeight, b = $1.ms * $1.onPathWeight
            if a != b { return a > b }
            if $0.ms != $1.ms { return $0.ms > $1.ms }
            return $0.key < $1.key
        }
        return HotspotsResult(rows: rows, rawLines: raw, warnLong: warnLong, hasSource: raw > 0 || warnLong > 0)
    }

    /// `<ms>ms\t<file>:<line>:<col>[\t<decl>]`: split on the first two TABs, location split from the right.
    static func parse(_ line: Substring) -> HotspotValue? {
        let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
        guard fields.count >= 2, fields[0].hasSuffix("ms"), let ms = Double(fields[0].dropLast(2)), ms.isFinite,
              ms >= 0, let location = splitLocation(fields[1]) else { return nil }
        let isBody = fields.count == 3
        var declaration = isBody ? String(fields[2].prefix(1024)) : "expression"
        // `StringsView._@/path:399:25`: the location suffix repeats the location.
        if let at = declaration.range(of: "@/", options: .backwards) { declaration = String(declaration[..<at.lowerBound]) }
        return HotspotValue(file: location.file, line: location.line, col: location.col, declaration: declaration,
                            kind: isBody ? "functionBody" : "expression", ms: ms,
                            source: isBody ? "debugTimeFunctionBodies" : "debugTimeExpression", onPathWeight: 1,
                            occurrences: 1, targetId: nil, taskId: nil)
    }

    /// `<ms>ms\t...` whatever follows.
    static func isTimerLine(_ line: Substring) -> Bool {
        guard let tab = line.firstIndex(of: "\t") else { return false }
        let head = line[..<tab]
        return head.hasSuffix("ms") && Double(head.dropLast(2)) != nil
    }

    static func splitLocation(_ text: Substring) -> (file: String, line: Int, col: Int)? {
        guard let lastColon = text.lastIndex(of: ":"), let col = Int(text[text.index(after: lastColon)...]) else {
            return nil
        }
        let head = text[..<lastColon]
        guard let colon = head.lastIndex(of: ":"), let line = Int(head[head.index(after: colon)...]) else {
            return nil
        }
        let file = String(head[..<colon])
        return file.isEmpty || line < 1 || col < 1 ? nil : (file, line, col)
    }

    /// `Expression took 62ms to type-check (limit: 50ms)` / `Instance method 'f()' took 120ms to type-check ...`.
    static func parseWarnLong(_ diagnostic: Diagnostic) -> HotspotValue? {
        let title = diagnostic.text.prefix { !$0.isNewline }
        guard let took = title.range(of: " took "), let msEnd = title.range(of: "ms to type-check", range:
              took.upperBound..<title.endIndex), let ms = Double(title[took.upperBound..<msEnd.lowerBound]),
              let file = diagnostic.file, let line = diagnostic.line, line >= 1 else { return nil }
        let subject = String(title[..<took.lowerBound])
        let isExpression = subject.lowercased() == "expression"
        var declaration = isExpression ? "expression" : subject
        if let limit = title.range(of: "(limit: ") {
            let value = title[limit.upperBound...].prefix { $0 != ")" }
            declaration += " (warn limit \(value))"
        }
        return HotspotValue(file: file, line: line, col: max(1, diagnostic.column ?? 1), declaration: declaration,
                            kind: isExpression ? "expression" : "functionBody", ms: ms, source: "warnLong",
                            onPathWeight: 1, occurrences: 1, targetId: nil, taskId: nil)
    }

    /// Σ ms per file over the deduped rows (all of them, before capping). v0.5 lane A: located rows only; the
    /// file-level `--deep` rows (stats-dir jobs, ftime-trace units, `line` 0) would count the same time twice.
    static func typeCheckMsByFile(_ rows: [HotspotValue]) -> [String: Double] {
        var sums: [String: Double] = [:]
        for row in rows where row.line > 0 { sums[row.file, default: 0] += row.ms }
        return sums
    }
}
