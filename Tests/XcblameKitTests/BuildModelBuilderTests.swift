import Foundation
import XCTest
@testable import XcblameKit

final class BuildModelBuilderTests: XCTestCase {
    // MARK: Fixture helpers

    private static let container = "Xcode.IDEActivityLogDomainType.BuildLog"
    private static let task = BuildModelBuilder.buildLogSectionDomain

    private func section(_ cd: String?, _ start: Double, _ end: Double, domain: String? = task, title: String = "t",
                         messages: [RawMessage] = [], attachments: [RawAttachment] = [],
                         children: [RawSection] = [], emitted: String? = nil,
                         slf: RawSection.SLFOnly? = nil) -> RawSection {
        RawSection(title: title, domainType: domain, commandDetails: cd, start: start, end: end,
                   emittedOutput: emitted, messages: messages, attachments: attachments, subsections: children,
                   slfOnly: slf)
    }

    private func log(_ tasks: [RawSection], start: Double = 1000, end: Double = 1100) -> RawLog {
        let building = section(nil, start, end, domain: Self.container, title: "Building project App", children: tasks)
        let root = section(nil, start, end, domain: Self.container, title: "Build Log", children: [building])
        return RawLog(formatVersion: 11, layout: .commandLine, root: root)
    }

    private func metrics(_ json: String) -> RawAttachment {
        RawAttachment(identifier: "com.apple.dt.ActivityLogSectionAttachment.TaskMetrics", data: Data(json.utf8))
    }

    private func warning(_ text: String, line: Int = 9, file: String = "file:///p/a.swift#StartingLineNumber=9",
                         category: String? = "Swift Compiler Error") -> RawMessage {
        RawMessage(title: text, severity: 1, categoryIdent: category,
                   location: RawLocation(file: file, startLine: line, startColumn: 4))
    }

    private let batchCD = "SwiftCompile normal arm64 Compiling\\ a.swift,\\ b.swift /p/a.swift /p/b.swift "
        + "(in target 'App' from project 'App')"

    private func richLog() -> RawLog {
        log([
            section("CreateBuildDescription", 1000, 1002,
                    children: [section("ExecuteExternalTool /usr/bin/swiftc --version", 1000, 1001)]),
            section(nil, 1002, 1003, domain: BuildModelBuilder.logSectionDomain, title: "Prepare packages"),
            section(batchCD, 1010, 1020, children: [
                section("SwiftCompile normal arm64 /p/a.swift (in target 'App' from project 'App')", 1010, 1015,
                        messages: [warning("unused  variable 'x'")]),
                section("SwiftCompile normal arm64 /p/b.swift (in target 'App' from project 'App')", 1015, 1020),
            ]),
            section("SwiftCompile normal arm64 /x/pkg/S.swift (in target 'Pkg' from project 'pkg' at path '/x/pkg')",
                    1020, 1030, messages: [warning("unused variable 'x'")]),
            section(nil, 1030, 1040, title: "extra parent", children: [
                section("CompileC /dd/Intermediates.noindex/App.build/Debug/Lib.build/Objects-normal/arm64/x.o "
                        + "/p/x.c normal arm64 c com.apple.compilers.llvm.clang.1_0.compiler", 1030, 1031),
            ]),
            section("SwiftExplicitDependencyGeneratePcm arm64 /dd/ModuleCache.noindex/SwiftShims-ABC.pcm", 1031, 1032),
            section("FrobnicateThing /p/Assets.xcassets", 1032, 1033, emitted: "/usr/bin/actool --compile /out\n"),
            section(nil, 1099, 1100, domain: BuildModelBuilder.timingSummaryDomain, title: "Build Timing Summary",
                    children: [
                        section("SwiftCompile (2 tasks) | 20.000 seconds", 1099, 1100,
                                domain: BuildModelBuilder.timingAggregateDomain, title: "SwiftCompile (2 tasks)"),
                        section("CompileC (1 task) | 1.500 seconds", 1099, 1100,
                                domain: BuildModelBuilder.timingAggregateDomain, title: "CompileC (1 task)"),
                    ]),
        ])
    }

