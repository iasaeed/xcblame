import XCTest
@testable import XcblameKit

/// The overlay file and the `fix --apply` / `--revert` rules (docs/SCHEMA-v0.6.md "Overlay file", "`fix --apply`
/// rules"): byte-exact round trips, idempotence, key ownership, hand edits.
final class FixOverlayTests: XCTestCase {
    private func dir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-overlay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func step(_ rule: String, plan: String, lines: [(String, String, String)], status: FixPlanDocument.VerifyStatus = .kept,
                      verifyOnly: Bool = false) -> FixPlanDocument.Step {
        FixPlanDocument.Step(
            order: 1, ruleId: rule, title: rule, fixKind: .overlay, mechanism: .hook, confidence: "high", verifyOnly: verifyOnly,
            overlay: lines.map { configuration, key, value in
                .init(configuration: configuration, key: key, value: value,
                      line: OverlayFile.line(key: key, condition: nil, value: value, ruleId: rule, planId: plan))
            },
            verify: .init(status: status, mechanism: .hook),
            commands: ["xcblame verify --rules \(rule) --kind clean --mechanism hook"])
    }

    private func plan(_ id: String, _ steps: [FixPlanDocument.Step]) -> FixPlanDocument {
        var plan = FixApply.placeholder(id)
        plan.steps = steps
        return plan
    }

