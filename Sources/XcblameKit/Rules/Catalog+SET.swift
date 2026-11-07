import Foundation

// Build settings (RULES.md §2): the rows as Swift literals (columns verbatim from docs/RULES.md) and their predicates.
extension RuleCatalog {
    static let setRules: [Rule] = [
        Rule(spec: RuleSpec(
            id: "SET-001", name: "swift-compilation-mode-per-config", category: .set, detection: .both,
            signal: "Effective Debug `SWIFT_COMPILATION_MODE = wholemodule`, or `-wmo`/`-whole-module-optimization` in `OTHER_SWIFT_FLAGS`, or legacy `SWIFT_OPTIMIZATION_LEVEL = -Owholemodule`. D: Debug log shows one compile task per module covering all files (`wmo` granularity).",
            fix: "Debug `SWIFT_COMPILATION_MODE = singlefile`; Release untouched.",
            applyKinds: [.overlayDebug], verifyOnly: false,
            impactContext: "M incremental, clean neutral (mechanism [P] S13: any edit rebuilds the module; no number)",
            risk: "Low. Never touch Release. Target-level overrides create variants (SET-024).",
            configurations: .debug, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "P"),
            sources: ["[OC] A1", "https://github.com/swiftlang/swift/blob/main/docs/CompilerPerformance.md"],
            conflicts: [], signalKeyTemplate: "setting:SWIFT_COMPILATION_MODE:<targets>:<configs>",
            summary: "Whole-module compilation in a Debug-like configuration makes every edit recompile the whole module. Debug should compile single-file (incremental); Release keeps whole-module.",
            severity: .medium), evaluate: SETChecks.compilationMode),
        Rule(spec: RuleSpec(
            id: "SET-002", name: "swift-optimization-level-debug-onone", category: .set, detection: .static,
            signal: "Debug `SWIFT_OPTIMIZATION_LEVEL` ≠ `-Onone`.",
            fix: "Debug `-Onone`.",
            applyKinds: [.overlayDebug], verifyOnly: false,
            impactContext: "? (qualitative \"significant SIL and LLVM time\" [P] S13)",
            risk: "Debug perf not representative.",
            configurations: .debug, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "P"),
            sources: ["[OC] A2", "https://github.com/swiftlang/swift/blob/main/docs/CompilerPerformance.md"],
            conflicts: [], signalKeyTemplate: "setting:SWIFT_OPTIMIZATION_LEVEL:<targets>:<configs>",
            summary: "An optimizing Swift level in a Debug-like configuration spends SIL and LLVM optimizer time on every iteration build. Debug should use -Onone.",
            severity: .medium), evaluate: SETChecks.optimizationLevel),
        Rule(spec: RuleSpec(
            id: "SET-003", name: "gcc-optimization-level-debug-zero", category: .set, detection: .static,
            signal: "Debug `GCC_OPTIMIZATION_LEVEL` ≠ `0` in a target with C/ObjC sources.",
            fix: "Debug `0`.",
            applyKinds: [.overlayDebug], verifyOnly: false,
            impactContext: "? (ObjC-heavy targets only)",
            risk: "Hides optimizer-only bugs (fine in Debug).",
            configurations: .debug, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] A3"],
            conflicts: [], signalKeyTemplate: "setting:GCC_OPTIMIZATION_LEVEL:<targets>:<configs>",
            summary: "An optimizing C/ObjC level in a Debug-like configuration slows Clang compiles in targets with C-family sources. Debug should use 0.",
            severity: .low), evaluate: SETChecks.gccOptimizationLevel),
        Rule(spec: RuleSpec(
            id: "SET-004", name: "debug-information-format-dwarf-debug", category: .set, detection: .both,
            signal: "Debug `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym`. D: `GenerateDSYMFile` tasks in Debug logs (seconds measured).",
            fix: "Debug `dwarf`. Skip if a Debug-config upload script exists (PHASE-002 signature) or Debug builds are distributed.",
            applyKinds: [.overlayDebug], verifyOnly: false,
            impactContext: "Measured; context: dSYM ~25 s of an 82 s cycle (Spotify, old [S], [BP] §4)",
            risk: "Breaks symbolication if Debug builds are shipped. Release must keep dSYM.",
            configurations: .debug, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] A4", "[BP] §4"],
            conflicts: ["PHASE-002"], signalKeyTemplate: "setting:DEBUG_INFORMATION_FORMAT:<targets>:<configs>",
            summary: "Debug builds that produce dSYMs run GenerateDSYMFile on every build. Debug should use dwarf; Release keeps dwarf-with-dsym for symbolication.",
            severity: .medium), evaluate: SETChecks.debugInformationFormat),
        Rule(spec: RuleSpec(
            id: "SET-005", name: "only-active-arch-debug", category: .set, detection: .both,
            signal: "Debug `ONLY_ACTIVE_ARCH = NO`, hard-coded multi-arch `ARCHS`, `VALID_ARCHS`. D: Debug compile tasks for more than one arch (`normal arm64` and `normal x86_64`).",
            fix: "Debug `YES`; CI generic destinations: `cli` `ONLY_ACTIVE_ARCH=YES`.",
            applyKinds: [.overlayDebug, .cli], verifyOnly: false,
            impactContext: "Measured = duplicated-arch task time; context \"multiplies compile and link\" [S] S1",
            risk: "Ignored for generic destinations; never Release/archive.",
            configurations: .debug, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] A5", "https://raw.githubusercontent.com/AvdLee/Xcode-Build-Optimization-Agent-Skill/main/OPTIMIZATION-CHECKS.md"],
            conflicts: [], signalKeyTemplate: "setting:ONLY_ACTIVE_ARCH:<targets>:<configs>",
            summary: "Building every architecture in a Debug-like configuration multiplies compile and link work. Debug should build only the active architecture.",
            severity: .medium), evaluate: SETChecks.onlyActiveArch),
        Rule(spec: RuleSpec(
            id: "SET-006", name: "excluded-archs-simulator-arm64-hack", category: .set, detection: .static,
            signal: "`EXCLUDED_ARCHS[sdk=iphonesimulator*]` contains `arm64` (often Podfile `post_install`).",
            fix: "Remove once all deps ship arm64-simulator slices.",
            applyKinds: [.recommend], verifyOnly: true,
            impactContext: "? needs measurement",
            risk: "Breaks deps without arm64-sim slices.",
            configurations: .debug, xcode: "12+", evidenceTag: RuleSpec.EvidenceTag(text: "K"),
            sources: ["[OC] A6"],
            conflicts: [], signalKeyTemplate: "setting:EXCLUDED_ARCHS[sdk=iphonesimulator*]:<targets>",
            summary: "Excluding arm64 for the simulator (an Apple-silicon workaround, often from a Podfile post_install) forces Rosetta simulators and x86_64 builds. Remove it once every dependency ships an arm64-simulator slice; needs measurement.",
            severity: .low), evaluate: SETChecks.excludedArchsSimulator),
        Rule(spec: RuleSpec(
            id: "SET-007", name: "enable-testability-release-no (incl. B10)", category: .set, detection: .static,
            signal: "Release `ENABLE_TESTABILITY = YES`; `@testable import` in non-test target sources.",
            fix: "Release `NO`; keep Debug `YES`; move `@testable` to test targets.",
            applyKinds: [.overlayRelease, .recommend], verifyOnly: false,
            impactContext: "XS-S (mostly Release size/perf)",
            risk: "Release-config test runs need YES.",
            configurations: .release, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "P"),
            sources: ["[OC] A7"],
            conflicts: [], signalKeyTemplate: "setting:ENABLE_TESTABILITY:<targets>:<configs>",
            summary: "ENABLE_TESTABILITY in Release exports internal symbols and limits optimization. Release should use NO; Debug keeps YES for @testable imports.",
            severity: .low), evaluate: SETChecks.testabilityRelease),
        Rule(spec: RuleSpec(
            id: "SET-008", name: "compiler-index-store-enable-ci (incl. G5)", category: .set, detection: .static,
            signal: "CI environment (`CI=true` etc.) and the xcodebuild invocation lacks `COMPILER_INDEX_STORE_ENABLE=NO`.",
            fix: "Pass `COMPILER_INDEX_STORE_ENABLE=NO` on the CI command line only. Never set in the project.",
            applyKinds: [.cli], verifyOnly: false,
            impactContext: "? (no number; Bitrise step does it, S41)",
            risk: "Periphery, SwiftLint analyze, SourceKit-LSP in CI need the index; no DataStore with remote caching (S19).",
            configurations: .ci, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] A8", "https://github.com/bitrise-steplib/steps-xcode-build-for-simulator/releases/0.10.0", "https://docs.bitrise.io/en/bitrise-build-cache/build-cache-for-xcode/xcode-compilation-cache-faq.html"],
            conflicts: [], signalKeyTemplate: "ci:COMPILER_INDEX_STORE_ENABLE",
            summary: "CI builds write the index store nobody reads. Pass COMPILER_INDEX_STORE_ENABLE=NO on the CI command line only, never in the project.",
            severity: .low), evaluate: SETChecks.indexStoreCI),
        Rule(spec: RuleSpec(
            id: "SET-009", name: "swift-enable-batch-mode", category: .set, detection: .static,
            signal: "`SWIFT_ENABLE_BATCH_MODE = NO`, or `-disable-batch-mode`/`-no-enable-batch-mode` in committed `OTHER_SWIFT_FLAGS`.",
            fix: "Remove override.",
            applyKinds: [.overlay, .pbxproj], verifyOnly: false,
            impactContext: "? (theory: 10,000 vs 400 parses for 100 files on 4 CPUs [P] S13)",
            risk: "None known.",
            configurations: .both, xcode: "10+", evidenceTag: RuleSpec.EvidenceTag(text: "P"),
            sources: ["[OC] A9", "https://github.com/swiftlang/swift/blob/main/docs/CompilerPerformance.md"],
            conflicts: [], signalKeyTemplate: "setting:SWIFT_ENABLE_BATCH_MODE:<targets>:<configs>",
            summary: "Disabling Swift batch mode makes the driver run one frontend per file, re-parsing every file once per frontend. Remove the override.",
            severity: .medium), evaluate: SETChecks.batchMode),
        Rule(spec: RuleSpec(
            id: "SET-010", name: "enable-bitcode-dead", category: .set, detection: .static,
            signal: "`ENABLE_BITCODE = YES`; `-fembed-bitcode`/`-embed-bitcode` in `OTHER_*FLAGS`/`OTHER_LDFLAGS`; Podfile setting it.",
            fix: "`ENABLE_BITCODE = NO`; remove flags.",
            applyKinds: [.overlay, .pbxproj], verifyOnly: false,
            impactContext: "XS on 14+ (deprecated; extra work on ≤ 13)",
            risk: "None for linking.",
            configurations: .both, xcode: "≤13 matters; 14+ cleanup", evidenceTag: RuleSpec.EvidenceTag(text: "P"),
            sources: ["[OC] A10"],
            conflicts: [], signalKeyTemplate: "setting:ENABLE_BITCODE:<targets>:<configs>",
            summary: "Bitcode is deprecated since Xcode 14; ENABLE_BITCODE and -embed-bitcode flags are dead weight (and extra work on Xcode 13 and older). Set NO and remove the flags.",
            severity: .low), evaluate: SETChecks.bitcode),
        Rule(spec: RuleSpec(
            id: "SET-011", name: "validate-product-debug-no", category: .set, detection: .both,
            signal: "Debug `VALIDATE_PRODUCT = YES`. D: `Validate`/`ValidateEmbeddedBinary` executed in zero-change builds.",
            fix: "Debug `NO`.",
            applyKinds: [.overlayDebug], verifyOnly: true,
            impactContext: "Measured; context: listed as unconditional zero-change overhead S1",
            risk: "Hides embedding/provisioning errors until Release.",
            configurations: .debug, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "S/K"),
            sources: ["[OC] A11"],
            conflicts: [], signalKeyTemplate: "setting:VALIDATE_PRODUCT:<targets>:<configs>",
            summary: "Product validation in a Debug-like configuration runs Validate tasks on every build, zero-change builds included. Debug can skip it (Release keeps it); needs measurement.",
            severity: .low), evaluate: SETChecks.validateProduct),
        Rule(spec: RuleSpec(
            id: "SET-013", name: "swift-enable-explicit-modules", category: .set, detection: .both,
            signal: "Xcode ≥ 26: explicit `SWIFT_ENABLE_EXPLICIT_MODULES = NO` (review). Xcode 16-25: `_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES` unset (candidate). D: scan/PCM task time and variant counts.",
            fix: "26+: keep default ON (required for SET-016); 16-25: benchmark only.",
            applyKinds: [.recommend, .overlay], verifyOnly: true,
            impactContext: "Conflict: Xcode 16 beta clean builds 1.7-43 % slower (S20); default on in 26 (S8). Conservative: never recommend disabling on 26+.",
            risk: "Variants (SET-024); Xcode 27 requires unique Clang module names (S33); off for Swift/C++ interop.",
            configurations: .both, xcode: "16+", evidenceTag: RuleSpec.EvidenceTag(text: "P/S"),
            sources: ["[OC] A13", "https://bitrise.io/blog/post/demystifying-explicitly-built-modules-for-xcode", "https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes", "https://blakecrosley.com/blog/xcode-27-build-failures-ld64-clang-modules"],
            conflicts: ["SET-016"], signalKeyTemplate: "setting:SWIFT_ENABLE_EXPLICIT_MODULES:<targets>:<configs>",
            summary: "Explicit modules are on by default from Xcode 26 and required for compilation caching. On 26+ an explicit NO is reported for review (never \"disable\"); on 16-25 enabling them is a benchmark only.",
            severity: .low), evaluate: SETChecks.explicitModules),
        Rule(spec: RuleSpec(
            id: "SET-014", name: "clang-enable-modules-and-imports", category: .set, detection: .static,
            signal: "`CLANG_ENABLE_MODULES = NO`; framework targets with `DEFINES_MODULE ≠ YES`; `#import \"Fw.h\"` for framework headers.",
            fix: "`CLANG_ENABLE_MODULES = YES`, `DEFINES_MODULE = YES`; framework-qualified imports.",
            applyKinds: [.overlay, .recommend], verifyOnly: true,
            impactContext: "? (ObjC-heavy code)",
            risk: "Non-self-contained headers fail as modules.",
            configurations: .both, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "P/K"),
            sources: ["[OC] A14"],
            conflicts: [], signalKeyTemplate: "setting:CLANG_ENABLE_MODULES:<targets>:<configs>",
            summary: "Clang modules let ObjC targets reuse precompiled headers instead of re-parsing them per file. Keep CLANG_ENABLE_MODULES and DEFINES_MODULE on; needs measurement.",
            severity: .low), evaluate: SETChecks.clangModules),
        Rule(spec: RuleSpec(
            id: "SET-015", name: "swift-use-integrated-driver", category: .set, detection: .static,
            signal: "`SWIFT_USE_INTEGRATED_DRIVER = NO`.",
            fix: "Remove (or `YES`) unless XCRemoteCache is in use (DEP-010). On 26+: report as blocking SET-016.",
            applyKinds: [.overlay, .recommend], verifyOnly: true,
            impactContext: "Conflict: AutoScout24 Xcode 14 incremental 103 s to 18 s with `NO` ([PP] A6); YES required for caching (S18); reportedly removed in 26.5 ([DS] §0). Never recommend `NO`.",
            risk: "Conflicts with XCRemoteCache.",
            configurations: .both, xcode: "14+", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] A15", "[PP] A6", "[DS] §0", "https://bitrise.io/blog/post/lifting-the-hood-on-build-cache-for-xcode"],
            conflicts: ["DEP-010", "SET-016"], signalKeyTemplate: "setting:SWIFT_USE_INTEGRATED_DRIVER:<targets>:<configs>",
            summary: "SWIFT_USE_INTEGRATED_DRIVER = NO falls back to the legacy driver and blocks compilation caching on Xcode 26+. Remove it unless XCRemoteCache needs it.",
            severity: .medium), evaluate: SETChecks.integratedDriver),
        Rule(spec: RuleSpec(
            id: "SET-016", name: "compilation-cache-enable-caching", category: .set, detection: .both,
            signal: "Xcode ≥ 26, `COMPILATION_CACHE_ENABLE_CACHING` unset/`NO`, explicit modules and integrated driver on. D: clean/branch-switch builds with no cache metrics.",
            fix: "`COMPILATION_CACHE_ENABLE_CACHING = YES` (Debug first).",
            applyKinds: [.overlayDebug], verifyOnly: true,
            impactContext: "? until verified on this project; context: clean/branch switch 5-14 % (S2), 19-77 % local (Tuist vendor, S17), \"up to 30 %\" (S21), no change on one CI (S31); first build slower (S4)",
            risk: "DerivedData growth (20.65 to 47.66 GB report); `clean` does not clear the CAS; storyboards/assets/scripts/link not cacheable; SPM package targets not cacheable in the 26 beta (S19) and unverified since, so the finding states its scope (project targets) and keeps band `?` when packages dominate task time (the corpus app: ~108 of 138 s); path-sensitive keys.",
            configurations: .debug, xcode: "26+", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] A16", "https://raw.githubusercontent.com/AvdLee/Xcode-Build-Optimization-Agent-Skill/main/references/build-settings-best-practices.md", "https://tuist.dev/blog/2025/10/22/xcode-cache", "https://www.bitrise.io/blog/post/expert-tips-to-speed-up-your-ios-builds", "https://forums.swift.org/t/how-to-make-incremental-builds-work-on-a-mac-mini-ci-with-xcode-26/83653", "https://www.avanderlee.com/xcode/xcode-build-optimization-using-6-agent-skills/", "https://docs.bitrise.io/en/bitrise-build-cache/build-cache-for-xcode/xcode-compilation-cache-faq.html"],
            conflicts: ["SET-013", "SET-015", "DEP-010"], signalKeyTemplate: "setting:COMPILATION_CACHE_ENABLE_CACHING:<targets>:<configs>",
            summary: "Xcode 26 can cache compilation results by content, which speeds clean and branch-switch builds of project targets. Try COMPILATION_CACHE_ENABLE_CACHING = YES in Debug first, kept only if verify measures it faster.",
            severity: .medium), evaluate: SETChecks.compilationCache),
        Rule(spec: RuleSpec(
            id: "SET-017", name: "compilation-cache-remote (incl. G7)", category: .set, detection: .static,
            signal: "Xcode ≥ 26; CI environment detected; history has ≥ 3 CI builds of kind `clean` in the last 7 days; neither `COMPILATION_CACHE_ENABLE_PLUGIN` nor `COMPILATION_CACHE_REMOTE_SERVICE_PATH` set.",
            fix: "Adopt a cache service (Tuist, Bitrise). Populate on main-branch builds; identical paths/Xcode on consumers or Xcode 27 prefix mapping (`SWIFT_ENABLE_PREFIX_MAPPING`, `CLANG_ENABLE_PREFIX_MAPPING`).",
            applyKinds: [.recommend], verifyOnly: false,
            impactContext: "M-L clean CI: remote 18-69 % (Tuist vendor S17)",
            risk: "Needs a service; Xcode UI builds not covered by wrappers (S18); remote slower than local.",
            configurations: .ci, xcode: "26+", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] A17", "https://tuist.dev/blog/2025/10/22/xcode-cache", "https://bitrise.io/blog/post/lifting-the-hood-on-build-cache-for-xcode"],
            conflicts: [], signalKeyTemplate: "ci:compilation-cache-remote",
            summary: "CI clean builds on Xcode 26+ can share a remote compilation cache. Adopt a cache service and populate it from main-branch builds.",
            severity: .low), evaluate: SETChecks.remoteCache),
        Rule(spec: RuleSpec(
            id: "SET-020", name: "timing-diagnostic-flags-hygiene", category: .set, detection: .static,
            signal: "`-debug-time-*`, `-warn-long-*` or `-stats-output-dir` present in a committed `OTHER_SWIFT_FLAGS` value (pbxproj/xcconfig) of a Release configuration, or of any configuration a CI invocation uses.",
            fix: "Remove from committed config; use `xcblame build --deep` (command-line, isolated DerivedData).",
            applyKinds: [.pbxproj, .recommend], verifyOnly: false,
            impactContext: "Diagnostic; heavy flags slow builds (S13)",
            risk: "`SWIFT_TREAT_WARNINGS_AS_ERRORS` breaks with warn-long.",
            configurations: .both, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "P"),
            sources: ["[OC] A20", "https://github.com/swiftlang/swift/blob/main/docs/CompilerPerformance.md"],
            conflicts: [], signalKeyTemplate: "setting:OTHER_SWIFT_FLAGS:timing-diagnostics:<targets>:<configs>",
            summary: "Timing diagnostic flags committed to a Release or CI configuration slow every build that uses it. Remove them; use xcblame build --deep for one-off measurements.",
            severity: .low), evaluate: SETChecks.timingFlags),
        Rule(spec: RuleSpec(
            id: "SET-021", name: "gcc-precompile-prefix-header", category: .set, detection: .static,
            signal: "`GCC_PREFIX_HEADER` set and `GCC_PRECOMPILE_PREFIX_HEADER = NO`; or prefix header imports project headers changed in the last 30 days (git log).",
            fix: "`YES`; keep prefix to stable/system headers; prefer modules.",
            applyKinds: [.overlay, .recommend], verifyOnly: false,
            impactContext: "?",
            risk: "Frequent prefix changes increase build time (S9).",
            configurations: .both, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "P"),
            sources: ["[OC] A21", "https://developer.apple.com/documentation/xcode/build-settings-reference"],
            conflicts: [], signalKeyTemplate: "setting:GCC_PRECOMPILE_PREFIX_HEADER:<targets>:<configs>",
            summary: "A prefix header that is not precompiled is re-parsed by every C-family compile. Precompile it and keep it to stable headers.",
            severity: .low), evaluate: SETChecks.prefixHeader),
        Rule(spec: RuleSpec(
            id: "SET-022", name: "headermap-and-header-search-paths", category: .set, detection: .static,
            signal: "`USE_HEADERMAP = NO`; `/**` in `HEADER_SEARCH_PATHS`/`USER_HEADER_SEARCH_PATHS`; `ALWAYS_SEARCH_USER_PATHS = YES`.",
            fix: "Booleans to defaults; explicit paths/module maps.",
            applyKinds: [.overlay, .recommend], verifyOnly: true,
            impactContext: "? needs measurement",
            risk: "Path removal breaks imports.",
            configurations: .both, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "K"),
            sources: ["[OC] A22"],
            conflicts: [], signalKeyTemplate: "setting:header-search:<targets>:<configs>",
            summary: "Disabled header maps, recursive header search paths and user-path searching make Clang stat many directories per include. Needs measurement.",
            severity: .low), evaluate: SETChecks.headerSearch),
        Rule(spec: RuleSpec(
            id: "SET-023", name: "eager-linking-debug", category: .set, detection: .static,
            signal: "Debug `EAGER_LINKING ≠ YES` and ≥ 2 Swift-only dynamic framework targets in the graph.",
            fix: "Debug `YES`.",
            applyKinds: [.overlayDebug], verifyOnly: true,
            impactContext: "? (larger on deep dynamic graphs)",
            risk: "No effect on static or ObjC targets.",
            configurations: .debug, xcode: "14+", evidenceTag: RuleSpec.EvidenceTag(text: "P"),
            sources: ["[OC] A23"],
            conflicts: [], signalKeyTemplate: "setting:EAGER_LINKING:<targets>:<configs>",
            summary: "With two or more Swift-only dynamic frameworks, eager linking lets dependents link against TBDs earlier in Debug builds.",
            severity: .low), evaluate: SETChecks.eagerLinking),
        Rule(spec: RuleSpec(
            id: "SET-027", name: "remove-ld-classic", category: .set, detection: .static,
            signal: "`-ld_classic`, `-Wl,-ld_classic`, `-ld64` in `OTHER_LDFLAGS` or Podfile `post_install`.",
            fix: "Remove. On Xcode 27 mandatory: ld64 removed, `-ld64` fails, `-ld_classic` ignored with warning ([DS] §5).",
            applyKinds: [.pbxproj, .manifest], verifyOnly: false,
            impactContext: "M link: ld64 ~2x faster in Xcode 14, new linker default 15 (S11, S49)",
            risk: "Flag was a workaround for 15.0.x LTO/branch-fixup bugs.",
            configurations: .both, xcode: "15+ (27: required)", evidenceTag: RuleSpec.EvidenceTag(text: "P"),
            sources: ["[OC] A27", "[DS] §5", "https://developer.apple.com/videos/play/wwdc2022/110362/", "https://developer.apple.com/forums/thread/741240"],
            conflicts: [], signalKeyTemplate: "setting:OTHER_LDFLAGS:ld-classic",
            summary: "-ld_classic and -ld64 select the old linker, about twice as slow as the default linker, and Xcode 27 removes it. Remove the flags.",
            severity: .medium), evaluate: SETChecks.ldClassic),
        Rule(spec: RuleSpec(
            id: "SET-028", name: "llvm-lto-mode", category: .set, detection: .static,
            signal: "`LLVM_LTO = YES` (monolithic), or any LTO in Debug.",
            fix: "Debug `NO`; Release `YES_THIN` unless measured otherwise.",
            applyKinds: [.overlayDebug, .recommend], verifyOnly: true,
            impactContext: "? (monolithic slowest, S9; Spotify old: LTO 51 % of link time, [BP] §4)",
            risk: "Thin LTO may optimize slightly less.",
            configurations: .both, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "P"),
            sources: ["[OC] A28", "[BP] §4", "https://developer.apple.com/documentation/xcode/build-settings-reference"],
            conflicts: [], signalKeyTemplate: "setting:LLVM_LTO:<targets>:<configs>",
            summary: "Link-time optimization in Debug, or monolithic LTO anywhere, makes links much slower. Debug NO; Release YES_THIN unless measured otherwise.",
            severity: .low), evaluate: SETChecks.lto),
        Rule(spec: RuleSpec(
            id: "SET-029", name: "strip-settings-debug-off", category: .set, detection: .static,
            signal: "Debug `COPY_PHASE_STRIP = YES` or `DEPLOYMENT_POSTPROCESSING = YES`.",
            fix: "Debug `NO` for both.",
            applyKinds: [.overlayDebug], verifyOnly: true,
            impactContext: "XS",
            risk: "Release keeps stripping.",
            configurations: .debug, xcode: "all", evidenceTag: RuleSpec.EvidenceTag(text: "S/K"),
            sources: ["[OC] A29"],
            conflicts: [], signalKeyTemplate: "setting:strip:<targets>:<configs>",
            summary: "Stripping in a Debug-like configuration adds work and hurts debugging. Debug should set COPY_PHASE_STRIP and DEPLOYMENT_POSTPROCESSING to NO.",
            severity: .low), evaluate: SETChecks.stripDebug),
        Rule(spec: RuleSpec(
            id: "SET-030", name: "user-script-sandboxing-and-parallel-scripts", category: .set, detection: .static,
            signal: "`ENABLE_USER_SCRIPT_SANDBOXING` unset/`NO`; `FUSE_BUILD_SCRIPT_PHASES` absent; only after PHASE-001 has no open findings.",
            fix: "Enable both.",
            applyKinds: [.overlay], verifyOnly: true,
            impactContext: "? (reduces serialization)",
            risk: "Scripts reading undeclared files fail; CocoaPods scripts often need xcfilelists. `FUSE_BUILD_SCRIPT_PHASES` naming from a WebKit bug (S48).",
            configurations: .both, xcode: "14+", evidenceTag: RuleSpec.EvidenceTag(text: "P/S"),
            sources: ["[OC] A30", "https://bugs.webkit.org/show_bug.cgi?id=315128"],
            conflicts: ["PHASE-001"], signalKeyTemplate: "setting:script-sandboxing:<configs>",
            summary: "User script sandboxing plus parallel script phases let the build system schedule scripts with declared inputs and outputs concurrently. Only after every script phase declares its inputs and outputs (PHASE-001).",
            severity: .low), evaluate: SETChecks.scriptSandboxing),
        Rule(spec: RuleSpec(
            id: "SET-031", name: "cross-module-optimization-debug", category: .set, detection: .static,
            signal: "`-cross-module-optimization` or `-enable-default-cmo` in Debug flags.",
            fix: "Remove from Debug; Release only if runtime gain proven.",
            applyKinds: [.pbxproj, .recommend], verifyOnly: false,
            impactContext: "? (compile cost unmeasured)",
            risk: "Code-size changes.",
            configurations: .debug, xcode: "5.5+", evidenceTag: RuleSpec.EvidenceTag(text: "S"),
            sources: ["[OC] A31"],
            conflicts: [], signalKeyTemplate: "setting:OTHER_SWIFT_FLAGS:cmo:<targets>:<configs>",
            summary: "Cross-module optimization flags in Debug add optimizer work to every iteration build. Remove them from Debug.",
            severity: .low), evaluate: SETChecks.crossModuleOptimization),
        Rule(spec: RuleSpec(
            id: "SET-032", name: "build-library-for-distribution-internal", category: .set, detection: .static,
            signal: "`BUILD_LIBRARY_FOR_DISTRIBUTION = YES` on targets not exported as XCFrameworks (no `-create-xcframework` script/CI step).",
            fix: "`NO` for internal modules.",
            applyKinds: [.overlay, .pbxproj], verifyOnly: true,
            impactContext: "?",
            risk: "Required for distributed binaries.",
            configurations: .both, xcode: "11+", evidenceTag: RuleSpec.EvidenceTag(text: "P/K"),
            sources: ["[OC] A32"],
            conflicts: [], signalKeyTemplate: "setting:BUILD_LIBRARY_FOR_DISTRIBUTION:<targets>:<configs>",
            summary: "BUILD_LIBRARY_FOR_DISTRIBUTION on modules that are not shipped as XCFrameworks emits module interfaces nobody consumes. Set NO for internal modules.",
            severity: .low), evaluate: SETChecks.libraryForDistribution),
    ]
}

