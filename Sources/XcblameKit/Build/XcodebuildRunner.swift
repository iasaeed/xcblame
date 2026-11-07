import Foundation

/// Runs xcodebuild for `xcblame build` (DESIGN §3.2): injects `-resultBundlePath` and `-showBuildTimingSummary`,
/// captures the log, snapshots the build description into `xcblameDir/snapshots/`. Lane B.
public enum XcodebuildRunner {
    public struct Result: Sendable {
        public var exitCode: Int32
        /// Process wall time in seconds.
        public var wall: Double
        public var derivedData: URL?
        public var logURL: URL?
        public var resultBundle: URL?
        /// `.xcblame/snapshots/<log-uuid>/`, when the build description was copied.
        public var snapshot: URL?
        /// What did not go as planned, one line each (a missing log, a skipped snapshot step, a timeout). Never fatal.
        public var notes: [String] = []
        /// `--timeout` fired and the process tree was killed; `exitCode` is then 124.
        public var timedOut = false
        /// `pmset -g therm` output before and after the build; nil when the probe failed.
        public var thermalBefore: String?
        public var thermalAfter: String?
        /// The `.xcodebuild.log` the output was tee'd into.
        public var capturedOutput: URL?
    }

    public enum RunError: Error, Sendable, CustomStringConvertible {
        case launchFailed(String)

        public var description: String {
            switch self {
            case let .launchFailed(why): return "could not run xcodebuild: \(why)"
            }
        }
    }

    public static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    /// Exit code for a build stopped by `--timeout`, as `timeout(1)` does. xcblame's own 6 is reserved for `verify`.
    public static let timeoutExitCode: Int32 = 124

    /// `executable` + `executablePrefix` + `arguments` is the argv; the defaults are `/usr/bin/xcrun xcodebuild ...`.
    /// Tests pass a fake xcodebuild script and an empty prefix. `environment` is merged over this process's
    /// environment for the child only, and `unsetEnvironment` names variables removed from it after the merge
    /// (`XCODE_XCCONFIG_FILE` once the wrapper includes it); xcblame's own environment is never changed.
    /// `cancel` (v0.6 verify): `Cancel.terminate()` from another thread stops the running xcodebuild tree, and any
    /// later launch through the same `Cancel`.
    public static func run(arguments: [String], xcblameDir: URL, timeout: Double?,
                           executable: URL = xcrun, executablePrefix: [String] = ["xcodebuild"],
                           environment: [String: String]? = nil, unsetEnvironment: [String] = [],
                           cancel: Cancel? = nil) throws -> Result {
        let fm = FileManager.default
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
        var notes: [String] = []

        // Capture folders. A failure here never stops the build: it only loses the tee and the injected bundle.
        var captureReady = true
        do {
            for sub in ["logs", "results"] {
                try fm.createDirectory(at: xcblameDir.appendingPathComponent(sub), withIntermediateDirectories: true)
            }
            ensureStateIgnore(in: xcblameDir)
        } catch {
            captureReady = false
            notes.append("cannot create \(xcblameDir.path) (\(error.localizedDescription)); the build output is not "
                + "captured and no result bundle is injected")
        }

        let stamp = timestamp(Date())
        var arguments = arguments
        var resultBundle: URL?
        if let given = value(of: "-resultBundlePath", in: arguments) {
            resultBundle = absolute(given, relativeTo: cwd)
        } else if captureReady {
            let bundle = uniqueURL(xcblameDir.appendingPathComponent("results/\(stamp)"), pathExtension: "xcresult")
            arguments += ["-resultBundlePath", bundle.path]
            resultBundle = bundle
        }
        if !arguments.contains("-showBuildTimingSummary") { arguments.append("-showBuildTimingSummary") }

        var capturedOutput: URL?
        var logHandle: FileHandle?
        if captureReady {
            let url = uniqueURL(xcblameDir.appendingPathComponent("logs/\(stamp).xcodebuild"), pathExtension: "log")
            if fm.createFile(atPath: url.path, contents: nil), let handle = try? FileHandle(forWritingTo: url) {
                capturedOutput = url
                logHandle = handle
            } else {
                notes.append("cannot write \(url.path); the build output is not captured")
            }
        }

        // Stream stdout and stderr through unchanged, copying both into the log in arrival order.
        let tee = Tee(log: logHandle)
        let outPipe = Pipe()
        let errPipe = Pipe()
        let eof = DispatchGroup()
        attach(outPipe, to: FileHandle.standardOutput, tee: tee, eof: eof)
        attach(errPipe, to: FileHandle.standardError, tee: tee, eof: eof)

        let process = Process()
        process.executableURL = executable
        process.arguments = executablePrefix + arguments
        process.standardOutput = outPipe
        process.standardError = errPipe
        if environment != nil || !unsetEnvironment.isEmpty {
            process.environment = childEnvironment(ProcessInfo.processInfo.environment, merging: environment ?? [:],
                                                   unsetting: unsetEnvironment)
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        let thermalBefore = ThermalProbe.capture()
        let started = Date()
        let clock = DispatchTime.now()
        do { try process.run() } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            try? logHandle?.close()
            throw RunError.launchFailed("\(executable.path): \(error.localizedDescription)")
        }
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        cancel?.attach(process)
        defer { cancel?.detach() }

        var timedOut = false
        if let timeout {
            if exited.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                killTree(process, exited: exited)
            }
        } else {
            exited.wait()
        }
        let wall = Double(DispatchTime.now().uptimeNanoseconds - clock.uptimeNanoseconds) / 1e9