    // MARK: Executed tasks

    func testOutermostSectionsAreTasksAndChildrenAreSubspans() {
        let model = BuildModelBuilder.build(richLog(), reader: .slf)
        XCTAssertEqual(model.tasks.map(\.ruleName), [
            "CreateBuildDescription", "SwiftCompile", "SwiftCompile", "CompileC",
            "SwiftExplicitDependencyGeneratePcm", "FrobnicateThing",
        ])
        XCTAssertEqual(model.tasks.map(\.id), Array(0..<6))
        let swift = model.tasks.filter { $0.kind == .swiftCompile }
        // Double-count guard: per-file children (2 x 5 s) are not added to the batch parent (10 s).
        XCTAssertEqual(swift.reduce(0) { $0 + $1.duration }, 20, accuracy: 1e-9)
        XCTAssertEqual(swift[0].subspans.count, 2)
        XCTAssertEqual(swift[0].subspans.first?.ruleName, "SwiftCompile")
        XCTAssertEqual(model.tasks[0].subspans.first?.ruleName, "ExecuteExternalTool")
        XCTAssertEqual(model.sessionStart, 1000)
        XCTAssertEqual(model.sessionEnd, 1100)
    }

    func testEscapedRuleNameAndToolFallback() {
        let model = BuildModelBuilder.build(log([
            section("SwiftDriver\\ Compilation\\ Requirements App normal arm64 com.apple.xcode.tools.swift.compiler "
                    + "(in target 'App' from project 'App')", 1000, 1001),
        ]), reader: .xcresult)
        XCTAssertEqual(model.tasks.first?.ruleName, "SwiftDriver Compilation Requirements")
        XCTAssertEqual(model.tasks.first?.kind, .gate)

        let rich = BuildModelBuilder.build(richLog(), reader: .slf)
        let frob = rich.tasks[5]
        XCTAssertEqual(frob.kind, .assets)
        XCTAssertEqual(frob.kindSource, .tool)
        XCTAssertEqual(frob.phase, .package)
    }

    func testTimingSummaryParsedFromAggregateSections() {
        let model = BuildModelBuilder.build(richLog(), reader: .slf)
        XCTAssertEqual(model.timingSummary?.rows, [
            TimingSummary.Row(ruleName: "SwiftCompile", taskCount: 2, seconds: 20),
            TimingSummary.Row(ruleName: "CompileC", taskCount: 1, seconds: 1.5),
        ])
        XCTAssertNil(BuildModelBuilder.build(log([section("Ld /o", 1, 2)]), reader: .slf).timingSummary)
        XCTAssertEqual(BuildModelBuilder.parseTimingRow("SwiftDriver Compilation (9 tasks) | 0.002 seconds")?.ruleName,
                       "SwiftDriver Compilation")
        XCTAssertNil(BuildModelBuilder.parseTimingRow("SwiftCompile (87 tasks)"))
    }

    // MARK: Classification share

    func testUnclassifiedShareDegradesAboveFivePercent() {
        let fine = BuildModelBuilder.build(log([
            section("SwiftCompile normal arm64 /p/a.swift", 1000, 1099),
            section("Mystery thing", 1099, 1100),
        ]), reader: .slf)
        XCTAssertEqual(fine.unclassifiedShare, 0.01, accuracy: 1e-9)
        XCTAssertTrue(fine.degradations.isEmpty)

        let bad = BuildModelBuilder.build(log([
            section("SwiftCompile normal arm64 /p/a.swift", 1000, 1090),
            section("Mystery thing", 1090, 1100),
        ]), reader: .slf)
        XCTAssertEqual(bad.unclassifiedShare, 0.1, accuracy: 1e-9)
        XCTAssertEqual(bad.degradations.map(\.kind), [.classification])
        XCTAssertEqual(bad.tasks[1].kind, .other)
        XCTAssertEqual(bad.tasks[1].kindSource, BuildTask.KindSource.none)
    }

    // MARK: Target attribution