/// SET predicates. Settings rules read effective values per project target and configuration role; evidence carries
/// the provenance of each value, and the engine decides whether the overlay line can win (DESIGN §7.5).
enum SETChecks {
    typealias Target = ProjectModel.Target

    static func swiftTargets(_ target: Target) -> Bool { target.hasSwiftSources }
    static func cTargets(_ target: Target) -> Bool { target.hasCSources }
    static func compileTargets(_ target: Target) -> Bool { target.hasSwiftSources || target.hasCSources }

    /// SET-001.
    static func compilationMode(_ s: RuleScan) -> Evaluation {
        let configurations = s.configurations(.debug)
        let mode = s.audit("SWIFT_COMPILATION_MODE", configurations, targets: swiftTargets) { $0 == "wholemodule" }
        let flags = s.audit("OTHER_SWIFT_FLAGS", configurations, targets: swiftTargets) {
            RuleScan.words($0).contains { $0 == "-wmo" || $0 == "-whole-module-optimization" }
        }
        let legacy = s.audit("SWIFT_OPTIMIZATION_LEVEL", configurations, targets: swiftTargets) { $0 == "-Owholemodule" }
        guard !mode.bad.isEmpty || !flags.bad.isEmpty || !legacy.bad.isEmpty else {
            return s.settingEvaluation(mode, which: .debug, apply: .overlayDebug, overlay: [], fix: "",
                                       noTargets: "no Swift targets with effective settings")
        }
        let all = mode.bad + flags.bad + legacy.bad
        var hit = RuleHit(title: (mode.bad.isEmpty ? (flags.bad.isEmpty ? s.settingTitle(legacy) : s.settingTitle(flags))
                                      : s.settingTitle(mode)) + "; Debug should compile singlefile",
                          evidence: s.evidence(mode) + s.evidence(flags) + s.evidence(legacy),
                          targets: s.distinct(all.map(\.target)), configurations: s.distinct(all.map(\.configuration)),
                          apply: mode.bad.isEmpty ? .recommend : .overlayDebug,
                          overlay: mode.bad.isEmpty ? [] : [("SWIFT_COMPILATION_MODE", "singlefile")])
        if let files = s.context.document?.files {
            let wmo = files.filter { $0.granularity == "wmo" }
            if !wmo.isEmpty {
                hit.measured = Measured(seconds: wmo.reduce(0) { $0 + $1.seconds }, share: nil,
                                        basis: "\(wmo.count) whole-module compile task(s) in this build")
            }
        }
        return .hits([hit])
    }

