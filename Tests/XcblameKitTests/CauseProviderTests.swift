import XCTest
@testable import XcblameKit

/// The evidence providers and the engine's precedence and roll-up rules on small hand-made builds (DESIGN §6.6).
final class CauseProviderTests: XCTestCase {
    private typealias Mini = WhyFixtures.Mini

    private func attribute(_ mini: Mini, previous: [History.TaskIndexRow]? = nil, previousKind: String = "incremental",
                           previousTime: Date? = nil, project: ProjectModel? = nil, capture: OutputHashes.Capture? = nil,
                           xcode: String? = nil, rows edit: (inout [History.TaskIndexRow]) -> Void = { _ in })
        throws -> (incremental: ReportDocument.Incremental, model: BuildModel) {
        let model = mini.model()
        let document = try mini.document(model)
        var rows = History.taskIndexRows(document, model)
        edit(&rows)
        let index = previous.map {
            PreviousIndex(id: "20261102-100000-\(previousKind)", time: previousTime, kind: previousKind, rows: $0, span: 60)
        }
        var context = try CauseEngine.makeContext(document: document, model: model, previous: index, project: project,
                                                  capture: capture)
        context.currentRows = rows
        context.xcode = xcode
        if let index { context.matches = try TaskIdentity.match(current: rows, previous: index.rows) }
        return (try CauseEngine.attribute(document: document, context: context), model)
    }

    private func causeId(_ incremental: ReportDocument.Incremental, task: Int) -> String? {
        incremental.causes.first { $0.tasks.contains { $0.taskId == task } }?.id
    }

    func testTaskIdentityMatchesByStableKeyThenShape() throws {
        func row(_ key: String?, _ rule: String, _ digest: String) -> History.TaskIndexRow {
            .init(key: key, rule: rule, target: "T", kind: "other", sigDigest: digest, durationMs: 1, onPath: false)
        }
        let previous = [row("P0:t:Debug:Ld /a", "Ld", "d1"), row("5075b6ed4d3f272114f33e28e32c2181", "SwiftCompile", "x"),
                        row(nil, "CpResource", "c"), row(nil, "CpResource", "c")]
        let current = [row("P0:t:Debug:Ld /a", "Ld", "d2"), row("5075b6ed4d3f272114f33e28e32c2181", "SwiftCompile", "y"),
                       row(nil, "CpResource", "c"), row(nil, "CpResource", "c"), row(nil, "CpResource", "c")]
        let matches = try TaskIdentity.match(current: current, previous: previous)
        XCTAssertEqual(matches[0], .init(current: 0, previous: 0, signatureChanged: true))
        XCTAssertEqual(matches[1].previous, nil, "a dynamic key (32 hex) is no identity")
        XCTAssertEqual(matches.map(\.previous), [0, nil, 2, 3, nil], "shape is a multiset")
        XCTAssertNil(TaskIdentity.stableKey("P2:target-A-x:Debug:0123456789abcdef0123456789abcdef"))
        XCTAssertEqual(TaskIdentity.stableKey("P0:target-A:Debug:CopySwiftLibs /x"), "P0:target-A:Debug:CopySwiftLibs /x")
    }

    func testScriptPhaseFromTheProjectAndFromXcodesWarning() throws {
        var mini = Mini()
        let stamp = mini.task("PhaseScriptExecution", target: "App", seconds: 2, title: "Run custom shell script 'Stamp'")
        let lint = mini.task("PhaseScriptExecution", target: "App", seconds: 1, title: "Run custom shell script 'Lint'",
                             diagnostic: "Run script build phase 'Lint' will be run during every build because it does not specify any outputs.")
        let fine = mini.task("PhaseScriptExecution", target: "App", seconds: 1, title: "Run custom shell script 'Gen'")
        let project = ProjectModel(
            root: URL(fileURLWithPath: "/p"), container: .xcodeproj(URL(fileURLWithPath: "/p/App.xcodeproj")),
            format: .pbxproj(objectVersion: 77),
            projects: [.init(path: URL(fileURLWithPath: "/p/App.xcodeproj"), name: "App", objectVersion: 77,
                             configurations: ["Debug"], defaultConfiguration: "Debug", projectSettings: [:],
                             projectXCConfig: [:], targets: [
                .init(id: "T", name: "App", productType: "com.apple.product-type.application", phases: [
                    .shellScript(.init(id: "1", name: "Stamp", shellScript: "date", inputPaths: ["$(SRCROOT)/a"])),
                    .shellScript(.init(id: "2", name: "Gen", shellScript: "gen", inputPaths: ["a"], outputPaths: ["b"])),
                ]),
            ])])
        let (incremental, _) = try attribute(mini, previous: nil, project: project)
        let script = try XCTUnwrap(incremental.causes.first { $0.id == "scriptPhase:App/Stamp" })
        XCTAssertEqual(script.source, "script")
        XCTAssertEqual(script.ruleId, "PHASE-001")
        XCTAssertEqual(script.seconds, 2)
        XCTAssertTrue(script.evidence[0].contains("declares no outputs"), "\(script.evidence)")
        XCTAssertEqual(causeId(incremental, task: stamp), "scriptPhase:App/Stamp")
        XCTAssertEqual(causeId(incremental, task: lint), "scriptPhase:App/Lint", "Xcode's warning stands in for the project")
        XCTAssertEqual(causeId(incremental, task: fine), "unknown", "inputs and outputs declared: no script evidence")
        XCTAssertEqual(incremental.basis, "currentLogOnly")
    }

