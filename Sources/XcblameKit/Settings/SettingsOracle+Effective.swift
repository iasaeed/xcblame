import Foundation

extension SettingsOracle {
    /// Per-configuration bound on xcodebuild (DESIGN §7.4): package projects stay under ~25 s worst case.
    public static let defaultTimeout: TimeInterval = 20
    /// `analyze`'s bound: the rules ride along with a log analysis and never wait for long.
    public static let analyzeTimeout: TimeInterval = 5
    /// `doctor`'s cap on the whole oracle run (every configuration together).
    public static let doctorTotalTimeout: TimeInterval = 30

    /// `effective` for several configurations at once: cache hits are returned as is, the misses run as concurrent
    /// xcodebuild calls, each bounded by its own `timeout` (the 200-target fixture takes ~2.4 s and 7.4 MB per
    /// configuration, so serial calls would miss the 5 s doctor budget). Each configuration that fails falls back to
    /// the offline resolver with a note. Package targets (never listed by xcodebuild) come from the offline resolver.
    /// Never throws. The settings JSON goes to `cacheDir`; the scratch workspace, DerivedData and package clones to
    /// `OracleCache.directory` under `cacheHome` (default `OracleCache.home()`), or a temporary folder removed after
    /// the run when `cacheDir` is nil. Nothing is written into the project: a write guard removes the empty folders
    /// xcodebuild creates there (noted).
    ///
    /// Packages: the project's own checkouts are reused when their pins match `Package.resolved` (one configuration
    /// first, `-skipPackageUpdates` always, so they are never resolved into); else the oracle cache's checkouts;
    /// else, only with `resolvePackages`, one configuration resolves (clones) into the oracle cache. Without
    /// `resolvePackages` (`analyze`) a project with packages and no usable checkouts goes offline at once.
    public static func effectiveAll(project: ProjectModel, configurations: [String], scheme: String?, offline: Bool,
                                    cacheDir: URL?, timeout: TimeInterval = defaultTimeout,
                                    resolvePackages: Bool = true, cacheHome: URL? = nil,
                                    totalTimeout: TimeInterval? = nil,
                                    xcodebuild: String = "/usr/bin/xcodebuild") -> [String: EffectiveSettings] {
        var result: [String: EffectiveSettings] = [:]
        func fallback(_ configuration: String, _ note: String?) -> EffectiveSettings {
            var settings = OfflineResolver.resolve(project: project, configuration: configuration)
            if let note { settings.notes.insert(note, at: 0) }
            return settings
        }
        func allOffline(_ note: String?) -> [String: EffectiveSettings] {
            for c in configurations { result[c] = fallback(c, note) }
            return result
        }
        guard !offline else { return allOffline(nil) }
        if case .package = project.container { return allOffline("package container: offline resolver only") }

        let scratch = XcodebuildSettings.scratch(cacheHome: cacheDir == nil ? nil : (cacheHome ?? OracleCache.home()),
                                                 project: project)
        defer { if scratch.temporary { try? FileManager.default.removeItem(at: scratch.url) } }
        let usesPackages = XcodebuildSettings.usesPackages(project)
        var packageNotes: [String] = []
        var packages: URL?
        // The user's checkouts a private clone was made from (never passed to xcodebuild).
        var reusedFrom: URL?
        if usesPackages {
            let own = XcodebuildSettings.sourcePackages(project)
            // Only checkouts proven at the pinned revisions (no Package.resolved: nothing to prove, not used).
            // `analyze` never clones (it would spend its 5 s on the copy): only a clone a `doctor` run already made.
            if let own, XcodebuildSettings.pinsMatch(project, checkouts: own) == true,
               let clone = resolvePackages ? XcodebuildSettings.clonedCheckouts(own, into: scratch.url, notes: &packageNotes)
                                           : XcodebuildSettings.existingClone(of: own, in: scratch.url) {
                packages = clone
                reusedFrom = own
            } else {
                if let own, XcodebuildSettings.pinsMatch(project, checkouts: own) != true {
                    packageNotes.append(XcodebuildSettings.pinsMatch(project, checkouts: own) == nil
                        ? "the project's package checkouts (\(own.path)) cannot be checked (no Package.resolved): not used"
                        : "the project's package checkouts (\(own.path)) do not match Package.resolved "
                            + "(pins changed since Xcode last resolved): not used, never updated by xcblame")
                }
                packages = scratch.url.appendingPathComponent("SourcePackages")
                if !XcodebuildSettings.hasPackageCheckouts(packages!), !resolvePackages {
                    return allOffline((packageNotes + ["no package checkouts to reuse (the project's DerivedData or the "
                        + "oracle cache) and analyze never resolves packages: offline resolver"]).joined(separator: "; "))
                }
            }
        }
        guard let version = runProbe(["xcodebuild", "-version"], timeout: 10) else {
            return allOffline("xcodebuild not available; offline resolver")
        }

        var misses: [String] = []
        for c in configurations where result[c] == nil {
            if let cacheDir,
               var hit = SettingsCache.load(SettingsCache.file(cacheDir: cacheDir, project: project, configuration: c,
                                                               scheme: scheme, xcodeVersion: version), project: project) {
                hit.notes.append("cache hit")
                result[c] = hit
            } else if !misses.contains(c) {
                misses.append(c)
            }
        }
        guard !misses.isEmpty else { return result }

        let prepared: XcodebuildSettings.Prepared
        do {
            prepared = try XcodebuildSettings.prepare(project: project, scheme: scheme, in: scratch.url)
        } catch {
            for c in misses { result[c] = fallback(c, "xcodebuild not run (\(error)); offline resolver") }
            return result
        }
        if !scratch.temporary { OracleCache.touch(scratch.url) }
        let inputs = SettingsCache.snapshot(SettingsCache.inputs(project: project))
        let sandboxFirst = !usesPackages
        // Checkouts already there (the project's or the cache's): resolve nothing (`-skipPackageUpdates`).
        let warm = usesPackages && XcodebuildSettings.hasPackageCheckouts(packages!)
        // The checkouts the clone came from are the user's too: watched like the project.
        let guardian = WriteGuard(roots: [project.root] + XcodebuildSettings.localPackageDirs(project)
                                      + project.projects.map { $0.path.deletingLastPathComponent() }
                                      + (reusedFrom.map { [$0] } ?? []))
        let shared = XcodebuildSettings.sharedTargetNames(project)
        // `analyze` caps the whole run (`totalTimeout`); each configuration also has its own `timeout` deadline.
        let overall = totalTimeout.map { Date().addingTimeInterval($0) }

        let outcomes = Outcomes(count: misses.count)
        let pending = misses
        let checkouts = packages
        let groups = prepared.groups
        // A destination that failed once is not tried again by the other configurations of this run.
        let failedDestinations = FailedDestinations()
        @Sendable func work(_ i: Int, skipUpdates: Bool) {
            let configuration = pending[i]
            // One deadline per configuration covering every call (groups, sandbox and destination retries).
            var deadline = Date().addingTimeInterval(timeout)
            if let overall, overall < deadline { deadline = overall }
            func attempt(_ scheme: String, _ destination: String?, sandboxed: Bool, skipUpdates: Bool) -> ProcessOutput? {
                guard deadline.timeIntervalSinceNow > 0.1 else {
                    return ProcessOutput(stdout: Data(), stderr: Data(), exitStatus: -1, timedOut: true)
                }
                return XcodebuildSettings.run(project: project, configuration: configuration, workspace: prepared.workspace,
                                              scheme: scheme, dir: scratch.url, sandboxed: sandboxed,
                                              skipPackageUpdates: skipUpdates, timeout: deadline.timeIntervalSinceNow,
                                              packages: checkouts, destination: destination, executable: xcodebuild)
            }
            // One call per platform group (one for most projects), merged.
            var merged: [String: [String: String]] = [:]
            var notes: [String] = []
            for group in groups {
                let destination = failedDestinations.contains(group.scheme) ? nil : group.destination
                var output = attempt(group.scheme, destination, sandboxed: sandboxFirst, skipUpdates: skipUpdates)
                // A sandboxed run fails on anything SwiftPM sandboxes itself: retry once unsandboxed (the write guard
                // covers it). Package runs never retry here: a resolve must not race (see below).
                if sandboxFirst, output?.succeeded != true, output?.timedOut != true {
                    output = attempt(group.scheme, destination, sandboxed: false, skipUpdates: false)
                }
                // A platform that is not installed: the old host-platform evaluation, noted.
                if destination != nil, output?.succeeded != true, output?.timedOut != true {
                    failedDestinations.insert(group.scheme)
                    output = attempt(group.scheme, nil, sandboxed: sandboxFirst, skipUpdates: skipUpdates)
                }
                if group.destination != nil, destination == nil || failedDestinations.contains(group.scheme),
                   output?.succeeded == true {
                    notes.append("evaluated without a destination (\(group.destination!) failed): "
                        + group.targets.joined(separator: ", "))
                }
                guard let output, output.succeeded, let targets = XcodebuildSettings.parse(output.stdout, qualified: shared),
                      !targets.isEmpty else {
                    var why = output?.succeeded == true ? "listed no targets" : XcodebuildSettings.reason(output)
                    if output?.timedOut == true { why = "timed out after " + String(format: "%g", timeout) + " s" }
                    outcomes.set(i, XcodebuildSettings.Outcome(targets: nil, notes: ["xcodebuild failed (\(why)); offline resolver"],
                                                               timedOut: output?.timedOut == true))
                    return
                }
                // A group's own targets win over the same names evaluated by another group's dependency walk.
                for (name, values) in targets
                where merged[name] == nil || group.targets.contains(String(name.split(separator: "/").last ?? "")) {
                    merged[name] = values
                }
            }
            outcomes.set(i, XcodebuildSettings.Outcome(targets: merged, notes: notes))
        }
        if usesPackages, !warm {
            // One configuration first, alone: on a cold cache it resolves (clones) for the others; on the project's own
            // checkouts it settles their state files before any concurrent reader. The rest then reuse the checkouts.
            // (Warm oracle-cache checkouts run all at once below, every call with -skipPackageUpdates.)
            work(0, skipUpdates: warm)
            let first = outcomes.get(0)
            if first.targets == nil, first.timedOut || !XcodebuildSettings.hasPackageCheckouts(packages!) {
                // A cold resolve that timed out (or failed) would make each other configuration wait as long again.
                packageNotes.append("package resolution failed for \(pending[0]); the other configurations were not run")
                for i in 1..<max(1, pending.count) { outcomes.set(i, first) }
            } else if pending.count > 1 {
                DispatchQueue.concurrentPerform(iterations: pending.count - 1) { work($0 + 1, skipUpdates: true) }
            }
        } else {
            DispatchQueue.concurrentPerform(iterations: pending.count) { work($0, skipUpdates: warm) }
        }
        let guarded = guardian.restore()
        var freshNotes = packageNotes
        if !guarded.removed.isEmpty {
            let shown = guarded.removed.map { path -> String in
                let root = project.root.standardizedFileURL.path + "/"
                return path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
            }
            freshNotes.append("removed empty folders xcodebuild created: " + shown.joined(separator: ", "))
        }

        for (i, configuration) in misses.enumerated() {
            let outcome = outcomes.get(i)
            guard var targets = outcome.targets else {
                result[configuration] = fallback(configuration, outcome.notes.first)
                result[configuration]!.notes += freshNotes + guarded.notes
                continue
            }
            var notes = guarded.notes + outcome.notes
            if let reusedFrom { notes.append("package checkouts cloned from \(reusedFrom.path)") }
            let missing = project.allTargets.map(\.name).filter { targets[$0] == nil }
            if !missing.isEmpty {
                notes.append("xcodebuild listed no settings for: \(missing.joined(separator: ", "))")
            }
            let (packageTargets, packageTargetNotes) = OfflineResolver.packageTargets(project: project,
                                                                                      existing: Set(targets.keys))
            targets.merge(packageTargets) { listed, _ in listed }
            notes += packageTargetNotes
            let settings = EffectiveSettings(configuration: configuration, targets: targets, source: .xcodebuild,
                                             notes: notes)
            if let cacheDir, guarded.notes.isEmpty {
                SettingsCache.store(settings, file: SettingsCache.file(cacheDir: cacheDir, project: project,
                                                                       configuration: configuration, scheme: scheme,
                                                                       xcodeVersion: version), inputs: inputs)
            }
            // Removal notes describe this run only: never cached.
            var shown = settings
            shown.notes = freshNotes + shown.notes
            result[configuration] = shown
        }
        return result
    }
}

/// Platform-group schemes whose destination failed in this run.
private final class FailedDestinations: @unchecked Sendable {
    private var schemes: Set<String> = []
    private let lock = NSLock()

    func insert(_ scheme: String) {
        lock.lock()
        schemes.insert(scheme)
        lock.unlock()
    }

    func contains(_ scheme: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return schemes.contains(scheme)
    }
}

/// Results written from `concurrentPerform` workers.
private final class Outcomes: @unchecked Sendable {
    private var values: [XcodebuildSettings.Outcome?]
    private let lock = NSLock()

    init(count: Int) { values = Array(repeating: nil, count: count) }

    func set(_ i: Int, _ value: XcodebuildSettings.Outcome) {
        lock.lock()
        values[i] = value
        lock.unlock()
    }

    func get(_ i: Int) -> XcodebuildSettings.Outcome {
        lock.lock()
        defer { lock.unlock() }
        return values[i] ?? XcodebuildSettings.Outcome(targets: nil, notes: ["xcodebuild did not run"])
    }
}