    /// SET-002.
    static func optimizationLevel(_ s: RuleScan) -> Evaluation {
        let audit = s.audit("SWIFT_OPTIMIZATION_LEVEL", s.configurations(.debug), targets: swiftTargets) {
            $0 != nil && $0 != "-Onone"
        }
        return s.settingEvaluation(audit, which: .debug, apply: .overlayDebug,
                                   overlay: [("SWIFT_OPTIMIZATION_LEVEL", "-Onone")], fix: "; Debug should use -Onone",
                                   noTargets: "no Swift targets with effective settings")
    }

    /// SET-003.
    static func gccOptimizationLevel(_ s: RuleScan) -> Evaluation {
        let audit = s.audit("GCC_OPTIMIZATION_LEVEL", s.configurations(.debug), targets: cTargets) { $0 != nil && $0 != "0" }
        return s.settingEvaluation(audit, which: .debug, apply: .overlayDebug, overlay: [("GCC_OPTIMIZATION_LEVEL", "0")],
                                   fix: "; Debug should use 0", noTargets: "no targets with C/ObjC sources")
    }

    /// SET-004.
    static func debugInformationFormat(_ s: RuleScan) -> Evaluation {
        let audit = s.audit("DEBUG_INFORMATION_FORMAT", s.configurations(.debug), targets: compileTargets) {
            $0 == "dwarf-with-dsym"
        }
        return s.settingEvaluation(audit, which: .debug, apply: .overlayDebug,
                                   overlay: [("DEBUG_INFORMATION_FORMAT", "dwarf")], fix: "; Debug should use dwarf",
                                   noTargets: "no compiling targets with effective settings") { hit in
            for item in PHASEChecks.unguardedUploads(s) where PHASEChecks.uploadsSymbols(item.phase) {
                hit.evidence.append(s.phaseEvidence(item, "uploads dSYMs in every configuration: guard it to Release "
                    + "before Debug switches to dwarf (PHASE-002)"))
            }
            let tasks = s.buildTasks.filter { $0.rule == "GenerateDSYMFile" }
            if !tasks.isEmpty {
                hit.measured = Measured(seconds: tasks.reduce(0) { $0 + $1.seconds }, share: nil,
                                        basis: "\(tasks.count) GenerateDSYMFile task(s) in this build")
            }
        }
    }

