import ArgumentParser
import Foundation
import XcblameKit

// v0.6 fix round 1 (review gap 1; DESIGN §3.2, §7.5): `xcblame build --overlay [<plan-id>] [--overlay-unverified]`.
// The plan's deliverable overlay lines (`OverlayDelivery`) go into `tmp/build-overlay-<C>.xcconfig`; the wrapper
// `-xcconfig` (`WrapperXCConfig`: the user's `-xcconfig`, `XCODE_XCCONFIG_FILE` then unset for the child, the overlay,
// `--deep` lines) carries them, and the oracle run with the same wrapper must show every key won, else nothing is
// built (exit 1). The analysis notes `overlay: <plan-id>`.
extension BuildCommand {
    /// What `--overlay` delivered, for the report note and `--deep` (whose wrapper includes the same overlay file).
    struct OverlayRun {
        var planId: String
        var ruleIds: [String]
        var file: URL
        var note: String
    }

    nonisolated(unsafe) static var overlayRun: OverlayRun?

    /// Plan, overlay file, wrapper and oracle check; returns the build arguments (`-xcconfig <wrapper>` instead of the
    /// user's own) and sets `overlayRun` and `deepUnsetEnvironment`.
    func prepareOverlay() throws -> [String] {
        let configuration = Self.argument("-configuration", in: xcodebuildArguments) ?? "Debug"
        let container = Self.container(arguments: xcodebuildArguments)
        let model = try? ProjectModel.load(container: container, scheme: nil)
        let containerPath = model?.container.url.path ?? container.path
        let plan: FixPlanDocument
        do {
            // Only this container's plans: another project's lines must never reach this build (fix round 2, finding 3).
            guard let found = try OverlayDelivery.plan(id: overlayPlan, container: containerPath,
                                                       unverified: overlayUnverified, xcblameDir: stateURL) else {
                let why = OverlayDelivery.reasons(container: containerPath, unverified: overlayUnverified, xcblameDir: stateURL)
                writeStderr("error: --overlay: no plan for \(containerPath) with a kept overlay step"
                    + (overlayUnverified ? " or an unverified one" : "") + " in "
                    + FixPlanStore.directory(xcblameDir: stateURL).path
                    + "; run xcblame fix (then xcblame verify), or pass the plan id"
                    + (why.map { " (newest plan \($0.planId): " + $0.left.joined(separator: "; ") + ")" } ?? ""))
                throw ArgumentParser.ExitCode(XcblameExit.usage.rawValue)
            }
            plan = found
        } catch let error as FixPlanStore.StoreError {
            writeStderr("error: --overlay: \(error)")
            throw ArgumentParser.ExitCode(XcblameExit.usage.rawValue)
        }
        let selection = OverlayDelivery.select(plan, configuration: configuration, unverified: overlayUnverified)
        guard !selection.lines.isEmpty else {
            writeStderr("error: --overlay: plan \(plan.id) has nothing to deliver for \(configuration)"
                + (selection.left.isEmpty ? "" : " (" + selection.left.joined(separator: "; ") + ")")
                + "; the build did not run")
            throw ArgumentParser.ExitCode(XcblameExit.internalError.rawValue)
        }
        if !global.quiet {
            for why in selection.left { writeStderr("note: --overlay leaves out \(why)") }
            for argument in OverlayDelivery.overridden(selection, arguments: xcodebuildArguments) {
                writeStderr("warning: \(argument) on the command line loses to the overlay's -xcconfig (probes Q1)")
            }
        }

        let file = OverlayDelivery.url(xcblameDir: stateURL, configuration: configuration)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(OverlayDelivery.text(selection).utf8).write(to: file, options: .atomic)
        let wrapper = try WrapperXCConfig.plan(arguments: xcodebuildArguments, environment: ProcessInfo.processInfo.environment,
                                               overlay: file, lines: [], xcblameDir: stateURL)
        try WrapperXCConfig.write(wrapper)

        // Oracle check (§7.5): the build's own arguments with the wrapper, the variable unset as for the build.
        let fake = ProcessInfo.processInfo.environment["XCBLAME_XCODEBUILD"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let derivedData = Self.argument("-derivedDataPath", in: xcodebuildArguments)
            .map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        let after = SettingsOracle.effective(withXCConfig: wrapper.url, arguments: wrapper.arguments, derivedData: derivedData,
                                             unsetEnvironment: wrapper.unsetEnvironment, executable: fake)
        var note = "overlay: \(plan.id) (\(selection.ruleIds.joined(separator: ", ")) for \(configuration) through the "
            + "-xcconfig wrapper)"
        if let settings = after.settings {
            let misses = OverlayDelivery.misses(selection, after: settings, plan: plan)
            guard misses.isEmpty else {
                for miss in misses { writeStderr("error: --overlay: a key did not win (\(miss))") }
                writeStderr("error: --overlay: the oracle shows the overlay does not reach every target (an unexpected "
                    + "precedence: please report it); the build did not run")
                throw ArgumentParser.ExitCode(XcblameExit.internalError.rawValue)
            }
            note += "; oracle check: every key won on \(settings.targets.count) target(s)"
        } else {
            note += "; oracle check skipped (\(after.note ?? "xcodebuild -showBuildSettings gave nothing"))"
        }
        if !global.quiet {
            writeStderr("note: --overlay: plan \(plan.id), " + selection.ruleIds.joined(separator: ", ") + " through "
                + wrapper.url.path)
        }
        Self.overlayRun = OverlayRun(planId: plan.id, ruleIds: selection.ruleIds, file: file, note: note)
        Self.deepUnsetEnvironment = wrapper.unsetEnvironment
        return wrapper.arguments
    }
}
