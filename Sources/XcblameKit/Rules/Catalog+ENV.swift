import Foundation

// Environment and Xcode preferences (RULES.md §7): the rows as Swift literals (columns verbatim from docs/RULES.md) and their predicates.
extension RuleCatalog {
    static let envRules: [Rule] = [
        Rule(spec: RuleSpec(
            id: "ENV-001", name: "show-build-duration-and-timing", category: .env, detection: .static,
            signal: "`ShowBuildOperationDuration` unset.",
            fix: "`defaults write com.apple.dt.Xcode ShowBuildOperationDuration -bool YES`.",
            applyKinds: [.defaults], verifyOnly: false,
            impactContext: "Diagnostic",
            risk: "None.",
            configurations: .both, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] F1"],
            conflicts: [], signalKeyTemplate: "xcode-defaults:ShowBuildOperationDuration",
            summary: "Xcode does not show the build duration in the activity view. Turn it on to notice slow builds.",
            severity: .info), evaluate: ENVChecks.showBuildDuration),
        Rule(spec: RuleSpec(
            id: "ENV-002", name: "concurrent-compile-tasks", category: .env, detection: .both,
            signal: "`IDEBuildOperationMaxNumberOfConcurrentCompileTasks` < physical cores; D: peak lanes capped at that value while tasks wait.",
            fix: "Delete the key (default = cores) or set to `hw.ncpu`; lower if RAM-constrained.",
            applyKinds: [.defaults], verifyOnly: false,
            impactContext: "? (usually none above default, S42)",
            risk: "Memory pressure/swap in WMO/Release.",
            configurations: .both, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] F2", "https://developer.apple.com/forums/thread/80073"],
            conflicts: [], signalKeyTemplate: "xcode-defaults:IDEBuildOperationMaxNumberOfConcurrentCompileTasks",
            summary: "A cap on concurrent compile tasks below the core count leaves cores idle. Delete the key (default = cores) unless memory is constrained.",
            severity: .medium), evaluate: ENVChecks.concurrentTasks),
        Rule(spec: RuleSpec(
            id: "ENV-003", name: "ide-index-disable", category: .env, detection: .static,
            signal: "`IDEIndexDisable` set on a developer machine, or unset on a headless CI machine.",
            fix: "CI only.",
            applyKinds: [.recommend], verifyOnly: true,
            impactContext: "? needs measurement",
            risk: "Kills autocomplete.",
            configurations: .ci, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "K"),
            sources: ["[OC] F3"],
            conflicts: [], signalKeyTemplate: "xcode-defaults:IDEIndexDisable",
            summary: "Disabling indexing helps only headless CI machines; on a developer machine it kills autocomplete. Needs measurement.",
            severity: .low), evaluate: ENVChecks.indexDisable),
        Rule(spec: RuleSpec(
            id: "ENV-004", name: "deriveddata-location-and-exclusions", category: .env, detection: .static,
            signal: "`diskutil info` of the DerivedData volume: not internal or not solid state; DerivedData path is a symlink; `tmutil isexcluded <dd>` = false while a Time Machine destination exists (`tmutil destinationinfo`); free space < 10 % of the volume. Antivirus scanning has no detectable signal (docs-only note).",
            fix: "Local SSD; `tmutil addexclusion`; free space; AV exclusion (docs).",
            applyKinds: [.recommend], verifyOnly: true,
            impactContext: "? needs measurement",
            risk: "None.",
            configurations: .both, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "K"),
            sources: ["[OC] F4", "https://www.bitrise.io/blog/post/expert-tips-to-speed-up-your-ios-builds"],
            conflicts: [], signalKeyTemplate: "machine:derived-data",
            summary: "DerivedData on a slow, external, nearly full or Time Machine-backed volume slows every build. Needs measurement.",
            severity: .low), evaluate: ENVChecks.derivedDataLocation),
        Rule(spec: RuleSpec(
            id: "ENV-005", name: "rosetta-ram-thermal", category: .env, detection: .both,
            signal: "`sysctl.proc_translated = 1` (Rosetta); RAM ≤ 8 GB with swap during build; `pmset -g therm` warning before/after; Intel host.",
            fix: "Run Xcode natively; hardware; cooling/power.",
            applyKinds: [.recommend], verifyOnly: false,
            impactContext: "L when Rosetta: 15,800 s vs 505 s ([PP] A15); 8 GB Air outlier 506 s ([PP] §C)",
            risk: "None.",
            configurations: .both, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] F5", "[PP] A15", "[PP]"],
            conflicts: [], signalKeyTemplate: "machine:host",
            summary: "Xcode under Rosetta, too little RAM or thermal throttling slow every build regardless of project settings.",
            severity: .medium), evaluate: ENVChecks.rosettaRamThermal),
        Rule(spec: RuleSpec(
            id: "ENV-006", name: "xcode-version-known-issues", category: .env, detection: .static,
            signal: "Xcode version in a known-issue table: 26.x planning bugs (ENV-008), 27.0 emit-module re-run (DYN-005), 15.0.x LTO; several Xcode copies sharing DerivedData.",
            fix: "Upgrade within the toolchain; pin `xcode-select`; per-Xcode DerivedData on CI.",
            applyKinds: [.recommend], verifyOnly: true,
            impactContext: "?",
            risk: "Upgrades can regress ([PP] A5).",
            configurations: .both, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "S/K"),
            sources: ["[OC] F6", "[PP] A5"],
            conflicts: [], signalKeyTemplate: "xcode:<version>",
            summary: "Some Xcode versions have known build-time bugs; several Xcode copies sharing one DerivedData invalidate each other's caches.",
            severity: .low), evaluate: ENVChecks.knownIssues),
        Rule(spec: RuleSpec(
            id: "ENV-008", name: "planning-bugs-macro-plugins-26x", category: .env, detection: .both,
            signal: "Xcode 26.x with ≥ 2 macro plugins on one module, or \"Planning Swift module\" for many modules in incremental builds (DYN-003). Target of SRC-009's repaired ref.",
            fix: "Give plugins only to modules that use them; upgrade to Xcode 27.",
            applyKinds: [.recommend], verifyOnly: false,
            impactContext: "L in reported case: no-change build 127 s vs 15 s, 108/375 modules replanned (S22)",
            risk: "None.",
            configurations: .debug, xcode: "26.x", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] F8"],
            conflicts: ["DYN-003"], signalKeyTemplate: "macro-plugins:<module>",
            summary: "On Xcode 26.x a module that loads two or more macro plugins can re-plan on every incremental build. Give plugins only to the modules that use them, or move to Xcode 27.",
            severity: .medium), evaluate: ENVChecks.macroPluginPlanning),
    ]
}

