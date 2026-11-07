import Foundation

/// Read-only helpers the predicates share over one `RuleContext`: configurations by role, effective values,
/// provenance, script phases, manifests and dependency files. One scan per engine run caches what several rules
/// read. Nothing here writes; files are only read (Podfile, Package.resolved, .rcinfo).
final class RuleScan {
    let context: RuleContext
    let probe: MachineProbe
    /// Provenance lookups nothing could answer (no project model).
    private(set) var unknownProvenance = 0

    init(_ context: RuleContext, probe: MachineProbe = .current) {
        self.context = context
        self.probe = probe
    }

    var project: ProjectModel? { context.project }

    // MARK: - Configurations and effective values

    /// Configurations with effective settings, in project order, then any others the oracle returned.
    lazy var configurationNames: [String] = {
        let known = context.project?.configurationNames ?? []
        let rest = context.settings.keys.filter { !known.contains($0) }.sorted()
        return known.filter { context.settings[$0] != nil } + rest
    }()

    /// Role by the first app target's effective values (RULES.md §0), else any project target's, else the name.
    func role(_ configuration: String) -> ConfigurationRole {
        let targets = context.settings[configuration]?.targets ?? [:]
        let all = project?.allTargets ?? []
        let ordered = all.filter { $0.productType.hasSuffix(".application") }
            + all.filter { !$0.productType.hasSuffix(".application") }
        let effective = ordered.lazy.compactMap { targets[$0.name] }.first
            ?? targets.keys.sorted().first.flatMap { targets[$0] } ?? [:]
        return ConfigurationRole.role(name: configuration, effective: effective)
    }

    func configurations(_ which: RuleSpec.Configurations) -> [String] {
        switch which {
        case .debug: return configurationNames.filter { role($0) == .debugLike }
        case .release: return configurationNames.filter { role($0) == .releaseLike }
        case .both, .ci: return configurationNames
        }
    }

    /// Why a configuration-scoped rule has nothing to check.
    func noConfigurationReason(_ which: RuleSpec.Configurations) -> String {
        if context.settings.isEmpty { return "no effective settings were read" }
        let role = which == .release ? "Release" : "Debug"
        return "no \(role)-like configuration among \(configurationNames.joined(separator: ", "))"
    }

    /// Project targets (not aggregates) the oracle listed for `configuration`. Package targets are left out: the
    /// overlay hook does not reach them and SwiftPM picks their settings.
    func targets(in configuration: String, _ include: (ProjectModel.Target) -> Bool = { _ in true })
        -> [ProjectModel.Target] {
        guard let effective = context.settings[configuration] else { return [] }
        return (project?.allTargets ?? []).filter {
            !$0.productType.isEmpty && effective.targets[$0.name] != nil && include($0)
        }
    }

    func value(_ target: String, _ key: String, _ configuration: String) -> String? {
        context.settings[configuration]?.targets[target]?[key]?.trimmingCharacters(in: .whitespaces)
    }

