import Foundation

// v0.5 lane A (docs/SCHEMA-v0.5.md "Deep readers"): clang `-ftime-trace` Chrome-trace JSON next to each object file
// (DESIGN §5.8, MV-7). The log line `Time trace json-file dumped to <path>` is never printed (MV-7), and Xcode puts
// the flag into a `*-common-args.resp` response file, so the CompileC command line never shows it: traces are found
// by the object file of each executed CompileC task (`<objdir>/<name>.o` → `<objdir>/<name>.json`).
enum FTimeTraceReader {
    /// One translation unit's trace, aggregated.
    struct Summary: Equatable {
        /// `Total Frontend` (else the `Frontend` events), ms.
        var frontendMs: Double?
        var backendMs: Double?
        /// `Total ExecuteCompiler` (else `ExecuteCompiler`), ms.
        var totalMs: Double?
        /// Headers by inclusive `Source` time (`args.detail`), heaviest first.
        var includes: [(path: String, ms: Double)]
        /// Template instantiations by name (`InstantiateFunction` / `InstantiateClass`, `args.detail`), heaviest first.
        var instantiations: [(name: String, ms: Double)]
        /// `Total InstantiateFunction` + `Total InstantiateClass` (else the events), ms.
        var instantiationMs: Double

        static func == (lhs: Summary, rhs: Summary) -> Bool {
            lhs.frontendMs == rhs.frontendMs && lhs.backendMs == rhs.backendMs && lhs.totalMs == rhs.totalMs
                && lhs.includes.map(\.path) == rhs.includes.map(\.path) && lhs.includes.map(\.ms) == rhs.includes.map(\.ms)
                && lhs.instantiations.map(\.name) == rhs.instantiations.map(\.name)
                && lhs.instantiationMs == rhs.instantiationMs
        }
    }

    /// Traces larger than this are not parsed (`JSONSerialization` holds the whole tree in memory).
    static let maxTraceBytes = 64 << 20

    /// Rows per translation unit at most for includes.
    static let topIncludes = 10
    static let topInstantiations = 3