/// ENV predicates: machine facts from `EnvSnapshot` plus read-only probes (`MachineProbe`: Xcode defaults, disk,
/// Time Machine). They run only when the context carries a machine snapshot (`doctor` always captures one).
enum ENVChecks {
    static func enabled(_ value: String?) -> Bool { ["1", "yes", "true"].contains((value ?? "").lowercased()) }

    static func defaultsItem(_ key: String, _ value: String?) -> ReportDocument.EvidenceItem {
        .init(kind: "env", ref: "defaults read com.apple.dt.Xcode \(key)", value: value ?? "unset")
    }

    /// ENV-001.
    static func showBuildDuration(_ s: RuleScan) -> Evaluation {
        guard !s.context.isCI else { return .notApplicable("CI machine: an Xcode UI preference") }
        let value = s.probe.xcodeDefault("ShowBuildOperationDuration")
        guard !enabled(value) else { return .passed("ShowBuildOperationDuration = YES") }
        return .hits([RuleHit(title: "Xcode does not show the build duration (ShowBuildOperationDuration "
                                + (value == nil ? "unset" : "= \(value!)") + "); turn it on",
                              evidence: [defaultsItem("ShowBuildOperationDuration", value),
                                         .init(kind: "env", ref: "fix",
                                               value: "defaults write com.apple.dt.Xcode ShowBuildOperationDuration -bool YES")],
                              apply: .defaults)])
    }

