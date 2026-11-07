import XCTest
@testable import XcblameKit

/// `--format github` (docs/SCHEMA-v0.4.md "github"): the markdown body plus workflow-command annotations.
final class FormatsGitHubTests: XCTestCase {
    private let options = FormatOptions(maxBytes: 64 * 1024, workspaceRoot: FormatsFixtures.repo)

    private func diag(_ severity: String, _ file: String?, _ line: Int? = 3, _ column: Int? = 4, message: String = "m",
                       occurrences: Int = 1) -> ReportDocument.DiagnosticEntry {
        .init(severity: severity, file: file, line: line, column: column, message: message, occurrences: occurrences)
    }

    func testBodyIsTheMarkdownBodyAndAnnotationsAreWorkflowCommands() throws {
        let document = try FormatsFixtures.report()
        let output = try GitHubReporter.render(document, options: options)
        XCTAssertEqual(output.body, try MarkdownReporter.render(document, options: options))
        XCTAssertFalse(output.annotations.isEmpty)
        for line in output.annotations {
            XCTAssertTrue(line.hasPrefix("::warning ") || line.hasPrefix("::error "), line)
            XCTAssertFalse(line.contains("\n"))
            XCTAssertTrue(line.contains(",title=xcblame") || line.hasPrefix("::warning title=xcblame") || line.hasPrefix("::error title=xcblame"), line)
        }
    }

    func testErrorAndWarningLinesHaveTheDocumentedShape() throws {
        let document = try FormatsFixtures.report()
        let lines = try GitHubReporter.render(document, options: options).annotations
        // Errors first, by occurrences descending, repo-relative, the root cut from the message too.
        XCTAssertEqual(lines[0], "::error file=Sources/E1.swift,line=4,col=4,title=xcblame::cannot find 'x1' in scope at Sources/E1.swift (x3)")
        XCTAssertEqual(lines[1], "::error file=Sources/E2.swift,line=5,col=4,title=xcblame::cannot find 'x2' in scope at Sources/E2.swift (x2)")
        XCTAssertEqual(lines[2], "::error file=Sources/E0.swift,line=3,col=4,title=xcblame::cannot find 'x0' in scope at Sources/E0.swift")
        XCTAssertEqual(lines[3], "::warning file=Sources/W0.swift,line=7,col=9,title=xcblame::variable 'w0' was never mutated; consider 'let'")
        XCTAssertTrue(lines.contains("::warning file=Sources/W3.swift,line=10,col=9,title=xcblame::variable 'w3' was never mutated; consider 'let' (x4)"))
        XCTAssertFalse(lines.contains { $0.contains("'w4'") }, "a warning without a file is not annotated")
        let hotspots = lines.filter { $0.contains("title=xcblame hotspot::") }
        XCTAssertFalse(hotspots.isEmpty)
        XCTAssertTrue(hotspots[0].range(of: #"^::warning file=Sources/[^,]+,line=\d+,col=5,title=xcblame hotspot::View0\.body0 400 ms \(type-check\)$"#, options: .regularExpression) != nil, hotspots[0])
        // The failed regression closes the warnings, file-less.
        XCTAssertEqual(lines.last, "::warning title=xcblame::build is slower than the baseline by +5.6 %25")
        // Errors come before warnings.
        let firstWarning = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("::warning") })
        XCTAssertFalse(lines[firstWarning...].contains { $0.hasPrefix("::error") })
    }

    func testRedactedDocumentGivesTheSameRepoRelativePaths() throws {
        let plain = try GitHubReporter.render(try FormatsFixtures.report(), options: options).annotations
        let redacted = try GitHubReporter.render(FormatsFixtures.redacted(try FormatsFixtures.report()),
                                                 options: FormatOptions(maxBytes: 64 * 1024, workspaceRoot: nil)).annotations
        XCTAssertEqual(plain, redacted)
    }

