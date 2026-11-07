import Foundation

// v0.5 lane A (docs/SCHEMA-v0.5.md "Deep readers"): `-stats-output-dir` JSON, one file per frontend job (DESIGN §5.8,
// key format MV-6, docs/research/probes-v0.5.md).
enum StatsDirReader {
    /// One frontend job's file: `stats-<µs>-swift-frontend-<Module>-<input|all>-<triple>-<outputType>-<opt>-<n>.json`.
    struct Job: Equatable {
        var module: String
        /// The first primary file's name (`StudioView.swift`), or `all` (emit-module, dependency scan, whole module).
        var input: String
        /// `arm64_apple_macos14.0` (`-` written as `_`).
        var triple: String
        /// `o` (compile), `swiftmodule` (emit-module), empty (dependency scan).
        var outputType: String
        var optimization: String
        /// `time.swift-frontend.<job>.wall`, seconds.
        var wall: Double?
        /// Wall seconds of the fixed top-level phases that are present (`phaseKeys`); never summed, they nest.
        var phases: [String: Double]

        var arch: String { triple.components(separatedBy: "_apple").first ?? triple }
        var isCompile: Bool { outputType == "o" }
        /// Type-check seconds: `Type checking and Semantic analysis`, else `perform-sema` (the same span, MV-6).
        var typeCheck: Double? { phases["typeCheck"] }
    }

    /// Report name → `time.swift.<phase>.wall` phase names, first present wins. Picked top-level spans only; LLVM has no
    /// own timer on 26 (27.1 adds `SIL-and-LLVM-processing`, which contains SIL processing).
    static let phaseKeys: [(name: String, keys: [String])] = [
        ("typeCheck", ["Type checking and Semantic analysis", "perform-sema"]),
        ("silGen", ["SILGen"]),
        ("silOptimization", ["SIL optimization"]),
        ("irGen", ["IRGen"]),
        ("silAndLLVM", ["SIL-and-LLVM-processing"]),
    ]

    private static let namePattern = try! NSRegularExpression(
        pattern: #"^stats-(\d+)-swift-frontend-(.+?)-(all|.+?\.swift)-([A-Za-z0-9_.]+)-([a-z]*)-(O[a-z]*)-(\d+)\.json$"#)

    /// The job fields of a stats file name; nil for anything else.
    static func parseName(_ name: String) -> Job? {
        let range = NSRange(name.startIndex..., in: name)
        guard let match = namePattern.firstMatch(in: name, range: range) else { return nil }
        func group(_ i: Int) -> String { Range(match.range(at: i), in: name).map { String(name[$0]) } ?? "" }
        return Job(module: group(2), input: group(3), triple: group(4), outputType: group(5), optimization: group(6),
                   wall: nil, phases: [:])
    }

    /// The job of one file: name fields plus timers. Nil when the name does not match; throws when the JSON is bad.
    static func job(at url: URL) throws -> Job? {
        guard var job = parseName(url.lastPathComponent) else { return nil }
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XcblameError.readerFailure("\(url.lastPathComponent): not a JSON object")
        }
        var walls: [String: Double] = [:]
        for (key, value) in object where key.hasSuffix(".wall") {
            guard let seconds = (value as? NSNumber)?.doubleValue else { continue }
            if key.hasPrefix("time.swift-frontend.") {
                job.wall = seconds
            } else if key.hasPrefix("time.swift.") {
                walls[String(key.dropFirst("time.swift.".count).dropLast(".wall".count))] = seconds
            }
        }
        for (name, keys) in phaseKeys {
            if let seconds = keys.lazy.compactMap({ walls[$0] }).first { job.phases[name] = seconds }
        }
        return job
    }

    /// Every job of `directory` sorted by file name; files that are not stats files are skipped.
    static func jobs(in directory: URL) throws -> [Job] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.sorted()
        return try names.compactMap { try job(at: directory.appendingPathComponent($0)) }
    }

    /// Rows of source `statsDir`: per input file (`line` and `col` 0, file-level), `ms` from the frontend timers,
    /// `declaration` the job kind. Unfiltered (the merge filters to user code).
    ///
    /// Compile jobs only (emit-module and dependency-scan jobs have no file). Each job is matched to the log's Swift
    /// compile task of the same target (`module`) whose files hold `input` (same arch first): one primary file gives
    /// kind `file` with that path; several give kind `batch` (the job covers the whole batch, first file named);
    /// `all` gives kind `wmo`. `ms` is the type-check wall time (the frontend total when there is none); the
    /// declaration lists the frontend total and the other phases. A job with no matching task keeps the bare input
    /// name, which the user-code filter drops.
    static func read(directory: URL, model: BuildModel) throws -> [HotspotValue] {
        let targetIds = Dictionary(model.targets.map { ($0.name, $0.id) }, uniquingKeysWith: { first, _ in first })
        var compiles: [Int: [(task: BuildTask, files: [String])]] = [:]
        for task in model.tasks where task.kind == .swiftCompile {
            guard let target = task.targetId else { continue }
            let files = FileAttribution.files(of: task)
            if !files.isEmpty { compiles[target, default: []].append((task, files)) }
        }
        var rows: [HotspotValue] = []
        for job in try jobs(in: directory) where job.isCompile {
            let candidates = targetIds[job.module].flatMap { compiles[$0] } ?? []
            let matching = job.input == "all"
                ? candidates
                : candidates.filter { $0.files.contains { ($0 as NSString).lastPathComponent == job.input } }
            let match = matching.first { $0.task.commandDetails?.contains("/\(job.arch)/") == true
                || $0.task.commandDetails?.contains(" \(job.arch) ") == true } ?? matching.first
            let kind: String
            let file: String
            if job.input == "all" {
                kind = "wmo"
                file = match?.files.sorted().first ?? job.module
            } else {
                kind = (match?.files.count ?? 1) > 1 ? "batch" : "file"
                file = match?.files.first { ($0 as NSString).lastPathComponent == job.input } ?? job.input
            }
            let typeCheck = job.typeCheck ?? job.wall ?? 0
            var parts: [String] = []
            if let wall = job.wall { parts.append(String(format: "frontend %.1f ms", wall * 1000)) }
            for (name, label) in [("silGen", "SILGen"), ("silOptimization", "SIL optimization"), ("irGen", "IRGen"),
                                  ("silAndLLVM", "SIL+LLVM")] {
                if let seconds = job.phases[name] { parts.append(String(format: "%@ %.1f ms", label, seconds * 1000)) }
            }
            let what = kind == "batch" ? "batch of \(match?.files.count ?? 0) files" : kind == "wmo" ? "whole module" : "file"
            let measured = job.typeCheck == nil ? "frontend (no type-check timer)" : "type-check"
            let declaration = "compile job (\(what), \(job.arch)): \(measured); " + parts.joined(separator: ", ")
            rows.append(HotspotValue(file: file, line: 0, col: 0, declaration: declaration, kind: kind,
                                     ms: typeCheck * 1000, source: "statsDir", onPathWeight: 1, occurrences: 1,
                                     targetId: match?.task.targetId ?? targetIds[job.module],
                                     taskId: match?.task.id))
        }
        return rows
    }
}
