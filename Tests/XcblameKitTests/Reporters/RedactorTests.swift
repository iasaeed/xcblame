import Foundation
import XCTest
@testable import XcblameKit

final class RedactorTests: XCTestCase {
    private let context = Redactor.Context(home: "/Users/ann", user: "ann", host: "ann's-MBP.local",
                                           repoRoot: "/Users/ann/src/App", derivedDataHash: "qqqhashqqq")

    func testTokensReplaceEachKindOfSecret() {
        func r(_ s: String) -> String { Redactor.redact(string: s, context: context) }
        XCTAssertEqual(r("/Users/ann/src/App/Sources/A.swift"), "$REPO/Sources/A.swift")
        XCTAssertEqual(r("/Users/ann/Library/Logs"), "~/Library/Logs")
        XCTAssertEqual(r("/Users/ann/Library/Developer/Xcode/DerivedData/App-abcdefghijklmnopqrstuvwxyzab/Logs/Build"),
                       "~/Library/Developer/Xcode/DerivedData/App-$DDHASH/Logs/Build")
        XCTAssertEqual(r("/tmp/DerivedData/My-App-abcdefghijklmnopqrstuvwxyzab"), "/tmp/DerivedData/My-App-$DDHASH")
        XCTAssertEqual(r("on ann's-MBP.local and ann's-MBP"), "on $HOST and $HOST")
        XCTAssertEqual(r("by ann, planning by annie"), "by $USER, planning by annie", "word-bounded user")
        XCTAssertEqual(r("x qqqhashqqq y"), "x $DDHASH y")
        XCTAssertEqual(r("nothing here"), "nothing here")
    }

    /// Code review v0.2 #8: another user's home and a user name glued to digits are replaced too; `/Users/Shared`
    /// and words glued to letters stay.
    func testForeignHomesAndDigitGluedUserNamesAreReplaced() {
        func r(_ s: String) -> String { Redactor.redact(string: s, context: context) }
        XCTAssertEqual(r("/Users/runner/work/App/A.swift"), "/Users/$USER/work/App/A.swift")
        XCTAssertEqual(r("/home/ci/build and /Users/bob"), "/home/$USER/build and /Users/$USER")
        XCTAssertEqual(r("/Volumes/ann2/src"), "/Volumes/$USER2/src")
        XCTAssertEqual(r("/Users/Shared/x"), "/Users/Shared/x")
        XCTAssertEqual(r("annie ann_x"), "annie $USER_x")
        // Re-check R3: only where a path starts.
        XCTAssertEqual(r("https://example.com/Users/guide"), "https://example.com/Users/guide")
        XCTAssertEqual(r("/opt/home/builder/x"), "/opt/home/builder/x")
        XCTAssertEqual(r("-I/Users/bob/inc \"/home/ci/a\" x=/Users/eve (/Users/joe) [/home/kim,/home/lee:/Users/max]"),
                       "-I/Users/bob/inc \"/home/$USER/a\" x=/Users/$USER (/Users/$USER) [/home/$USER,/home/$USER:/Users/$USER]")
    }

    /// Regression (fail-open redaction): a NaN used to make the round trip fail and the document came back
    /// unredacted with only a stderr warning. Now the NaN becomes null with a note and the document is redacted.
    func testNonFiniteNumberIsNulledWithANoteAndTheDocumentIsStillRedacted() throws {
        var (doc, _) = try HTMLSample.populated(hostileStrings: false)
        doc.input.path = "/Users/ann/src/App/build.xcactivitylog"
        doc.timing.processWall = .nan
        doc.timing.outsideLogSeconds = .infinity
        let out = try Redactor.redact(doc, context: context)
        XCTAssertTrue(out.redacted)
        XCTAssertEqual(out.input.path, "$REPO/build.xcactivitylog")
        XCTAssertNil(out.timing.processWall)
        XCTAssertNil(out.timing.outsideLogSeconds)
        XCTAssertTrue(out.timing.notes.contains("timing.processWall: not a finite number (nan), reported as null"),
                      "\(out.timing.notes)")
        XCTAssertTrue(out.timing.notes.contains("timing.outsideLogSeconds: not a finite number (+inf), reported as null"))
        let json = try JSONReporter.renderString(out)
        XCTAssertFalse(json.contains("/Users/ann"), json)
    }

