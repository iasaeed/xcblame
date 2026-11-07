import Foundation

// v0.6 lane B (docs/SCHEMA-v0.6.md "Verify document", "Verdict", "Mechanisms in verify"; DESIGN §7.8): the A/B harness.
// Preconditions, then per unit arm A (the overlay as committed, the unit's own applied blocks taken out) and arm B (A
// plus the unit's lines through `hook` or `cli`), validity checks, the noise-model verdict, and (with `record`) the
// verdicts written into the plan, auto-revert of applied reverted steps and the history verify entry.
public struct ABHarness: Verifying {
    public var runner: any VerifyBuildRunning
    public var host: any VerifyHost
    public var interrupt: VerifyInterrupt
    /// Read for `XCODE_XCCONFIG_FILE` (the `cli` wrapper includes it and unsets it for the child).
    public var environment: [String: String]
    /// SIGINT/SIGTERM restore the overlay and abort (`interrupted`); off in tests.
    public var installSignalHandlers: Bool
    /// Write the verdicts into the stored plan, auto-revert, save the history verify entry.
    public var record: Bool

    public init(runner: any VerifyBuildRunning, host: any VerifyHost = SystemVerifyHost(),
                interrupt: VerifyInterrupt = VerifyInterrupt(),
                environment: [String: String] = ProcessInfo.processInfo.environment,
                installSignalHandlers: Bool = true, record: Bool = true) {
        self.runner = runner
        self.host = host
        self.interrupt = interrupt
        self.environment = environment
        self.installSignalHandlers = installSignalHandlers
        self.record = record
    }

    public func verify(_ request: VerifyRequest) throws -> VerifyDocument {
        try VerifySession(harness: self, request: request).run()
    }
}

/// The name docs/SCHEMA-v0.6.md "Lane ownership" gives the harness.
public typealias ABRun = ABHarness

/// One `verify` invocation's mutable state.
final class VerifySession {
    typealias Run = VerifyDocument.Run

    struct Measured {
        var run: Run
        var outcome: VerifyBuildOutcome?
    }

    struct ArmState {
        var label: String
        var derivedData: URL?
        var measured: [Measured] = []
        var nextIndex: Int { measured.count + 1 }
        var runs: [Run] { measured.map(\.run) }
        var samples: [Measured] { measured.filter { $0.run.ok && $0.run.excluded == nil && $0.run.wall != nil } }
    }

    struct UnitState {
        var unit: VerifyUnit
        var arm: ArmState
        /// Set once the unit's verdict no longer depends on more runs (`noEffect`, `brokeBuild`, all runs done).
        var finished = false
        var verdict: VerifyDocument.Verdict?
        var checks: [VerifyDocument.Check] = []
        var notes: [String] = []
        /// Index of the A arm the unit is compared with.
        var group = 0
    }

    struct Group {
        var kind: VerifyDocument.Kind
        var mechanism: FixPlanDocument.Mechanism
        var a: ArmState
        var units: [Int]
    }

    struct Aborted: Error {}

    let harness: ABHarness
    let request: VerifyRequest
    var host: any VerifyHost { harness.host }
    let plan: FixPlanDocument
    let start: Date
    var notes: [String] = []
    var preconditions: [VerifyDocument.Precondition] = []
    var abort: VerifyDocument.Abort?
    var units: [UnitState] = []
    var groups: [Group] = []
    var arguments: [String] = []
    var scheme: String?
    var configuration = "Debug"
    var touch: URL?
    var xcode: String?
    var overlayURL: URL!
    /// The overlay as committed, without the selected steps' own plan blocks: arm A's overlay.
    var base: String?
    var current: String?
    let overlayGuard = OverlayGuard()
    var builds = 0
    /// Other plans' blocks arm A left out because they set a measured key (auto-revert does not touch them).
    var otherBlocks: [(planId: String, ruleId: String)] = []

    init(harness: ABHarness, request: VerifyRequest) {
        self.harness = harness
        self.request = request
        self.plan = request.plan
        self.start = harness.host.now()
    }

    // MARK: - Run

