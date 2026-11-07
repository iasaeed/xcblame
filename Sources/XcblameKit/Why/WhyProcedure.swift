import Foundation

// v0.5 lane B (docs/SCHEMA-v0.5.md "why"): settle build, then a zero-change build (or `--touch`, then a build), with
// output hashes and DYN-002. Task Backtraces come from `EnableBuildBacktraceRecording=YES` in the xcodebuild
// environment of BOTH builds (probes-v0.5 §MV-2: works on Xcode 26 and 27, leaves no file behind, and the settle build
// must use the same mechanism as the measured one, or the switch itself changes task signatures). The temporary
// scheme copy of DESIGN §6.6 is not used.
public enum WhyProcedure {
    /// `build --kind`.
    public enum Kind: String, Sendable, CaseIterable {
        case clean, incremental
        case zeroChange = "zero-change"
    }

    public struct Options: Sendable {
        /// xcodebuild arguments after `--`.
        public var arguments: [String]
        public var xcblameDir: URL
        /// `--touch <file>`: settle, touch, build (mode `touch`); nil: settle, build (mode `zeroChange`).
        public var touch: String?
        public var showIncremental: Bool
        public var backtraces: Bool
        public var timeout: Double?
        /// `XCBLAME_XCODEBUILD` test hook (nil: `xcrun xcodebuild`).
        public var executable: URL?
        /// Variables removed from each xcodebuild's environment (`build --deep`: `XCODE_XCCONFIG_FILE` once the
        /// wrapper includes it).
        public var unsetEnvironment: [String] = []

        public init(arguments: [String], xcblameDir: URL, touch: String?, showIncremental: Bool, backtraces: Bool,
                    timeout: Double?, executable: URL?) {
            self.arguments = arguments
            self.xcblameDir = xcblameDir
            self.touch = touch
            self.showIncremental = showIncremental
            self.backtraces = backtraces
            self.timeout = timeout
            self.executable = executable
        }
    }

    /// One xcodebuild run of the procedure with what was read from it.
    public struct Step: Sendable {
        /// `settle` / `measure` / `repeat`.
        public var role: String
        public var build: XcodebuildRunner.Result
        public var model: BuildModel
        /// Output and input hashes taken right after this build (nil when nothing could be hashed).
        public var capture: OutputHashes.Capture?
        public var executedTasks: Int
        /// Executed compile, plan, emit-module and link tasks (`BuildKind.workKinds`).
        public var workTasks: [Int]
    }

    public struct Result: Sendable {
        /// Every xcodebuild run in order (settle, measure, and the DYN-002 repeat when it ran).
        public var builds: [XcodebuildRunner.Result]
        /// The measured build (its log is the one explained).
        public var measured: XcodebuildRunner.Result
        public var procedure: ReportDocument.Incremental.Procedure
        public var capture: OutputHashes.Capture?
        /// Two consecutive zero-change builds both executed compile or plan tasks.
        public var dyn002: Bool
        public var notes: [String]
        /// The builds with their models and captures, same order as `builds`.
        public var steps: [Step] = []

        public init(builds: [XcodebuildRunner.Result], measured: XcodebuildRunner.Result,
                    procedure: ReportDocument.Incremental.Procedure, capture: OutputHashes.Capture?, dyn002: Bool,
                    notes: [String]) {
            self.builds = builds
            self.measured = measured
            self.procedure = procedure
            self.capture = capture
            self.dyn002 = dyn002
            self.notes = notes
        }

        public func step(_ role: String) -> Step? { steps.first { $0.role == role } }
    }

    /// Why the procedure stopped; `xcblame why` exits 1 and names the build (docs/SCHEMA-v0.5.md "Exit codes").
    public enum ProcedureError: Error, Sendable, CustomStringConvertible {
        case buildFailed(role: String, exitCode: Int32)
        case timedOut(role: String)
        case noLog(role: String, notes: [String])
        case unreadableLog(role: String, why: String)

        public var description: String {
            switch self {
            case let .buildFailed(role, code): return "the \(role) build failed (xcodebuild exit code \(code)); why stopped"
            case let .timedOut(role): return "the \(role) build timed out (xcodebuild exit code "
                + "\(XcodebuildRunner.timeoutExitCode)); why stopped"
            case let .noLog(role, notes): return "the \(role) build wrote no build log; why stopped"
                + (notes.isEmpty ? "" : " (" + notes.joined(separator: "; ") + ")")
            case let .unreadableLog(role, why): return "the log of the \(role) build could not be read (\(why)); why stopped"
            }
        }
    }

    /// The environment variable that turns Task Backtraces on (MV-2).
    public static let backtraceVariable = "EnableBuildBacktraceRecording"