    /// SET-005.
    static func onlyActiveArch(_ s: RuleScan) -> Evaluation {
        let configurations = s.configurations(.debug)
        // xcodebuild reports NO for generic destinations and for the generated multi-target scheme the oracle uses,
        // whatever the project says: judge the value the project files resolve to, else the effective one.
        var audit = s.audit("ONLY_ACTIVE_ARCH", configurations, targets: compileTargets,
                            read: { s.writtenValue($0, $1, $2) ?? s.value($0, $1, $2) }) { $0 == "NO" }
        var validItems: [ReportDocument.EvidenceItem] = []
        for configuration in configurations {
            for target in s.targets(in: configuration, compileTargets) {
                let written = s.provenance(target.name, "VALID_ARCHS", configuration)
                if let raw = written.rawValue {
                    validItems.append(ReportDocument.EvidenceItem(kind: "setting", ref: "\(target.name):\(configuration):VALID_ARCHS",
                                                                  value: raw, provenance: s.label(written)))
                    if !audit.bad.contains(where: { $0.target == target.name && $0.configuration == configuration }) {
                        audit.bad.append(.init(target: target.name, configuration: configuration,
                                               value: s.value(target.name, "ONLY_ACTIVE_ARCH", configuration)))
                    }
                }
            }
        }
        let ci = s.context.isCI
        return s.settingEvaluation(audit, which: .debug, apply: ci ? .cli : .overlayDebug,
                                   overlay: [("ONLY_ACTIVE_ARCH", "YES")], fix: "; Debug should build the active arch only",
                                   noTargets: "no compiling targets with effective settings") { hit in
            hit.evidence += validItems
            if ci { hit.cliArguments = ["ONLY_ACTIVE_ARCH=YES"] }
            if let measured = multiArchCost(s) { hit.measured = measured }
        }
    }

