import XCTest
@testable import XcblameKit

/// Task Backtraces (docs/research/probes-v0.5.md §MV-2): category and frame-kind keys decide, the root cause is the
/// LAST frame, a chain through other tasks names the upstream task, and the `Build Backtrace:` text block is the
/// fallback. Both Xcodes' fixtures.
final class BacktraceParsingTests: XCTestCase {
    private func task(_ model: BuildModel, title: String, target: String? = nil) throws -> BuildTask {
        try XCTUnwrap(model.tasks.first { task in
            task.title == title && (target == nil || task.targetId.map { model.targets[$0].name } == target)
        }, title)
    }

    func testAttachmentKeepsCategoriesKindsAndIdentifiers() throws {
        let bytes = Array("\u{0}P0:target-Core-abc-:Debug:Ld /p/Core.o".utf8).map(String.init).joined(separator: ",")
        let json = """
        [{"description":"an input of 'Link Core (arm64)' changed","identifier":{"storage":{"task":{"_0":[\(bytes)]}}},
          "frameKind":{"genericTask":{}},"category":{"ruleInputRebuilt":{}},
          "previousFrameIdentifier":{"storage":{"key":{"_0":"<BuildKey.Node path=/src/Core/A.swift>"}}}},
         {"category":{"ruleHadInvalidValue":{}},"frameKind":{"file":{}},"description":"file '/src/Core/A.swift' changed",
          "identifier":{"storage":{"key":{"_0":"<BuildKey.Node path=/src/Core/A.swift>"}}}}]
        """
        let backtrace = try XCTUnwrap(BacktraceAttachment.decode(Data(json.utf8)))
        XCTAssertEqual(backtrace.frames.map(\.category), ["ruleInputRebuilt", "ruleHadInvalidValue"])
        XCTAssertEqual(backtrace.frames.map(\.frameKind), ["genericTask", "file"])
        XCTAssertEqual(backtrace.frames[0].identifier, "task:P0:target-Core-abc-:Debug:Ld /p/Core.o")
        XCTAssertEqual(backtrace.frames[0].previousFrameIdentifier, "key:<BuildKey.Node path=/src/Core/A.swift>")
        let root = try XCTUnwrap(BacktraceRoot.fromAttachment(backtrace.frames))
        XCTAssertEqual(root.kind, .fileChanged("/src/Core/A.swift"))
        XCTAssertNil(root.rootTaskKey, "the only task frame is the task itself")
        XCTAssertEqual(BacktraceRoot.buildKeyPath("key:<BuildKey.DirectoryTreeSignature path=/a b/c.swiftmodule filters=[]>"),
                       "/a b/c.swiftmodule")
        // The model keeps the same frames (BuildModelBuilder hook).
        XCTAssertEqual(BuildModelBuilder.decodeBacktrace(Data(json.utf8)), backtrace)
    }