    func testBacktraceBeatsScriptAndSignatureIsSecondary() throws {
        var mini = Mini()
        let stamp = mini.task("PhaseScriptExecution", target: "App", title: "Run custom shell script 'Stamp'", key: "P0:App:Stamp",
                              frames: [WhyFixtures.frame("ruleHadInvalidValue", "genericTask",
                                                         "'Run custom shell script 'Stamp'' was configured to run in every incremental build")],
                              diagnostic: "Run script build phase 'Stamp' will be run during every build because it does not specify any outputs.")
        let link = mini.task("Ld", target: "App", title: "Link App", key: "P0:App:Ld",
                             frames: [WhyFixtures.frame("ruleInputRebuilt", "genericTask", "an input of 'Link App' changed"),
                                      WhyFixtures.frame("ruleHadInvalidValue", "file", "file '/src/App/A.swift' changed")])
        let model = mini.model()
        let rows = History.taskIndexRows(try mini.document(model), model)
        var previous = rows
        previous[0].sigDigest = "0000000000000000"
        previous[1].sigDigest = "0000000000000000"
        let (incremental, _) = try attribute(mini, previous: previous)
        let cause = try XCTUnwrap(incremental.causes.first { $0.id == "scriptPhase:App/Stamp" })
        XCTAssertEqual(cause.source, "backtrace", "precedence 1 over 2")
        XCTAssertEqual(causeId(incremental, task: stamp), cause.id)
        XCTAssertTrue(cause.secondaryEvidence.contains { $0.hasPrefix("script:") }, "\(cause.secondaryEvidence)")
        XCTAssertFalse(cause.secondaryEvidence.contains { $0.hasPrefix("signature:") },
                       "a script's command text carries the environment: no signature signal")
        let input = try XCTUnwrap(incremental.causes.first { $0.id == "inputChanged:/src/App/A.swift" })
        XCTAssertEqual(causeId(incremental, task: link), input.id, "precedence 1 over 3")
        XCTAssertTrue(input.secondaryEvidence.contains { $0.hasPrefix("signature:") }, "\(input.secondaryEvidence)")
    }

    func testSignatureChangeAndFirstBuildAfterClean() throws {
        var mini = Mini()
        let link = mini.task("Ld", target: "Core", title: "Link Core", key: "P0:target-Core:Debug:Ld /p/Core.o")
        let fresh = mini.task("CpResource", target: "Core", title: "Copy a.png", key: "P0:target-Core:Debug:CpResource a.png")
        let model = mini.model()
        var previous = History.taskIndexRows(try mini.document(model), model)
        previous[0].sigDigest = "ffffffffffffffff"
        previous.remove(at: 1)
        let (incremental, _) = try attribute(mini, previous: previous, previousKind: "clean")
        XCTAssertEqual(causeId(incremental, task: link), "settingsChanged:Core")
        XCTAssertEqual(causeId(incremental, task: fresh), "firstBuild:Core")
        XCTAssertEqual(incremental.causes.first { $0.id == "settingsChanged:Core" }?.source, "signature")
        XCTAssertEqual(incremental.basis, "previousIndex")
    }

