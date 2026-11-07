import Foundation
import XCTest
@testable import XcblameKit

/// Report documents for the HTML tests. Until Lane A merges, real runs leave the v0.2 members null (`bare`);
/// `populated` and `synthetic` fill every member per docs/SCHEMA-v0.2.md by hand.
enum HTMLSample {
    static let date = Date(timeIntervalSince1970: 1_700_000_000)
    static let hostile = "</script><img src=x onerror=alert(1)><!-- O'Brien \"q\" \u{2028}line\u{2029} {{TITLE}}"

    /// The pipeline document plus the stub `TaskIndex.make`: what `analyze` produces today.
    static func bare(_ model: BuildModel = SyntheticModel.make(), topN: Int = .max,
                     path: String? = "/Users/sample/Projects/App/build.xcactivitylog") throws -> (ReportDocument, TaskIndex) {
        let result = try ReportPipeline.run(model, options: .init(topN: topN, generatedAt: date, inputPath: path))
        return (result.document, TaskIndex.make(model: model, analysis: result.analysis, document: result.document))
    }

    /// Every v0.2 member filled from the model's own tasks: an inferred critical path (latest end backwards), greedy
    /// lanes, utilization buckets, one file row per Swift compile, hotspots, one finding with its rule doc.
    static func populated(_ model: BuildModel = SyntheticModel.make(), hostileStrings: Bool = true) throws
        -> (ReportDocument, TaskIndex) {
        var (doc, _) = try bare(model)
        let start0 = model.sessionStart
        struct Task { var id: Int; var start: Double; var end: Double; var target: Int?; var kind: String; var title: String }
        let tasks = model.tasks.filter { $0.hasTiming && $0.end > $0.start }
            .map { Task(id: $0.id, start: max(0, $0.start - start0), end: $0.end - start0, target: $0.targetId,
                        kind: $0.kind.rawValue, title: $0.title) }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        func targetName(_ id: Int?) -> String? { id.flatMap { model.targets.indices.contains($0) ? model.targets[$0].name : nil } }

        // Critical path: from the latest end, repeatedly the task with the latest end not after the current start.
        var path: [Task] = []
        if var pick = tasks.max(by: { $0.end < $1.end }) {
            path.append(pick)
            while let prev = tasks.filter({ $0.end <= pick.start + 1e-9 }).max(by: { $0.end < $1.end }) {
                path.append(prev)
                pick = prev
            }
        }
        path.reverse()
        let span = ReportDocument.round6((path.last?.end ?? 0) - (path.first?.start ?? 0))
        var segments: [ReportDocument.PathSegment] = []
        var waits: [ReportDocument.PathWait] = []
        for (i, task) in path.enumerated() {
            if let last = segments.last, task.start - last.end > 1e-6 {
                waits.append(.init(start: last.end, end: task.start, seconds: ReportDocument.round6(task.start - last.end)))
            }
            let seconds = ReportDocument.round6(task.end - task.start)
            segments.append(.init(start: ReportDocument.round6(task.start), end: ReportDocument.round6(task.end),
                                  seconds: seconds, share: span > 0 ? seconds / span : nil,
                                  basis: i % 3 == 2 ? "byTiming" : "dag", target: targetName(task.target),
                                  targetId: task.target, label: "\(task.kind) \(task.title)", taskIds: [task.id]))
        }
        let onPath = Set(path.map(\.id))
        var whatIf: [String: Double] = [:]
        for segment in segments { if let t = segment.target { whatIf[t, default: 0] += segment.seconds } }
        doc.criticalPath = .init(
            span: span, basis: "mixed", segments: segments, segmentsTotal: segments.count, segmentsShownShare: 1,
            waits: waits,
            whatIf: whatIf.sorted { ($1.value, $0.key) < ($0.value, $1.key) }.map { entry in
                .init(target: entry.key, targetId: model.targets.firstIndex { $0.name == entry.key },
                      savingIfZero: ReportDocument.round6(entry.value), savingIfHalf: ReportDocument.round6(entry.value / 2))
            },
            notes: ["sample: inferred from task ends"])

        // Task index with greedy lane packing.
        var laneEnds: [Double] = []
        var index = TaskIndex(start: [], dur: [], lane: [], target: [], kind: [], label: [], onPath: [],
                              targets: model.targets.map(\.name) + ["(no target)"],
                              kinds: TaskKind.allCases.map(\.rawValue), labels: [], dropped: [],
                              taskIndexTotal: doc.build.tasks, taskIndexShownShare: 1)
        var labelIds: [String: Int] = [:]
        for task in tasks {
            let lane = laneEnds.firstIndex { $0 <= task.start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(task.end) } else { laneEnds[lane] = task.end }
            index.start.append(Int((task.start * 1000).rounded()))
            index.dur.append(Int(((task.end - task.start) * 1000).rounded()))
            index.lane.append(lane)
            index.target.append(task.target ?? model.targets.count)
            index.kind.append(TaskKind.allCases.firstIndex { $0.rawValue == task.kind } ?? 0)
            let label = hostileStrings && task.id == tasks.first?.id ? hostile : task.title
            if labelIds[label] == nil { labelIds[label] = index.labels.count; index.labels.append(label) }
            index.label.append(labelIds[label]!)
            index.onPath.append(onPath.contains(task.id) ? 1 : 0)
        }

        // Utilization, serial stretches, idle gaps.
        let fullSpan = doc.build.span ?? span
        let bucket = max(0.1, fullSpan / 4000)
        let buckets = Int((fullSpan / bucket).rounded(.up))
        let lanes = (0..<buckets).map { b -> Double in
            let mid = (Double(b) + 0.5) * bucket
            return Double(tasks.filter { $0.start <= mid && mid < $0.end }.count)
        }
        doc.timing.utilization = .init(bucketSeconds: bucket, lanes: lanes)
        doc.timing.serialThresholdLanes = 1
        var stretches: [ReportDocument.SerialStretch] = []
        var gaps: [ReportDocument.Gap] = []
        var runStart: Int?
        var gapStart: Int?
        for b in 0...buckets {
            let v = b < buckets ? lanes[b] : 99
            if v <= 1, runStart == nil { runStart = b }
            if v > 1, let s = runStart {
                if Double(b - s) * bucket >= 1 {
                    stretches.append(.init(start: Double(s) * bucket, end: Double(b) * bucket, lanes: 1))
                }
                runStart = nil
            }
            if v == 0, gapStart == nil { gapStart = b }
            if v != 0, let s = gapStart {
                if Double(b - s) * bucket > 0.1 { gaps.append(.init(start: Double(s) * bucket, end: Double(b) * bucket)) }
                gapStart = nil
            }
        }
        doc.timing.serialStretches = stretches
        doc.timing.serialStretchesTotal = stretches.count
        doc.timing.serialSeconds = stretches.reduce(0) { $0 + $1.end - $1.start }
        doc.timing.serialStretchesShownShare = stretches.isEmpty ? nil : 1
        doc.timing.idleGaps = gaps
        doc.timing.idleGapsTotal = gaps.count
        doc.timing.idleGapsShownShare = gaps.isEmpty ? nil : 1
        doc.timing.processWall = ReportDocument.round6(fullSpan + 1.25)
        doc.timing.outsideLogSeconds = 1.25

        // Target extras.
        if var rows = doc.targets {
            for i in rows.indices where !rows[i].isOther {
                let mine = tasks.filter { targetName($0.target) == rows[i].name }
                rows[i].owner = i == 0 ? "app" : "localPackage"
                rows[i].onPathSeconds = ReportDocument.round6(segments.filter { $0.target == rows[i].name }.reduce(0) { $0 + $1.seconds })
                rows[i].whatIfSeconds = whatIf[rows[i].name].map(ReportDocument.round6)
                var busy = 0.0, reach = -Double.infinity
                for t in mine { busy += max(0, t.end - max(t.start, reach)); reach = max(reach, t.end) }
                rows[i].busy = ReportDocument.round6(busy)
                let byKind = Dictionary(grouping: mine, by: \.kind)
                rows[i].kinds = byKind.keys.sorted().map { key in
                    let time = byKind[key]!.reduce(0) { $0 + $1.end - $1.start }
                    return .init(key: key, tasks: byKind[key]!.count, taskTime: ReportDocument.round6(time),
                                 share: rows[i].taskTime > 0 ? ReportDocument.round6(time / rows[i].taskTime) : nil,
                                 isOther: false)
                }
            }
            doc.targets = rows
        }
        doc.build.kind = "clean"
        doc.build.kindEvidence = ["sample: 0 reused tasks"]

        // Files, hotspots, a finding.
        let compiles = tasks.filter { $0.kind == "swiftCompile" }
        var files = compiles.enumerated().map { i, t in
            ReportDocument.FileRow(path: "/Users/sample/Projects/App/Sources/\(t.title.replacingOccurrences(of: " ", with: "_")).swift",
                                   target: targetName(t.target), targetId: t.target,
                                   seconds: ReportDocument.round6(t.end - t.start),
                                   granularity: i % 4 == 1 ? "estimated" : "exact", batchSize: i % 4 == 1 ? 3 : nil,
                                   members: i % 4 == 1 ? ["/Users/sample/a.swift", "/Users/sample/b.swift", "/Users/sample/c.swift"] : nil,
                                   onPath: onPath.contains(t.id), typeCheckMs: i % 2 == 0 ? 42.5 : nil, taskId: t.id)
        }
        if let first = files.first {
            files.append(.init(path: "/Users/sample/Projects/App/Sources/Batch1.swift", target: first.target,
                               targetId: first.targetId, seconds: 0.5, granularity: "batch", batchSize: 2,
                               members: ["/Users/sample/Projects/App/Sources/Batch1.swift", "/Users/sample/Projects/App/Sources/Batch2.swift"],
                               onPath: false, typeCheckMs: nil, taskId: nil))
        }
        files.sort { ($0.seconds, $1.path) > ($1.seconds, $0.path) }
        doc.files = files
        doc.filesTotal = files.count
        doc.filesShownShare = files.isEmpty ? nil : 1
        var hotspots: [ReportDocument.Hotspot] = []
        for (i, file) in files.prefix(6).enumerated() {
            for j in 0..<3 {
                hotspots.append(.init(file: file.path, line: 10 + j * 7, col: 5, declaration: i == 0 && j == 0 && hostileStrings ? hostile : "View\(i).body\(j)",
                                      kind: j == 2 ? "expression" : "functionBody", ms: Double(400 - i * 50 - j * 20),
                                      source: "debugTimeFunctionBodies", onPathWeight: file.onPath ? 1 : 0.25,
                                      occurrences: j + 1, target: file.target, taskId: file.taskId))
            }
        }
        hotspots.sort { $0.ms * $0.onPathWeight > $1.ms * $1.onPathWeight }
        doc.hotspots = hotspots
        doc.hotspotsTotal = hotspots.count
        doc.hotspotsShownShare = 1
        doc.findings = [.init(ruleId: "SET-016", title: "Use the explicit-modules build setting", severity: "warning",
                              impactBand: "M", impactSeconds: 4.2, impactBasis: "pathShare", confidence: "medium",
                              evidence: ["one", "two", "three", "four", hostileStrings ? hostile : "five"],
                              fixKind: "xcconfig", risk: "low", mechanism: "hook", signalKey: "module-variants")]
        doc.findingsTotal = 1
        doc.ruleDocs = ["SET-016": .init(title: "Explicit modules", summary: "Summary text.", fix: "Fix text.",
                                         sources: ["https://developer.apple.com/documentation/xcode"], id: "SET-016",
                                         category: "SET", applyKinds: ["overlay(D)"], verifyOnly: true, risk: "low",
                                         evidenceTag: "S")]
        return (doc, index)
    }

