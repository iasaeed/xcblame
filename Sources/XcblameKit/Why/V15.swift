import Foundation

// v0.5 lane B (docs/SCHEMA-v0.5.md "V15"): Σ causes == executed task time.
public enum V15 {
    /// Absolute tolerance on the partition: rounding of 6-decimal seconds over many tasks.
    public static let toleranceSeconds = 0.001

    /// `incremental.v15` for causes summing to `sumOfCauses` against `executedSeconds`: `pass` when they agree within
    /// `toleranceSeconds`, `fail` when they do not, `skipped` when either side is unknown (timing withheld).
    public static func evaluate(sumOfCauses: Double?, executedSeconds: Double?) -> ReportDocument.Incremental.V15 {
        guard let sumOfCauses, let executedSeconds, sumOfCauses.isFinite, executedSeconds.isFinite else {
            return ReportDocument.Incremental.V15(status: "skipped", executedSeconds: executedSeconds,
                                                  sumOfCauses: sumOfCauses)
        }
        let status = abs(sumOfCauses - executedSeconds) <= toleranceSeconds ? "pass" : "fail"
        return ReportDocument.Incremental.V15(status: status, executedSeconds: executedSeconds, sumOfCauses: sumOfCauses)
    }
}