    func testTargetSuffixWithAndWithoutPathTail() {
        let plain = BuildModelBuilder.targetSuffix(in: "Ld /o normal (in target 'App' from project 'App')")
        XCTAssertEqual(plain?.name, "App")
        XCTAssertEqual(plain?.project, "App")
        XCTAssertNil(plain?.path)
        let pkg = BuildModelBuilder.targetSuffix(
            in: "SwiftCompile x (in target 'SwiftSyntax' from project 'swift-syntax' at path '/x/swift syntax')")
        XCTAssertEqual(pkg?.name, "SwiftSyntax")
        XCTAssertEqual(pkg?.project, "swift-syntax")
        XCTAssertEqual(pkg?.path, "/x/swift syntax")
        XCTAssertNil(BuildModelBuilder.targetSuffix(in: "Ld /o (in target 'App' from project"))
    }

    func testTargetsFromSignaturePathAndBuckets() {
        let model = BuildModelBuilder.build(richLog(), reader: .slf)
        func target(of taskId: Int) -> Target? { model.tasks[taskId].targetId.map { model.targets[$0] } }
        XCTAssertEqual(target(of: 1)?.name, "App")
        XCTAssertEqual(target(of: 1)?.isPackage, false)
        XCTAssertEqual(target(of: 2)?.name, "Pkg")
        XCTAssertEqual(target(of: 2)?.path, "/x/pkg")
        XCTAssertEqual(target(of: 2)?.isPackage, true)
        XCTAssertEqual(target(of: 3)?.name, "Lib")
        XCTAssertNil(target(of: 3)?.project)
        XCTAssertEqual(target(of: 4)?.name, Target.explicitModulesBucket)
        XCTAssertEqual(target(of: 4)?.isBucket, true)
        XCTAssertEqual(target(of: 0)?.name, Target.buildSystemBucket)
        XCTAssertEqual(model.targets.map(\.id), Array(0..<model.targets.count))
        XCTAssertEqual(model.targets.flatMap(\.taskIds).sorted(), Array(0..<model.tasks.count))
        XCTAssertEqual(BuildModelBuilder.pathTargetName(in: "CompileC /dd/Foo.build/Debug/Bar-t.build/x.o /p/x.c"), "Bar")
    }

    func testPathTargetReusesSignatureTargetOfSameName() {
        let model = BuildModelBuilder.build(log([
            section("WriteAuxiliaryFile /dd/App.build/Debug/App.build/App.hmap", 1000, 1001),
            section("Ld /o normal (in target 'App' from project 'App')", 1001, 1002),
        ]), reader: .slf)
        XCTAssertEqual(model.targets.count, 1)
        XCTAssertEqual(model.targets[0].project, "App")
        XCTAssertEqual(model.targets[0].taskIds, [0, 1])
    }

    // MARK: Attachments, signature

