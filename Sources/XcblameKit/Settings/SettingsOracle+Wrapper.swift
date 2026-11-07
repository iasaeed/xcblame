import Foundation

// v0.5 lane A (docs/SCHEMA-v0.5.md "Oracle check"): the effective settings of the build exactly as `xcblame build`
// will run it, with or without the wrapper xcconfig (DESIGN §5.8, §7.5).
extension SettingsOracle {
    /// Action words and flags of a build invocation that `-showBuildSettings` must not get.
    static let buildActions: Set<String> = ["build", "clean", "test", "archive", "analyze", "install", "installsrc",
                                            "build-for-testing", "test-without-building", "docbuild"]
    static let droppedFlagsWithValue: Set<String> = ["-resultBundlePath", "-derivedDataPath"]
    static let droppedFlags: Set<String> = ["-showBuildTimingSummary", "-quiet"]

    /// `xcodebuild -showBuildSettings -json` over the build's own arguments (container, scheme, configuration,
    /// destination, `KEY=VALUE` settings) with `-xcconfig <xcconfig>` added when it is not there yet, in
    /// `derivedData`. `unsetEnvironment` is removed from the child's environment (the wrapper includes
    /// `XCODE_XCCONFIG_FILE`). Unlike `effective`, the scheme's own targets are evaluated as xcodebuild sees them on the
    /// command line (package targets included only when xcodebuild lists them), nothing is cached, and the project is
    /// never copied: the run is the same one `build` makes. Nil with a reason when xcodebuild fails or lists nothing.
    public static func effective(withXCConfig xcconfig: URL?, arguments: [String], derivedData: URL?,
                                 unsetEnvironment: [String] = [], timeout: TimeInterval = 60,
                                 executable: URL? = nil) -> (settings: EffectiveSettings?, note: String?) {
        var argv: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            if droppedFlagsWithValue.contains(argument) {
                index += 2
                continue
            }
            if !buildActions.contains(argument), !droppedFlags.contains(argument) { argv.append(argument) }
            index += 1
        }
        if let xcconfig, XcodebuildRunner.value(of: "-xcconfig", in: argv) != xcconfig.path {
            argv += ["-xcconfig", xcconfig.path]
        }
        if let derivedData { argv += ["-derivedDataPath", derivedData.path] }
        argv += ["-showBuildSettings", "-json"]
        let tool = executable.map { [$0.path] } ?? ["/usr/bin/xcrun", "xcodebuild"]
        let env = unsetEnvironment.isEmpty ? [] : ["/usr/bin/env"] + unsetEnvironment.flatMap { ["-u", $0] }
        guard let output = runProcess(env + tool + argv, timeout: timeout) else {
            return (nil, "could not run xcodebuild -showBuildSettings")
        }
        guard output.succeeded else {
            return (nil, "xcodebuild -showBuildSettings failed (\(XcodebuildSettings.reason(output)))")
        }
        guard let targets = XcodebuildSettings.parse(output.stdout), !targets.isEmpty else {
            return (nil, "xcodebuild -showBuildSettings listed no targets")
        }
        let configuration = XcodebuildRunner.value(of: "-configuration", in: arguments)
            ?? targets.values.first?["CONFIGURATION"] ?? "Default"
        return (EffectiveSettings(configuration: configuration, targets: targets, source: .xcodebuild), nil)
    }

    /// One configuration's `xcodebuild -showBuildSettings -json` through `effectiveAll`'s scratch workspace and
    /// generated all-targets scheme (`OracleCache.directory` under `cacheHome`, default `OracleCache.home()`), so the
    /// call carries `-derivedDataPath` in the oracle cache and nothing lands under `~/Library/Developer` or in the
    /// project (sandboxed without packages, the write guard otherwise). `xcconfig` is passed as `-xcconfig` (the fix
    /// planner's cli rows); `unsetEnvironment` is removed from the child's environment. Never cached. Nil with a reason
    /// when xcodebuild fails or lists nothing (the fix lane's hook verifier and cli oracle; v0.6 fix round 1).
    public static func effectiveInScratch(project: ProjectModel, configuration: String, xcconfig: URL? = nil,
                                          unsetEnvironment: [String] = [], cacheHome: URL? = nil,
                                          timeout: TimeInterval = defaultTimeout,
                                          xcodebuild: String = "/usr/bin/xcodebuild")
        -> (settings: EffectiveSettings?, note: String?) {
        if case .package = project.container { return (nil, "package container: no xcodebuild settings") }
        let scratch = XcodebuildSettings.scratch(cacheHome: cacheHome ?? OracleCache.home(), project: project).url
        let prepared: XcodebuildSettings.Prepared
        do {
            prepared = try XcodebuildSettings.prepare(project: project, scheme: nil, in: scratch)
        } catch {
            return (nil, "xcodebuild not run (\(error))")
        }
        OracleCache.touch(scratch)
        let usesPackages = XcodebuildSettings.usesPackages(project)
        let packages = scratch.appendingPathComponent("SourcePackages")
        let warm = XcodebuildSettings.hasPackageCheckouts(packages)
        let guardian = WriteGuard(roots: [project.root] + XcodebuildSettings.localPackageDirs(project)
                                      + project.projects.map { $0.path.deletingLastPathComponent() })
        defer { _ = guardian.restore() }
        let shared = XcodebuildSettings.sharedTargetNames(project)
        let deadline = Date().addingTimeInterval(timeout)
        var merged: [String: [String: String]] = [:]
        for group in prepared.groups {
            let output = XcodebuildSettings.run(
                project: project, configuration: configuration, workspace: prepared.workspace, scheme: group.scheme,
                dir: scratch, sandboxed: !usesPackages, skipPackageUpdates: warm, timeout: deadline.timeIntervalSinceNow,
                packages: packages, destination: group.destination, executable: xcodebuild,
                extraArguments: xcconfig.map { ["-xcconfig", $0.path] } ?? [], unsetEnvironment: unsetEnvironment)
            guard let output, output.succeeded, let targets = XcodebuildSettings.parse(output.stdout, qualified: shared) else {
                return (nil, "xcodebuild -showBuildSettings failed (\(XcodebuildSettings.reason(output)))")
            }
            for (name, values) in targets
            where merged[name] == nil || group.targets.contains(String(name.split(separator: "/").last ?? "")) {
                merged[name] = values
            }
        }
        guard !merged.isEmpty else { return (nil, "xcodebuild -showBuildSettings listed no targets") }
        return (EffectiveSettings(configuration: configuration, targets: merged, source: .xcodebuild), nil)
    }
}