    /// Compile tasks of more than one architecture in this build: the seconds of the non-dominant ones.
    static func multiArchCost(_ s: RuleScan) -> Measured? {
        let compiles = s.buildTasks.filter { $0.kind == .swiftCompile || $0.kind == .clangCompile }
        var byArch: [String: Double] = [:]
        for task in compiles {
            // The arch is in the command line (`SwiftCompile normal arm64 …`); Swift titles carry none.
            let line = String(task.command.prefix { !$0.isNewline }) + " " + task.title
            guard let range = line.range(of: #"\b(arm64e?|x86_64|i386|armv7k?)\b"#, options: .regularExpression) else {
                continue
            }
            byArch[String(line[range]), default: 0] += task.seconds
        }
        guard byArch.count > 1, let dominant = byArch.max(by: { $0.value < $1.value })?.key else { return nil }
        let extra = byArch.filter { $0.key != dominant }.reduce(0) { $0 + $1.value }
        return Measured(seconds: extra, share: nil,
                        basis: "compile tasks for \(byArch.keys.sorted().joined(separator: " and ")) in this build")
    }

    /// SET-006.
    static func excludedArchsSimulator(_ s: RuleScan) -> Evaluation {
        var evidence: [ReportDocument.EvidenceItem] = []
        var targets: [String] = []
        for project in s.project?.projects ?? [] {
            let pbxproj = project.path.lastPathComponent
            for (configuration, settings) in project.projectSettings.sorted(by: { $0.key < $1.key }) {
                for (condition, value) in settings["EXCLUDED_ARCHS"]?.conditions ?? [:]
                where condition.contains("sdk=iphonesimulator") && RuleScan.words(value).contains("arm64") {
                    evidence.append(.init(kind: "setting", ref: "\(project.name):\(configuration):EXCLUDED_ARCHS[\(condition)]",
                                          value: value, provenance: "project settings (\(pbxproj))"))
                }
            }
            for target in project.targets {
                for (configuration, settings) in target.settings.sorted(by: { $0.key < $1.key }) {
                    for (condition, value) in settings["EXCLUDED_ARCHS"]?.conditions ?? [:]
                    where condition.contains("sdk=iphonesimulator") && RuleScan.words(value).contains("arm64") {
                        evidence.append(.init(kind: "setting", ref: "\(target.name):\(configuration):EXCLUDED_ARCHS[\(condition)]",
                                              value: value, provenance: "target settings (\(pbxproj))"))
                        targets.append(target.name)
                    }
                }
            }
        }
        if let podfile = s.podfileFacts {
            for (key, value) in s.postInstallSettings("EXCLUDED_ARCHS")
            where key.contains("sdk=iphonesimulator") && RuleScan.words(value).contains("arm64") {
                evidence.append(.init(kind: "file", ref: s.displayPath(podfile.url.path),
                                      value: "post_install sets \(key) = \(value)"))
            }
        }
        guard !evidence.isEmpty else { return .passed("no arm64 exclusion for the simulator") }
        return .hits([RuleHit(title: "arm64 excluded for the simulator (\(evidence.map(\.ref).joined(separator: ", "))); "
                                + "remove once every dependency ships an arm64-simulator slice",
                              evidence: evidence, targets: s.distinct(targets), apply: .recommend,
                              keys: ["targets": targets.isEmpty ? "*" : s.distinct(targets).joined(separator: "+")])])
    }

    /// SET-007.
    static func testabilityRelease(_ s: RuleScan) -> Evaluation {
        let audit = s.audit("ENABLE_TESTABILITY", s.configurations(.release), targets: { !$0.isTest && compileTargets($0) }) {
            $0 == "YES"
        }
        return s.settingEvaluation(audit, which: .release, apply: .overlayRelease, overlay: [("ENABLE_TESTABILITY", "NO")],
                                   fix: "; Release should use NO (the @testable source scan is not part of v0.3)",
                                   noTargets: "no non-test targets with effective settings")
    }

    /// SET-008.
    static func indexStoreCI(_ s: RuleScan) -> Evaluation {
        guard s.context.isCI else { return .notApplicable("not a CI run (CI=true is not set)") }
        let audit = s.audit("COMPILER_INDEX_STORE_ENABLE", s.configurations(.both), targets: compileTargets) { $0 != "NO" }
        guard audit.checkedTargets == 0 || !audit.bad.isEmpty else { return .passed("CI: COMPILER_INDEX_STORE_ENABLE = NO") }
        let provider = s.context.env?.ciProvider ?? "ci"
        return .hits([RuleHit(title: "CI (\(provider)) builds write the index store; pass COMPILER_INDEX_STORE_ENABLE=NO on "
                                + "the CI command line only",
                              evidence: s.evidence(audit) + [.init(kind: "env", ref: "CI", value: provider)],
                              targets: s.distinct(audit.bad.map(\.target)), apply: .cli,
                              cliArguments: ["COMPILER_INDEX_STORE_ENABLE=NO"])])
    }

    /// SET-009.
    static func batchMode(_ s: RuleScan) -> Evaluation {
        let configurations = s.configurations(.both)
        let setting = s.audit("SWIFT_ENABLE_BATCH_MODE", configurations, targets: swiftTargets) { $0 == "NO" }
        let flags = s.audit("OTHER_SWIFT_FLAGS", configurations, targets: swiftTargets) {
            RuleScan.words($0).contains { $0 == "-disable-batch-mode" || $0 == "-no-enable-batch-mode" }
        }
        guard !setting.bad.isEmpty || !flags.bad.isEmpty else {
            return s.settingEvaluation(setting, which: .both, apply: .overlay, overlay: [], fix: "",
                                       passed: "batch mode on (no override)",
                                       noTargets: "no Swift targets with effective settings")
        }
        let all = setting.bad + flags.bad
        return .hits([RuleHit(title: (setting.bad.isEmpty ? s.settingTitle(flags) : s.settingTitle(setting))
                                + "; remove the override",
                              evidence: s.evidence(setting) + s.evidence(flags), targets: s.distinct(all.map(\.target)),
                              configurations: s.distinct(all.map(\.configuration)),
                              apply: setting.bad.isEmpty ? .pbxproj : .overlay,
                              overlay: setting.bad.isEmpty ? [] : [("SWIFT_ENABLE_BATCH_MODE", "YES")],
                              change: .removeFlag(key: "OTHER_SWIFT_FLAGS", flag: "-disable-batch-mode"))])
    }