        // A daemon xcodebuild left behind can keep the pipes open: wait a moment for EOF, then stop reading.
        if eof.wait(timeout: .now() + 1) == .timedOut { notes.append("output pipes stayed open after xcodebuild exited") }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        try? logHandle?.close()
        let thermalAfter = ThermalProbe.capture()
        if let thermal = ThermalProbe.note(before: thermalBefore, after: thermalAfter) { notes.append(thermal) }

        var exitCode: Int32
        if timedOut {
            exitCode = timeoutExitCode
            notes.append("timeout: xcodebuild was stopped after \(timeout ?? 0) s (exit code \(timeoutExitCode))")
        } else {
            exitCode = process.terminationReason == .uncaughtSignal
                ? 128 + process.terminationStatus : process.terminationStatus
        }

        var result = Result(exitCode: exitCode, wall: wall, resultBundle: resultBundle, notes: notes,
                            timedOut: timedOut, thermalBefore: thermalBefore, thermalAfter: thermalAfter,
                            capturedOutput: capturedOutput)
        collect(into: &result, arguments: arguments, cwd: cwd, started: started, xcblameDir: xcblameDir)
        return result
    }

    /// `base` with `overrides` merged over it, then every `unset` name removed (v0.5 integration).
    static func childEnvironment(_ base: [String: String], merging overrides: [String: String],
                                 unsetting unset: [String]) -> [String: String] {
        var environment = base.merging(overrides) { _, new in new }
        for name in unset { environment[name] = nil }
        return environment
    }

    // MARK: - After the build

    /// DerivedData, the log this build wrote and the snapshot. Every step may fail; none fails the build.
    private static func collect(into result: inout Result, arguments: [String], cwd: URL, started: Date,
                                xcblameDir: URL) {
        let fm = FileManager.default
        guard let derivedData = derivedData(arguments: arguments, cwd: cwd, notes: &result.notes) else { return }
        result.derivedData = derivedData

        let logs = derivedData.appendingPathComponent("Logs/Build")
        let candidates = entries(in: logs).filter { $0.url.pathExtension == "xcactivitylog" }
        if let log = candidates.filter({ $0.modified >= started }).max(by: { $0.modified < $1.modified }) {
            result.logURL = log.url
        } else {
            result.notes.append("no .xcactivitylog written since the build started in \(logs.path) ("
                + (candidates.isEmpty ? "none there" : "\(candidates.count) older ones ignored") + ")")
        }

        guard let log = result.logURL else {
            result.notes.append("no build description snapshot: it is named after the build log")
            return
        }
        let descriptions = derivedData.appendingPathComponent("Build/Intermediates.noindex/XCBuildData")
        let all = entries(in: descriptions).filter { $0.url.pathExtension == "xcbuilddata" && $0.isDirectory }
        guard let newest = all.max(by: { $0.modified < $1.modified }) else {
            result.notes.append("no build description snapshot: no .xcbuilddata in \(descriptions.path)")
            return
        }
        // The log names its own description; mtime picks another scheme's or destination's when the build reused
        // its description (every incremental build), so it is only the fallback.
        let signature = logSignature(log)
        let source: Entry
        if let signature, let own = all.first(where: { $0.url.lastPathComponent == signature + ".xcbuilddata" }) {
            source = own
            if own.modified < started {
                result.notes.append("build description \(own.url.lastPathComponent) predates this build (the build "
                    + "reused it); matched by the log's signature")
            }
        } else {
            let fresh = all.filter { $0.modified >= started }.max(by: { $0.modified < $1.modified })
            source = fresh ?? newest
            result.notes.append((signature.map { "no \($0).xcbuilddata in \(descriptions.path)" }
                ?? "the log names no build description signature") + ": snapshot picked by modification time")
            if fresh == nil {
                result.notes.append("build description may predate this build (\(newest.url.lastPathComponent) was "
                    + "not written during it; the build reused it)")
            }
        }
        let name = log.deletingPathExtension().lastPathComponent
        let destination = xcblameDir.appendingPathComponent("snapshots/\(name)")
        do {
            try? fm.removeItem(at: destination)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            ensureStateIgnore(in: xcblameDir)
            copySnapshot(from: source.url, siblings: descriptions, to: destination, notes: &result.notes)
            result.snapshot = destination
        } catch {
            result.notes.append("build description snapshot failed: \(error.localizedDescription)")
        }
    }

    /// The log's build description signature (`BuildDescriptionLocator.signature(of:)`); nil when it does not decode.
    // ponytail: decodes the log once more (BuildCommand decodes it again for the report); fine for one log per build.
    static func logSignature(_ log: URL) -> String? {
        guard let raw = try? SLFReader.read(url: log) else { return nil }
        return BuildDescriptionLocator.signature(of: BuildModelBuilder.build(raw, reader: .slf))
    }

    /// manifest.json -> manifest.json.gz, the two small files and both modules-report folders, as the fixture layout.
    // ponytail: the modules reports (a CSV per module, small) are copied as they are, not gzipped; upgrade: gzip each
    // CSV when snapshot size matters.
    private static func copySnapshot(from description: URL, siblings: URL, to destination: URL, notes: inout [String]) {
        let fm = FileManager.default
        func step(_ what: String, _ body: () throws -> Void) {
            do { try body() } catch { notes.append("snapshot: \(what) failed: \(error.localizedDescription)") }
        }
        let manifest = description.appendingPathComponent("manifest.json")
        let manifestGz = destination.appendingPathComponent("manifest.json.gz")
        if fm.fileExists(atPath: manifest.path) {
            step("manifest.json") { try gzip(manifest, to: manifestGz) }
        } else if fm.fileExists(atPath: description.appendingPathComponent("manifest.json.gz").path) {
            step("manifest.json.gz") {
                try fm.copyItem(at: description.appendingPathComponent("manifest.json.gz"), to: manifestGz)
            }
        } else {
            notes.append("snapshot: no manifest.json in \(description.lastPathComponent)")
        }
        for file in ["target-graph.txt", "build-request.json"] {
            let from = description.appendingPathComponent(file)
            guard fm.fileExists(atPath: from.path) else {
                notes.append("snapshot: no \(file) in \(description.lastPathComponent)")
                continue
            }
            step(file) { try fm.copyItem(at: from, to: destination.appendingPathComponent(file)) }
        }
        for report in ["clangmodulesreport", "swiftmodulesreport"] {
            // Written next to the descriptions (DESIGN §5.11); the description folder itself is the fallback.
            let candidates = [siblings.appendingPathComponent(report), description.appendingPathComponent(report)]
            guard let from = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else { continue }
            step(report) { try fm.copyItem(at: from, to: destination.appendingPathComponent(report)) }
        }
        step("SIGNATURE") {
            try Data((description.lastPathComponent + "\n").utf8).write(to: destination.appendingPathComponent("SIGNATURE"))
        }
    }

    /// `-derivedDataPath`, else the project's DerivedData by `info.plist` `WorkspacePath` (DerivedDataLocator).
    private static func derivedData(arguments: [String], cwd: URL, notes: inout [String]) -> URL? {
        if let given = value(of: "-derivedDataPath", in: arguments) {
            return absolute(given, relativeTo: cwd)
        }
        let container = (value(of: "-workspace", in: arguments) ?? value(of: "-project", in: arguments))
            .map { absolute($0, relativeTo: cwd) }
        let resolution: DerivedDataResolution?
        if let container {
            resolution = DerivedDataLocator(workspace: container).locate()
        } else {
            resolution = DerivedDataLocator.locateProject(in: cwd)
        }
        guard let resolution else {
            notes.append("no project or workspace in \(cwd.path) and no -project/-workspace/-derivedDataPath: "
                + "cannot find DerivedData")
            return nil
        }
        guard let derivedData = resolution.derivedData else {
            notes.append(resolution.failureDescription)
            return nil
        }
        return derivedData
    }

    // MARK: - Process plumbing

    /// Both pipes feed this one object, so the log is written in the order the bytes arrived.
    private final class Tee: @unchecked Sendable {
        private let lock = NSLock()
        private let log: FileHandle?

        init(log: FileHandle?) { self.log = log }

        func write(_ data: Data, to destination: FileHandle) {
            lock.lock()
            defer { lock.unlock() }
            try? destination.write(contentsOf: data)
            try? log?.write(contentsOf: data)
        }
    }

    private static func attach(_ pipe: Pipe, to destination: FileHandle, tee: Tee, eof: DispatchGroup) {
        eof.enter()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                eof.leave()
                return
            }
            tee.write(data, to: destination)
        }
    }

    /// SIGTERM to xcodebuild and everything below it, SIGKILL after 5 s.
    // ponytail: the tree is found with a `ps` snapshot, not a process group, so a Ctrl-C still reaches xcodebuild
    // through xcblame's own group; upgrade: posix_spawn with POSIX_SPAWN_SETPGROUP and kill(-pgid).
    private static func killTree(_ process: Process, exited: DispatchSemaphore) {
        let pids = descendants(of: process.processIdentifier) + [process.processIdentifier]
        for pid in pids { kill(pid, SIGTERM) }
        if exited.wait(timeout: .now() + 5) == .timedOut {
            for pid in pids { kill(pid, SIGKILL) }
            _ = exited.wait(timeout: .now() + 5)
        }
    }

    /// Stops a running xcodebuild from another thread (SIGTERM forwarded by `verify`): the tree gets SIGTERM, then
    /// SIGKILL after 5 s. Sticky: a launch after `terminate()` is stopped at once.
    public final class Cancel: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        public init() {}

        func attach(_ process: Process) {
            lock.lock()
            self.process = process
            let stop = cancelled
            lock.unlock()
            if stop { Self.stopTree(process) }
        }

        func detach() {
            lock.lock()
            process = nil
            lock.unlock()
        }

        /// Returns once the running process (if any) exited or was killed.
        public func terminate() {
            lock.lock()
            cancelled = true
            let running = process
            lock.unlock()
            if let running { Self.stopTree(running) }
        }

        /// Polls `isRunning` instead of waiting on the run's semaphore, which only one waiter may take.
        private static func stopTree(_ process: Process) {
            let pids = descendants(of: process.processIdentifier) + [process.processIdentifier]
            for pid in pids { kill(pid, SIGTERM) }
            for _ in 0..<50 where process.isRunning { usleep(100_000) }
            if process.isRunning { for pid in pids { kill(pid, SIGKILL) } }
        }
    }

    private static func descendants(of root: pid_t) -> [pid_t] {
        guard let out = runProcess(["/bin/ps", "-axo", "pid=,ppid="], timeout: 2), out.succeeded else { return [] }
        var children: [pid_t: [pid_t]] = [:]
        for line in out.stdoutString.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count == 2, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else { continue }
            children[parent, default: []].append(pid)
        }
        var found: [pid_t] = []
        var queue = children[root] ?? []
        while let next = queue.popLast() {
            found.append(next)
            queue += children[next] ?? []
        }
        return found
    }

    // MARK: - Small helpers

    private struct Entry {
        var url: URL
        var modified: Date
        var isDirectory: Bool
    }

    private static func entries(in directory: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let modified = values.contentModificationDate else { return nil }
            return Entry(url: url, modified: modified, isDirectory: values.isDirectory ?? false)
        }
    }

    static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    private static func absolute(_ path: String, relativeTo base: URL) -> URL {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath, relativeTo: base).standardizedFileURL
    }

    /// `yyyyMMdd-HHmmss` in local time, the file-name stamp of logs, result bundles and history entries.
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// `base.ext`, or `base-2.ext`, `base-3.ext` ... when that exists (two builds in one second).
    private static func uniqueURL(_ base: URL, pathExtension: String) -> URL {
        var url = base.appendingPathExtension(pathExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = URL(fileURLWithPath: base.path + "-\(counter)").appendingPathExtension(pathExtension)
            counter += 1
        }
        return url
    }
}
