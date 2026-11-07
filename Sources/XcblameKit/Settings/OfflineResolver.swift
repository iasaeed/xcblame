import Foundation

/// Effective settings from provenance alone (`--offline`, or xcodebuild failed): `$(inherited)` expanded along each
/// key's chain (an `$(inherited)` at the bottom stands for an empty platform default), then `$(KEY)` / `${KEY}`
/// references resolved within the target's own map. References to keys nothing sets (platform defaults we do not
/// know) stay unexpanded and are counted in `notes`. Only keys the project writes appear in the output.
enum OfflineResolver {
    static func resolve(project: ProjectModel, configuration: String) -> EffectiveSettings {
        var resolver = ProvenanceResolver(project: project)
        var targets: [String: [String: String]] = [:]
        var unknownRefs: Set<String> = []
        for target in project.allTargets where targets[target.name] == nil {
            let (values, unknown) = resolve(&resolver, target: target.name, configuration: configuration)
            targets[target.name] = values
            unknownRefs.formUnion(unknown)
        }
        var notes: [String] = []
        if !unknownRefs.isEmpty {
            let sample = unknownRefs.sorted().prefix(8).joined(separator: ", ")
            notes.append("offline resolver: \(unknownRefs.count) referenced setting(s) left unexpanded "
                + "(platform defaults not known offline): \(sample)\(unknownRefs.count > 8 ? ", …" : "")")
        }
        let (packages, packageNotes) = packageTargets(project: project, existing: Set(targets.keys))
        targets.merge(packages) { project, _ in project }
        notes += packageNotes
        return EffectiveSettings(configuration: configuration, targets: targets, source: .offlineResolver, notes: notes)
    }

    /// One target's resolved map plus the names it referenced that nothing sets.
    static func resolve(_ resolver: inout ProvenanceResolver, target: String, configuration: String,
                        effective: [String: String]? = nil) -> (values: [String: String], unknown: Set<String>) {
        guard let all = resolver.assignments(target: target, configuration: configuration),
              let (proj, _) = resolver.locate(target) else { return ([:], []) }
        let context = resolver.context(target: target, configuration: configuration, effective: effective)
        var unexpanded: [String: String] = [:]
        for (key, chain) in all {
            var value = ""
            var any = false
            for a in chain where a.condition.map(context.matches) ?? true {
                value = replaceInherited(a.raw, with: value)
                any = true
            }
            if any { unexpanded[key] = value }
        }
        // Builtins the build system always defines; used for expansion only, never emitted.
        let projectDir = proj.path.deletingLastPathComponent().standardizedFileURL.path
        let builtins = ["TARGET_NAME": target, "PROJECT_NAME": proj.name, "CONFIGURATION": configuration,
                        "SRCROOT": projectDir, "PROJECT_DIR": projectDir, "SOURCE_ROOT": projectDir]
        var expander = Expander(raw: unexpanded, builtins: builtins)
        var values: [String: String] = [:]
        for key in unexpanded.keys { values[key] = expander.value(of: key) }
        return (values, expander.unknown)
    }

    static func replaceInherited(_ raw: String, with lower: String) -> String {
        raw.replacingOccurrences(of: "$(inherited)", with: lower).replacingOccurrences(of: "${inherited}", with: lower)
    }

    /// Late-binding `$(KEY)` expansion with a cycle guard; anything that is not a plain name (`$(A:lower)`,
    /// `$(A_$(B))`) is left as written.
    struct Expander {
        let raw: [String: String]
        let builtins: [String: String]
        var done: [String: String] = [:]
        var active: Set<String> = []
        var unknown: Set<String> = []

        init(raw: [String: String], builtins: [String: String]) {
            self.raw = raw
            self.builtins = builtins
        }

        mutating func value(of key: String) -> String? {
            if let cached = done[key] { return cached }
            guard let text = raw[key] ?? builtins[key] else { return nil }
            guard !active.contains(key) else { return text }
            active.insert(key)
            let result = expand(text)
            active.remove(key)
            done[key] = result
            return result
        }

        mutating func expand(_ text: String) -> String {
            guard text.contains("$") else { return text }
            var out = ""
            var i = text.startIndex
            while i < text.endIndex {
                let c = text[i]
                let next = text.index(after: i)
                guard c == "$", next < text.endIndex, text[next] == "(" || text[next] == "{" else {
                    out.append(c)
                    i = next
                    continue
                }
                let close: Character = text[next] == "(" ? ")" : "}"
                guard let end = text[next...].firstIndex(of: close) else {
                    out += text[i...]
                    break
                }
                let name = String(text[text.index(after: next)..<end])
                let whole = String(text[i...end])
                if XCConfigChain.isIdentifier(name), let resolved = value(of: name) {
                    out += resolved
                } else {
                    if XCConfigChain.isIdentifier(name) { unknown.insert(name) }
                    out += whole
                }
                i = text.index(after: end)
            }
            return out
        }
    }

    /// Package targets (not listed by xcodebuild): local manifests only, `SWIFT_VERSION` from
    /// `swiftLanguageModes`/`swiftLanguageVersions` or the tools version; nothing else is known.
    static func packageTargets(project: ProjectModel, existing: Set<String>) -> ([String: [String: String]], [String]) {
        var out: [String: [String: String]] = [:]
        var skipped: [String] = []
        for package in project.packages {
            guard let manifest = package.manifest else { continue }
            let manifestURL = package.path.map { $0.lastPathComponent == "Package.swift" ? $0 : $0.appendingPathComponent("Package.swift") }
            let swiftVersion = manifestURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) }.flatMap(swiftVersion(manifest:))
            for target in manifest.targets where ["regular", "executable", "test", "macro"].contains(target.type) {
                guard !existing.contains(target.name) else {
                    skipped.append(target.name)
                    continue
                }
                var settings: [String: String] = [:]
                if let swiftVersion { settings["SWIFT_VERSION"] = swiftVersion }
                out[target.name] = settings
            }
        }
        var notes: [String] = []
        if !out.isEmpty {
            notes.append("package targets: offline resolver only (SWIFT_VERSION from the manifest; other settings unknown)")
        }
        if !skipped.isEmpty {
            notes.append("package targets named like project targets not listed: \(skipped.sorted().joined(separator: ", "))")
        }
        return (out, notes)
    }

    /// `6` / `5` / `4.2` from a manifest's text: the highest `swiftLanguageModes` (or legacy `swiftLanguageVersions`)
    /// entry, else the tools version's major (`// swift-tools-version: 6.0` → `6`, `5.9` → `5`).
    static func swiftVersion(manifest text: String) -> String? {
        if let range = text.range(of: #"swiftLanguage(Modes|Versions)\s*:\s*\[([^\]]*)\]"#, options: .regularExpression) {
            let list = String(text[range])
            let versions = matches(#"\.v(\d+(?:_\d+)?)"#, in: list).map { $0.replacingOccurrences(of: "_", with: ".") }
                + matches(#"\.version\(\s*"([^"]+)""#, in: list)
            if let best = versions.max(by: { $0.compare($1, options: .numeric) == .orderedAscending }) { return best }
        }
        guard let tools = matches(#"swift-tools-version\s*:\s*(\d+)"#, in: text).first else { return nil }
        return (Int(tools) ?? 5) >= 6 ? "6" : "5"
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }
}
