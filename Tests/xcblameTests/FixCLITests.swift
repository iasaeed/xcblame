import Foundation
import XCTest
import XcblameKit

/// `xcblame fix` (docs/SCHEMA-v0.6.md "`xcblame fix`"): every flag path, refusals and exit codes, on scratch copies
/// of `fixtures/projects/AcmeFixWin` with `--offline` (no xcodebuild) and `--rules` (no machine-dependent ENV rule
/// is ever written; `defaults write` never runs).
final class FixCLITests: XCTestCase {
    private var cli: CLIRunner { CLIRunner(test: self) }
    private static let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("fixtures/projects/AcmeFixWin")

    private struct Scratch {
        var folder: URL
        var project: String { folder.appendingPathComponent("AcmeFixWin.xcodeproj").path }
        var dir: URL { folder.appendingPathComponent(".xcblame") }
        var debug: URL { folder.appendingPathComponent("Config/Debug.xcconfig") }
        var overlay: URL { dir.appendingPathComponent("overlay-Debug.xcconfig") }
    }

    private func scratch() throws -> Scratch {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-fixcli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("AcmeFixWin")
        try FileManager.default.copyItem(at: Self.fixture, to: folder)
        return Scratch(folder: folder)
    }

    /// `fix` on the scratch project, offline, json unless `arguments` say otherwise.
    private func fix(_ s: Scratch, _ arguments: [String], format: String = "json") throws -> CLIRunner.Run {
        try cli.run(["fix", "--project", s.project, "--xcblame-dir", s.dir.path, "--offline", "--format", format] + arguments)
    }

