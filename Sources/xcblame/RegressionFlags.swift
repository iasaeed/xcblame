import ArgumentParser
import Foundation
import XcblameKit

/// `--baseline <file>` and `--fail-if-slower <pct>` of `analyze` and `build` (DESIGN §3.2, §6.10, docs/SCHEMA-v0.4.md
/// "Regression"). The flags are frozen here; Lane B fills what the commands do with them, inside their
/// `// v0.4 lane B` blocks.
struct RegressionFlags: ParsableArguments {
    @Option(help: "Compare this build with a baseline (.xcblame/baseline.json): adds the regression block to the report.",
            completion: .file(extensions: ["json"]))
    var baseline: String?
    @Option(name: .customLong("fail-if-slower"),
            help: "Exit 3 when the build is slower than the baseline by more than this percent (needs --baseline; with fewer than 3 runs per side a 5 percent allowance is added).")
    var failIfSlower: Double?

    func validate() throws {
        if let failIfSlower {
            if baseline == nil { throw ValidationError("--fail-if-slower needs --baseline <file>") }
            if failIfSlower < 0 || !failIfSlower.isFinite { throw ValidationError("--fail-if-slower must be 0 or greater") }
        }
    }

    /// `--fail-if-slower` as a fraction (5 means 0.05).
    var thresholdFraction: Double? { failIfSlower.map { $0 / 100 } }

    var baselineURL: URL? {
        baseline.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
    }

    var options: Regression.Options { Regression.Options(thresholdPct: thresholdFraction) }

    /// `--fail-if-slower` with a wall that has no delta (a baseline made by `build` checked against a log analyzed
    /// afterwards) can never fail: say so on stderr, the report's `regression.notes` has the reason.
    func warnIfNotComparable(_ result: ReportDocument.Regression?) {
        guard failIfSlower != nil, let result, result.wall.delta == nil else { return }
        writeStderr("warning: --fail-if-slower cannot fire: the wall is not comparable with the baseline's "
            + "(see regression.notes in the report)")
    }
}
