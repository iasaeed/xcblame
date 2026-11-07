import Foundation
import XCTest

/// A fake xcodebuild: a shell script that prints, sleeps 0.1 s, records its argv, then writes what a real build writes
/// into DerivedData (a build log copied from a fixture, a build description) and exits with a chosen code.
struct FakeXcodebuild {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/logs/cli-xcode26-dd")
    static let logUUID = "5E3BDB3A-008A-466D-A419-CB4D4E8CED29"
    static let signature = "05e6f8da62523e252c9ce2f537414df7"

    var script: URL
    var argvFile: URL
    var derivedData: URL

    /// `writeLog` / `writeDescription` false makes a build that leaves nothing behind (a failed build).
    /// `sleep` is the seconds the script waits before writing and exiting.
    /// `log` replaces the build log the script copies (default: the 5E3BDB3A fixture).
    static func make(in directory: URL, exitCode: Int32 = 0, writeLog: Bool = true, writeDescription: Bool = true,
                     sleep: String = "0.1", log: URL? = nil) throws -> FakeXcodebuild {
        let derivedData = directory.appendingPathComponent("dd")
        let argvFile = directory.appendingPathComponent("argv.txt")
        let script = directory.appendingPathComponent("fake-xcodebuild.sh")
        let build = derivedData.appendingPathComponent("Build/Intermediates.noindex/XCBuildData")
        var lines = [
            "#!/bin/sh",
            "echo 'fake xcodebuild stdout'",
            "echo 'fake xcodebuild stderr' >&2",
            "printf '%s\\n' \"$@\" > '\(argvFile.path)'",
            "sleep \(sleep)",
        ]
        if writeLog {
            lines += [
                "mkdir -p '\(derivedData.path)/Logs/Build'",
                "cp '\((log ?? fixtures.appendingPathComponent("\(logUUID).xcactivitylog")).path)' '\(derivedData.path)/Logs/Build/'",
            ]
        }
        if writeDescription {
            let description = "\(build.path)/\(signature).xcbuilddata"
            let source = fixtures.appendingPathComponent("xcbuilddata").path
            lines += [
                "mkdir -p '\(description)'",
                "gunzip -c '\(source)/manifest.json.gz' > '\(description)/manifest.json'",
                "cp '\(source)/target-graph.txt' '\(source)/build-request.json' '\(description)/'",
                "cp -R '\(source)/clangmodulesreport' '\(source)/swiftmodulesreport' '\(build.path)/'",
            ]
        }
        lines.append("exit \(exitCode)")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return FakeXcodebuild(script: script, argvFile: argvFile, derivedData: derivedData)
    }

    /// What the script was called with, one argument per line.
    func recordedArguments() throws -> [String] {
        try String(contentsOf: argvFile, encoding: .utf8).split(separator: "\n").map(String.init)
    }
}

extension XCTestCase {
    /// A fresh directory removed when the test ends.
    func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-laneb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            // A test may leave a read-only folder behind.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            try? FileManager.default.removeItem(at: url)
        }
        return url.resolvingSymlinksInPath()
    }
}