    /// Physical cores (performance + efficiency), else the logical count.
    static func cores(_ env: EnvSnapshot) -> Int? {
        if let p = env.performanceCores { return p + (env.efficiencyCores ?? 0) }
        return env.logicalCPUCount
    }

    /// ENV-002.
    static func concurrentTasks(_ s: RuleScan) -> Evaluation {
        guard let env = s.context.env, let cores = cores(env) else { return .notApplicable("core count unknown") }
        let key = "IDEBuildOperationMaxNumberOfConcurrentCompileTasks"
        let raw = s.probe.xcodeDefault(key)
        guard let cap = raw.flatMap({ Int($0) }) else { return .passed("\(key) unset (default = cores)") }
        guard cap < cores else { return .passed("\(key) = \(cap), not below \(cores) cores") }
        var evidence = [defaultsItem(key, raw), .init(kind: "env", ref: "cores", value: "\(cores)")]
        if let peak = s.context.document?.timing.peakLanes, peak <= cap {
            evidence.append(.init(kind: "report", ref: "peak lanes", value: "\(peak) in this build, capped at \(cap)"))
        }
        return .hits([RuleHit(title: "\(key) = \(cap) caps compile tasks below the \(cores) cores; delete the key "
                                + "(default = cores) unless memory is constrained",
                              evidence: evidence, apply: .defaults)])
    }

    /// ENV-003.
    static func indexDisable(_ s: RuleScan) -> Evaluation {
        let value = s.probe.xcodeDefault("IDEIndexDisable")
        let disabled = enabled(value)
        if disabled && !s.context.isCI {
            return .hits([RuleHit(title: "IDEIndexDisable is set on a developer machine: indexing off kills autocomplete; "
                                    + "use it on headless CI machines only",
                                  evidence: [defaultsItem("IDEIndexDisable", value)], apply: .recommend)])
        }
        if !disabled && s.context.isCI {
            return .hits([RuleHit(title: "headless CI machine indexes in Xcode (IDEIndexDisable unset); consider disabling it "
                                    + "there", evidence: [defaultsItem("IDEIndexDisable", value),
                                                         .init(kind: "env", ref: "CI", value: s.context.env?.ciProvider ?? "ci")],
                                  apply: .recommend)])
        }
        return .passed(s.context.isCI ? "CI: IDEIndexDisable set" : "indexing on (developer machine)")
    }

