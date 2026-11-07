import Foundation

/// Captured result of a subprocess run.
public struct ProcessOutput: Sendable {
    public var stdout: Data
    public var stderr: Data
    public var exitStatus: Int32
    public var timedOut: Bool

    public var succeeded: Bool { exitStatus == 0 && !timedOut }
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// System tools run by absolute path, so PATH shims (version managers, repo `bin/` dirs) cannot stand in for them.
let systemToolPaths: [String: String] = [
    "xcrun": "/usr/bin/xcrun", "xcodebuild": "/usr/bin/xcodebuild", "xcode-select": "/usr/bin/xcode-select",
    "sysctl": "/usr/sbin/sysctl", "sw_vers": "/usr/bin/sw_vers", "defaults": "/usr/bin/defaults",
    "pmset": "/usr/bin/pmset", "git": "/usr/bin/git", "tmutil": "/usr/bin/tmutil", "diskutil": "/usr/sbin/diskutil",
]

/// Runs `argv` (system tools by absolute path, anything else through `PATH` via `/usr/bin/env`), killing it after
/// `timeout` seconds.
/// Output goes to temp files, so a 13 MB `xcresulttool` log never blocks on a pipe. Nil when it cannot launch.
public func runProcess(_ argv: [String], timeout: TimeInterval) -> ProcessOutput? {
    guard !argv.isEmpty else { return nil }
    let fm = FileManager.default
    let id = UUID().uuidString
    let outURL = fm.temporaryDirectory.appendingPathComponent("xcblame-\(id).out")
    let errURL = fm.temporaryDirectory.appendingPathComponent("xcblame-\(id).err")
    guard fm.createFile(atPath: outURL.path, contents: nil), fm.createFile(atPath: errURL.path, contents: nil),
          let outHandle = try? FileHandle(forWritingTo: outURL),
          let errHandle = try? FileHandle(forWritingTo: errURL) else { return nil }
    defer {
        try? outHandle.close()
        try? errHandle.close()
        try? fm.removeItem(at: outURL)
        try? fm.removeItem(at: errURL)
    }

    let process = Process()
    if let tool = systemToolPaths[argv[0]] {
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = Array(argv.dropFirst())
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
    }
    process.standardOutput = outHandle
    process.standardError = errHandle
    process.standardInput = FileHandle.nullDevice
    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }
    do { try process.run() } catch { return nil }

    var timedOut = false
    if done.wait(timeout: .now() + timeout) == .timedOut {
        timedOut = true
        // Foundation.Process cannot spawn into its own process group, so the tree is collected before the kill: an
        // xcodebuild's build service or SwiftPM children must not outlive it (and write after the write guard ran).
        let children = descendants(of: process.processIdentifier)
        process.terminate()
        for pid in children { kill(pid, SIGTERM) }
        if done.wait(timeout: .now() + 1) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 1)
        }
        for pid in children { kill(pid, SIGKILL) }
        // Bounded wait for the exit to be recorded (the handler can run just before `isRunning` flips).
        var polls = 0
        while process.isRunning, polls < 50 {
            usleep(10_000)
            polls += 1
        }
    }
    let stdout = (try? Data(contentsOf: outURL)) ?? Data()
    let stderr = (try? Data(contentsOf: errURL)) ?? Data()
    // `terminationStatus` raises while the child still runs (e.g. stuck in uninterruptible I/O after SIGKILL).
    let status = process.isRunning ? -1 : process.terminationStatus
    return ProcessOutput(stdout: stdout, stderr: stderr, exitStatus: status, timedOut: timedOut)
}

/// Every process below `root`, from one `ps` snapshot (deepest last).
func descendants(of root: pid_t) -> [pid_t] {
    guard let out = runProcess(["/bin/ps", "-axo", "pid=,ppid="], timeout: 2), out.succeeded else { return [] }
    var children: [pid_t: [pid_t]] = [:]
    for line in out.stdoutString.split(separator: "\n") {
        let fields = line.split(separator: " ")
        guard fields.count == 2, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]) else { continue }
        children[parent, default: []].append(pid)
    }
    var found: [pid_t] = []
    var queue = children[root] ?? []
    while !queue.isEmpty {
        let next = queue.removeFirst()
        found.append(next)
        queue += children[next] ?? []
    }
    return found
}

/// One environment probe (DESIGN §5.9): trimmed stdout, or nil ("unknown") on launch failure, non-zero exit,
/// empty output or timeout.
public func runProbe(_ cmd: [String], timeout: TimeInterval = 2) -> String? {
    guard let out = runProcess(cmd, timeout: timeout), out.succeeded else { return nil }
    let text = out.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
    return text.isEmpty ? nil : text
}
