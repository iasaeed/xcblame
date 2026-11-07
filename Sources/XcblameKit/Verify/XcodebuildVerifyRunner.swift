import Foundation

// v0.6 lane B: the real `VerifyBuildRunning`: `XcodebuildRunner.run` (log capture, process wall, exit code), then the
// log through the model builder for the critical path, the executed task kinds per target and the built targets.
public struct XcodebuildVerifyRunner: VerifyBuildRunning {
    public var xcblameDir: URL
    /// `XCBLAME_XCODEBUILD` test hook; nil runs `xcrun xcodebuild`.
    public var executable: URL?
    /// Stops the running xcodebuild on SIGINT/SIGTERM (`VerifyInterrupt.onRaise`).
    public var cancel: XcodebuildRunner.Cancel?

    public init(xcblameDir: URL, executable: URL?, cancel: XcodebuildRunner.Cancel? = nil) {
        self.xcblameDir = xcblameDir
        self.executable = executable
        self.cancel = cancel
    }

    public func build(_ build: VerifyBuild) throws -> VerifyBuildOutcome {
        var notes: [String] = []
        // `--max-minutes`: a timer stops the running xcodebuild tree through the `Cancel` when the budget runs out
        // (review minor 8; sticky, so the build after a stopped `clean` does not start either).
        let cancel = self.cancel ?? XcodebuildRunner.Cancel()
        let fired = Flag()
        var timer: DispatchWorkItem?
        if let deadline = build.deadline {
            let item = DispatchWorkItem {
                fired.set()
                cancel.terminate()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(0, deadline.timeIntervalSinceNow), execute: item)
            timer = item
        }
        defer { timer?.cancel() }
        if build.clean {
            let clean = try xcodebuild(WhyProcedure.withAction("clean", build.arguments), unset: build.unsetEnvironment,
                                       cancel: cancel)
            if fired.isSet { return VerifyBuildOutcome(exitCode: clean.exitCode, wall: nil, timedOut: true) }
            if clean.exitCode != 0 {
                return VerifyBuildOutcome(exitCode: clean.exitCode, wall: nil,
                                          notes: ["xcodebuild clean exited \(clean.exitCode) before run \(build.index)"])
            }
        }
        let result = try xcodebuild(build.arguments, unset: build.unsetEnvironment, cancel: cancel)
        notes += result.notes
        var outcome = VerifyBuildOutcome(exitCode: result.exitCode, wall: result.wall, notes: notes)
        if fired.isSet {
            outcome.timedOut = true
            return outcome
        }
        guard result.exitCode == 0 else { return outcome }
        guard let log = result.logURL else {
            outcome.notes.append("no build log: critical path, targets and task kinds unknown for this run")
            return outcome
        }
        do {
            let model = BuildModelBuilder.build(try SLFReader.read(url: log), reader: .slf)
            Self.read(model, wall: result.wall, into: &outcome)
        } catch {
            outcome.notes.append("build log unreadable (\(error)): critical path, targets and task kinds unknown")
        }
        return outcome
    }

    /// Critical path, task kinds, targets, Swift sources and Xcode of a run's model.
    static func read(_ model: BuildModel, wall: Double?, into outcome: inout VerifyBuildOutcome) {
        let counted = Timing.timeline(model).counted
        var kinds: [String: Int] = [:]
        var targets = Set<String>()
        var sources: [VerifyBuildOutcome.SwiftSource] = []
        for entry in counted {
            let target = entry.task.targetId.flatMap { $0 < model.targets.count ? model.targets[$0] : nil }
            let name = target?.name ?? "-"
            kinds["\(name)\t\(entry.task.ruleName)", default: 0] += 1
            if let target, !target.isBucket { targets.insert(target.name) }
            if let target, !target.isPackage, !target.isBucket, entry.task.kind == .swiftCompile {
                sources += FileAttribution.files(of: entry.task).filter { $0.hasSuffix(".swift") }
                    .map { .init(target: target.name, path: $0) }
            }
        }
        outcome.taskKinds = kinds
        outcome.targets = targets.sorted()
        outcome.swiftSources = sources
        outcome.xcode = XcodeVersionInference.infer(from: model)?.value
        let options = ReportPipeline.Options(topN: 1, processWall: wall)
        outcome.criticalPath = (try? ReportPipeline.run(model, options: options))?.document.criticalPath.map { Stats.round6($0.span) }
    }

    private func xcodebuild(_ arguments: [String], unset: [String], cancel: XcodebuildRunner.Cancel) throws
        -> XcodebuildRunner.Result {
        if let executable {
            return try XcodebuildRunner.run(arguments: arguments, xcblameDir: xcblameDir, timeout: nil,
                                            executable: executable, executablePrefix: [], unsetEnvironment: unset,
                                            cancel: cancel)
        }
        return try XcodebuildRunner.run(arguments: arguments, xcblameDir: xcblameDir, timeout: nil, unsetEnvironment: unset,
                                        cancel: cancel)
    }

    /// Set once from the timer's thread.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
}
