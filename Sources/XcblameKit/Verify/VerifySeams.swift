import Foundation

// v0.6 lane B (docs/SCHEMA-v0.6.md "Verify document", DESIGN §7.8, §12 item 7): the two seams of the A/B harness. The
// harness never runs xcodebuild or reads the machine itself: `VerifyBuildRunning` builds, `VerifyHost` answers the
// precondition and clock questions, so tests script durations, noise, failures, thermal states and task-set changes.

/// One xcodebuild invocation the harness asks for.
public struct VerifyBuild: Sendable, Equatable {
    public var arm: VerifyDocument.Arm
    /// The DerivedData label: `A`, `B-<RULE>` or `B-batch`.
    public var label: String
    /// 1-based within the arm (settle and thermal replacements included).
    public var index: Int
    /// The unmeasured settle build of a non-clean kind.
    public var settle: Bool
    /// Run `xcodebuild clean` with the same arguments first (not timed): every `clean` kind run.
    public var clean: Bool
    /// The full xcodebuild arguments (`-derivedDataPath` and, under `cli`, the wrapper `-xcconfig` included).
    public var arguments: [String]
    /// Removed from the child's environment (`XCODE_XCCONFIG_FILE` once the wrapper includes it).
    public var unsetEnvironment: [String]
    public var derivedData: URL
    /// `--max-minutes` runs out at this time: the runner stops a build (or its `clean`) still running then and
    /// reports `timedOut`. Nil without `--max-minutes`.
    public var deadline: Date?

    public init(arm: VerifyDocument.Arm, label: String, index: Int, settle: Bool, clean: Bool, arguments: [String],
                unsetEnvironment: [String], derivedData: URL, deadline: Date? = nil) {
        self.arm = arm
        self.label = label
        self.index = index
        self.settle = settle
        self.clean = clean
        self.arguments = arguments
        self.unsetEnvironment = unsetEnvironment
        self.derivedData = derivedData
        self.deadline = deadline
    }
}

/// What one build gave the harness.
public struct VerifyBuildOutcome: Sendable, Equatable {
    public var exitCode: Int32
    /// Process wall seconds of the build (the clean before it excluded); nil when it did not run.
    public var wall: Double?
    /// Critical-path seconds of the build's log; nil when the log was not read.
    public var criticalPath: Double?
    /// Executed tasks per `target\tkind` (kind = the task's rule name, `GenerateDSYMFile`); nil when the log was not read.
    public var taskKinds: [String: Int]?
    /// Names of the targets that executed tasks; nil when the log was not read.
    public var targets: [String]?
    /// Swift sources the build compiled for project (non-package) targets, as `(target, absolute path)`; the
    /// `incremental` touch default comes from here.
    public var swiftSources: [SwiftSource]
    /// Inferred Xcode version of the log.
    public var xcode: String?
    public var notes: [String]
    /// The build was stopped at `VerifyBuild.deadline` (`--max-minutes` ran out): the harness aborts `timeout`.
    public var timedOut = false

    public struct SwiftSource: Sendable, Equatable {
        public var target: String
        public var path: String

        public init(target: String, path: String) {
            self.target = target
            self.path = path
        }
    }

    public init(exitCode: Int32, wall: Double?, criticalPath: Double? = nil, taskKinds: [String: Int]? = nil,
                targets: [String]? = nil, swiftSources: [SwiftSource] = [], xcode: String? = nil, notes: [String] = [],
                timedOut: Bool = false) {
        self.timedOut = timedOut
        self.exitCode = exitCode
        self.wall = wall
        self.criticalPath = criticalPath
        self.taskKinds = taskKinds
        self.targets = targets
        self.swiftSources = swiftSources
        self.xcode = xcode
        self.notes = notes
    }
}

/// Builds for the harness. The real one is `XcodebuildVerifyRunner`; a throw is an internal error (exit 1).
public protocol VerifyBuildRunning: Sendable {
    func build(_ build: VerifyBuild) throws -> VerifyBuildOutcome
}

/// The machine questions of the harness (preconditions, thermal state after each run, the clock, touching a file).
public protocol VerifyHost: Sendable {
    /// `ProcessInfo.thermalState` spelled `nominal`, `fair`, `serious`, `critical`.
    func thermalState() -> String
    /// True on battery, false on AC power, nil when unknown.
    func onBattery() -> Bool?
    /// Process ids of running `xcodebuild` processes other than xcblame's own children.
    func otherXcodebuilds() -> [Int32]
    /// Repository-relative paths among `files` with uncommitted changes (untracked included); nil when `directory`
    /// is not in a git work tree or git cannot run.
    func dirtyFiles(_ files: [URL], in directory: URL) -> [String]?
    /// The git work tree root containing `directory`; nil outside one.
    func repositoryRoot(of directory: URL) -> URL?
    func now() -> Date
    /// `Mac15,14/28c/96g`; nil when unknown.
    func machine() -> String?
    /// Sets `file`'s modification time to now (`why --touch` semantics: content unchanged).
    func touch(_ file: URL) throws
}

