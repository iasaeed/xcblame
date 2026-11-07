import XCTest
@testable import XcblameKit

/// Documents for the v0.4 format tests: the populated synthetic report (paths under `/Users/ann/Work/App`) with a
/// regression, diagnostics, git info and a build context; a doctor document; a 500-target document.
enum FormatsFixtures {
    static let context = Redactor.Context(home: "/Users/ann", user: "ann", host: "ann-mbp", repoRoot: "/Users/ann/Work/App")
    static let repo = "/Users/ann/Work/App"

    static func diagnostics(errors: Int, warnings: Int) -> [ReportDocument.DiagnosticEntry] {
        (0..<errors).map { i in
            .init(severity: "error", file: "\(repo)/Sources/E\(i).swift", line: 3 + i, column: 4,
                  message: "cannot find 'x\(i)' in scope at \(repo)/Sources/E\(i).swift", occurrences: 1 + (errors - i) % 3)
        } + (0..<warnings).map { i in
            .init(severity: "warning", file: i % 5 == 4 ? nil : "\(repo)/Sources/W\(i).swift", line: 7 + i, column: 9,
                  message: "variable 'w\(i)' was never mutated; consider 'let'", occurrences: 1 + i % 4)
        }
    }

    static func report(hostile: Bool = false,
                       regression: ReportDocument.Regression? = V04Samples.regression) throws -> ReportDocument {
        var (doc, _) = try HTMLSample.populated(hostileStrings: hostile)
        doc.input = .init(reader: "slf", layout: "commandLine", logFormatVersion: 11, path: "\(repo)/build.xcactivitylog",
                          decodeWarnings: 0, excludedActions: [])
        doc.build.scheme = "App"
        doc.build.configuration = "Debug"
        doc.build.destination = "macOS arm64"
        doc.xcode = .init(value: "26.0", source: "inferred", evidence: [], notes: [])
        doc.regression = regression
        doc.diagnostics = diagnostics(errors: 3, warnings: 6)
        doc.diagnosticsTotal = 9
        doc.diagnosticsShownShare = 1
        doc.diagnosticsSummary = DiagnosticsSummary(unique: 9, occurrences: 20, errors: 3, warnings: 6, analyzerWarnings: 0,
                                                    notices: 0, unknown: 0)
        var env = EnvSnapshot()
        env.macOSProductVersion = "26.0"
        env.hwModel = "Mac15,14"
        env.logicalCPUCount = 28
        env.memoryBytes = 96 << 30
        env.git = GitInfo(branch: "ann/fix", commit: String(repeating: "a", count: 40), dirty: true, remoteHost: "github.com")
        doc.environment = env
        doc.notes.append("built on ann-mbp by ann")
        doc.findings[0].fixCommands = ["xcblame verify --rules SET-016"]
        doc.findings[0].evidence = ["Debug: explicit modules off", "App: SWIFT_ENABLE_EXPLICIT_MODULES = NO", "CoreKit: same"]
        let old = "/Users/sample/Projects/App"
        doc.files = doc.files?.map { row in
            var row = row
            row.path = row.path.replacingOccurrences(of: old, with: repo)
            row.members = nil
            return row
        }
        doc.hotspots = doc.hotspots?.map { row in
            var row = row
            row.file = row.file.replacingOccurrences(of: old, with: repo)
            return row
        }
        return doc
    }

    static func redacted(_ doc: ReportDocument) -> ReportDocument { try! Redactor.redact(doc, context: context) }

    static func doctor() -> ReportDocument { HTMLSample.doctor(hostileStrings: false) }

    /// 500 targets, many findings, 100 diagnostics, long titles: the document the size caps are tested on.
    static func large() throws -> ReportDocument {
        let model = SyntheticModel.large(taskCount: 4_000, targets: 500)
        var doc = try ReportPipeline.run(model, options: .init(topN: 1_000, generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                                               inputPath: "\(repo)/big.xcactivitylog")).document
        doc.regression = V04Samples.regression
        doc.diagnostics = diagnostics(errors: 40, warnings: 60)
        doc.diagnosticsTotal = 100
        doc.diagnosticsSummary = DiagnosticsSummary(unique: 100, occurrences: 200, errors: 40, warnings: 60,
                                                    analyzerWarnings: 0, notices: 0, unknown: 0)
        doc.findings = (0..<30).map { i in
            .init(ruleId: "SET-\(100 + i)", title: String(repeating: "Long finding title \(i) ", count: 20), severity: "medium",
                  impactBand: "M", impactSeconds: 1, impactBasis: "pathShare", confidence: "high",
                  evidence: (0..<5).map { "evidence \($0) " + String(repeating: "x", count: 400) }, fixKind: "cli", risk: "low",
                  mechanism: nil, signalKey: "k\(i)", fixCommands: ["xcblame fix SET-\(100 + i) " + String(repeating: "y", count: 400)])
        }
        doc.findingsTotal = 30
        return doc
    }
}