    /// ENV-004 (antivirus scanning has no detectable signal; docs only).
    static func derivedDataLocation(_ s: RuleScan) -> Evaluation {
        let path = s.probe.derivedDataPath()
        var evidence: [ReportDocument.EvidenceItem] = []
        if s.probe.isSymlink(path) { evidence.append(.init(kind: "file", ref: path, value: "is a symbolic link")) }
        if let free = s.probe.freeShare(path), free < 0.10 {
            evidence.append(.init(kind: "file", ref: path, value: "volume \(Int((free * 100).rounded())) % free"))
        }
        if let info = s.probe.run(["diskutil", "info", path]) {
            if RuleScan.matches(info, #"Solid State:\s+No"#) { evidence.append(.init(kind: "env", ref: "diskutil info", value: "not solid state")) }
            if RuleScan.matches(info, #"Device Location:\s+External"#) {
                evidence.append(.init(kind: "env", ref: "diskutil info", value: "external volume"))
            }
        }
        if let destinations = s.probe.run(["tmutil", "destinationinfo"]), !destinations.contains("No destinations"),
           let excluded = s.probe.run(["tmutil", "isexcluded", path]), excluded.contains("[Included]") {
            evidence.append(.init(kind: "env", ref: "tmutil isexcluded", value: "not excluded from Time Machine"))
        }
        guard !evidence.isEmpty else { return .passed("DerivedData on a local SSD with free space, not backed up") }
        let backedUp = evidence.contains { $0.ref == "tmutil isexcluded" }
        return .hits([RuleHit(title: "DerivedData (\(path)) " + evidence.map { $0.value ?? "" }.joined(separator: ", ")
                                + (backedUp ? "; run tmutil addexclusion on it" : ""),
                              evidence: evidence, apply: .recommend)])
    }

    /// ENV-005.
    static func rosettaRamThermal(_ s: RuleScan) -> Evaluation {
        guard let env = s.context.env else { return .notApplicable("no machine snapshot") }
        var evidence: [ReportDocument.EvidenceItem] = []
        var severity: RuleSpec.Severity?
        if env.processTranslated == true {
            evidence.append(.init(kind: "env", ref: "sysctl.proc_translated", value: "1 (running under Rosetta)"))
            severity = .high
        }
        if let memory = env.memoryBytes, memory <= 8 << 30 {
            evidence.append(.init(kind: "env", ref: "hw.memsize", value: "\(memory >> 30) GB"))
        }
        if s.probe.run(["sysctl", "-n", "hw.optional.arm64"]) == "0" {
            evidence.append(.init(kind: "env", ref: "hw.optional.arm64", value: "0 (Intel host)"))
        }
        if let therm = ThermalProbe.capture(probe: s.probe.run), let limit = ThermalProbe.cpuSpeedLimit(in: therm), limit < 100 {
            evidence.append(.init(kind: "env", ref: "pmset -g therm", value: "CPU_Speed_Limit \(limit) %"))
        }
        guard !evidence.isEmpty else {
            var facts: [String] = []
            if env.processTranslated == false { facts.append("native") }
            if let memory = env.memoryBytes { facts.append("\(memory >> 30) GB") }
            return .passed(facts.isEmpty ? "no Rosetta, RAM or thermal signal" : facts.joined(separator: ", ") + ", no thermal limit")
        }
        return .hits([RuleHit(title: "build host: " + evidence.map { $0.value ?? "" }.joined(separator: ", ")
                                + "; run Xcode natively on enough RAM, keep the machine cool",
                              evidence: evidence, apply: .recommend, severity: severity)])
    }

    /// ENV-006.
    static func knownIssues(_ s: RuleScan) -> Evaluation {
        var evidence: [ReportDocument.EvidenceItem] = []
        let selected = s.context.xcode ?? "unknown"
        if let version = s.xcodeVersion {
            if version.first == 15, version.count < 2 || version[1] == 0 {
                evidence.append(.init(kind: "env", ref: "Xcode \(selected)", value: "15.0.x LTO and branch-fixup linker bugs; upgrade within 15"))
            }
            if version.first == 27, version.count < 2 || version[1] == 0 {
                evidence.append(.init(kind: "env", ref: "Xcode \(selected)",
                                      value: "27.0 re-runs SwiftEmitModule after body-only edits (swift-driver#2214)"))
            }
            if version.first == 26 {
                let macros = Set(DEPChecks.macroTargets(s))
                for (_, manifest) in s.manifests {
                    for target in manifest.targets where target.dependencies.filter(macros.contains).count >= 2 {
                        evidence.append(.init(kind: "package", ref: target.name,
                                              value: "2+ macro plugins on one module: Xcode 26.x planning bug (ENV-008)"))
                    }
                }
            }
        }
        let copies = s.probe.xcodeApps()
        if copies.count > 1, s.probe.xcodeDefault("IDECustomDerivedDataLocation") == nil {
            evidence.append(.init(kind: "env", ref: "/Applications", value: "\(copies.count) Xcode copies (\(copies.joined(separator: ", "))) "
                + "share one DerivedData"))
        }
        guard !evidence.isEmpty else { return .passed("Xcode \(selected): no known build-time issue in the table") }
        return .hits([RuleHit(title: "Xcode \(selected): " + evidence.map { $0.value ?? "" }.joined(separator: "; "),
                              evidence: evidence, apply: .recommend, keys: ["version": selected])])
    }

    /// ENV-008 (static part): on Xcode 26.x (gated by the catalog) a module — a local package target or a project
    /// target — that loads two or more macro plugins. A macro provider is a macro target, or a target or product of
    /// any package (local manifests, remote checkouts when they exist) that depends on one; a remote package whose
    /// manifest cannot be read makes the result unknown (N/A), never a pass. The DYN-003 replanning signal needs a build.
    static func macroPluginPlanning(_ s: RuleScan) -> Evaluation {
        guard let project = s.project else { return .notApplicable("no project read") }
        guard !s.manifests.isEmpty || !s.remotePackages.isEmpty else { return .notApplicable("no Swift packages") }
        var providers: Set<String> = []
        func addProviders(_ manifest: ProjectModel.PackageManifest, products: [String]) {
            var macroish = Set(manifest.targets.filter { $0.type == "macro" }.map(\.name))
            var changed = true
            while changed {  // targets that depend (transitively) on a macro target load its plugin
                changed = false
                for target in manifest.targets where !macroish.contains(target.name) && target.dependencies.contains(where: macroish.contains) {
                    macroish.insert(target.name)
                    changed = true
                }
            }
            providers.formUnion(macroish.filter { name in manifest.targets.first { $0.name == name }?.type != "macro" })
            providers.formUnion(products.filter(macroish.contains))
        }
        for (_, manifest) in s.manifests { addProviders(manifest, products: []) }
        // Remote packages: their manifests in the checkouts the project (or the oracle cache) already has.
        var checkoutRoots: [URL] = []
        if let own = XcodebuildSettings.sourcePackages(project) { checkoutRoots.append(own.appendingPathComponent("checkouts")) }
        checkoutRoots.append(OracleCache.directory(for: project.container.url, home: OracleCache.home())
            .appendingPathComponent("SourcePackages/checkouts"))
        var unread: [String] = []
        for package in s.remotePackages {
            guard let url = package.url else { continue }
            let name = (RuleScan.normalized(url) as NSString).lastPathComponent
            guard let manifest = checkoutRoots.lazy.map({ $0.appendingPathComponent(name + "/Package.swift") })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
                  let parsed = try? ManifestReaders.package(manifest: manifest) else {
                unread.append(name)
                continue
            }
            addProviders(parsed.manifest, products: parsed.products)
        }

        var modules: [(name: String, ref: String, used: [String])] = []
        for (package, manifest) in s.manifests {
            for target in manifest.targets where target.type != "macro" {
                let used = s.distinct(target.dependencies.filter { providers.contains($0) || isMacro($0, manifest) })
                if used.count >= 2 { modules.append((target.name, package.path.map { s.displayPath($0.path) } ?? (manifest.name ?? "package"), used)) }
            }
        }
        for target in project.allTargets {
            let used = s.distinct(target.packageProducts.filter(providers.contains))
            if used.count >= 2 { modules.append((target.name, "project target \(target.name)", used)) }
        }
        guard modules.isEmpty else {
            return .hits(modules.map { module in
                RuleHit(title: "\(module.name) loads \(module.used.count) macro plugins (\(module.used.joined(separator: ", "))) on "
                            + "Xcode 26.x, which can re-plan it on every incremental build; give plugins only to "
                            + "the modules that use them",
                        evidence: [.init(kind: "file", ref: module.ref, value: "\(module.name) depends on macros "
                            + module.used.joined(separator: ", "))],
                        apply: .recommend, keys: ["module": module.name])
            })
        }
        if !unread.isEmpty {
            return .notApplicable("macro products of remote packages unknown (no checkout manifest for "
                + s.targetsText(unread) + ")")
        }
        return .passed("no module with two or more macro plugins")
    }

    static func isMacro(_ name: String, _ manifest: ProjectModel.PackageManifest) -> Bool {
        manifest.targets.contains { $0.name == name && $0.type == "macro" }
    }
}
