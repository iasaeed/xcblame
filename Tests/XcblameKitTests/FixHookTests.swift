import XCTest
@testable import XcblameKit

/// `fix --install-hook` / `--uninstall-hook` on scratch copies of AcmeFixWin (docs/SCHEMA-v0.6.md "Hook"). The
/// verifier is injected or the offline resolver; no xcodebuild.
final class FixHookTests: XCTestCase {
    private let clean: HookInstaller.DirtyCheck = { _ in false }

    private func setup() throws -> (folder: URL, model: ProjectModel, dir: URL, debug: URL, original: Data) {
        let folder = try FixFixture.copy("AcmeFixWin", test: self)
        let model = try ProjectModel.load(container: FixFixture.container(folder), scheme: nil)
        let debug = folder.appendingPathComponent("Config/Debug.xcconfig")
        return (folder, model, folder.appendingPathComponent(".xcblame"), debug, try Data(contentsOf: debug))
    }

    private func overlay(_ dir: URL, value: String = "dwarf") throws {
        let text = OverlayFile.appending(planId: "aaaa0001", ruleId: "SET-004", lines: [
            OverlayFile.line(key: "DEBUG_INFORMATION_FORMAT", condition: nil, value: value, ruleId: "SET-004", planId: "aaaa0001"),
        ], to: nil, configuration: "Debug")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: OverlayFile.url(xcblameDir: dir, configuration: "Debug"))
    }

    func testInstallAppendsIncludeAsLastLineAndUninstallRestoresBytes() throws {
        let s = try setup()
        let release = s.folder.appendingPathComponent("Config/Release.xcconfig")
        let releaseOriginal = try Data(contentsOf: release)
        let outcomes = HookInstaller.install(project: s.model, configurations: ["Debug", "Release"], xcblameDir: s.dir,
                                             isDirty: clean, verify: { _, _, _, _ in nil })
        XCTAssertEqual(outcomes.map(\.status), [.installed, .installed], outcomes.map(\.message).joined(separator: "\n"))
        let text = try String(contentsOf: s.debug, encoding: .utf8)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.suffix(3), [HookInstaller.marker, "#include? \"../.xcblame/overlay-Debug.xcconfig\"", ""],
                       "the include is the last line, path relative to Config/")
        // Exactly two lines appended (fix round 1): the marker comment and the #include?.
        XCTAssertEqual(text, String(decoding: s.original, as: UTF8.self) + HookInstaller.marker + "\n"
            + "#include? \"../.xcblame/overlay-Debug.xcconfig\"\n")
        XCTAssertEqual(HookInstaller.marker, "// xcblame hook (fix --install-hook); remove with: xcblame fix --uninstall-hook")
        XCTAssertFalse(text.contains("#include \"../.xcblame"), "never a plain #include")
        let records = Backups.hooks(xcblameDir: s.dir)
        XCTAssertEqual(records.map(\.path), ["Config/Debug.xcconfig", "Config/Release.xcconfig"])
        XCTAssertEqual(records.first?.originalSHA256, Backups.sha256(s.original))
        XCTAssertEqual(try Data(contentsOf: s.dir.appendingPathComponent(records[0].backup)), s.original)
        XCTAssertEqual(HookInstaller.states(project: s.model, configurations: ["Debug"], xcblameDir: s.dir).first?.status,
                       "installed")
        XCTAssertEqual(HookInstaller.install(project: s.model, configurations: ["Debug"], xcblameDir: s.dir, isDirty: clean,
                                             verify: { _, _, _, _ in nil }).map(\.status), [.alreadyInstalled])
        XCTAssertTrue(HookInstaller.notLast(project: s.model, configurations: ["Debug"], xcblameDir: s.dir).isEmpty)

        let removed = HookInstaller.uninstall(project: s.model, configurations: ["Debug", "Release"], xcblameDir: s.dir)
        XCTAssertEqual(removed.map(\.status), [.uninstalled, .uninstalled])
        XCTAssertEqual(try Data(contentsOf: s.debug), s.original, "byte-identical")
        XCTAssertEqual(try Data(contentsOf: release), releaseOriginal)
        XCTAssertTrue(Backups.hooks(xcblameDir: s.dir).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.dir.appendingPathComponent(records[0].backup).path))
    }

    func testUnterminatedLastLineGetsANewlineAndRoundTrips() throws {
        let s = try setup()
        let unterminated = s.original.dropLast()
        try Data(unterminated).write(to: s.debug)
        _ = HookInstaller.install(project: s.model, configurations: ["Debug"], xcblameDir: s.dir, isDirty: clean,
                                  verify: { _, _, _, _ in nil })
        XCTAssertTrue(try String(contentsOf: s.debug, encoding: .utf8).contains("VALIDATE_PRODUCT = NO\n" + HookInstaller.marker))
        _ = HookInstaller.uninstall(project: s.model, configurations: ["Debug"], xcblameDir: s.dir)
        XCTAssertEqual(try Data(contentsOf: s.debug), Data(unterminated))
    }

    func testLinesAddedAfterTheHookWarnAndUninstallRemovesTheHookTextually() throws {
        let s = try setup()
        _ = HookInstaller.install(project: s.model, configurations: ["Debug"], xcblameDir: s.dir, isDirty: clean,
                                  verify: { _, _, _, _ in nil })
        let edited = try String(contentsOf: s.debug, encoding: .utf8) + "SWIFT_VERSION = 6.0\n"
        try Data(edited.utf8).write(to: s.debug)
        XCTAssertEqual(HookInstaller.notLast(project: s.model, configurations: ["Debug"], xcblameDir: s.dir),
                       ["Config/Debug.xcconfig"])
        let outcome = try XCTUnwrap(HookInstaller.uninstall(project: s.model, configurations: ["Debug"], xcblameDir: s.dir).first)
        XCTAssertEqual(outcome.status, .uninstalled)
        XCTAssertTrue(outcome.message.contains("kept as edited"))
        XCTAssertEqual(try String(contentsOf: s.debug, encoding: .utf8),
                       String(decoding: s.original, as: UTF8.self) + "SWIFT_VERSION = 6.0\n")
    }

    func testHookLinesRemovedByHandFailUninstall() throws {
        let s = try setup()
        _ = HookInstaller.install(project: s.model, configurations: ["Debug"], xcblameDir: s.dir, isDirty: clean,
                                  verify: { _, _, _, _ in nil })
        try Data((String(decoding: s.original, as: UTF8.self) + "// edited\n").utf8).write(to: s.debug)
        let outcome = try XCTUnwrap(HookInstaller.uninstall(project: s.model, configurations: ["Debug"], xcblameDir: s.dir).first)
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(outcome.isFailure)
        XCTAssertEqual(Backups.hooks(xcblameDir: s.dir).count, 1, "the record stays")
    }

    func testDirtyFileIsRefused() throws {
        let s = try setup()
        let outcome = try XCTUnwrap(HookInstaller.install(project: s.model, configurations: ["Debug"], xcblameDir: s.dir,
                                                          isDirty: { _ in true }, verify: { _, _, _, _ in nil }).first)
        XCTAssertEqual(outcome.status, .refused)
        XCTAssertTrue(outcome.message.contains("commit first"))
        XCTAssertEqual(try Data(contentsOf: s.debug), s.original)
    }

    func testVerifierFailureRestoresTheBackup() throws {
        let s = try setup()
        try overlay(s.dir)
        let outcome = try XCTUnwrap(HookInstaller.install(
            project: s.model, configurations: ["Debug"], xcblameDir: s.dir, isDirty: clean,
            verify: { _, target, configuration, key in
                XCTAssertEqual([target, configuration, key], ["AcmeFixWin", "Debug", "DEBUG_INFORMATION_FORMAT"])
                return "dwarf-with-dsym"
            }).first)
        XCTAssertEqual(outcome.status, .failed)
        XCTAssertTrue(outcome.message.contains("did not reach AcmeFixWin"), outcome.message)
        XCTAssertEqual(try Data(contentsOf: s.debug), s.original)
        XCTAssertTrue(Backups.hooks(xcblameDir: s.dir).isEmpty)
    }

    func testOfflineVerifierSeesTheOverlayThroughTheHook() throws {
        let s = try setup()
        try overlay(s.dir)
        let outcomes = HookInstaller.install(project: s.model, configurations: ["Debug"], xcblameDir: s.dir, isDirty: clean,
                                             verify: HookInstaller.offlineVerifier(container: FixFixture.container(s.folder)))
        XCTAssertEqual(outcomes.map(\.status), [.installed], outcomes.map(\.message).joined(separator: "\n"))
        let model = try ProjectModel.load(container: FixFixture.container(s.folder), scheme: nil)
        XCTAssertEqual(OfflineResolver.resolve(project: model, configuration: "Debug").targets["AcmeFixWin"]?["DEBUG_INFORMATION_FORMAT"],
                       "dwarf", "the overlay wins over the base xcconfig's own line")
        XCTAssertEqual(SettingsOracle.provenance(project: model, target: "AcmeFixWin", key: "DEBUG_INFORMATION_FORMAT",
                                                 configuration: "Debug").file, ".xcblame/overlay-Debug.xcconfig")
    }

    func testUnavailableConfigurationReportsWhy() throws {
        let s = try setup()
        var bare = s.model
        bare.projects[0].projectXCConfig["Release"] = nil
        let outcomes = HookInstaller.install(project: bare, configurations: ["Release"], xcblameDir: s.dir, isDirty: clean,
                                             verify: { _, _, _, _ in nil })
        XCTAssertEqual(outcomes.map(\.status), [.unavailable])
        XCTAssertTrue(outcomes[0].message.contains("no project-level base xcconfig"))
        XCTAssertFalse(outcomes[0].isFailure)
        XCTAssertEqual(HookInstaller.uninstall(project: s.model, configurations: ["Debug"], xcblameDir: s.dir).map(\.status),
                       [.notInstalled])
    }

    // MARK: - Fix round 1

    /// Review M1: a symlinked base xcconfig is edited at its target (the link survives), the include path is relative
    /// to the link's folder (where Xcode resolves includes, probe 2026-11-06), both paths are recorded, and uninstall
    /// restores the target byte-identical.
    func testSymlinkedBaseXCConfigIsEditedAtItsTarget() throws {
        let s = try setup()
        let fm = FileManager.default
        let shared = s.folder.appendingPathComponent("shared")
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        let real = shared.appendingPathComponent("Debug.real.xcconfig")
        try fm.moveItem(at: s.debug, to: real)
        try fm.createSymbolicLink(atPath: s.debug.path, withDestinationPath: "../shared/Debug.real.xcconfig")
        let model = try ProjectModel.load(container: FixFixture.container(s.folder), scheme: nil)
        let outcome = try XCTUnwrap(HookInstaller.install(project: model, configurations: ["Debug"], xcblameDir: s.dir,
                                                          isDirty: clean, verify: { _, _, _, _ in nil }).first)
        XCTAssertEqual(outcome.status, .installed, outcome.message)
        XCTAssertTrue(FixPaths.isSymlink(s.debug), "the link is still a link")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: s.debug.path), "../shared/Debug.real.xcconfig")
        XCTAssertEqual(try String(contentsOf: real, encoding: .utf8), String(decoding: s.original, as: UTF8.self)
            + HookInstaller.marker + "\n#include? \"../.xcblame/overlay-Debug.xcconfig\"\n",
                       "include relative to Config/ (the link's folder), written into the target")
        let record = try XCTUnwrap(Backups.hooks(xcblameDir: s.dir).first)
        XCTAssertEqual(record.path, "shared/Debug.real.xcconfig")
        XCTAssertEqual(record.link, "Config/Debug.xcconfig")
        XCTAssertEqual(HookInstaller.states(project: model, configurations: ["Debug"], xcblameDir: s.dir).first?.status,
                       "installed")
        let removed = HookInstaller.uninstall(project: model, configurations: ["Debug"], xcblameDir: s.dir)
        XCTAssertEqual(removed.map(\.status), [.uninstalled], removed.map(\.message).joined())
        XCTAssertEqual(try Data(contentsOf: real), s.original, "byte-identical")
        XCTAssertTrue(FixPaths.isSymlink(s.debug))
    }

    /// Review gap 3 / minor 4: in a teammate's clone (`backup/` is git-ignored, the hook lines are committed) uninstall
    /// removes exactly the two trailing hook lines; lines after them make it a hand edit (failed, nothing written).
    func testUninstallWithoutABackupRemovesTheTwoTrailingLines() throws {
        let s = try setup()
        _ = HookInstaller.install(project: s.model, configurations: ["Debug"], xcblameDir: s.dir, isDirty: clean,
                                  verify: { _, _, _, _ in nil })
        let hooked = try Data(contentsOf: s.debug)
        try FileManager.default.removeItem(at: Backups.directory(xcblameDir: s.dir))
        XCTAssertEqual(HookInstaller.states(project: s.model, configurations: ["Debug"], xcblameDir: s.dir).first?.status,
                       "installed")
        let removed = try XCTUnwrap(HookInstaller.uninstall(project: s.model, configurations: ["Debug"], xcblameDir: s.dir).first)
        XCTAssertEqual(removed.status, .uninstalled, removed.message)
        XCTAssertTrue(removed.message.contains("no local backup"))
        XCTAssertEqual(try Data(contentsOf: s.debug), s.original, "byte-identical: the two lines went")

        try (hooked + Data("SWIFT_VERSION = 6.0\n".utf8)).write(to: s.debug)
        let edited = try XCTUnwrap(HookInstaller.uninstall(project: s.model, configurations: ["Debug"], xcblameDir: s.dir).first)
        XCTAssertEqual(edited.status, .failed)
        XCTAssertTrue(edited.message.contains("by hand"), edited.message)
        XCTAssertEqual(try Data(contentsOf: s.debug), hooked + Data("SWIFT_VERSION = 6.0\n".utf8), "nothing written")
    }

    /// Review minor 3: the record is in hooks.json before the include is checked (an interrupted check can still be
    /// undone), and a failed check drops it.
    func testHookRecordIsSavedBeforeTheCheck() throws {
        let s = try setup()
        try overlay(s.dir)
        let dir = s.dir
        let outcome = try XCTUnwrap(HookInstaller.install(project: s.model, configurations: ["Debug"], xcblameDir: s.dir,
                                                          isDirty: clean, verify: { _, _, _, _ in
            XCTAssertEqual(Backups.hooks(xcblameDir: dir).map(\.path), ["Config/Debug.xcconfig"], "recorded first")
            return "dwarf"
        }).first)
        XCTAssertEqual(outcome.status, .installed, outcome.message)
        XCTAssertEqual(Backups.hooks(xcblameDir: s.dir).count, 1)
    }

    /// Review D/C: the xcodebuild verifier goes through the scratch-workspace oracle, so every call carries
    /// `-derivedDataPath` in the oracle cache (nothing under ~/Library/Developer).
    func testXcodebuildVerifierPassesADerivedDataPathInTheOracleCache() throws {
        let s = try setup()
        // Outside the project: the oracle denies writes below the project root (sandbox-exec).
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-verifier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        let cache = outside.appendingPathComponent("cache-home")
        let record = cache.appendingPathComponent("calls.txt")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let stub = outside.appendingPathComponent("stub-xcodebuild.sh")
        try Data("""
            #!/bin/sh
            for a in "$@"; do echo "$a" >> '\(record.path)'; done
            echo '[{"target":"AcmeFixWin","action":"build","buildSettings":{"PROJECT_NAME":"AcmeFixWin","DEBUG_INFORMATION_FORMAT":"dwarf"}}]'
            """.utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        let verifier = HookInstaller.xcodebuildVerifier(model: s.model, cacheHome: cache, xcodebuild: stub.path)
        XCTAssertEqual(verifier(s.model.projects[0], "AcmeFixWin", "Debug", "DEBUG_INFORMATION_FORMAT"), "dwarf")
        let argv = try String(contentsOf: record, encoding: .utf8).split(separator: "\n").map(String.init)
        let index = try XCTUnwrap(argv.firstIndex(of: "-derivedDataPath"), argv.joined(separator: " "))
        XCTAssertTrue(argv[index + 1].hasPrefix(cache.path + "/"), argv[index + 1])
        XCTAssertFalse(argv[index + 1].contains("Library/Developer"))
        XCTAssertTrue(argv.contains("-scheme") && argv.contains("-workspace"), "the generated scheme, not -project -target")
        XCTAssertFalse(argv.contains("-target"))
    }

    /// Fix round 2, nit 8: a file hooked in the pre-fix-round format is upgraded in place (no second hook), and the
    /// backup is the file without the old hook, so uninstall restores the original.
    func testLegacyHookIsUpgradedInPlace() throws {
        let s = try setup()
        let legacy = String(decoding: s.original, as: UTF8.self) + "\n" + HookInstaller.legacyMarker + "\n"
            + "#include? \"../.xcblame/overlay-Debug.xcconfig\"\n"
        try Data(legacy.utf8).write(to: s.debug)
        let outcome = try XCTUnwrap(HookInstaller.install(project: s.model, configurations: ["Debug"], xcblameDir: s.dir,
                                                          isDirty: clean, verify: { _, _, _, _ in nil }).first)
        XCTAssertEqual(outcome.status, .installed, outcome.message)
        XCTAssertTrue(outcome.message.contains("upgraded to the two-line format"), outcome.message)
        XCTAssertEqual(try String(contentsOf: s.debug, encoding: .utf8), String(decoding: s.original, as: UTF8.self)
            + HookInstaller.marker + "\n#include? \"../.xcblame/overlay-Debug.xcconfig\"\n")
        let record = try XCTUnwrap(Backups.hooks(xcblameDir: s.dir).first)
        XCTAssertEqual(try Data(contentsOf: s.dir.appendingPathComponent(record.backup)), s.original)
        _ = HookInstaller.uninstall(project: s.model, configurations: ["Debug"], xcblameDir: s.dir)
        XCTAssertEqual(try Data(contentsOf: s.debug), s.original)
    }

    /// Fix round 2, finding 6: hooking a file without a trailing newline does not change the project digest.
    func testProjectDigestIgnoresTheHookOnAnUnterminatedFile() throws {
        let s = try setup()
        try Data(s.original.dropLast()).write(to: s.debug)
        let model = try ProjectModel.load(container: FixFixture.container(s.folder), scheme: nil)
        let before = VerifyBasis.projectDigest(model, xcblameDir: s.dir)
        _ = HookInstaller.install(project: model, configurations: ["Debug"], xcblameDir: s.dir, isDirty: clean,
                                  verify: { _, _, _, _ in nil })
        XCTAssertNotEqual(try Data(contentsOf: s.debug), Data(s.original.dropLast()), "hooked")
        XCTAssertEqual(VerifyBasis.projectDigest(model, xcblameDir: s.dir), before)
        try Data((String(decoding: s.original, as: UTF8.self) + "SWIFT_VERSION = 6.0\n").utf8).write(to: s.debug)
        XCTAssertNotEqual(VerifyBasis.projectDigest(model, xcblameDir: s.dir), before, "a real edit still counts")
    }

    /// Fix round 3: the generated-scheme oracle reports ONLY_ACTIVE_ARCH = NO whatever the project says, so the hook
    /// check reads that key from the project files (an applied SET-005 overlay no longer fails `--install-hook`).
    func testOracleBlindKeyIsCheckedFromTheProjectFiles() throws {
        let s = try setup()
        let text = OverlayFile.appending(planId: "aaaa0005", ruleId: "SET-005", lines: [
            OverlayFile.line(key: "ONLY_ACTIVE_ARCH", condition: nil, value: "YES", ruleId: "SET-005", planId: "aaaa0005"),
        ], to: nil, configuration: "Debug")
        try FileManager.default.createDirectory(at: s.dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: OverlayFile.url(xcblameDir: s.dir, configuration: "Debug"))
        let outcome = try XCTUnwrap(HookInstaller.install(project: s.model, configurations: ["Debug"], xcblameDir: s.dir,
                                                          isDirty: clean, verify: { _, _, _, _ in "NO" }).first)
        XCTAssertEqual(outcome.status, .installed, outcome.message)
    }

    func testRelativePaths() {
        XCTAssertEqual(FixPaths.relative(to: URL(fileURLWithPath: "/r/.xcblame/overlay-Debug.xcconfig"),
                                         fromDirectory: URL(fileURLWithPath: "/r/Config")), "../.xcblame/overlay-Debug.xcconfig")
        XCTAssertEqual(FixPaths.relative(to: URL(fileURLWithPath: "/r/.xcblame/overlay-Debug.xcconfig"),
                                         fromDirectory: URL(fileURLWithPath: "/r")), ".xcblame/overlay-Debug.xcconfig")
        XCTAssertEqual(FixPaths.relative(to: URL(fileURLWithPath: "/r/.xcblame/o.xcconfig"),
                                         fromDirectory: URL(fileURLWithPath: "/r/a/b")), "../../.xcblame/o.xcconfig")
    }
}
