import XCTest
@testable import XcblameKit

/// DESIGN §12 item 9: redaction removes every home, user and host string. The CLI redacts the document before the
/// reporters see it (`markdown`, `github` and `agent` redact by default); these tests do the same with an explicit
/// context and look at what the formats print.
final class FormatsRedactionTests: XCTestCase {
    private func assertClean(_ text: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(text.contains("/Users/"), "\(label): home path", file: file, line: line)
        XCTAssertFalse(text.contains("ann-mbp"), "\(label): host name", file: file, line: line)
        XCTAssertNil(text.range(of: #"\bann\b"#, options: .regularExpression), "\(label): user name", file: file, line: line)
        XCTAssertFalse(text.contains(FormatsFixtures.repo), "\(label): repo root", file: file, line: line)
    }

    private func dirty() throws -> ReportDocument {
        var document = try FormatsFixtures.report()
        document.notes.append("path /Users/ann/Library/Developer/Xcode/DerivedData/App-abcdefghijklmnopqrstuvwxyzab/Build")
        document.findings[0].evidence.append("see /Users/ann/Work/App/project.pbxproj on ann-mbp")
        document.findings[0].fixCommands = ["cd /Users/ann/Work/App && xcblame fix"]
        document.regression?.baseline.ref = "/Users/ann/Work/App/.xcblame/baseline.json"
        document.regression?.attribution.append(.init(kind: "setting", subject: "App", detail: "set by /Users/ann/Work/App/a.xcconfig", deltaSeconds: 0.1))
        document.diagnostics[3].message = "ann's file /Users/ann/Work/App/Sources/W0.swift on ann-mbp"
        document.validation.notes.append("run by ann")
        return document
    }

    func testMarkdownGithubAndAgentCarryNoHomeUserOrHost() throws {
        let document = FormatsFixtures.redacted(try dirty())
        XCTAssertTrue(document.redacted)
        let options = FormatOptions(maxBytes: 64 * 1024, workspaceRoot: FormatsFixtures.repo)
        let markdown = try MarkdownReporter.render(document, options: options)
        let github = try GitHubReporter.render(document, options: options)
        let agent = try AgentReporter.render(document, options: FormatOptions(maxBytes: 8192, workspaceRoot: FormatsFixtures.repo))
        assertClean(markdown, "markdown")
        assertClean(github.body, "github body")
        assertClean(github.annotations.joined(separator: "\n"), "github annotations")
        assertClean(agent, "agent")
        // Whole-document renders (no caps) too, with every detail section.
        assertClean(try MarkdownReporter.render(document, options: FormatOptions(maxBytes: .max)), "markdown, uncapped")
        for text in [markdown, agent] {
            XCTAssertTrue(text.contains("$USER") || text.contains("$REPO") || text.contains("$HOST") || text.contains("~"), "tokens stand in")
        }
        XCTAssertTrue(markdown.contains("redacted</sub>"))
    }

    func testTheSameDocumentUnredactedShowsWhyRedactionIsTheDefault() throws {
        let text = try MarkdownReporter.render(try dirty(), options: FormatOptions(maxBytes: 64 * 1024))
        XCTAssertTrue(text.contains("/Users/ann") || text.contains("ann-mbp") || text.contains("ann/fix"))
    }

    func testDoctorAndCompareDocumentsRedactToo() throws {
        var doctor = FormatsFixtures.doctor()
        doctor.input.path = "/Users/ann/Work/App/App.xcodeproj"
        doctor.project?.container = "/Users/ann/Work/App/App.xcodeproj"
        doctor.notes.append("host ann-mbp, user ann")
        let redacted = FormatsFixtures.redacted(doctor)
        let options = FormatOptions(maxBytes: 64 * 1024)
        assertClean(try MarkdownReporter.render(redacted, options: options), "doctor markdown")
        assertClean(try AgentReporter.render(redacted, options: FormatOptions(maxBytes: 8192)), "doctor agent")

        var compare = V04Samples.compare
        compare.a.source = "/Users/ann/Work/App/a.json"
        compare.b.source = "/Users/ann/Work/App/b.json"
        compare.env = [.init(field: "branch", a: "ann/one", b: "ann/two"), .init(field: "commit", a: "ann-mbp", b: "x")]
        compare.notes = ["compared on ann-mbp by ann"]
        let compareRedacted = try Redactor.redact(compare, context: FormatsFixtures.context)
        assertClean(try MarkdownReporter.render(compareRedacted, options: options), "compare markdown")
    }

    // v0.4 integration: the origin's host is an identifier (a self-hosted remote is internal); branch and commit are not.
    func testRemoteHostIsRedactedButBranchAndCommitStay() throws {
        var document = try FormatsFixtures.report()
        document.environment?.git = GitInfo(branch: "feature/x", commit: String(repeating: "c", count: 40), dirty: false,
                                            remoteHost: "git.corp.internal")
        let redacted = FormatsFixtures.redacted(document)
        XCTAssertEqual(redacted.environment?.git?.remoteHost, "$REMOTE")
        XCTAssertEqual(redacted.environment?.git?.branch, "feature/x")
        XCTAssertEqual(redacted.environment?.git?.commit, String(repeating: "c", count: 40))
        XCTAssertEqual(document.environment?.git?.remoteHost, "git.corp.internal", "unredacted keeps it")

        var compare = V04Samples.compare
        compare.a.git = GitInfo(branch: "main", commit: String(repeating: "a", count: 40), dirty: false, remoteHost: "git.corp.internal")
        compare.b.git = compare.a.git
        let compareRedacted = try Redactor.redact(compare, context: FormatsFixtures.context)
        XCTAssertEqual(compareRedacted.a.git?.remoteHost, "$REMOTE")
        XCTAssertEqual(compareRedacted.b.git?.branch, "main")
    }

    func testJUnitCarriesNoHostEvenUnredacted() throws {
        var document = try dirty()
        document.environment?.git?.branch = "main"
        let xml = try JUnitReporter.render(document, options: FormatOptions(maxBytes: .max))
        XCTAssertFalse(xml.contains("ann-mbp"))
        XCTAssertFalse(xml.contains("/Users/"))
    }
}