    func run() throws -> VerifyDocument {
        let selection = try VerifySelection.units(plan: plan, rules: request.rules, kind: request.kind,
                                                  mechanism: request.mechanism, oneByOne: request.oneByOne)
        notes += selection.notes
        let resolved = try VerifyArguments.resolve(given: request.xcodebuildArguments, plan: plan,
                                                   historyDirectory: request.xcblameDir.appendingPathComponent("history"))
        arguments = resolved.arguments
        scheme = resolved.scheme
        notes += resolved.notes
        configuration = try Self.configuration(resolved.configuration, units: selection.units)
        // Without -configuration xcodebuild builds the project's default (normally Release), not the configuration
        // whose overlay lines are measured (review minor 5).
        if XcodebuildRunner.value(of: "-configuration", in: arguments) == nil {
            arguments += ["-configuration", configuration]
            notes.append("-configuration \(configuration) added to the xcodebuild arguments (the selected steps' overlay "
                + "lines are for \(configuration))")
        }
        if let path = request.touch {
            let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { throw XcblameError.usage("--touch \(path): no such file") }
            touch = url
        }
        overlayURL = VerifyOverlay.url(xcblameDir: request.xcblameDir, configuration: configuration)
        current = try? String(contentsOf: overlayURL, encoding: .utf8)
        if let current {
            // Arm A: without the selected steps' own blocks, and without another plan's block that sets one of the
            // keys the units set (else both arms hold the change: review minor 6).
            let rules = selection.units.flatMap(\.ruleIds)
            let keys = Set(selection.units.flatMap(\.steps).flatMap(\.overlay).filter { $0.configuration == configuration }
                .map(\.key))
            let others = try VerifyOverlay.otherPlanBlocks(current, plan: plan.id, keys: keys, file: overlayURL.lastPathComponent)
            base = try VerifyOverlay.removingBlocks(current, file: overlayURL.lastPathComponent) { block in
                (block.planId == self.plan.id && rules.contains(block.ruleId))
                    || others.contains { $0.planId == block.planId && $0.ruleId == block.ruleId }
            }
            otherBlocks = others
            if !others.isEmpty {
                notes.append("arm A also builds without " + others.map { "plan \($0.planId)'s \($0.ruleId) block" }
                    .joined(separator: ", ") + " (it sets a key the measured steps set)")
            }
        }
        if base != current {
            notes.append("arm A builds without the selected steps' applied blocks in \(overlayURL.lastPathComponent)")
        }
        overlayGuard.journal = VerifyJournal(xcblameDir: request.xcblameDir, planId: plan.id,
                                             rules: selection.units.flatMap(\.ruleIds))

        for unit in selection.units {
            var state = UnitState(unit: unit, arm: ArmState(label: unit.label))
            state.checks.append(oracleCheck(unit))
            if state.checks.last?.status == "fail" {
                state.finished = true
                state.verdict = .init(status: .reverted, reason: .noEffect)
                state.notes.append("not built: the change reaches no target under \(unit.mechanism.rawValue)")
            }
            units.append(state)
        }
        for index in units.indices where !units[index].finished {
            let unit = units[index].unit
            if let group = groups.firstIndex(where: { $0.kind == unit.kind && $0.mechanism == unit.mechanism }) {
                groups[group].units.append(index)
                units[index].group = group
            } else {
                units[index].group = groups.count
                groups.append(Group(kind: unit.kind, mechanism: unit.mechanism, a: ArmState(label: "A"), units: [index]))
            }
        }
        if groups.count > 1 {
            for index in groups.indices { groups[index].a.label = "A-\(groups[index].kind.rawValue)-\(groups[index].mechanism.rawValue)" }
            notes.append("arm A measured once per kind and mechanism: "
                + groups.map { "\($0.a.label) for " + $0.units.map { units[$0].unit.ruleIds.joined(separator: "+") }.joined(separator: ", ") }
                    .joined(separator: "; "))
        }

        checkPreconditions()
        if abort == nil {
            let signals = harness.installSignalHandlers ? VerifySignals(guard: overlayGuard, interrupt: harness.interrupt) : nil
            defer {
                overlayGuard.restoreAll()
                signals?.uninstall()
            }
            for index in groups.indices {
                do { try measure(group: index) } catch is Aborted { break }
            }
        }
        overlayGuard.restoreAll()
        var results = units.map(result)
        if harness.record { try recordVerdicts(&results) }
        return document(results)
    }

    static func configuration(_ given: String?, units: [VerifyUnit]) throws -> String {
        if let given { return given }
        let configurations = Set(units.flatMap(\.steps).flatMap(\.overlay).map(\.configuration))
        guard configurations.count == 1, let only = configurations.first else {
            throw XcblameError.usage("give -configuration after -- (the selected steps have overlay lines for "
                + (configurations.isEmpty ? "no configuration" : configurations.sorted().joined(separator: ", ")) + ")")
        }
        return only
    }

    // MARK: - Preconditions (§7.8 step 1)