    func testSLFFixturesBothXcodes() throws {
        for set in [WhyFixtures.why26, WhyFixtures.why27] {
            let (model, _) = try WhyFixtures.report(set.incremental)
            let withFrames = model.tasks.filter { $0.backtrace != nil }
            XCTAssertGreaterThanOrEqual(withFrames.count, 45, set.name)
            XCTAssertTrue(withFrames.allSatisfy { $0.backtrace!.frames.allSatisfy { $0.category != nil && $0.frameKind != nil } })

            // Root = last frame, chosen by category + frame kind: `ruleHadInvalidValue` on a file.
            let compile = try task(model, title: "Compile LocalizeCore (arm64)")
            let compileRoot = try XCTUnwrap(BacktraceRoot.of(compile))
            XCTAssertEqual(compileRoot.origin, "attachment")
            guard case let .fileChanged(path) = compileRoot.kind else { return XCTFail("\(compileRoot.kind)") }
            XCTAssertTrue(path.hasSuffix("/Sources/LocalizeCore/Models.swift"), path)

            // A chain of several frames: the root is the last one, the upstream task the deepest task frame.
            let link = try task(model, title: "Link AcmeApp (arm64)")
            let linkRoot = try XCTUnwrap(BacktraceRoot.of(link))
            XCTAssertGreaterThanOrEqual(linkRoot.frameCount, 4, set.name)
            XCTAssertEqual(linkRoot.kind, compileRoot.kind)
            XCTAssertEqual(linkRoot.rootTaskTitle, "Compile LocalizeCore (arm64)")
            XCTAssertEqual(linkRoot.rootTaskKey, compile.taskKey, "static task frames carry the task key")

            // Per-file compiles only say "had never run" (MV-2).
            XCTAssertEqual(BacktraceRoot.of(try task(model, title: "Compiling Models.swift"))?.kind, .neverBuilt)
            // The always-run stat cache.
            let stat = try XCTUnwrap(model.tasks.first { $0.ruleName == "ClangStatCache" && $0.backtrace != nil })
            XCTAssertEqual(BacktraceRoot.of(stat)?.kind, .alwaysRuns)
            // Copying the emitted module: a DerivedData directory root.
            let copy = try task(model, title: "Copy LocalizeCore.swiftmodule (arm64)")
            guard case let .directoryChanged(dir) = try XCTUnwrap(BacktraceRoot.of(copy)).kind else { return XCTFail() }
            XCTAssertEqual(derivedModuleProduct(dir), "LocalizeCore")
        }
    }

    func testXCResultLogAndTextFallbackAgree() throws {
        for set in [WhyFixtures.why26, WhyFixtures.why27] {
            let (model, _) = try WhyFixtures.report(try XCTUnwrap(set.xcresultIncremental))
            let compile = try task(model, title: "Compile LocalizeCore (arm64)")
            let fromAttachment = try XCTUnwrap(BacktraceRoot.of(compile))
            XCTAssertEqual(fromAttachment.origin, "attachment")
            // Without the attachment, the emitted `Build Backtrace:` block gives the same root.
            var textOnly = compile
            textOnly.backtrace = nil
            let fromText = try XCTUnwrap(BacktraceRoot.of(textOnly), set.name)
            XCTAssertEqual(fromText.origin, "text")
            XCTAssertEqual(fromText.kind, fromAttachment.kind, set.name)
            var link = try task(model, title: "Link AcmeApp (arm64)")
            link.backtrace = nil
            XCTAssertEqual(BacktraceRoot.of(link)?.rootTaskTitle, "Compile LocalizeCore (arm64)", set.name)
        }
    }

    func testTextWordingOfBothXcodes() {
        func kind(_ lines: [String]) -> BacktraceRoot.Kind? { BacktraceRoot.fromText(lines)?.kind }
        XCTAssertEqual(kind(["a", "signature of 'Copy Swift standard libraries into A.app' changed"]), .signatureChanged)
        XCTAssertEqual(kind(["a", "arguments, environment, working directory, or another component of the signature of 'X' changed"]),
                       .signatureChanged)
        XCTAssertEqual(kind(["'X' did not have up-to-date outputs"]), .outputsInvalid)
        XCTAssertEqual(kind(["outputs of 'X' were missing or modified"]), .outputsInvalid)
        XCTAssertEqual(kind(["'X' is configured to run in every incremental build"]), .alwaysRuns)
        XCTAssertEqual(kind(["'X' was configured to run in every incremental build"]), .alwaysRuns)
        XCTAssertEqual(kind(["an input of 'L' changed", "the task producing file '/o' ran"]), .inputRebuilt)
        XCTAssertEqual(kind(["x", "contents of '/dd/Build/Intermediates.noindex/A.swiftmodule' changed"]),
                       .directoryChanged("/dd/Build/Intermediates.noindex/A.swiftmodule"))
        XCTAssertEqual(BacktraceAttachment.textFrames(in: "tool output\rBuild Backtrace:\rfirst\rroot\r"), ["first", "root"])
        XCTAssertEqual(BacktraceAttachment.textFrames(in: "no backtrace here"), [])
    }
}
