import Foundation

// Scripts and phases (RULES.md §5): the rows as Swift literals (columns verbatim from docs/RULES.md) and their predicates.
extension RuleCatalog {
    static let phaseRules: [Rule] = [
        Rule(spec: RuleSpec(
            id: "PHASE-001", name: "run-script-inputs-outputs", category: .phase, detection: .both,
            signal: "`PBXShellScriptBuildPhase` (or xcproj equivalent) with empty `outputPaths` and `outputFileListPaths`, or `alwaysOutOfDate = 1`, or no inputs; D: `PhaseScriptExecution` executed in zero-change/incremental builds (seconds measured).",
            fix: "Declare inputs/outputs or `.xcfilelist`; stable dummy input + static output for no-input scripts; \"Based on dependency analysis\" on.",
            applyKinds: [.recommend, .pbxproj], verifyOnly: false,
            impactContext: "M: Allegro warm 27.2 to 7.5 s ([BP] §7.1); Helm zero-change 70 to 9 s combined (S4)",
            risk: "Wrong declarations skip needed runs.",
            configurations: .both, xcode: "10+", evidenceTag: RuleSpec.EvidenceTag(text: "P"),
            sources: ["[OC] D1", "[BP] §7.1", "https://www.avanderlee.com/xcode/xcode-build-optimization-using-6-agent-skills/"],
            conflicts: ["SET-030"], signalKeyTemplate: "script-phase:<phase-id>",
            summary: "A run script phase without declared outputs (or with \"Based on dependency analysis\" unchecked, or without inputs) runs on every build, including zero-change builds. Declare inputs and outputs.",
            severity: .medium), evaluate: PHASEChecks.scriptIO),
        Rule(spec: RuleSpec(
            id: "PHASE-002", name: "guard-release-only-scripts (incl. D6)", category: .phase, detection: .both,
            signal: "Script text matches `upload-symbols`, `sentry-cli`, `Crashlytics/run` (`${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run`, `${PODS_ROOT}/FirebaseCrashlytics/run`), `curl`, without `${CONFIGURATION}`/`${PLATFORM_NAME}`/`${ACTION}` guard; also Debug `dwarf` with a dSYM upload (nothing to upload).",
            fix: "Wrap: `if [ \"${CONFIGURATION}\" = \"Release\" ]; then ... fi`.",
            applyKinds: [.pbxproj, .recommend], verifyOnly: false,
            impactContext: "S: Sentry 6.3 s per incremental (S5); D6 has no own measurement",
            risk: "Wrong guard skips Release uploads; verify with a Release dry run.",
            configurations: .debug, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] D2", "https://www.avanderlee.com/optimization/analysing-build-performance-xcode/"],
            conflicts: ["SET-004"], signalKeyTemplate: "script-guard:<phase-id>",
            summary: "Symbol uploads and network calls in a run script phase that has no configuration guard run on every Debug build. Wrap them in a Release-only guard.",
            severity: .medium), evaluate: PHASEChecks.releaseOnlyScripts),
        Rule(spec: RuleSpec(
            id: "PHASE-003", name: "linters-in-build-phase", category: .phase, detection: .both,
            signal: "Script calls `swiftlint`/`swiftformat`; `--fix`/formatters in a build phase; D: their task seconds; formatter touching timestamps (DYN-002).",
            fix: "Pre-commit/CI; changed files only; `--quiet`; config guard.",
            applyKinds: [.recommend], verifyOnly: false,
            impactContext: "M: SwiftLint ~10 s per incremental, ~15 s/build across targets saved by linting changed files (S5); AutoScout24 ~19 s ([PP] A6)",
            risk: "Loses inline warnings in Xcode.",
            configurations: .debug, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] D3", "[PP] A6", "https://www.avanderlee.com/optimization/analysing-build-performance-xcode/"],
            conflicts: [], signalKeyTemplate: "script-linter:<phase-id>",
            summary: "Linters and formatters in a build phase run over the whole project on every build. Run them on changed files in a pre-commit hook or on CI.",
            severity: .medium), evaluate: PHASEChecks.linters),
        Rule(spec: RuleSpec(
            id: "PHASE-004", name: "codegen-tools", category: .phase, detection: .both,
            signal: "Script calls Sourcery/SwiftGen/R.swift without I/O lists; generated files rewritten every build (mtime churn, DYN-002).",
            fix: "Run on demand; write only on content change; declare I/O.",
            applyKinds: [.recommend], verifyOnly: false,
            impactContext: "? (measured when it runs)",
            risk: "Stale generated code.",
            configurations: .both, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] D4"],
            conflicts: [], signalKeyTemplate: "script-codegen:<phase-id>",
            summary: "Code generators without input/output lists run and rewrite their output on every build, which invalidates downstream compiles. Declare I/O and write only on change.",
            severity: .low), evaluate: PHASEChecks.codegen),
        Rule(spec: RuleSpec(
            id: "PHASE-005", name: "spm-build-tool-plugins-overhead", category: .phase, detection: .both,
            signal: "`plugins:` in Package.swift / `.plugin(` targets; D: plugin tasks in zero-change builds.",
            fix: "Remove/restrict; regular plugin over prebuilt plugin.",
            applyKinds: [.recommend], verifyOnly: false,
            impactContext: "? (cache invalidation reported, S5)",
            risk: "Loses generated code/lint.",
            configurations: .debug, xcode: "14+", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] D5", "https://www.avanderlee.com/optimization/analysing-build-performance-xcode/"],
            conflicts: [], signalKeyTemplate: "package-plugin:<package>:<target>",
            summary: "Swift package build-tool plugins run during builds and are reported to invalidate caches. Restrict them to the targets that need them.",
            severity: .low), evaluate: PHASEChecks.buildToolPlugins),
        Rule(spec: RuleSpec(
            id: "PHASE-007", name: "cocoapods-generated-phases", category: .phase, detection: .static,
            signal: "Podfile, `Pods/`, `[CP] Embed Pods Frameworks`/`[CP] Copy Pods Resources`.",
            fix: "Do not tweak CocoaPods internals (`COCOAPODS_PARALLEL_CODE_SIGN`); migrate (DEP-005) or precompile (DEP-004).",
            applyKinds: [.recommend], verifyOnly: false,
            impactContext: "?",
            risk: "CocoaPods tweaks regress unpredictably (S1).",
            configurations: .both, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] D7", "https://raw.githubusercontent.com/AvdLee/Xcode-Build-Optimization-Agent-Skill/main/OPTIMIZATION-CHECKS.md"],
            conflicts: ["DEP-005"], signalKeyTemplate: "cocoapods:phases",
            summary: "CocoaPods adds generated script phases to app targets. Do not tweak CocoaPods internals; migrate (DEP-005) or precompile pods instead.",
            severity: .low), evaluate: PHASEChecks.cocoapodsPhases),
    ]
}