    func testRuleInputRebuiltChainsRollUpToTheRootTask() throws {
        var mini = Mini()
        let compile = mini.task("SwiftDriver Compilation", target: "Core", seconds: 0.5, title: "Compile Core (arm64)",
                                key: "P0:target-Core:Debug:SwiftDriver Compilation Core",
                                frames: [WhyFixtures.frame("ruleInputRebuilt", "genericTask", "an input of 'Compile Core (arm64)' changed"),
                                         WhyFixtures.frame("ruleHadInvalidValue", "file", "file '/src/Core/A.swift' changed",
                                                           id: "key:<BuildKey.Node path=/src/Core/A.swift>")])
        let perFile = mini.task("SwiftCompile", target: "Core", seconds: 3, title: "Compiling A.swift",
                                frames: [WhyFixtures.frame("ruleNeverBuilt", "genericTask", "'Compiling A.swift' had never run")])
        let discovery = mini.task("SwiftDriverJobDiscovery", target: "Core", seconds: 0.25, title: "Discovering Swift tasks")
        let link = mini.task("Ld", target: "App", seconds: 1, title: "Link App",
                             frames: [WhyFixtures.frame("ruleInputRebuilt", "genericTask", "an input of 'Link App' changed"),
                                      WhyFixtures.frame("ruleInputRebuilt", "file", "the producer of file '/o/Core.o' ran"),
                                      WhyFixtures.frame("ruleInputRebuilt", "genericTask", "an input of 'Compile Core (arm64)' changed",
                                                        id: "task:P0:target-Core:Debug:SwiftDriver Compilation Core"),
                                      WhyFixtures.frame("ruleHadInvalidValue", "file", "file '/src/Core/A.swift' changed")])
        let stray = mini.task("Touch", target: "App", seconds: 2, title: "Touch App.app")
        let (incremental, _) = try attribute(mini, previous: [])
        let id = "inputChanged:/src/Core/A.swift"
        for task in [compile, perFile, discovery, link] { XCTAssertEqual(causeId(incremental, task: task), id) }
        XCTAssertEqual(causeId(incremental, task: stray), "unknown")
        let cause = try XCTUnwrap(incremental.causes.first { $0.id == id })
        XCTAssertEqual(cause.seconds, 4.75)
        XCTAssertEqual(cause.tasksTotal, 4)
        XCTAssertTrue(cause.evidence.contains { $0.contains("joins 'driver gate Core'") }, "\(cause.evidence)")
        XCTAssertEqual(incremental.causes.map(\.id), [id, "unknown"], "unknown last")
        XCTAssertEqual(incremental.unknownSeconds, 2)
        XCTAssertEqual(incremental.v15.status, "pass")
        XCTAssertEqual(incremental.v15.sumOfCauses, 6.75)
    }

    func testCyclicRootsFallBackToTheEvidencesOwnClass() throws {
        var mini = Mini()
        // Two tasks naming each other as their upstream task: neither resolves through the other.
        let a = mini.task("Ld", target: "A", title: "Link A", key: "P0:A:Ld",
                          frames: [WhyFixtures.frame("ruleInputRebuilt", "genericTask", "an input of 'Link A' changed"),
                                   WhyFixtures.frame("ruleInputRebuilt", "genericTask", "an input of 'Link B' changed", id: "task:P0:B:Ld")])
        let b = mini.task("Ld", target: "B", title: "Link B", key: "P0:B:Ld",
                          frames: [WhyFixtures.frame("ruleInputRebuilt", "genericTask", "an input of 'Link B' changed"),
                                   WhyFixtures.frame("ruleInputRebuilt", "genericTask", "an input of 'Link A' changed", id: "task:P0:A:Ld")])
        let (incremental, _) = try attribute(mini, previous: nil)
        let ids = [causeId(incremental, task: a), causeId(incremental, task: b)]
        XCTAssertFalse(ids.contains("unknown"), "\(ids)")
        XCTAssertTrue(ids.allSatisfy { $0 == "inputChanged:A" || $0 == "inputChanged:B" }, "\(ids)")
        XCTAssertEqual(incremental.v15.status, "pass")
    }