    func checkPreconditions() {
        let fm = FileManager.default
        let containerDir = URL(fileURLWithPath: plan.project.container).deletingLastPathComponent()
        let near = fm.fileExists(atPath: containerDir.path) ? containerDir : request.xcblameDir.deletingLastPathComponent()
        let root = host.repositoryRoot(of: near)
        func resolve(_ relative: String) -> URL {
            let candidates = [root, containerDir].compactMap { $0?.appendingPathComponent(relative).standardizedFileURL }
            return candidates.first { fm.fileExists(atPath: $0.path) } ?? candidates[0]
        }
        var failed: [(VerifyDocument.AbortReason, String)] = []

        let configurations = Set(units.flatMap { $0.unit.steps.flatMap(\.overlay).map(\.configuration) } + [configuration])
        var touched = configurations.sorted().map { VerifyOverlay.url(xcblameDir: request.xcblameDir, configuration: $0) }
        touched += plan.hook.filter { $0.status == "installed" }.compactMap(\.baseXCConfig).map(resolve)
        let present = touched.filter { fm.fileExists(atPath: $0.path) }
        if let dirty = host.dirtyFiles(present, in: near) {
            if dirty.isEmpty {
                add("cleanTree", "pass", present.isEmpty ? "no overlay or hooked xcconfig exists yet"
                    : "committed: " + present.map(\.lastPathComponent).joined(separator: ", "))
            } else {
                let detail = "uncommitted changes in \(dirty.joined(separator: ", ")): commit them first, so arm A is what "
                    + "is committed and the overlay comes back exactly"
                add("cleanTree", "fail", detail)
                failed.append((.dirtyTree, detail))
            }
        } else {
            add("cleanTree", "warn", "not a git work tree: the files the plan touches were not checked")
        }

        switch host.onBattery() {
        case true?:
            let detail = "on battery power: connect the charger (battery saving slows builds unevenly) and run verify again"
            add("power", "fail", detail)
            failed.append((.onBattery, detail))
        case false?: add("power", "pass", "on AC power")
        case nil: add("power", "warn", "power source unknown (pmset -g batt gave nothing)")
        }

        let thermal = host.thermalState()
        add("thermal", thermal == "nominal" ? "pass" : "warn", thermal == "nominal" ? "nominal"
            : "thermal state \(thermal) at the start: throttled runs are excluded and replaced once")

        let others = host.otherXcodebuilds()
        if others.isEmpty {
            add("otherBuild", "pass", "no other xcodebuild running")
        } else {
            let detail = "another xcodebuild is running (pid \(others.map(String.init).joined(separator: ", "))): wait for "
                + "it to finish, it would share the cores with every run"
            add("otherBuild", "fail", detail)
            failed.append((.xcodebuildRunning, detail))
        }

        if units.contains(where: { $0.unit.mechanism == .hook && !$0.finished }) {
            let state = plan.hook.first { $0.configuration == configuration }
            let file = state?.baseXCConfig.map(resolve)
            let include = "overlay-\(configuration).xcconfig"
            let text = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
            let hooked = text.components(separatedBy: "\n").contains {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("#include?") && $0.contains(include)
            }
            if hooked, let file {
                add("hook", "pass", "\(file.lastPathComponent) includes \(include)")
            } else {
                let detail = "the hook is not installed for \(configuration)"
                    + (file.map { " (\($0.lastPathComponent) has no #include? of \(include))" } ?? (state?.reason.map { " (\($0))" } ?? ""))
                    + ": run xcblame fix --install-hook, or verify with --mechanism cli"
                add("hook", "fail", detail)
                failed.append((.hookMissing, detail))
            }
        }
        if let first = failed.first { abort = .init(reason: first.0, detail: first.1) }
    }

    private func add(_ name: String, _ status: String, _ detail: String) {
        preconditions.append(.init(name: name, status: status, detail: detail))
    }

    /// `oracle`: the plan's scope rows of the unit's mechanism for the verified configuration (the oracle ran when the
    /// plan was made); none reached is `noEffect`.
    func oracleCheck(_ unit: VerifyUnit) -> VerifyDocument.Check {
        let lines = unit.steps.flatMap(\.overlay).filter { $0.configuration == configuration }
        guard !lines.isEmpty else {
            return .init(name: "oracle", status: "fail", detail: "no overlay line for configuration \(configuration)")
        }
        let rows = unit.steps.flatMap(\.scope).filter { $0.mechanism == unit.mechanism && $0.configuration == configuration }
        guard !rows.isEmpty else {
            return .init(name: "oracle", status: "skipped",
                         detail: "the plan has no \(unit.mechanism.rawValue) scope rows for \(configuration)")
        }
        let reached = Set(rows.filter(\.reached).map(\.target))
        let all = Set(rows.map(\.target))
        guard !reached.isEmpty else {
            return .init(name: "oracle", status: "fail", detail: "no target reached under \(unit.mechanism.rawValue): "
                + "every key is shadowed (" + all.sorted().joined(separator: ", ") + ")")
        }
        let shadowed = all.subtracting(reached)
        return .init(name: "oracle", status: "pass", detail: "\(reached.count) of \(all.count) target(s) reached"
            + (shadowed.isEmpty ? "" : "; shadowed: " + shadowed.sorted().joined(separator: ", ")))
    }

