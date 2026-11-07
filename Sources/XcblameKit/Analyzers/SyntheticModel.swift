import Foundation

/// A deterministic synthetic `BuildModel` (about 50 tasks, 4 targets, nested sub-spans, one diagnostic, a timing
/// summary) for `selftest`, the CLI end-to-end tests and the reporter snapshot. All times are multiples of 0.25 s on
/// a fixed epoch, so every sum is exact in binary floating point.
public enum SyntheticModel {
    public static let sessionStart = 1_700_000_000.0
    public static let sessionSpan = 40.0

    public static func make() -> BuildModel {
        var builder = Builder()
        builder.addAll()
        return builder.model()
    }

    struct Builder {
        var tasks: [BuildTask] = []
        let table = KindTable.v1

        let app = 0, coreKit = 1, netKit = 2, modules = 3

        mutating func add(_ rule: String, target: Int?, at start: Double, for seconds: Double, title: String,
                          subspans: Int = 0, metrics: TaskMetrics? = nil, diagnostics: [Int] = [],
                          output: String? = nil) {
            let entry = table.lookup(rule)
            let id = tasks.count
            let begin = SyntheticModel.sessionStart + start
            let end = begin + seconds
            let children = (0..<subspans).map { index -> Subspan in
                let slice = seconds / Double(subspans)
                let childStart = begin + Double(index) * slice
                return Subspan(ruleName: nil, commandDetails: nil, title: "\(title) file \(index + 1)",
                               interval: Interval(start: childStart, end: childStart + slice))
            }
            tasks.append(BuildTask(
                id: id, ruleName: rule, kind: entry?.kind ?? .other, kindSource: entry == nil ? .none : .rule,
                phase: entry?.phase ?? .other, targetId: target, start: begin, end: end, duration: seconds,
                resultCode: 0, metrics: metrics, backtrace: nil, taskKey: nil, subspans: children,
                commandDetails: nil, signature: nil, title: title, emittedOutput: output, diagnosticIds: diagnostics,
                slfOnly: nil, unknownAttachments: []))
        }

        func metrics(for seconds: Double, id: Int) -> TaskMetrics? {
            switch id % 5 {
            case 0: return TaskMetrics(start: nil, duration: seconds, userCPU: seconds, systemCPU: seconds,
                                       maxRSS: 0, isPlaceholder: true)
            case 1, 2, 3: return TaskMetrics(start: nil, duration: seconds, userCPU: seconds * 0.75,
                                             systemCPU: seconds * 0.25, maxRSS: Int64(80_000_000 + id * 1_000_000),
                                             isPlaceholder: false)
            default: return nil
            }
        }

        mutating func addSwift(_ target: Int, name: String, count: Int, at start: Double) {
            for index in 0..<count {
                let seconds = 2.0 + Double(index % 3) * 0.5
                let begin = start + Double(index) * 1.0
                add("SwiftCompile", target: target, at: begin, for: seconds, title: "Compile \(name)\(index).swift",
                    subspans: 3, metrics: metrics(for: seconds, id: tasks.count),
                    diagnostics: tasks.count == 30 ? [0] : [])
            }
        }

        mutating func addAll() {
            add("CreateBuildDescription", target: nil, at: 0, for: 1.25, title: "Create build description",
                output: "Build description signature: 0123456789abcdef0123456789abcdef\r")
            add("ComputeTargetDependencyGraph", target: nil, at: 1.25, for: 0.25, title: "Compute dependency graph")
            add("ClangStatCache", target: nil, at: 1.5, for: 1.0, title: "Create SDK stat cache")
            for index in 0..<6 {
                add("SwiftExplicitDependencyGeneratePcm", target: modules, at: 2.5 + Double(index) * 0.25,
                    for: 1.0 + Double(index % 3) * 0.5, title: "Generate PCM Module\(index)")
            }
            addSwift(coreKit, name: "CoreKit", count: 8, at: 4.5)
            add("SwiftEmitModule", target: coreKit, at: 13.5, for: 1.5, title: "Emit CoreKit module")
            add("Libtool", target: coreKit, at: 15.0, for: 0.75, title: "Link CoreKit")
            addSwift(netKit, name: "NetKit", count: 6, at: 5.0)
            add("SwiftEmitModule", target: netKit, at: 12.0, for: 1.0, title: "Emit NetKit module")
            add("Libtool", target: netKit, at: 13.0, for: 0.5, title: "Link NetKit")
            addSwift(app, name: "App", count: 12, at: 15.5)
            add("CompileC", target: app, at: 16.0, for: 1.25, title: "Compile Bridge.m")
            add("CompileAssetCatalogVariant", target: app, at: 6.0, for: 3.5, title: "Compile Assets.xcassets")
            add("ProcessInfoPlistFile", target: app, at: 10.0, for: 0.25, title: "Process Info.plist")
            add("PhaseScriptExecution", target: app, at: 28.0, for: 2.0, title: "Run Script: Lint")
            add("Ld", target: app, at: 29.0, for: 2.5, title: "Link App")
            add("CodeSign", target: app, at: 31.75, for: 1.5, title: "Sign App.app")
            for index in 0..<3 {
                add("WriteAuxiliaryFile", target: app, at: 3.0 + Double(index) * 0.5, for: 0.25,
                    title: "Write aux file \(index)")
            }
            add("Touch", target: app, at: 33.5, for: 0.25, title: "Touch App.app")
            add("MysteryTool", target: app, at: 20.0, for: 0.75, title: "Mystery step")
        }