    func testUpstreamInterfaceTimestampChurnAndDYN005() throws {
        var mini = Mini()
        let emit = mini.task("SwiftEmitModule", target: "Core", title: "Emitting module for Core", key: "P0:Core:emit")
        let downstream = mini.task("SwiftCompile", target: "App", title: "Compiling V.swift", key: "P0:App:V")
        let churned = mini.task("SwiftCompile", target: "Core", title: "Compiling W.swift", key: "P0:Core:W")
        let model = mini.model()
        let rows = History.taskIndexRows(try mini.document(model), model)
        var previous = rows
        previous[0].outputHash = "aaaaaaaaaaaaaaaa"
        previous[2].inputHashes = ["$REPO/W.swift": "1111111111111111"]
        // The previous build started at 1000 - 60 s; W.swift was rewritten after that with the same content.
        let previousTime = Date(timeIntervalSince1970: 1_000)
        let capture = OutputHashes.Capture(outputs: ["P0:Core:emit": .init(hash: "bbbbbbbbbbbbbbbb", bytes: 10)],
                                           inputs: ["P0:Core:W": ["$REPO/W.swift": "1111111111111111"]],
                                           inputMtimes: ["P0:Core:W": ["$REPO/W.swift": 980]])
        let (incremental, _) = try attribute(mini, previous: previous, previousTime: previousTime, capture: capture)
        XCTAssertEqual(causeId(incremental, task: downstream), "upstreamInterface:Core")
        XCTAssertEqual(causeId(incremental, task: churned), "timestampChurn:$REPO/W.swift")
        let churn = try XCTUnwrap(incremental.causes.first { $0.id == "timestampChurn:$REPO/W.swift" })
        XCTAssertEqual(churn.ruleId, "DYN-002")
        XCTAssertEqual(churn.cause, "W.swift got a newer modification time with the same content, so the tasks reading it "
            + "re-ran (DYN-002)")
        XCTAssertEqual(causeId(incremental, task: emit), "unknown", "the changed module itself needs other evidence")

        // Code review v0.5: equal hashes alone are no churn. An input older than the previous build's start (a
        // dependent recompiled for another reason, `why --touch X` on another file) gives no DYN-002, nor does an
        // unknown previous build time.
        var old = capture
        old.inputMtimes = ["P0:Core:W": ["$REPO/W.swift": 900]]
        let (settled, _) = try attribute(mini, previous: previous, previousTime: previousTime, capture: old)
        XCTAssertEqual(causeId(settled, task: churned), "unknown")
        XCTAssertFalse(settled.causes.contains { $0.class == "timestampChurn" })
        let (untimed, _) = try attribute(mini, previous: previous, capture: capture)
        XCTAssertFalse(untimed.causes.contains { $0.class == "timestampChurn" })

        // Xcode 27.0: the emit-module re-ran with an unchanged output (swift-driver#2214).
        var same = previous
        same[0].outputHash = "bbbbbbbbbbbbbbbb"
        let (falseTrigger, _) = try attribute(mini, previous: same, capture: capture, xcode: "27.0")
        let dyn005 = try XCTUnwrap(falseTrigger.causes.first { $0.id == "upstreamInterface:Core" })
        XCTAssertEqual(dyn005.ruleId, "DYN-005")
        XCTAssertEqual(causeId(falseTrigger, task: emit), dyn005.id)
        XCTAssertNotEqual(causeId(falseTrigger, task: downstream), dyn005.id, "an unchanged interface explains no dependent")
    }

    func testPlanningWithoutCompilesAndMacroPlugins() throws {
        var mini = Mini()
        mini.task("CreateBuildDescription", target: nil, title: "Create build description")
        let plan = mini.task("SwiftDriver", target: "Kit", title: "Planning Swift module Kit (arm64)",
                             details: "SwiftDriver Kit normal arm64 -load-plugin-executable /p/A#A -load-plugin-executable /p/B#B")
        let (incremental, _) = try attribute(mini, previous: [], xcode: "26.0.1")
        XCTAssertEqual(causeId(incremental, task: 0), "planning:build planning")
        let kit = try XCTUnwrap(incremental.causes.first { $0.id == "planning:Kit" })
        XCTAssertEqual(kit.ruleId, "ENV-008")
        XCTAssertEqual(causeId(incremental, task: plan), kit.id)
    }

    func testDriverRemarkParsing() throws {
        let excerpt = try String(contentsOf: WhyFixtures.logs.appendingPathComponent(
            "cli-xcode26-incremental-remarks/xcodebuild-stdout-inc2-excerpt.txt"), encoding: .utf8)
        let remarks = DriverRemarkEvidenceProvider.parse([excerpt])
        XCTAssertEqual(remarks.changed, ["Models.swift"])
        XCTAssertEqual(remarks.imports, ["LocalizeCore.swiftmodule"])
        XCTAssertTrue(remarks.external.contains("StudioView.swift"))
        XCTAssertTrue(remarks.cascaded.contains("Diff.swift"), "26 stdout has the discovery-time remarks")
        XCTAssertEqual(DriverRemarkEvidenceProvider.compiledFile(
            "Scheduling changed input  {compile: StudioModel.o <= StudioModel.swift}"), "StudioModel.swift")
        XCTAssertNil(DriverRemarkEvidenceProvider.compiledFile("Read dependency graph '/x'"))
    }
}
