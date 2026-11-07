import Foundation

// Dependencies (RULES.md §6): the rows as Swift literals (columns verbatim from docs/RULES.md) and their predicates.
extension RuleCatalog {
    static let depRules: [Rule] = [
        Rule(spec: RuleSpec(
            id: "DEP-001", name: "spm-pin-versions-not-branches", category: .dep, detection: .static,
            signal: "`XCRemoteSwiftPackageReference` `kind = branch`, or `.package(url:, branch:)`.",
            fix: "Pin version/revision (from `Package.resolved`).",
            applyKinds: [.manifest, .pbxproj], verifyOnly: false,
            impactContext: "? (network checks on fresh resolves)",
            risk: "Loses auto-updates.",
            configurations: .both, xcode: "11+", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] E1"],
            conflicts: [], signalKeyTemplate: "package:<url>",
            summary: "A Swift package pinned to a branch makes every fresh resolve hit the network and pulls unreviewed changes. Pin a version or a revision.",
            severity: .medium), evaluate: DEPChecks.branchPins),
        Rule(spec: RuleSpec(
            id: "DEP-002", name: "spm-resolution-cost", category: .dep, detection: .both,
            signal: "D: `Logs/Package` resolve duration and out-of-log time (DYN-004); S: `Package.resolved` not in VCS.",
            fix: "Commit `Package.resolved`; CI cache via CI-002; resolve only from the resolved file (`-onlyUsePackageVersionsFromResolvedFile`, spelling MV-14).",
            applyKinds: [.recommend, .cli], verifyOnly: false,
            impactContext: "Measured; context Azure CI resolution 2m52s (16.1) vs 7m31s (26.0) ([PP] A5)",
            risk: "Stale pins.",
            configurations: .both, xcode: "11+", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] E2", "[PP] A5"],
            conflicts: [], signalKeyTemplate: "package-resolved:<container>",
            summary: "Without a committed Package.resolved every machine and CI run resolves package versions again. Commit it and resolve only from it on CI.",
            severity: .low), evaluate: DEPChecks.packageResolved),
        Rule(spec: RuleSpec(
            id: "DEP-003", name: "heavy-deps-as-binaries", category: .dep, detection: .both,
            signal: "Source deps known heavy (Firebase, Realm, grpc, abseil) with owner task time > 20 % of a clean build; package offers `.binaryTarget`.",
            fix: "Vendor binary distribution or in-house XCFrameworks.",
            applyKinds: [.recommend], verifyOnly: true,
            impactContext: "?",
            risk: "ABI/version compat; debugging; supply chain.",
            configurations: .both, xcode: "11+", evidenceTag: RuleSpec.EvidenceTag(text: "S/K"),
            sources: ["[OC] E3"],
            conflicts: ["DEP-012"], signalKeyTemplate: "heavy-dependency:<name>",
            summary: "Known heavy dependencies (Firebase, Realm, gRPC, abseil) compiled from source dominate clean builds. Prefer their binary distributions; needs measurement.",
            severity: .low), evaluate: DEPChecks.heavyDeps),
        Rule(spec: RuleSpec(
            id: "DEP-004", name: "cocoapods-precompiled", category: .dep, detection: .both,
            signal: "Podfile with > 20 pods; clean build dominated by Pods targets.",
            fix: "Rugby / cocoapods-binary-cache / PodBuilder.",
            applyKinds: [.recommend], verifyOnly: false,
            impactContext: "~10 % on a project with ~15 % pod code (S29)",
            risk: "`@import` required; Xcode UI test issues.",
            configurations: .both, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] E4"],
            conflicts: ["DEP-005"], signalKeyTemplate: "cocoapods:precompile",
            summary: "More than 20 pods compiled from source on every clean build. Precompile them (Rugby, cocoapods-binary-cache, PodBuilder) when Pods targets dominate clean builds.",
            severity: .low), evaluate: DEPChecks.cocoapodsPrecompiled),
        Rule(spec: RuleSpec(
            id: "DEP-005", name: "cocoapods-to-spm", category: .dep, detection: .static,
            signal: "Podfile/Podfile.lock present.",
            fix: "Migrate pod by pod.",
            applyKinds: [.recommend], verifyOnly: false,
            impactContext: "? (long-term; caching/explicit modules, S1)",
            risk: "Migration effort.",
            configurations: .both, xcode: "11+", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] E5", "https://raw.githubusercontent.com/AvdLee/Xcode-Build-Optimization-Agent-Skill/main/OPTIMIZATION-CHECKS.md"],
            conflicts: ["PHASE-007"], signalKeyTemplate: "cocoapods:migrate",
            summary: "CocoaPods-managed dependencies miss Swift package caching and explicit-module improvements. Migrate pod by pod to Swift packages.",
            severity: .low), evaluate: DEPChecks.cocoapodsToSPM),
        Rule(spec: RuleSpec(
            id: "DEP-006", name: "carthage-prebuilt-cache", category: .dep, detection: .static,
            signal: "Cartfile, `Carthage/Build`.",
            fix: "Cache keyed on `Cartfile.resolved`; `--use-xcframeworks`.",
            applyKinds: [.recommend], verifyOnly: false,
            impactContext: "Context: 15-20 min local Carthage builds at LINE (S27)",
            risk: "Cache invalidation.",
            configurations: .ci, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] E6", "https://engineering.linecorp.com/en/blog/improving-build-performance-line-ios-bazel/"],
            conflicts: [], signalKeyTemplate: "carthage:cache",
            summary: "Carthage builds dependencies from source unless cached. Cache Carthage/Build keyed on Cartfile.resolved and use --use-xcframeworks.",
            severity: .low), evaluate: DEPChecks.carthageCache),
        Rule(spec: RuleSpec(
            id: "DEP-007", name: "tuist-module-or-xcode-cache", category: .dep, detection: .static,
            signal: "`Project.swift`/`Tuist/` present, or Xcode 26 with CI cold builds.",
            fix: "`tuist cache` / `tuist setup cache`.",
            applyKinds: [.recommend], verifyOnly: false,
            impactContext: "See SET-016/017 (vendor, S17)",
            risk: "Vendor dependency.",
            configurations: .both, xcode: "26+ for Xcode cache", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] E7", "https://tuist.dev/blog/2025/10/22/xcode-cache"],
            conflicts: [], signalKeyTemplate: "tuist:cache",
            summary: "Tuist projects can cache modules or the Xcode compilation cache (tuist cache, tuist setup cache).",
            severity: .low), evaluate: DEPChecks.tuistCache),
        Rule(spec: RuleSpec(
            id: "DEP-008", name: "swift-syntax-prebuilts-for-macros", category: .dep, detection: .static,
            signal: "Macro targets present and swift-syntax referenced as `apple/swift-syntax` (blocks prebuilts); Xcode 16.4 without `IDEPackageEnablePrebuilts`; Xcode 26: automatic.",
            fix: "URL to `https://github.com/swiftlang/swift-syntax`; 16.4: set default.",
            applyKinds: [.manifest, .defaults], verifyOnly: false,
            impactContext: "M: emit-module penalty 40 to 16 s (S23); \"significantly improves clean build times\" (S24)",
            risk: "`_SwiftSyntaxCShims` failures (workaround `IDEPackageEnablePrebuilts NO`, S8); some setups still build from source.",
            configurations: .both, xcode: "16.4+", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] E8", "https://forums.swift.org/t/preview-swift-syntax-prebuilts-for-macros/80202", "https://swift.org/blog/swift-6.2-released/", "https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes"],
            conflicts: ["DEP-012"], signalKeyTemplate: "package:swift-syntax:prebuilts",
            summary: "Macro targets can use swift-syntax prebuilts instead of compiling swift-syntax from source, but only when swift-syntax is referenced by its swiftlang URL.",
            severity: .medium), evaluate: DEPChecks.swiftSyntaxPrebuilts),
        Rule(spec: RuleSpec(
            id: "DEP-010", name: "xcremotecache", category: .dep, detection: .static,
            signal: "XCRemoteCache in use: `.rcinfo` in the repo, or `CC`/`SWIFT_EXEC`/`LD` settings pointing at XCRemoteCache wrappers (`xccc`, `xcswiftc`, `xcld`).",
            fix: "Only if Xcode 26 caching is insufficient; note conflicts.",
            applyKinds: [.recommend], verifyOnly: false,
            impactContext: "? (no published numbers)",
            risk: "SPM unsupported; needs `SWIFT_USE_INTEGRATED_DRIVER=NO` (conflicts SET-015/016).",
            configurations: .ci, xcode: "11.4-14 era", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] E10"],
            conflicts: ["SET-015", "SET-016"], signalKeyTemplate: "xcremotecache",
            summary: "XCRemoteCache is in use. It needs SWIFT_USE_INTEGRATED_DRIVER = NO, which conflicts with Xcode 26 compilation caching; keep it only if Xcode caching is insufficient.",
            severity: .low), evaluate: DEPChecks.xcremotecache),
        Rule(spec: RuleSpec(
            id: "DEP-012", name: "heavy-library-package-from-source (new)", category: .dep, detection: .both,
            signal: "D: a remote package's tasks are ≥ 20 % of the clean-build critical path or ≥ 30 % of task time. S: swift-syntax products (`SwiftSyntax`, `SwiftParser`) used by a non-macro target (prebuilts cover macro targets only, S23). corpus app on Xcode 26: 54.5 s task time, ≤ 4.6 s on the path [OBS-6, OBS-14, OBS-11].",
            fix: "First: keep swift-syntax-dependent code in a stable leaf module so incremental builds skip it; second: a binary target (XCFramework) of the dependent module; caching (SET-016) only helps project targets while SPM package caching is unverified.",
            applyKinds: [.recommend], verifyOnly: false,
            impactContext: "Measured on clean builds: on-path seconds of the package's tasks (corpus app ≤ 4.6 s of 18.1 s)",
            risk: "Binary targets pin toolchain versions.",
            configurations: .both, xcode: "15+", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["https://forums.swift.org/t/preview-swift-syntax-prebuilts-for-macros/80202"],
            conflicts: ["DEP-008"], signalKeyTemplate: "package:swift-syntax:library:<targets>",
            summary: "swift-syntax used as a library by a non-macro target compiles from source on every clean build (prebuilts cover macro targets only). Keep swift-syntax code in a stable leaf module; consider a binary target.",
            severity: .medium), evaluate: DEPChecks.swiftSyntaxLibrary),
    ]
}

