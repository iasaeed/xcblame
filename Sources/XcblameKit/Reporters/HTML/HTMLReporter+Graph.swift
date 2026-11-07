import Foundation

// v0.5 lane C (docs/SCHEMA-v0.5.md "HTML views"): the module-graph step of the budget (DESIGN §8.2.3 step 4).
extension HTMLReporter {
    /// `graph` with nodes outside the critical chain and its direct neighbours collapsed into one node per owner, so
    /// at most `keep` plain nodes remain (floor: the critical chain). Totals unchanged.
    static func collapsedModuleGraph(_ graph: ReportDocument.ModuleGraph, keep: Int) -> ReportDocument.ModuleGraph {
        ModuleGraph.collapsed(graph, keep: keep)
    }
}