    /// The `doctor` document for the hand-built AcmeApp mirror (Rules fixtures): project header, findings with rule
    /// docs, PASS / N/A / suppressed lists, every build member empty. `hostileStrings` puts the hostile string into a
    /// finding title, an evidence value and a pass detail.
    /// The AcmeApp doctor document as `doctor --offline` makes it: same findings, every confidence one step lower.
    static func doctorOffline() -> ReportDocument {
        let model = RulesFixtures.acmeApp()
        let settings = RulesFixtures.effective(model)
        let env = RulesFixtures.env()
        let result = RulesFixtures.run(RulesFixtures.context(model, settings: settings, env: env, offline: true))
        return ReportDocument.makeDoctor(project: model, settings: settings, result: result,
                                         configurations: model.configurationNames, environment: env, xcode: "26.0.1",
                                         generatedAt: date, durationSeconds: 2.8, offline: true, failOn: nil)
    }

    static func doctor(hostileStrings: Bool = true, generated: Bool = false) -> ReportDocument {
        let model = generated ? RulesFixtures.genXcodeGen() : RulesFixtures.acmeApp()
        let settings = RulesFixtures.effective(model)
        let env = RulesFixtures.env()
        var result = RulesFixtures.run(RulesFixtures.context(model, settings: settings, env: env))
        if hostileStrings, !result.findings.isEmpty {
            result.findings[0].title += " " + hostile
            result.findings[0].evidence.append("note: " + hostile)
            result.findings[0].evidenceDetails.append(.init(kind: "report", ref: "note", value: hostile))
            result.passed[0].detail = hostile
        }
        return ReportDocument.makeDoctor(project: model, settings: settings, result: result,
                                         configurations: model.configurationNames, environment: env, xcode: "26.0.1",
                                         generatedAt: date, durationSeconds: 2.8, offline: false, failOn: "medium")
    }

