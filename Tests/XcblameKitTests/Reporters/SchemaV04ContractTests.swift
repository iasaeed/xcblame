import XCTest
@testable import XcblameKit

/// Sample values of the v0.4 documents, for the contract tests and the lanes' own tests (docs/SCHEMA-v0.4.md).
enum V04Samples {
    static let tool = ReportDocument.Tool(name: "xcblame", version: XcblameVersion.current, kindTable: "2026.10.2")
    static let date = Date(timeIntervalSince1970: 1_700_000_000)

    static func delta(_ baseline: Double?, _ current: Double?) -> ReportDocument.Regression.Delta {
        let diff = baseline.flatMap { b in current.map { $0 - b } }
        return .init(baseline: baseline, current: current, delta: diff,
                     deltaPct: baseline.flatMap { b in b > 0 ? diff.map { $0 / b } : nil })
    }

    static let regression = ReportDocument.Regression(
        baseline: .init(source: "file", ref: ".xcblame/baseline.json", savedAt: date, kind: "clean", scheme: "App",
                        configuration: "Debug", destination: "macOS arm64", xcode: "26.0", runs: 5),
        verdict: "slower", wallBasis: "span", wall: delta(18, 19), busy: delta(17, 18), criticalPath: delta(18, 19),
        noiseBand: .init(method: "mad", pooledMad: 0.2, madMultiplier: 3, minPct: 0.02, band: 0.6, runsBaseline: 5,
                         runsCurrent: 5),
        attribution: [.init(kind: "env", subject: "xcode", detail: "26.0 -> 26.1 (inferred)", deltaSeconds: nil),
                      .init(kind: "target", subject: "App", detail: "+0.80 s task time", deltaSeconds: 0.8)],
        thresholdPct: 0.05, allowancePct: 0.05, failed: true, notes: [])

    static let baseline = Baseline(
        tool: tool, savedAt: date, source: .init(kind: "history", refs: ["20261101-120000-clean"]),
        key: .init(kind: "clean", scheme: "App", configuration: "Debug", destination: "macOS arm64", xcode: "26.0"),
        wallBasis: "span", runs: 5, wall: .init(median: 18, mad: 0.2), busy: .init(median: 17, mad: 0.1),
        criticalPath: .init(median: 18, mad: 0.2), git: GitInfo(branch: "main", commit: String(repeating: "a", count: 40),
                                                                 dirty: false, remoteHost: "github.com"),
        machine: "Mac15,14/28c/96g", tasks: .init(total: 2, ids: ["0011223344556677", "8899aabbccddeeff"]), notes: [])

    static func side(_ label: String) -> CompareDocument.Side {
        .init(label: label, source: "\(label).json", runs: 1, generatedAt: date, toolVersion: "0.4.0", kind: "clean",
              scheme: "App", configuration: "Debug", destination: "macOS arm64", xcode: "26.0", wall: 18, busy: 17,
              criticalPath: 18, tasks: 577, errors: 0, warnings: 1, degraded: false, git: nil, machine: nil)
    }

    static let compare = CompareDocument(
        tool: tool, generatedAt: date, a: side("a"), b: side("b"), regression: regression,
        env: [.init(field: "xcode", a: "26.0", b: "26.1")], envCompared: 16,
        phases: [.init(key: "compile", status: "changed",
                       seconds: .init(a: 10, b: 11, delta: 1, deltaPct: 0.1), tasks: nil, isOther: false)],
        targets: [], targetsTotal: 0, targetsShownShare: nil,
        criticalPath: .init(span: .init(a: 18, b: 19, delta: 1, deltaPct: 1 / 18), byTarget: [], byTargetTotal: 0,
                            byTargetShownShare: nil, notes: []),
        tasks: .init(available: false, added: [], addedTotal: 0, addedShownShare: nil, removed: [], removedTotal: 0,
                     removedShownShare: nil, notes: ["task index: a has none"]),
        settings: nil, notes: [], truncation: .init(steps: []), redacted: false)