    /// Whitespace-separated words of a list value, quotes dropped (xcodebuild keeps a leading space where
    /// `$(inherited)` was empty, so raw strings are never compared).
    static func words(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }.filter { !$0.isEmpty }
    }

    func words(_ target: String, _ key: String, _ configuration: String) -> [String] {
        Self.words(value(target, key, configuration))
    }

    /// True when any evaluated configuration came from the offline resolver (or `--offline`): confidence drops one
    /// step (DESIGN §7.4).
    var offlineSource: Bool {
        context.offline || context.settings.values.contains { $0.source == .offlineResolver }
    }

    // MARK: - Build tasks

    struct BuildTaskRow {
        var rule: String
        var kind: TaskKind
        var title: String
        /// `commandDetails` (empty when the log has none).
        var command: String
        var seconds: Double
    }

    /// The analyzed build's tasks: `RuleContext.tasks` (every timed task), else the report's top tasks (no command
    /// lines; synthetic contexts).
    lazy var buildTasks: [BuildTaskRow] = context.tasks.isEmpty
        ? (context.analysis?.topTasks ?? []).map {
            BuildTaskRow(rule: $0.ruleName, kind: $0.kind, title: $0.title, command: "", seconds: $0.seconds)
        }
        : context.tasks.map {
            BuildTaskRow(rule: $0.task.ruleName, kind: $0.task.kind, title: $0.task.title,
                         command: $0.task.commandDetails ?? "", seconds: $0.seconds)
        }

    // MARK: - Provenance

    /// An injected `RuleContext.provenance` answer when it knows the level, else `SettingsOracle.provenance` over the
    /// project with the target's effective values (conditional keys match the real SDK and archs). Without a project
    /// nothing can answer: `unknown`, counted for the engine's note.
    func provenance(_ target: String, _ key: String, _ configuration: String) -> Provenance {
        let injected = context.provenance(target, key, configuration)
        if injected.level != .unknown { return injected }
        guard let project else {
            unknownProvenance += 1
            return injected
        }
        return SettingsOracle.provenance(project: project, target: target, key: key, configuration: configuration,
                                         commandLineOverrides: [:],
                                         effective: context.settings[configuration]?.targets[target])
    }

    /// The assignment above the project-level base xcconfig (where the hook includes the overlay, DESIGN §7.5) that
    /// sets `key` without `$(inherited)`, so an overlay line cannot win; nil when nothing shadows it. An injected
    /// provenance decides by its own level; otherwise `SettingsOracle.isShadowed`.
    func shadowing(_ target: String, _ key: String, _ configuration: String) -> Provenance? {
        let injected = context.provenance(target, key, configuration)
        if injected.level != .unknown {
            return FindingBuilder.shadowingLevels.contains(injected.level) && !injected.inherited ? injected : nil
        }
        guard let project else {
            unknownProvenance += 1
            return nil
        }
        return SettingsOracle.isShadowed(project: project, target: target, key: key, configuration: configuration,
                                         byLevelAbove: .projectXCConfig)
    }

    /// The value the project files resolve `key` to (xcconfig chains and `$(inherited)` included), ignoring what
    /// xcodebuild's destination forces. Nil when nothing writes it.
    func writtenValue(_ target: String, _ key: String, _ configuration: String) -> String? {
        guard let project else { return nil }
        let resolved = writtenSettings[configuration, default: OfflineResolver.resolve(project: project,
                                                                                       configuration: configuration)]
        writtenSettings[configuration] = resolved
        return resolved.targets[target]?[key]?.trimmingCharacters(in: .whitespaces)
    }

    private var writtenSettings: [String: EffectiveSettings] = [:]

    /// `target settings (AcmeApp.xcodeproj)`, `project xcconfig (Config/Debug.xcconfig)`; nil when unknown.
    func label(_ provenance: Provenance) -> String? {
        let names: [Provenance.Level: String] = [
            .platformDefault: "platform default", .projectXCConfig: "project xcconfig",
            .projectSettings: "project settings", .targetXCConfig: "target xcconfig",
            .targetSettings: "target settings", .commandLine: "command line",
        ]
        guard let name = names[provenance.level] else { return nil }
        guard let file = provenance.file else { return name }
        return name + " (" + displayPath(file) + ")"
    }

    /// A `project.pbxproj` shows as its `.xcodeproj`; other files relative to the project root (the container's folder).
    func displayPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if url.lastPathComponent == "project.pbxproj" { return url.deletingLastPathComponent().lastPathComponent }
        // Provenance files are already relative to the project root (`Config/target.xcconfig`): keep them so.
        if !path.hasPrefix("/") { return path }
        let root = (project?.root.standardizedFileURL.path ?? "") + "/"
        return url.standardizedFileURL.path.hasPrefix(root) && root != "/"
            ? String(url.standardizedFileURL.path.dropFirst(root.count)) : url.lastPathComponent
    }

    // MARK: - Setting audits

    struct SettingEntry {
        var target: String
        var configuration: String
        var value: String?
        /// How an unset value is shown when the platform default stood in (`unset (platform default s)`).
        var display: String?
    }

    struct SettingAudit {
        var key: String
        var configurations: [String]
        var bad: [SettingEntry] = []
        /// Configuration → distinct values seen on targets that passed (`unset` for a missing key).
        var good: [String: [String]] = [:]
        var checkedTargets = 0
        /// Targets whose value is unknown: unset in offline settings, where only the platform default could decide.
        var unknown: [SettingEntry] = []
    }

    /// xcspec defaults for keys a rule judges, used when xcodebuild prints no value (an unset key). Offline, an unset
    /// key stays unknown instead (DESIGN §7.4: the offline resolver has no defaults).
    static let platformDefaults: [String: String] = [
        "GCC_OPTIMIZATION_LEVEL": "s", "ONLY_ACTIVE_ARCH": "NO", "COPY_PHASE_STRIP": "YES",
        "SWIFT_OPTIMIZATION_LEVEL": "-O", "DEPLOYMENT_POSTPROCESSING": "NO", "VALIDATE_PRODUCT": "NO",
    ]

    func isOffline(_ configuration: String) -> Bool {
        context.offline || context.settings[configuration]?.source == .offlineResolver
    }

    /// Checks `key` on every included target of `configurations`. An unset key is never a silent pass: with
    /// xcodebuild's settings the platform default stands in (`platformDefaults`); offline it is unknown unless unset
    /// already counts as bad.
    func audit(_ key: String, _ configurations: [String], targets include: (ProjectModel.Target) -> Bool = { _ in true },
               read: ((String, String, String) -> String?)? = nil, bad isBad: (String?) -> Bool) -> SettingAudit {
        var audit = SettingAudit(key: key, configurations: configurations)
        for configuration in configurations {
            for target in targets(in: configuration, include) {
                audit.checkedTargets += 1
                var value = read?(target.name, key, configuration) ?? self.value(target.name, key, configuration)
                var display: String?
                if value == nil {
                    if isOffline(configuration) {
                        if !isBad(nil) {
                            audit.unknown.append(SettingEntry(target: target.name, configuration: configuration, value: nil))
                            continue
                        }
                    } else if let fallback = Self.platformDefaults[key] {
                        value = fallback
                        display = "unset (platform default \(fallback))"
                    }
                }
                if isBad(value) {
                    audit.bad.append(SettingEntry(target: target.name, configuration: configuration, value: value,
                                                  display: display))
                } else {
                    let shown = display ?? value.map { $0.isEmpty ? "empty" : $0 } ?? "unset"
                    if !(audit.good[configuration] ?? []).contains(shown) { audit.good[configuration, default: []].append(shown) }
                }
            }
        }
        return audit
    }

    /// `Debug: singlefile, Release: wholemodule` from an audit's passing values.
    func passDetail(_ audit: SettingAudit, label: String? = nil) -> String {
        audit.configurations.compactMap { configuration in
            audit.good[configuration].map { "\(configuration): " + (label.map { $0 + " " } ?? "") + $0.joined(separator: "/") }
        }.joined(separator: ", ")
    }

    /// Bad entries grouped by configuration, value and provenance into setting evidence items.
    func evidence(_ audit: SettingAudit, key: String? = nil) -> [ReportDocument.EvidenceItem] {
        let key = key ?? audit.key
        var groups: [(configuration: String, value: String?, provenance: String?, targets: [String])] = []
        for entry in audit.bad {
            let provenance = label(self.provenance(entry.target, key, entry.configuration))
            let value = entry.display ?? entry.value
            if let index = groups.firstIndex(where: {
                $0.configuration == entry.configuration && $0.value == value && $0.provenance == provenance
            }) {
                groups[index].targets.append(entry.target)
            } else {
                groups.append((entry.configuration, value, provenance, [entry.target]))
            }
        }
        return groups.map {
            ReportDocument.EvidenceItem(kind: "setting", ref: $0.targets.joined(separator: "+") + ":\($0.configuration):\(key)",
                                        value: $0.value ?? "unset", provenance: $0.provenance)
        }
    }

    /// One hit for a failed audit, or passed / not applicable.
    func settingEvaluation(_ audit: SettingAudit, which: RuleSpec.Configurations, apply: RuleSpec.ApplyKind,
                           overlay: [(key: String, value: String)], fix: String,
                           passLabel: String? = nil, passed: String? = nil,
                           noTargets: String = "no project targets with effective settings",
                           adjust: (inout RuleHit) -> Void = { _ in }) -> Evaluation {
        guard !audit.configurations.isEmpty else { return .notApplicable(noConfigurationReason(which)) }
        guard audit.checkedTargets > 0 else { return .notApplicable(noTargets) }
        if audit.bad.isEmpty, let reason = unknownReason(audit) { return .notApplicable(reason) }
        guard !audit.bad.isEmpty else {
            return .passed(passed.map { audit.configurations.joined(separator: "/") + ": " + $0 }
                ?? passDetail(audit, label: passLabel))
        }
        var hit = RuleHit(title: settingTitle(audit) + fix, evidence: evidence(audit), targets: distinct(audit.bad.map(\.target)),
                          configurations: distinct(audit.bad.map(\.configuration)), apply: apply, overlay: overlay)
        adjust(&hit)
        return .hits([hit])
    }

    /// Why an audit with no bad value is not a pass: some targets' values are unknown offline.
    func unknownReason(_ audit: SettingAudit) -> String? {
        guard !audit.unknown.isEmpty else { return nil }
        return "\(audit.key) unknown (offline) for \(targetsText(distinct(audit.unknown.map(\.target)))): unset in the "
            + "project files, so the platform default decides (run without --offline)"
    }

    /// `SWIFT_COMPILATION_MODE = wholemodule in Debug for Acme, AcmeKit`.
    func settingTitle(_ audit: SettingAudit) -> String {
        let values = distinct(audit.bad.map { $0.display ?? $0.value.map { $0.isEmpty ? "empty" : $0 } ?? "unset" })
        return "\(audit.key) = \(values.joined(separator: "/")) in \(distinct(audit.bad.map(\.configuration)).joined(separator: "/"))"
            + " for " + targetsText(distinct(audit.bad.map(\.target)))
    }

    func targetsText(_ names: [String]) -> String {
        names.count <= 3 ? names.joined(separator: ", ") : "\(names.count) targets"
    }

    func distinct(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - Phases, packages, dependency files

    typealias ScriptPhase = (target: ProjectModel.Target, project: ProjectModel.Project, phase: ProjectModel.ShellScriptPhase)

    lazy var scriptPhases: [ScriptPhase] = (project?.projects ?? []).flatMap { project in
        project.targets.flatMap { target in
            target.phases.compactMap { phase -> ScriptPhase? in
                if case let .shellScript(script) = phase { return (target, project, script) }
                return nil
            }
        }
    }

    /// CocoaPods-generated phases (`[CP] …`) belong to PHASE-007, not to the per-phase rules.
    static func isCocoaPods(_ phase: ProjectModel.ShellScriptPhase) -> Bool { phase.name.hasPrefix("[CP]") }

    /// Script text without comment lines.
    static func code(_ script: String) -> String {
        script.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    func phaseEvidence(_ item: ScriptPhase, _ value: String) -> ReportDocument.EvidenceItem {
        ReportDocument.EvidenceItem(kind: "phase", ref: "\(item.target.name) › \(item.phase.name) (\(item.phase.id))", value: value)
    }

    /// Local packages (and a `.package` container) with a parsed manifest.
    lazy var manifests: [(package: ProjectModel.PackageReference, manifest: ProjectModel.PackageManifest)] =
        (project?.packages ?? []).compactMap { reference in reference.manifest.map { (reference, $0) } }

    /// Remote package references of the project and of local manifests, first occurrence per URL.
    lazy var remotePackages: [ProjectModel.PackageReference] = {
        var seen: Set<String> = []
        let all = (project?.packages ?? []) + manifests.flatMap(\.manifest.dependencies)
        return all.filter { reference in
            guard reference.requirement != .local, let url = reference.url else { return false }
            return seen.insert(Self.normalized(url)).inserted
        }
    }()

    /// `https://github.com/apple/swift-syntax.git` → `github.com/apple/swift-syntax`.
    static func normalized(_ url: String) -> String {
        var text = url.lowercased()
        for prefix in ["https://", "http://", "ssh://", "git@"] where text.hasPrefix(prefix) { text.removeFirst(prefix.count) }
        if text.hasSuffix(".git") { text.removeLast(4) }
        if text.hasSuffix("/") { text.removeLast() }
        return text.replacingOccurrences(of: ":", with: "/")
    }

    lazy var podfile: (url: URL, text: String)? = {
        for manager in project?.dependencyManagers ?? [] {
            if case let .cocoapods(podfile, _, _) = manager {
                return (podfile, (try? String(contentsOf: podfile, encoding: .utf8)) ?? "")
            }
        }
        return nil
    }()

    var cocoapods: (podfile: URL, lockfile: URL?, podCount: Int?)? {
        for manager in project?.dependencyManagers ?? [] {
            if case let .cocoapods(podfile, lockfile, count) = manager { return (podfile, lockfile, count) }
        }
        return nil
    }

    var cartfile: URL? {
        for manager in project?.dependencyManagers ?? [] {
            if case let .carthage(cartfile) = manager { return cartfile }
        }
        return nil
    }

    /// Podfile facts from Lane A's reader (SET-006, SET-010, SET-027 read `post_install`).
    lazy var podfileFacts: (url: URL, facts: PodfileFacts)? = context.podfileFacts

    /// `post_install` `build_settings` assignments whose key is `key` or `key[condition]`.
    func postInstallSettings(_ key: String) -> [(key: String, value: String)] {
        (podfileFacts?.facts.postInstallSettings ?? [:]).filter { $0.key == key || $0.key.hasPrefix(key + "[") }
            .sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Podfile lines that are not comments.
    var podfileCode: String { podfile.map { Self.code($0.text) } ?? "" }

    // MARK: - Xcode version

    /// `26.0.1` → [26, 0, 1]; nil when unknown.
    static func version(_ text: String?) -> [Int]? {
        guard let text else { return nil }
        let numbers = text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) }
        guard let major = numbers.first ?? nil else { return nil }
        return [major] + numbers.dropFirst().map { $0 ?? 0 }
    }

    static func compare(_ lhs: [Int], _ rhs: [Int]) -> Int {
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    var xcodeVersion: [Int]? { Self.version(context.xcode) }

    /// True when the selected Xcode is at least `minimum`; nil when unknown.
    func xcodeAtLeast(_ minimum: String) -> Bool? {
        guard let version = xcodeVersion, let floor = Self.version(minimum) else { return nil }
        return Self.compare(version, floor) >= 0
    }
}