    func testBlockFormatMatchesTheContract() throws {
        let text = OverlayFile.appending(planId: "7f3a91c2", ruleId: "SET-004",
                                         lines: ["DEBUG_INFORMATION_FORMAT = dwarf // xcblame SET-004 (plan 7f3a91c2)"],
                                         to: nil, configuration: "Debug")
        let lines = text.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("// xcblame overlay for configuration Debug."))
        XCTAssertTrue(lines[1].hasPrefix("// "))
        XCTAssertTrue(lines[2].hasPrefix("// "))
        XCTAssertEqual(Array(lines[3...]), ["", "// xcblame plan 7f3a91c2 rule SET-004",
                                            "DEBUG_INFORMATION_FORMAT = dwarf // xcblame SET-004 (plan 7f3a91c2)",
                                            "// end xcblame plan 7f3a91c2 rule SET-004", ""])
        let blocks = try OverlayFile.blocks(in: text, path: "x")
        XCTAssertEqual(blocks.map(\.planId), ["7f3a91c2"])
        XCTAssertEqual(blocks.first?.lines, ["DEBUG_INFORMATION_FORMAT = dwarf // xcblame SET-004 (plan 7f3a91c2)"])
        XCTAssertEqual(OverlayFile.key(of: "KEY[sdk=iphonesimulator*] = YES // x"), "KEY")
        XCTAssertNil(OverlayFile.key(of: "// comment = no"))
    }

    func testApplyThenRevertIsByteIdenticalAndDeletesACreatedFile() throws {
        let dir = try dir()
        let plan = plan("aaaa0001", [step("SET-004", plan: "aaaa0001", lines: [("Debug", "DEBUG_INFORMATION_FORMAT", "dwarf")]),
                                     step("SET-030", plan: "aaaa0001", lines: [("Debug", "ENABLE_USER_SCRIPT_SANDBOXING", "YES"),
                                                                               ("Release", "ENABLE_USER_SCRIPT_SANDBOXING", "YES")])])
        let applied = FixApply.apply(plan, root: dir, xcblameDir: dir, forceUnverified: false, now: Date())
        XCTAssertFalse(applied.failed, applied.messages.joined(separator: "\n"))
        XCTAssertEqual(applied.plan.steps.map(\.state), [.applied, .applied])
        XCTAssertEqual(applied.files, ["overlay-Debug.xcconfig", "overlay-Release.xcconfig"])
        XCTAssertEqual(applied.plan.events.map(\.action), ["apply"])
        let debug = try String(contentsOf: OverlayFile.url(xcblameDir: dir, configuration: "Debug"), encoding: .utf8)
        XCTAssertEqual(try OverlayFile.blocks(in: debug, path: "d").map(\.ruleId), ["SET-004", "SET-030"])

        // Idempotent: applying the same plan again writes nothing.
        let again = FixApply.apply(applied.plan, root: dir, xcblameDir: dir, forceUnverified: false, now: Date())
        XCTAssertTrue(again.files.isEmpty)
        XCTAssertEqual(try String(contentsOf: OverlayFile.url(xcblameDir: dir, configuration: "Debug"), encoding: .utf8), debug)

        let reverted = FixApply.revert(planId: "aaaa0001", plan: applied.plan, root: dir, xcblameDir: dir,
                                       runner: FakeDefaults(), now: Date())
        XCTAssertFalse(reverted.failed)
        XCTAssertEqual(reverted.plan.steps.map(\.state), [.reverted, .reverted])
        XCTAssertTrue(OverlayFile.all(xcblameDir: dir).isEmpty, "files apply created are deleted")
    }

    func testRevertKeepsOtherPlansBytesExactly() throws {
        let dir = try dir()
        let url = OverlayFile.url(xcblameDir: dir, configuration: "Debug")
        // A file with another plan's block and no trailing newline on a hand-written comment first.
        let before = OverlayFile.appending(planId: "bbbb0002", ruleId: "SET-011", lines: [
            OverlayFile.line(key: "VALIDATE_PRODUCT", condition: nil, value: "NO", ruleId: "SET-011", planId: "bbbb0002"),
        ], to: nil, configuration: "Debug") + "// a teammate's comment"
        try Data(before.utf8).write(to: url)
        let mine = plan("aaaa0001", [step("SET-004", plan: "aaaa0001", lines: [("Debug", "DEBUG_INFORMATION_FORMAT", "dwarf")])])
        XCTAssertFalse(FixApply.apply(mine, root: dir, xcblameDir: dir, forceUnverified: false, now: Date()).failed)
        XCTAssertNotEqual(try Data(contentsOf: url), Data(before.utf8))
        XCTAssertFalse(FixApply.revert(planId: "aaaa0001", plan: nil, root: dir, xcblameDir: dir, runner: FakeDefaults(),
                                       now: Date()).failed)
        XCTAssertEqual(try Data(contentsOf: url), Data(before.utf8), "byte-identical after apply then revert")
    }

    func testKeyOwnedByAnotherPlanIsSkipped() throws {
        let dir = try dir()
        let first = plan("aaaa0001", [step("SET-004", plan: "aaaa0001", lines: [("Debug", "DEBUG_INFORMATION_FORMAT", "dwarf")])])
        _ = FixApply.apply(first, root: dir, xcblameDir: dir, forceUnverified: false, now: Date())
        let second = plan("cccc0003", [step("SET-004", plan: "cccc0003", lines: [("Debug", "DEBUG_INFORMATION_FORMAT", "dwarf")])])
        let result = FixApply.apply(second, root: dir, xcblameDir: dir, forceUnverified: false, now: Date())
        XCTAssertEqual(result.plan.steps[0].state, .skipped)
        XCTAssertEqual(result.plan.steps[0].stateReason, "key DEBUG_INFORMATION_FORMAT is set by plan aaaa0001 (SET-004) in "
            + "overlay-Debug.xcconfig: xcblame fix --revert aaaa0001 first")
        XCTAssertTrue(result.messages.contains { $0.hasPrefix("nothing written: every overlay step was skipped") },
                      result.messages.joined(separator: "\n"))
        XCTAssertTrue(result.plan.events.isEmpty)
    }

    func testApplyRulesVerifyStatesAndForceUnverified() {
        func reason(_ status: FixPlanDocument.VerifyStatus, verifyOnly: Bool = false, force: Bool = false) -> String? {
            FixApply.skipReason(step("SET-004", plan: "p", lines: [], status: status, verifyOnly: verifyOnly), forceUnverified: force)
        }
        XCTAssertNil(reason(.kept))
        XCTAssertEqual(reason(.unverified), "not verified yet: xcblame verify --rules SET-004 --kind clean --mechanism hook, or "
            + "pass --force-unverified")
        XCTAssertNil(reason(.unverified, force: true))
        XCTAssertTrue(reason(.unverified, verifyOnly: true, force: true)?.hasPrefix("+V rule") == true)
        XCTAssertTrue(reason(.indicative, force: true)?.contains("indicative") == true)
        // Review B: a reverted step names its verdict and date, not "verify first".
        var reverted = step("SET-004", plan: "p", lines: [], status: .reverted)
        reverted.verify.reason = .withinNoise
        reverted.verify.verifiedAt = Date(timeIntervalSince1970: 1_793_880_000)
        let text = FixApply.skipReason(reverted, forceUnverified: true) ?? ""
        XCTAssertTrue(text.hasPrefix("SET-004 was reverted (within noise) on 2026-11-0"), text)
        XCTAssertTrue(text.hasSuffix(": not applied; re-verify with xcblame verify --rules SET-004 --kind clean --mechanism hook"),
                      text)
    }

    func testKeptThroughCLIIsRecordedAppliedCLIUnlessScopesAgree() throws {
        var kept = step("SET-004", plan: "p", lines: [("Debug", "DEBUG_INFORMATION_FORMAT", "dwarf")])
        kept.verify.mechanism = .cli
        kept.scope = [
            .init(target: "App", configuration: "Debug", key: "DEBUG_INFORMATION_FORMAT", before: "dwarf-with-dsym",
                  after: "dwarf", provenance: nil, mechanism: .hook, reached: true),
            .init(target: "App", configuration: "Debug", key: "DEBUG_INFORMATION_FORMAT", before: "dwarf-with-dsym",
                  after: "dwarf", provenance: nil, mechanism: .cli, reached: true),
            .init(target: "Pkg", configuration: "Debug", key: "DEBUG_INFORMATION_FORMAT", before: "dwarf-with-dsym",
                  after: "dwarf", provenance: nil, mechanism: .cli, reached: true),
        ]
        XCTAssertNil(FixApply.skipReason(kept, forceUnverified: false))
        XCTAssertTrue(FixApply.deliversThroughCLI(kept), "kept through cli, scopes differ: build --overlay delivers it")
        let dir = try dir()
        let result = FixApply.apply(plan("p", [kept]), root: dir, xcblameDir: dir, forceUnverified: false, now: Date())
        XCTAssertEqual(result.plan.steps[0].state, .appliedCLI)
        XCTAssertTrue(result.files.isEmpty && result.plan.events.isEmpty, "nothing written")
        XCTAssertTrue(OverlayFile.all(xcblameDir: dir).isEmpty)
        XCTAssertTrue(result.messages.contains {
            $0.contains("recorded applied-cli") && $0.contains("xcblame build --overlay p -- -scheme <scheme> -configuration Debug build")
        }, result.messages.joined(separator: "\n"))
        kept.scope.removeLast()
        XCTAssertFalse(FixApply.deliversThroughCLI(kept), "identical reached rows: the hook delivers the same")

        // A step planned cli (fully hook-shadowed, CI) with --force-unverified: applied-cli with --overlay-unverified.
        var planned = step("SET-016", plan: "p", lines: [("Debug", "OTHER_SWIFT_FLAGS", "$(inherited) -foo")], status: .unverified)
        planned.mechanism = .cli
        let forced = FixApply.apply(plan("p", [planned]), root: dir, xcblameDir: dir, forceUnverified: true, now: Date())
        XCTAssertEqual(forced.plan.steps[0].state, .appliedCLI)
        XCTAssertTrue(forced.plan.steps[0].stateReason?.contains("xcblame build --overlay p --overlay-unverified --") == true)
        XCTAssertTrue(OverlayFile.all(xcblameDir: dir).isEmpty, "the hook cannot reach a cli step: nothing in the overlay")
    }

    /// Fix round 2, finding 4: `fix --revert` moves `applied-cli` steps to `reverted` (nothing to remove from a file),
    /// so `build --overlay` stops delivering them; `newestApplied` finds such a plan.
    func testRevertMovesAppliedCLIStepsToReverted() throws {
        let dir = try dir()
        var cli = step("SET-016", plan: "aaaa0001", lines: [("Debug", "OTHER_SWIFT_FLAGS", "$(inherited) -foo")])
        cli.state = .appliedCLI
        cli.mechanism = .cli
        cli.verify.mechanism = .cli
        var mine = plan("aaaa0001", [cli])
        mine.generatedAt = Date()
        try FixPlanStore.save(mine, xcblameDir: dir)
        XCTAssertEqual(FixApply.newestApplied(xcblameDir: dir)?.id, "aaaa0001")
        XCTAssertNil(OverlayDelivery.leftOut(cli, unverified: false), "delivered while applied-cli")
        let reverted = FixApply.revert(planId: "aaaa0001", plan: mine, root: dir, xcblameDir: dir, runner: FakeDefaults(), now: Date())
        XCTAssertFalse(reverted.failed)
        XCTAssertEqual(reverted.plan.steps[0].state, .reverted)
        XCTAssertEqual(reverted.plan.events.last?.ruleIds, ["SET-016"])
        XCTAssertTrue(reverted.messages.contains { $0.contains("no longer delivers") }, reverted.messages.joined())
        XCTAssertEqual(OverlayDelivery.leftOut(reverted.plan.steps[0], unverified: true), "reverted with xcblame fix --revert")
    }

    /// Fix round 2, finding 5: a step kept through hook goes through cli only when both scopes agree.
    func testKeptThroughHookIsDeliveredThroughCLIOnlyWhenScopesAgree() {
        var kept = step("SET-004", plan: "p", lines: [("Debug", "DEBUG_INFORMATION_FORMAT", "dwarf")])
        kept.scope = [
            .init(target: "App", configuration: "Debug", key: "DEBUG_INFORMATION_FORMAT", before: "dwarf-with-dsym",
                  after: "dwarf", provenance: nil, mechanism: .hook, reached: true),
            .init(target: "App", configuration: "Debug", key: "DEBUG_INFORMATION_FORMAT", before: "dwarf-with-dsym",
                  after: "dwarf", provenance: nil, mechanism: .cli, reached: true),
            .init(target: "Pkg", configuration: "Debug", key: "DEBUG_INFORMATION_FORMAT", before: "dwarf-with-dsym",
                  after: "dwarf", provenance: nil, mechanism: .cli, reached: true),
        ]
        XCTAssertTrue(OverlayDelivery.leftOut(kept, unverified: false)?.hasPrefix("kept through hook, but cli reaches other") == true)
        kept.scope.removeLast()
        XCTAssertNil(OverlayDelivery.leftOut(kept, unverified: false), "identical reached rows")
    }

    func testApplyWarnsWhenTheHookIsNotInstalled() throws {
        let dir = try dir()
        var mine = plan("aaaa0001", [step("SET-004", plan: "aaaa0001", lines: [("Debug", "DEBUG_INFORMATION_FORMAT", "dwarf")])])
        mine.hook = [.init(configuration: "Debug", status: "notInstalled", baseXCConfig: "Config/Debug.xcconfig", reason: nil)]
        let result = FixApply.apply(mine, root: dir, xcblameDir: dir, forceUnverified: false, now: Date())
        XCTAssertTrue(result.messages.contains { $0.hasPrefix("warning: the hook is not installed for Debug") },
                      result.messages.joined(separator: "\n"))
    }

    func testTemporaryVerifyBlocksAreSeenByApplyAndRevert() throws {
        let dir = try dir()
        let url = OverlayFile.url(xcblameDir: dir, configuration: "Debug")
        let committed = OverlayFile.header(configuration: "Debug")
        // What a SIGKILLed hook verify leaves: its temporary block, never restored.
        let left = VerifyOverlay.withTemporaryBlocks(committed, plan: "aaaa0001", configuration: "Debug", blocks: [
            (rule: "SET-004", lines: [OverlayFile.line(key: "DEBUG_INFORMATION_FORMAT", condition: nil, value: "dwarf",
                                                       ruleId: "SET-004", planId: "aaaa0001")]),
        ])
        try Data(left.utf8).write(to: url)
        let blocks = try OverlayFile.blocks(in: left, path: "d")
        XCTAssertEqual(blocks.map(\.temporary), [true])
        // Apply sees the key (conflict, never "already in the overlay").
        let mine = plan("aaaa0001", [step("SET-004", plan: "aaaa0001", lines: [("Debug", "DEBUG_INFORMATION_FORMAT", "dwarf")])])
        let applied = FixApply.apply(mine, root: dir, xcblameDir: dir, forceUnverified: false, now: Date())
        XCTAssertEqual(applied.plan.steps[0].state, .skipped)
        XCTAssertTrue(applied.plan.steps[0].stateReason?.contains("interrupted verify of plan aaaa0001") == true)
        // Revert removes it byte-exactly (the file held only the header before: apply never created it, so it stays).
        let reverted = FixApply.revert(planId: "aaaa0001", plan: nil, root: dir, xcblameDir: dir, runner: FakeDefaults(), now: Date())
        XCTAssertFalse(reverted.failed)
        XCTAssertTrue(reverted.messages.contains { $0.contains("temporary verify block(s) of SET-004") }, reverted.messages.joined())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "only the header was left: deleted")
    }

    func testBlocksWithoutTheBlankLineBetweenThemDoNotOverlap() throws {
        // Review minor 2: a hand edit removed the blank line between two blocks of one plan; removing both must not eat
        // the blank line before the comment that follows.
        let a = OverlayFile.line(key: "A", condition: nil, value: "1", ruleId: "SET-004", planId: "p")
        let b = OverlayFile.line(key: "B", condition: nil, value: "2", ruleId: "SET-011", planId: "p")
        let text = OverlayFile.header(configuration: "Debug") + "\n// xcblame plan p rule SET-004\n\(a)\n// end xcblame plan p rule SET-004\n"
            + "// xcblame plan p rule SET-011\n\(b)\n// end xcblame plan p rule SET-011\n\n// a teammate's note\n"
        let blocks = try OverlayFile.blocks(in: text, path: "x")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertLessThanOrEqual(blocks[0].range.upperBound, blocks[1].range.lowerBound)
        let removed = try OverlayFile.removing(planId: "p", from: text, configuration: "Debug", path: "x")
        XCTAssertEqual(removed.text, OverlayFile.header(configuration: "Debug") + "\n// a teammate's note\n")
        XCTAssertEqual(try VerifyOverlay.removingPlanBlocks(text, plan: "p", rules: ["SET-004", "SET-011"], file: "x"),
                       OverlayFile.header(configuration: "Debug") + "\n// a teammate's note\n")
    }

    func testHandEditedOverlayRefusesApplyAndRevert() throws {
        let dir = try dir()
        let url = OverlayFile.url(xcblameDir: dir, configuration: "Debug")
        let broken = OverlayFile.header(configuration: "Debug") + "\n// xcblame plan aaaa0001 rule SET-004\nDEBUG_INFORMATION_FORMAT = dwarf\n"
        try Data(broken.utf8).write(to: url)
        let mine = plan("aaaa0001", [step("SET-004", plan: "aaaa0001", lines: [("Debug", "DEBUG_INFORMATION_FORMAT", "dwarf")])])
        let applied = FixApply.apply(mine, root: dir, xcblameDir: dir, forceUnverified: false, now: Date())
        XCTAssertTrue(applied.failed)
        XCTAssertTrue(applied.messages.first?.contains("edited by hand") == true)
        let reverted = FixApply.revert(planId: "aaaa0001", plan: nil, root: dir, xcblameDir: dir, runner: FakeDefaults(), now: Date())
        XCTAssertTrue(reverted.failed)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), broken, "nothing written")
        XCTAssertThrowsError(try OverlayFile.blocks(in: "// end xcblame plan a rule B\n", path: "x"))
    }

    func testNewestAppliedSkipsRevertedPlans() throws {
        let dir = try dir()
        var appliedStep = step("SET-004", plan: "aaaa0001", lines: [])
        appliedStep.state = .applied
        var applied = plan("aaaa0001", [appliedStep])
        applied.generatedAt = Date(timeIntervalSince1970: 100)
        applied.events = [.init(at: Date(), action: "apply", ruleIds: ["SET-004"], files: [], defaultsKeys: [])]
        var revertedStep = appliedStep
        revertedStep.state = .reverted
        var reverted = plan("bbbb0002", [revertedStep])
        reverted.generatedAt = Date(timeIntervalSince1970: 200)
        reverted.events = applied.events + [.init(at: Date(), action: "revert", ruleIds: ["SET-004"], files: [], defaultsKeys: [])]
        try FixPlanStore.save(applied, xcblameDir: dir)
        try FixPlanStore.save(reverted, xcblameDir: dir)
        XCTAssertEqual(FixApply.newestApplied(xcblameDir: dir)?.id, "aaaa0001")
    }

    func testPartialAutoRevertKeepsTheOtherAppliedStepRevertable() throws {
        // Review minor 1: apply A and B, verify reverts A (auto-revert: A's block goes, a revert event names A only);
        // `fix --revert` without an id still finds the plan and removes B.
        let dir = try dir()
        let both = plan("aaaa0001", [step("SET-004", plan: "aaaa0001", lines: [("Debug", "DEBUG_INFORMATION_FORMAT", "dwarf")]),
                                     step("SET-011", plan: "aaaa0001", lines: [("Debug", "VALIDATE_PRODUCT", "NO")])])
        var applied = FixApply.apply(both, root: dir, xcblameDir: dir, forceUnverified: false, now: Date()).plan
        let url = OverlayFile.url(xcblameDir: dir, configuration: "Debug")
        let text = try String(contentsOf: url, encoding: .utf8)
        try Data(try VerifyOverlay.removingPlanBlocks(text, plan: "aaaa0001", rules: ["SET-004"], file: "d").utf8).write(to: url)
        applied.steps[0].state = .reverted
        applied.events.append(.init(at: Date(), action: "revert", ruleIds: ["SET-004"], files: [], defaultsKeys: []))
        try FixPlanStore.save(applied, xcblameDir: dir)
        let newest = try XCTUnwrap(FixApply.newestApplied(xcblameDir: dir))
        XCTAssertEqual(newest.id, "aaaa0001")
        let reverted = FixApply.revert(planId: newest.id, plan: newest, root: dir, xcblameDir: dir, runner: FakeDefaults(), now: Date())
        XCTAssertEqual(reverted.plan.steps.map(\.state), [.reverted, .reverted])
        XCTAssertTrue(OverlayFile.all(xcblameDir: dir).isEmpty)
    }
}