    func testNoAbsolutePathOrHomeEverLeavesInAnAnnotation() throws {
        var document = try FormatsFixtures.report()
        document.diagnostics = [
            diag("error", "/opt/other/A.swift"), diag("error", "~/Library/B.swift"), diag("error", "$HOST/C.swift"),
            diag("error", "../outside/D.swift"), diag("error", "/Users/ann/Work/App/Inside.swift", message: "in repo"),
            diag("warning", "/Users/ann/Work/Other/W.swift"), diag("warning", "Sources/Relative.swift"),
        ]
        document.diagnosticsSummary.errors = 5
        document.hotspots = [.init(file: "/Library/Developer/SDK.swift", line: 1, col: 1, declaration: "sdk", kind: "functionBody", ms: 900,
                                   source: "debugTimeFunctionBodies", onPathWeight: 1, occurrences: 1, target: nil, taskId: nil)]
        let lines = try GitHubReporter.render(document, options: options).annotations
        XCTAssertEqual(lines.filter { $0.hasPrefix("::error file=") }, ["::error file=Inside.swift,line=3,col=4,title=xcblame::in repo"])
        // An entry whose path cannot be repo-relative is never dropped: file-less, with the file name and line in the text.
        for name in ["A", "B", "C", "D"] {
            XCTAssertTrue(lines.contains("::error title=xcblame::\(name).swift:3: m"), "\(name): \(lines)")
        }
        XCTAssertTrue(lines.contains("::warning title=xcblame::W.swift:3: m"), "\(lines)")
        XCTAssertTrue(lines.contains("::warning file=Sources/Relative.swift,line=3,col=4,title=xcblame::m"))
        for line in lines {
            XCTAssertFalse(line.contains("/Users"), line)
            XCTAssertFalse(line.contains("file=/"), line)
            XCTAssertFalse(line.contains("file=~"), line)
            XCTAssertFalse(line.contains("file=$"), line)
            XCTAssertFalse(line.contains("Library/Developer"), "a hotspot outside the workspace is not user code")
        }
    }

    /// Code review v0.4 minor: `##[` is neutralized in the body and in every annotation message.
    func testRunnerCommandSyntaxIsEscapedInTheBodyAndAnnotations() throws {
        var document = try FormatsFixtures.report()
        document.diagnostics = [diag("error", "Sources/A.swift", message: "##[add-mask]secret ##[stop-commands]x"),
                                diag("warning", "Sources/B.swift", message: "see ##[group]")]
        document.diagnosticsSummary = DiagnosticsSummary(unique: 2, occurrences: 2, errors: 1, warnings: 1, analyzerWarnings: 0,
                                                         notices: 0, unknown: 0)
        let output = try GitHubReporter.render(document, options: options)
        XCTAssertFalse(output.body.contains("##["), "the markdown body")
        XCTAssertTrue(output.body.contains("##\\[add-mask]secret ##\\[stop-commands]x"), output.body)
        XCTAssertFalse(output.annotations.joined().contains("##["))
        XCTAssertTrue(output.annotations.contains("::error file=Sources/A.swift,line=3,col=4,title=xcblame::##\\[add-mask]secret ##\\[stop-commands]x"),
                      "\(output.annotations)")
        // Markdown on stdout is covered too (the escape is made where the text is, not in one reporter).
        XCTAssertFalse(try MarkdownReporter.render(document, options: options).contains("##["))
        // Escaping comes before fitting: a body at any cap stays within it and keeps its footer and closing tags whole.
        for cap in [900, 1_500, 2_500, 4_000] {
            let tight = try GitHubReporter.render(document, options: FormatOptions(maxBytes: cap, workspaceRoot: FormatsFixtures.repo))
            XCTAssertLessThanOrEqual(tight.body.utf8.count, cap)
            XCTAssertFalse(tight.body.contains("##["))
            XCTAssertEqual(tight.body.components(separatedBy: "<details>").count, tight.body.components(separatedBy: "</details>").count, "cap \(cap)")
            XCTAssertEqual(tight.body.components(separatedBy: "<sub>").count, tight.body.components(separatedBy: "</sub>").count, "cap \(cap)")
        }
    }