/// Raised by SIGINT/SIGTERM (or a test); the harness checks it around every build and aborts `interrupted`.
public final class VerifyInterrupt: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    private var signalName: String?
    private var handlers: [@Sendable () -> Void] = []

    public init() {}

    /// Runs `handler` on the first `raise` (at once when already raised), on the raising thread: `verify` stops the
    /// running xcodebuild this way before the overlay is restored.
    public func onRaise(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        let now = raised
        if !now { handlers.append(handler) }
        lock.unlock()
        if now { handler() }
    }

    public func raise(_ name: String = "SIGINT") {
        lock.lock()
        let first = !raised
        if first { signalName = name }
        raised = true
        let run = first ? handlers : []
        handlers = []
        lock.unlock()
        for handler in run { handler() }
    }

    public var isRaised: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }

    public var name: String? {
        lock.lock()
        defer { lock.unlock() }
        return signalName
    }
}

/// The machine as it is: `ProcessInfo`, `pmset`, `pgrep`, `git`.
public struct SystemVerifyHost: VerifyHost {
    public init() {}

    public func thermalState() -> String { Self.spelling(ProcessInfo.processInfo.thermalState) }

    static func spelling(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    public func onBattery() -> Bool? {
        guard let text = runProbe(["pmset", "-g", "batt"], timeout: 2) else { return nil }
        return Self.onBattery(pmset: text)
    }

    /// `Now drawing from 'Battery Power'` / `'AC Power'` (first line of `pmset -g batt`).
    static func onBattery(pmset text: String) -> Bool? {
        if text.contains("'Battery Power'") { return true }
        if text.contains("'AC Power'") || text.contains("'UPS Power'") { return false }
        return nil
    }

    public func otherXcodebuilds() -> [Int32] {
        guard let out = runProcess(["/usr/bin/pgrep", "-x", "xcodebuild"], timeout: 2), out.exitStatus == 0 else { return [] }
        let own = Set(descendants(of: getpid()))
        return out.stdoutString.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !own.contains($0) }
    }

    public func dirtyFiles(_ files: [URL], in directory: URL) -> [String]? {
        guard let root = repositoryRoot(of: directory) else { return nil }
        guard !files.isEmpty else { return [] }
        let paths = files.map(\.standardizedFileURL.path)
        guard let out = runProcess(["git", "-C", root.path, "--no-optional-locks", "status", "--porcelain",
                                    "--untracked-files=all", "--"] + paths, timeout: 10), out.succeeded else { return nil }
        return out.stdoutString.split(separator: "\n").map { String($0.dropFirst(3)) }
    }

    public func repositoryRoot(of directory: URL) -> URL? {
        guard let text = runProbe(["git", "-C", directory.path, "rev-parse", "--show-toplevel"], timeout: 5) else { return nil }
        return URL(fileURLWithPath: text).standardizedFileURL
    }

    public func now() -> Date { Date() }

    public func machine() -> String? {
        guard let model = runProbe(["sysctl", "-n", "hw.model"]), let cores = runProbe(["sysctl", "-n", "hw.ncpu"]),
              let memory = runProbe(["sysctl", "-n", "hw.memsize"]).flatMap({ Int64($0) }) else { return nil }
        return "\(model)/\(cores)c/\(memory >> 30)g"
    }

    public func touch(_ file: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }
}

/// `SystemVerifyHost` with the power, other-xcodebuild and thermal answers taken from `XCBLAME_VERIFY_HOST`
/// (`power=ac|battery|unknown,xcodebuild=none|<pid>,thermal=<state>`; any part may be left out) when set: the CLI tests'
/// hook, like `XCBLAME_XCODEBUILD`, so a test never depends on the machine it runs on.
public struct EnvironmentVerifyHost: VerifyHost {
    public var base: SystemVerifyHost
    public var overrides: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        base = SystemVerifyHost()
        overrides = [:]
        for part in (environment["XCBLAME_VERIFY_HOST"] ?? "").split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { overrides[pair[0]] = pair[1] }
        }
    }

    public func thermalState() -> String { overrides["thermal"] ?? base.thermalState() }

    public func onBattery() -> Bool? {
        switch overrides["power"] {
        case "ac": return false
        case "battery": return true
        case "unknown": return nil
        default: return base.onBattery()
        }
    }

    public func otherXcodebuilds() -> [Int32] {
        guard let value = overrides["xcodebuild"] else { return base.otherXcodebuilds() }
        return value == "none" ? [] : value.split(separator: " ").compactMap { Int32($0) }
    }

    public func dirtyFiles(_ files: [URL], in directory: URL) -> [String]? { base.dirtyFiles(files, in: directory) }
    public func repositoryRoot(of directory: URL) -> URL? { base.repositoryRoot(of: directory) }
    public func now() -> Date { base.now() }
    public func machine() -> String? { base.machine() }
    public func touch(_ file: URL) throws { try base.touch(file) }
}