/// DEP predicates over package references, local manifests and the CocoaPods/Carthage files.
enum DEPChecks {
    typealias Package = ProjectModel.PackageReference

    static func name(_ url: String) -> String {
        RuleScan.normalized(url).split(separator: "/").last.map(String.init) ?? url
    }

    static func requirementText(_ requirement: Package.Requirement) -> String {
        switch requirement {
        case let .exact(version): return "exact \(version)"
        case let .upToNextMajor(version): return "from \(version)"
        case let .upToNextMinor(version): return "up to next minor \(version)"
        case let .range(from, to): return "\(from)..<\(to)"
        case let .branch(branch): return "branch \(branch)"
        case let .revision(revision): return "revision \(revision.prefix(12))"
        case .local: return "local"
        }
    }

    /// DEP-001.
    static func branchPins(_ s: RuleScan) -> Evaluation {
        let remote = s.remotePackages
        guard !remote.isEmpty else { return .notApplicable("no remote Swift packages") }
        let projectURLs = Set((s.project?.packages ?? []).compactMap(\.url).map(RuleScan.normalized))
        let hits = remote.compactMap { package -> RuleHit? in
            guard case let .branch(branch) = package.requirement, let url = package.url else { return nil }
            let inProject = projectURLs.contains(RuleScan.normalized(url))
            let consumers = package.consumers.isEmpty ? "" : " (used by \(package.consumers.joined(separator: ", ")))"
            return RuleHit(title: "\(name(url)) is pinned to branch \(branch)\(consumers); pin a version or a revision from "
                            + "Package.resolved",
                           evidence: [.init(kind: "package", ref: url, value: "branch \(branch)"
                                            + (inProject ? " (XCRemoteSwiftPackageReference)" : " (Package.swift)"))],
                           targets: package.consumers, apply: inProject ? .pbxproj : .manifest,
                           keys: ["url": RuleScan.normalized(url)], change: .packagePin(url: url))
        }
        return hits.isEmpty ? .passed("\(remote.count) remote package(s) pinned to versions or revisions") : .hits(hits)
    }

