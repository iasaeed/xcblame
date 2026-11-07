/// Maps a task rule name to `(TaskKind, Phase, Xcode range)` (DESIGN §5.5, §4.3 rule 6). Version-dependent data
/// lives here, not in code.
public struct KindTable: Sendable {
    /// Xcode versions a row applies to, as "major.minor" strings; nil bound = open-ended.
    public struct XcodeRange: Sendable, Hashable {
        public var from: String?
        public var through: String?

        public init(from: String? = nil, through: String? = nil) {
            self.from = from
            self.through = through
        }

        public static let any = XcodeRange()
    }

    public struct Entry: Sendable, Hashable {
        public var ruleName: String
        public var kind: TaskKind
        public var phase: Phase
        public var xcode: XcodeRange
        /// When true, `ruleName` is a prefix (e.g. `builtin-`).
        public var isPrefix: Bool

        public init(_ ruleName: String, _ kind: TaskKind, _ phase: Phase, xcode: XcodeRange = .any,
                    isPrefix: Bool = false) {
            self.ruleName = ruleName
            self.kind = kind
            self.phase = phase
            self.xcode = xcode
            self.isPrefix = isPrefix
        }
    }

    public let version: String
    public let entries: [Entry]
    private let exact: [String: Entry]
    private let prefixes: [Entry]

    public init(version: String, entries: [Entry]) {
        self.version = version
        self.entries = entries
        var exact: [String: Entry] = [:]
        for entry in entries where !entry.isPrefix { exact[entry.ruleName] = entry }
        self.exact = exact
        self.prefixes = entries.filter(\.isPrefix)
    }

    /// Exact rule-name hit first, then prefix rows. The Xcode range is informational in v1 (the producing Xcode is
    /// often unknown at classification time), so it does not filter.
    public func lookup(_ ruleName: String) -> Entry? {
        if let hit = exact[ruleName] { return hit }
        return prefixes.first { ruleName.hasPrefix($0.ruleName) }
    }

    /// Phase for a kind decided without a table row (command-line tool fallback).
    public static func defaultPhase(for kind: TaskKind) -> Phase {
        switch kind {
        case .swiftCompile, .swiftPlan, .swiftEmitModule, .moduleScan, .modulePrecompile, .clangCompile, .gate:
            return .compile
        case .link: return .link
        case .assets, .resources, .copy, .metadata, .validate: return .package
        case .codesign: return .sign
        case .planning, .packageResolution, .sdkStatCache: return .planning
        case .script, .aux, .clean, .other: return .other
        }
    }

    /// Rule names from DESIGN §5.5 item 1, plus rules seen in the r26/r27 fixtures.
    public static let v1 = KindTable(version: "2026.10.1", entries: [
        // Swift
        Entry("SwiftCompile", .swiftCompile, .compile),
        Entry("SwiftDriver", .swiftPlan, .compile),
        Entry("SwiftDriverJobDiscovery", .swiftPlan, .compile),
        Entry("SwiftDriver Compilation", .gate, .compile),
        Entry("SwiftDriver Compilation Requirements", .gate, .compile),
        Entry("SwiftEmitModule", .swiftEmitModule, .compile),
        Entry("EmitSwiftModule", .swiftEmitModule, .compile),
        Entry("SwiftMergeGeneratedHeaders", .aux, .compile),
        // Explicit modules
        Entry("ScanDependencies", .moduleScan, .compile),
        Entry("SwiftExplicitDependencyGeneratePcm", .modulePrecompile, .compile),
        Entry("SwiftExplicitDependencyCompileModuleFromInterface", .modulePrecompile, .compile,
              xcode: XcodeRange(from: "27.0")),
        Entry("PrecompileModule", .modulePrecompile, .compile),
        Entry("PruneExplicitPrecompiledModules", .aux, .compile, xcode: XcodeRange(from: "27.0")),
        Entry("ClangStatCache", .sdkStatCache, .planning),
        // C family, link
        Entry("CompileC", .clangCompile, .compile),
        Entry("Ld", .link, .link),
        Entry("Libtool", .link, .link),
        Entry("ConstructStubExecutorLinkFileList", .aux, .link),
        // Scripts, resources, packaging
        Entry("PhaseScriptExecution", .script, .other),
        Entry("CompileAssetCatalogVariant", .assets, .package),
        Entry("LinkAssetCatalog", .assets, .package),
        Entry("GenerateAssetSymbols", .assets, .package),
        Entry("ExtractAppIntentsMetadata", .metadata, .package),
        Entry("ProcessInfoPlistFile", .resources, .package),
        Entry("CpResource", .resources, .package),
        Entry("Copy", .copy, .package),
        Entry("CopySwiftLibs", .copy, .package),
        Entry("Touch", .aux, .package),
        // Signing, validation, registration
        Entry("CodeSign", .codesign, .sign),
        Entry("RegisterExecutionPolicyException", .aux, .sign),
        Entry("RegisterWithLaunchServices", .aux, .other),
        Entry("ValidateEmbeddedBinary", .validate, .package),
        Entry("Validate", .validate, .package),
        // Build-system planning
        Entry("CreateBuildDescription", .planning, .planning),
        Entry("ComputeTargetDependencyGraph", .planning, .planning),
        Entry("ComputePackagePrebuildTargetDependencyGraph", .planning, .planning),
        Entry("SendProjectDescription", .planning, .planning),
        Entry("CreateBuildRequest", .planning, .planning),
        Entry("CreateBuildOperation", .planning, .planning),
        Entry("GatherProvisioningInputs", .planning, .planning),
        // Auxiliary
        Entry("GenerateClangModulesReport", .aux, .other),
        Entry("GenerateSwiftModulesReport", .aux, .other),
        Entry("WriteAuxiliaryFile", .aux, .other),
        Entry("MkDir", .aux, .other),
        Entry("CreateBuildDirectory", .aux, .other),
        Entry("ExecuteExternalTool", .aux, .other),
        Entry("builtin-", .aux, .other, isPrefix: true),
    ])
}