    /// Code review v0.4 re-check: `--format agent` prints diagnostic messages to stdout, `compare --format github|agent`
    /// prints the compare comment: none may carry a runner command.
    func testRunnerCommandsAreNeutralizedInAgentAndCompareText() throws {
        var document = try FormatsFixtures.report()
        document.diagnostics = [diag("error", "Sources/A.swift", message: "##[add-mask]secret")]
        document.diagnosticsSummary = DiagnosticsSummary(unique: 1, occurrences: 1, errors: 1, warnings: 0, analyzerWarnings: 0,
                                                         notices: 0, unknown: 0)
        let agent = try AgentReporter.render(document, options: options)
        XCTAssertTrue(agent.contains("##\\[add-mask]secret"), agent)
        XCTAssertFalse(agent.contains("##["))
        var compare = V04Samples.compare
        compare.targets = [.init(key: "##[add-mask]App", status: "changed", seconds: .init(a: 10, b: 11, delta: 1, deltaPct: 0.1),
                                 tasks: nil, isOther: false)]
        compare.targetsTotal = 1
        let comment = try MarkdownReporter.render(compare, options: options)
        XCTAssertTrue(comment.contains("##\\[add-mask]App"), comment)
        XCTAssertFalse(comment.contains("##["))
        XCTAssertEqual(FormatText.neutralizeRunnerCommands("::error::x ##[group]"), "\\::error::x ##\\[group]", "a leading :: too")
        XCTAssertEqual(FormatText.neutralizeRunnerCommands("a::b"), "a::b")
    }

    /// Code review v0.4 minor: a backslash-escaped backtick is not a code span delimiter.
    func testMentionSafeTreatsAnEscapedBacktickAsLiteral() {
        XCTAssertEqual(FormatText.mentionSafe("foo \\`@octocat\\` bar"), "foo \\``@octocat`\\` bar")
        XCTAssertEqual(FormatText.mentionSafe("`@octocat` stays, \\`@dev\\` does not"), "`@octocat` stays, \\``@dev`\\` does not")
        XCTAssertEqual(FormatText.mentionSafe("a `b \\` @octocat c` d"), "a `b \\` `@octocat` c` d",
                       "CommonMark: a backslash is literal inside a span, so the span closes at the backtick after it")
        XCTAssertEqual(FormatText.mentionSafe("``a ` @octocat`` and \\\\`@dev`"), "``a ` @octocat`` and \\\\`@dev`",
                       "a span closes only at a backtick string of its own length; an escaped backslash does not escape the tick")
        XCTAssertEqual(FormatText.mentionSafe("`open @octocat"), "`open `@octocat`", "an opener without a closer is plain text")
        XCTAssertEqual(FormatText.mentionSafe("no mention \\` here"), "no mention \\` here")
    }

    func testAnnotationMessagesWrapMentions() throws {
        var document = try FormatsFixtures.report()
        document.diagnostics = [diag("error", "\(FormatsFixtures.repo)/Sources/A.swift", message: "bad @octocat and @MainActor use")]
        document.diagnosticsSummary = DiagnosticsSummary(unique: 1, occurrences: 1, errors: 1, warnings: 0, analyzerWarnings: 0,
                                                         notices: 0, unknown: 0)
        let lines = try GitHubReporter.render(document, options: options).annotations
        XCTAssertEqual(lines[0], "::error file=Sources/A.swift,line=3,col=4,title=xcblame::bad `@octocat` and `@MainActor` use")
    }

    func testEscapingFollowsTheRunnersRules() {
        XCTAssertEqual(GitHubReporter.escapeData("100%\r\nnext: a,b"), "100%25%0D%0Anext: a,b")
        XCTAssertEqual(GitHubReporter.escapeProperty("a:b,c%\n"), "a%3Ab%2Cc%25%0A")
        var document = ReportDocument.sampleForFormats()
        document.diagnostics = [diag("warning", "Sources/A:B,C.swift", 1, 2, message: "50% done: really, 100%")]
        document.diagnosticsSummary.warnings = 1
        let lines = GitHubReporter.annotations(document, options: options)
        XCTAssertEqual(lines, ["::warning file=Sources/A%3AB%2CC.swift,line=1,col=2,title=xcblame::50%25 done: really, 100%25"])
    }

