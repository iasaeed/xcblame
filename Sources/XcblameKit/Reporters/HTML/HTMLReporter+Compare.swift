import Foundation

extension HTMLReporter {
    /// The one-file HTML of `compare --format html` (DESIGN §8.2.4 #11; docs/SCHEMA-v0.4.md "HTML views"): the template
    /// with the pretty-printed `CompareDocument` JSON as `#xcblame-data`, plus the HTML-only members `taskIndexA` and
    /// `taskIndexB` (compact, spliced at their sorted positions) when a side has a task index. Each side is held to
    /// half the data budget (§8.2.2): when the page is over `options.maxBytes`, each index is thinned (off-path tasks
    /// under 50 ms, 250 ms, 1 s; on-path tasks and each target's longest stay) and dropped when that is not enough;
    /// then the document's own tables are cut to 25 rows. Every step is recorded in `truncation.steps`. The page
    /// never exceeds the cap unless even the floors do not fit (then it is written anyway; the caller warns).
    public static func renderCompare(_ document: CompareDocument, taskIndexA: TaskIndex?, taskIndexB: TaskIndex?,
                                     options: Options) throws -> Data {
        let page = filledTemplate(toolVersion: document.tool.version, generatedAt: document.generatedAt, title: options.title)
        guard let range = page.range(of: dataPlaceholder) else {
            throw XcblameError.notImplemented("report template has no \(dataPlaceholder) placeholder")
        }
        let templateBytes = page.utf8.count - dataPlaceholder.utf8.count
        func assemble(_ document: CompareDocument, _ a: TaskIndex?, _ b: TaskIndex?) throws -> Data {
            var out = Data(page[..<range.lowerBound].utf8)
            out.append(Data(try compareBlob(document, taskIndexA: a, taskIndexB: b).utf8))
            out.append(Data(page[range.upperBound...].utf8))
            return out
        }
        let whole = try assemble(document, taskIndexA, taskIndexB)
        if whole.count <= options.maxBytes { return whole }

        var document = document
        var indexA = taskIndexA, indexB = taskIndexB
        // Room for the steps recorded below and the JSON of the document itself stays with the document.
        let dataBudget = max(0, options.maxBytes - templateBytes - 1024)
        let documentBytes = try compareBlob(document, taskIndexA: nil, taskIndexB: nil).utf8.count
        let half = max(0, (dataBudget - documentBytes) / 2)
        for side in ["A", "B"] {
            guard let index = side == "A" ? indexA : indexB else { continue }
            let thinned = thin(index, budget: half)
            if side == "A" { indexA = thinned.index } else { indexB = thinned.index }
            if let step = thinned.step { document.truncation.steps.append(step.named("taskIndex" + side)) }
        }
        var current = try assemble(document, indexA, indexB)
        if current.count > options.maxBytes { current = try assemble(cutTables(&document), indexA, indexB) }
        return current
    }

    /// The `#xcblame-data` content of a compare page: exactly `Compare.renderJSON(document)` with `taskIndexA` and
    /// `taskIndexB` spliced in as top-level members at their sorted positions, escaped for script data. Without task
    /// indexes (and without characters that need escaping) it is byte-equal to `--format json`.
    public static func compareBlob(_ document: CompareDocument, taskIndexA: TaskIndex?, taskIndexB: TaskIndex?) throws -> String {
        var json = String(decoding: try Compare.renderJSON(document), as: UTF8.self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        for (name, index) in [("taskIndexA", taskIndexA), ("taskIndexB", taskIndexB)] {
            guard let index else { continue }
            json = splice(member: name, value: String(decoding: try encoder.encode(index), as: UTF8.self), into: json)
        }
        return escapeScriptData(json)
    }

    // MARK: - Budget

    private static func compactSize(_ index: TaskIndex) -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(index).count) ?? .max
    }

    /// `index` within `budget` bytes (compact JSON): untouched when it fits, thinned, or nil (dropped). The step is nil
    /// when nothing was removed.
    private static func thin(_ index: TaskIndex, budget: Int) -> (index: TaskIndex?, step: ReportDocument.TruncationStep?) {
        if compactSize(index) <= budget { return (index, nil) }
        let embedded = Double(index.dur.reduce(0, +))
        let allMs = (index.taskIndexShownShare ?? 0) > 0 ? embedded / (index.taskIndexShownShare ?? 1) : embedded
        var current = index
        for threshold in [50, 250, 1000] {
            var longest: [Int: Int] = [:]
            for row in current.start.indices
            where current.dur[row] > longest[current.target[row]].map({ current.dur[$0] }) ?? -1 {
                longest[current.target[row]] = row
            }
            let always = Set(longest.values)
            let keep = current.start.indices.filter { current.onPath[$0] != 0 || current.dur[$0] >= threshold || always.contains($0) }
            guard keep.count < current.start.count else { continue }
            current = ReportBudget.Pass.thinned(current, keeping: keep, allMs: allMs)
            if compactSize(current) <= budget { break }
        }
        if compactSize(current) > budget {
            return (nil, .init(step: "taskIndex", kept: 0, total: index.taskIndexTotal, shownShare: nil))
        }
        return (current, .init(step: "taskIndex", kept: current.start.count, total: index.taskIndexTotal,
                               shownShare: current.taskIndexShownShare))
    }

    /// Floors of the compare tables: 25 rows each, the `other` row keeping the partition.
    private static func cutTables(_ document: inout CompareDocument) -> CompareDocument {
        func record(_ step: String, kept: Int, total: Int, share: Double?) {
            document.truncation.steps.removeAll { $0.step == step }
            document.truncation.steps.append(.init(step: step, kept: kept, total: total, shownShare: share))
        }
        if let rows = document.targets, rows.filter({ !$0.isOther }).count > 25 {
            let capped = CompareDiffs.capped(rows, keep: 25)
            document.targets = capped.rows
            document.targetsShownShare = capped.shownShare
            record("targets", kept: capped.rows.count, total: document.targetsTotal, share: capped.shownShare)
        }
        if document.tasks.added.count > 25 || document.tasks.removed.count > 25 {
            let added = CompareDiffs.capped(document.tasks.added, keep: 25)
            let removed = CompareDiffs.capped(document.tasks.removed, keep: 25)
            document.tasks.added = added.rows
            document.tasks.addedShownShare = added.share
            document.tasks.removed = removed.rows
            document.tasks.removedShownShare = removed.share
            record("tasks", kept: added.rows.count + removed.rows.count,
                   total: document.tasks.addedTotal + document.tasks.removedTotal, share: nil)
        }
        if let rows = document.settings, rows.count > 25 {
            document.settings = Array(rows.prefix(25))
            record("settings", kept: 25, total: rows.count, share: nil)
        }
        return document
    }
}

private extension ReportDocument.TruncationStep {
    func named(_ name: String) -> ReportDocument.TruncationStep { .init(step: name, kept: kept, total: total, shownShare: shownShare) }
}
