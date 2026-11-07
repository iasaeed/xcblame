import Foundation

/// `xcblame trend --format text`: one compact table per group, wall time (`build.span`) per build kind.
public enum TrendTextReporter {
    public static func render(_ document: TrendDocument) -> String {
        var lines: [String] = []
        lines.append("xcblame trend: \(document.entriesUsed) of \(document.entriesTotal) history entries")
        if let filter = filterLine(document.filter) { lines.append(filter) }
        for group in document.groups {
            lines.append("")
            let title = group.key.map { label($0, by: document.filter.by) } ?? "all builds"
            lines.append("\(document.filter.by.map { "\($0.rawValue) " } ?? "")\(title): \(group.entries) "
                + (group.entries == 1 ? "entry" : "entries"))
            lines += table(group)
            for series in group.series {
                for marker in series.xcodeChangeMarkers {
                    lines.append("  \(series.kind): Xcode \(marker.from ?? "?") -> \(marker.to ?? "?") at \(marker.atId)")
                }
            }
        }
        if !document.notes.isEmpty {
            lines.append("")
            lines.append("NOTES")
            lines += document.notes.map { "- \($0)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A commit is shown by its short hash; everything else as is.
    static func label(_ key: String, by: TrendDocument.By?) -> String {
        by == .commit && key != Trend.unknownKey ? String(key.prefix(8)) : key
    }

    private static func filterLine(_ filter: TrendDocument.Filter) -> String? {
        var parts: [String] = []
        if let kind = filter.kind { parts.append("kind \(kind)") }
        if let scheme = filter.scheme { parts.append("scheme \(scheme)") }
        if let since = filter.since { parts.append("since \(ISO8601DateFormatter().string(from: since))") }
        if let by = filter.by { parts.append("by \(by.rawValue)") }
        return parts.isEmpty ? nil : "filter: " + parts.joined(separator: ", ")
    }

    private static func table(_ group: TrendDocument.Group) -> [String] {
        func cell(_ text: String, _ width: Int, right: Bool = true) -> String {
            let pad = String(repeating: " ", count: max(0, width - text.count))
            return right ? pad + text : text + pad
        }
        func time(_ value: Double?) -> String { value.map(TextReporter.duration) ?? "-" }
        let rows: [[String]] = group.series.map { series in
            let last = series.points.last(where: { $0.wall != nil })?.wall
            return [series.kind, String(series.wall.n), time(series.wall.p50), time(series.wall.p75),
                    time(series.wall.p95), time(last), arrow(series.points)]
        }
        let header = ["KIND", "N", "P50", "P75", "P95", "LAST", "TREND (last 5 vs previous 5)"]
        let widths = header.indices.map { column in ([header[column]] + rows.map { $0[column] }).map(\.count).max() ?? 0 }
        func line(_ row: [String]) -> String {
            "  " + row.indices.map { cell(row[$0], widths[$0], right: $0 != 0 && $0 != 6) }.joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }
        return [line(header)] + rows.map(line)
    }

    /// `↑ +8.0 %` slower, `↓ -8.0 %` faster, `→ +0.5 %` within 2 %, `-` without a window to compare against.
    static func arrow(_ points: [TrendDocument.Point]) -> String {
        guard let change = Trend.recentChange(points) else { return "-" }
        let symbol = change.change > 0.02 ? "↑" : change.change < -0.02 ? "↓" : "→"
        return symbol + String(format: " %+.1f %%", change.change * 100)
    }
}