    /// Where Xcode keeps the resolved pins for this container.
    static func resolvedFile(_ s: RuleScan) -> URL? {
        guard let container = s.project?.container else { return nil }
        switch container {
        case let .xcodeproj(url):
            return url.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
        case let .xcworkspace(url): return url.appendingPathComponent("xcshareddata/swiftpm/Package.resolved")
        case let .package(url): return url.deletingLastPathComponent().appendingPathComponent("Package.resolved")
        }
    }

    /// DEP-002 (static part; the resolve-time part needs `Logs/Package`, DYN-004): `Package.resolved` missing (with
    /// remote packages) or present but untracked fires; tracked passes; outside a git work tree it is N/A.
    static func packageResolved(_ s: RuleScan) -> Evaluation {
        guard let file = resolvedFile(s), let root = s.project?.root else { return .notApplicable("no container path") }
        let exists = FileManager.default.fileExists(atPath: file.path)
        guard exists || !s.remotePackages.isEmpty else { return .notApplicable("no remote Swift packages") }
        let shown = s.displayPath(file.path)
        guard exists else {
            return .hits([RuleHit(title: "Package.resolved is missing (\(shown)): every machine and CI run resolves package "
                                    + "versions again; commit it and resolve only from it on CI",
                                  evidence: [.init(kind: "file", ref: shown, value: "missing")], apply: .recommend,
                                  keys: ["container": shown])])
        }
        guard s.probe.run(["git", "-C", root.path, "rev-parse", "--is-inside-work-tree"]) == "true" else {
            return .notApplicable("Package.resolved present (\(shown)); not a git work tree, so tracking is unknown")
        }
        if s.probe.run(["git", "-C", root.path, "ls-files", "--error-unmatch", file.path]) == nil {
            return .hits([RuleHit(title: "Package.resolved (\(shown)) is not tracked by git; commit it and resolve only from "
                                    + "it on CI",
                                  evidence: [.init(kind: "file", ref: shown, value: "not in git")], apply: .recommend,
                                  keys: ["container": shown])])
        }
        return .passed("Package.resolved present and tracked (\(shown))")
    }

