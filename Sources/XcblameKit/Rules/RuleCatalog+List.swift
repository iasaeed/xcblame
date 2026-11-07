import Foundation

extension RuleCatalog {
    /// `rules list` table: id, name, category, detection, apply kinds (`+V`), evidence tag; one row per rule.
    public static func listTable(_ specs: [RuleSpec]) -> String {
        let detection: [RuleSpec.Detection: String] = [.static: "S", .dynamic: "D", .both: "S+D", .info: "info"]
        let rows = [["ID", "NAME", "CAT", "DET", "APPLY", "EV"]] + specs.map { spec in
            [spec.id, spec.name, spec.category.prefix, detection[spec.detection] ?? "",
             spec.applyKinds.map(\.label).joined(separator: ", ") + (spec.verifyOnly ? " +V" : ""), spec.evidenceTag.text]
        }
        var widths = Array(repeating: 0, count: 6)
        for row in rows { for (index, cell) in row.enumerated() { widths[index] = max(widths[index], cell.count) } }
        return rows.map { row in
            row.enumerated().map { index, cell in
                index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }.joined(separator: "\n") + "\n"
    }
}