    /// A 50k-task document: `tasks` top tasks and task-index rows (with `labels` distinct labels), `files` file rows,
    /// `hotspots` hotspot rows and 300 targets with kind mix.
    static func synthetic(tasks count: Int = 50_000, labels: Int = 20_000, files fileCount: Int = 5_000,
                          hotspots hotspotCount: Int = 20_000) throws -> (ReportDocument, TaskIndex) {
        var (doc, _) = try populated(hostileStrings: false)
        let span = 900.0
        var rng = SplitMix(seed: 42)
        let targetCount = 300
        let names = (0..<targetCount).map { "Module\($0)" }
        let kinds = TaskKind.allCases.map(\.rawValue)
        var index = TaskIndex(start: [], dur: [], lane: [], target: [], kind: [], label: [], onPath: [],
                              targets: names, kinds: kinds,
                              labels: (0..<labels).map { "Compile /Users/sample/Projects/Big/Sources/Feature\($0 % 400)/File\($0).swift" },
                              dropped: [], taskIndexTotal: count, taskIndexShownShare: 1)
        var laneEnds: [Int] = []
        var top: [ReportDocument.TopTask] = []
        let starts = (0..<count).map { _ in Int(rng.next() % UInt64(span * 1000)) }.sorted()
        for (i, start) in starts.enumerated() {
            let dur = Int(rng.next() % 100 == 0 ? 2000 + rng.next() % 20_000 : rng.next() % 400)
            let lane = laneEnds.firstIndex { $0 <= start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(start + dur) } else { laneEnds[lane] = start + dur }
            index.start.append(start)
            index.dur.append(dur)
            index.lane.append(lane)
            index.target.append(i % targetCount)
            index.kind.append(i % kinds.count)
            index.label.append(i % labels)
            index.onPath.append(i % 250 == 0 ? 1 : 0)
            top.append(.init(id: i, rule: "SwiftCompile", kind: kinds[i % kinds.count], target: names[i % targetCount],
                             seconds: Double(dur) / 1000, startOffset: Double(start) / 1000, title: index.labels[i % labels]))
        }
        top.sort { ($0.seconds, $1.id) > ($1.seconds, $0.id) }
        let taskTime = top.reduce(0) { $0 + $1.seconds }
        doc.build.tasks = count
        doc.build.tasksInModel = count
        doc.build.span = span
        doc.build.taskTime = ReportDocument.round6(taskTime)
        doc.topTasks = top
        doc.topTasksTotal = count
        doc.topTasksShownShare = 1
        doc.targets = names.enumerated().map { i, name in
            let time = ReportDocument.round6(taskTime / Double(targetCount) * (1 + Double(targetCount - i) / 100))
            return .init(id: i, name: name, project: "/Users/sample/Projects/Big/Big.xcodeproj", isPackage: false,
                         isBucket: false, tasks: count / targetCount, taskTime: time, share: time / taskTime,
                         isOther: false, owner: "localPackage", onPathSeconds: 1, whatIfSeconds: nil, busy: time / 2,
                         kinds: [.init(key: "swiftCompile", tasks: count / targetCount, taskTime: time, share: 1, isOther: false)])
        }
        doc.targetsTotal = targetCount
        doc.targetsShownShare = 1
        doc.files = (0..<fileCount).map { i in
            .init(path: "/Users/sample/Projects/Big/Sources/Feature\(i % 400)/File\(i).swift", target: names[i % targetCount],
                  targetId: i % targetCount, seconds: ReportDocument.round6(Double(fileCount - i) / 100),
                  granularity: "exact", batchSize: nil, members: nil, onPath: i % 50 == 0, typeCheckMs: Double(i % 300),
                  taskId: i)
        }
        doc.filesTotal = fileCount
        doc.filesShownShare = 1
        doc.hotspots = (0..<hotspotCount).map { i in
            .init(file: "/Users/sample/Projects/Big/Sources/Feature\(i % 400)/File\(i % fileCount).swift", line: i % 900 + 1,
                  col: i % 40 + 1, declaration: "Feature\(i % 400).View\(i).body", kind: "functionBody",
                  ms: Double(hotspotCount - i) / 100, source: "debugTimeFunctionBodies", onPathWeight: 1, occurrences: 1,
                  target: names[i % targetCount], taskId: i)
        }
        doc.hotspotsTotal = hotspotCount
        doc.hotspotsShownShare = 1
        doc.timing.utilization = .init(bucketSeconds: span / 4000, lanes: (0..<4000).map { Double($0 % 16) })
        return (doc, index)
    }
}