    // MARK: - Measuring

    /// Clean kind: rounds of A then each unit's B (ABAB). Other kinds: arm A (settle + measured runs) in its
    /// DerivedData, then each unit's arm B in its own.
    func measure(group index: Int) throws {
        let group = groups[index]
        groups[index].a.derivedData = try VerifyDerivedData.prepare(home: request.cacheHome, plan: plan.id, label: group.a.label)
        for unit in group.units {
            units[unit].arm.derivedData = try VerifyDerivedData.prepare(home: request.cacheHome, plan: plan.id,
                                                                        label: units[unit].unit.label)
        }
        if group.kind == .clean {
            for _ in 0..<request.runs where !group.units.allSatisfy({ units[$0].finished }) {
                try runA(group: index, settle: false)
                for unit in group.units where !units[unit].finished { try runB(unit: unit, settle: false) }
            }
            for unit in group.units { units[unit].finished = true }
        } else {
            for position in 0..<request.runs { try runA(group: index, settle: position == 0) }
            for unit in group.units {
                for position in 0..<request.runs where !units[unit].finished { try runB(unit: unit, settle: position == 0) }
                units[unit].finished = true
            }
        }
    }

    func runA(group index: Int, settle: Bool) throws {
        let group = groups[index]
        var arm = group.a
        defer { groups[index].a = arm }
        try measured(arm: .a, state: &arm, kind: group.kind, mechanism: group.mechanism, settle: settle, lines: nil)
        if settle, group.kind == .incremental, touch == nil, let outcome = arm.measured.last?.outcome {
            guard let picked = outcome.swiftSources.sorted(by: { ($0.target, $0.path) < ($1.target, $1.path) }).first else {
                throw XcblameError.usage("--kind incremental: the settle build compiled no Swift source of a project "
                    + "target to touch; give --touch <file>")
            }
            touch = URL(fileURLWithPath: picked.path).standardizedFileURL
            notes.append("touch: \(picked.path) (first Swift source of target \(picked.target)), timestamp only, before "
                + "each measured run of both arms")
        }
        if let failed = arm.measured.last, !failed.run.ok {
            let what = failed.run.settle ? "the settle build" : "run \(failed.run.index)"
            try stop(.baselineBroken, "arm A \(what) exited \(failed.run.exitCode): the build fails without the change, "
                + "so nothing can be compared; fix the build (xcblame build -- …) and verify again")
        }
    }

    func runB(unit index: Int, settle: Bool) throws {
        var state = units[index]
        defer { units[index] = state }
        let blocks = state.unit.steps.map { step in
            (rule: step.ruleId, lines: step.overlay.filter { $0.configuration == configuration }.map(\.line))
        }
        let text = VerifyOverlay.withTemporaryBlocks(base, plan: plan.id, configuration: configuration, blocks: blocks)
        try measured(arm: .b, state: &state.arm, kind: state.unit.kind, mechanism: state.unit.mechanism, settle: settle,
                     lines: text)
        if let failed = state.arm.measured.last, !failed.run.ok {
            state.finished = true
            state.verdict = .init(status: .reverted, reason: .brokeBuild)
        }
    }

    /// One run, and its one replacement when the run ends throttled (a throttled replacement aborts `thermal`).
    /// `lines`: arm B's overlay text; nil for arm A.
    func measured(arm: VerifyDocument.Arm, state: inout ArmState, kind: VerifyDocument.Kind,
                  mechanism: FixPlanDocument.Mechanism, settle: Bool, lines: String?) throws {
        var first = try once(arm: arm, state: state, kind: kind, mechanism: mechanism, settle: settle, overlay: lines)
        guard first.run.ok, !settle, Self.throttled(first.run.thermal) else {
            state.measured.append(first)
            return
        }
        first.run.excluded = "thermal: replaced by run \(first.run.index + 1)"
        state.measured.append(first)
        var second = try once(arm: arm, state: state, kind: kind, mechanism: mechanism, settle: false, overlay: lines)
        if second.run.ok, Self.throttled(second.run.thermal) {
            second.run.excluded = "thermal"
            state.measured.append(second)
            try stop(.thermal, "thermal state stayed \(second.run.thermal ?? "high") through arm \(arm.rawValue) run "
                + "\(first.run.index) and its replacement: let the Mac cool down and run verify again")
        }
        state.measured.append(second)
    }

    static func throttled(_ thermal: String?) -> Bool { ["fair", "serious", "critical"].contains(thermal ?? "") }

    /// Exit codes of a process ended by SIGHUP, SIGINT, SIGQUIT, SIGKILL or SIGTERM (`128 + n`, `XcodebuildRunner`).
    static let signalExits: Set<Int32> = [129, 130, 131, 137, 143]

