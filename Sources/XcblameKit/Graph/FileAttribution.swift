import Foundation

/// Compile time per source file, batch-aware (DESIGN §6.4). The files come from the compile task's own command line
/// (`commandDetails`, first line), never from titles. `exact`: one primary file; `batch`: one row for all its files,
/// never split; `wmo`: the module compile of a whole-module target. No `estimated` rows are produced.
// ponytail: `estimated` (batch time split by type-check ms) is left out: no fixture has a batch with per-file
// type-check text, and V9 forbids mixing it with exact rows. Add it when `--deep` lands.
struct FileRowValue {
    var path: String
    var targetId: Int?
    var seconds: Double
    var granularity: String
    var members: [String]?
    var onPath: Bool
    var typeCheckMs: Double?
    var taskId: Int?
}

enum FileAttribution {
    /// Source extensions recognized in a compile command line.
    static let sourceExtensions: Set<String> = ["swift", "m", "mm", "c", "cc", "cpp", "cxx", "s", "metal"]

    /// Source compiles only (Swift, C / Objective-C / C++, Metal): asset catalogs, storyboards, resources and
    /// scripts are not files of the files table.
    static func isFileCompile(_ task: BuildTask) -> Bool {
        task.kind == .swiftCompile || task.kind == .clangCompile || task.ruleName == "CompileMetalFile"
    }

    /// Absolute source paths on the first line of `commandDetails`, in order, without duplicates. Escaped spaces
    /// (`\ `) stay inside a path; the `(in target ...)` suffix is cut.
    static func files(of task: BuildTask) -> [String] {
        guard let details = task.commandDetails else { return [] }
        // Bytes, not Characters: this runs once per compile task (50k on large logs).
        let lineEnd = details.utf8.firstIndex { $0 == 10 || $0 == 13 } ?? details.endIndex
        var line = details[..<lineEnd]
        if let suffix = line.range(of: " (in target '") { line = line[..<suffix.lowerBound] }
        let bytes = line.utf8
        var tokens: [String] = []
        var current: [UInt8] = []
        var escaped = false
        func flush() {
            if current.first == UInt8(ascii: "/") { tokens.append(String(decoding: current, as: UTF8.self)) }
            current.removeAll(keepingCapacity: true)
        }
        for byte in bytes {
            if escaped {
                current.append(byte)
                escaped = false
            } else if byte == UInt8(ascii: "\\") {
                escaped = true
            } else if byte == UInt8(ascii: " ") {
                flush()
            } else {
                current.append(byte)
            }
        }
        flush()
        var seen = Set<String>()
        return tokens.filter { token in
            sourceExtensions.contains((token as NSString).pathExtension.lowercased()) && seen.insert(token).inserted
        }
    }

    /// Targets whose Swift planning command asks for whole-module optimization.
    static func wholeModuleTargets(_ model: BuildModel) -> Set<Int> {
        var targets = Set<Int>()
        for task in model.tasks where task.ruleName == "SwiftDriver" {
            guard let target = task.targetId, let text = task.commandDetails else { continue }
            if text.contains(" -whole-module-optimization") || text.contains(" -wmo ") { targets.insert(target) }
        }
        return targets
    }

    /// One row per file-compile task that names at least one file, ranked by seconds then path.
    static func rows(counted: [Timing.Counted], model: BuildModel, pathTaskIds: Set<Int>,
                     typeCheckMs: [String: Double]) -> [FileRowValue] {
        let wmo = wholeModuleTargets(model)
        var rows: [FileRowValue] = []
        for item in counted where isFileCompile(item.task) {
            let files = files(of: item.task)
            guard !files.isEmpty else { continue }
            let sorted = files.sorted()
            let typeCheck = files.compactMap { typeCheckMs[$0] }
            let typeCheckSum: Double? = typeCheck.isEmpty ? nil : typeCheck.reduce(0, +)
            let granularity: String
            if item.task.kind == .swiftCompile, let target = item.task.targetId, wmo.contains(target) {
                granularity = "wmo"
            } else {
                granularity = files.count == 1 ? "exact" : "batch"
            }
            rows.append(FileRowValue(
                path: sorted[0], targetId: item.task.targetId, seconds: item.interval.duration, granularity: granularity,
                members: granularity == "batch" ? sorted : nil, onPath: pathTaskIds.contains(item.task.id),
                typeCheckMs: typeCheckSum, taskId: item.task.id))
        }
        return rows.sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.path < $1.path }
    }
}