    static let trend = TrendDocument(
        tool: tool, generatedAt: date, filter: .init(kind: "clean", scheme: nil, since: nil, by: .xcode),
        entriesTotal: 3, entriesUsed: 2,
        groups: [.init(key: "26.0", entries: 2, series: [
            .init(kind: "clean",
                  points: [.init(id: "20261101-120000-clean", time: date, wall: 18, busy: 17, xcode: "26.0",
                                 commit: nil, branch: nil, machine: nil)],
                  wall: .init(n: 1, p50: 18, p75: 18, p95: 18), busy: .init(n: 1, p50: 17, p75: 17, p95: 17),
                  xcodeChangeMarkers: [])])],
        notes: [], redacted: false)
}

/// Tripwire for docs/SCHEMA-v0.4.md: member names of the v0.4 documents. Renaming, removing or retyping one breaks the
/// contract; a lane that needs a change stops and asks.
final class SchemaV04ContractTests: XCTestCase {
    private func keys<T: Encodable>(_ value: T) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: try JSONReporter.encoder().encode(value))
        return try XCTUnwrap(object as? [String: Any]).keys.sorted()
    }

    func testSchemaVersionStrings() {
        XCTAssertEqual(ReportDocument.schemaVersion, "xcblame.report/1")
        XCTAssertEqual(CompareDocument.schemaVersion, "xcblame.compare/1")
        XCTAssertEqual(TrendDocument.schemaVersion, "xcblame.trend/1")
        XCTAssertEqual(Baseline.schemaVersion, "xcblame.baseline/1")
        XCTAssertEqual(XcblameVersion.current, "0.6.1")
    }

    func testRegressionKeys() throws {
        let regression = V04Samples.regression
        XCTAssertEqual(try keys(regression), [
            "allowancePct", "attribution", "baseline", "busy", "criticalPath", "failed", "noiseBand", "notes",
            "thresholdPct", "verdict", "wall", "wallBasis",
        ])
        XCTAssertEqual(try keys(regression.baseline), [
            "configuration", "destination", "kind", "ref", "runs", "savedAt", "scheme", "source", "xcode",
        ])
        XCTAssertEqual(try keys(regression.wall), ["baseline", "current", "delta", "deltaPct"])
        XCTAssertEqual(try keys(regression.noiseBand), [
            "band", "madMultiplier", "method", "minPct", "pooledMad", "runsBaseline", "runsCurrent",
        ])
        XCTAssertEqual(try keys(regression.attribution[0]), ["deltaSeconds", "detail", "kind", "subject"])
        // Unknowns stay explicit nulls.
        var unknown = regression
        unknown.thresholdPct = nil
        unknown.noiseBand.pooledMad = nil
        XCTAssertTrue(try keys(unknown).contains("thresholdPct"))
        XCTAssertTrue(try keys(unknown.noiseBand).contains("pooledMad"))
    }

    func testBaselineKeys() throws {
        let baseline = V04Samples.baseline
        XCTAssertEqual(try keys(baseline), [
            "busy", "criticalPath", "git", "key", "machine", "notes", "runs", "savedAt", "schemaVersion", "source",
            "tasks", "tool", "wall", "wallBasis",
        ])
        XCTAssertEqual(try keys(baseline.key), ["configuration", "destination", "kind", "scheme", "xcode"])
        XCTAssertEqual(try keys(baseline.wall), ["mad", "median"])
        XCTAssertEqual(try keys(baseline.source), ["kind", "refs"])
        XCTAssertEqual(try keys(try XCTUnwrap(baseline.tasks)), ["ids", "total"])
        XCTAssertEqual(try keys(try XCTUnwrap(baseline.git)), ["branch", "commit", "dirty", "remoteHost"])
        XCTAssertEqual(Baseline.fileName, "baseline.json")
    }

    func testCompareDocumentKeys() throws {
        let compare = V04Samples.compare
        XCTAssertEqual(try keys(compare), [
            "a", "b", "criticalPath", "env", "envCompared", "generatedAt", "notes", "phases", "redacted",
            "regression", "schemaVersion", "settings", "targets", "targetsShownShare", "targetsTotal", "tasks", "tool",
            "truncation",
        ])
        XCTAssertEqual(try keys(compare.a), [
            "busy", "configuration", "criticalPath", "degraded", "destination", "errors", "generatedAt",
            "git", "kind", "label", "machine", "runs", "scheme", "source", "tasks", "toolVersion", "wall", "warnings",
            "xcode",
        ])
        XCTAssertEqual(try keys(compare.env[0]), ["a", "b", "field"])
        XCTAssertEqual(try keys(try XCTUnwrap(compare.phases?[0])), ["isOther", "key", "seconds", "status", "tasks"])
        XCTAssertEqual(try keys(compare.criticalPath!), ["byTarget", "byTargetShownShare", "byTargetTotal", "notes", "span"])
        XCTAssertEqual(try keys(compare.tasks), [
            "added", "addedShownShare", "addedTotal", "available", "changed", "changedShownShare", "changedTotal", "notes",
            "removed", "removedShownShare", "removedTotal",
        ])
        XCTAssertEqual(try keys(CompareDocument.TaskRef(rule: "r", target: nil, kind: "k", seconds: 1, onPath: false)),
                       ["kind", "onPath", "rule", "seconds", "target", "title"])
        XCTAssertEqual(try keys(CompareDocument.SettingDiff(ref: "r", a: nil, b: nil, provenanceA: nil, provenanceB: nil)),
                       ["a", "b", "provenanceA", "provenanceB", "ref"])
    }

    func testTrendDocumentKeys() throws {
        let trend = V04Samples.trend
        XCTAssertEqual(try keys(trend), [
            "entriesTotal", "entriesUsed", "filter", "generatedAt", "groups", "notes", "redacted", "schemaVersion",
            "tool",
        ])
        XCTAssertEqual(try keys(trend.filter), ["by", "kind", "scheme", "since"])
        XCTAssertEqual(try keys(trend.groups[0]), ["entries", "key", "series"])
        XCTAssertEqual(try keys(trend.groups[0].series[0]), ["busy", "kind", "points", "wall", "xcodeChangeMarkers"])
        XCTAssertEqual(try keys(trend.groups[0].series[0].points[0]), [
            "branch", "busy", "commit", "id", "machine", "time", "wall", "xcode",
        ])
        XCTAssertEqual(try keys(trend.groups[0].series[0].wall), ["n", "p50", "p75", "p95"])
        XCTAssertEqual(try keys(TrendDocument.XcodeChange(atId: "x", from: nil, to: "26.1", time: nil)),
                       ["atId", "from", "time", "to"])
        XCTAssertEqual(TrendDocument.By.allCases.map(\.rawValue), ["xcode", "branch", "commit", "machine"])
    }

    func testReportDocumentGainsTheV04MembersAndBuildContext() throws {
        let model = BuildModelBuilder.build(try SLFReader.read(url: SLFFixtures.cli26Clean), reader: .slf)
        let document = try ReportPipeline.run(model, options: .init(generatedAt: Date(timeIntervalSince1970: 0))).document
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONReporter.render(document)) as? [String: Any])
        XCTAssertTrue(json["regression"] is NSNull)
        XCTAssertNil(document.regression)
        XCTAssertEqual(json["diagnosticsTotal"] as? Int, document.diagnosticsSummary.errors + document.diagnosticsSummary.warnings)
        XCTAssertEqual((json["diagnostics"] as? [Any])?.count, document.diagnostics.count)
        let build = try XCTUnwrap(json["build"] as? [String: Any])
        for key in ["scheme", "configuration", "destination"] { XCTAssertTrue(build[key] is NSNull, key) }
        // A report written before v0.4 decodes with the members nil / empty / 0.
        var old = json
        for key in ["regression", "diagnostics", "diagnosticsTotal", "diagnosticsShownShare"] { old[key] = nil }
        var oldBuild = build
        for key in ["scheme", "configuration", "destination"] { oldBuild[key] = nil }
        old["build"] = oldBuild
        let decoded = try JSONReporter.decoder().decode(ReportDocument.self,
                                                        from: try JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.regression)
        XCTAssertEqual(decoded.diagnostics, [])
        XCTAssertEqual(decoded.diagnosticsTotal, 0)
        XCTAssertNil(decoded.build.scheme)
    }

    func testDiagnosticEntryKeysAndOrdering() throws {
        let entry = ReportDocument.DiagnosticEntry(severity: "error", file: "A.swift", line: 3, column: 4, message: "m",
                                                   occurrences: 2)
        XCTAssertEqual(try keys(entry), ["column", "file", "line", "message", "occurrences", "severity"])
        var collector = DiagnosticCollector()
        var interner = StringInterner()
        func add(_ severity: Int, _ title: String, times: Int) {
            for _ in 0..<times {
                collector.add(RawMessage(title: title, severity: severity), taskId: nil, interner: &interner)
            }
        }
        add(1, "warn once", times: 1)
        add(1, "warn thrice", times: 3)
        add(2, "error once", times: 1)
        add(0, "a notice", times: 5)
        var model = SyntheticModel.make()
        model.diagnostics = collector.diagnostics
        let members = ReportDocument.diagnosticMembers(model: model, topN: 15)
        XCTAssertEqual(members.rows.map(\.message), ["error once", "warn thrice", "warn once"])
        XCTAssertEqual(members.total, 3)
        XCTAssertEqual(members.shownShare, 1)
        XCTAssertEqual(ReportDocument.diagnosticMembers(model: model, topN: 1).rows.map(\.message), ["error once"])
    }

    func testEnvironmentGitIsOmittedWhenNilAndCodableWhenSet() throws {
        var env = EnvSnapshot()
        XCTAssertNil(env.git)
        XCTAssertFalse(try keys(env).contains("git"))
        env.git = GitInfo(branch: "main", commit: "abc", dirty: true, remoteHost: "github.com")
        XCTAssertTrue(try keys(env).contains("git"))
        let back = try JSONDecoder().decode(EnvSnapshot.self, from: JSONEncoder().encode(env))
        XCTAssertEqual(back.git, env.git)
    }

    func testV04DocumentsRoundTrip() throws {
        func trip<T: Codable & Equatable>(_ value: T) throws {
            let back = try JSONReporter.decoder().decode(T.self, from: try JSONReporter.encoder().encode(value))
            XCTAssertEqual(back, value)
        }
        try trip(V04Samples.regression)
        try trip(V04Samples.baseline)
        try trip(V04Samples.compare)
        try trip(V04Samples.trend)
    }

    func testBuildContextFlowsThroughThePipelineIntoBuild() throws {
        var options = ReportPipeline.Options(generatedAt: Date(timeIntervalSince1970: 0))
        options.buildContext = BuildContext(scheme: "App", configuration: "Debug", destination: "macOS arm64")
        let document = try ReportPipeline.run(SyntheticModel.make(), options: options).document
        XCTAssertEqual(document.build.scheme, "App")
        XCTAssertEqual(document.build.configuration, "Debug")
        XCTAssertEqual(document.build.destination, "macOS arm64")
    }

    func testRedactorCoversCompareAndTrendDocuments() throws {
        let context = Redactor.Context(home: "/Users/ann", user: "ann", host: "ann-mac", repoRoot: "/Users/ann/Work/App")
        var compare = V04Samples.compare
        compare.a.source = "/Users/ann/Work/App/a.json"
        let redactedCompare = try Redactor.redact(compare, context: context)
        XCTAssertTrue(redactedCompare.redacted)
        XCTAssertEqual(redactedCompare.a.source, "$REPO/a.json")
        var trend = V04Samples.trend
        trend.groups[0].series[0].points[0].branch = "ann/fix"
        let redactedTrend = try Redactor.redact(trend, context: context)
        XCTAssertTrue(redactedTrend.redacted)
        XCTAssertEqual(redactedTrend.groups[0].series[0].points[0].branch, "$USER/fix")
    }
}
