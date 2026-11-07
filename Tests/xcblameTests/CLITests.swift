import Foundation
import XCTest
import XcblameKit

/// Runs the built `xcblame` binary (it sits next to the test bundle) and checks exit codes and output.
final class CLITests: XCTestCase {
    struct Run {
        var status: Int32
        var out: String
        var err: String
    }

    private var binary: URL {
        Bundle(for: CLITests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("xcblame")
    }

    /// `analyze` gets a throwaway `--xcblame-dir` (history and reports are real, and would land in the `swift test`
    /// working directory) unless the arguments name one or `isolateState` is false.
    private func run(_ arguments: [String], environment overrides: [String: String] = [:],
                     isolateState: Bool = true) throws -> Run {
        var arguments = arguments
        if isolateState, arguments.first == "analyze", !arguments.contains("--xcblame-dir") {
            let state = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-state-\(UUID().uuidString)")
            addTeardownBlock { try? FileManager.default.removeItem(at: state) }
            arguments += ["--xcblame-dir", state.path]
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["CI"] = nil
        env["NO_COLOR"] = "1"
        // The settings oracle's cache home: a throwaway folder per call, never ~/Library/Caches and never state shared
        // with other tests or earlier runs. A shared home let the doctor tests leave package checkouts that made a
        // later `analyze --project` run a real xcodebuild against its 5 s cap (a cold home goes offline at once, so
        // the findings do not depend on how loaded the machine is).
        let cacheHome = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheHome) }
        env["XCBLAME_CACHE_DIR"] = cacheHome.path
        env.merge(overrides) { $1 }
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                   err: String(decoding: errData, as: UTF8.self))
    }

    private func dumpModel() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-model-\(UUID().uuidString).json")
        try JSONEncoder().encode(SyntheticModel.make()).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testSelfTestExitsZeroAndPrintsPass() throws {
        let result = try run(["selftest"])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.hasPrefix("selftest PASS"), result.out)
    }

    func testVersionKeepsItsFormat() throws {
        let result = try run(["version"])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.out, "xcblame \(XcblameVersion.current) (kind table \(KindTable.v1.version))\n")
    }

    func testAnalyzeModelJSONTextFormat() throws {
        let result = try run(["analyze", "--model-json", try dumpModel().path, "--format", "text", "--top", "5"])
        XCTAssertEqual(result.status, 0, result.err)
        for section in ["TIME", "CRITICAL PATH", "TARGETS", "KINDS", "TOP TASKS", "DIAGNOSTICS", "checks 12 pass"] {
            XCTAssertTrue(result.out.contains(section), "\(section) missing:\n\(result.out)")
        }
        XCTAssertFalse(result.out.contains("\u{1B}["))
    }

    func testAnalyzeModelJSONValidatesItsOwnInvariants() throws {
        let result = try run(["analyze", "--model-json", try dumpModel().path, "--format", "json"])
        XCTAssertEqual(result.status, 0, result.err)
        let doc = try JSONReporter.decoder().decode(ReportDocument.self, from: Data(result.out.utf8))
        XCTAssertEqual(doc.schemaVersion, "xcblame.report/1")
        for id in ["V1", "V2", "V5", "V6", "V7", "V8", "V10", "V13", "V14"] {
            XCTAssertEqual(doc.validation.checks.first { $0.id == id }?.status, "pass", id)
        }
        let taskTime = try XCTUnwrap(doc.build.taskTime)
        let kinds = try XCTUnwrap(doc.kinds)
        XCTAssertEqual(kinds.reduce(0) { $0 + $1.taskTime }, taskTime, accuracy: 1e-4)
        XCTAssertEqual(kinds.reduce(0) { $0 + $1.tasks }, doc.build.tasks)
        XCTAssertEqual(try XCTUnwrap(doc.phases).reduce(0) { $0 + $1.taskTime }, taskTime, accuracy: 1e-4)
        XCTAssertLessThanOrEqual(try XCTUnwrap(doc.build.busy), try XCTUnwrap(doc.build.span))
        XCTAssertLessThanOrEqual(try XCTUnwrap(doc.build.busy), taskTime)
        XCTAssertEqual(doc.input.path.map { URL(fileURLWithPath: $0).pathExtension }, "json")
    }

    func testOutputFileGetsTheReportAndStdoutAOneLineSummary() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-out-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let result = try run(["analyze", "--model-json", try dumpModel().path, "--format", "json", "-o", file.path])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertEqual(result.out.split(separator: "\n").count, 1, result.out)
        XCTAssertTrue(result.out.hasPrefix("wrote "), result.out)
        let doc = try JSONReporter.decoder().decode(ReportDocument.self, from: try Data(contentsOf: file))
        XCTAssertEqual(doc.build.tasks, 50)
    }

    func testRedactMarksTheReportWithoutANote() throws {
        let result = try run(["analyze", "--model-json", try dumpModel().path, "--redact", "--format", "json"])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertFalse(result.err.contains("not redacted"), result.err)
        XCTAssertFalse(result.err.contains("--redact is not implemented"), result.err)
        XCTAssertTrue(try JSONReporter.decoder().decode(ReportDocument.self, from: Data(result.out.utf8)).redacted)
    }

    /// `--redact` rewrites text and json output too, with no stale "not implemented" note.
    func testRedactCleansTextAndJSONOfARealLog() throws {
        let plain = try run(["analyze", Self.clean26, "--format", "json", "--no-history"])
        XCTAssertEqual(plain.status, 0, plain.err)
        XCTAssertTrue(plain.out.contains("/Users/") || plain.out.contains("/home/"), "the fixture carries home paths")
        for format in ["json", "text"] {
            let result = try run(["analyze", Self.clean26, "--format", format, "--redact", "--no-history"])
            XCTAssertEqual(result.status, 0, result.err)
            // The fixture's home is another account's (fixtures/ANONYMIZATION.md), so it becomes `/Users/$USER`, not `~`:
            // no account name may survive after any `/Users/`.
            let named = result.out.components(separatedBy: "/Users/").dropFirst().filter { !$0.hasPrefix("$USER") }
            XCTAssertEqual(named.count, 0, "\(format): \(result.out)")
            XCTAssertFalse(result.err.contains("not implemented") || result.err.contains("NOT redacted"), result.err)
        }
    }

    func testMissingPathExitsFive() throws {
        let result = try run(["analyze", "/definitely/not/here.xcactivitylog"])
        XCTAssertEqual(result.status, 5, result.err)
        XCTAssertTrue(result.err.contains("not found"), result.err)
    }

    func testMissingModelJSONExitsFive() throws {
        XCTAssertEqual(try run(["analyze", "--model-json", "/definitely/not/here.json"]).status, 5)
    }

    func testBogusFlagExitsTwo() throws {
        let result = try run(["analyze", "--bogus"])
        XCTAssertEqual(result.status, 2, result.err)
        XCTAssertEqual(try run(["analyze", "--format", "sarif"]).status, 2)
        XCTAssertEqual(try run(["analyze", "--top", "0"]).status, 2)
        XCTAssertEqual(try run(["nonsense"]).status, 2)
    }

    func testFolderWithoutBuildLogsExitsFiveWithTheHint() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: empty) }
        let result = try run(["analyze", empty.path])
        XCTAssertEqual(result.status, 5, result.err)
        XCTAssertTrue(result.err.contains("no build log found"), result.err)
        XCTAssertTrue(result.err.contains(Locator.noLogHint), result.err)
    }

    func testBrokenModelJSONExitsFive() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-bad-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try run(["analyze", "--model-json", url.path]).status, 5)
    }

    func testFailedValidationExitsOneButStillPrintsTheReport() throws {
        var model = SyntheticModel.make()
        // JSON cannot hold NaN, so a negative duration stands in for the invalid value.
        model.tasks[0].duration = -1
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-v1-\(UUID().uuidString).json")
        try JSONEncoder().encode(model).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let result = try run(["analyze", "--model-json", url.path, "--format", "json"])
        XCTAssertEqual(result.status, 1, result.err)
        let doc = try JSONReporter.decoder().decode(ReportDocument.self, from: Data(result.out.utf8))
        XCTAssertNil(doc.build.taskTime)
        XCTAssertEqual(doc.validation.checks.first { $0.id == "V1" }?.status, "fail")
    }

    // MARK: - Real fixtures, end to end

    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/logs")
    private static let cli26 = fixtures.appendingPathComponent("cli-xcode26")
    private static let clean26 = cli26.appendingPathComponent("20E8B73D-96FE-4232-8A33-311BFD02F961.xcactivitylog").path
    private static let incremental26 = "D822889B-3D9A-478F-BB03-AB98C3967FD1.xcactivitylog"
    private static let clean27 = fixtures.appendingPathComponent(
        "cli-xcode27.1b/21F7B51C-4B90-49D4-B328-EDA168F7A9A5.xcactivitylog").path

    private func report(_ arguments: [String]) throws -> ReportDocument {
        let result = try run(["analyze"] + arguments + ["--format", "json"])
        XCTAssertEqual(result.status, 0, result.err)
        return try JSONReporter.decoder().decode(ReportDocument.self, from: Data(result.out.utf8))
    }

    func testAnalyzeCleanXcode26LogJSON() throws {
        let doc = try report([Self.clean26, "--no-env"])
        XCTAssertEqual(doc.schemaVersion, "xcblame.report/1")
        XCTAssertEqual(doc.build.tasks, 577)
        XCTAssertEqual(doc.input.reader, "slf")
        XCTAssertEqual(doc.input.logFormatVersion, 11)
        XCTAssertEqual(doc.xcode.value, "26.0")
        XCTAssertEqual(doc.xcode.source, "inferred")
        XCTAssertFalse(doc.xcode.evidence.isEmpty)
        XCTAssertNil(doc.environment, "--no-env")
        XCTAssertEqual(doc.build.kind, "clean", "build kind lands in v0.2")
        let swiftCompile = try XCTUnwrap(try XCTUnwrap(doc.kinds).first { $0.key == "swiftCompile" })
        XCTAssertEqual(swiftCompile.taskTime, 109.343, accuracy: 0.001)
        XCTAssertEqual(doc.validation.checks.filter { $0.status == "fail" }.count, 0)
    }

    /// Code review v0.2 #1: B3F9A630 with a task end (and the root end, and a ±1.7e308 root) patched to extreme
    /// doubles. Every format, with history on, exits 0; the task is invalid, nothing traps.
    func testExtremeTimesInARealLogNeverTrap() throws {
        let source = Self.fixtures.appendingPathComponent(
            "cli-xcode26-dd3/B3F9A630-E7E7-4CB9-BABA-A141351BD516.xcactivitylog")
        let inflated = String(decoding: try GzipFile.inflate(contentsOf: source).bytes, as: UTF8.self)
        func hex(_ value: Double) -> String {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { $0.map { String(format: "%02x", $0) }.joined() }
        }
        let cases: [(String, [(String, Double)])] = [
            ("task", [("3d10e9833b4bc841", 1e300)]),
            ("root", [("3d10e9833b4bc841", 1e300), ("87f916843b4bc841", 1e300)]),
            ("overflow", [("2768d7833b4bc841", -1.7e308), ("87f916843b4bc841", 1.7e308)]),
        ]
        for (name, patches) in cases {
            var text = inflated
            for (old, value) in patches {
                let range = try XCTUnwrap(text.range(of: old + "^"), old)
                text.replaceSubrange(range, with: hex(value) + "^")
            }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-extreme-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
            let log = dir.appendingPathComponent("B3F9A630-E7E7-4CB9-BABA-A141351BD516.xcactivitylog")
            try Data(text.utf8).write(to: log)
            for format in ["text", "json", "html"] {
                let result = try run(["analyze", log.path, "--no-env", "--format", format, "-o",
                                      dir.appendingPathComponent("out.\(format)").path])
                XCTAssertEqual(result.status, 0, "\(name) \(format): \(result.err)")
            }
            if name == "task" {
                let doc = try JSONReporter.decoder().decode(ReportDocument.self,
                                                            from: Data(contentsOf: dir.appendingPathComponent("out.json")))
                XCTAssertEqual(doc.build.tasksInvalid, 1)
            }
        }
    }

    /// Code review v0.3 #12: under `analyze`, ENV findings say they describe this machine, not the log's builder.
    func testAnalyzeLabelsEnvironmentFindingsAsThisMachine() throws {
        let project = Self.fixtures.deletingLastPathComponent().appendingPathComponent("projects/AcmeLegacy/AcmeLegacy.xcodeproj")
        let doc = try report([Self.clean26, "--project", project.path, "--offline", "--no-history"])
        let env = doc.findings.filter { $0.ruleId.hasPrefix("ENV-") }
        for finding in env {
            XCTAssertTrue(finding.title.hasSuffix("(this machine, not necessarily the one that built the log)"), finding.title)
        }
        XCTAssertTrue(doc.findings.contains { !$0.ruleId.hasPrefix("ENV-") }, "project findings are not labelled")
        XCTAssertFalse(doc.findings.contains { !$0.ruleId.hasPrefix("ENV-") && $0.title.contains("this machine") })
    }

    func testOutputToDevNullWorks() throws {
        let result = try run(["analyze", Self.clean26, "--format", "json", "-o", "/dev/null"])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.hasPrefix("wrote /dev/null"), result.out)
    }

    func testAnalyzeCapturesTheEnvironmentByDefault() throws {
        let doc = try report([Self.clean26])
        XCTAssertNotNil(doc.environment?.macOSProductVersion)
        XCTAssertNotNil(doc.environment?.logicalCPUCount)
    }

    func testAnalyzeCleanXcode26LogText() throws {
        let result = try run(["analyze", Self.clean26, "--format", "text", "--no-env"])
        XCTAssertEqual(result.status, 0, result.err)
        for expected in ["TARGETS", "AcmeApp", "LocalizeCore", "SwiftSyntax", "in 577 tasks", "xcode   26.0 (inferred: ",
                         "swiftCompile", "109.3 s"] {
            XCTAssertTrue(result.out.contains(expected), "\(expected) missing:\n\(result.out)")
        }
    }

    func testAnalyzeXcode27LogInfersTheDotOneRelease() throws {
        let doc = try report([Self.clean27, "--no-env"])
        XCTAssertEqual(doc.build.tasks, 587)
        XCTAssertEqual(doc.input.logFormatVersion, 13)
        XCTAssertEqual(doc.xcode.value, "27.1")
        XCTAssertTrue(doc.xcode.evidence.first?.hasPrefix("log format version 13") == true, "\(doc.xcode.evidence)")
    }

    func testAnalyzeXCResultBuildLogJSONReportsTheBuildAction() throws {
        let doc = try report([Self.cli26.appendingPathComponent("xcresult-buildlog.json.gz").path, "--no-env"])
        XCTAssertEqual(doc.input.reader, "xcresult")
        XCTAssertEqual(doc.input.layout, "xcresult")
        XCTAssertNil(doc.input.logFormatVersion)
        XCTAssertEqual(doc.build.tasks, 577, "the build action, as the SLF log of the same build")
        XCTAssertEqual(doc.input.excludedActions.count, 1, "the clean action (3 planning tasks) is noted")
        XCTAssertEqual(try XCTUnwrap(doc.build.span), 18.14, accuracy: 0.01)
        XCTAssertEqual(doc.xcode.value, "26.0")
    }

    /// The manifest's newest build-log candidate is the 1.6 s incremental build recorded after the clean build; it has
    /// executed tasks, so it wins over the clean build (index 1). The Cleaning action's log (index 2) is never chosen.
    func testFolderSelectsTheNewestBuildLogConfirmedByContent() throws {
        let result = try run(["analyze", Self.cli26.path, "--format", "json", "--no-env"])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.err.contains("selected \(Self.incremental26) (candidate 0 of 3"), result.err)
        let doc = try JSONReporter.decoder().decode(ReportDocument.self, from: Data(result.out.utf8))
        XCTAssertEqual(doc.input.path.map { URL(fileURLWithPath: $0).lastPathComponent }, Self.incremental26)
        XCTAssertEqual(doc.build.tasks, 18)
        XCTAssertEqual(doc.build.tasksReused, 39)
    }

    func testIndexPicksAnotherCandidateAndListShowsAll() throws {
        let clean = try report([Self.cli26.path, "--index", "1", "--no-env"])
        XCTAssertEqual(clean.build.tasks, 577)
        XCTAssertEqual(try report([Self.cli26.path, "--index", "2", "--no-env"]).build.tasks, 3)

        let outOfRange = try run(["analyze", Self.cli26.path, "--index", "3"])
        XCTAssertEqual(outOfRange.status, 5, outOfRange.err)
        XCTAssertTrue(outOfRange.err.contains("--index 3 is out of range"), outOfRange.err)

        let list = try run(["analyze", Self.cli26.path, "--list"])
        XCTAssertEqual(list.status, 0, list.err)
        XCTAssertEqual(list.out.split(separator: "\n").filter { $0.contains("[") && $0.contains(".xcactivitylog") }.count, 3)
        XCTAssertLessThan(try XCTUnwrap(list.out.range(of: Self.incremental26)).lowerBound,
                          try XCTUnwrap(list.out.range(of: "20E8B73D")).lowerBound, "newest first")
        XCTAssertTrue(list.out.contains("Cleaning project AcmeApp"), list.out)

        XCTAssertEqual(try run(["analyze", Self.clean26, "--list"]).status, 2)
        XCTAssertEqual(try run(["analyze", Self.cli26.path, "--list", "--index", "0"]).status, 2)
    }

    func testIDEPackageOnlyFolderExitsFiveAndPrintsTheHintVerbatim() throws {
        let result = try run(["analyze", Self.fixtures.appendingPathComponent("ide-xcode26").path])
        XCTAssertEqual(result.status, 5, result.err)
        XCTAssertTrue(result.err.contains(
            "xcodebuild may not write an activity log without -resultBundlePath; run it through `xcblame build -- ...`"),
                      result.err)
        XCTAssertTrue(result.out.isEmpty, result.out)
    }

    func testNotALogFileExitsFive() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-notalog-\(UUID().uuidString).txt")
        try Data("hello".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let result = try run(["analyze", url.path])
        XCTAssertEqual(result.status, 5, result.err)
        XCTAssertTrue(result.err.contains("neither an .xcactivitylog nor an xcresult"), result.err)
    }

    // MARK: - v0.2 surface (stubs until the lanes land)

    func testAnalyzeHTMLWritesAFileAndOnlyTheSummaryGoesToStdout() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-\(UUID().uuidString).html")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let result = try run(["analyze", Self.clean26, "--format", "html", "--no-env", "--no-history", "-o", file.path])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.out.hasPrefix("wrote \(file.path) (html, "), result.out)
        XCTAssertTrue(result.out.contains("open \"\(file.path)\""), result.out)
        XCTAssertFalse(result.out.contains("<html"), "HTML never goes to stdout")
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("id=\"xcblame-data\""))
    }

    func testHTMLFlagsParse() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-\(UUID().uuidString).html")
        addTeardownBlock { try? FileManager.default.removeItem(at: file) }
        let result = try run(["analyze", Self.clean26, "--format", "html", "--no-redact", "--top", "all", "--open",
                              "--browser", "Safari", "--no-history", "--no-build-description", "--no-env", "-o", file.path],
                             environment: ["CI": "true"])
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertTrue(result.err.contains("--open ignored because CI=true"), result.err)
        XCTAssertFalse(result.err.contains("--redact is not implemented"), "--no-redact turns redaction off")
        XCTAssertEqual(try run(["analyze", "--build-description", "/tmp", "--no-build-description"]).status, 2)
    }

    func testSavedReportIsRoutedToTheReRenderPath() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-report-\(UUID().uuidString).json")
        try Data(#"{"schemaVersion": "xcblame.report/1"}"#.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let result = try run(["analyze", url.path])
        XCTAssertEqual(result.status, 1, result.err)
        XCTAssertTrue(result.err.contains("re-rendering a saved JSON report"), result.err)
    }

    /// Rules in `analyze`: without a project one summary line (not 46 N/A lines); with `--project` the engine runs
    /// on the project (static findings, the log is another project's) and V13 is measured after the merge.
    func testAnalyzeRulesSummaryAndProjectFindings() throws {
        let dd = Self.fixtures.appendingPathComponent("cli-xcode26-dd")
        let log = dd.appendingPathComponent("5E3BDB3A-008A-466D-A419-CB4D4E8CED29.xcactivitylog").path
        let common = [log, "--build-description", dd.appendingPathComponent("xcbuilddata").path, "--no-env", "--no-history"]
        let bare = try run(["analyze"] + common + ["--format", "text"])
        XCTAssertEqual(bare.status, 0, bare.err)
        XCTAssertTrue(bare.out.contains("rules: 49 evaluated, 0 findings, 49 not applicable (no project)\n"), bare.out)
        XCTAssertFalse(bare.out.contains("FINDINGS"))
        XCTAssertFalse(bare.out.contains("N/A"))

        let acme = Self.fixtures.deletingLastPathComponent().appendingPathComponent("projects/AcmeApp/AcmeApp.xcodeproj")
        // `--offline`: the offline resolver, so the result does not depend on a real `xcodebuild -showBuildSettings`
        // finishing inside analyze's 5 s cap or on package checkouts another test left in a shared oracle cache (AcmeApp
        // has remote packages: without checkouts analyze goes offline, with them it asks xcodebuild).
        let text = try run(["analyze"] + common + ["--project", acme.path, "--offline", "--format", "text"])
        XCTAssertEqual(text.status, 0, text.err)
        XCTAssertTrue(text.out.contains("FINDINGS "), text.out)
        XCTAssertTrue(text.out.contains("rules: 49 evaluated, 17 findings"), text.out)
        let json = try run(["analyze"] + common + ["--project", acme.path, "--offline", "--format", "json"])
        let doc = try JSONReporter.decoder().decode(ReportDocument.self, from: Data(json.out.utf8))
        XCTAssertEqual(doc.project?.container, acme.path)
        XCTAssertFalse(doc.findings.isEmpty)
        XCTAssertEqual(doc.project?.settingsSource, "offline resolver")
        XCTAssertTrue(doc.findings.allSatisfy { $0.confidence == "low" }, "static-only findings on unverified (offline) settings")
        let v13 = try XCTUnwrap(doc.validation.checks.first { $0.id == "V13" })
        XCTAssertEqual(v13.status, "pass")
        XCTAssertEqual(v13.detail, "\(json.out.utf8.count) of 2000000 bytes", "measured on the report with its findings")
    }

    func testTopAllListsEveryTopTask() throws {
        let doc = try report([Self.clean26, "--no-env", "--top", "all"])
        XCTAssertEqual(doc.topTasks?.count, doc.topTasksTotal)
    }
}