    var stamps: [String: Date] = [:]

    /// The modification time the hook overlay gets for every run of arm `label`.
    func stamp(_ label: String) -> Date {
        if let date = stamps[label] { return date }
        let date = Date()
        stamps[label] = date
        return date
    }

    static func writeIfChanged(_ text: String, to url: URL) throws {
        guard (try? String(contentsOf: url, encoding: .utf8)) != text else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func once(arm: VerifyDocument.Arm, state: ArmState, kind: VerifyDocument.Kind, mechanism: FixPlanDocument.Mechanism,
              settle: Bool, overlay text: String?) throws -> Measured {
        if harness.interrupt.isRaised {
            try stop(.interrupted, "\(harness.interrupt.name ?? "a signal") stopped verify; the overlay was restored")
        }
        if let minutes = request.maxMinutes, host.now().timeIntervalSince(start) >= minutes * 60 {
            try stop(.timeout, "--max-minutes \(Self.number(minutes)) passed after \(builds) build(s); finished verdicts are "
                + "kept, give more minutes or fewer --runs for the rest")
        }
        // The budget left: the runner stops a build still running when it is used up (review minor 8).
        let deadline = request.maxMinutes.map { start.addingTimeInterval($0 * 60) }
        guard let derivedData = state.derivedData else { throw XcblameError.usage("internal: arm without DerivedData") }
        var buildArguments = arguments
        var unset: [String] = []
        switch mechanism {
        case .cli:
            // Rewritten only when the text changes, so a series of one arm sees the same files (no re-planning).
            let cliOverlay = VerifyOverlay.cliURL(xcblameDir: request.xcblameDir, configuration: configuration)
            try Self.writeIfChanged(text ?? base ?? "", to: cliOverlay)
            let wrapper = try WrapperXCConfig.plan(arguments: arguments, environment: harness.environment,
                                                   overlay: cliOverlay, lines: [], xcblameDir: request.xcblameDir)
            try Self.writeIfChanged(wrapper.contents, to: wrapper.url)
            buildArguments = wrapper.arguments
            unset = wrapper.unsetEnvironment
        default:
            // The same text gets the same modification time on every run of the arm (restored in between).
            if let text {
                try overlayGuard.write(text, to: overlayURL, modificationDate: stamp(state.label))
            } else if base != current, let base {
                try overlayGuard.write(base, to: overlayURL, modificationDate: stamp(state.label))
            }
        }
        buildArguments += ["-derivedDataPath", derivedData.path]
        if kind == .incremental, !settle, let touch { try host.touch(touch) }
        let build = VerifyBuild(arm: arm, label: state.label, index: state.nextIndex, settle: settle, clean: kind == .clean,
                                arguments: buildArguments, unsetEnvironment: unset, derivedData: derivedData,
                                deadline: deadline)
        let outcome: VerifyBuildOutcome
        do {
            defer { if mechanism != .cli { overlayGuard.restore(overlayURL) } }
            outcome = try harness.runner.build(build)
        }
        builds += 1
        if xcode == nil { xcode = outcome.xcode }
        if outcome.timedOut, let minutes = request.maxMinutes {
            overlayGuard.restoreAll()
            try stop(.timeout, "--max-minutes \(Self.number(minutes)) ran out during arm \(arm.rawValue) run \(build.index): "
                + "the running build was stopped; finished verdicts are kept, give more minutes or fewer --runs")
        }
        let ok = outcome.exitCode == 0
        // A build stopped by a signal (Ctrl-C reaches xcodebuild through the process group before the handler marks
        // the interrupt): wait a moment for it, so the run is `interrupted`, not `broke build` (review minor 7).
        if !ok, Self.signalExits.contains(outcome.exitCode) {
            for _ in 0..<20 where !harness.interrupt.isRaised { usleep(50_000) }
        }
        let run = Run(arm: arm, index: build.index, settle: settle, ok: ok, exitCode: outcome.exitCode,
                      wall: outcome.wall.map(Stats.round6), criticalPath: outcome.criticalPath,
                      taskKindsHash: outcome.taskKinds.map(VerifyVerdict.taskKindsHash),
                      targetSetHash: outcome.targets.map(VerifyVerdict.targetSetHash), thermal: host.thermalState(),
                      excluded: settle ? "settle build" : (ok ? nil : "failed"))
        if harness.interrupt.isRaised {
            overlayGuard.restoreAll()
            try stop(.interrupted, "\(harness.interrupt.name ?? "a signal") stopped verify during arm \(arm.rawValue) run "
                + "\(build.index); the overlay was restored")
        }
        return Measured(run: run, outcome: outcome)
    }

    func stop(_ reason: VerifyDocument.AbortReason, _ detail: String) throws -> Never {
        abort = .init(reason: reason, detail: detail)
        throw Aborted()
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    // MARK: - Results

    func result(_ state: UnitState) -> VerifyDocument.UnitResult {
        let unit = state.unit
        let a = groups.indices.contains(state.group) && !(state.verdict?.reason == .noEffect) ? groups[state.group].a
            : ArmState(label: "A")
        var checks = state.checks
        var notes = state.notes
        var verdict = state.verdict ?? .init(status: .unverified)
        var timing: VerifyVerdict.Timing?
        if state.finished, state.verdict?.reason != .noEffect {
            checks += validity(a: a, b: state.arm, unit: unit)
            if verdict.status == .unverified,
               checks.contains(where: { ($0.name == "targetSet" || $0.name == "taskKinds") && $0.status == "fail" }) {
                verdict = .init(status: .reverted, reason: .taskSetChanged)
            }
            let t = VerifyVerdict.timing(a: a.samples.compactMap(\.run.wall), b: state.arm.samples.compactMap(\.run.wall),
                                         runs: request.runs, keepOnTie: request.keepOnTie)
            if verdict.reason != .brokeBuild { timing = t }
            if verdict.status == .unverified { verdict = t.verdict }
            if verdict.status == .indicative {
                notes.append(request.runs < VerifyDocument.NoiseModel.v06.minRuns
                    ? "indicative: --runs \(request.runs) is below \(VerifyDocument.NoiseModel.v06.minRuns); never kept"
                    : "indicative: fewer than \(VerifyDocument.NoiseModel.v06.minSamples) samples in an arm; never kept")
            }
        } else if !state.finished {
            notes.append("not finished: verify stopped (\(abort?.reason.rawValue ?? "aborted")) before this unit's verdict")
        }
        let scope = unit.steps.flatMap(\.scope).filter { $0.mechanism == unit.mechanism }
        return .init(ruleIds: unit.ruleIds, titles: unit.steps.map(\.title), mechanism: unit.mechanism, scope: scope,
                     arms: [armResult(.a, a), armResult(.b, state.arm)],
                     deltaSeconds: timing?.deltaSeconds, deltaPct: timing?.deltaPct,
                     noiseBand: verdict.status == .indicative ? nil : timing?.noiseBand,
                     verdict: verdict, checks: checks, notes: notes)
    }

    func armResult(_ arm: VerifyDocument.Arm, _ state: ArmState) -> VerifyDocument.ArmResult {
        let walls = state.samples.compactMap(\.run.wall)
        let (p50, mad) = VerifyVerdict.stats(walls)
        return .init(arm: arm, derivedData: state.derivedData?.path, runs: state.runs, runsTotal: state.runs.count,
                     runsOk: state.runs.filter(\.ok).count, samples: walls.count, p50: p50, mad: mad)
    }

    /// `exitCode`, `targetSet`, `taskKinds` (clean kind only) and `thermal` of a finished unit.
    func validity(a: ArmState, b: ArmState, unit: VerifyUnit) -> [VerifyDocument.Check] {
        var checks: [VerifyDocument.Check] = []
        let failedB = b.runs.filter { !$0.ok }
        checks.append(failedB.isEmpty
            ? .init(name: "exitCode", status: "pass", detail: "every run of both arms exited 0")
            : .init(name: "exitCode", status: "fail", detail: failedB.map { "B run \($0.index) exited \($0.exitCode)" }
                .joined(separator: "; ")))
        guard failedB.isEmpty else { return checks }

        let aSamples = a.samples.compactMap(\.outcome)
        let bSamples = b.samples.compactMap(\.outcome)
        if let reference = aSamples.first?.targets {
            let differing = bSamples.compactMap(\.targets).filter { $0 != reference }
            if let other = differing.first {
                let added = Set(other).subtracting(reference).sorted()
                let removed = Set(reference).subtracting(other).sorted()
                checks.append(.init(name: "targetSet", status: "fail", detail: "arm B built other targets ("
                    + [added.isEmpty ? nil : "added " + added.joined(separator: ", "),
                       removed.isEmpty ? nil : "missing " + removed.joined(separator: ", ")].compactMap { $0 }
                        .joined(separator: "; ") + ")"))
            } else {
                checks.append(.init(name: "targetSet", status: "pass", detail: "\(reference.count) target(s), the same in both arms"))
            }
        } else {
            checks.append(.init(name: "targetSet", status: "skipped", detail: "no log was read for arm A"))
        }

        if unit.kind != .clean {
            checks.append(.init(name: "taskKinds", status: "skipped",
                                detail: "compared for clean builds only (an \(unit.kind.rawValue) build's tasks depend on what changed)"))
        } else if let reference = aSamples.first?.taskKinds {
            let allowed = VerifyVerdict.declared(for: unit.ruleIds)
            // An architecture-count rule (SET-005): per-arch tasks run once per architecture, so kinds compare by
            // presence; the compile/link work and every other kind of A must still be in B (fix round 3).
            let presenceOnly = VerifyVerdict.architectureCount(unit.ruleIds)
            let selfDiff = aSamples.dropFirst().compactMap(\.taskKinds)
                .flatMap { VerifyVerdict.differingKinds(reference, $0, allowed: allowed, presenceOnly: presenceOnly) }
            let bKinds = bSamples.compactMap(\.taskKinds)
            let diff = Set(bKinds.flatMap {
                VerifyVerdict.differingKinds(reference, $0, allowed: allowed, presenceOnly: presenceOnly)
            }).sorted()
            var effect = allowed.isEmpty ? "" : " (declared effect left out: " + allowed.sorted().joined(separator: ", ") + ")"
            if presenceOnly { effect += " (architecture count changes: kinds compared by presence, not count)" }
            if diff.isEmpty {
                checks.append(.init(name: "taskKinds", status: "pass", detail: "the same executed task kinds per target" + effect))
            } else if !selfDiff.isEmpty {
                checks.append(.init(name: "taskKinds", status: "warn", detail: "arm A's own runs differ ("
                    + Set(selfDiff).sorted().prefix(5).map(Self.readable).joined(separator: ", ") + "), so B is not judged by it"))
            } else {
                checks.append(.init(name: "taskKinds", status: "fail",
                                    detail: VerifyVerdict.taskKindsFailure(diff, reference: reference, samples: bKinds,
                                                                           rules: unit.ruleIds)))
            }
        } else {
            checks.append(.init(name: "taskKinds", status: "skipped", detail: "no log was read for arm A"))
        }

        let replaced = (a.runs + b.runs).filter { $0.excluded?.hasPrefix("thermal") == true }
        checks.append(replaced.isEmpty
            ? .init(name: "thermal", status: "pass", detail: "no run was throttled")
            : .init(name: "thermal", status: "warn", detail: replaced.map { "\($0.arm.rawValue) run \($0.index) \($0.thermal ?? "")" }
                .joined(separator: ", ") + ": excluded and replaced"))
        return checks
    }

    static func readable(_ key: String) -> String { key.replacingOccurrences(of: "\t", with: " ") }

    // MARK: - Recording

    /// Verdicts into the stored plan (same id only), auto-revert of applied reverted steps, the history verify entry.
    func recordVerdicts(_ results: inout [VerifyDocument.UnitResult]) throws {
        var stored = (try? FixPlanStore.load(id: plan.id, xcblameDir: request.xcblameDir)).flatMap { $0.id == plan.id ? $0 : nil }
            ?? plan
        let verifyId = documentId
        // What the verdicts were measured against (`VerifyBasis`): a later plan reuses them only while it is the same.
        let digest = VerifyBasis.projectDigest(container: stored.project.container, xcblameDir: request.xcblameDir)
        var reverted: [(rules: [String], reason: String)] = []
        for (position, unitResult) in results.enumerated() where unitResult.verdict.status != .unverified {
            let unit = units[position].unit
            for rule in unitResult.ruleIds {
                guard let step = stored.steps.firstIndex(where: { $0.ruleId == rule }) else { continue }
                stored.steps[step].verify = .init(status: unitResult.verdict.status, reason: unitResult.verdict.reason,
                                                  mechanism: unit.mechanism, kind: unit.kind.rawValue, verifyId: verifyId,
                                                  verifiedAt: request.generatedAt, deltaSeconds: unitResult.deltaSeconds,
                                                  deltaPct: unitResult.deltaPct, tie: unitResult.verdict.tie,
                                                  basis: VerifyBasis.value(step: stored.steps[step],
                                                                           container: stored.project.container,
                                                                           projectDigest: digest))
            }
            results[position].basis = VerifyBasis.combined(ruleIds: unitResult.ruleIds, plan: stored, projectDigest: digest)
            if unitResult.verdict.status == .reverted {
                reverted.append((unitResult.ruleIds, unitResult.verdict.reason?.rawValue ?? "reverted"))
            }
        }
        for item in reverted {
            guard let index = results.firstIndex(where: { $0.ruleIds == item.rules }) else { continue }
            // One failed auto-revert (another configuration's overlay edited by hand, a write error) must not lose the
            // verdicts of the whole run (review minor 9): noted, and the plan and history entry are still saved.
            do {
                let revertedRules = try autoRevert(item.rules, reason: item.reason, plan: &stored)
                if !revertedRules.isEmpty {
                    results[index].notes.append("auto-revert: removed the overlay block of "
                        + revertedRules.joined(separator: ", ") + " that xcblame fix --apply wrote")
                }
            } catch {
                results[index].notes.append("auto-revert of \(item.rules.joined(separator: ", ")) failed (\(error)): remove "
                    + "its block with xcblame fix --revert \(stored.id)")
            }
            for other in otherBlocks {
                results[index].notes.append("plan \(other.planId)'s \(other.ruleId) block sets the same key and stays in the "
                    + "overlay: xcblame fix --revert \(other.planId) removes it")
            }
        }
        do {
            try FixPlanStore.save(stored, xcblameDir: request.xcblameDir)
        } catch {
            notes.append("the verdicts were not written into plan \(stored.id) (\(error)); the history verify entry has them")
        }
    }

    /// Removes the plan blocks of the `applied` steps among `rules` from every overlay file that holds one.
    func autoRevert(_ rules: [String], reason: String, plan stored: inout FixPlanDocument) throws -> [String] {
        let fm = FileManager.default
        var done: [String] = []
        var files: [String] = []
        let root = host.repositoryRoot(of: request.xcblameDir.deletingLastPathComponent())
            ?? request.xcblameDir.deletingLastPathComponent()
        for rule in rules {
            guard let index = stored.steps.firstIndex(where: { $0.ruleId == rule }) else { continue }
            // An `applied-cli` step has no block: it only stops being delivered by `build --overlay` (fix round 2,
            // finding 4).
            if stored.steps[index].state == .appliedCLI {
                stored.steps[index].state = .reverted
                stored.steps[index].stateReason = "verify reverted it (\(reason)); xcblame build --overlay no longer delivers it"
                done.append(rule)
                continue
            }
            guard stored.steps[index].state == .applied else { continue }
            var removed = false
            for configuration in Set(stored.steps[index].overlay.map(\.configuration)).sorted() {
                let url = VerifyOverlay.url(xcblameDir: request.xcblameDir, configuration: configuration)
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      VerifyOverlay.hasPlanBlock(text, plan: stored.id, rule: rule) else { continue }
                let rest = try VerifyOverlay.removingPlanBlocks(text, plan: stored.id, rules: [rule], file: url.lastPathComponent)
                if VerifyOverlay.isEmptyOverlay(rest) {
                    try fm.removeItem(at: url)
                } else {
                    try Data(rest.utf8).write(to: url, options: .atomic)
                }
                removed = true
                let path = url.standardizedFileURL.path
                files.append(path.hasPrefix(root.path + "/") ? String(path.dropFirst(root.path.count + 1)) : path)
            }
            guard removed else { continue }
            stored.steps[index].state = .reverted
            stored.steps[index].stateReason = "verify reverted it (\(reason)); its overlay block was removed"
            done.append(rule)
        }
        if !done.isEmpty {
            stored.events.append(.init(at: request.generatedAt, action: "revert", ruleIds: done, files: Array(Set(files)).sorted(),
                                       defaultsKeys: []))
        }
        return done
    }

    // MARK: - Document

    var documentId: String { XcodebuildRunner.timestamp(request.generatedAt) + "-verify" }

    func document(_ results: [VerifyDocument.UnitResult]) -> VerifyDocument {
        var notes = self.notes
        let kinds = Set(units.map(\.unit.kind))
        if kinds.count > 1 {
            notes.append("kinds per unit: " + units.map { "\($0.unit.ruleIds.joined(separator: "+")) \($0.unit.kind.rawValue)" }
                .joined(separator: ", "))
        }
        if units.contains(where: { $0.unit.mechanism == .hook }) {
            notes.append("hook: arm B wrote its lines into \(overlayURL.lastPathComponent) as temporary blocks; the file's "
                + "exact bytes were restored after each B run")
        }
        let document = VerifyDocument(
            tool: ReportDocument.Tool(name: "xcblame", version: XcblameVersion.current, kindTable: KindTable.v1.version),
            generatedAt: request.generatedAt, id: documentId, planId: plan.id, kind: units.first?.unit.kind ?? request.kind ?? .clean,
            mechanism: request.mechanism, runsPerArm: request.runs, oneByOne: request.oneByOne, keepOnTie: request.keepOnTie,
            maxMinutes: request.maxMinutes, touch: touch?.path, scheme: scheme, configuration: configuration,
            xcodebuildArguments: arguments, preconditions: preconditions, results: results, abort: abort,
            elapsedSeconds: Stats.round6(max(0, host.now().timeIntervalSince(start))), xcode: xcode, machine: host.machine(),
            notes: notes)
        if harness.record {
            do {
                _ = try History.saveVerify(document, directory: request.xcblameDir.appendingPathComponent("history"))
            } catch {
                var noted = document
                noted.notes.append("history: the verify entry was not saved (\(error))")
                return noted
            }
        }
        return document
    }
}