    private func decode(_ run: CLIRunner.Run) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(run.out.utf8)) as? [String: Any], run.out + run.err)
    }

    private func steps(_ plan: [String: Any]) -> [[String: Any]] { plan["steps"] as? [[String: Any]] ?? [] }

    /// Sets the stored plan's step `rule` verify state as lane B's verify writes it (with its `basis`, fix round 1).
    private func markVerified(_ s: Scratch, id: String, rule: String, status: String, mechanism: String = "hook") throws {
        var plan = try FixPlanStore.load(id: id, xcblameDir: s.dir)
        let index = try XCTUnwrap(plan.steps.firstIndex { $0.ruleId == rule })
        let digest = VerifyBasis.projectDigest(container: plan.project.container, xcblameDir: s.dir)
        plan.steps[index].verify = .init(status: try XCTUnwrap(FixPlanDocument.VerifyStatus(rawValue: status)),
                                         mechanism: FixPlanDocument.Mechanism(rawValue: mechanism), kind: "clean",
                                         verifyId: "20261106-120000-verify", verifiedAt: Date(timeIntervalSince1970: 1_793_880_000),
                                         basis: VerifyBasis.value(step: plan.steps[index], container: plan.project.container,
                                                                  projectDigest: digest))
        try FixPlanStore.save(plan, xcblameDir: s.dir)
    }

    // MARK: - Parsing

    func testHelpListsFlags() throws {
        let help = try cli.run(["fix", "--help"])
        XCTAssertEqual(help.status, 0, help.err)
        for flag in ["--rules", "--apply", "--apply-defaults", "--force-unverified", "--install-hook", "--uninstall-hook",
                     "--revert", "<plan-id>", "--edit-project", "--plan-out", "--from", "--project", "--workspace",
                     "--configuration", "--offline", "--xcblame-dir", "--format", "--output", "--open"] {
            XCTAssertTrue(help.out.contains(flag), "\(flag) missing from fix --help:\n\(help.out)")
        }
        XCTAssertTrue(try cli.run(["--help"]).out.contains("fix"))
    }

    func testUsageErrorsExit2() throws {
        for arguments in [["fix", "--edit-project"], ["fix", "--apply", "--revert"], ["fix", "7f3a91c2"],
                          ["fix", "--force-unverified"], ["fix", "--format", "junit"], ["fix", "--rules", "NOPE-1"],
                          ["fix", "--uninstall-hook", "--install-hook"], ["fix", "--revert", "--apply-defaults"],
                          ["fix", "--project", "a.xcodeproj", "--workspace", "b.xcworkspace"]] {
            let run = try cli.run(arguments)
            XCTAssertEqual(run.status, 2, "\(arguments): \(run.err)")
            XCTAssertFalse(run.err.contains("not implemented"), "\(arguments): \(run.err)")
        }
        let edit = try cli.run(["fix", "--edit-project"])
        XCTAssertTrue(edit.err.contains("not part of xcblame 0.6"), edit.err)
    }

    func testMissingProjectExits5() throws {
        let missing = try cli.run(["fix", "--project", "/nonexistent/Acme.xcodeproj", "--offline"])
        XCTAssertEqual(missing.status, 5, missing.err)
    }

    // MARK: - Plan

    func testPlanPrintsStoresAndChangesNothing() throws {
        let s = try scratch()
        let before = try Data(contentsOf: s.debug)
        let out = s.folder.appendingPathComponent("plan.json")
        let run = try fix(s, ["--rules", "SET-004", "--plan-out", out.path])
        XCTAssertEqual(run.status, 0, run.err)
        let plan = try decode(run)
        XCTAssertEqual(plan["schemaVersion"] as? String, "xcblame.fixplan/1")
        let id = try XCTUnwrap(plan["id"] as? String)
        XCTAssertEqual(steps(plan).map { $0["ruleId"] as? String }, ["SET-004"])
        XCTAssertEqual(steps(plan).first?["mechanism"] as? String, "hook")
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.dir.appendingPathComponent("plans/\(id).json").path))
        let written = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any])
        XCTAssertEqual(written["id"] as? String, id)
        XCTAssertEqual(try Data(contentsOf: s.debug), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.overlay.path))

        let again = try decode(try fix(s, ["--rules", "SET-004"]))
        XCTAssertEqual(again["id"] as? String, id, "deterministic id")

        let text = try fix(s, ["--rules", "SET-004"], format: "text")
        XCTAssertEqual(text.status, 0, text.err)
        XCTAssertTrue(text.out.contains("fix plan \(id)"), text.out)
        XCTAssertTrue(text.out.contains("SET-004"), text.out)
        XCTAssertTrue(text.out.contains("nothing in the project changed"), text.out)
    }

    func testFromReportFileAndMissingFrom() throws {
        let s = try scratch()
        let report = s.folder.appendingPathComponent("doctor.json")
        let doctor = try cli.run(["doctor", "--project", s.project, "--offline", "--rules", "SET-004",
                                  "--xcblame-dir", s.dir.path, "--format", "json", "-o", report.path])
        XCTAssertEqual(doctor.status, 0, doctor.err)
        let from = try fix(s, ["--rules", "SET-004", "--from", report.path])
        XCTAssertEqual(from.status, 0, from.err)
        let generated = try XCTUnwrap(try decode(from)["generatedFrom"] as? [String: Any])
        XCTAssertEqual(generated["analysisPath"] as? String, report.standardizedFileURL.path)
        XCTAssertEqual(try fix(s, ["--from", "20990101-000000"]).status, 5)
    }

    // MARK: - Apply

    func testApplyNeedsVerifyOrForceAndRevertRoundTrips() throws {
        let s = try scratch()
        let unverified = try fix(s, ["--rules", "SET-004", "--apply"])
        XCTAssertEqual(unverified.status, 0, unverified.err)
        XCTAssertTrue(unverified.err.contains("not verified yet"), unverified.err)
        XCTAssertTrue(unverified.err.contains("nothing written: every overlay step was skipped"), unverified.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.overlay.path))
        XCTAssertEqual(steps(try decode(unverified)).first?["state"] as? String, "skipped")
        // Review B: a write flag that wrote nothing does not claim "the project changed".
        let text = try fix(s, ["--rules", "SET-004", "--apply"], format: "text")
        XCTAssertTrue(text.out.contains("nothing in the project changed"), text.out)
        XCTAssertFalse(text.out.contains("the project changed: see WRITES"), text.out)

        let forced = try fix(s, ["--rules", "SET-004", "--apply", "--force-unverified"])
        XCTAssertEqual(forced.status, 0, forced.err)
        let plan = try decode(forced)
        let id = try XCTUnwrap(plan["id"] as? String)
        XCTAssertEqual(steps(plan).first?["state"] as? String, "applied")
        XCTAssertEqual((plan["events"] as? [[String: Any]])?.last?["action"] as? String, "apply")
        let overlay = try String(contentsOf: s.overlay, encoding: .utf8)
        XCTAssertTrue(overlay.contains("// xcblame plan \(id) rule SET-004\nDEBUG_INFORMATION_FORMAT = dwarf "
            + "// xcblame SET-004 (plan \(id))\n// end xcblame plan \(id) rule SET-004\n"), overlay)

        let revert = try fix(s, ["--revert"])
        XCTAssertEqual(revert.status, 0, revert.err)
        XCTAssertTrue(revert.err.contains("removed SET-004 of plan \(id)"), revert.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.overlay.path), "apply created it, revert deletes it")
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: s.dir.appendingPathComponent(
            "plans/\(id).json"))) as? [String: Any])
        XCTAssertEqual(steps(stored).first?["state"] as? String, "reverted")
        XCTAssertTrue(try fix(s, ["--revert"]).err.contains("nothing to revert"))
    }

    func testKeptStepIsWrittenAndRevertById() throws {
        let s = try scratch()
        let id = try XCTUnwrap(try decode(try fix(s, ["--rules", "SET-004"]))["id"] as? String)
        try markVerified(s, id: id, rule: "SET-004", status: "kept")
        let apply = try fix(s, ["--rules", "SET-004", "--apply"])
        XCTAssertEqual(apply.status, 0, apply.err)
        XCTAssertTrue(apply.err.contains("wrote SET-004"), apply.err)
        XCTAssertEqual(steps(try decode(apply)).first?["verify"].flatMap { ($0 as? [String: Any])?["status"] as? String }, "kept")
        let byId = try fix(s, ["--revert", String(id.prefix(4))])
        XCTAssertEqual(byId.status, 0, byId.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.overlay.path))
    }

    func testRefusals() throws {
        let s = try scratch()
        let id = try XCTUnwrap(try decode(try fix(s, ["--rules", "SET-004"]))["id"] as? String)
        // Kept through cli while the cli rows have no oracle confirmation: --apply writes nothing into the overlay, records
        // the step applied-cli and prints the build --overlay command that delivers it (fix round 1, gap 1).
        try markVerified(s, id: id, rule: "SET-004", status: "kept", mechanism: "cli")
        let cli = try fix(s, ["--rules", "SET-004", "--apply"])
        XCTAssertEqual(cli.status, 0, cli.err)
        XCTAssertTrue(cli.err.contains("recorded applied-cli"), cli.err)
        XCTAssertTrue(cli.err.contains("xcblame build --overlay \(id) -- -scheme"), cli.err)
        XCTAssertTrue(cli.err.contains("-configuration Debug build"), cli.err)
        XCTAssertEqual(steps(try decode(cli)).first?["state"] as? String, "applied-cli")
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.overlay.path))
        // Reverted by verify: never written, not even with --force-unverified; the message names the verdict (review B).
        try markVerified(s, id: id, rule: "SET-004", status: "reverted")
        let reverted = try fix(s, ["--rules", "SET-004", "--apply", "--force-unverified"])
        XCTAssertTrue(reverted.err.contains("SET-004 was reverted on 2026-11-0"), reverted.err)
        XCTAssertTrue(reverted.err.contains("not applied; re-verify with xcblame verify --rules SET-004"), reverted.err)
        XCTAssertFalse(reverted.err.contains("verify first"), reverted.err)
        // +V rule: --force-unverified does not override it.
        XCTAssertTrue(try fix(s, ["--rules", "SET-016", "--apply", "--force-unverified"]).err.contains("+V rule"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.overlay.path))

        // A key another plan's block owns.
        try markVerified(s, id: id, rule: "SET-004", status: "kept")
        XCTAssertEqual(try fix(s, ["--rules", "SET-004", "--apply"]).status, 0)
        let other = try fix(s, ["--rules", "SET-004,SET-016", "--apply", "--force-unverified"])
        XCTAssertEqual(other.status, 0, other.err)
        XCTAssertTrue(other.err.contains("key DEBUG_INFORMATION_FORMAT is set by plan \(id)"), other.err)

        // A hand-edited overlay: --apply and --revert exit 1 and write nothing.
        let edited = try String(contentsOf: s.overlay, encoding: .utf8).replacingOccurrences(of: "// end xcblame plan", with: "// end")
        try Data(edited.utf8).write(to: s.overlay)
        let applyEdited = try fix(s, ["--rules", "SET-004,SET-016", "--apply", "--force-unverified"])
        XCTAssertEqual(applyEdited.status, 1, applyEdited.err)
        XCTAssertTrue(applyEdited.err.contains("edited by hand"), applyEdited.err)
        XCTAssertEqual(try fix(s, ["--revert", id]).status, 1)
        XCTAssertEqual(try String(contentsOf: s.overlay, encoding: .utf8), edited)
    }

    func testApplyDefaultsWithoutDefaultsStepIsANoOp() throws {
        let s = try scratch()
        let run = try fix(s, ["--rules", "SET-004", "--apply-defaults"])
        XCTAssertEqual(run.status, 0, run.err)
        XCTAssertTrue(run.err.contains("no defaults step"), run.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.dir.appendingPathComponent("backup/defaults.json").path))
    }

    // MARK: - Hook

    func testInstallHookWithApplyThenUninstallIsByteIdentical() throws {
        let s = try scratch()
        let debug = try Data(contentsOf: s.debug)
        let release = try Data(contentsOf: s.folder.appendingPathComponent("Config/Release.xcconfig"))
        let run = try fix(s, ["--rules", "SET-004", "--install-hook", "--apply", "--force-unverified"])
        XCTAssertEqual(run.status, 0, run.err)
        XCTAssertTrue(run.err.contains("hook appended to Config/Debug.xcconfig"), run.err)
        let lines = try String(contentsOf: s.debug, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(lines.dropLast().last, "#include? \"../.xcblame/overlay-Debug.xcconfig\"")
        let plan = try decode(run)
        XCTAssertEqual((plan["hook"] as? [[String: Any]])?.map { $0["status"] as? String }, ["installed", "installed"])
        XCTAssertEqual((plan["events"] as? [[String: Any]])?.map { $0["action"] as? String }, ["apply", "installHook"])

        let again = try fix(s, ["--install-hook"])
        XCTAssertTrue(again.err.contains("hook already in"), again.err)

        let undo = try fix(s, ["--revert", "--uninstall-hook"])
        XCTAssertEqual(undo.status, 0, undo.err)
        XCTAssertEqual(try Data(contentsOf: s.debug), debug)
        XCTAssertEqual(try Data(contentsOf: s.folder.appendingPathComponent("Config/Release.xcconfig")), release)
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.overlay.path))
    }

    func testInstallHookRefusesAFileWithUncommittedChanges() throws {
        let s = try scratch()
        func git(_ arguments: String...) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", s.folder.path, "-c", "user.name=Acme", "-c", "user.email=acme@example.com"] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }
        guard (try? git("init", "-q")) == 0 else { throw XCTSkip("git unavailable") }
        XCTAssertEqual(try git("add", "-f", "-A"), 0, "-f: a global excludes file may ignore *.xcconfig")
        XCTAssertEqual(try git("commit", "-qm", "fixture"), 0)
        let edited = try String(contentsOf: s.debug, encoding: .utf8) + "// local edit\n"
        try Data(edited.utf8).write(to: s.debug)
        let run = try fix(s, ["--rules", "SET-004", "--install-hook", "--configuration", "Debug"])
        XCTAssertEqual(run.status, 1, run.err)
        XCTAssertTrue(run.err.contains("commit first"), run.err)
        XCTAssertEqual(try String(contentsOf: s.debug, encoding: .utf8), edited)
    }

    func testUninstallWithoutHookIsANote() throws {
        let s = try scratch()
        let run = try fix(s, ["--uninstall-hook"])
        XCTAssertEqual(run.status, 0, run.err)
        XCTAssertTrue(run.err.contains("no xcblame hook recorded"), run.err)
    }
}
