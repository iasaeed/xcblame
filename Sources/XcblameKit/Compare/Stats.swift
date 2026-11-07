import Foundation

/// Median and MAD as the noise model defines them (docs/SCHEMA-v0.4.md "Noise model"): the median of an even count is
/// the mean of the two middle values, MAD is unscaled.
enum Stats {
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let n = sorted.count
        return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
    }

    /// `median(|x_i - median(x)|)`; 0 for one value, nil for none.
    static func mad(_ values: [Double]) -> Double? {
        guard let middle = median(values) else { return nil }
        return median(values.map { abs($0 - middle) })
    }

    /// `sqrt((a² + b²) / 2)`.
    static func pooled(_ a: Double, _ b: Double) -> Double { ((a * a + b * b) / 2).squareRoot() }

    static func round6(_ value: Double) -> Double { ReportDocument.round6(value) }
}

/// The numbers of a report that regression, baseline and compare read.
extension ReportDocument {
    /// `timing.processWall` when every report has it, else `build.span` (`Regression.wallBasis`).
    static func wallBasis(of documents: [ReportDocument]) -> String {
        documents.allSatisfy { $0.timing.processWall != nil } ? "processWall" : "span"
    }

    func wall(basis: String) -> Double? { basis == "processWall" ? timing.processWall : build.span }

    /// `Mac15,14/28c/96g`: hardware model, logical cores, memory in GB; nil unless all three are known.
    var machineSummary: String? {
        guard let env = environment, let model = env.hwModel, let cores = env.logicalCPUCount,
              let memory = env.memoryBytes else { return nil }
        return "\(model)/\(cores)c/\(memory >> 30)g"
    }
}
