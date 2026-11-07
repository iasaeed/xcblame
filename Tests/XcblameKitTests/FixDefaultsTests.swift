import Foundation
import XCTest
@testable import XcblameKit

/// An in-memory `defaults` domain: tests never run `defaults write`.
final class FakeDefaults: DefaultsRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: (type: String, value: String)]
    private(set) var calls: [String] = []
    var failWrites = false

    init(_ store: [String: (type: String, value: String)] = [:]) { self.store = store }

    func value(_ key: String) -> (type: String, value: String)? { lock.withLock { store[key] } }

    func read(domain: String, key: String) -> Backups.Prior {
        lock.withLock {
            store[key].map { Backups.Prior(exists: true, type: $0.type, value: $0.value) } ?? .absent
        }
    }

    func write(domain: String, key: String, type: String, value: String) throws {
        try lock.withLock {
            calls.append("write \(key) -\(type) \(value)")
            if failWrites { throw DefaultsApplier.Failure(description: "denied") }
            store[key] = (type, value)
        }
    }

    func delete(domain: String, key: String) throws {
        lock.withLock {
            calls.append("delete \(key)")
            store[key] = nil
        }
    }
}

/// `fix --apply-defaults` and its revert (docs/SCHEMA-v0.6.md "Defaults").
final class FixDefaultsTests: XCTestCase {
    private let key = "IDEBuildOperationMaxNumberOfConcurrentCompileTasks"

    private func dir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-defaults-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func plan(value: String? = nil, verifyOnly: Bool = false) -> FixPlanDocument {
        var plan = FixApply.placeholder("dddd0004")
        plan.steps = [FixPlanDocument.Step(
            order: 1, ruleId: "ENV-002", title: "cap", fixKind: .defaults, mechanism: .defaults, confidence: "medium",
            verifyOnly: verifyOnly, defaults: [.init(key: key, value: value, type: value == nil ? nil : "int")])]
        return plan
    }

    func testDeleteThenRevertRestoresThePriorValueAndType() throws {
        let dir = try dir()
        let runner = FakeDefaults([key: ("int", "4")])
        let applied = FixApply.applyDefaults(plan(), xcblameDir: dir, runner: runner, now: Date())
        XCTAssertFalse(applied.failed, applied.messages.joined(separator: "\n"))
        XCTAssertNil(runner.value(key), "deleted: default = cores")
        XCTAssertEqual(applied.plan.steps[0].state, .applied)
        XCTAssertEqual(applied.plan.events.map(\.action), ["applyDefaults"])
        XCTAssertEqual(applied.plan.events.first?.defaultsKeys, [key])
        XCTAssertEqual(Backups.defaults(xcblameDir: dir),
                       [.init(planId: "dddd0004", domain: "com.apple.dt.Xcode", key: key,
                              prior: .init(exists: true, type: "int", value: "4"))])

        let reverted = FixApply.revert(planId: "dddd0004", plan: applied.plan, root: dir, xcblameDir: dir, runner: runner,
                                       now: Date())
        XCTAssertFalse(reverted.failed)
        XCTAssertEqual(runner.value(key)?.type, "int")
        XCTAssertEqual(runner.value(key)?.value, "4")
        XCTAssertEqual(reverted.plan.steps[0].state, .reverted)
        XCTAssertEqual(reverted.plan.events.last?.defaultsKeys, [key])
        XCTAssertTrue(Backups.defaults(xcblameDir: dir).isEmpty)
    }

    func testWriteOfAnUnsetKeyIsDeletedOnRevertAndReapplyKeepsTheFirstPrior() throws {
        let dir = try dir()
        let runner = FakeDefaults()
        _ = try DefaultsApplier.apply([.init(key: key, value: "8", type: "int")], planId: "dddd0004", xcblameDir: dir, runner: runner)
        _ = try DefaultsApplier.apply([.init(key: key, value: "10", type: "int")], planId: "dddd0004", xcblameDir: dir, runner: runner)
        XCTAssertEqual(runner.value(key)?.value, "10")
        XCTAssertEqual(Backups.defaults(xcblameDir: dir).map(\.prior), [.absent])
        XCTAssertEqual(try DefaultsApplier.revert(planId: "dddd0004", xcblameDir: dir, runner: runner), [key])
        XCTAssertNil(runner.value(key))
        XCTAssertEqual(runner.calls, ["write \(key) -int 8", "write \(key) -int 10", "delete \(key)"])
    }

    func testDeletingAnAbsentKeyWritesNothingAndOnlyTheV06KeyIsWritten() throws {
        let dir = try dir()
        let runner = FakeDefaults()
        XCTAssertEqual(try DefaultsApplier.apply([.init(key: key, value: nil, type: nil),
                                                  .init(key: "ShowBuildOperationDuration", value: "YES", type: "bool")],
                                                 planId: "dddd0004", xcblameDir: dir, runner: runner), [key])
        XCTAssertTrue(runner.calls.isEmpty)
    }

    func testFailedWriteRestoresAndReports() throws {
        let dir = try dir()
        let runner = FakeDefaults()
        runner.failWrites = true
        let result = FixApply.applyDefaults(plan(value: "8"), xcblameDir: dir, runner: runner, now: Date())
        XCTAssertTrue(result.failed)
        XCTAssertNil(runner.value(key))
        XCTAssertTrue(result.plan.events.isEmpty)
    }

    func testVerifyOnlyDefaultsNeedKeptAndNoStepIsANote() throws {
        let dir = try dir()
        let runner = FakeDefaults()
        let skipped = FixApply.applyDefaults(plan(value: "8", verifyOnly: true), xcblameDir: dir, runner: runner, now: Date())
        XCTAssertEqual(skipped.plan.steps[0].state, .skipped)
        XCTAssertTrue(runner.calls.isEmpty)
        let none = FixApply.applyDefaults(FixApply.placeholder("e"), xcblameDir: dir, runner: runner, now: Date())
        XCTAssertFalse(none.failed)
        XCTAssertEqual(none.messages, ["nothing to write: the plan has no defaults step"])
    }
}