    static let heavy: [(pattern: String, name: String)] = [
        ("firebase", "Firebase"), ("realm", "Realm"), ("grpc", "gRPC"), ("abseil", "abseil"),
    ]

    /// DEP-003 (static part: a known heavy dependency compiled from source; sized when a build is analyzed).
    static func heavyDeps(_ s: RuleScan) -> Evaluation {
        var found: [(name: String, item: ReportDocument.EvidenceItem)] = []
        for package in s.remotePackages {
            guard let url = package.url else { continue }
            let normalized = RuleScan.normalized(url)
            if let match = heavy.first(where: { normalized.contains($0.pattern) && !normalized.contains("binary") }) {
                found.append((match.name, .init(kind: "package", ref: url, value: requirementText(package.requirement))))
            }
        }
        if let podfile = s.podfile {
            for match in heavy where RuleScan.matches(s.podfileCode.lowercased(), #"pod\s+['"][^'"]*"# + match.pattern) {
                found.append((match.name, .init(kind: "file", ref: s.displayPath(podfile.url.path), value: "pod \(match.name)")))
            }
        }
        // Podfile.lock lists every pod actually installed, transitive ones included (a Podfile may name only a
        // wrapper pod).
        if let lock = s.cocoapods?.lockfile, let text = try? String(contentsOf: lock, encoding: .utf8) {
            let pods = lockedPods(text)
            for match in heavy where !found.contains(where: { $0.name == match.name }) {
                let names = pods.filter { $0.lowercased().contains(match.pattern) }
                if !names.isEmpty {
                    found.append((match.name, .init(kind: "file", ref: s.displayPath(lock.path),
                                                    value: names.prefix(3).joined(separator: ", ")
                                                        + (names.count > 3 ? " (+\(names.count - 3))" : ""))))
                }
            }
        }
        guard !found.isEmpty else {
            guard s.project != nil else { return .notApplicable("no project read") }
            return .passed("no known heavy source dependency (Firebase, Realm, gRPC, abseil)")
        }
        let names = s.distinct(found.map(\.name))
        return .hits(names.map { name in
            var hit = RuleHit(title: "\(name) is built from source; prefer its binary distribution if clean builds are "
                                + "dominated by it",
                              evidence: found.filter { $0.name == name }.map(\.item), apply: .recommend, keys: ["name": name])
            if let rows = s.context.document?.targets, let total = s.context.document?.build.taskTime, total > 0 {
                // Package and pod targets only (by owner), matched on the whole pattern, not a name prefix.
                let pattern = heavy.first { $0.name == name }?.pattern ?? name.lowercased()
                let owned = rows.filter {
                    !$0.isOther && ($0.owner == "remotePackage" || $0.owner == "pods") && $0.name.lowercased().contains(pattern)
                }
                let seconds = owned.reduce(0) { $0 + $1.taskTime }
                if seconds > 0 {
                    hit.measured = Measured(seconds: seconds, share: seconds / total, basis: "task time of \(name) targets")
                }
            }
            return hit
        })
    }

