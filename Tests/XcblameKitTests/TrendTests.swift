import XCTest
@testable import XcblameKit

final class TrendTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    private func run(_ directory: URL, _ options: Trend.Options = Trend.Options()) throws -> TrendDocument {
        try Trend.run(history: directory, options: options, now: now)
    }

    // MARK: - Percentiles

    func testPercentilesAreR7() {
        let p = Trend.percentiles([100, 10, 40, 20, 30])
        XCTAssertEqual(p, .init(n: 5, p50: 30, p75: 40, p95: 88))
        XCTAssertEqual(Trend.percentiles([7]), .init(n: 1, p50: 7, p75: 7, p95: 7))
        XCTAssertEqual(Trend.percentiles([1, 2]), .init(n: 2, p50: 1.5, p75: 1.75, p95: 1.95), "even count: mean of the middle two")
        XCTAssertEqual(Trend.percentiles([]), .init(n: 0, p50: nil, p75: nil, p95: nil))
    }

    // MARK: - Grouping

    func testWithoutByThereIsOneGroupWithOneSeriesPerKindOldestFirst() throws {
        let dir = try makeHistoryDirectory()
        // Written out of order on purpose.
        let c3 = try TrendFixture.save(.init(minutes: 30, wall: 30), in: dir)
        let c1 = try TrendFixture.save(.init(minutes: 10, wall: 10), in: dir)
        let i1 = try TrendFixture.save(.init(minutes: 20, kind: "incremental", wall: 2, busy: nil), in: dir)
        let c2 = try TrendFixture.save(.init(minutes: 20.5, wall: 20), in: dir)
        let doc = try run(dir)

        XCTAssertEqual(doc.schemaVersion, "xcblame.trend/1")
        XCTAssertEqual(doc.entriesTotal, 4)
        XCTAssertEqual(doc.entriesUsed, 4)
        XCTAssertEqual(doc.groups.count, 1)
        let group = doc.groups[0]
        XCTAssertNil(group.key)
        XCTAssertEqual(group.entries, 4)
        XCTAssertEqual(group.series.map(\.kind), ["clean", "incremental"])
        let clean = group.series[0]
        XCTAssertEqual(clean.points.map(\.id), [c1, c2, c3])
        XCTAssertEqual(clean.points.map(\.wall), [10, 20, 30])
        XCTAssertEqual(clean.wall, .init(n: 3, p50: 20, p75: 25, p95: 29))
        XCTAssertEqual(clean.busy, .init(n: 3, p50: 18, p75: 18, p95: 18))
        let incremental = group.series[1]
        XCTAssertEqual(incremental.points.map(\.id), [i1])
        XCTAssertEqual(incremental.busy, .init(n: 0, p50: nil, p75: nil, p95: nil), "no point has the metric")
        XCTAssertEqual(clean.points[0].machine, "Mac15,14/28c/96g")
        XCTAssertEqual(clean.points[0].xcode, "26.0")
    }

    func testByXcodeGroupsNumericallyWithUnknownLastAndNoMarkers() throws {
        let dir = try makeHistoryDirectory()
        try TrendFixture.save(.init(minutes: 1, xcode: "26.0"), in: dir)
        try TrendFixture.save(.init(minutes: 2, xcode: "9.4"), in: dir)
        try TrendFixture.save(.init(minutes: 3, xcode: nil), in: dir)
        try TrendFixture.save(.init(minutes: 4, xcode: "26.1"), in: dir)
        try TrendFixture.save(.init(minutes: 5, xcode: "26.0"), in: dir)
        let doc = try run(dir, .init(by: .xcode))
        XCTAssertEqual(doc.groups.map(\.key), ["9.4", "26.0", "26.1", "unknown"])
        XCTAssertEqual(doc.groups.map(\.entries), [1, 2, 1, 1])
        XCTAssertEqual(doc.entriesUsed, doc.groups.map(\.entries).reduce(0, +))
        XCTAssertTrue(doc.groups.flatMap(\.series).allSatisfy { $0.xcodeChangeMarkers.isEmpty })
        XCTAssertEqual(doc.filter.by, .xcode)
    }

    func testXcodeChangeMarkersBetweenConsecutiveKnownVersions() throws {
        let dir = try makeHistoryDirectory()
        try TrendFixture.save(.init(minutes: 1, xcode: "26.0"), in: dir)
        try TrendFixture.save(.init(minutes: 2, xcode: "26.0"), in: dir)
        try TrendFixture.save(.init(minutes: 3, xcode: nil), in: dir)
        let moved = try TrendFixture.save(.init(minutes: 4, xcode: "26.1"), in: dir)
        let later = try TrendFixture.save(.init(minutes: 5, xcode: "27.0"), in: dir)
        let series = try XCTUnwrap(try run(dir).groups.first?.series.first)
        // The unknown version in between is no change, and 26.0 -> (unknown) -> 26.1 is not compared across it.
        XCTAssertEqual(series.xcodeChangeMarkers.map(\.atId), [later])
        XCTAssertEqual(series.xcodeChangeMarkers.first?.from, "26.1")
        XCTAssertEqual(series.xcodeChangeMarkers.first?.to, "27.0")
        XCTAssertNotNil(series.xcodeChangeMarkers.first?.time)
        _ = moved
    }

    func testByCommitOrdersByTimeAndKeepsTheFullHash() throws {
        let dir = try makeHistoryDirectory()
        // Hash order is the opposite of time order.
        try TrendFixture.save(.init(minutes: 1, commit: TrendFixture.hash("f"), branch: "main"), in: dir)
        try TrendFixture.save(.init(minutes: 2, commit: TrendFixture.hash("a"), branch: "main"), in: dir)
        try TrendFixture.save(.init(minutes: 3), in: dir)
        try TrendFixture.save(.init(minutes: 4, commit: TrendFixture.hash("f"), branch: "main"), in: dir)
        let doc = try run(dir, .init(by: .commit))
        XCTAssertEqual(doc.groups.map(\.key), [TrendFixture.hash("f"), TrendFixture.hash("a"), "unknown"])
        XCTAssertEqual(doc.groups.map(\.entries), [2, 1, 1])
        let text = TrendTextReporter.render(doc)
        XCTAssertTrue(text.contains("commit ffffffff: 2 entries"), text)
        XCTAssertFalse(text.contains(TrendFixture.hash("f")), "labelled by the short commit")
    }

    func testByBranchAndByMachine() throws {
        let dir = try makeHistoryDirectory()
        try TrendFixture.save(.init(minutes: 1, branch: "main", machine: ("Mac15,14", 28, 96)), in: dir)
        try TrendFixture.save(.init(minutes: 2, branch: "feature/x", machine: ("Macmini9,1", 8, 16)), in: dir)
        try TrendFixture.save(.init(minutes: 3, branch: "main", machine: nil), in: dir)
        XCTAssertEqual(try run(dir, .init(by: .branch)).groups.map(\.key), ["feature/x", "main"])
        XCTAssertEqual(try run(dir, .init(by: .machine)).groups.map(\.key), ["Mac15,14/28c/96g", "Macmini9,1/8c/16g", "unknown"])
    }

    // MARK: - Filters and notes

    func testKindSchemeAndSinceFilters() throws {
        let dir = try makeHistoryDirectory()
        try TrendFixture.save(.init(minutes: 1, kind: "clean"), in: dir)
        try TrendFixture.save(.init(minutes: 2, kind: "incremental"), in: dir)
        try TrendFixture.save(.init(minutes: 3, kind: "clean", scheme: "AcmeKit"), in: dir)
        try TrendFixture.save(.init(minutes: 4, kind: "clean", scheme: nil), in: dir)
        let since = TrendFixture.epoch.addingTimeInterval(150)

        let kind = try run(dir, .init(kind: "clean"))
        XCTAssertEqual(kind.entriesUsed, 3)
        XCTAssertEqual(kind.groups[0].series.map(\.kind), ["clean"])
        XCTAssertTrue(kind.notes.contains { $0.contains("1 entries of another kind left out by --kind") }, "\(kind.notes)")

        let scheme = try run(dir, .init(scheme: "AcmeApp"))
        XCTAssertEqual(scheme.entriesUsed, 2)
        XCTAssertEqual(scheme.entriesTotal, 4)
        XCTAssertTrue(scheme.notes.contains { $0.contains("1 entries have no scheme") && $0.contains("--scheme") }, "\(scheme.notes)")
        XCTAssertTrue(scheme.notes.contains { $0.contains("1 entries of another scheme") }, "\(scheme.notes)")

        let recent = try run(dir, .init(since: since))
        XCTAssertEqual(recent.entriesUsed, 2)
        XCTAssertEqual(recent.filter.since, since)
        XCTAssertTrue(recent.notes.contains { $0.contains("2 entries older than --since") }, "\(recent.notes)")

        let mixed = try run(dir)
        XCTAssertTrue(mixed.notes.contains { $0.contains("2 schemes (AcmeApp, AcmeKit)") }, "\(mixed.notes)")
    }

    /// Code review v0.4 minor: an entry with no time (no stamp in its name, no `generatedAt`) cannot be "since" anything.
    func testSinceLeavesOutEntriesWithoutATimeAndCountsThem() throws {
        let dir = try makeHistoryDirectory()
        try TrendFixture.save(.init(minutes: 10), in: dir)
        let json = dir.appendingPathComponent("undated.json")
        try Data(#"{"build":{"kind":"clean","span":9,"busy":8,"tasks":3}}"#.utf8).write(to: json)
        try gzip(json, to: dir.appendingPathComponent("undated.json.gz"))
        try FileManager.default.removeItem(at: json)
        let since = TrendFixture.epoch.addingTimeInterval(-3600)

        let all = try run(dir)
        XCTAssertEqual(all.entriesUsed, 2, "without --since the undated entry counts")
        let recent = try run(dir, .init(since: since))
        XCTAssertEqual(recent.entriesUsed, 1)
        XCTAssertEqual(recent.groups.flatMap(\.series).flatMap(\.points).map(\.id).count, 1)
        XCTAssertTrue(recent.notes.contains { $0.contains("1 entries have no time and are left out by --since") }, "\(recent.notes)")
    }

    func testEntriesWithoutGitSaySoInsteadOfGuessing() throws {
        let dir = try makeHistoryDirectory()
        try TrendFixture.save(.init(minutes: 1), in: dir)
        try TrendFixture.save(.init(minutes: 2, commit: TrendFixture.hash("c"), branch: "main"), in: dir)
        let doc = try run(dir)
        XCTAssertTrue(doc.notes.contains { $0.contains("1 of 2 entries carry no git commit or branch") }, "\(doc.notes)")
        let points = doc.groups[0].series[0].points
        XCTAssertNil(points[0].commit)
        XCTAssertNil(points[0].branch)
        XCTAssertEqual(points[1].commit, TrendFixture.hash("c"))
        XCTAssertEqual(points[1].branch, "main")
    }

    func testUnreadableAndUntimedEntriesAreSkippedWithANote() throws {
        let dir = try makeHistoryDirectory()
        try TrendFixture.save(.init(minutes: 1), in: dir)
        try TrendFixture.save(.init(minutes: 2, wall: nil, busy: nil), in: dir)
        try TrendFixture.save(.init(minutes: 3, wall: nil, busy: 5), in: dir)
        try Data("not gzip".utf8).write(to: dir.appendingPathComponent("20260101-000000-clean.json.gz"))
        let doc = try run(dir)
        XCTAssertEqual(doc.entriesTotal, 4)
        XCTAssertEqual(doc.entriesUsed, 2, "a busy-only entry still counts")
        XCTAssertTrue(doc.notes.contains { $0.contains("1 of 4 history entries could not be read") }, "\(doc.notes)")
        XCTAssertTrue(doc.notes.contains { $0.contains("1 entries have no timing") }, "\(doc.notes)")
        let points = doc.groups[0].series[0].points
        XCTAssertEqual(points.map(\.wall), [20, nil])
        XCTAssertEqual(doc.groups[0].series[0].wall.n, 1)
    }

    func testEmptyOrMissingHistoryIsADocumentWithANote() throws {
        let missing = try makeScratchDirectory().appendingPathComponent("history")
        let doc = try run(missing)
        XCTAssertEqual(doc.entriesTotal, 0)
        XCTAssertEqual(doc.entriesUsed, 0)
        XCTAssertTrue(doc.groups.isEmpty)
        XCTAssertTrue(doc.notes[0].hasPrefix("no history entries in "), "\(doc.notes)")
        XCTAssertTrue(TrendTextReporter.render(doc).contains("NOTES"))
    }

    // MARK: - --since

    func testParseSince() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(Trend.parseSince("30d", now: base), base.addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(Trend.parseSince("0d", now: base), base)
        let day = try XCTUnwrap(Trend.parseSince("2026-10-05", now: base, calendar: calendar))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: day),
                       DateComponents(year: 2026, month: 10, day: 5, hour: 0, minute: 0), "local midnight")
        for bad in ["", "d", "-3d", "yesterday", "2026-13-01", "2026-02-30", "26-1-1", "2026-10"] {
            XCTAssertNil(Trend.parseSince(bad, now: base, calendar: calendar), bad)
        }
    }

    // MARK: - Text, JSON

    private func point(_ id: String, _ wall: Double) -> TrendDocument.Point {
        .init(id: id, time: nil, wall: wall, busy: nil, xcode: nil, commit: nil, branch: nil, machine: nil)
    }

    func testRecentChangeComparesTheLastFiveWithTheFiveBefore() {
        let flat = (1...10).map { point("p\($0)", 10) }
        XCTAssertEqual(Trend.recentChange(flat)?.change ?? 1, 0, accuracy: 1e-9)
        let slower = (1...5).map { point("a\($0)", 10) } + (1...5).map { point("b\($0)", 12) }
        let change = Trend.recentChange(slower)
        XCTAssertEqual(change?.previous, 10)
        XCTAssertEqual(change?.last, 12)
        XCTAssertEqual(change?.change ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertEqual(TrendTextReporter.arrow(slower), "↑ +20.0 %")
        XCTAssertEqual(TrendTextReporter.arrow((1...5).map { point("a\($0)", 10) } + (1...5).map { point("b\($0)", 8) }), "↓ -20.0 %")
        XCTAssertEqual(TrendTextReporter.arrow(flat), "→ +0.0 %")
        XCTAssertNil(Trend.recentChange([point("only", 3)]))
        XCTAssertNil(Trend.recentChange((1...5).map { point("a\($0)", 3) }), "nothing before the newest five")
        XCTAssertEqual(TrendTextReporter.arrow([point("only", 3)]), "-")
    }

    func testTextReportShowsATablePerGroup() throws {
        let dir = try makeHistoryDirectory()
        for (minute, wall) in [(1.0, 10.0), (2, 10), (3, 10), (4, 10), (5, 10), (6, 12), (7, 12), (8, 12), (9, 12), (10, 12)] {
            try TrendFixture.save(.init(minutes: minute, wall: wall, xcode: minute < 6 ? "26.0" : "26.1"), in: dir)
        }
        let text = TrendTextReporter.render(try run(dir, .init(kind: "clean", by: .xcode)))
        XCTAssertTrue(text.hasPrefix("xcblame trend: 10 of 10 history entries\nfilter: kind clean, by xcode\n"), text)
        XCTAssertTrue(text.contains("xcode 26.0: 5 entries"), text)
        XCTAssertTrue(text.contains("xcode 26.1: 5 entries"), text)
        XCTAssertTrue(text.contains("KIND   N     P50     P75     P95    LAST  TREND (last 5 vs previous 5)"), text)
        XCTAssertTrue(text.contains("clean  5  10.0 s  10.0 s  10.0 s  10.0 s  -"), text)
        XCTAssertTrue(text.contains("clean  5  12.0 s  12.0 s  12.0 s  12.0 s  -"), text)
        let all = TrendTextReporter.render(try run(dir))
        XCTAssertTrue(all.contains("all builds: 10 entries"), all)
        XCTAssertTrue(all.contains("↑ +20.0 %"), all)
        XCTAssertTrue(all.contains("clean: Xcode 26.0 -> 26.1 at "), all)
    }

    func testJSONIsKeyStableAndRoundTrips() throws {
        let dir = try makeHistoryDirectory()
        try TrendFixture.save(.init(minutes: 1, commit: TrendFixture.hash("a"), branch: "main"), in: dir)
        try TrendFixture.save(.init(minutes: 2, kind: "incremental", wall: 3), in: dir)
        let doc = try run(dir, .init(by: .branch))
        let first = try Trend.renderJSON(doc)
        XCTAssertEqual(first, try Trend.renderJSON(try run(dir, .init(by: .branch))), "two runs over one input are byte-equal")
        XCTAssertEqual(first.last, UInt8(ascii: "\n"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(object.keys.sorted(), ["entriesTotal", "entriesUsed", "filter", "generatedAt", "groups", "notes",
                                              "redacted", "schemaVersion", "tool"])
        XCTAssertEqual(object["schemaVersion"] as? String, "xcblame.trend/1")
        let groups = try XCTUnwrap(object["groups"] as? [[String: Any]])
        let seriesObject = try XCTUnwrap((groups[0]["series"] as? [[String: Any]])?.first)
        let pointObject = try XCTUnwrap((seriesObject["points"] as? [[String: Any]])?.first)
        XCTAssertEqual(pointObject.keys.sorted(), ["branch", "busy", "commit", "id", "machine", "time", "wall", "xcode"])
        // A member that is unknown serializes as null (never omitted, never 0).
        let withoutGit = try XCTUnwrap((((groups.last?["series"] as? [[String: Any]])?.last?["points"]) as? [[String: Any]])?.first)
        XCTAssertTrue(withoutGit["commit"] is NSNull)
        XCTAssertEqual(try JSONReporter.decoder().decode(TrendDocument.self, from: first), doc)
    }

    // MARK: - HTML

    /// The `#xcblame-data` content of a page.
    private func blob(of html: Data) throws -> String {
        let page = String(decoding: html, as: UTF8.self)
        let open = try XCTUnwrap(page.range(of: "id=\"xcblame-data\" data-encoding=\"json\">"))
        let close = try XCTUnwrap(page.range(of: "</script>", range: open.upperBound..<page.endIndex))
        return String(page[open.upperBound..<close.lowerBound])
    }

    func testHTMLBlobIsTheJSONOutput() throws {
        let dir = try makeHistoryDirectory()
        try TrendFixture.save(.init(minutes: 1, branch: "feature/</script><!--x"), in: dir)
        try TrendFixture.save(.init(minutes: 2), in: dir)
        let doc = try run(dir, .init(by: .branch))
        let html = try HTMLReporter.renderTrend(doc, options: .init(redact: false, title: "xcblame trend"))
        let json = String(decoding: try Trend.renderJSON(doc), as: UTF8.self)
        let embedded = try blob(of: html)
        // The one difference is the script-data escaping of `<`.
        XCTAssertEqual(embedded, HTMLReporter.escapeScriptData(json))
        XCTAssertNotEqual(embedded, json, "the hostile branch name needed escaping")
        XCTAssertEqual(try JSONReporter.decoder().decode(TrendDocument.self, from: Data(embedded.utf8)), doc)
        let page = String(decoding: html, as: UTF8.self)
        XCTAssertTrue(page.contains("<title>xcblame trend</title>"))
        XCTAssertFalse(page.contains(HTMLReporter.dataPlaceholder))
        XCTAssertEqual(html, try HTMLReporter.renderTrend(doc, options: .init(redact: false, title: "xcblame trend")), "deterministic")
    }

    func testRedactedDocumentRendersRedacted() throws {
        let dir = try makeHistoryDirectory()
        try TrendFixture.save(.init(minutes: 1, branch: "ann/fix"), in: dir)
        let context = Redactor.Context(home: "/Users/ann", user: "ann", host: "ann-mac.local")
        let doc = try Redactor.redact(try run(dir), context: context)
        XCTAssertTrue(doc.redacted)
        let html = try HTMLReporter.renderTrend(doc, options: .init(redact: true, title: "t"))
        XCTAssertTrue(try blob(of: html).contains("\"$USER/fix\""))
        XCTAssertFalse(try blob(of: html).contains("ann/fix"))
    }
}