    /// SET-010.
    static func bitcode(_ s: RuleScan) -> Evaluation {
        let configurations = s.configurations(.both)
        let setting = s.audit("ENABLE_BITCODE", configurations, targets: compileTargets) { $0 == "YES" }
        var flagEvidence: [ReportDocument.EvidenceItem] = []
        var flagged: [RuleScan.SettingEntry] = []
        for key in ["OTHER_CFLAGS", "OTHER_CPLUSPLUSFLAGS", "OTHER_SWIFT_FLAGS", "OTHER_LDFLAGS"] {
            let audit = s.audit(key, configurations, targets: compileTargets) {
                RuleScan.words($0).contains { $0 == "-fembed-bitcode" || $0 == "-embed-bitcode" || $0.hasPrefix("-fembed-bitcode=") }
            }
            flagEvidence += s.evidence(audit)
            flagged += audit.bad
        }
        var podfileEvidence: [ReportDocument.EvidenceItem] = []
        if let podfile = s.podfileFacts, s.postInstallSettings("ENABLE_BITCODE").contains(where: { $0.value == "YES" }) {
            podfileEvidence.append(.init(kind: "file", ref: s.displayPath(podfile.url.path), value: "post_install sets ENABLE_BITCODE = YES"))
        }
        guard !setting.bad.isEmpty || !flagged.isEmpty || !podfileEvidence.isEmpty else {
            return s.settingEvaluation(setting, which: .both, apply: .overlay, overlay: [], fix: "",
                                       noTargets: "no compiling targets with effective settings")
        }
        let all = setting.bad + flagged
        let title: String
        if !setting.bad.isEmpty { title = s.settingTitle(setting) } else if !flagged.isEmpty {
            title = "bitcode flags in \(s.targetsText(s.distinct(flagged.map(\.target))))"
        } else { title = "Podfile post_install sets ENABLE_BITCODE = YES" }
        let apply: RuleSpec.ApplyKind = !setting.bad.isEmpty ? .overlay : (!flagged.isEmpty ? .pbxproj : .recommend)
        let modern = s.xcodeAtLeast("14") ?? true
        return .hits([RuleHit(title: title + "; bitcode is " + (modern ? "deprecated since Xcode 14: set NO, remove the flags"
                                                                        : "extra work: set NO, remove the flags"),
                              evidence: s.evidence(setting) + flagEvidence + podfileEvidence,
                              targets: s.distinct(all.map(\.target)), configurations: s.distinct(all.map(\.configuration)),
                              apply: apply, overlay: setting.bad.isEmpty ? [] : [("ENABLE_BITCODE", "NO")],
                              severity: modern ? .low : .medium,
                              change: .removeFlag(key: "OTHER_LDFLAGS", flag: "-embed-bitcode"))])
    }

    /// SET-011 (static part; sized by the Validate tasks of a zero-change build).
    static func validateProduct(_ s: RuleScan) -> Evaluation {
        let audit = s.audit("VALIDATE_PRODUCT", s.configurations(.debug), targets: { $0.productType.hasSuffix(".application") }) {
            $0 == "YES"
        }
        return s.settingEvaluation(audit, which: .debug, apply: .overlayDebug, overlay: [("VALIDATE_PRODUCT", "NO")],
                                   fix: "; Debug can skip product validation (Release keeps it)",
                                   noTargets: "no application targets with effective settings") { hit in
            hit.verifyKind = "zero-change"
            let tasks = s.buildTasks.filter { $0.rule == "Validate" || $0.rule == "ValidateEmbeddedBinary" }
            if s.context.document?.build.kind == "zero-change", !tasks.isEmpty {
                hit.measured = Measured(seconds: tasks.reduce(0) { $0 + $1.seconds }, share: nil,
                                        basis: "\(tasks.count) validation task(s) in this zero-change build")
            }
        }
    }

    /// SET-013.
    static func explicitModules(_ s: RuleScan) -> Evaluation {
        guard let modern = s.xcodeAtLeast("26") else { return .notApplicable("Xcode version unknown") }
        let configurations = s.configurations(.both)
        if modern {
            let audit = s.audit("SWIFT_ENABLE_EXPLICIT_MODULES", configurations, targets: swiftTargets) { $0 == "NO" }
            return s.settingEvaluation(audit, which: .both, apply: .recommend, overlay: [],
                                       fix: "; review: on Xcode 26+ explicit modules are the default and compilation "
                                           + "caching (SET-016) needs them", passLabel: "explicit modules",
                                       noTargets: "no Swift targets with effective settings")
        }
        let audit = s.audit("_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES", configurations, targets: swiftTargets) { $0 != "YES" }
        return s.settingEvaluation(audit, which: .both, apply: .overlay,
                                   overlay: [("_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES", "YES")],
                                   fix: "; candidate on Xcode 16-25: benchmark before keeping",
                                   noTargets: "no Swift targets with effective settings") { hit in hit.severity = .info }
    }

    /// SET-014.
    static func clangModules(_ s: RuleScan) -> Evaluation {
        let configurations = s.configurations(.both)
        let modules = s.audit("CLANG_ENABLE_MODULES", configurations, targets: cTargets) { $0 == "NO" }
        let defines = s.audit("DEFINES_MODULE", configurations, targets: { $0.productType.contains("framework") }) {
            $0 != "YES"
        }
        guard !modules.bad.isEmpty || !defines.bad.isEmpty else {
            guard !configurations.isEmpty else { return .notApplicable(s.noConfigurationReason(.both)) }
            guard modules.checkedTargets + defines.checkedTargets > 0 else {
                return .notApplicable("no C/ObjC or framework targets with effective settings")
            }
            if let reason = s.unknownReason(modules) ?? s.unknownReason(defines) { return .notApplicable(reason) }
            return .passed("Clang modules on" + (defines.checkedTargets > 0 ? ", frameworks define modules" : ""))
        }
        let all = modules.bad + defines.bad
        var overlay: [(key: String, value: String)] = []
        if !modules.bad.isEmpty { overlay.append(("CLANG_ENABLE_MODULES", "YES")) }
        return .hits([RuleHit(title: (modules.bad.isEmpty ? s.settingTitle(defines) : s.settingTitle(modules))
                                + "; keep Clang modules on and frameworks defining modules",
                              evidence: s.evidence(modules) + s.evidence(defines), targets: s.distinct(all.map(\.target)),
                              configurations: s.distinct(all.map(\.configuration)),
                              apply: modules.bad.isEmpty ? .recommend : .overlay, overlay: overlay)])
    }

    /// SET-015.
    static func integratedDriver(_ s: RuleScan) -> Evaluation {
        let remote = DEPChecks.xcremotecacheEvidence(s)
        if !remote.isEmpty {
            return .suppressed("conflict: XCRemoteCache (DEP-010) needs SWIFT_USE_INTEGRATED_DRIVER = NO; never "
                + "recommended both ways (RULES.md §10)")
        }
        let modern = s.xcodeAtLeast("26") ?? false
        let audit = s.audit("SWIFT_USE_INTEGRATED_DRIVER", s.configurations(.both), targets: swiftTargets) { $0 == "NO" }
        return s.settingEvaluation(audit, which: .both, apply: modern ? .recommend : .overlay,
                                   overlay: modern ? [] : [("SWIFT_USE_INTEGRATED_DRIVER", "YES")],
                                   fix: modern ? "; remove it: it blocks compilation caching (SET-016) on Xcode 26+"
                                       : "; remove it unless XCRemoteCache needs it", passLabel: "integrated driver",
                                   noTargets: "no Swift targets with effective settings")
    }

