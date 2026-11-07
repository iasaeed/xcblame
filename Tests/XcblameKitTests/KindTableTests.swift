import XCTest
@testable import XcblameKit

final class KindTableTests: XCTestCase {
    /// Every rule name listed in DESIGN §5.5 item 1.
    static let designRuleNames = [
        "SwiftCompile", "SwiftDriver", "SwiftDriver Compilation", "SwiftDriver Compilation Requirements",
        "SwiftDriverJobDiscovery", "SwiftEmitModule", "EmitSwiftModule", "SwiftExplicitDependencyGeneratePcm",
        "SwiftExplicitDependencyCompileModuleFromInterface", "PrecompileModule", "ScanDependencies", "ClangStatCache",
        "CompileC", "Ld", "Libtool", "PhaseScriptExecution", "CompileAssetCatalogVariant", "LinkAssetCatalog",
        "GenerateAssetSymbols", "ExtractAppIntentsMetadata", "ProcessInfoPlistFile", "CodeSign", "CopySwiftLibs",
        "RegisterExecutionPolicyException", "RegisterWithLaunchServices", "ValidateEmbeddedBinary", "Validate",
        "Touch", "CreateBuildDescription", "ComputeTargetDependencyGraph",
        "ComputePackagePrebuildTargetDependencyGraph", "SendProjectDescription", "CreateBuildRequest",
        "CreateBuildOperation", "GatherProvisioningInputs", "GenerateClangModulesReport", "GenerateSwiftModulesReport",
        "WriteAuxiliaryFile", "MkDir", "CreateBuildDirectory", "Copy", "CpResource", "ExecuteExternalTool",
    ]

    func testEveryDesignRuleMapsToAKind() {
        for rule in Self.designRuleNames {
            let entry = KindTable.v1.lookup(rule)
            XCTAssertNotNil(entry, rule)
            XCTAssertNotEqual(entry?.kind, .other, rule)
        }
    }

    func testBuiltinPrefixRule() {
        XCTAssertEqual(KindTable.v1.lookup("builtin-copy")?.kind, .aux)
        XCTAssertEqual(KindTable.v1.lookup("builtin-create-build-directory")?.isPrefix, true)
    }

    func testUnknownRuleHasNoEntry() {
        XCTAssertNil(KindTable.v1.lookup("FrobnicateThing"))
        XCTAssertNil(KindTable.v1.lookup("swiftcompile"))
    }

    func testRepresentativeKindsAndPhases() {
        XCTAssertEqual(KindTable.v1.lookup("SwiftCompile")?.kind, .swiftCompile)
        XCTAssertEqual(KindTable.v1.lookup("SwiftDriver Compilation Requirements")?.kind, .gate)
        XCTAssertEqual(KindTable.v1.lookup("SwiftExplicitDependencyGeneratePcm")?.kind, .modulePrecompile)
        XCTAssertEqual(KindTable.v1.lookup("Ld")?.phase, .link)
        XCTAssertEqual(KindTable.v1.lookup("CodeSign")?.phase, .sign)
        XCTAssertEqual(KindTable.v1.lookup("CreateBuildDescription")?.kind, .planning)
        XCTAssertEqual(KindTable.v1.lookup("SwiftExplicitDependencyCompileModuleFromInterface")?.xcode.from, "27.0")
    }

    func testNoDuplicateRows() {
        let names = KindTable.v1.entries.map(\.ruleName)
        XCTAssertEqual(Set(names).count, names.count)
    }
}