/// PHASE predicates: one finding per script phase (signal keys `script-phase:<id>`, `script-guard:<id>`, ...), so
/// a phase that misses its outputs and runs a linter shows under both rules.
enum PHASEChecks {
    typealias ScriptPhase = RuleScan.ScriptPhase

    /// Script phases the user owns: not CocoaPods-generated (PHASE-007), not install-only.
    static func userScripts(_ s: RuleScan) -> [ScriptPhase] {
        s.scriptPhases.filter { !RuleScan.isCocoaPods($0.phase) && !$0.phase.runOnlyForDeploymentPostprocessing }
    }

    /// Why a phase runs on every build: no outputs, "Based on dependency analysis" off, no inputs.
    static func ioProblems(_ phase: ProjectModel.ShellScriptPhase) -> [String] {
        var problems: [String] = []
        if phase.outputPaths.isEmpty && phase.outputFileListPaths.isEmpty { problems.append("no outputs") }
        if phase.alwaysOutOfDate { problems.append("alwaysOutOfDate = 1 (dependency analysis off)") }
        if phase.inputPaths.isEmpty && phase.inputFileListPaths.isEmpty { problems.append("no inputs") }
        return problems
    }

    static func phasesWithoutIO(_ s: RuleScan) -> [ScriptPhase] { userScripts(s).filter { !ioProblems($0.phase).isEmpty } }

    static func noScripts(_ s: RuleScan) -> String {
        s.scriptPhases.isEmpty ? "no script phases" : "only CocoaPods-generated or install-only script phases (PHASE-007)"
    }

    /// Script tasks that ran in an incremental or zero-change build; `phaseId` narrows to one phase's tasks by the
    /// `Script-<id>.sh` in their command line (two phases named "Run Script" never share a cost), `title` to one
    /// title (no project).
    static func scriptCost(_ s: RuleScan, phase: ProjectModel.ShellScriptPhase? = nil, title: String? = nil) -> Measured? {
        guard let analysis = s.context.analysis, let kind = s.context.document?.build.kind,
              kind == "incremental" || kind == "zero-change" else { return nil }
        let tasks = s.buildTasks.filter { task in
            guard task.kind == .script, title.map({ task.title == $0 }) ?? true else { return false }
            guard let phase else { return true }
            // Without command lines (a report's top tasks) only the title can say which phase ran.
            return task.command.isEmpty ? task.title.contains(phase.name) : task.command.contains("Script-\(phase.id).sh")
        }
        guard !tasks.isEmpty else { return nil }
        let seconds = tasks.reduce(0) { $0 + $1.seconds }
        return Measured(seconds: seconds, share: analysis.span > 0 ? seconds / analysis.span : nil,
                        basis: "\(tasks.count) PhaseScriptExecution task(s) in this \(kind) build")
    }

