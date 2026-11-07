import XCTest
@testable import XcblameKit

/// Module variants from the modules reports (DESIGN §5.11, §6.9) on the cli-xcode26-dd snapshot (the only fixture
/// whose description folder carries `clangmodulesreport/` and `swiftmodulesreport/`).
final class VariantsTests: XCTestCase {
    func testDDSnapshotNumbers() throws {
        let model = try GraphFixtures.model(GraphFixtures.cleanDD)
        let description = try BuildDescription.load(directory: GraphFixtures.descriptionDD)
        let variants = try XCTUnwrap(ModuleVariants.compute(description: description, model: model,
                                                            counted: Timing.timeline(model).counted))
        // DESIGN §6.9 (AcmeApp 26): 64 modules, 17 with 3 variants, 45 with 2, 2 with 1; 79 redundant.
        XCTAssertEqual(variants.modules, 64)
        XCTAssertEqual(variants.redundantTasks, 79)
        XCTAssertEqual(variants.perModuleTotal, 62)
        XCTAssertEqual(variants.perModule.filter { $0.variants == 3 }.count, 17)
        XCTAssertEqual(variants.perModule.filter { $0.variants == 2 }.count, 45)
        // 143 Swift-side PCM tasks (SwiftExplicitDependencyGeneratePcm) + 12 PrecompileModule for the clang report.
        XCTAssertEqual(variants.pcmTasks, 155)
        XCTAssertEqual(variants.perModule.reduce(0) { $0 + ($1.pcmTasks ?? 0) }, 143 - 2 + 12 - 0,
                       "rows hold modules with >= 2 variants: all but Spatial and SwiftUI (1 PCM task each)")
        XCTAssertEqual(variants.redundantSeconds ?? 0, 6.954, accuracy: 0.001)
        XCTAssertEqual(variants.causes, ["swiftPackage", "languageMode"])
        let darwin = try XCTUnwrap(variants.perModule.first { $0.module == "Darwin" })
        XCTAssertEqual(darwin.variants, 3)
        XCTAssertEqual(darwin.pcmTasks, 4, "3 Swift-side variants + the clang report's one")
        XCTAssertEqual(darwin.causes, ["languageMode", "swiftPackage"])
        XCTAssertEqual(darwin.flags, ["-fapinotes-swift-version=6", "-fapinotes-swift-version=5", "SWIFT_PACKAGE",
                                      "__swift__=60200", "__swift__=51000"])
        XCTAssertEqual(variants.perModule.first { $0.module == "Foundation" }?.causes, ["swiftPackage"])
        XCTAssertEqual(variants.perModule.first?.module, "Darwin", "largest redundant seconds first")
    }

    func testTheReportLimitsPerModuleToTopAndKeepsTotals() throws {
        let document = try GraphFixtures.report(try GraphFixtures.model(GraphFixtures.cleanDD), description:
            try BuildDescription.load(directory: GraphFixtures.descriptionDD), topN: 5).document
        let variants = try XCTUnwrap(document.moduleGraph?.variants)
        XCTAssertEqual(variants.perModule.count, 5)
        XCTAssertEqual(variants.perModuleTotal, 62)
        XCTAssertEqual(variants.redundantTasks, 79)
        XCTAssertLessThan(variants.perModuleShownShare ?? 1, 1)
    }

    func testNoReportsMeansNullWithANote() throws {
        let model = try GraphFixtures.model(GraphFixtures.cleanDD3)
        let description = try BuildDescription.load(directory: GraphFixtures.descriptionDD3)
        XCTAssertNil(ModuleVariants.compute(description: description, model: model, counted: Timing.timeline(model).counted))
        XCTAssertNil(ModuleVariants.compute(description: nil, model: model, counted: []))
        let graph = try XCTUnwrap(try GraphFixtures.report(model, description: description).document.moduleGraph)
        XCTAssertNil(graph.variants)
        XCTAssertTrue(graph.notes.contains { $0.hasPrefix("variants: no clangmodulesreport/") }, "\(graph.notes)")
    }

    func testLiveDescriptionsFindTheReportsNextToTheFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("xcblame-var-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let xcbuilddata = root.appendingPathComponent("0123456789abcdef0123456789abcdef.xcbuilddata")
        let report = root.appendingPathComponent("swiftmodulesreport")
        try FileManager.default.createDirectory(at: xcbuilddata, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: report, withIntermediateDirectories: true)
        try Data("Name,Variants\n\"Kit (Clang)\",2\n".utf8).write(to: report.appendingPathComponent("Summary.csv"))
        try Data("Variant,-DFEATURE_X,-Xcc,-O2\nKit-A.pcm,✅,✅,❌\nKit-B.pcm,❌,✅,✅\n".utf8)
            .write(to: report.appendingPathComponent("Kit (Clang).csv"))
        let description = BuildDescription(signature: nil, directory: xcbuilddata, commands: [], targetGraph: [],
                                           buildRequest: .init(action: nil, enableIndexBuildArena: nil, raw: [:]))
        var pcm = TestModels.task(0, "SwiftExplicitDependencyGeneratePcm", kind: .modulePrecompile, start: 1, end: 1.5)
        pcm.commandDetails = "SwiftExplicitDependencyGeneratePcm arm64 /DD/ModuleCache.noindex/Kit-B.pcm\n    cd /"
        let model = TestModels.model([pcm], start: 0, end: 10)
        let variants = try XCTUnwrap(ModuleVariants.compute(description: description, model: model,
                                                            counted: Timing.timeline(model).counted))
        XCTAssertEqual(variants.modules, 1)
        XCTAssertEqual(variants.redundantTasks, 1)
        XCTAssertEqual(variants.redundantSeconds, 0.5, "Kit-B is the variant beyond the first")
        XCTAssertEqual(variants.perModule.first?.flags, ["-DFEATURE_X", "-O2"])
        XCTAssertEqual(variants.perModule.first?.causes, ["macros", "other"])
    }

    func testCausesAndCSV() {
        XCTAssertEqual(ModuleVariants.causes(flags: ["-fapinotes-swift-version=6"]), ["languageMode"])
        XCTAssertEqual(ModuleVariants.causes(flags: ["__swift__=60200", "SWIFT_PACKAGE"]), ["languageMode", "swiftPackage"])
        XCTAssertEqual(ModuleVariants.causes(flags: ["-DDEBUG=1", "FEATURE"]), ["macros"])
        XCTAssertEqual(ModuleVariants.causes(flags: ["-fmodule-map-file=/x"]), ["other"])
        XCTAssertEqual(ModuleVariants.causes(flags: []), ["other"])
        XCTAssertEqual(ModuleVariants.csvRows("a,\"b, c\",\"d\"\"e\"\n\"x\",2"), [["a", "b, c", "d\"e"], ["x", "2"]])
    }

    func testTextAndNodeBadges() throws {
        let document = try GraphFixtures.report(try GraphFixtures.model(GraphFixtures.cleanDD),
                                                description: try BuildDescription.load(directory: GraphFixtures.descriptionDD)).document
        XCTAssertEqual(document.moduleGraph?.nodes.filter { ($0.variants ?? 0) > 0 }.map(\.id), ["_SwiftSyntaxCShims"])
    }
}
