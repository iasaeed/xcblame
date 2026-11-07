import Foundation
import XCTest

/// Runs the built `xcblame` binary (it sits next to the test bundle); shared by the v0.4 CLI tests.
struct CLIRunner {
    struct Run {
        var status: Int32
        var out: String
        var err: String
    }

    let test: XCTestCase

    var binary: URL {
        Bundle(for: type(of: test)).bundleURL.deletingLastPathComponent().appendingPathComponent("xcblame")
    }

    func run(_ arguments: [String], environment overrides: [String: String] = [:]) throws -> Run {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["CI"] = nil
        env["NO_COLOR"] = "1"
        env["GITHUB_STEP_SUMMARY"] = nil
        // `history prune` and `doctor` touch the settings-oracle cache: a throwaway home per call, never ~/Library/Caches.
        let cacheHome = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cacheHome) }
        env["XCBLAME_CACHE_DIR"] = cacheHome.path
        env.merge(overrides) { $1 }
        process.environment = env
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        // Both pipes drain at once: a command that writes a lot to stderr (verify sends xcodebuild's output there)
        // would otherwise fill that pipe and block while stdout is read to its end.
        nonisolated(unsafe) var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, out: String(decoding: outData, as: UTF8.self),
                   err: String(decoding: errData, as: UTF8.self))
    }
}
