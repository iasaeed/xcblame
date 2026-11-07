import Foundation

// v0.5 lane C (docs/SCHEMA-v0.5.md "Module graph"): variants from `clangmodulesreport/` and `swiftmodulesreport/`
// (DESIGN §5.11, §6.9).
enum ModuleVariants {
    /// One module of one report: its variants (PCM file stems, report order) and the flags that differ between them.
    struct ReportModule: Equatable {
        /// `swiftmodulesreport` / `clangmodulesreport`.
        var report: String
        /// Module name without the ` (Clang)` suffix of the Swift report.
        var module: String
        /// Variant names without `.pcm` (`Darwin-1O0UIAOGBDH5HDGBN297OVSJS`), in report order; the first is the one kept.
        var variants: [String]
        /// Header flags of the module CSV, the bare wrapper tokens (`-Xcc`, `-D`) left out.
        var flags: [String]
    }

    static let reportNames = ["swiftmodulesreport", "clangmodulesreport"]
    /// Header tokens that only wrap the next flag (`-Xcc -D -Xcc SWIFT_PACKAGE`).
    static let wrapperTokens: Set<String> = ["-Xcc", "-D", "-Xclang", "-Xfrontend", "-Xllvm"]

    /// The report folders of a description: inside it (a snapshot) or next to it (live `XCBuildData`).
    static func reportDirectories(of description: BuildDescription) -> [URL] {
        let fm = FileManager.default
        return reportNames.compactMap { name in
            [description.directory.appendingPathComponent(name),
             description.directory.deletingLastPathComponent().appendingPathComponent(name)]
                .first { fm.fileExists(atPath: $0.appendingPathComponent("Summary.csv").path) }
        }
    }

    /// Variant counts and differing flags per module from the description folder's (or snapshot's) modules reports,
    /// PCM tasks matched by variant file name, causes classified from the flags. Nil when no report exists.
    /// Redundant = every variant beyond the first of a module within one report (V12); `modules` counts distinct
    /// module names across both reports; `pcmTasks` counts the log's executed PCM tasks.
    static func compute(description: BuildDescription?, model: BuildModel,
                        counted: [Timing.Counted]) -> ReportDocument.ModuleGraph.Variants? {
        guard let description else { return nil }
        let directories = reportDirectories(of: description)
        guard !directories.isEmpty else { return nil }
        let modules = directories.flatMap { read(directory: $0) }
        return summarize(modules, counted: counted)
    }

    /// Pure part of `compute`, for tests.
    static func summarize(_ modules: [ReportModule], counted: [Timing.Counted]) -> ReportDocument.ModuleGraph.Variants {
        // PCM tasks by output stem (`SwiftShims-2427RXV5PFL7BUOTJAJY7PQ6Z` from `…/SwiftShims-2427….pcm` or `.scan`).
        let pcm = counted.filter { $0.task.kind == .modulePrecompile }
        var byStem: [String: Double] = [:]
        for item in pcm {
            guard let token = Explain.firstPathToken(item.task) else { continue }
            byStem[(token as NSString).deletingPathExtension, default: 0] += item.interval.duration
        }
        struct Merged {
            var variants = 0
            var flags: [String] = []
            var pcmTasks = 0
            var redundantTasks = 0
            var redundantSeconds = 0.0
        }
        var merged: [String: Merged] = [:]
        var moduleOrder: [String] = []
        for module in modules {
            if merged[module.module] == nil { moduleOrder.append(module.module) }
            var entry = merged[module.module] ?? Merged()
            entry.variants = max(entry.variants, module.variants.count)
            for flag in module.flags where !entry.flags.contains(flag) { entry.flags.append(flag) }
            entry.pcmTasks += module.variants.filter { byStem[$0] != nil }.count
            entry.redundantTasks += max(0, module.variants.count - 1)
            entry.redundantSeconds += module.variants.dropFirst().reduce(0) { $0 + (byStem[$1] ?? 0) }
            merged[module.module] = entry
        }
        var causeSeconds: [String: Double] = [:]
        let rows = moduleOrder.compactMap { name -> ReportDocument.ModuleGraph.ModuleVariant? in
            guard let entry = merged[name], entry.variants >= 2 else { return nil }
            let found = Self.causes(flags: entry.flags)
            for cause in found { causeSeconds[cause, default: 0] += entry.redundantSeconds }
            return .init(module: name, variants: entry.variants, flags: entry.flags, causes: found,
                         pcmTasks: entry.pcmTasks, redundantSeconds: ReportDocument.round6(entry.redundantSeconds))
        }.sorted {
            if ($0.redundantSeconds ?? 0) != ($1.redundantSeconds ?? 0) { return ($0.redundantSeconds ?? 0) > ($1.redundantSeconds ?? 0) }
            if $0.variants != $1.variants { return $0.variants > $1.variants }
            return $0.module < $1.module
        }
        let redundantTasks = merged.values.reduce(0) { $0 + $1.redundantTasks }
        let redundantSeconds = merged.values.reduce(0) { $0 + $1.redundantSeconds }
        let vocabulary = ReportDocument.ModuleGraph.variantCauses
        let causes = causeSeconds.keys.sorted {
            causeSeconds[$0]! != causeSeconds[$1]! ? causeSeconds[$0]! > causeSeconds[$1]!
                : vocabulary.firstIndex(of: $0)! < vocabulary.firstIndex(of: $1)!
        }
        return .init(modules: merged.count, pcmTasks: pcm.count, redundantTasks: redundantTasks,
                     redundantSeconds: ReportDocument.round6(redundantSeconds), causes: causes, perModule: rows,
                     perModuleTotal: rows.count, perModuleShownShare: rows.isEmpty ? nil : 1)
    }

