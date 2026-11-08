import Foundation

/// `xcblame schema`: JSON Schema (draft 2020-12) of the four v0.4 documents (docs/SCHEMA-v0.4.md "JSON Schema") and the
/// two v0.6 documents, `fixplan` and `verify` (docs/SCHEMA-v0.6.md "Text, formats, JSON Schema").
///
/// The schema is generated from one Swift mirror table per document (`SchemaTable`): key, type, nullability. Tests encode
/// real sample documents and validate them against the produced schema, and compare every encoded key set with the
/// table, so a member added to a document type and forgotten here fails a test.
public enum JSONSchema {
    public static let dialect = "https://json-schema.org/draft/2020-12/schema"

    public enum Document: String, Sendable, CaseIterable {
        case report, compare, trend, baseline
        /// v0.6: `xcblame.fixplan/1` and `xcblame.verify/1`.
        case fixplan, verify
        /// One schema with every document under `$defs` and `oneOf` at the root.
        case all
    }

    /// The `--version` values `render` accepts: the major of every `schemaVersion` (`xcblame.report/1`, ...).
    public static let versions = [1]

    /// Pretty-printed JSON with sorted keys, ending in a newline.
    public static func render(_ document: Document, version: Int = 1) throws -> String {
        guard versions.contains(version) else {
            throw XcblameError.usage("schema version \(version) is unknown (known: " + versions.map(String.init).joined(separator: ", ") + ")")
        }
        let data = try JSONSerialization.data(withJSONObject: object(document, version: version),
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    /// The schema as a JSON object tree (what `render` serializes).
    public static func object(_ document: Document, version: Int = 1) -> [String: Any] {
        switch document {
        case .all:
            var defs: [String: Any] = [:]
            for part in Document.allCases where part != .all {
                defs[part.rawValue] = body(part, version: version, refPrefix: "#/$defs/\(part.rawValue)/$defs/")
            }
            return [
                "$schema": dialect, "$id": "urn:xcblame:schema:all:\(version)",
                "title": "xcblame documents (report, compare, trend, baseline, fixplan, verify), version \(version)",
                "$defs": defs, "oneOf": Document.allCases.filter { $0 != .all }.map { ["$ref": "#/$defs/\($0.rawValue)"] },
            ]
        default:
            var root = body(document, version: version, refPrefix: "#/$defs/")
            root["$schema"] = dialect
            root["$id"] = "urn:xcblame:schema:\(document.rawValue):\(version)"
            return root
        }
    }

    private static func body(_ document: Document, version: Int, refPrefix: String) -> [String: Any] {
        let root = SchemaTable.root(document)
        var out = SchemaTable.objectSchema(root.fields, refPrefix: refPrefix)
        out["title"] = root.title
        var defs: [String: Any] = [:]
        for name in SchemaTable.closure(of: root.fields) {
            defs[name] = SchemaTable.objectSchema(SchemaTable.objects[name] ?? [], refPrefix: refPrefix)
        }
        out["$defs"] = defs
        return out
    }
}

// MARK: - Mirror table

/// A JSON Schema type of one member.
indirect enum SchemaType: Sendable {
    case str, int, num, bool, date
    /// A closed set of strings.
    case enumeration([String])
    case const(String)
    /// An object definition of `SchemaTable.objects`.
    case ref(String)
    case array(SchemaType)
    /// An object with any keys, every value of the type.
    case map(SchemaType)
    /// An object with no description of its members.
    case obj
}

struct SchemaField: Sendable {
    var key: String
    var type: SchemaType
    /// Serializes as `null` when unknown (`@Null`, `@Added`): the type also admits null.
    var null: Bool
    /// May be absent from the document (`EnvSnapshot` members, the HTML-only task index): not in `required`.
    var optional: Bool

    init(_ key: String, _ type: SchemaType, null: Bool = false, optional: Bool = false) {
        self.key = key
        self.type = type
        self.null = null
        self.optional = optional
    }
}

enum SchemaTable {
    typealias F = SchemaField

    struct Root {
        var title: String
        var fields: [F]
    }

    static func root(_ document: JSONSchema.Document) -> Root {
        switch document {
        case .report, .all: return Root(title: "xcblame report (xcblame.report/1)", fields: reportFields)
        case .compare: return Root(title: "xcblame compare (xcblame.compare/1)", fields: compareFields)
        case .trend: return Root(title: "xcblame trend (xcblame.trend/1)", fields: trendFields)
        case .baseline: return Root(title: "xcblame baseline (xcblame.baseline/1)", fields: baselineFields)
        case .fixplan: return Root(title: "xcblame fix plan (xcblame.fixplan/1)", fields: fixPlanFields)
        case .verify: return Root(title: "xcblame verify (xcblame.verify/1)", fields: verifyFields)
        }
    }

    // MARK: JSON

    static func objectSchema(_ fields: [F], refPrefix: String) -> [String: Any] {
        var properties: [String: Any] = [:]
        for field in fields { properties[field.key] = memberSchema(field, refPrefix: refPrefix) }
        return ["type": "object", "required": fields.filter { !$0.optional }.map(\.key).sorted(),
                "properties": properties, "additionalProperties": true]
    }

    static func memberSchema(_ field: F, refPrefix: String) -> [String: Any] {
        typeSchema(field.type, null: field.null, refPrefix: refPrefix)
    }

    static func typeSchema(_ type: SchemaType, null: Bool, refPrefix: String) -> [String: Any] {
        func typed(_ name: String, _ extra: [String: Any] = [:]) -> [String: Any] {
            var out = extra
            out["type"] = null ? [name, "null"] : name
            return out
        }
        switch type {
        case .str: return typed("string")
        case .int: return typed("integer")
        case .num: return typed("number")
        case .bool: return typed("boolean")
        case .date: return typed("string", ["format": "date-time"])
        case let .enumeration(values): return typed("string", ["enum": null ? values + [NSNull()] : values as [Any]])
        case let .const(value): return ["const": value]
        case let .ref(name):
            let reference: [String: Any] = ["$ref": refPrefix + name]
            return null ? ["anyOf": [reference, ["type": "null"]]] : reference
        case let .array(inner): return typed("array", ["items": typeSchema(inner, null: false, refPrefix: refPrefix)])
        case let .map(inner): return typed("object", ["additionalProperties": typeSchema(inner, null: false, refPrefix: refPrefix)])
        case .obj: return typed("object")
        }
    }

    /// The names of the object definitions reachable from `fields`.
    static func closure(of fields: [F]) -> [String] {
        var seen = Set<String>()
        func visit(_ type: SchemaType) {
            switch type {
            case let .ref(name):
                guard seen.insert(name).inserted else { return }
                for field in objects[name] ?? [] { visit(field.type) }
            case let .array(inner), let .map(inner): visit(inner)
            default: break
            }
        }
        for field in fields { visit(field.type) }
        return seen.sorted()
    }

    // MARK: Shorthands

    static func s(_ key: String, null: Bool = false) -> F { F(key, .str, null: null) }
    static func i(_ key: String, null: Bool = false) -> F { F(key, .int, null: null) }
    static func n(_ key: String, null: Bool = false) -> F { F(key, .num, null: null) }
    static func b(_ key: String, null: Bool = false) -> F { F(key, .bool, null: null) }
    static func d(_ key: String, null: Bool = false) -> F { F(key, .date, null: null) }
    static func strings(_ key: String) -> F { F(key, .array(.str)) }
    static func ref(_ key: String, _ name: String, null: Bool = false) -> F { F(key, .ref(name), null: null) }
    static func list(_ key: String, _ name: String, null: Bool = false) -> F { F(key, .array(.ref(name)), null: null) }

    static func schemaVersion(_ value: String) -> F { F("schemaVersion", .const(value)) }

    // MARK: Report

    static let reportFields: [F] = [
        schemaVersion(ReportDocument.schemaVersion), ref("tool", "Tool"), d("generatedAt"), ref("input", "Input"),
        ref("xcode", "Xcode"), ref("environment", "EnvSnapshot", null: true), ref("build", "Build"),
        ref("metrics", "Metrics"),
        list("phases", "Row", null: true), list("kinds", "Row", null: true), list("targets", "TargetRow", null: true),
        i("targetsTotal"), n("targetsShownShare", null: true),
        list("topTasks", "TopTask", null: true), i("topTasksTotal"), n("topTasksShownShare", null: true),
        ref("diagnosticsSummary", "DiagnosticsSummary"), ref("validation", "Validation"), b("degraded"),
        list("degradations", "Degradation"), list("decodeWarnings", "DecodeWarning"), i("decodeWarningsTotal"),
        strings("notes"), i("topN"),
        ref("graph", "Graph"), ref("criticalPath", "CriticalPath", null: true), ref("timing", "Timing"),
        list("files", "FileRow", null: true), i("filesTotal"), n("filesShownShare", null: true),
        list("hotspots", "Hotspot", null: true), i("hotspotsTotal"), n("hotspotsShownShare", null: true),
        list("findings", "Finding"), i("findingsTotal"), F("ruleDocs", .map(.ref("RuleDoc"))),
        ref("truncation", "Truncation"), b("redacted"),
        ref("project", "ProjectSection", null: true), ref("doctor", "DoctorSection", null: true),
        list("fixPlan", "FixPlanStep"),
        ref("regression", "Regression", null: true), list("diagnostics", "DiagnosticEntry"), i("diagnosticsTotal"),
        n("diagnosticsShownShare", null: true),
        // v0.5 (docs/SCHEMA-v0.5.md)
        ref("incremental", "Incremental", null: true), list("fixedCosts", "FixedCost", null: true),
        ref("moduleGraph", "ModuleGraph", null: true), ref("deep", "Deep", null: true),
        // v0.6 addition D1 (docs/SCHEMA-v0.6.md "report: previous")
        ref("previous", "Previous", null: true),
        // HTML only: the page's task index (`--format html`); never in `--format json`.
        F("taskIndex", .ref("TaskIndex"), optional: true),
    ]

    static let objects: [String: [F]] = baseObjects.merging(fixVerifyObjects) { base, _ in base }

    static let baseObjects: [String: [F]] = [
        "Tool": [s("name"), s("version"), s("kindTable")],
        "Input": [s("reader"), s("layout"), i("logFormatVersion", null: true), s("path", null: true), i("decodeWarnings"),
                  strings("excludedActions")],
        "Xcode": [s("value", null: true), s("source", null: true), strings("evidence"), strings("notes")],
        "Build": [
            s("kind", null: true), strings("kindEvidence"), n("span", null: true), n("taskTime", null: true),
            n("busy", null: true), n("idle", null: true), ref("parallelism", "Parallelism"), i("tasks"),
            i("tasksInModel"), i("tasksReused"), i("tasksInvalid"), i("tasksClamped"),
            list("tasksWithoutTiming", "UntimedTask"), i("tasksWithoutTimingTotal"), strings("notes"),
            s("scheme", null: true), s("configuration", null: true), s("destination", null: true),
            ref("cache", "BuildCache", null: true),
        ],
        "Parallelism": [n("average", null: true), i("peak", null: true)],
        "UntimedTask": [i("id"), s("rule"), s("kind"), s("target", null: true), s("title")],
        "Metrics": [i("tasks"), i("tasksWithCPU"), i("placeholdersIgnored"), n("cpuSeconds", null: true), i("tasksWithRSS"),
                    i("maxRSSBytes", null: true), strings("notes")],
        "Row": [s("key"), i("tasks"), n("taskTime"), n("share", null: true), b("isOther")],
        "TargetRow": [
            i("id", null: true), s("name"), s("project", null: true), b("isPackage", null: true), b("isBucket", null: true),
            i("tasks"), n("taskTime"), n("share", null: true), b("isOther"), s("owner", null: true),
            n("onPathSeconds", null: true), n("whatIfSeconds", null: true), n("busy", null: true),
            list("kinds", "Row", null: true),
        ],
        "TopTask": [i("id"), s("rule"), s("kind"), s("target", null: true), n("seconds"), n("startOffset"), s("title")],
        "DiagnosticsSummary": [i("unique"), i("occurrences"), i("errors"), i("warnings"), i("analyzerWarnings"), i("notices"),
                               i("unknown")],
        "Validation": [list("checks", "Check"), b("degraded"), strings("notes")],
        "Check": [s("id"), s("title"), s("status"), s("detail", null: true)],
        "Degradation": [s("kind"), s("detail")],
        "DecodeWarning": [s("kind"), s("detail"), i("offset", null: true)],
        "Graph": [s("basis"), s("signature", null: true), s("path", null: true), i("commands", null: true), i("keyedTasks"),
                  i("unkeyedTasks"), strings("notes")],
        "CriticalPath": [n("span"), s("basis"), list("segments", "PathSegment"), i("segmentsTotal"),
                         n("segmentsShownShare", null: true), list("waits", "PathWait"), list("whatIf", "WhatIf", null: true),
                         strings("notes")],
        "PathSegment": [n("start"), n("end"), n("seconds"), n("share", null: true), s("basis"), s("target", null: true),
                        i("targetId", null: true), s("label"), F("taskIds", .array(.int))],
        "PathWait": [n("start"), n("end"), n("seconds")],
        "WhatIf": [s("target"), i("targetId", null: true), n("savingIfZero"), n("savingIfHalf")],
        "Timing": [
            ref("utilization", "Utilization", null: true), list("serialStretches", "SerialStretch", null: true),
            i("serialStretchesTotal"), n("serialStretchesShownShare", null: true), i("serialThresholdLanes", null: true),
            n("serialSeconds", null: true), list("idleGaps", "Gap", null: true), i("idleGapsTotal"),
            n("idleGapsShownShare", null: true), i("peakLanes", null: true), n("processWall", null: true),
            n("outsideLogSeconds", null: true), strings("notes"),
        ],
        "Utilization": [n("bucketSeconds"), F("lanes", .array(.num))],
        "SerialStretch": [n("start"), n("end"), i("lanes")],
        "Gap": [n("start"), n("end")],
        "FileRow": [s("path"), s("target", null: true), i("targetId", null: true), n("seconds"), s("granularity"),
                    i("batchSize", null: true), F("members", .array(.str), null: true), b("onPath"),
                    n("typeCheckMs", null: true), i("taskId", null: true)],
        "Hotspot": [s("file"), i("line"), i("col"), s("declaration"), s("kind"), n("ms"), s("source"), n("onPathWeight"),
                    i("occurrences"), s("target", null: true), i("taskId", null: true)],
        "Finding": [
            s("ruleId"), s("title"), s("severity", null: true), s("impactBand", null: true), n("impactSeconds", null: true),
            s("impactBasis", null: true), s("confidence"), strings("evidence"), s("fixKind", null: true),
            s("risk", null: true), s("mechanism", null: true), s("signalKey"), strings("scopeTargets"),
            strings("scopeConfigurations"), list("evidenceDetails", "EvidenceItem"), strings("fixCommands"),
            strings("overlayLines"), strings("seeAlso"), s("xcode", null: true), strings("sources"), b("needsMeasurement"),
            strings("inXcode"), s("estimatedBand", null: true),
        ],
        "EvidenceItem": [s("kind"), s("ref"), s("value", null: true), s("provenance", null: true)],
        "RuleDoc": [s("title"), s("summary"), s("fix"), strings("sources"), s("id"), s("category"), strings("applyKinds"),
                    b("verifyOnly"), s("risk"), s("evidenceTag")],
        "Previous": [n("span"), s("kind"), d("generatedAt"), s("id")],
        "Truncation": [list("steps", "TruncationStep")],
        "TruncationStep": [s("step"), i("kept"), i("total"), n("shownShare", null: true)],
        "ProjectSection": [
            s("container"), s("format"), i("objectVersion", null: true), s("generator", null: true), i("targets"),
            i("packageTargets", null: true), i("localPackages"), i("remotePackages"), strings("dependencyManagers"),
            i("schemes"), s("settingsSource", null: true), strings("configurations"), strings("notes"),
        ],
        "DoctorSection": [list("passed", "RuleOutcome"), list("notApplicable", "RuleOutcome"),
                          list("suppressed", "RuleOutcome"), i("rulesEvaluated"), n("durationSeconds", null: true),
                          b("offline"), s("failOn", null: true), b("failed")],
        "RuleOutcome": [s("ruleId"), s("title"), s("detail")],
        "FixPlanStep": [i("order"), s("ruleId"), s("command"), s("note", null: true), s("kind", null: true),
                        s("verifyStatus", null: true)],
        "DiagnosticEntry": [F("severity", .enumeration(["error", "warning"])), s("file", null: true),
                            i("line", null: true), i("column", null: true), s("message"), i("occurrences")],
        "Regression": [
            ref("baseline", "BaselineRef"), F("verdict", .enumeration(["faster", "slower", "same", "indicative"])),
            F("wallBasis", .enumeration(["processWall", "span"])), ref("wall", "Delta"), ref("busy", "Delta"),
            ref("criticalPath", "Delta"), ref("noiseBand", "NoiseBand"), list("attribution", "Attribution"),
            n("thresholdPct", null: true), n("allowancePct"), b("failed"), strings("notes"),
        ],
        "BaselineRef": [s("source"), s("ref", null: true), d("savedAt", null: true), s("kind", null: true),
                        s("scheme", null: true), s("configuration", null: true), s("destination", null: true),
                        s("xcode", null: true), i("runs")],
        "Delta": [n("baseline", null: true), n("current", null: true), n("delta", null: true), n("deltaPct", null: true)],
        "NoiseBand": [s("method"), n("pooledMad", null: true), n("madMultiplier"), n("minPct"), n("band", null: true),
                      i("runsBaseline"), i("runsCurrent")],
        "Attribution": [s("kind"), s("subject"), s("detail"), n("deltaSeconds", null: true)],
        // `EnvSnapshot` and `GitInfo` omit a member when it is nil.
        "EnvSnapshot": [
            F("xcodebuildVersion", .str, optional: true), F("developerDir", .str, optional: true),
            F("macOSProductVersion", .str, optional: true), F("macOSBuildVersion", .str, optional: true),
            F("hwModel", .str, optional: true), F("logicalCPUCount", .int, optional: true),
            F("memoryBytes", .int, optional: true), F("performanceCores", .int, optional: true),
            F("efficiencyCores", .int, optional: true), F("processTranslated", .bool, optional: true),
            F("ciProvider", .str, optional: true), F("git", .ref("GitInfo"), optional: true),
        ],
        "GitInfo": [F("branch", .str, optional: true), F("commit", .str, optional: true), F("dirty", .bool, optional: true),
                    F("remoteHost", .str, optional: true)],
        "TaskIndex": [
            F("start", .array(.int)), F("dur", .array(.int)), F("lane", .array(.int)), F("target", .array(.int)),
            F("kind", .array(.int)), F("label", .array(.int)), F("onPath", .array(.int)), strings("targets"),
            strings("kinds"), strings("labels"), list("dropped", "TaskIndexDropped"), i("taskIndexTotal"),
            n("taskIndexShownShare", null: true),
        ],
        "TaskIndexDropped": [i("target"), i("lane"), i("tasks"), n("seconds")],

        // v0.5 (docs/SCHEMA-v0.5.md)
        "BuildCache": [i("hits", null: true), i("misses", null: true), i("replayedTasks", null: true),
                       i("replayedTasksHeuristic", null: true),
                       F("source", .enumeration(["buildOperationMetrics", "casRemarks", "history"]))],
        "Incremental": [
            F("basis", .enumeration(["previousIndex", "currentLogOnly"])),
            ref("previousBuild", "IncrementalPreviousBuild", null: true), list("causes", "IncrementalCause"),
            n("unknownSeconds"), n("unknownShare", null: true), strings("byTaskTime"), strings("byPathSeconds"),
            ref("v15", "IncrementalV15"), ref("procedure", "IncrementalProcedure", null: true), strings("notes"),
        ],
        "IncrementalPreviousBuild": [s("id"), d("time", null: true)],
        "IncrementalCause": [
            s("id"), F("class", .enumeration(ReportDocument.Incremental.classes)),
            s("cause"), F("source", .enumeration(ReportDocument.Incremental.sources)), s("subject", null: true),
            strings("evidence"), strings("secondaryEvidence"), list("tasks", "CauseTask"), i("tasksTotal"),
            n("tasksShownShare", null: true), n("seconds"), n("pathSeconds", null: true), s("ruleId", null: true),
            s("whatToDo", null: true),
        ],
        "CauseTask": [s("key", null: true), s("label"), s("target", null: true), s("kind"), n("seconds"),
                      n("pathSeconds", null: true), i("taskId", null: true)],
        "IncrementalV15": [F("status", .enumeration(["pass", "fail", "skipped"])), n("executedSeconds", null: true),
                           n("sumOfCauses", null: true)],
        "IncrementalProcedure": [F("mode", .enumeration(["zeroChange", "touch"])), s("touched", null: true),
                                 list("builds", "ProcedureBuild"),
                                 F("backtraces", .enumeration(["off", "on", "unavailable"])), b("showIncremental")],
        "ProcedureBuild": [F("role", .enumeration(["settle", "measure", "repeat"])), i("exitCode"), n("wall", null: true),
                           i("executedTasks", null: true), i("executedWorkTasks", null: true),
                           s("historyId", null: true)],
        "FixedCost": [
            s("class"), n("seconds", null: true), n("perDay", null: true), i("perDayAssumedBuilds"),
            F("perDayBasis", .enumeration(["history", "config", "assumed"])),
            F("basis", .enumeration(["zeroChange", "historyFrequency", "static"])), list("tasks", "CauseTask"),
            i("tasksTotal"), n("tasksShownShare", null: true),
        ],
        "ModuleGraph": [
            F("source", .enumeration(ReportDocument.ModuleGraph.sources)), i("targets"), i("depth", null: true),
            list("longestChain", "ChainLink"), n("longestChainSeconds", null: true), list("fanIn", "Degree"),
            list("fanOut", "Degree"), strings("umbrellaCandidates"), F("cycles", .array(.array(.str))),
            list("blockers", "Blocker"), list("macroPluginsPerModule", "MacroPlugins"),
            ref("variants", "Variants", null: true), strings("criticalChain"), list("nodes", "GraphNode"),
            i("nodesTotal"), n("nodesShownShare", null: true), list("edges", "GraphEdge"), i("edgesTotal"),
            n("edgesShownShare", null: true), strings("notes"),
        ],
        "ChainLink": [s("target"), n("seconds")],
        "Degree": [s("target"), i("count")],
        "Blocker": [s("target"), n("gatedSeconds")],
        "MacroPlugins": [s("module"), i("plugins"), strings("names")],
        "Variants": [i("modules"), i("pcmTasks", null: true), i("redundantTasks", null: true),
                     n("redundantSeconds", null: true), F("causes", .array(.enumeration(ReportDocument.ModuleGraph.variantCauses))),
                     list("perModule", "ModuleVariant"), i("perModuleTotal"), n("perModuleShownShare", null: true)],
        "ModuleVariant": [s("module"), i("variants"), strings("flags"),
                          F("causes", .array(.enumeration(ReportDocument.ModuleGraph.variantCauses))),
                          i("pcmTasks", null: true), n("redundantSeconds", null: true)],
        "GraphNode": [s("id"), s("name"), s("owner", null: true), i("depth"), i("variants", null: true),
                      i("macroPlugins", null: true), n("onPathSeconds", null: true), n("taskTime", null: true),
                      i("collapsed")],
        "GraphEdge": [s("from"), s("to"), b("critical")],
        "Deep": [
            b("enabled"), F("scope", .array(.enumeration(DeepScope.allCases.map(\.rawValue)))), strings("flagsInjected"),
            list("flagsDropped", "DeepDroppedFlag"), list("flagsNotInjected", "DeepDroppedFlag"), strings("shadowed"),
            s("derivedData"),
            i("derivedDataBytes", null: true), s("wrapper", null: true), ref("exactFiles", "DeepExactFiles", null: true),
            ref("sources", "DeepSources", null: true), strings("notes"),
        ],
        "DeepDroppedFlag": [s("flag"), s("reason")],
        "DeepExactFiles": [strings("rebuiltTargets"), s("note")],
        "DeepSources": [i("debugTime"), i("warnLong"), i("statsDir"), i("ftimeTrace")],

        // Compare
        "CompareSide": [
            s("label"), s("source"), i("runs"), d("generatedAt", null: true), s("toolVersion"), s("kind", null: true),
            s("scheme", null: true), s("configuration", null: true), s("destination", null: true), s("xcode", null: true),
            n("wall", null: true), n("busy", null: true), n("criticalPath", null: true), i("tasks"), i("errors"),
            i("warnings"), b("degraded"), ref("git", "GitInfo", null: true), s("machine", null: true),
        ],
        "ComparePair": [n("a", null: true), n("b", null: true), n("delta", null: true), n("deltaPct", null: true)],
        "EnvDiff": [s("field"), s("a", null: true), s("b", null: true)],
        "CompareRow": [s("key"), F("status", .enumeration(["changed", "same", "added", "removed"])), ref("seconds", "ComparePair"),
                       ref("tasks", "ComparePair", null: true), b("isOther")],
        "CriticalPathDiff": [ref("span", "ComparePair"), list("byTarget", "CompareRow"), i("byTargetTotal"),
                             n("byTargetShownShare", null: true), strings("notes")],
        "TaskRef": [s("rule"), s("target", null: true), s("kind"), n("seconds"), b("onPath"), s("title", null: true)],
        "TaskChange": [s("rule"), s("target", null: true), s("kind"), s("title", null: true), ref("seconds", "ComparePair"),
                       b("onPath")],
        "TaskDiff": [b("available"), list("added", "TaskRef"), i("addedTotal"), n("addedShownShare", null: true),
                     list("removed", "TaskRef"), i("removedTotal"), n("removedShownShare", null: true), strings("notes"),
                     list("changed", "TaskChange"), i("changedTotal"), n("changedShownShare", null: true)],
        "SettingDiff": [s("ref"), s("a", null: true), s("b", null: true), s("provenanceA", null: true),
                        s("provenanceB", null: true)],

        // Trend
        "TrendFilter": [s("kind", null: true), s("scheme", null: true), d("since", null: true),
                        F("by", .enumeration(TrendDocument.By.allCases.map(\.rawValue)), null: true)],
        "TrendGroup": [s("key", null: true), i("entries"), list("series", "TrendSeries")],
        "TrendSeries": [s("kind"), list("points", "TrendPoint"), ref("wall", "Percentiles"), ref("busy", "Percentiles"),
                        list("xcodeChangeMarkers", "XcodeChange")],
        "TrendPoint": [s("id"), d("time", null: true), n("wall", null: true), n("busy", null: true), s("xcode", null: true),
                       s("commit", null: true), s("branch", null: true), s("machine", null: true)],
        "Percentiles": [i("n"), n("p50", null: true), n("p75", null: true), n("p95", null: true)],
        "XcodeChange": [s("atId"), s("from", null: true), s("to", null: true), d("time", null: true)],

        // Baseline
        "BaselineSource": [s("kind"), strings("refs")],
        "BaselineKey": [s("kind", null: true), s("scheme", null: true), s("configuration", null: true),
                        s("destination", null: true), s("xcode", null: true)],
        "BaselineStat": [n("median", null: true), n("mad", null: true)],
        "TaskDigests": [i("total"), strings("ids")],
    ]

    // MARK: Compare, trend, baseline

    static let compareFields: [F] = [
        schemaVersion(CompareDocument.schemaVersion), ref("tool", "Tool"), d("generatedAt"), ref("a", "CompareSide"),
        ref("b", "CompareSide"), ref("regression", "Regression"), list("env", "EnvDiff"), i("envCompared"),
        list("phases", "CompareRow", null: true), list("targets", "CompareRow", null: true), i("targetsTotal"),
        n("targetsShownShare", null: true), ref("criticalPath", "CriticalPathDiff", null: true), ref("tasks", "TaskDiff"),
        list("settings", "SettingDiff", null: true), strings("notes"), ref("truncation", "Truncation"), b("redacted"),
        // HTML only (`--format html`): the task index of each side that was a log.
        F("taskIndexA", .ref("TaskIndex"), optional: true), F("taskIndexB", .ref("TaskIndex"), optional: true),
    ]

    static let trendFields: [F] = [
        schemaVersion(TrendDocument.schemaVersion), ref("tool", "Tool"), d("generatedAt"), ref("filter", "TrendFilter"),
        i("entriesTotal"), i("entriesUsed"), list("groups", "TrendGroup"), strings("notes"), b("redacted"),
    ]

    static let baselineFields: [F] = [
        schemaVersion(Baseline.schemaVersion), ref("tool", "Tool"), d("savedAt"), ref("source", "BaselineSource"),
        ref("key", "BaselineKey"), F("wallBasis", .enumeration(["processWall", "span"])), i("runs"),
        ref("wall", "BaselineStat"), ref("busy", "BaselineStat"), ref("criticalPath", "BaselineStat"),
        ref("git", "GitInfo", null: true), s("machine", null: true), ref("tasks", "TaskDigests", null: true),
        strings("notes"),
    ]
}

// MARK: - v0.6 fix plan and verify (docs/SCHEMA-v0.6.md; closed vocabularies as enums)

extension SchemaTable {
    private static func e(_ key: String, _ values: [String], null: Bool = false) -> F { F(key, .enumeration(values), null: null) }

    static let verifyKinds = VerifyDocument.Kind.allCases.map(\.rawValue)
    static let mechanisms = FixPlanDocument.Mechanism.allCases.map(\.rawValue)

    static let fixPlanFields: [F] = [
        schemaVersion(FixPlanDocument.schemaVersion), ref("tool", "Tool"), d("generatedAt"), s("id"),
        ref("generatedFrom", "PlanSource"), ref("project", "PlanProject"), list("steps", "PlanStep"),
        list("guards", "PlanGuard"), list("hook", "PlanHook"), strings("commands"), list("events", "PlanEvent"),
        strings("notes"), b("redacted"),
    ]

    static let verifyFields: [F] = [
        schemaVersion(VerifyDocument.schemaVersion), ref("tool", "Tool"), d("generatedAt"), s("id"), s("planId"),
        e("kind", verifyKinds), e("mechanism", mechanisms, null: true), i("runsPerArm"), b("oneByOne"), b("keepOnTie"),
        n("maxMinutes", null: true), s("touch", null: true), s("scheme", null: true), s("configuration", null: true),
        strings("xcodebuildArguments"), e("wallBasis", ["processWall"]), ref("noiseModel", "NoiseModel"),
        list("preconditions", "VerifyPrecondition"), list("results", "VerifyUnit"), ref("abort", "VerifyAbort", null: true),
        n("elapsedSeconds"), s("xcode", null: true), s("machine", null: true), strings("notes"), b("redacted"),
    ]

    static let fixVerifyObjects: [String: [F]] = [
        "PlanSource": [s("analysisId", null: true), s("analysisPath", null: true), s("analysisKind", null: true),
                       strings("doctorConfigurations"), e("settingsSource", ["xcodebuild", "offline", "mixed"]),
                       strings("rulesFilter")],
        "PlanProject": [s("container"), s("generator", null: true), strings("configurations"), s("scheme", null: true)],
        "PlanStep": [
            i("order"), s("ruleId"), s("title"), e("fixKind", FixPlanDocument.FixKind.allCases.map(\.rawValue)),
            e("mechanism", mechanisms), s("mechanismDetail", null: true), s("impactBand", null: true),
            n("impactSeconds", null: true), s("estimatedBand", null: true), s("confidence"), b("verifyOnly"),
            e("verifyKind", verifyKinds), list("scope", "ScopeRow"), list("overlay", "OverlayLine"),
            list("defaults", "DefaultsChange"), e("shadowing", FixPlanDocument.Shadowing.allCases.map(\.rawValue)),
            strings("shadowedBy"), ref("verify", "VerifyState"), e("state", FixPlanDocument.StepState.allCases.map(\.rawValue)),
            s("stateReason", null: true), strings("commands"), strings("inXcode"), s("risk", null: true),
        ],
        "ScopeRow": [s("target"), s("configuration"), s("key"), s("before", null: true), s("after", null: true),
                     s("provenance", null: true), e("mechanism", mechanisms), b("reached"), s("note", null: true)],
        "OverlayLine": [s("configuration"), s("key"), s("condition", null: true), s("value"), s("line")],
        "DefaultsChange": [s("domain"), s("key"), s("value", null: true), e("type", ["bool", "int", "string"], null: true)],
        "VerifyState": [
            e("status", FixPlanDocument.VerifyStatus.allCases.map(\.rawValue)),
            e("reason", FixPlanDocument.RevertReason.allCases.map(\.rawValue), null: true), e("mechanism", mechanisms, null: true),
            e("kind", verifyKinds, null: true), s("verifyId", null: true), d("verifiedAt", null: true),
            n("deltaSeconds", null: true), n("deltaPct", null: true), b("tie"), s("basis", null: true),
        ],
        "PlanGuard": [e("id", ["commitFirst", "hookInstalled", "prerequisite", "verifyFirst", "cleanTree"]), s("text"),
                      strings("ruleIds"), b("satisfied", null: true)],
        "PlanHook": [s("configuration"), e("status", ["installed", "notInstalled", "unavailable", "generated"]),
                     s("baseXCConfig", null: true), s("reason", null: true)],
        "PlanEvent": [d("at"), e("action", ["apply", "applyDefaults", "revert", "installHook", "uninstallHook"]),
                      strings("ruleIds"), strings("files"), strings("defaultsKeys")],

        "NoiseModel": [n("madMultiplier"), n("minPct"), i("minSamples"), i("minRuns")],
        "VerifyPrecondition": [e("name", ["cleanTree", "power", "thermal", "otherBuild", "hook"]),
                               e("status", ["pass", "warn", "fail"]), s("detail")],
        "VerifyUnit": [
            strings("ruleIds"), strings("titles"), e("mechanism", mechanisms), list("scope", "ScopeRow"),
            list("arms", "VerifyArm"), n("deltaSeconds", null: true), n("deltaPct", null: true), n("noiseBand", null: true),
            ref("verdict", "VerifyVerdict"), list("checks", "VerifyCheck"), strings("notes"), s("basis", null: true),
        ],
        "VerifyArm": [e("arm", VerifyDocument.Arm.allCases.map(\.rawValue)), s("derivedData", null: true),
                      list("runs", "VerifyRun"), i("runsTotal"), i("runsOk"), i("samples"), n("p50", null: true),
                      n("mad", null: true)],
        "VerifyRun": [e("arm", VerifyDocument.Arm.allCases.map(\.rawValue)), i("index"), b("settle"), b("ok"), i("exitCode"),
                      n("wall", null: true), n("criticalPath", null: true), s("taskKindsHash", null: true),
                      s("targetSetHash", null: true), s("thermal", null: true), s("excluded", null: true)],
        "VerifyVerdict": [e("status", FixPlanDocument.VerifyStatus.allCases.map(\.rawValue)),
                          e("reason", FixPlanDocument.RevertReason.allCases.map(\.rawValue), null: true), b("tie")],
        "VerifyCheck": [e("name", ["exitCode", "targetSet", "taskKinds", "thermal", "oracle"]),
                        e("status", ["pass", "fail", "warn", "skipped"]), s("detail")],
        "VerifyAbort": [e("reason", VerifyDocument.AbortReason.allCases.map(\.rawValue)), s("detail")],
    ]
}
