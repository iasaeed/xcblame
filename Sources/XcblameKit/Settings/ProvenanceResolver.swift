import Foundation

/// What conditional assignments (`KEY[sdk=…][arch=…][config=…]`) are matched against.
struct ConditionContext: Equatable {
    /// SDK canonical name or SDKROOT (`iphoneos26.0`, `iphonesimulator`); nil: sdk conditions never match.
    var sdk: String?
    /// Architectures; empty: arch conditions never match.
    var archs: [String] = []
    var configuration: String

    /// From a target's effective settings when available (`SDK_NAME`, else the SDKROOT path's SDK name; `ARCHS`).
    static func from(effective: [String: String]?, fallbackSDK: String?, configuration: String) -> ConditionContext {
        var sdk = fallbackSDK
        var archs: [String] = []
        if let effective {
            if let name = effective["SDK_NAME"], !name.isEmpty {
                sdk = name
            } else if let root = effective["SDKROOT"], !root.isEmpty {
                // `/…/iPhoneOS26.0.sdk` → `iphoneos26.0`; a bare `iphoneos` stays.
                sdk = URL(fileURLWithPath: root).lastPathComponent.lowercased().replacingOccurrences(of: ".sdk", with: "")
            }
            archs = (effective["ARCHS"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        }
        return ConditionContext(sdk: sdk, archs: archs, configuration: configuration)
    }

    /// All `][`-joined conditions hold. Unknown condition names never match.
    func matches(_ condition: String) -> Bool {
        condition.components(separatedBy: "][").allSatisfy { part in
            let pieces = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count == 2 else { return false }
            let pattern = pieces[1]
            switch pieces[0] {
            case "sdk": return sdk.map { glob(pattern, $0) } ?? false
            case "arch": return archs.contains { glob(pattern, $0) }
            case "config": return glob(pattern, configuration)
            default: return false
            }
        }
    }

    private func glob(_ pattern: String, _ text: String) -> Bool { fnmatch(pattern, text, 0) == 0 }
}

/// One assignment of a key at one level, in evaluation order (low to high, later wins within a level).
struct LevelAssignment {
    var level: Provenance.Level
    var file: String?
    var raw: String
    var condition: String?

    var provenance: Provenance {
        Provenance(level: level, file: file, rawValue: raw, inherited: ProvenanceResolver.referencesInherited(raw))
    }
}

/// Provenance from the project model and xcconfig chains (DESIGN §7.4), plus the shared machinery the offline
/// resolver and the cache read.
struct ProvenanceResolver {
    let project: ProjectModel
    private var chains: [URL: XCConfigChain] = [:]

    init(project: ProjectModel) {
        self.project = project
    }

    /// The project and target that define `target`: a qualified `<project>/<target>` (`ProjectModel.allTargets`
    /// for names several projects use) names its project; a plain name takes the first match in project order.
    func locate(_ target: String) -> (ProjectModel.Project, ProjectModel.Target)? {
        if let slash = target.firstIndex(of: "/") {
            let projectName = String(target[..<slash]), name = String(target[target.index(after: slash)...])
            if let project = project.projects.first(where: { $0.name == projectName }),
               let found = project.targets.first(where: { $0.name == name }) { return (project, found) }
        }
        for project in project.projects {
            if let found = project.targets.first(where: { $0.name == target }) { return (project, found) }
        }
        return nil
    }

    mutating func chain(_ url: URL) -> XCConfigChain {
        if let cached = chains[url] { return cached }
        let chain = XCConfigChain.load(url)
        chains[url] = chain
        return chain
    }

    /// `file` as reported: relative to the project root when inside it, else absolute.
    func display(_ url: URL) -> String {
        let root = project.root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// Every assignment of every key for `target` in `configuration`, low to high, conditions unevaluated. Nil when
    /// the target is not a project target.
    mutating func assignments(target: String, configuration: String,
                              commandLine: [String: String] = [:]) -> [String: [LevelAssignment]]? {
        guard let (proj, tgt) = locate(target) else { return nil }
        var out: [String: [LevelAssignment]] = [:]
        func addChain(_ url: URL?, _ level: Provenance.Level) {
            guard let url else { return }
            for a in chain(url).assignments {
                out[a.key, default: []].append(LevelAssignment(level: level, file: display(a.file), raw: a.value,
                                                               condition: a.condition))
            }
        }
        func addSettings(_ settings: [String: SettingValue]?, _ level: Provenance.Level) {
            guard let settings else { return }
            let pbxproj = display(proj.path.appendingPathComponent("project.pbxproj"))
            for key in settings.keys.sorted() {
                let value = settings[key]!
                // Unconditional first, so a matching conditional value (more specific) wins within the level.
                if let raw = value.raw {
                    out[key, default: []].append(LevelAssignment(level: level, file: pbxproj, raw: raw, condition: nil))
                }
                for condition in (value.conditions ?? [:]).keys.sorted() {
                    out[key, default: []].append(LevelAssignment(level: level, file: pbxproj,
                                                                 raw: value.conditions![condition]!, condition: condition))
                }
            }
        }
        addChain(proj.projectXCConfig[configuration], .projectXCConfig)
        addSettings(proj.projectSettings[configuration], .projectSettings)
        addChain(tgt.xcconfig[configuration], .targetXCConfig)
        addSettings(tgt.settings[configuration], .targetSettings)
        for key in commandLine.keys.sorted() {
            out[key, default: []].append(LevelAssignment(level: .commandLine, file: nil, raw: commandLine[key]!,
                                                         condition: nil))
        }
        return out
    }

    /// The condition context for `target`: effective settings when given, else the target's own SDKROOT as written
    /// (`iphoneos` matches `sdk=iphoneos*`), unconditional assignments only.
    mutating func context(target: String, configuration: String, effective: [String: String]?) -> ConditionContext {
        if effective != nil {
            return ConditionContext.from(effective: effective, fallbackSDK: nil, configuration: configuration)
        }
        let plain = ConditionContext(sdk: nil, archs: [], configuration: configuration)
        let sdkroot = assignments(target: target, configuration: configuration)?["SDKROOT"]
            .map { $0.filter { $0.condition == nil || plain.matches($0.condition!) } }?.last?.raw
        return ConditionContext(sdk: sdkroot, archs: [], configuration: configuration)
    }

    /// The assignments of `key` that apply, low to high.
    mutating func chain(target: String, key: String, configuration: String, commandLine: [String: String] = [:],
                        effective: [String: String]? = nil) -> [LevelAssignment]? {
        guard let all = assignments(target: target, configuration: configuration, commandLine: commandLine) else {
            return nil
        }
        let context = context(target: target, configuration: configuration, effective: effective)
        return (all[key] ?? []).filter { $0.condition.map(context.matches) ?? true }
    }

    /// SDKs `target` builds for: written `SUPPORTED_PLATFORMS`, else the written SDKROOT with its simulator; every
    /// platform when neither is written (`auto`).
    mutating func supportedSDKs(target: String, configuration: String) -> [String] {
        let plain = ConditionContext(sdk: nil, archs: [], configuration: configuration)
        func written(_ key: String) -> String? {
            assignments(target: target, configuration: configuration)?[key]?
                .filter { $0.condition == nil || plain.matches($0.condition!) }.last?.raw
        }
        if let platforms = written("SUPPORTED_PLATFORMS")?.split(separator: " ").map(String.init), !platforms.isEmpty,
           !platforms.contains(where: { $0.contains("$(") }) {
            return platforms
        }
        let pairs: [(String, String?)] = [("iphoneos", "iphonesimulator"), ("macosx", nil), ("appletvos", "appletvsimulator"),
                                          ("watchos", "watchsimulator"), ("xros", "xrsimulator")]
        if let sdk = written("SDKROOT")?.lowercased(), let pair = pairs.first(where: { sdk.hasPrefix($0.0) }) {
            return [pair.0] + (pair.1.map { [$0] } ?? [])
        }
        return pairs.flatMap { [$0.0] + ($0.1.map { [$0] } ?? []) }
    }

    static func referencesInherited(_ raw: String) -> Bool {
        raw.contains("$(inherited)") || raw.contains("${inherited}") || raw.contains("$inherited")
    }

    static let order = Provenance.Level.allCases
    static func rank(_ level: Provenance.Level) -> Int { order.firstIndex(of: level) ?? order.count }
}

extension SettingsOracle {
    /// Every level that assigns `key` for `target` in `configuration`, low to high (the last one wins; within a level
    /// later lines win). Conditional assignments are matched against `effective` (`SDK_NAME`/`SDKROOT`, `ARCHS`) when
    /// given, else against the target's SDKROOT as written; an arch condition never matches without `effective`.
    /// Empty when nothing sets the key (platform default); `[Provenance(level: .unknown)]` for an unknown target.
    public static func provenanceChain(project: ProjectModel, target: String, key: String, configuration: String,
                                       commandLineOverrides: [String: String] = [:],
                                       effective: [String: String]? = nil) -> [Provenance] {
        var resolver = ProvenanceResolver(project: project)
        guard let chain = resolver.chain(target: target, key: key, configuration: configuration,
                                         commandLine: commandLineOverrides, effective: effective) else {
            return [Provenance(level: .unknown)]
        }
        return chain.map(\.provenance)
    }

    /// `provenance(project:target:key:configuration:)` with command-line overrides (`KEY=VALUE` arguments; the
    /// project model has none) and the target's effective settings for conditional keys.
    public static func provenance(project: ProjectModel, target: String, key: String, configuration: String,
                                  commandLineOverrides: [String: String], effective: [String: String]? = nil)
        -> Provenance {
        provenanceChain(project: project, target: target, key: key, configuration: configuration,
                        commandLineOverrides: commandLineOverrides, effective: effective).last
            ?? Provenance(level: .platformDefault)
    }

    /// For Lane C's overlay planning (DESIGN §7.5): the highest assignment above `level` that sets `key` without
    /// `$(inherited)`, which keeps a value written at `level` (e.g. an overlay xcconfig) from reaching the effective
    /// value. Nil when nothing above shadows it (or the target is unknown).
    public static func isShadowed(project: ProjectModel, target: String, key: String, configuration: String,
                                  byLevelAbove level: Provenance.Level,
                                  commandLineOverrides: [String: String] = [:]) -> Provenance? {
        let floor = ProvenanceResolver.rank(level)
        var resolver = ProvenanceResolver(project: project)
        guard let all = resolver.assignments(target: target, configuration: configuration,
                                             commandLine: commandLineOverrides) else { return nil }
        // A conditional assignment shadows when it can apply to any SDK the target builds for (a
        // `[sdk=iphonesimulator*]` value wins for every simulator build), not only the written SDKROOT.
        let sdks = resolver.supportedSDKs(target: target, configuration: configuration)
        return (all[key] ?? []).filter { assignment in
            guard ProvenanceResolver.rank(assignment.level) > floor,
                  !ProvenanceResolver.referencesInherited(assignment.raw) else { return false }
            guard let condition = assignment.condition else { return true }
            return sdks.contains { sdk in
                ConditionContext(sdk: sdk, archs: ["arm64", "arm64e", "x86_64"], configuration: configuration)
                    .matches(condition)
            }
        }.last?.provenance
    }
}