    /// `Summary.csv` (`Name,Variants`) names the modules; `<Name>.csv` (`Variant,<flag>…` then one row per variant)
    /// gives the variants and the differing flags. A module whose CSV is missing keeps its count with unnamed variants.
    static func read(directory: URL) -> [ReportModule] {
        let report = directory.lastPathComponent
        guard let summary = try? String(contentsOf: directory.appendingPathComponent("Summary.csv"), encoding: .utf8)
        else { return [] }
        return csvRows(summary).dropFirst().compactMap { row -> ReportModule? in
            guard row.count >= 2, let count = Int(row[1].trimmingCharacters(in: .whitespaces)), !row[0].isEmpty else {
                return nil
            }
            let name = row[0]
            let module = name.hasSuffix(" (Clang)") ? String(name.dropLast(" (Clang)".count)) : name
            let file = directory.appendingPathComponent(name + ".csv")
            let table = (try? String(contentsOf: file, encoding: .utf8)).map(csvRows) ?? []
            let flags = (table.first?.dropFirst() ?? []).filter { !$0.isEmpty && !wrapperTokens.contains($0) }
            var variants = table.dropFirst().compactMap { $0.first }.filter { !$0.isEmpty }
                .map { $0.hasSuffix(".pcm") ? String($0.dropLast(4)) : $0 }
            if variants.count != count {
                variants = variants.count > count ? Array(variants.prefix(count))
                    : variants + (variants.count..<count).map { "\(module)#\($0)" }
            }
            var unique: [String] = []
            for flag in flags where !unique.contains(flag) { unique.append(flag) }
            return ReportModule(report: report, module: module, variants: variants, flags: unique)
        }
    }

    /// Minimal CSV: comma-separated, double-quoted fields with `""` escapes, one record per line.
    static func csvRows(_ text: String) -> [[String]] {
        text.split(whereSeparator: \.isNewline).map { line in
            var fields: [String] = []
            var field = ""
            var quoted = false
            var iterator = line.makeIterator()
            var pending: Character? = nil
            while let char = pending ?? iterator.next() {
                pending = nil
                if quoted {
                    if char == "\"" {
                        if let next = iterator.next() {
                            if next == "\"" { field.append("\"") } else { quoted = false; pending = next }
                        } else { quoted = false }
                    } else { field.append(char) }
                } else if char == "\"" {
                    quoted = true
                } else if char == "," {
                    fields.append(field)
                    field = ""
                } else {
                    field.append(char)
                }
            }
            fields.append(field)
            return fields
        }
    }

    /// `languageMode` (`-fapinotes-swift-version`, `__swift__`), `swiftPackage` (`SWIFT_PACKAGE`), `macros` (other
    /// `-D` definitions: `NAME` or `NAME=value` tokens, `-DNAME`), else `other`; in `variantCauses` order.
    static func causes(flags: [String]) -> [String] {
        var found = Set<String>()
        for flag in flags {
            let bare = flag.hasPrefix("-D") && flag.count > 2 ? String(flag.dropFirst(2)) : flag
            if flag.contains("-fapinotes-swift-version") || bare.hasPrefix("__swift__") {
                found.insert("languageMode")
            } else if bare == "SWIFT_PACKAGE" || bare.hasPrefix("SWIFT_PACKAGE=") {
                found.insert("swiftPackage")
            } else if flag.hasPrefix("-D") || (!flag.hasPrefix("-") && flag.range(of: "^[A-Za-z_][A-Za-z0-9_]*(=.*)?$",
                                                                                   options: .regularExpression) != nil) {
                found.insert("macros")
            } else {
                found.insert("other")
            }
        }
        if found.isEmpty { found.insert("other") }
        return ReportDocument.ModuleGraph.variantCauses.filter(found.contains)
    }
}