    /// Runs the procedure. A failed build aborts it (exit 1, docs/SCHEMA-v0.5.md "Exit codes").
    public static func run(_ options: Options) throws -> Result {
        var notes: [String] = []
        let arguments = options.showIncremental
            ? try withRemarkFlag(options.arguments, xcblameDir: options.xcblameDir) : options.arguments
        let touched = try options.touch.map(resolvedTouch)
        // The variable goes into each xcodebuild's own environment (`XcodebuildRunner.run(environment:)`); xcblame's
        // environment is never changed.
        if options.backtraces {
            notes.append("backtraces: \(backtraceVariable)=YES in the environment of every build of the procedure (MV-2)")
        }
        if options.showIncremental {
            let delivery = WrapperXCConfig.existing(in: options.arguments, xcblameDir: options.xcblameDir) == nil
                ? "on the command line" : "as a line of the xcblame wrapper xcconfig"
            notes.append("show-incremental: OTHER_SWIFT_FLAGS = $(inherited) -driver-show-incremental \(delivery) on every "
                + "build; the flag changes the Swift command lines, so the first run rebuilds Swift modules once")
        }

        var steps = [try step("settle", arguments: arguments, options: options)]
        if let touched {
            try touch(touched)
            notes.append("touch: mtime-only touch of \(touched.path) (content unchanged) before the measured build")
            notes.append(CauseEngine.touchNote)
        }
        steps.append(try step("measure", arguments: arguments, options: options))
        var dyn002 = false
        if touched == nil, !steps[1].workTasks.isEmpty {
            steps.append(try step("repeat", arguments: arguments, options: options))
            dyn002 = !steps[2].workTasks.isEmpty
            notes.append(dyn002
                ? "DYN-002: two zero-change builds in a row both executed compile or plan tasks"
                : "repeat: a second zero-change build executed no compile or plan task (the measured one settled late)")
        }
        let procedure = ReportDocument.Incremental.Procedure(
            mode: touched == nil ? "zeroChange" : "touch", touched: touched?.path,
            builds: steps.map { step in
                .init(role: step.role, exitCode: Int(step.build.exitCode), wall: ReportDocument.round6(step.build.wall),
                      executedTasks: step.executedTasks, executedWorkTasks: step.workTasks.count, historyId: nil)
            },
            backtraces: options.backtraces ? "on" : "off", showIncremental: options.showIncremental)
        var result = Result(builds: steps.map(\.build), measured: steps[1].build, procedure: procedure,
                            capture: steps[1].capture, dyn002: dyn002, notes: notes)
        result.steps = steps
        return result
    }

    /// `build --kind` / `--touch` preparation before the measured build: `clean` runs `xcodebuild clean` with the same
    /// arguments, `incremental` builds once then touches `touch` (required), `zero-change` builds once. A failed
    /// preparation build throws `ProcedureError`. `arguments` and `unsetEnvironment` are the measured build's own
    /// (under `build --deep`: the deep `-derivedDataPath` and wrapper), so the preparation acts on that DerivedData.
    /// `backtraces` puts `EnableBuildBacktraceRecording=YES` into the preparation build's environment, as `why` does.
    public static func prepare(kind: Kind?, touch: String?, arguments: [String], xcblameDir: URL, timeout: Double?,
                               executable: URL?, unsetEnvironment: [String] = [], backtraces: Bool = false) throws {
        let kind = kind ?? (touch == nil ? nil : .incremental)
        let touched = try touch.map(resolvedTouch)
        guard let kind else { return }
        var options = Options(arguments: arguments, xcblameDir: xcblameDir, touch: touch, showIncremental: false,
                              backtraces: backtraces, timeout: timeout, executable: executable)
        options.unsetEnvironment = unsetEnvironment
        switch kind {
        case .clean:
            let result = try xcodebuild(withAction("clean", arguments), options: options)
            try check(result, role: "clean")
        case .zeroChange, .incremental:
            let result = try xcodebuild(arguments, options: options)
            try check(result, role: "prepare")
            if kind == .incremental {
                guard let touched else { throw XcblameError.usage("--kind incremental needs --touch <file>") }
                try self.touch(touched)
            }
        }
    }

    // MARK: - Steps

    static func step(_ role: String, arguments: [String], options: Options) throws -> Step {
        let build = try xcodebuild(arguments, options: options)
        try check(build, role: role)
        guard let log = build.logURL else { throw ProcedureError.noLog(role: role, notes: build.notes) }
        let model: BuildModel
        do { model = BuildModelBuilder.build(try SLFReader.read(url: log), reader: .slf) } catch {
            throw ProcedureError.unreadableLog(role: role, why: "\(error)")
        }
        let counted = Timing.timeline(model).counted
        let work = counted.filter { BuildKind.workKinds.contains($0.task.kind) }.map(\.task.id)
        let capture = try? OutputHashes.capture(model: model, derivedData: build.derivedData ?? options.xcblameDir)
        return Step(role: role, build: build, model: model, capture: capture, executedTasks: counted.count,
                    workTasks: work)
    }