    func testAtMostTenOfEachKindDedupedAndTheRegressionLineIsReserved() throws {
        var document = try FormatsFixtures.report()
        document.hotspots = []
        document.diagnostics = (0..<30).map { diag("error", "Sources/E\($0).swift", $0 + 1) }
            + (0..<30).map { diag("warning", "Sources/W\($0).swift", $0 + 1) }
            + [diag("error", "Sources/E0.swift", 1), diag("warning", "Sources/W0.swift", 1)]
        document.diagnosticsSummary.errors = 31
        let lines = try GitHubReporter.render(document, options: options).annotations
        XCTAssertEqual(lines.filter { $0.hasPrefix("::error") }.count, 10 + 0, "ten errors; the file-less summary is among them")
        XCTAssertEqual(lines.filter { $0.hasPrefix("::warning") }.count, 10)
        XCTAssertEqual(Set(lines).count, lines.count, "deduped")
        XCTAssertEqual(lines.filter { $0.contains("Sources/E0.swift") }.count, 1)
        XCTAssertEqual(lines.last, "::warning title=xcblame::build is slower than the baseline by +5.6 %25", "kept inside the cap of ten")
        XCTAssertTrue(lines.contains { $0.hasPrefix("::error title=xcblame::") }, "the errors beyond the cap are summarized")
        document.regression = nil
        XCTAssertEqual(try GitHubReporter.render(document, options: options).annotations.filter { $0.hasPrefix("::warning") }.count, 10)
    }

    func testSlowHotspotsOnlyAndDoctorDocumentsHaveNone() throws {
        var document = try FormatsFixtures.report()
        document.diagnostics = []
        document.diagnosticsSummary.errors = 0
        document.regression = nil
        document.hotspots = [
            .init(file: "Sources/Fast.swift", line: 1, col: 1, declaration: "fast", kind: "functionBody", ms: 99, source: "debugTimeFunctionBodies",
                  onPathWeight: 1, occurrences: 1, target: nil, taskId: nil),
            .init(file: "Sources/Slow.swift", line: 2, col: 3, declaration: "slow()", kind: "functionBody", ms: 100, source: "debugTimeFunctionBodies",
                  onPathWeight: 1, occurrences: 1, target: nil, taskId: nil),
        ]
        XCTAssertEqual(GitHubReporter.annotations(document, options: options),
                       ["::warning file=Sources/Slow.swift,line=2,col=3,title=xcblame hotspot::slow() 100 ms (type-check)"])
        XCTAssertEqual(GitHubReporter.annotations(FormatsFixtures.doctor(), options: options), [])
    }

    func testPathHelpers() {
        let root = "/Users/ann/Work/App"
        XCTAssertEqual(FormatText.repoRelative("$REPO/Sources/A.swift", workspaceRoot: nil), "Sources/A.swift")
        XCTAssertEqual(FormatText.repoRelative("\(root)/Sources/A.swift", workspaceRoot: root), "Sources/A.swift")
        XCTAssertEqual(FormatText.repoRelative("\(root)/Sources/A.swift", workspaceRoot: root + "/"), "Sources/A.swift")
        XCTAssertEqual(FormatText.repoRelative("./Sources/A.swift", workspaceRoot: root), "Sources/A.swift")
        XCTAssertNil(FormatText.repoRelative("\(root)/Sources/A.swift", workspaceRoot: nil))
        XCTAssertNil(FormatText.repoRelative("\(root)2/A.swift", workspaceRoot: root), "a sibling folder is not the workspace")
        XCTAssertNil(FormatText.repoRelative("$REPO/../x.swift", workspaceRoot: nil))
        XCTAssertNil(FormatText.repoRelative("$REPO/", workspaceRoot: nil))
    }
}

extension ReportDocument {
    /// The synthetic pipeline report, for the tests that only need a valid document.
    static func sampleForFormats() -> ReportDocument {
        // swiftlint:disable:next force_try
        try! ReportPipeline.run(SyntheticModel.make(), options: .init(generatedAt: Date(timeIntervalSince1970: 0))).document
    }
}