    func testTaskMetricsPlaceholderAndRealRecords() {
        let start2001 = 815_073_646_595_000.0
        let model = BuildModelBuilder.build(log([
            section("CreateBuildDirectory /dd", 1000, 1001, attachments: [
                metrics(#"{"wcStartTime":815073646595000,"utime":98,"stime":98,"maxRSS":0,"wcDuration":98}"#),
            ]),
            section("SwiftCompile normal arm64 /p/a.swift", 1001, 1004, attachments: [
                metrics(#"{"wcStartTime":815073653931597,"utime":930677,"stime":1930138,"maxRSS":336084992,"wcDuration":2985189}"#),
            ]),
        ]), reader: .slf)
        let placeholder = model.tasks[0]
        XCTAssertEqual(placeholder.metrics?.isPlaceholder, true)
        XCTAssertNil(placeholder.metrics?.userCPU)
        XCTAssertNil(placeholder.metrics?.maxRSS)
        // Timing from a placeholder is still accepted.
        XCTAssertEqual(placeholder.start, start2001 / 1e6 + BuildModelBuilder.appleEpochOffset, accuracy: 1e-6)
        XCTAssertEqual(placeholder.duration, 98e-6, accuracy: 1e-12)

        let real = model.tasks[1]
        XCTAssertEqual(real.metrics?.isPlaceholder, false)
        XCTAssertEqual(real.metrics?.userCPU ?? 0, 0.930677, accuracy: 1e-9)
        XCTAssertEqual(real.metrics?.systemCPU ?? 0, 1.930138, accuracy: 1e-9)
        XCTAssertEqual(real.metrics?.maxRSS, 336_084_992)
        XCTAssertEqual(real.duration, 2.985189, accuracy: 1e-9)
    }

    func testBacktraceAndUnknownAttachments() {
        let backtrace = RawAttachment(
            identifier: "com.apple.dt.ActivityLogSectionAttachment.TaskBacktrace",
            data: Data(#"[{"category":"ruleInputRebuilt","description":"input changed"},{"category":{"ruleForced":{}}}]"#.utf8))
        let big = RawAttachment(identifier: "com.example.Mystery", data: Data(repeating: 0x41, count: 5000))
        let model = BuildModelBuilder.build(log([
            section("Ld /o", 1000, 1001, attachments: [backtrace, big]),
            section("Ld /p", 1001, 1002, attachments: [big, metrics("not json")]),
        ]), reader: .slf)
        XCTAssertEqual(model.tasks[0].backtrace?.frames.map(\.category), ["ruleInputRebuilt", "ruleForced"])
        XCTAssertEqual(model.tasks[0].backtrace?.frames.first?.description, "input changed")
        XCTAssertEqual(model.tasks[0].unknownAttachments.first?.data.count, BuildModelBuilder.keptAttachmentLimit)
        XCTAssertEqual(model.tasks[0].unknownAttachments.first?.truncated, true)
        XCTAssertNil(model.tasks[1].metrics)
        XCTAssertEqual(model.decodeWarnings.filter { $0.kind == .unknownAttachment }.count, 1)
        XCTAssertEqual(model.decodeWarnings.filter { $0.kind == .invalidAttachment }.count, 1)
    }

    func testTaskKeyStripsPrefixByte() {
        let key = "P0:target-LocalizeCore-PACKAGE-TARGET:LocalizeCore-SDKROOT:macosx:Debug:ExtractAppIntentsMetadata"
        let hex = "00" + key.utf8.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(BuildModelBuilder.taskKey(fromSignatureHex: hex), key)
        XCTAssertEqual(BuildModelBuilder.taskKey(fromSignatureHex: "014142"), "AB")
        XCTAssertNil(BuildModelBuilder.taskKey(fromSignatureHex: "0zz1"))
        XCTAssertNil(BuildModelBuilder.taskKey(fromSignatureHex: "001"))

        let model = BuildModelBuilder.build(log([
            section("ExtractAppIntentsMetadata", 1000, 1001, slf: .init(xcbuildSignatureHex: hex)),
            section("Ld /o", 1001, 1002, slf: .init(xcbuildSignatureHex: "nothex")),
        ]), reader: .slf)
        XCTAssertEqual(model.tasks[0].taskKey, key)
        XCTAssertNil(model.tasks[1].taskKey)
        XCTAssertEqual(model.decodeWarnings.map(\.kind), [.invalidSignature])
    }

    // MARK: Diagnostics

    func testDiagnosticsDedupeAcrossTasksWithOneBasedLines() {
        let model = BuildModelBuilder.build(richLog(), reader: .slf)
        let warnings = model.diagnostics.filter { $0.severity == .warning }
        XCTAssertEqual(warnings.count, 1)
        let d = warnings[0]
        XCTAssertEqual(d.occurrences, 2)
        XCTAssertEqual(d.taskIds, [1, 2])
        XCTAssertEqual(d.file, "/p/a.swift")
        XCTAssertEqual(d.line, 10)
        XCTAssertEqual(d.column, 5)
        XCTAssertEqual(d.category, "Swift Compiler Error")  // display only; severity came from the int
        XCTAssertEqual(model.tasks[1].diagnosticIds, [d.id])
        XCTAssertEqual(model.tasks[2].diagnosticIds, [d.id])
    }

    func testSeverityFromTypeStringAndSubmessages() {
        XCTAssertEqual(Diagnostic.Severity(int: nil, type: "analyzer warning"), .analyzerWarning)
        XCTAssertEqual(Diagnostic.Severity(int: nil, type: "error"), .error)
        XCTAssertEqual(Diagnostic.Severity(int: 2, type: "warning"), .error)
        var collector = DiagnosticCollector()
        var interner = StringInterner()
        let message = RawMessage(title: "cannot find 'x'", type: "error",
                                 location: RawLocation(file: "/p/a.swift", startLine: 3, numberBase: 1),
                                 submessages: [RawMessage(title: "did you mean 'y'?", type: "notice")])
        collector.add(message, taskId: nil, interner: &interner)
        XCTAssertEqual(collector.diagnostics.first?.text, "cannot find 'x'\ndid you mean 'y'?")
        XCTAssertEqual(collector.diagnostics.first?.line, 3)
        XCTAssertEqual(collector.diagnostics.first?.taskIds, [])
    }

    func testUnknownDomainWarnsOnceAndStillYieldsTask() {
        let model = BuildModelBuilder.build(log([
            section("Ld /o", 1000, 1001, domain: "com.apple.dt.IDE.FutureSection"),
            section("Ld /p", 1001, 1002, domain: "com.apple.dt.IDE.FutureSection"),
        ]), reader: .slf)
        XCTAssertEqual(model.tasks.count, 2)
        XCTAssertEqual(model.decodeWarnings.map(\.kind), [.unknownDomain])
    }

    func testModelIsEncodable() throws {
        let data = try JSONEncoder().encode(BuildModelBuilder.build(richLog(), reader: .slf))
        XCTAssertFalse(data.isEmpty)
    }

    /// Code review v0.1 row 20: a section whose command slot was lost is walked through, not turned into a task by its
    /// signature text, unless the signature carries the `(in target ...)` suffix.
    func testSignatureAloneNeedsTargetSuffixToMakeATask() {
        let domain = BuildModelBuilder.buildLogSectionDomain
        let root = RawSection(domainType: Locator.buildLogDomain, start: 0, end: 10, subsections: [
            RawSection(domainType: domain, signature: "SwiftCompile normal arm64 x.swift", start: 1, end: 2),
            RawSection(domainType: domain, signature: "Ld /p/App (in target 'App' from project 'App')", start: 2, end: 3),
        ])
        let model = BuildModelBuilder.build(RawLog(layout: .commandLine, root: root), reader: .slf)
        XCTAssertEqual(model.tasks.map(\.ruleName), ["Ld"])
    }

    /// Re-check N4: a parent without commandDetails or target suffix whose children have rule names stays the one
    /// outermost task (10 s, not 2 x 9 s) and the model is degraded.
    func testParentWithoutCommandButRuledChildrenStaysOneTask() {
        let domain = BuildModelBuilder.buildLogSectionDomain
        let children = [1.0, 1.5].map { start in
            RawSection(domainType: domain, commandDetails: "SwiftCompile normal arm64 f\(start).swift", start: start,
                       end: start + 9)
        }
        let root = RawSection(domainType: Locator.buildLogDomain, start: 0, end: 20, subsections: [
            RawSection(domainType: domain, signature: "SwiftCompile normal arm64 batch", start: 1, end: 11,
                       subsections: children),
        ])
        let model = BuildModelBuilder.build(RawLog(layout: .commandLine, root: root), reader: .slf)
        XCTAssertEqual(model.tasks.map(\.duration), [10])
        XCTAssertEqual(model.tasks.first?.subspans.count, 2)
        XCTAssertEqual(Timing.analyze(model).taskTime, 10, accuracy: 1e-9)
        XCTAssertTrue(model.decodeWarnings.contains { $0.kind == .schemaDrift && $0.detail.contains("without commandDetails") })
        XCTAssertTrue(model.degradations.contains { $0.kind == .schemaDrift })
    }
}