    static func xcodebuild(_ arguments: [String], options: Options) throws -> XcodebuildRunner.Result {
        let environment = options.backtraces ? [backtraceVariable: "YES"] : nil
        if let executable = options.executable {
            return try XcodebuildRunner.run(arguments: arguments, xcblameDir: options.xcblameDir, timeout: options.timeout,
                                            executable: executable, executablePrefix: [], environment: environment,
                                            unsetEnvironment: options.unsetEnvironment)
        }
        return try XcodebuildRunner.run(arguments: arguments, xcblameDir: options.xcblameDir, timeout: options.timeout,
                                        environment: environment, unsetEnvironment: options.unsetEnvironment)
    }

    static func check(_ result: XcodebuildRunner.Result, role: String) throws {
        if result.timedOut { throw ProcedureError.timedOut(role: role) }
        if result.exitCode != 0 { throw ProcedureError.buildFailed(role: role, exitCode: result.exitCode) }
    }

    // MARK: - Arguments and files

    /// xcodebuild actions; `withAction` replaces them.
    static let actions: Set<String> = ["build", "clean", "test", "archive", "analyze", "installsrc", "install",
                                       "build-for-testing", "test-without-building", "docbuild"]

    /// `arguments` with every action word replaced by `action` (appended once at the end). A flag of
    /// `booleanFlags` never takes the next word as its value (`-parallelizeTargets build` drops `build`); any other
    /// flag does (`-scheme build` keeps a scheme named `build`).
    static func withAction(_ action: String, _ arguments: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if word.hasPrefix("-") && !word.contains("=") {
                out.append(word)
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-"), !booleanFlags.contains(word) {
                    out.append(arguments[index + 1])
                    index += 1
                }
            } else if !actions.contains(word) {
                out.append(word)
            }
            index += 1
        }
        return out + [action]
    }

    /// xcodebuild flags without a value (`xcodebuild -help`, Xcode 26), so a word after one is an action or a setting.
    static let booleanFlags: Set<String> = [
        "-quiet", "-verbose", "-json", "-list", "-showsdks", "-showBuildSettings", "-showBuildSettingsForIndex",
        "-showdestinations", "-showTestPlans", "-showBuildTimingSummary", "-parallelizeTargets", "-dry-run",
        "-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "-skipPackagePluginValidation",
        "-skipMacroValidation", "-skipPackageSignatureValidation", "-disableAutomaticPackageResolution",
        "-skipPackageUpdates", "-skipUnavailableActions", "-onlyUsePackageVersionsFromResolvedFile",
        "-disablePackageRepositoryCache", "-hideShellScriptEnvironment", "-UseModernBuildSystem", "-usage", "-help",
        "-version", "-license", "-checkFirstLaunchStatus", "-runFirstLaunch", "-exportArchive", "-exportNotarizedApp",
        "-exportLocalizations", "-importLocalizations", "-create-xcframework", "-downloadAllPlatforms",
        "-downloadAllPreviouslySelectedPlatforms", "-enumerate-tests",
    ]

    /// `-driver-show-incremental` for every build of the procedure (v0.5 integration): a wrapper line when the
    /// arguments already pass an xcblame wrapper xcconfig (`WrapperXCConfig.existing`, e.g. the `--deep` one), so both
    /// sets of flags sit in one `$(inherited)` chain at one level; else on the command line (`withSwiftFlag`). On Xcode
    /// 26.0.1 both compose: the `-xcconfig` level sits above command-line `KEY=VALUE`, and its `$(inherited)` takes the
    /// command-line value (checked with `-showBuildSettings` on AcmeWhy).
    static func withRemarkFlag(_ arguments: [String], xcblameDir: URL) throws -> [String] {
        guard let wrapper = WrapperXCConfig.existing(in: arguments, xcblameDir: xcblameDir) else {
            return withSwiftFlag("-driver-show-incremental", arguments)
        }
        try WrapperXCConfig.append(["OTHER_SWIFT_FLAGS = $(inherited) -driver-show-incremental // xcblame why "
            + "--show-incremental"], to: wrapper)
        return arguments
    }

    /// `OTHER_SWIFT_FLAGS=$(inherited) <flag>` added to the command line, or `<flag>` appended to an existing
    /// `OTHER_SWIFT_FLAGS=…` setting (command-line settings win over every other level, and `$(inherited)` keeps them).
    static func withSwiftFlag(_ flag: String, _ arguments: [String]) -> [String] {
        var arguments = arguments
        if let index = arguments.firstIndex(where: { $0.hasPrefix("OTHER_SWIFT_FLAGS=") }) {
            if !arguments[index].contains(flag) { arguments[index] += " " + flag }
        } else {
            arguments.append("OTHER_SWIFT_FLAGS=$(inherited) " + flag)
        }
        return arguments
    }

    static func resolvedTouch(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw XcblameError.usage("--touch \(path): no such file")
        }
        return url
    }

    /// Sets the modification time to now; the content is not touched.
    static func touch(_ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
}