    /// Aggregates a Chrome trace (`{"traceEvents": [...]}`): `ph: X` events with `dur` (µs), `Source` also as `b`/`e`
    /// pairs (clang 17+), `Total <Name>` summary events.
    static func summarize(_ data: Data) throws -> Summary {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = object["traceEvents"] as? [[String: Any]] else {
            throw XcblameError.readerFailure("not a Chrome trace (no traceEvents)")
        }
        var totals: [String: Double] = [:]
        var sums: [String: Double] = [:]
        var includes: [String: Double] = [:]
        var instantiations: [String: Double] = [:]
        // Open `Source` begins per (tid, id), a stack each (headers nest).
        var open: [String: [(ts: Double, detail: String)]] = [:]
        for event in events {
            guard let name = event["name"] as? String, let phase = event["ph"] as? String else { continue }
            let detail = (event["args"] as? [String: Any])?["detail"] as? String
            let ts = (event["ts"] as? NSNumber)?.doubleValue ?? 0
            let dur = (event["dur"] as? NSNumber)?.doubleValue ?? 0
            switch phase {
            case "X":
                if name.hasPrefix("Total ") {
                    totals[String(name.dropFirst(6))] = dur / 1000
                    continue
                }
                sums[name, default: 0] += dur / 1000
                if name == "Source", let detail { includes[detail, default: 0] += dur / 1000 }
                if name == "InstantiateFunction" || name == "InstantiateClass", let detail {
                    instantiations[detail, default: 0] += dur / 1000
                }
            case "b" where name == "Source":
                let key = "\(event["tid"] ?? "")/\(event["id"] ?? "")"
                open[key, default: []].append((ts, detail ?? "?"))
            case "e" where name == "Source":
                let key = "\(event["tid"] ?? "")/\(event["id"] ?? "")"
                guard let begin = open[key]?.popLast() else { continue }
                let ms = max(0, ts - begin.ts) / 1000
                includes[begin.detail, default: 0] += ms
                sums["Source", default: 0] += ms
            default:
                continue
            }
        }
        func value(_ name: String) -> Double? { totals[name] ?? sums[name] }
        let instantiationTotal = (totals["InstantiateFunction"] ?? sums["InstantiateFunction"] ?? 0)
            + (totals["InstantiateClass"] ?? sums["InstantiateClass"] ?? 0)
        func ranked(_ values: [String: Double]) -> [(String, Double)] {
            values.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }
        }
        return Summary(frontendMs: value("Frontend"), backendMs: value("Backend"), totalMs: value("ExecuteCompiler"),
                       includes: ranked(includes).map { (path: $0.0, ms: $0.1) },
                       instantiations: ranked(instantiations).map { (name: $0.0, ms: $0.1) },
                       instantiationMs: instantiationTotal)
    }

    /// The object file a CompileC task writes: the first `.o` token of its command's first line
    /// (`CompileC <obj>.o <src> normal arm64 ...`), else the token after `-o`.
    static func objectFile(of task: BuildTask) -> String? {
        guard let details = task.commandDetails else { return nil }
        let lines = details.split(whereSeparator: { $0 == "\n" || $0 == "\r" })
        if let first = lines.first, let object = tokens(first).first(where: { $0.hasPrefix("/") && $0.hasSuffix(".o") }) {
            return object
        }
        for line in lines.dropFirst() {
            let words = tokens(line)
            if let at = words.firstIndex(of: "-o"), at + 1 < words.count, words[at + 1].hasSuffix(".o") {
                return words[at + 1]
            }
        }
        return nil
    }

    /// Space-separated words with `\ ` escapes kept inside a word.
    private static func tokens(_ line: Substring) -> [String] {
        var out: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == " " {
                if !current.isEmpty { out.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// The trace of an object file: the same folder and base name, `.json`.
    static func traceURL(forObject object: String) -> URL {
        URL(fileURLWithPath: object).deletingPathExtension().appendingPathExtension("json")
    }

    /// Rows of source `ftimeTrace`, aggregated per translation unit (`line` and `col` 0): one `frontend` row per TU
    /// (the source file, frontend ms), one `include` row per heavy header (the header, inclusive parse ms), one
    /// `instantiation` row per TU with templates (the source file, instantiation ms, top names in the declaration).
    /// Unfiltered.
    static func read(counted: [Timing.Counted], model: BuildModel) throws -> [HotspotValue] {
        var notes: [String] = []
        return try read(counted: counted, model: model, notes: &notes)
    }

    /// `read` plus why TUs had no trace: cache hits (`Cache hit` output, MV-7/MV-12), missing files, traces older than
    /// the build (the deep DerivedData persists, so a TU replayed or not rebuilt keeps an earlier build's trace), and
    /// traces over `maxTraceBytes`. Explicit-module PCM builds never have one (MV-7); they are not CompileC tasks and
    /// are not counted here.
    static func read(counted: [Timing.Counted], model: BuildModel, notes: inout [String]) throws -> [HotspotValue] {
        var rows: [HotspotValue] = []
        var compiles = 0
        var replayed = 0
        var missing = 0
        var stale = 0
        var oversized = 0
        var unreadable: [String] = []
        let fm = FileManager.default
        for item in counted where item.task.kind == .clangCompile {
            let task = item.task
            guard let object = objectFile(of: task) else { continue }
            compiles += 1
            // A cache hit writes no trace: whatever lies next to the object is from an earlier build.
            if task.emittedOutput?.trimmingCharacters(in: .whitespacesAndNewlines) == "Cache hit" {
                replayed += 1
                continue
            }
            let url = traceURL(forObject: object)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path) else {
                missing += 1
                continue
            }
            let buildStart = Timing.isPlausible(model.sessionStart) ? min(model.sessionStart, task.start) : task.start
            if let modified = attributes[.modificationDate] as? Date,
               modified.timeIntervalSince1970 < buildStart - 1 {
                stale += 1
                continue
            }
            if let size = (attributes[.size] as? NSNumber)?.intValue, size > maxTraceBytes {
                oversized += 1
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                missing += 1
                continue
            }
            let summary: Summary
            do { summary = try summarize(data) } catch {
                unreadable.append(url.lastPathComponent)
                continue
            }
            let source = FileAttribution.files(of: task).first ?? object
            let unit = (source as NSString).lastPathComponent
            func row(_ file: String, _ kind: String, _ ms: Double, _ declaration: String) -> HotspotValue {
                HotspotValue(file: file, line: 0, col: 0, declaration: declaration, kind: kind, ms: ms,
                             source: "ftimeTrace", onPathWeight: 1, occurrences: 1, targetId: task.targetId,
                             taskId: task.id)
            }
            if let frontend = summary.frontendMs ?? summary.totalMs {
                var parts = [String(format: "frontend %.1f ms", frontend)]
                if let backend = summary.backendMs { parts.append(String(format: "backend %.1f ms", backend)) }
                if let total = summary.totalMs { parts.append(String(format: "compiler %.1f ms", total)) }
                rows.append(row(source, "frontend", frontend, "translation unit: " + parts.joined(separator: ", ")))
            }
            for include in summary.includes.prefix(topIncludes) {
                rows.append(row(include.path, "include", include.ms, "included from \(unit)"))
            }
            if summary.instantiationMs > 0 {
                let names = summary.instantiations.prefix(topInstantiations).map(\.name).joined(separator: ", ")
                rows.append(row(source, "instantiation", summary.instantiationMs,
                                "template instantiation in \(unit)" + (names.isEmpty ? "" : ": " + names)))
            }
        }
        if replayed > 0 {
            notes.append("ftime-trace: \(replayed) of \(compiles) C-family compile(s) were compilation-cache hits and "
                + "wrote no trace (MV-7)")
        }
        if missing > 0 {
            notes.append("ftime-trace: no trace next to the object file of \(missing) of \(compiles) C-family compile(s)")
        }
        if stale > 0 {
            notes.append("ftime-trace: \(stale) of \(compiles) C-family compile(s) left only a trace older than this build "
                + "(from an earlier deep build); ignored")
        }
        if oversized > 0 {
            notes.append("ftime-trace: \(oversized) trace(s) over \(maxTraceBytes >> 20) MB not read")
        }
        if !unreadable.isEmpty {
            notes.append("ftime-trace: unreadable trace(s): " + unreadable.prefix(5).joined(separator: ", "))
        }
        return rows
    }
}
