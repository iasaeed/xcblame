import Foundation

/// `xcblame selftest`: runs analysis, validation and both reporters on the deterministic synthetic model and checks
/// the invariants the real pipeline relies on.
public enum SelfTest {
    public struct Outcome: Sendable {
        public var failures: [String]
        public var checksRun: Int
        public var passed: Bool { failures.isEmpty }

        /// The one-line result the CLI prints.
        public var summary: String {
            passed ? "selftest PASS (\(checksRun) checks)"
                : "selftest FAIL (\(failures.count) of \(checksRun) checks): " + failures.joined(separator: "; ")
        }
    }

    public static func run() -> Outcome {
        var failures: [String] = []
        var checks = 0
        func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
            checks += 1
            if !condition { failures.append(message()) }
        }

        let model = SyntheticModel.make()
        let options = ReportPipeline.Options(generatedAt: Date(timeIntervalSince1970: 1_700_000_100),
                                             inputPath: "synthetic")
        let result: ReportPipeline.Result
        do { result = try ReportPipeline.run(model, options: options) } catch {
            return Outcome(failures: ["pipeline threw: \(error)"], checksRun: 1)
        }

        for id in ["V1", "V2", "V6"] {
            expect(result.validation.status(id) == .pass, "\(id) is \(result.validation.status(id))")
        }
        let analysis = result.analysis
        expect(analysis.taskCount == model.tasks.count, "task count \(analysis.taskCount) != \(model.tasks.count)")
        expect(analysis.busy <= analysis.span && analysis.busy <= analysis.taskTime, "busy exceeds span or task time")
        expect(analysis.byKind.isPartition && analysis.byPhase.isPartition && analysis.byTarget.isPartition,
               "a rollup is not a partition")

        do {
            let first = try JSONReporter.render(result.document)
            let second = try JSONReporter.render(try ReportPipeline.run(model, options: options).document)
            expect(first == second, "JSON output is not byte-stable across runs")
            let decoded = try JSONReporter.decoder().decode(ReportDocument.self, from: first)
            expect(decoded == result.document, "JSON does not round-trip")
            expect(decoded.schemaVersion == ReportDocument.schemaVersion, "schema version mismatch")
        } catch {
            expect(false, "JSON encode/decode threw: \(error)")
        }

        let text = TextReporter.render(result.document)
        expect(text.contains("TIME") && text.contains("TARGETS") && text.contains("KINDS")
            && text.contains("TOP TASKS") && text.contains("checks "), "text report is missing a section")
        expect(!text.contains("\u{1B}["), "text report has color codes with colors off")
        return Outcome(failures: failures, checksRun: checks)
    }
}
