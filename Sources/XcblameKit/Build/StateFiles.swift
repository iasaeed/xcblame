import Foundation

/// Gzip a file with the system `gzip` (no new dependency; the inflate side reads it with `GzipFile`).
/// `-n` leaves the name and mtime out of the header, so equal input gives equal bytes.
// ponytail: one process per file, fine for a few files per build; upgrade: zlib deflate in-process.
func gzip(_ source: URL, to destination: URL) throws {
    let fm = FileManager.default
    guard fm.createFile(atPath: destination.path, contents: nil) else {
        throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: destination.path])
    }
    let input = try FileHandle(forReadingFrom: source)
    let output = try FileHandle(forWritingTo: destination)
    defer {
        try? input.close()
        try? output.close()
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    process.arguments = ["-n", "-c"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        try? fm.removeItem(at: destination)
        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
    }
}

/// Folders of `<xcblame-dir>` that never belong in a commit (DESIGN §8.3). `baseline.json` and `config.json` (v0.4)
/// sit next to them and are meant to be committed, so the state folder does not ignore everything. `cache/` holds
/// the settings JSON (the oracle's heavy scratch lives in `OracleCache`, outside the repository); `tmp/` the wrapper
/// xcconfig of `build --deep` (v0.5, DESIGN §7.5); `plans/` the fix plans and `backup/` the bytes and `defaults`
/// values `fix` saved (v0.6, docs/SCHEMA-v0.6.md "Storage"). The overlay files stay committable.
let stateIgnoreLines = "history/\nsnapshots/\nreports/\nresults/\nlogs/\ncache/\ntmp/\nplans/\nbackup/\n"

/// What earlier versions wrote: upgraded in place.
let previousStateIgnores: Set<String> = ["*\n", "history/\nsnapshots/\nreports/\nresults/\nlogs/\n",
                                         "history/\nsnapshots/\nreports/\nresults/\nlogs/\ncache/\n",
                                         "history/\nsnapshots/\nreports/\nresults/\nlogs/\ncache/\ntmp/\n"]

/// Writes `<xcblame-dir>/.gitignore` with `stateIgnoreLines`. Best effort: a file someone edited is left alone, what
/// earlier versions wrote is upgraded, a failure is silent (the caller's own write reports real errors).
public func ensureStateIgnore(in xcblameDir: URL) {
    let file = xcblameDir.appendingPathComponent(".gitignore")
    if let existing = try? String(contentsOf: file, encoding: .utf8), !previousStateIgnores.contains(existing) { return }
    try? FileManager.default.createDirectory(at: xcblameDir, withIntermediateDirectories: true)
    try? Data(stateIgnoreLines.utf8).write(to: file)
}