/// Deterministic PRNG for the synthetic report.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Pulls the `#xcblame-data` blob out of a rendered page.
enum HTMLBlob {
    static let open = "<script type=\"application/json\" id=\"xcblame-data\" data-encoding=\"json\">"

    static func extract(_ html: String) throws -> String {
        let start = try XCTUnwrap(html.range(of: open), "no data script").upperBound
        let end = try XCTUnwrap(html.range(of: "</script>", range: start..<html.endIndex)).lowerBound
        return String(html[start..<end])
    }

    /// `document` with its V13 check taken from `rendered`: the html render measures V13 on the final page
    /// (§8.2.3), the only member it changes besides truncation.
    static func withV13(of rendered: ReportDocument, _ document: ReportDocument) -> ReportDocument {
        var out = document
        out.validation.checks = out.validation.checks.map { check in
            check.id == "V13" ? rendered.validation.checks.first { $0.id == "V13" } ?? check : check
        }
        return out
    }

    /// The blob with the `taskIndex` member line removed (it is one line: the index is compact JSON).
    static func withoutTaskIndex(_ blob: String) -> String {
        var lines = blob.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let at = lines.firstIndex(where: { $0.hasPrefix("  \"taskIndex\" : ") }) else { return blob }
        let wasLast = !lines[at].hasSuffix(",")
        lines.remove(at: at)
        if wasLast, at > 0, lines[at - 1].hasSuffix(",") { lines[at - 1].removeLast() }
        return lines.joined(separator: "\n")
    }
}
