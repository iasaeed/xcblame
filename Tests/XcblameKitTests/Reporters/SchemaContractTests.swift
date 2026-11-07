import XCTest
@testable import XcblameKit

/// Tripwire for docs/SCHEMA-v0.2.md: the exact member names of the report document and its v0.2 objects. A lane that
/// renames or drops a member fails here; adding one means updating this test and the schema doc together.
final class SchemaContractTests: XCTestCase {
    private func cleanReport() throws -> [String: Any] {
        let model = BuildModelBuilder.build(try SLFReader.read(url: SLFFixtures.cli26Clean), reader: .slf)
        let document = try ReportPipeline.run(model, options: .init(generatedAt: Date(timeIntervalSince1970: 0))).document
        return try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONReporter.render(document)) as? [String: Any])
    }

    private func keys<T: Encodable>(_ value: T) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: try JSONReporter.encoder().encode(value))
        return try XCTUnwrap(object as? [String: Any]).keys.sorted()
    }

    private func keys(_ object: Any?) throws -> [String] {
        try XCTUnwrap(object as? [String: Any]).keys.sorted()
    }

    func testTopLevelAndV02ObjectKeysOnTheCleanXcode26Fixture() throws {
        let json = try cleanReport()
        XCTAssertEqual(json.keys.sorted(), [
            "build", "criticalPath", "decodeWarnings", "decodeWarningsTotal", "deep", "degradations", "degraded",
            "diagnostics", "diagnosticsShownShare", "diagnosticsSummary", "diagnosticsTotal", "doctor", "environment",
            "files", "filesShownShare", "filesTotal", "findings",
            "findingsTotal", "fixPlan", "fixedCosts", "generatedAt", "graph", "hotspots", "hotspotsShownShare", "hotspotsTotal",
            "incremental", "input", "kinds", "metrics", "moduleGraph", "notes", "phases", "project", "redacted", "regression",
            "ruleDocs", "schemaVersion",
            "targets", "targetsShownShare", "targetsTotal", "timing", "tool", "topN", "topTasks", "topTasksShownShare",
            "topTasksTotal", "truncation", "validation", "xcode",
        ])
        XCTAssertEqual(json["schemaVersion"] as? String, "xcblame.report/1")
        XCTAssertEqual(try keys(json["graph"]),
                       ["basis", "commands", "keyedTasks", "notes", "path", "signature", "unkeyedTasks"])
        XCTAssertEqual(try keys(json["timing"]), [
            "idleGaps", "idleGapsShownShare", "idleGapsTotal", "notes", "outsideLogSeconds", "peakLanes", "processWall",
            "serialSeconds", "serialStretches", "serialStretchesShownShare", "serialStretchesTotal",
            "serialThresholdLanes", "utilization",
        ])
        XCTAssertEqual(try keys(json["truncation"]), ["steps"])
        XCTAssertTrue(try keys(json["build"]).contains("kindEvidence"))
        let target = try XCTUnwrap((json["targets"] as? [[String: Any]])?.first)
        XCTAssertEqual(target.keys.sorted(), [
            "busy", "id", "isBucket", "isOther", "isPackage", "kinds", "name", "onPathSeconds", "owner", "project",
            "share", "taskTime", "tasks", "whatIfSeconds",
        ])

        // Lane A filled: path (inferred, no description in this test), files and hotspots. Until the other lanes
        // land: empty findings, nothing truncated or redacted.
        let path = try XCTUnwrap(json["criticalPath"] as? [String: Any])
        XCTAssertEqual(path["basis"] as? String, "inferred")
        XCTAssertTrue(path["whatIf"] is NSNull)
        XCTAssertNotNil(json["files"] as? [Any])
        XCTAssertNotNil(json["hotspots"] as? [Any])
        let build0 = try XCTUnwrap(json["build"] as? [String: Any])
        XCTAssertEqual(build0["kind"] as? String, "clean")
        XCTAssertEqual((json["findings"] as? [Any])?.count, 0)
        XCTAssertEqual(json["findingsTotal"] as? Int, 0)
        XCTAssertEqual((json["ruleDocs"] as? [String: Any])?.count, 0)
        XCTAssertEqual(((json["truncation"] as? [String: Any])?["steps"] as? [Any])?.count, 0)
        // v0.3: no project for a fixture log, no rule run yet.
        XCTAssertTrue(json["project"] is NSNull)
        XCTAssertTrue(json["doctor"] is NSNull)
        XCTAssertEqual((json["fixPlan"] as? [Any])?.count, 0)
        XCTAssertEqual(json["redacted"] as? Bool, false)
        let graph = try XCTUnwrap(json["graph"] as? [String: Any])
        XCTAssertEqual(graph["basis"] as? String, "none")
        let build = try XCTUnwrap(json["build"] as? [String: Any])
        XCTAssertEqual((graph["keyedTasks"] as? Int ?? 0) + (graph["unkeyedTasks"] as? Int ?? 0),
                       build["tasksInModel"] as? Int)
    }

    func testNestedV02ObjectKeys() throws {
        typealias D = ReportDocument
        let segment = D.PathSegment(start: 0, end: 1, seconds: 1, share: 1, basis: "dag", target: nil, targetId: nil,
                                    label: "x", taskIds: [])
        XCTAssertEqual(try keys(segment),
                       ["basis", "end", "label", "seconds", "share", "start", "target", "targetId", "taskIds"])
        let path = D.CriticalPath(span: 1, basis: "dag", segments: [segment], segmentsTotal: 1, segmentsShownShare: 1,
                                  waits: [D.PathWait(start: 0, end: 0, seconds: 0)],
                                  whatIf: [D.WhatIf(target: "A", targetId: nil, savingIfZero: 0, savingIfHalf: 0)],
                                  notes: [])
        XCTAssertEqual(try keys(path),
                       ["basis", "notes", "segments", "segmentsShownShare", "segmentsTotal", "span", "waits", "whatIf"])
        XCTAssertEqual(try keys(D.PathWait(start: 0, end: 0, seconds: 0)), ["end", "seconds", "start"])
        XCTAssertEqual(try keys(D.WhatIf(target: "A", targetId: nil, savingIfZero: 0, savingIfHalf: 0)),
                       ["savingIfHalf", "savingIfZero", "target", "targetId"])
        XCTAssertEqual(try keys(D.Utilization(bucketSeconds: 0.1, lanes: [])), ["bucketSeconds", "lanes"])
        XCTAssertEqual(try keys(D.SerialStretch(start: 0, end: 1, lanes: 1)), ["end", "lanes", "start"])
        XCTAssertEqual(try keys(D.Gap(start: 0, end: 1)), ["end", "start"])
        XCTAssertEqual(try keys(D.FileRow(path: "a.swift", target: nil, targetId: nil, seconds: 1, granularity: "exact",
                                          batchSize: nil, members: nil, onPath: false, typeCheckMs: nil, taskId: nil)),
                       ["batchSize", "granularity", "members", "onPath", "path", "seconds", "target", "targetId",
                        "taskId", "typeCheckMs"])
        XCTAssertEqual(try keys(D.Hotspot(file: "a.swift", line: 1, col: 1, declaration: "f", kind: "functionBody",
                                          ms: 1, source: "warnLong", onPathWeight: 1, occurrences: 1, target: nil,
                                          taskId: nil)),
                       ["col", "declaration", "file", "kind", "line", "ms", "occurrences", "onPathWeight", "source",
                        "target", "taskId"])
        XCTAssertEqual(try keys(D.Finding(ruleId: "SET-001", title: "t", severity: nil, impactBand: nil,
                                          impactSeconds: nil, impactBasis: nil, confidence: "high", evidence: [],
                                          fixKind: nil, risk: nil, mechanism: nil, signalKey: "k")),
                       ["confidence", "estimatedBand", "evidence", "evidenceDetails", "fixCommands", "fixKind", "impactBand",
                        "impactBasis", "impactSeconds", "inXcode", "mechanism", "needsMeasurement", "overlayLines", "risk",
                        "ruleId", "scopeConfigurations", "scopeTargets", "seeAlso", "severity", "signalKey", "sources",
                        "title", "xcode"])
        XCTAssertEqual(try keys(D.RuleDoc(title: "t", summary: "s", fix: "f", sources: [], id: "SET-001",
                                          category: "SET", applyKinds: [], verifyOnly: false, risk: "r",
                                          evidenceTag: "P")),
                       ["applyKinds", "category", "evidenceTag", "fix", "id", "risk", "sources", "summary", "title",
                        "verifyOnly"])
        XCTAssertEqual(try keys(D.TruncationStep(step: "hotspots", kept: 1, total: 2, shownShare: nil)),
                       ["kept", "shownShare", "step", "total"])
    }

    func testNestedV03ObjectKeys() throws {
        typealias D = ReportDocument
        XCTAssertEqual(try keys(D.EvidenceItem(kind: "setting", ref: "Acme:Debug:SWIFT_COMPILATION_MODE")),
                       ["kind", "provenance", "ref", "value"])
        XCTAssertEqual(try keys(D.RuleOutcome(ruleId: "SET-002", title: "t", detail: "d")),
                       ["detail", "ruleId", "title"])
        XCTAssertEqual(try keys(D.ProjectSection(container: "A.xcodeproj", format: "pbxproj", objectVersion: 77,
                                                 generator: nil, targets: 1, packageTargets: nil, localPackages: 0,
                                                 remotePackages: 0, dependencyManagers: [], schemes: 0,
                                                 settingsSource: nil, configurations: [], notes: [])),
                       ["configurations", "container", "dependencyManagers", "format", "generator", "localPackages",
                        "notes", "objectVersion", "packageTargets", "remotePackages", "schemes", "settingsSource",
                        "targets"])
        XCTAssertEqual(try keys(D.DoctorSection(passed: [], notApplicable: [], suppressed: [], rulesEvaluated: 0,
                                                durationSeconds: nil, offline: false, failOn: nil, failed: false)),
                       ["durationSeconds", "failOn", "failed", "notApplicable", "offline", "passed", "rulesEvaluated",
                        "suppressed"])
        XCTAssertEqual(try keys(D.FixPlanStep(order: 1, ruleId: "SET-016", command: "xcblame verify", note: nil)),
                       ["command", "kind", "note", "order", "ruleId", "verifyStatus"])
    }

    /// `@Added` members: a report saved before v0.3 (no `project`, `doctor`, `fixPlan`) still decodes.
    func testV02SavedReportDecodesWithoutV03Members() throws {
        let model = SyntheticModel.make()
        let document = try ReportPipeline.run(model, options: .init(generatedAt: Date(timeIntervalSince1970: 0))).document
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONReporter.render(document)) as? [String: Any])
        for key in ["project", "doctor", "fixPlan"] { XCTAssertNotNil(object.removeValue(forKey: key), key) }
        let decoded = try JSONReporter.decoder().decode(ReportDocument.self,
                                                        from: try JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.project)
        XCTAssertNil(decoded.doctor)
        XCTAssertEqual(decoded.fixPlan, [])
        XCTAssertEqual(decoded, document)
    }

    func testTaskIndexStubKeysAndTotal() throws {
        let model = SyntheticModel.make()
        let result = try ReportPipeline.run(model)
        let index = TaskIndex.make(model: model, analysis: result.analysis, document: result.document)
        // Lane A: every synthetic task is timed and not reused, so the total equals `build.tasks` and the model count.
        XCTAssertEqual(index.taskIndexTotal, result.document.build.tasks)
        XCTAssertEqual(index.taskIndexTotal, model.tasks.count)
        XCTAssertEqual(index.taskIndexShownShare, 1)
        XCTAssertEqual(try keys(index), [
            "dropped", "dur", "kind", "kinds", "label", "labels", "lane", "onPath", "start", "target", "targets",
            "taskIndexShownShare", "taskIndexTotal",
        ])
        XCTAssertEqual(try keys(TaskIndex.Dropped(target: 0, lane: 0, tasks: 1, seconds: 1)),
                       ["lane", "seconds", "target", "tasks"])
    }
}