    /// SET-016.
    static func compilationCache(_ s: RuleScan) -> Evaluation {
        let configurations = s.configurations(.debug)
        let remote = DEPChecks.xcremotecacheEvidence(s)
        let explicitOff = s.audit("SWIFT_ENABLE_EXPLICIT_MODULES", configurations, targets: swiftTargets) { $0 == "NO" }
        let driverOff = s.audit("SWIFT_USE_INTEGRATED_DRIVER", configurations, targets: swiftTargets) { $0 == "NO" }
        if remote.isEmpty {
            if !explicitOff.bad.isEmpty {
                return .suppressed("blocked: SWIFT_ENABLE_EXPLICIT_MODULES = NO in \(s.targetsText(s.distinct(explicitOff.bad.map(\.target)))) "
                    + "(SET-013 reports it)")
            }
            if !driverOff.bad.isEmpty {
                return .suppressed("blocked: SWIFT_USE_INTEGRATED_DRIVER = NO in \(s.targetsText(s.distinct(driverOff.bad.map(\.target)))) "
                    + "(SET-015 reports it)")
            }
        }
        let audit = s.audit("COMPILATION_CACHE_ENABLE_CACHING", configurations, targets: compileTargets) { $0 != "YES" }
        return s.settingEvaluation(audit, which: .debug, apply: remote.isEmpty ? .overlayDebug : .recommend,
                                   overlay: remote.isEmpty ? [("COMPILATION_CACHE_ENABLE_CACHING", "YES")] : [],
                                   fix: remote.isEmpty ? "; try YES (Debug first), kept only if verify measures it faster"
                                       : "; conflicts with XCRemoteCache (DEP-010): choose one",
                                   passLabel: "COMPILATION_CACHE_ENABLE_CACHING",
                                   noTargets: "no compiling targets with effective settings") { hit in
            hit.title = "COMPILATION_CACHE_ENABLE_CACHING not set to YES in \(hit.configurations.joined(separator: "/")) "
                + "for \(s.targetsText(hit.targets))" + (remote.isEmpty ? " (Xcode 26+); covers project targets, SPM "
                    + "package caching unverified" : "; conflicts with XCRemoteCache (DEP-010)")
            hit.evidence.append(.init(kind: "report", ref: "scope", value: "the overlay reaches project targets; caching "
                + "of SPM package targets is unverified (S19)"))
            if !remote.isEmpty {
                hit.evidence += remote
                hit.evidence.append(.init(kind: "report", ref: "conflict", value: "XCRemoteCache needs "
                    + "SWIFT_USE_INTEGRATED_DRIVER = NO; compilation caching needs YES (RULES.md §10)"))
            }
            if let analysis = s.context.analysis, s.context.document?.build.kind == "clean", analysis.reusedCount == 0 {
                hit.evidence.append(.init(kind: "report", ref: "build", value: "clean build with no reused or cached tasks"))
            }
            hit.verifyKind = "clean"
        }
    }

    /// SET-017.
    static func remoteCache(_ s: RuleScan) -> Evaluation {
        guard s.context.isCI else { return .notApplicable("not a CI run (CI=true is not set)") }
        let configurations = s.configurations(.both)
        let audit = s.audit("COMPILATION_CACHE_REMOTE_SERVICE_PATH", configurations, targets: compileTargets) {
            ($0 ?? "").isEmpty
        }
        let plugin = s.audit("COMPILATION_CACHE_ENABLE_PLUGIN", configurations, targets: compileTargets) { $0 != "YES" }
        guard !audit.bad.isEmpty, !plugin.bad.isEmpty else { return .passed("CI: a compilation cache service is configured") }
        return .hits([RuleHit(title: "CI build on Xcode 26+ without a remote compilation cache (no "
                                + "COMPILATION_CACHE_ENABLE_PLUGIN / COMPILATION_CACHE_REMOTE_SERVICE_PATH)",
                              evidence: [.init(kind: "env", ref: "CI", value: s.context.env?.ciProvider ?? "ci"),
                                         .init(kind: "report", ref: "history", value: "not consulted in v0.3: the "
                                             + "≥ 3 clean CI builds in 7 days condition is assumed")],
                              targets: s.distinct(audit.bad.map(\.target)), apply: .recommend)])
    }

    /// SET-020.
    static func timingFlags(_ s: RuleScan) -> Evaluation {
        let configurations = s.context.isCI ? s.configurations(.both) : s.configurations(.release)
        func timing(_ word: String) -> Bool {
            word.hasPrefix("-debug-time-") || word.hasPrefix("-warn-long-") || word == "-stats-output-dir"
        }
        let audit = s.audit("OTHER_SWIFT_FLAGS", configurations, targets: swiftTargets) { RuleScan.words($0).contains(where: timing) }
        let flag = audit.bad.lazy.flatMap { RuleScan.words($0.value) }.first(where: timing) ?? "-debug-time-function-bodies"
        return s.settingEvaluation(audit, which: .release, apply: .pbxproj, overlay: [],
                                   fix: "; remove \(flag) from the committed configuration (xcblame build --deep measures "
                                       + "without it)", passed: "no timing diagnostic flags in OTHER_SWIFT_FLAGS",
                                   noTargets: "no Swift targets with effective settings") { hit in
            hit.title = "timing flag \(flag) committed in \(hit.configurations.joined(separator: "/")) OTHER_SWIFT_FLAGS for "
                + s.targetsText(hit.targets) + "; remove it (xcblame build --deep measures without it)"
            hit.change = .removeFlag(key: "OTHER_SWIFT_FLAGS", flag: flag)
        }
    }

    /// SET-021.
    static func prefixHeader(_ s: RuleScan) -> Evaluation {
        let configurations = s.configurations(.both)
        let audit = s.audit("GCC_PRECOMPILE_PREFIX_HEADER", configurations, targets: { target in
            cTargets(target) && configurations.contains { !(s.value(target.name, "GCC_PREFIX_HEADER", $0) ?? "").isEmpty }
        }) { $0 == "NO" }
        return s.settingEvaluation(audit, which: .both, apply: .overlay, overlay: [("GCC_PRECOMPILE_PREFIX_HEADER", "YES")],
                                   fix: "; precompile the prefix header", noTargets: "no targets with a prefix header")
    }

    /// SET-022.
    static func headerSearch(_ s: RuleScan) -> Evaluation {
        let configurations = s.configurations(.both)
        let headermap = s.audit("USE_HEADERMAP", configurations, targets: cTargets) { $0 == "NO" }
        let userPaths = s.audit("ALWAYS_SEARCH_USER_PATHS", configurations, targets: cTargets) { $0 == "YES" }
        let recursive = ["HEADER_SEARCH_PATHS", "USER_HEADER_SEARCH_PATHS"].map { key in
            s.audit(key, configurations, targets: cTargets) { RuleScan.words($0).contains { $0.hasSuffix("/**") } }
        }
        let all = headermap.bad + userPaths.bad + recursive.flatMap(\.bad)
        guard !all.isEmpty else {
            guard !configurations.isEmpty else { return .notApplicable(s.noConfigurationReason(.both)) }
            guard headermap.checkedTargets > 0 else { return .notApplicable("no targets with C/ObjC sources") }
            if let reason = s.unknownReason(headermap) ?? s.unknownReason(userPaths) { return .notApplicable(reason) }
            return .passed("header maps on, no recursive header search paths")
        }
        var overlay: [(key: String, value: String)] = []
        if !headermap.bad.isEmpty { overlay.append(("USE_HEADERMAP", "YES")) }
        if !userPaths.bad.isEmpty { overlay.append(("ALWAYS_SEARCH_USER_PATHS", "NO")) }
        let first = [headermap, userPaths] + recursive
        return .hits([RuleHit(title: s.settingTitle(first.first { !$0.bad.isEmpty }!)
                                + "; booleans back to defaults, explicit header paths",
                              evidence: first.flatMap { s.evidence($0) }, targets: s.distinct(all.map(\.target)),
                              configurations: s.distinct(all.map(\.configuration)),
                              apply: overlay.isEmpty ? .recommend : .overlay, overlay: overlay)])
    }

    /// SET-023.
    static func eagerLinking(_ s: RuleScan) -> Evaluation {
        let frameworks = (s.project?.allTargets ?? []).filter {
            $0.frameworkKind == .dynamic && $0.hasSwiftSources && !$0.hasCSources
        }
        guard frameworks.count >= 2 else {
            return .notApplicable("fewer than 2 Swift-only dynamic framework targets (\(frameworks.count))")
        }
        let audit = s.audit("EAGER_LINKING", s.configurations(.debug), targets: compileTargets) { $0 != "YES" }
        return s.settingEvaluation(audit, which: .debug, apply: .overlayDebug, overlay: [("EAGER_LINKING", "YES")],
                                   fix: "; \(frameworks.count) Swift-only dynamic frameworks, try YES in Debug",
                                   passLabel: "EAGER_LINKING") { hit in
            hit.verifyKind = "incremental"
            hit.evidence.append(.init(kind: "report", ref: "graph",
                                      value: "Swift-only dynamic frameworks: " + frameworks.map(\.name).joined(separator: ", ")))
        }
    }