    /// A non-finite number where null is not allowed leaves nothing safe to write: redaction throws, it never hands
    /// back the unredacted document.
    func testUnsanitizableDocumentThrowsInsteadOfReturningItUnredacted() throws {
        var (doc, _) = try HTMLSample.populated(hostileStrings: false)
        doc.input.path = "/Users/ann/src/App/build.xcactivitylog"
        doc.targets?[0].taskTime = -.infinity
        XCTAssertNotNil(doc.targets?.first)
        XCTAssertThrowsError(try Redactor.redact(doc, context: context)) { error in
            guard case let .outputAborted(why) = error as? XcblameError else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("targets[0].taskTime"), why)
            XCTAssertFalse(why.contains("/Users/ann"), why)
        }
        XCTAssertThrowsError(try ReportPipeline.prepareForOutput(doc, redact: false, context: context))
    }

    /// Without --redact the same sanitizer runs: a NaN is null with a note, never a failed encode.
    func testPrepareForOutputSanitizesWithoutRedacting() throws {
        var (doc, _) = try HTMLSample.populated(hostileStrings: false)
        doc.input.path = "/Users/ann/src/App/build.xcactivitylog"
        doc.timing.processWall = .nan
        let out = try ReportPipeline.prepareForOutput(doc, redact: false, context: context)
        XCTAssertFalse(out.redacted)
        XCTAssertEqual(out.input.path, doc.input.path)
        XCTAssertNil(out.timing.processWall)
        XCTAssertNoThrow(try JSONReporter.render(out))
    }

    /// Code review v0.2 #10: the task index's target names and labels get the same tokens as the document.
    func testTaskIndexStringsAreRedacted() throws {
        var (_, index) = try HTMLSample.populated(hostileStrings: false)
        index.targets[0] = "ann"
        index.labels[0] = "CompileC /Users/ann/src/App/a.c on ann's-MBP"
        let out = Redactor.redact(index, context: context)
        XCTAssertEqual(out.targets[0], "$USER")
        XCTAssertEqual(out.labels[0], "CompileC $REPO/a.c on $HOST")
        XCTAssertEqual(out.start, index.start)
        XCTAssertEqual(out.kinds, index.kinds)
    }

    func testRedactWalksEveryStringAndKeepsNumbers() throws {
        var (doc, index) = try HTMLSample.populated(hostileStrings: false)
        _ = index
        doc.input.path = "/Users/ann/src/App/build.xcactivitylog"
        doc.notes = ["ann ran it on ann's-MBP"]
        doc.targets?[0].name = "ann"
        doc.timing.processWall = 12.345678
        let out = try Redactor.redact(doc, context: context)
        XCTAssertTrue(out.redacted)
        XCTAssertFalse(doc.redacted)
        XCTAssertEqual(out.input.path, "$REPO/build.xcactivitylog")
        XCTAssertEqual(out.notes, ["$USER ran it on $HOST"])
        XCTAssertEqual(out.targets?[0].name, "$USER")
        XCTAssertEqual(out.timing.processWall, 12.345678)
        XCTAssertEqual(out.criticalPath, doc.criticalPath)
        XCTAssertEqual(out.timing.utilization, doc.timing.utilization)
        XCTAssertEqual(out.generatedAt, doc.generatedAt)
        var expected = doc
        expected.redacted = true
        expected.input.path = out.input.path
        expected.notes = out.notes
        expected.targets?[0].name = "$USER"
        // The sample's other home (`/Users/sample`, not this context's user) loses its user name too.
        let json = try JSONReporter.renderString(expected).replacingOccurrences(of: "/Users/sample/", with: "/Users/$USER/")
        expected = try JSONReporter.decoder().decode(ReportDocument.self, from: Data(json.utf8))
        XCTAssertEqual(out, expected, "nothing else changes")
    }

    func testHostileHostNameIsReplacedCleanly() {
        let hostile = Redactor.Context(home: "/Users/o", user: "o'brien", host: "O'Brien's \"Mac\"</script>")
        XCTAssertEqual(Redactor.redact(string: "host O'Brien's \"Mac\"</script>, user o'brien", context: hostile),
                       "host $HOST, user $USER")
    }

    func testRepoRootIsTheNearestGitAncestorButNotHome() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-redact-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let nested = base.appendingPathComponent("repo/Sources/Deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("repo/.git"), withIntermediateDirectories: true)
        let root = Redactor.Context.gitRoot(from: nested.path, home: "/nowhere")
        XCTAssertEqual(root.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       base.appendingPathComponent("repo").resolvingSymlinksInPath().path)
        XCTAssertNil(Redactor.Context.gitRoot(from: nested.path, home: root ?? ""))
    }
}
