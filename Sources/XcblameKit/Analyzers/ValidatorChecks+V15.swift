import Foundation

// v0.5 lane B (docs/SCHEMA-v0.5.md "V15"): the Validator row of `incremental.v15`.
extension Validator {
    /// V15 recomputed from `incremental.causes` against `executedSeconds` (`build.taskTime`): `pass`, `fail` (the
    /// partition is off by more than `V15.toleranceSeconds`; degrades the report, §6.11), or `notApplicable` without
    /// incremental attribution (clean builds, doctor) or without executed task time (timing withheld).
    public static func checkV15(_ incremental: ReportDocument.Incremental?, executedSeconds: Double?) -> Check {
        guard let incremental else {
            return notApplicable("V15", why: "no incremental causes in this report (a clean build re-runs everything, so "
                + "there is nothing to attribute)")
        }
        let sum = incremental.causes.reduce(0) { $0 + $1.seconds }
        let result = V15.evaluate(sumOfCauses: sum, executedSeconds: executedSeconds ?? incremental.v15.executedSeconds)
        let detail = "\(incremental.causes.count) causes sum to \(format(sum)) s of \(format(result.executedSeconds)) s "
            + "executed task time (tolerance \(format(V15.toleranceSeconds)) s)"
        switch result.status {
        case "pass": return Check(id: "V15", title: titles["V15"] ?? "V15", status: .pass, note: detail)
        case "fail": return Check(id: "V15", title: titles["V15"] ?? "V15", status: .fail(detail))
        default: return notApplicable("V15", why: "skipped: executed task time unknown (timing withheld)")
        }
    }

    private static func format(_ seconds: Double?) -> String {
        seconds.map { String(format: "%.3f", $0) } ?? "unknown"
    }
}