    /// SET-027.
    static func ldClassic(_ s: RuleScan) -> Evaluation {
        let classic: Set<String> = ["-ld_classic", "-Wl,-ld_classic", "-ld64"]
        let audit = s.audit("OTHER_LDFLAGS", s.configurations(.both), targets: compileTargets) {
            RuleScan.words($0).contains { classic.contains($0) }
        }
        var evidence = s.evidence(audit)
        let podfile = s.podfileFacts.flatMap { podfile -> ReportDocument.EvidenceItem? in
            RuleScan.matches(RuleScan.code(podfile.facts.postInstall ?? ""), #"-ld_classic|-ld64\b"#)
                ? .init(kind: "file", ref: s.displayPath(podfile.url.path), value: "post_install adds -ld_classic/-ld64") : nil
        }
        if let podfile { evidence.append(podfile) }
        guard !evidence.isEmpty else {
            return s.settingEvaluation(audit, which: .both, apply: .pbxproj, overlay: [], fix: "",
                                       passed: "no -ld_classic/-ld64 in OTHER_LDFLAGS", noTargets: "no compiling targets with effective settings")
        }
        let flag = audit.bad.lazy.flatMap { RuleScan.words($0.value) }.first { classic.contains($0) } ?? "-ld_classic"
        let required = s.xcodeAtLeast("27") ?? false
        return .hits([RuleHit(title: (audit.bad.isEmpty ? "Podfile post_install adds \(flag)"
                                      : "\(flag) in OTHER_LDFLAGS (\(s.distinct(audit.bad.map(\.configuration)).joined(separator: "/"))) "
                                          + "for " + s.targetsText(s.distinct(audit.bad.map(\.target))))
                                + (required ? "; Xcode 27 removed ld64: remove it" : "; selects the old, slower linker: remove it"),
                              evidence: evidence, targets: s.distinct(audit.bad.map(\.target)),
                              configurations: s.distinct(audit.bad.map(\.configuration)),
                              apply: audit.bad.isEmpty ? .manifest : .pbxproj, severity: required ? .high : nil,
                              change: .removeFlag(key: "OTHER_LDFLAGS", flag: flag))])
    }

    /// SET-028.
    static func lto(_ s: RuleScan) -> Evaluation {
        let debug = s.configurations(.debug)
        let others = s.configurations(.both).filter { !debug.contains($0) }
        let debugLTO = s.audit("LLVM_LTO", debug, targets: compileTargets) { $0 == "YES" || $0 == "YES_THIN" }
        let monolithic = s.audit("LLVM_LTO", others, targets: compileTargets) { $0 == "YES" }
        guard !debugLTO.bad.isEmpty || !monolithic.bad.isEmpty else {
            guard !s.configurations(.both).isEmpty else { return .notApplicable(s.noConfigurationReason(.both)) }
            guard debugLTO.checkedTargets + monolithic.checkedTargets > 0 else {
                return .notApplicable("no compiling targets with effective settings")
            }
            if let reason = s.unknownReason(debugLTO) ?? s.unknownReason(monolithic) { return .notApplicable(reason) }
            return .passed("no LTO in Debug, no monolithic LTO")
        }
        let all = debugLTO.bad + monolithic.bad
        return .hits([RuleHit(title: (debugLTO.bad.isEmpty ? s.settingTitle(monolithic) + "; try YES_THIN"
                                      : s.settingTitle(debugLTO) + "; Debug should use NO"),
                              evidence: s.evidence(debugLTO) + s.evidence(monolithic), targets: s.distinct(all.map(\.target)),
                              configurations: s.distinct(all.map(\.configuration)),
                              apply: debugLTO.bad.isEmpty ? .recommend : .overlayDebug,
                              overlay: debugLTO.bad.isEmpty ? [] : [("LLVM_LTO", "NO")])])
    }

    /// SET-029.
    static func stripDebug(_ s: RuleScan) -> Evaluation {
        let configurations = s.configurations(.debug)
        let strip = s.audit("COPY_PHASE_STRIP", configurations, targets: compileTargets) { $0 == "YES" }
        let post = s.audit("DEPLOYMENT_POSTPROCESSING", configurations, targets: compileTargets) { $0 == "YES" }
        guard !strip.bad.isEmpty || !post.bad.isEmpty else {
            return s.settingEvaluation(strip, which: .debug, apply: .overlayDebug, overlay: [], fix: "",
                                       passed: "COPY_PHASE_STRIP and DEPLOYMENT_POSTPROCESSING off", noTargets: "no compiling targets with effective settings")
        }
        var overlay: [(key: String, value: String)] = []
        if !strip.bad.isEmpty { overlay.append(("COPY_PHASE_STRIP", "NO")) }
        if !post.bad.isEmpty { overlay.append(("DEPLOYMENT_POSTPROCESSING", "NO")) }
        let all = strip.bad + post.bad
        return .hits([RuleHit(title: s.settingTitle(strip.bad.isEmpty ? post : strip) + "; Debug should not strip",
                              evidence: s.evidence(strip) + s.evidence(post), targets: s.distinct(all.map(\.target)),
                              configurations: s.distinct(all.map(\.configuration)), apply: .overlayDebug, overlay: overlay,
                              verifyKind: "incremental")])
    }

    /// SET-030.
    static func scriptSandboxing(_ s: RuleScan) -> Evaluation {
        let scripts = s.scriptPhases.filter { !RuleScan.isCocoaPods($0.phase) }
        guard !scripts.isEmpty else { return .notApplicable("no script phases") }
        let open = PHASEChecks.phasesWithoutIO(s)
        if !open.isEmpty {
            return .suppressed("deferred until PHASE-001 has no open findings (\(open.count) script phase(s) without "
                + "declared outputs)")
        }
        let owners = Set(scripts.map(\.target.name))
        let configurations = s.configurations(.both)
        let sandbox = s.audit("ENABLE_USER_SCRIPT_SANDBOXING", configurations, targets: { owners.contains($0.name) }) { $0 != "YES" }
        let fuse = s.audit("FUSE_BUILD_SCRIPT_PHASES", configurations, targets: { owners.contains($0.name) }) { $0 != "YES" }
        guard !sandbox.bad.isEmpty || !fuse.bad.isEmpty else {
            return s.settingEvaluation(sandbox, which: .both, apply: .overlay, overlay: [], fix: "",
                                       passed: "script sandboxing and parallel script phases on", noTargets: "no script targets with effective settings")
        }
        var overlay: [(key: String, value: String)] = []
        if !sandbox.bad.isEmpty { overlay.append(("ENABLE_USER_SCRIPT_SANDBOXING", "YES")) }
        if !fuse.bad.isEmpty { overlay.append(("FUSE_BUILD_SCRIPT_PHASES", "YES")) }
        let all = sandbox.bad + fuse.bad
        return .hits([RuleHit(title: "script sandboxing / parallel script phases off for \(s.targetsText(s.distinct(all.map(\.target)))) "
                                + "while every script declares its outputs; enable both",
                              evidence: s.evidence(sandbox) + s.evidence(fuse), targets: s.distinct(all.map(\.target)),
                              configurations: s.distinct(all.map(\.configuration)), apply: .overlay, overlay: overlay,
                              verifyKind: "incremental")])
    }

    /// SET-031.
    static func crossModuleOptimization(_ s: RuleScan) -> Evaluation {
        let cmo: Set<String> = ["-cross-module-optimization", "-enable-default-cmo"]
        let audit = s.audit("OTHER_SWIFT_FLAGS", s.configurations(.debug), targets: swiftTargets) {
            RuleScan.words($0).contains { cmo.contains($0) }
        }
        let flag = audit.bad.lazy.flatMap { RuleScan.words($0.value) }.first { cmo.contains($0) } ?? "-cross-module-optimization"
        return s.settingEvaluation(audit, which: .debug, apply: .pbxproj, overlay: [], fix: "; remove \(flag) from Debug",
                                   passed: "no cross-module optimization flags",
                                   noTargets: "no Swift targets with effective settings") { hit in
            hit.change = .removeFlag(key: "OTHER_SWIFT_FLAGS", flag: flag)
        }
    }

    /// SET-032.
    static func libraryForDistribution(_ s: RuleScan) -> Evaluation {
        if let exporter = s.scriptPhases.first(where: { RuleScan.code($0.phase.shellScript).contains("-create-xcframework") }) {
            return .passed("XCFramework export script found (\(exporter.target.name) › \(exporter.phase.name))")
        }
        let audit = s.audit("BUILD_LIBRARY_FOR_DISTRIBUTION", s.configurations(.both), targets: compileTargets) { $0 == "YES" }
        return s.settingEvaluation(audit, which: .both, apply: .overlay, overlay: [("BUILD_LIBRARY_FOR_DISTRIBUTION", "NO")],
                                   fix: "; no XCFramework export found: set NO for internal modules",
                                   passed: "BUILD_LIBRARY_FOR_DISTRIBUTION off") { hit in
            hit.verifyKind = "clean"
        }
    }
}