        func model() -> BuildModel {
            let names: [(String, String?, Bool, Bool)] = [
                ("App", "App.xcodeproj", false, false), ("CoreKit", "CoreKit.xcodeproj", true, false),
                ("NetKit", "NetKit.xcodeproj", true, false), (Target.explicitModulesBucket, nil, false, true),
            ]
            let targets = names.enumerated().map { index, entry in
                Target(id: index, name: entry.0, project: entry.1, path: nil, isPackage: entry.2, isBucket: entry.3,
                       taskIds: tasks.filter { $0.targetId == index }.map(\.id))
            }
            let diagnostic = Diagnostic(
                id: 0, severity: .warning, text: "variable 'x' was never mutated", category: "Semantic Issue",
                file: "Sources/App/App2.swift", line: 12, column: 9, endLine: nil, endColumn: nil,
                occurrences: 1, taskIds: [30])
            var seconds: [String: Double] = [:]
            var counts: [String: Int] = [:]
            for task in tasks {
                seconds[task.ruleName, default: 0] += task.duration
                counts[task.ruleName, default: 0] += 1
            }
            let rows = seconds.keys.sorted().map {
                TimingSummary.Row(ruleName: $0, taskCount: counts[$0] ?? 0, seconds: seconds[$0] ?? 0)
            }
            let total = tasks.reduce(0) { $0 + $1.duration }
            let other = tasks.filter { $0.kind == .other }.reduce(0) { $0 + $1.duration }
            return BuildModel(
                readerKind: .slf, formatVersion: 11, layout: .commandLine,
                sessionStart: SyntheticModel.sessionStart, sessionEnd: SyntheticModel.sessionStart + SyntheticModel.sessionSpan,
                tasks: tasks, targets: targets, diagnostics: [diagnostic], decodeWarnings: [], degradations: [],
                unclassifiedShare: total > 0 ? other / total : 0, timingSummary: TimingSummary(rows: rows),
                buildAttachments: [], kindTableVersion: table.version)
        }
    }

    /// A large deterministic model for the performance budget (v0.2 exit criteria: 50k tasks, no build description):
    /// one planning step, then per target a Swift planning task, single-file compiles 16 at a time (every 8th with
    /// two debug-time lines, every 50th a two-file batch), an emit-module and a link; targets overlap by half. Times
    /// are multiples of 1/64 s.
    public static func large(taskCount: Int = 50_000, targets targetCount: Int = 50) -> BuildModel {
        let table = KindTable.v1
        var tasks: [BuildTask] = []
        func add(_ rule: String, target: Int?, start: Double, seconds: Double, title: String,
                 details: String? = nil, output: String? = nil) {
            let entry = table.lookup(rule)
            let begin = sessionStart + start
            tasks.append(BuildTask(
                id: tasks.count, ruleName: rule, kind: entry?.kind ?? .other, kindSource: entry == nil ? .none : .rule,
                phase: entry?.phase ?? .other, targetId: target, start: begin, end: begin + seconds, duration: seconds,
                resultCode: 0, metrics: nil, backtrace: nil, taskKey: nil, subspans: [], commandDetails: details,
                signature: nil, title: title, emittedOutput: output, diagnosticIds: [], slfOnly: nil,
                unknownAttachments: []))
        }
        add("CreateBuildDescription", target: nil, start: 0, seconds: 1, title: "Create build description",
            output: "Build description signature: 0123456789abcdef0123456789abcdef\r")
        let perTarget = max(1, (taskCount - 1) / targetCount - 3)
        var cursor = 1.0
        for target in 0..<targetCount {
            let name = "Module\(target)"
            let suffix = " (in target '\(name)' from project 'Big')"
            add("SwiftDriver", target: target, start: cursor, seconds: 0.25, title: "Planning \(name)")
            let compileStart = cursor + 0.25
            var end = compileStart
            for index in 0..<perTarget {
                let start = compileStart + Double(index / 16) * 0.25
                let seconds = 0.125 + Double(index % 4) / 64
                let file = "/src/\(name)/File\(index).swift"
                var details = "SwiftCompile normal arm64 Compiling\\ File\(index).swift \(file)"
                if index % 50 == 49 { details += " /src/\(name)/Extra\(index).swift" }
                let output = index % 8 == 0
                    ? "12.5ms\t\(file):3:7\tgetter \(name).(file).View\(index)._@\(file):3:7\r0.5ms\t\(file):9:2\r" : nil
                add("SwiftCompile", target: target, start: start, seconds: seconds, title: "Compiling File\(index).swift",
                    details: details + suffix, output: output)
                end = max(end, start + seconds)
            }
            add("SwiftEmitModule", target: target, start: compileStart, seconds: 0.5, title: "Emitting module for \(name)")
            add("Ld", target: target, start: end, seconds: 0.125, title: "Link \(name)",
                details: "Ld /products/\(name).o normal" + suffix)
            cursor = (compileStart + end) / 2
        }
        while tasks.count < taskCount {
            add("WriteAuxiliaryFile", target: nil, start: 0.5, seconds: 0.015625, title: "Write aux file")
        }
        let span = tasks.map { $0.end - sessionStart }.max() ?? 0
        var targets = (0..<targetCount).map {
            Target(id: $0, name: "Module\($0)", project: "Big", path: nil, isPackage: false, isBucket: false,
                   taskIds: [])
        }
        for task in tasks { if let id = task.targetId { targets[id].taskIds.append(task.id) } }
        return BuildModel(
            readerKind: .slf, formatVersion: 11, layout: .commandLine, sessionStart: sessionStart,
            sessionEnd: sessionStart + span, tasks: tasks, targets: targets, diagnostics: [], decodeWarnings: [],
            degradations: [], unclassifiedShare: 0, timingSummary: nil, buildAttachments: [],
            kindTableVersion: table.version)
    }
}
