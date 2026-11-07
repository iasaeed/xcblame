import Foundation
import XCTest
@testable import XcblameKit

/// DESIGN §8.2.5 tier 1: parity, escaping, placeholders, size, redaction, determinism. No browser.
final class HTMLReporterTests: XCTestCase {
    private func render(_ doc: ReportDocument, _ index: TaskIndex?, maxBytes: Int = HTMLReporter.defaultMaxBytes) throws -> String {
        String(decoding: try HTMLReporter.render(doc, taskIndex: index, options: .init(redact: false, maxBytes: maxBytes,
                                                                                       title: "xcblame report")),
               as: UTF8.self)
    }

    private func cleanFixture() throws -> (model: BuildModel, doc: ReportDocument, index: TaskIndex) {
        let model = BuildModelBuilder.build(try SLFReader.read(url: SLFFixtures.cli26Clean), reader: .slf)
        let (doc, index) = try HTMLSample.bare(model)
        return (model, doc, index)
    }

    private func embedded(_ doc: ReportDocument, _ index: TaskIndex?) throws -> ReportDocument {
        try HTMLReporter.renderReport(doc, taskIndex: index, options: .init(redact: false, title: "xcblame report")).document
    }

    // (a) The blob minus `taskIndex` is byte-equal to `--format json --top all` of the embedded document, which is the
    // input document with V13 measured on the page.
    func testBlobWithoutTaskIndexIsByteEqualToTheJSONReport() throws {
        let (_, doc, index) = try cleanFixture()
        let blob = try HTMLBlob.extract(try render(doc, index))
        XCTAssertEqual(doc.topN, .max, "html defaults to --top all")
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(blob.utf8)))
        XCTAssertTrue(blob.contains("\"taskIndex\" : {"))
        let shown = try embedded(doc, index)
        XCTAssertEqual(shown, HTMLBlob.withV13(of: shown, doc), "only V13 differs")
        XCTAssertEqual(HTMLBlob.withoutTaskIndex(blob), try JSONReporter.renderString(shown))
        XCTAssertEqual(try HTMLBlob.extract(try render(doc, nil)), try JSONReporter.renderString(embedded(doc, nil)))
    }

    /// Code review v0.2 #5: a normal render passes V13, measured on the final page, template included.
    func testV13IsMeasuredOnTheRenderedPage() throws {
        let (_, doc, index) = try cleanFixture()
        let rendered = try HTMLReporter.renderReport(doc, taskIndex: index, options: .init(redact: false,
                                                                                          title: "xcblame report"))
        let blob = try JSONReporter.decoder().decode(ReportDocument.self,
                                                     from: Data(try HTMLBlob.extract(String(decoding: rendered.data,
                                                                                            as: UTF8.self)).utf8))
        let v13 = try XCTUnwrap(blob.validation.checks.first { $0.id == "V13" })
        XCTAssertEqual(v13.status, "pass")
        XCTAssertEqual(v13.detail, "\(rendered.data.count) of \(HTMLReporter.defaultMaxBytes) bytes (html, template included)")
    }

    /// Re-check R1: a cap 5 bytes under the whole page truncates (the budget leaves room for the final V13 line)
    /// and the file fits.
    func testCapJustUnderTheWholePageTruncatesAndFits() throws {
        let (_, doc, index) = try cleanFixture()
        let full = try HTMLReporter.renderReport(doc, taskIndex: index, options: .init(redact: false, title: "xcblame report"))
        XCTAssertTrue(full.document.truncation.steps.isEmpty)
        let cap = full.data.count - 5
        let tight = try HTMLReporter.renderReport(doc, taskIndex: index, options: .init(redact: false, maxBytes: cap,
                                                                                       title: "xcblame report"))
        XCTAssertLessThanOrEqual(tight.data.count, cap)
        XCTAssertFalse(tight.document.truncation.steps.isEmpty)
        XCTAssertEqual(tight.document.validation.checks.first { $0.id == "V13" }?.status, "pass")
    }

    func testPopulatedBlobParityAndTaskIndexRoundTrip() throws {
        let (doc, index) = try HTMLSample.populated(hostileStrings: false)
        let blob = try HTMLBlob.extract(try render(doc, index))
        XCTAssertEqual(HTMLBlob.withoutTaskIndex(blob), try JSONReporter.renderString(embedded(doc, index)))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(blob.utf8)) as? [String: Any])
        let indexData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["taskIndex"]))
        XCTAssertEqual(try JSONDecoder().decode(TaskIndex.self, from: indexData), index)
    }

    func testSpliceKeepsSortedOrderAtEitherEnd() {
        let json = "{\n  \"a\" : 1,\n  \"z\" : {\n    \"b\" : 2\n  }\n}\n"
        XCTAssertEqual(HTMLReporter.splice(member: "m", value: "[]", into: json),
                       "{\n  \"a\" : 1,\n  \"m\" : [],\n  \"z\" : {\n    \"b\" : 2\n  }\n}\n")
        XCTAssertEqual(HTMLReporter.splice(member: "zz", value: "0", into: "{\n  \"a\" : 1\n}\n"),
                       "{\n  \"a\" : 1,\n  \"zz\" : 0\n}\n")
    }

    // (b) Escaping: nothing in the blob can close the script or open a comment; hostile strings round-trip.
    func testHostileStringsCannotEscapeTheBlobAndRoundTrip() throws {
        let (doc, index) = try HTMLSample.populated()
        let html = try render(doc, index)
        let blob = try HTMLBlob.extract(html)
        XCTAssertFalse(blob.contains("</script"))
        XCTAssertFalse(blob.lowercased().contains("</script"))
        XCTAssertFalse(blob.contains("<!--"))
        XCTAssertFalse(blob.contains("\u{2028}"))
        XCTAssertFalse(blob.contains("\u{2029}"))
        let back = try JSONReporter.decoder().decode(ReportDocument.self, from: Data(blob.utf8))
        XCTAssertEqual(back, HTMLBlob.withV13(of: back, doc))
        XCTAssertEqual(back.hotspots?.first { $0.declaration.hasPrefix("</script>") }?.declaration, HTMLSample.hostile)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(blob.utf8)) as? [String: Any])
        let indexData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["taskIndex"]))
        XCTAssertTrue(try JSONDecoder().decode(TaskIndex.self, from: indexData).labels.contains(HTMLSample.hostile))
        XCTAssertEqual(html.components(separatedBy: "</script>").count - 1, 2, "only the data and code scripts close")
    }

    // (c) Every placeholder outside the blob is filled; a placeholder-looking string inside the data stays as data.
    func testNoUnfilledPlaceholders() throws {
        let (doc, index) = try HTMLSample.populated()
        let html = try render(doc, index)
        let blob = try HTMLBlob.extract(html)
        XCTAssertFalse(html.replacingOccurrences(of: blob, with: "").contains("{{"))
        XCTAssertTrue(blob.contains("{{TITLE}}"), "data is substituted last, never re-scanned")
        XCTAssertTrue(html.contains("<title>xcblame report</title>"))
        XCTAssertTrue(html.contains("Generated 2023-11-14T22:13:20Z by xcblame \(XcblameVersion.current)"))
    }

    func testTitleIsHTMLEscaped() throws {
        let (doc, _) = try HTMLSample.bare()
        let data = try HTMLReporter.render(doc, taskIndex: nil, options: .init(redact: false, title: "<b>a & 'b'</b>"))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("<title>&lt;b&gt;a &amp; &#39;b&#39;&lt;/b&gt;</title>"))
    }

    // (e) Size: the AcmeApp r26 clean fixture (577 tasks) renders to ≤ 1 MB, bare and with every member filled.
    func testCleanFixtureRendersUnderOneMegabyte() throws {
        let (model, doc, index) = try cleanFixture()
        let bare = try render(doc, index)
        XCTAssertLessThanOrEqual(bare.utf8.count, 1_000_000)
        let (full, fullIndex) = try HTMLSample.populated(model, hostileStrings: false)
        XCTAssertEqual(fullIndex.start.count, 577)
        let html = try render(full, fullIndex)
        XCTAssertLessThanOrEqual(html.utf8.count, 1_000_000, "\(html.utf8.count) bytes")
        XCTAssertTrue(try JSONReporter.decoder().decode(ReportDocument.self, from: Data(try HTMLBlob.extract(html).utf8))
            .truncation.steps.isEmpty)
    }

    func testFiftyThousandTaskSyntheticFitsEightMegabytesWithTotalsIntact() throws {
        let (doc, index) = try HTMLSample.synthetic()
        let html = try render(doc, index)
        XCTAssertLessThanOrEqual(html.utf8.count, HTMLReporter.defaultMaxBytes)
        let blob = try HTMLBlob.extract(html)
        let out = try JSONReporter.decoder().decode(ReportDocument.self, from: Data(blob.utf8))
        XCTAssertFalse(out.truncation.steps.isEmpty)
        XCTAssertEqual(out.truncation.steps.map(\.step).prefix(2), ["topTasks", "hotspots"])
        XCTAssertGreaterThan(html.utf8.count, 2_000_000, "stops trimming once it fits")
        XCTAssertEqual(out.hotspotsTotal, doc.hotspotsTotal)
        XCTAssertEqual(out.filesTotal, doc.filesTotal)
        XCTAssertEqual(out.targetsTotal, doc.targetsTotal)
        XCTAssertEqual(out.topTasksTotal, doc.topTasksTotal)
        XCTAssertEqual(out.findingsTotal, doc.findingsTotal)
        XCTAssertEqual(out.decodeWarningsTotal, doc.decodeWarningsTotal)
        XCTAssertEqual(out.timing.serialStretchesTotal, doc.timing.serialStretchesTotal)
        XCTAssertEqual(out.timing.idleGapsTotal, doc.timing.idleGapsTotal)
        XCTAssertEqual(out.build, doc.build)
        XCTAssertEqual(out.timing.utilization, doc.timing.utilization)
        XCTAssertEqual(out.criticalPath, doc.criticalPath)
        XCTAssertEqual(out.findings, doc.findings)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(blob.utf8)) as? [String: Any])
        if let raw = object["taskIndex"] {
            let thinned = try JSONDecoder().decode(TaskIndex.self, from: try JSONSerialization.data(withJSONObject: raw))
            XCTAssertEqual(thinned.taskIndexTotal, index.taskIndexTotal)
            XCTAssertEqual(thinned.start.count + thinned.dropped.reduce(0) { $0 + $1.tasks }, index.start.count)
        }
        print("50k synthetic: \(html.utf8.count) bytes, steps \(out.truncation.steps.map { "\($0.step) \($0.kept)/\($0.total)" })")
    }

    /// Code review v0.5 M3: a non-clean 50k-task build. html runs with `--top all`, so every executed task sits in
    /// `incremental.causes[].tasks` (and, for a zero-change build, in `fixedCosts[].tasks`); the budget caps those
    /// lists per entry, keeps every cause (`unknown` too) and every class, and stays under 8 MB with the banner.
    func testFiftyThousandTaskIncrementalFitsEightMegabytesWithEveryCause() throws {
        var (doc, index) = try HTMLSample.synthetic()
        let tasks = try XCTUnwrap(doc.topTasks)
        typealias Incremental = ReportDocument.Incremental
        func causeTask(_ task: ReportDocument.TopTask) -> Incremental.CauseTask {
            .init(key: "target-\(task.target ?? "")-0123456789abcdef0123456789abcdef0123456789abcdef:Debug:"
                    + "SwiftCompile normal arm64 \(task.title)",
                  label: task.title, target: task.target, kind: task.kind, seconds: task.seconds, pathSeconds: 0,
                  taskId: task.id)
        }
        let groups = Dictionary(grouping: tasks, by: { $0.id % 21 })
        var causes: [Incremental.Cause] = (0..<20).map { n in
            let members = (groups[n] ?? []).map(causeTask)
            let subject = "/Users/sample/Projects/Big/Sources/Feature\(n)/File\(n).swift"
            return .init(id: "inputChanged:" + subject, class: "inputChanged", cause: "File\(n).swift changed",
                         source: "backtrace", subject: subject, evidence: ["backtrace: ruleInputRebuilt"],
                         secondaryEvidence: [], tasks: members, tasksTotal: members.count, tasksShownShare: 1,
                         seconds: ReportDocument.round6(members.reduce(0) { $0 + $1.seconds }), pathSeconds: 0, ruleId: nil)
        }
        causes.sort { $0.seconds > $1.seconds }
        let unknown = (groups[20] ?? []).map(causeTask)
        causes.append(.init(id: "unknown", class: "unknown", cause: "No evidence explains these tasks", source: "unknown",
                            subject: nil, evidence: [], secondaryEvidence: [], tasks: unknown, tasksTotal: unknown.count,
                            tasksShownShare: 1, seconds: ReportDocument.round6(unknown.reduce(0) { $0 + $1.seconds }),
                            pathSeconds: 0, ruleId: nil))
        let sum = ReportDocument.round6(causes.reduce(0) { $0 + $1.seconds })
        doc = doc.applying(incremental: Incremental(
            basis: "previousIndex", previousBuild: .init(id: "20261102-101500-clean", time: nil), causes: causes,
            unknownSeconds: causes.last!.seconds, unknownShare: nil, byTaskTime: causes.map(\.id), byPathSeconds: [],
            v15: V15.evaluate(sumOfCauses: sum, executedSeconds: sum), procedure: nil, notes: []))
        let byClass = Dictionary(grouping: tasks.prefix(6_000), by: { $0.id % 3 })
        doc.fixedCosts = ["scripts", "codesign", "planning"].enumerated().map { n, cls in
            let members = (byClass[n] ?? []).map(causeTask)
            return FixedCosts.row(cls, tasks: members, basis: "zeroChange", perDay: 50, perDayBasis: "assumed")
        }
        let html = try render(doc, index)
        XCTAssertLessThanOrEqual(html.utf8.count, HTMLReporter.defaultMaxBytes)
        let out = try JSONReporter.decoder().decode(ReportDocument.self, from: Data(try HTMLBlob.extract(html).utf8))
        let steps = out.truncation.steps.map(\.step)
        XCTAssertEqual(Array(steps.prefix(3)), ["topTasks", "incrementalTasks", "fixedCostTasks"], "\(steps)")
        XCTAssertFalse(steps.contains("lastResort"), "\(steps)")
        XCTAssertTrue(html.contains("This report is truncated to fit its size cap."), "the banner")
        let kept = try XCTUnwrap(out.incremental)
        XCTAssertEqual(kept.causes.map(\.id), causes.map(\.id), "every cause, unknown last")
        XCTAssertEqual(kept.causes.map(\.tasksTotal), causes.map(\.tasksTotal))
        XCTAssertEqual(kept.causes.map(\.seconds), causes.map(\.seconds))
        XCTAssertEqual(kept.v15, doc.incremental?.v15)
        for (cause, original) in zip(kept.causes, causes) {
            XCTAssertLessThanOrEqual(cause.tasks.count, 200)
            XCTAssertEqual(cause.tasks.map(\.taskId), original.tasks.prefix(cause.tasks.count).map(\.taskId))
            let share = try XCTUnwrap(cause.tasksShownShare)
            XCTAssertEqual(share, cause.tasks.reduce(0) { $0 + $1.seconds } / original.seconds, accuracy: 1e-5)
            XCTAssertLessThan(share, 1)
        }
        let costs = try XCTUnwrap(out.fixedCosts)
        XCTAssertEqual(costs.map(\.class), doc.fixedCosts?.map(\.class))
        XCTAssertEqual(costs.map(\.tasksTotal), doc.fixedCosts?.map(\.tasksTotal))
        XCTAssertTrue(costs.allSatisfy { $0.tasks.count <= 200 })
        XCTAssertNotNil(out.criticalPath, "the cheap step ran before anything that drops a section")
        XCTAssertEqual(out.build, doc.build)
        print("50k incremental: \(html.utf8.count) bytes, steps \(out.truncation.steps.map { "\($0.step) \($0.kept)/\($0.total)" })")
    }

    /// M3: history entries hold each cause's and fixed-cost class's top 25 tasks (the task index rows hold every task).
    func testHistoryEntriesTrimTheCauseAndFixedCostTasks() throws {
        let (doc, _) = try HTMLSample.synthetic(tasks: 2_000, labels: 100, files: 10, hotspots: 10)
        let tasks = try XCTUnwrap(doc.topTasks).map {
            ReportDocument.Incremental.CauseTask(key: nil, label: $0.title, target: $0.target, kind: $0.kind,
                                                 seconds: $0.seconds, pathSeconds: nil, taskId: $0.id)
        }
        let seconds = tasks.reduce(0) { $0 + $1.seconds }
        var document = doc.applying(incremental: .init(
            basis: "currentLogOnly", previousBuild: nil,
            causes: [.init(id: "unknown", class: "unknown", cause: "none", source: "unknown", subject: nil, evidence: [],
                           secondaryEvidence: [], tasks: tasks, tasksTotal: tasks.count, tasksShownShare: 1,
                           seconds: seconds, pathSeconds: nil, ruleId: nil)],
            unknownSeconds: seconds, unknownShare: 1, byTaskTime: ["unknown"], byPathSeconds: [],
            v15: .init(status: "pass", executedSeconds: seconds, sumOfCauses: seconds), procedure: nil, notes: []))
        document.fixedCosts = [FixedCosts.row("scripts", tasks: tasks, basis: "zeroChange", perDay: 50, perDayBasis: "assumed")]
        let trimmed = History.trimmed(document)
        let cause = try XCTUnwrap(trimmed.incremental?.causes.first)
        XCTAssertEqual(cause.tasks.count, History.topRows)
        XCTAssertEqual(cause.tasksTotal, tasks.count)
        XCTAssertEqual(try XCTUnwrap(cause.tasksShownShare), cause.tasks.reduce(0) { $0 + $1.seconds } / seconds,
                       accuracy: 1e-9)
        XCTAssertEqual(trimmed.fixedCosts?.first?.tasks.count, History.topRows)
        XCTAssertEqual(trimmed.fixedCosts?.first?.tasksTotal, tasks.count)
    }

    // (f) Redaction: home, user, host, repo root and DerivedData hash appear nowhere in the file.
    func testRedactedReportHasNoHomeUserOrHost() throws {
        let context = Redactor.Context(home: "/Users/zqxuser", user: "zqxuser", host: "Zqx'MacBook\"</script>.local",
                                       repoRoot: "/Users/zqxuser/Projects/App")
        var (doc, index) = try HTMLSample.populated(hostileStrings: false)
        let dd = "/Users/zqxuser/Library/Developer/Xcode/DerivedData/App-abcdefghijklmnopqrstuvwxyzab/Build"
        doc.input.path = dd + "/../Logs/Build/x.xcactivitylog"
        doc.graph.path = dd + "/Intermediates.noindex/XCBuildData/abc.xcbuilddata"
        doc.notes.append("built on Zqx'MacBook\"</script> by zqxuser in /Users/zqxuser/Projects/App/Sources")
        doc.files?[0].path = "/Users/zqxuser/Projects/App/Sources/A.swift"
        doc.hotspots?[0].file = "/Users/zqxuser/elsewhere/B.swift"
        doc.targets?[0].project = "/Users/zqxuser/Projects/App/App.xcodeproj"
        var env = EnvSnapshot()
        env.developerDir = "/Users/zqxuser/Applications/Xcode.app/Contents/Developer"
        doc.environment = env
        let redacted = try Redactor.redact(doc, context: context)
        XCTAssertTrue(redacted.redacted)
        let html = try render(redacted, index)
        for secret in ["zqxuser", "Zqx", "abcdefghijklmnopqrstuvwxyzab"] {
            XCTAssertFalse(html.contains(secret), "\(secret) leaked")
        }
        XCTAssertEqual(redacted.files?[0].path, "$REPO/Sources/A.swift")
        XCTAssertEqual(redacted.hotspots?[0].file, "~/elsewhere/B.swift")
        XCTAssertEqual(redacted.graph.path, "~/Library/Developer/Xcode/DerivedData/App-$DDHASH/Build/Intermediates.noindex/XCBuildData/abc.xcbuilddata")
        XCTAssertEqual(redacted.notes.last, "built on $HOST by $USER in $REPO/Sources")
    }

    // (h) Determinism.
    func testTwoRendersAreByteIdentical() throws {
        let (doc, index) = try HTMLSample.populated()
        XCTAssertEqual(try render(doc, index), try render(doc, index))
        let (big, bigIndex) = try HTMLSample.synthetic(tasks: 8_000, labels: 3_000, files: 2_000, hotspots: 6_000)
        XCTAssertEqual(try render(big, bigIndex, maxBytes: 1_500_000), try render(big, bigIndex, maxBytes: 1_500_000))
    }
}