    /// Pod names of a `Podfile.lock` `PODS:` section (`  - Firebase/Core (10.0.0):` → `Firebase/Core`).
    static func lockedPods(_ text: String) -> [String] {
        var inPods = false
        var names: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("PODS:") { inPods = true; continue }
            if inPods, !line.hasPrefix(" ") && !line.isEmpty { break }
            guard inPods, line.hasPrefix("  - ") else { continue }
            let entry = line.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if let name = entry.split(separator: " ").first { names.append(String(name).trimmingCharacters(in: CharacterSet(charactersIn: ":\""))) }
        }
        return names
    }

    /// DEP-004 (static part: the pod count; sized by the Pods targets' share of a clean build).
    static func cocoapodsPrecompiled(_ s: RuleScan) -> Evaluation {
        guard let pods = s.cocoapods else { return .notApplicable("no CocoaPods (no Podfile)") }
        guard let count = pods.podCount else { return .notApplicable("pod count unknown (no Podfile.lock)") }
        guard count > 20 else { return .passed("\(count) pods (≤ 20)") }
        var hit = RuleHit(title: "\(count) pods compiled from source; precompile them (Rugby, cocoapods-binary-cache, "
                            + "PodBuilder) if Pods targets dominate clean builds",
                          evidence: [.init(kind: "file", ref: s.displayPath((pods.lockfile ?? pods.podfile).path),
                                           value: "\(count) pods")],
                          apply: .recommend)
        if let rows = s.context.document?.targets, s.context.document?.build.kind == "clean",
           let total = s.context.document?.build.taskTime, total > 0 {
            let seconds = rows.filter { $0.owner == "pods" }.reduce(0) { $0 + $1.taskTime }
            if seconds > 0 { hit.measured = Measured(seconds: seconds, share: seconds / total, basis: "task time of Pods targets") }
        }
        return .hits([hit])
    }

    /// DEP-005.
    static func cocoapodsToSPM(_ s: RuleScan) -> Evaluation {
        guard let pods = s.cocoapods else { return .notApplicable("no CocoaPods (no Podfile)") }
        var evidence: [ReportDocument.EvidenceItem] = [.init(kind: "file", ref: s.displayPath(pods.podfile.path), value: "present")]
        if let lock = pods.lockfile {
            evidence.append(.init(kind: "file", ref: s.displayPath(lock.path),
                                  value: pods.podCount.map { "\($0) pods" } ?? "pod count unknown"))
        }
        let count = pods.podCount.map { "\($0) pods" } ?? "pods"
        return .hits([RuleHit(title: "CocoaPods manages \(count); migrate pod by pod to Swift packages (caching and explicit "
                                + "modules)", evidence: evidence, apply: .recommend)])
    }

    /// DEP-006.
    static func carthageCache(_ s: RuleScan) -> Evaluation {
        guard let cartfile = s.cartfile else { return .notApplicable("no Carthage (no Cartfile)") }
        let entries = ((try? String(contentsOf: cartfile, encoding: .utf8)) ?? "").split(separator: "\n")
            .filter { let line = $0.trimmingCharacters(in: .whitespaces); return !line.isEmpty && !line.hasPrefix("#") }.count
        let built = FileManager.default.fileExists(atPath: cartfile.deletingLastPathComponent()
            .appendingPathComponent("Carthage/Build").path)
        return .hits([RuleHit(title: "Carthage builds \(entries) dependenc\(entries == 1 ? "y" : "ies") from source; cache "
                                + "Carthage/Build keyed on Cartfile.resolved and use --use-xcframeworks",
                              evidence: [.init(kind: "file", ref: s.displayPath(cartfile.path), value: "\(entries) entries"),
                                         .init(kind: "file", ref: "Carthage/Build", value: built ? "present" : "absent")],
                              apply: .recommend)])
    }

    /// DEP-007.
    static func tuistCache(_ s: RuleScan) -> Evaluation {
        if case let .tuist(manifest)? = s.project?.generator {
            return .hits([RuleHit(title: "Tuist project (\(manifest.lastPathComponent)): tuist cache or tuist setup cache can "
                                    + "skip unchanged modules", evidence: [.init(kind: "file", ref: s.displayPath(manifest.path),
                                                                                 value: "Tuist manifest")],
                                  apply: .recommend)])
        }
        if s.context.isCI, s.context.document?.build.kind == "clean", s.xcodeAtLeast("26") == true {
            return .hits([RuleHit(title: "CI clean build on Xcode 26+: a hosted Xcode cache (tuist setup cache) can serve "
                                    + "compilation results", evidence: [.init(kind: "env", ref: "CI",
                                                                              value: s.context.env?.ciProvider ?? "ci")],
                                  apply: .recommend)])
        }
        return .notApplicable("not a Tuist project, and no CI clean build on Xcode 26+")
    }

    static func macroTargets(_ s: RuleScan) -> [String] {
        s.manifests.flatMap { $0.manifest.targets.filter { $0.type == "macro" }.map(\.name) }
    }

    /// DEP-008.
    static func swiftSyntaxPrebuilts(_ s: RuleScan) -> Evaluation {
        let macros = macroTargets(s)
        guard !macros.isEmpty else { return .notApplicable("no macro target") }
        let syntax = s.remotePackages.filter { ($0.url.map(RuleScan.normalized) ?? "").hasSuffix("/swift-syntax") }
        guard !syntax.isEmpty else { return .passed("macro targets present, no swift-syntax reference found") }
        var evidence: [ReportDocument.EvidenceItem] = []
        for package in syntax where RuleScan.normalized(package.url ?? "").contains("apple/swift-syntax") {
            evidence.append(.init(kind: "package", ref: package.url ?? "", value: "apple/ URL blocks prebuilts"))
        }
        let urlFix = !evidence.isEmpty
        var defaultsFix = false
        if let version = s.xcodeVersion, RuleScan.compare(version, [16, 4]) >= 0, RuleScan.compare(version, [26]) < 0,
           s.context.env != nil, s.probe.run(["defaults", "read", "com.apple.dt.Xcode", "IDEPackageEnablePrebuilts"]) == nil {
            defaultsFix = true
            evidence.append(.init(kind: "env", ref: "defaults com.apple.dt.Xcode IDEPackageEnablePrebuilts", value: "unset"))
        }
        guard urlFix || defaultsFix else { return .passed("swift-syntax referenced via swiftlang (prebuilts eligible)") }
        evidence.append(.init(kind: "report", ref: "macro targets", value: macros.joined(separator: ", ")))
        return .hits([RuleHit(title: urlFix ? "swift-syntax is referenced as apple/swift-syntax, which blocks macro prebuilts; "
                                + "use https://github.com/swiftlang/swift-syntax"
                                : "Xcode 16.4 without IDEPackageEnablePrebuilts: macro targets compile swift-syntax from source",
                              evidence: evidence, apply: urlFix ? .manifest : .defaults)])
    }

    /// XCRemoteCache configuration: `.rcinfo` at the root, or compiler/linker settings pointing at its wrappers.
    static func xcremotecacheEvidence(_ s: RuleScan) -> [ReportDocument.EvidenceItem] {
        var evidence: [ReportDocument.EvidenceItem] = []
        if let root = s.project?.root, FileManager.default.fileExists(atPath: root.appendingPathComponent(".rcinfo").path) {
            evidence.append(.init(kind: "file", ref: ".rcinfo", value: "present"))
        }
        let wrappers: Set<String> = ["xccc", "xcswiftc", "xcld", "xcldplusplus", "xclibtool"]
        var seen: Set<String> = []
        for configuration in s.configurationNames {
            for target in s.targets(in: configuration) {
                for key in ["CC", "CXX", "SWIFT_EXEC", "LD", "LDPLUSPLUS", "LIBTOOL"] {
                    guard let value = s.value(target.name, key, configuration),
                          wrappers.contains(URL(fileURLWithPath: value).lastPathComponent),
                          seen.insert("\(key)=\(value)").inserted else { continue }
                    evidence.append(.init(kind: "setting", ref: "\(target.name):\(configuration):\(key)", value: value,
                                          provenance: s.label(s.provenance(target.name, key, configuration))))
                }
            }
        }
        return evidence
    }

    /// DEP-010.
    static func xcremotecache(_ s: RuleScan) -> Evaluation {
        let evidence = xcremotecacheEvidence(s)
        guard !evidence.isEmpty else { return .passed("no XCRemoteCache configuration") }
        return .hits([RuleHit(title: "XCRemoteCache is in use: it needs SWIFT_USE_INTEGRATED_DRIVER = NO, which blocks Xcode "
                                + "26 compilation caching; keep it only if Xcode caching is insufficient",
                              evidence: evidence, apply: .recommend)])
    }

    static let syntaxProducts: Set<String> = [
        "SwiftSyntax", "SwiftParser", "SwiftSyntaxBuilder", "SwiftBasicFormat", "SwiftDiagnostics", "SwiftOperators",
        "SwiftParserDiagnostics", "SwiftIDEUtils", "SwiftRefactor", "SwiftLexicalLookup", "SwiftSyntaxMacros",
        "SwiftSyntaxMacroExpansion", "SwiftCompilerPlugin",
    ]

    /// DEP-012.
    static func swiftSyntaxLibrary(_ s: RuleScan) -> Evaluation {
        var users: [(target: String, products: [String])] = []
        for target in s.project?.allTargets ?? [] {
            let products = target.packageProducts.filter(syntaxProducts.contains)
            if !products.isEmpty { users.append((target.name, products)) }
        }
        for (_, manifest) in s.manifests {
            for target in manifest.targets where target.type != "macro" && target.type != "test" {
                let products = target.dependencies.filter(syntaxProducts.contains)
                if !products.isEmpty { users.append((target.name, products)) }
            }
        }
        let cost = packageCost(s)
        guard !users.isEmpty else {
            if s.project == nil, let cost, !cost.isEmpty {
                return .hits(cost.map { row in
                    RuleHit(title: "remote package target \(row.name) takes \(Int((row.share * 100).rounded())) % of this "
                                + "clean build; keep it in a stable leaf module or ship it as a binary target",
                            evidence: [.init(kind: "report", ref: "targets", value: row.basis)], targets: [row.name],
                            apply: .recommend, keys: ["targets": row.name],
                            measured: Measured(seconds: row.seconds, share: row.share, basis: row.basis))
                })
            }
            guard s.project != nil else { return .notApplicable("no project read, and no remote package dominates the build") }
            return .passed("no non-macro target uses swift-syntax")
        }
        let version = s.remotePackages.first { ($0.url.map(RuleScan.normalized) ?? "").hasSuffix("/swift-syntax") }
            .map { " " + requirementText($0.requirement).replacingOccurrences(of: "exact ", with: "") } ?? ""
        let targets = s.distinct(users.map(\.target))
        var hit = RuleHit(title: "swift-syntax\(version) is a library dependency of \(targets.joined(separator: ", ")) ("
                            + s.distinct(users.flatMap(\.products)).joined(separator: ", ") + "); prebuilts cover macro "
                            + "targets only, so it compiles from source on every clean build. Keep swift-syntax code in a "
                            + "stable leaf module; consider a binary target",
                          evidence: users.map { .init(kind: "package", ref: $0.target, value: "uses " + $0.products.joined(separator: ", ")) },
                          targets: targets, apply: .recommend)
        if let cost, let syntax = cost.filter({ syntaxProducts.contains($0.name) || $0.name.hasPrefix("_SwiftSyntax") }).max(by: { $0.share < $1.share }) {
            hit.measured = Measured(seconds: syntax.seconds, share: syntax.share, basis: syntax.basis)
        } else if s.context.analysis == nil {
            hit.evidence.append(.init(kind: "report", ref: "size", value: "run xcblame analyze on a clean build to size it"))
        }
        return .hits([hit])
    }

    /// Remote-package target rows of a clean build at ≥ 30 % of task time or ≥ 20 % of the critical path.
    static func packageCost(_ s: RuleScan) -> [(name: String, seconds: Double, share: Double, basis: String)]? {
        guard let document = s.context.document, document.build.kind == "clean", let rows = document.targets else { return nil }
        let total = document.build.taskTime ?? 0
        let span = document.criticalPath?.span ?? 0
        return rows.compactMap { row in
            guard row.owner == "remotePackage", !row.isOther else { return nil }
            let taskShare = total > 0 ? row.taskTime / total : 0
            let pathShare = span > 0 ? (row.onPathSeconds ?? 0) / span : 0
            if pathShare >= 0.2, let onPath = row.onPathSeconds {
                return (row.name, onPath, pathShare, "on-path seconds of \(row.name) in this clean build")
            }
            if taskShare >= 0.3 { return (row.name, row.taskTime, taskShare, "task time of \(row.name) in this clean build") }
            return nil
        }
    }
}