    /// PHASE-001.
    static func scriptIO(_ s: RuleScan) -> Evaluation {
        guard s.project != nil else {
            // Dynamic part only (analyze without a project): script tasks in a non-clean build, grouped by title.
            guard s.context.analysis != nil, let kind = s.context.document?.build.kind,
                  kind == "incremental" || kind == "zero-change" else {
                return .notApplicable("no project, and the build is not incremental or zero-change")
            }
            let titles = s.distinct(s.buildTasks.filter { $0.kind == .script }.map(\.title))
            guard !titles.isEmpty else { return .passed("no script task ran in this \(kind) build") }
            return .hits(titles.map { title in
                RuleHit(title: "\(title) ran in this \(kind) build; declare its inputs and outputs",
                        evidence: [.init(kind: "task", ref: title, value: "executed in a \(kind) build")],
                        apply: .recommend, keys: ["phase-id": title],
                        measured: scriptCost(s, title: title))
            })
        }
        let scripts = userScripts(s)
        guard !scripts.isEmpty else { return .notApplicable(noScripts(s)) }
        let open = scripts.filter { !ioProblems($0.phase).isEmpty }
        guard !open.isEmpty else { return .passed("\(scripts.count) script phase(s) declare inputs and outputs") }
        return .hits(open.map { item in
            let problems = ioProblems(item.phase)
            return RuleHit(title: "\(item.target.name) › \(item.phase.name): \(problems.joined(separator: ", ")), so it runs "
                            + "on every build; declare inputs and outputs (or a stable input and a static output)",
                           evidence: [s.phaseEvidence(item, problems.joined(separator: ", "))], targets: [item.target.name],
                           apply: .recommend, keys: ["phase-id": item.phase.id], measured: scriptCost(s, phase: item.phase),
                           change: .scriptIO(phase: item.phase.name, target: item.target.name))
        })
    }

    static let uploadPattern = #"upload-symbols|upload-dif|sentry-cli|Crashlytics/run|\bcurl\b"#
    /// A condition on the configuration, platform or action: `if`/`case`/`[`/`test` with `$CONFIGURATION` (or
    /// `${PLATFORM_NAME}`, `$ACTION`) as a whole word, so `$CONFIGURATION_BUILD_DIR` is no guard.
    static let guardPattern = #"(\bif\b|\bcase\b|\[|\btest\b)[^\n]*\$\{?(CONFIGURATION|PLATFORM_NAME|ACTION)\b"#

    /// Upload or network scripts with no configuration, platform or action guard.
    static func unguardedUploads(_ s: RuleScan) -> [ScriptPhase] {
        userScripts(s).filter {
            let code = RuleScan.code($0.phase.shellScript)
            return RuleScan.matches(code, uploadPattern) && !RuleScan.matches(code, guardPattern)
        }
    }

    static func uploadsSymbols(_ phase: ProjectModel.ShellScriptPhase) -> Bool {
        RuleScan.matches(RuleScan.code(phase.shellScript), #"upload-symbols|upload-dif|sentry-cli|Crashlytics/run|dSYM|DSYM"#)
    }

    /// PHASE-002.
    static func releaseOnlyScripts(_ s: RuleScan) -> Evaluation {
        let scripts = userScripts(s)
        guard !scripts.isEmpty else { return .notApplicable(noScripts(s)) }
        let open = unguardedUploads(s)
        guard !open.isEmpty else { return .passed("no unguarded upload or network script") }
        let dwarfDebug = s.configurations(.debug).first { configuration in
            s.targets(in: configuration).contains { s.value($0.name, "DEBUG_INFORMATION_FORMAT", configuration) == "dwarf" }
        }
        return .hits(open.map { item in
            let code = RuleScan.code(item.phase.shellScript)
            let tool = code.range(of: uploadPattern, options: .regularExpression).map { String(code[$0]) } ?? "upload"
            var evidence = [s.phaseEvidence(item, "runs \(tool) with no ${CONFIGURATION}/${PLATFORM_NAME}/${ACTION} guard")]
            if let dwarfDebug, uploadsSymbols(item.phase) {
                evidence.append(.init(kind: "setting", ref: "\(dwarfDebug):DEBUG_INFORMATION_FORMAT", value: "dwarf",
                                      provenance: nil))
            }
            return RuleHit(title: "\(item.target.name) › \(item.phase.name) runs \(tool) in every configuration, Debug "
                            + "included; wrap it in a Release-only guard",
                           evidence: evidence, targets: [item.target.name], apply: .pbxproj,
                           keys: ["phase-id": item.phase.id], measured: scriptCost(s, phase: item.phase),
                           change: .scriptGuard(phase: item.phase.name, target: item.target.name))
        })
    }

    /// PHASE-003.
    static func linters(_ s: RuleScan) -> Evaluation {
        let scripts = userScripts(s)
        guard !scripts.isEmpty else { return .notApplicable(noScripts(s)) }
        let hits = scripts.compactMap { item -> RuleHit? in
            let code = RuleScan.code(item.phase.shellScript)
            guard let range = code.range(of: #"\b(swiftlint|swiftformat)\b"#, options: .regularExpression) else { return nil }
            let tool = String(code[range])
            let rewrites = RuleScan.matches(code, #"--fix|autocorrect|swiftformat"#)
            return RuleHit(title: "\(item.target.name) › \(item.phase.name) runs \(tool) on every build; lint changed files "
                            + "in a pre-commit hook or on CI",
                           evidence: [s.phaseEvidence(item, tool + (rewrites ? " (rewrites sources: invalidates compiles)" : ""))],
                           targets: [item.target.name], apply: .recommend, keys: ["phase-id": item.phase.id],
                           measured: scriptCost(s, phase: item.phase))
        }
        return hits.isEmpty ? .passed("no linter or formatter in script phases") : .hits(hits)
    }

    /// PHASE-004.
    static func codegen(_ s: RuleScan) -> Evaluation {
        let scripts = userScripts(s)
        guard !scripts.isEmpty else { return .notApplicable(noScripts(s)) }
        let hits = scripts.compactMap { item -> RuleHit? in
            let code = RuleScan.code(item.phase.shellScript)
            guard let range = code.range(of: #"\b(sourcery|swiftgen|rswift)\b|R\.swift"#, options: [.regularExpression, .caseInsensitive]),
                  !ioProblems(item.phase).isEmpty else { return nil }
            let tool = String(code[range])
            return RuleHit(title: "\(item.target.name) › \(item.phase.name) runs \(tool) without declared inputs/outputs; "
                            + "declare them and write only on change",
                           evidence: [s.phaseEvidence(item, "\(tool); " + ioProblems(item.phase).joined(separator: ", "))],
                           targets: [item.target.name], apply: .recommend, keys: ["phase-id": item.phase.id],
                           measured: scriptCost(s, phase: item.phase),
                           change: .scriptIO(phase: item.phase.name, target: item.target.name))
        }
        return hits.isEmpty ? .passed("no code generator without declared I/O") : .hits(hits)
    }

    /// PHASE-005.
    static func buildToolPlugins(_ s: RuleScan) -> Evaluation {
        guard !s.manifests.isEmpty else { return .notApplicable("no local package manifests") }
        var hits: [RuleHit] = []
        for (reference, manifest) in s.manifests {
            let package = manifest.name ?? reference.path?.lastPathComponent ?? "package"
            for target in manifest.targets where !target.plugins.isEmpty {
                hits.append(RuleHit(title: "package \(package): target \(target.name) applies build-tool plugin(s) "
                                        + target.plugins.joined(separator: ", ") + "; restrict plugins to the targets that need them",
                                    evidence: [.init(kind: "package", ref: "\(package) › \(target.name)",
                                                     value: "plugins: " + target.plugins.joined(separator: ", "))],
                                    targets: [target.name], apply: .recommend,
                                    keys: ["package": package, "target": target.name]))
            }
        }
        return hits.isEmpty ? .passed("no build-tool plugin applied in \(s.manifests.count) local manifest(s)") : .hits(hits)
    }

    /// PHASE-007.
    static func cocoapodsPhases(_ s: RuleScan) -> Evaluation {
        let generated = s.scriptPhases.filter { RuleScan.isCocoaPods($0.phase) }
        guard s.cocoapods != nil || !generated.isEmpty else { return .notApplicable("no CocoaPods") }
        var evidence = generated.map { s.phaseEvidence($0, "generated by CocoaPods") }
        if let pods = s.cocoapods {
            evidence.append(.init(kind: "file", ref: s.displayPath(pods.podfile.path),
                                  value: pods.podCount.map { "\($0) pods in Podfile.lock" } ?? "no Podfile.lock"))
        }
        let names = s.distinct(generated.map(\.phase.name))
        return .hits([RuleHit(title: "CocoaPods " + (names.isEmpty ? "manages this project" : "adds "
                                + "\(names.count) generated script phase(s) (\(names.joined(separator: ", ")))")
                                + "; do not tweak them: migrate (DEP-005) or precompile pods (DEP-004)",
                              evidence: evidence, targets: s.distinct(generated.map(\.target.name)), apply: .recommend)])
    }
}
