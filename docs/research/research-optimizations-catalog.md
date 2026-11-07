# Xcode / Swift Build-Time Optimization Catalog (for a detect-and-apply CLI)

Compiled 2026-10-30. ~38 sources fetched or searched. Evidence tags used in every record:
- **[P]** = primary (Apple docs/release notes/WWDC, swift.org, swift repo docs, vendor README).
- **[S]** = secondary with measurements or reproducible detail (engineering blogs, forum threads with data).
- **[K]** = practitioner knowledge that I did NOT verify with a fetched source this session. Treat as hypothesis; the CLI should gate it behind "measure first".
Impact numbers are only quoted when a source gave them. "unmeasured" means no number was found.

## Xcode version applicability cheat-sheet
| Version | Build-relevant change | Source |
|---|---|---|
| Xcode 9 | New build system default; static Swift libs | [S15] |
| Xcode 10 | Batch mode (K); WMO no longer needed for Debug speed | [S15] |
| Xcode 14 | ld64 ~2x faster for many projects; bitcode deprecated; integrated Swift driver default (K) | [S11],[S45] |
| Xcode 15 | New linker (ld-prime) default; mergeable libraries (`MERGED_BINARY_TYPE`); user script sandboxing in new projects (K) | [S10],[S49] |
| Xcode 16 | Explicit modules default for C/ObjC; Swift explicit modules experimental (`_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES`); 16.4: swift-syntax prebuilts opt-in; Task Backtraces (16.4+) | [S20],[S23],[S1] |
| Xcode 26 (Swift 6.2) | Compilation caching (opt-in); Swift explicit modules default for Swift >=5 mode (opt-out `SWIFT_ENABLE_EXPLICIT_MODULES=NO`; stays off for Swift/C++ interop targets); swift-syntax prebuilts automatic; preview of new package PIF builder (`IDEEnableNewPackagePIFBuilder`) | [S8],[S24] |
| Xcode 26.4+ / 26.6 | Known planning-phase perf bugs (macro plugin ordering, path-cache lock) fixed in Swift 6.4 / Xcode 27 per forum | [S22] |
| Xcode 27 (GA ~Sep 2026) | ld64 removed (`-ld_classic` unsupported); faster Swift dependency scanner requires unique Clang module names. SECONDARY source only (personal blog quoting release notes) - verify | [S33] |

## Source index
S1 https://raw.githubusercontent.com/AvdLee/Xcode-Build-Optimization-Agent-Skill/main/OPTIMIZATION-CHECKS.md (40+ checks, 2026)
S2 https://raw.githubusercontent.com/AvdLee/Xcode-Build-Optimization-Agent-Skill/main/references/build-settings-best-practices.md
S3 https://raw.githubusercontent.com/AvdLee/Xcode-Build-Optimization-Agent-Skill/main/references/build-optimization-sources.md (its own bibliography)
S4 https://www.avanderlee.com/xcode/xcode-build-optimization-using-6-agent-skills/ (benchmarks)
S5 https://www.avanderlee.com/optimization/analysing-build-performance-xcode/
S6 https://developer.apple.com/documentation/xcode/improving-the-speed-of-incremental-builds (read via the tutorials/data JSON endpoint)
S7 https://developer.apple.com/documentation/xcode/improving-build-efficiency-with-good-coding-practices
S8 https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes
S9 https://developer.apple.com/documentation/xcode/build-settings-reference
S10 https://developer.apple.com/documentation/xcode/configuring-your-project-to-use-mergeable-libraries
S11 https://developer.apple.com/videos/play/wwdc2022/110362/ (Link fast)
S12 https://developer.apple.com/videos/play/wwdc2025/245 (via search summary only)
S13 https://github.com/swiftlang/swift/blob/main/docs/CompilerPerformance.md
S14 https://github.com/swiftlang/swift/blob/main/docs/OptimizationTips.rst
S15 https://github.com/fastred/Optimizing-Swift-Build-Times (2017-2018; old)
S16 https://danielchasehooper.com/posts/why-swift-is-slow/
S17 https://tuist.dev/blog/2025/10/22/xcode-cache
S18 https://bitrise.io/blog/post/lifting-the-hood-on-build-cache-for-xcode
S19 https://docs.bitrise.io/en/bitrise-build-cache/build-cache-for-xcode/xcode-compilation-cache-faq.html
S20 https://bitrise.io/blog/post/demystifying-explicitly-built-modules-for-xcode (Xcode 16 beta 1 data)
S21 https://www.bitrise.io/blog/post/expert-tips-to-speed-up-your-ios-builds
S22 https://forums.swift.org/t/slow-incremental-builds-because-of-planning-swift-module/84803
S23 https://forums.swift.org/t/preview-swift-syntax-prebuilts-for-macros/80202
S24 https://swift.org/blog/swift-6.2-released/
S25 https://github.com/spotify/XCRemoteCache
S26 https://blog.allegro.tech/2020/12/speeding-up-ios-builds-with-bazel.html
S27 https://engineering.linecorp.com/en/blog/improving-build-performance-line-ios-bazel/
S28 https://github.com/swiftyfinch/Rugby
S29 https://github.com/grab/cocoapods-binary-cache (search snippet; ~10% claim)
S30 https://livsycode.com/best-practices/xcode-26-compilation-cache/
S31 https://forums.swift.org/t/how-to-make-incremental-builds-work-on-a-mac-mini-ci-with-xcode-26/83653
S32 https://developer.apple.com/forums/thread/676421 (asset catalog)
S33 https://blakecrosley.com/blog/xcode-27-build-failures-ld64-clang-modules (secondary)
S34 https://tuist.dev/yue_Hant/docs/guides/features/registry/continuous-integration (via search snippet)
S35 https://itnext.io/effective-swift-package-manager-caching-with-fastlane-and-github-actions-b241585f0a4c
S36 https://discuss.circleci.com/t/sharing-xcode-derived-data-folder-across-jobs-workflows/31363
S37 https://forums.swift.org/t/compilation-extremely-slow-since-macros-adoption/67921
S38 https://forums.swift.org/t/swiftpm-how-to-prevent-resolve-packages-from-stymying-developer-productivity-local-packages/63363
S39 https://developer.apple.com/forums/thread/771645 (Xcode Cloud DerivedData)
S40 https://developer.apple.com/forums/thread/109641 (antivirus exclusions)
S41 https://github.com/bitrise-steplib/steps-xcode-build-for-simulator/releases/0.10.0
S42 https://developer.apple.com/forums/thread/80073 (concurrent compile tasks)
S43 https://forums.swift.org/t/why-would-this-take-410ms-to-type-check/66099
S44 https://lists.swift.org/pipermail/swift-users/Week-of-Mon-20170320/005003.html
S45 https://developer.apple.com/documentation/xcode-release-notes/xcode-14-release-notes
S46 https://forums.swift.org/t/how-do-you-mitigate-the-performance-impact-of-using-packages/52307 and https://developer.apple.com/forums/thread/750712
S47 https://developer.apple.com/documentation/xcode/understanding-build-product-layout-changes
S48 https://bugs.webkit.org/show_bug.cgi?id=315128 (FUSE_BUILD_SCRIPT_PHASES mention)
S49 https://developer.apple.com/forums/thread/741240 (ld-prime)
S50 https://tuist.dev/en/docs/guides/features/cache
S51 https://forums.swift.org/t/about-swift-shared-cache-across-machines/81850
S52 https://glama.ai/mcp/servers/@steipete/Peekaboo/blob/bace59f90bb276f1c6fb613acfda3935ec4a7a90/docs/swift-performance.md (page body not retrievable; claims come only from a search-engine summary - low confidence)
S53 https://developer.apple.com/forums/thread/671988 (SwiftUI "unable to type-check")
S54 Gojek https://medium.com/gojekengineering/gojeks-journey-to-3x-faster-ios-builds-with-bazel-90fbe3f22f81 (403 on fetch; snippet only) and Spotify https://engineering.atspotify.com/2023/10/switching-build-systems-seamlessly (snippet only)
S55 https://developer.apple.com/forums/thread/695634 (Xcode Cloud cache)

---
# A. BUILD SETTINGS (category: build-settings)

Convention: "auto" = safe for a tool to edit pbxproj/xcconfig automatically; "rec" = recommend only.

### A1 `swift-compilation-mode-per-config`
- **What/why:** `SWIFT_COMPILATION_MODE` = `singlefile` ("Incremental") spawns per-file/batch frontends and rebuilds only out-of-date files; `wholemodule` compiles the module in one process, so any edit rebuilds the entire module [S9],[S13]. Batch/incremental parallelizes and supports incremental; WMO gives cross-file optimization and is right for Release.
- **Detect:** pbxproj `buildSettings` of Debug `XCBuildConfiguration` (project and target level; target overrides win): `SWIFT_COMPILATION_MODE = wholemodule` or `SWIFT_OPTIMIZATION_LEVEL = "-O"` with WMO in Debug, or legacy `-Owholemodule`. Also check xcconfig and `OTHER_SWIFT_FLAGS` containing `-whole-module-optimization`.
- **Fix:** Debug `SWIFT_COMPILATION_MODE = singlefile` (or unset); Release `wholemodule`. **auto** (low risk) [S1],[S2].
- **Impact:** AvdLee's checks list as top Debug fix; the Medium-era note says difference can be small on tiny projects [search summaries]. Incremental builds mainly; clean ~neutral. Debug.
- **Risks:** WMO in Debug destroys incremental builds [S13]. Do not set `singlefile` for Release (loses cross-file optimization). Target-level overrides can create module variants (see A24).
- **Sources:** S1, S2, S9, S13, S15 (WMO "no longer needed for Debug since Xcode 10"). Versions: all.

### A2 `swift-optimization-level-debug-onone`
- **What/why:** `-Onone` skips SIL/LLVM optimization passes, which add "significant SIL and LLVM time and memory" [S13]. Type-check cost is unchanged by level [S13].
- **Detect:** Debug `SWIFT_OPTIMIZATION_LEVEL` != `-Onone`.
- **Fix:** Debug `-Onone`; Release `-O` or `-Osize`. **auto**.
- **Impact:** large for Debug compile+link (unmeasured in sources; qualitative). Debug, incremental+clean.
- **Risks:** Debug perf not representative (profile on Release). Some SwiftUI/previews perf tests misleading. Don't apply to Release.
- **Sources:** S1, S2, S13.

### A3 `gcc-optimization-level-debug-zero`
- **What/why:** C/ObjC/C++ sources at `-O0` in Debug compile faster.
- **Detect:** Debug `GCC_OPTIMIZATION_LEVEL` not `0` (note: Xcode default Debug `0`; Release `s`).
- **Fix:** Debug `0`, Release `s` (or `3`/`fast` if perf-critical). **auto**.
- **Impact:** unmeasured; only matters for ObjC-heavy targets. Debug.
- **Risks:** `-O0` can hide UB/optimizer-only bugs; fine for Debug.
- **Sources:** S1, S2.

### A4 `debug-information-format-dwarf-debug`
- **What/why:** `dwarf` keeps debug info in object files (no dSYM generation/dsymutil step, which also runs at link). `dwarf-with-dsym` adds a dsymutil step per product.
- **Detect:** Debug `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym` (new Xcode projects default Debug to `dwarf`; old projects often override). Also check `GCC_GENERATE_DEBUGGING_SYMBOLS`.
- **Fix:** Debug `dwarf`; Release must stay `dwarf-with-dsym`. **auto** with guard "Debug only".
- **Impact:** estimated seconds per link on large targets (one skill page claims 3-5 s; unverified). Debug, incremental+clean.
- **Risks:** `dwarf` for Release/Archive breaks crash symbolication (no dSYM) [S2]. Device debugging with `dwarf` needs original object files (fine locally). If Debug builds are uploaded to Crashlytics/Sentry/TestFlight-dev, keep dSYM there. XCRemoteCache recommends `dwarf` [S25].
- **Sources:** S1, S2, S5, S25.

### A5 `only-active-arch-debug`
- **What/why:** Building one architecture instead of all halves (or more) compile/link work in Debug.
- **Detect:** Debug `ONLY_ACTIVE_ARCH = NO` (or missing); also `ARCHS` hardcoded multi-arch, or `VALID_ARCHS`.
- **Fix:** Debug `ONLY_ACTIVE_ARCH = YES`; Release `NO`. **auto**.
- **Impact:** "multiplies compile and link time" [S1]; a skill page claims 40-50% (unverified). Debug, both clean and incremental. Mostly relevant for macOS/iOS-device+x86 sim and Mac apps; on Apple-Silicon iOS sim builds it is already arm64-only.
- **Risks:** Ignored for generic destinations ("Generic iOS Device") or when "Override Architectures" set [S9]. CI doing `xcodebuild build -destination generic/...` may need explicit `ONLY_ACTIVE_ARCH=YES` on command line. Never in Release/archive.
- **Sources:** S1, S2, S9.

### A6 `excluded-archs-simulator-arm64-hack`
- **What/why:** Legacy workaround `EXCLUDED_ARCHS[sdk=iphonesimulator*] = arm64` forces x86_64 simulator builds (Rosetta) on Apple Silicon: slower build and run, and doubles work if universal.
- **Detect:** pbxproj/xcconfig key `EXCLUDED_ARCHS[sdk=iphonesimulator*]` containing `arm64` (often injected by CocoaPods post_install `config.build_settings['EXCLUDED_ARCHS[sdk=iphonesimulator*]'] = 'arm64'`).
- **Fix:** Remove once all deps ship arm64-simulator slices (XCFrameworks). **rec** (needs dependency check).
- **Impact:** unmeasured [K]. Debug/simulator.
- **Risks:** Removing breaks deps with no arm64-sim slice (old static .a / fat frameworks).
- **Sources:** [K]; see also S9 for ONLY_ACTIVE_ARCH semantics. Mark unverified.

### A7 `enable-testability-release-no`
- **What/why:** `ENABLE_TESTABILITY=YES` makes internal symbols exported (needed for `@testable import`), disables some optimization/strip, and in Release it forces `-enable-testing`. Apple notes ENABLE_TESTABILITY disables `STRIP_INSTALLED_PRODUCT` [S9].
- **Detect:** Release `ENABLE_TESTABILITY = YES`. Debug `NO` while tests use `@testable import` (grep test sources) = breakage not speed issue.
- **Fix:** Debug `YES`, Release `NO`. **auto** for Release; Debug leave YES.
- **Impact:** small compile/link; main benefit is smaller/faster Release binary. Release.
- **Risks:** Release-config test runs (`-configuration Release` tests) need YES. Debug NO breaks `@testable`.
- **Sources:** S1, S2, S9.

### A8 `compiler-index-store-enable`
- **What/why:** `COMPILER_INDEX_STORE_ENABLE` makes compilers emit index data while building (needed for autocomplete, jump-to-definition, find usages, Periphery) [S9]. Disabling saves per-file index emission.
- **Detect:** CI scripts/`xcodebuild` invocations lacking `COMPILER_INDEX_STORE_ENABLE=NO`; project default is `Default` (YES in Debug, NO in Release per Xcode defaults [K]).
- **Fix:** CI only: pass `COMPILER_INDEX_STORE_ENABLE=NO` on xcodebuild command line (Bitrise step does this) [S41]. **auto for CI scripts; rec for pbxproj** (don't set NO in project for developers).
- **Impact:** unmeasured (no number found). Both. 
- **Risks:** Kills autocomplete/jump-to-def if set in project; tools needing index DataStore (Periphery, SwiftLint analyze, SourceKit-LSP in CI) fail or trigger an extra build [S41]. Note Xcode also does not generate `Index.noindex/DataStore` when remote compilation caching is enabled [S19].
- **Sources:** S9, S19, S41.

### A9 `swift-enable-batch-mode`
- **What/why:** Batch mode groups several primary files per frontend job, removing repeated parsing ("100 files: 10,000 parses single-file vs 400 batch on 4 CPUs") [S13].
- **Detect:** `SWIFT_ENABLE_BATCH_MODE = NO` or `-no-enable-batch-mode` in `OTHER_SWIFT_FLAGS`. Default is on in modern Xcode [K for exact version; S13 says "will become default"].
- **Fix:** Remove override / set `YES`. **auto**.
- **Impact:** S13 example is theoretical (~25x fewer parses); practical gains vary. Debug incremental+clean.
- **Risks:** Rare compiler bugs; none known.
- **Sources:** S13.

### A10 `enable-bitcode-dead`
- **What/why:** Bitcode deprecated in Xcode 14; App Store no longer accepts it. `ENABLE_BITCODE=YES` produces warnings and (in older toolchains) extra bitcode emission and slower archive.
- **Detect:** `ENABLE_BITCODE = YES` anywhere; Podfile `post_install` setting it; `-fembed-bitcode` / `-embed-bitcode` in `OTHER_*FLAGS`/`OTHER_LDFLAGS`.
- **Fix:** `ENABLE_BITCODE = NO` (or delete), remove embed flags. **auto**.
- **Impact:** removes extra work in Xcode<=13; modest/none for 14+. Release/archive.
- **Risks:** Third-party static libs built with bitcode still link fine when disabled.
- **Sources:** S45.

### A11 `validate-product-debug-no`
- **What/why:** `VALIDATE_PRODUCT` runs product validation (embedded-binary/provisioning checks, `ValidateEmbeddedBinary`, `Validate` steps) at build end; AvdLee's zero-change overhead table lists `ValidateEmbeddedBinary` as unconditional [S1].
- **Detect:** Debug `VALIDATE_PRODUCT = YES` (Xcode default: Debug NO, Release YES [K]).
- **Fix:** Debug `NO`. **auto**.
- **Impact:** unmeasured; fixed per-build cost (zero-change builds >5 s on Apple Silicon usually point to script phases/codesign [S1]). Debug incremental.
- **Risks:** Hides provisioning/extension-embedding errors until Release/archive. Keep YES in Release.
- **Sources:** S1 (overhead table), S9 (key listed). Setting semantics [K].

### A12 `assetcatalog-compiler-optimization`
- **What/why:** `ASSETCATALOG_COMPILER_OPTIMIZATION` (`time` vs `space`) tunes compiled .car output [S9]. Apple DTS says compression cannot be varied per configuration via the UI/File Inspector and asset compile is not tunable like code optimization [S32].
- **Detect:** `CompileAssetCatalog`/`CompileAssetCatalogVariant` dominates timing summary; large catalogs (many MB of PNG/PDF); `ASSETCATALOG_COMPILER_OPTIMIZATION` unset or `space`.
- **Fix:** Try `time` in Debug via xcconfig; adjust catalog compression in File Inspector; split catalogs (see E10). **rec** (no measured effect).
- **Impact:** unmeasured. Both; clean mostly.
- **Risks:** `time` may enlarge .car; changes app size.
- **Sources:** S9, S32.

### A13 `swift-enable-explicit-modules`
- **What/why:** Explicit modules turn module compilation into scheduled build-system tasks (scan -> build modules -> compile sources), enabling parallelism/reuse, deterministic builds, debugger reusing module graph [S12],[S20]. Required for Xcode 26 compilation caching [S19].
- **Detect:** `SWIFT_ENABLE_EXPLICIT_MODULES` (Xcode 26+) / `_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES` (Xcode 16-25). Xcode 26 default is ON for Swift >=5 mode and not for Swift/C++ interop targets [S8]. Flag explicit `=NO` as an opt-out to review; flag Xcode 16/17/18-25 projects where unset.
- **Fix:** Xcode 26+: leave default (YES) especially if using compilation cache. Xcode 16-25: only enable after benchmarking. **rec** (benchmark first).
- **Impact:** Mixed. Bitrise Xcode 16 beta 1 on M1 Pro, clean: Tuist 50.1 -> 57.8 s, BackyardBirds 21 -> 30 s, pocketcasts 119 -> 121 s (all slower) [S20]. AvdLee: "can aid parallelism but may regress from scanning overhead; benchmark" [S2]. Xcode 27 reportedly speeds up the scanner (secondary) [S33].
- **Risks:** Module variant duplication (A24); needs unique Clang module names in Xcode 27 [S33]; macros/Swift-C++ interop opt out.
- **Sources:** S2, S8, S12, S19, S20, S33.

### A14 `clang-enable-modules-and-explicit-clang-modules`
- **What/why:** `CLANG_ENABLE_MODULES=YES` lets ObjC/C code use module maps (headers parsed once, cached as PCM) instead of textual includes [S6],[S7]. Xcode 16+ builds C/ObjC modules explicitly by default [S20] (build-setting name `CLANG_ENABLE_EXPLICIT_MODULES` is my recollection; not verified in fetched text).
- **Detect:** `CLANG_ENABLE_MODULES = NO`; code importing with quotes (`#import "Foo.h"`) of framework headers rather than `<Foo/Foo.h>`/`@import`; frameworks missing `DEFINES_MODULE=YES`.
- **Fix:** `CLANG_ENABLE_MODULES=YES`; `DEFINES_MODULE=YES`; framework-qualified imports. **auto** for settings; **rec** for import rewrite.
- **Impact:** unmeasured; important for ObjC-heavy code. Both.
- **Risks:** Headers that aren't self-contained break as modules [S6]; Rugby requires `@import` [S28].
- **Sources:** S2, S6, S7, S20.

### A15 `swift-use-integrated-driver`
- **What/why:** Integrated swift-driver runs inside the build system process, avoiding per-invocation process overhead [S2]. Default since ~Xcode 14.
- **Detect:** `SWIFT_USE_INTEGRATED_DRIVER = NO` (often set for XCRemoteCache, old CocoaPods hacks) [S25].
- **Fix:** Remove/`YES`. **auto**, but conflicts with XCRemoteCache which requires `NO` on Xcode 14+ [S25] and breaks compilation caching which requires YES [S18].
- **Impact:** unmeasured. Both.
- **Sources:** S2, S18, S25.

### A16 `compilation-cache-enable-caching` (Xcode 26+)
- **What/why:** `COMPILATION_CACHE_ENABLE_CACHING=YES` ("Enable Compilation Caching") caches compile results keyed on inputs in a content-addressable store (LLVM CAS) at `DerivedData/CompilationCache.noindex`. Umbrella over `SWIFT_ENABLE_COMPILE_CACHE` and `CLANG_ENABLE_COMPILE_CACHE`. Helps branch switching and clean builds [S8],[S2],[S18]. Needs `SWIFT_ENABLE_EXPLICIT_MODULES=YES`, `SWIFT_USE_INTEGRATED_DRIVER=YES`, `CLANG_ENABLE_MODULES=YES` [S19].
- **Detect:** Xcode >=26 and `COMPILATION_CACHE_ENABLE_CACHING` absent/NO in project/xcconfig/per-user settings; Swift targets in explicit-modules mode.
- **Fix:** `COMPILATION_CACHE_ENABLE_CACHING = YES` (project, `xcodebuild` arg, or per-user setting; per-user avoids committing). **auto** (project/xcconfig) but recommend per-user/xcconfig for opt-in rollout.
- **Impact:** AvdLee reference: 5-14% faster clean builds on projects of 87-1,991 Swift files [S2]. Tuist M4 Pro benchmarks, local cache build-time reduction: Wikipedia 24%, Pocket Casts 36%, Tuist CLI 77%, Mastodon (SwiftPM) 19%, Mastodon (Tuist-generated) 55%; remote cache 18/20/53/30/69% [S17]. Bitrise: "up to 30%" [S21]. Counter-evidence: Mac mini CI user saw no change [S31]; first cold build can be slightly slower [S4]. Clean and cached rebuilds; incremental small.
- **Risks:** Opt-in/early: not cacheable: storyboards/XIB, asset catalog variants, script phases, data model compile, dsym, linking; SPM deps not cacheable in 26 beta (Sept 2025 note) [S19]; cache grows (one report 20.65 -> 47.66 GB DerivedData) [search result: Apple forum thread 779612]; `clean` does not remove CompilationCache.noindex [S18]; no Index DataStore with remote caching [S19]; absolute-path leaks block cross-machine sharing [S51]; existing DerivedData outputs bypass the cache (0% remote hit) [S18].
- **Sources:** S2, S8, S17, S18, S19, S21, S30, S31, S51.

### A17 `compilation-cache-remote-plugin`
- **What/why:** Share the CAS across machines/CI via a gRPC cache service: `COMPILATION_CACHE_ENABLE_PLUGIN=YES`, `COMPILATION_CACHE_REMOTE_SERVICE_PATH=<socket>`, plus `COMPILATION_CACHE_ENABLE_INTEGRATED_QUERIES`, `COMPILATION_CACHE_ENABLE_DETACHED_KEY_QUERIES` [S17],[S18],[S19].
- **Detect:** CI on Xcode 26+, cold runners, team >1; no remote cache config.
- **Fix:** Use a vendor (Tuist `tuist setup cache`, Bitrise Build Cache CLI wrapper) which injects flags. **rec** (needs service).
- **Impact:** See A16 remote column [S17]; remote is slower than local because of thousands of network requests [S17].
- **Risks:** Bitrise wrapper does not cover builds started from the Xcode UI [S18]; fixed paths/module cache dir must match across machines [S51].
- **Sources:** S17, S18, S19, S51.

### A18 `swift-strict-concurrency-cost`
- **What/why:** `SWIFT_STRICT_CONCURRENCY=complete`, Swift 6 language mode, `SWIFT_APPROACHABLE_CONCURRENCY`, `SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor` add isolation/Sendable checking passes [S9]. Compile-time cost is project dependent.
- **Detect:** these keys in pbxproj/xcconfig; compare `-stats-output-dir` / timing summary with key toggled.
- **Fix:** none automatic; measure. AvdLee deliberately treats as out of scope (migration decision, not build-perf) [S2]. **rec/measure only**.
- **Impact:** No benchmark found. 
- **Risks:** Lowering strictness trades correctness diagnostics for speed; not recommended as a perf lever.
- **Sources:** S2, S9.

### A19 `swift-upcoming-feature-flags-cost`
- **What/why:** `SWIFT_UPCOMING_FEATURE_*` / `-enable-upcoming-feature` flags change inference/checking; cost unmeasured in sources. Out of scope per AvdLee [S2].
- **Detect:** `SWIFT_UPCOMING_FEATURE_*` keys; `OTHER_SWIFT_FLAGS` with `-enable-upcoming-feature`; differences across sibling targets (module-variant risk, A24).
- **Fix:** measure; keep consistent across targets. **rec**.
- **Impact:** unmeasured.
- **Sources:** S2, S9.

### A20 `other-swift-flags-timing-warnings` (diagnostic)
- **What/why:** `-Xfrontend -warn-long-function-bodies=<ms>` and `-Xfrontend -warn-long-expression-type-checking=<ms>` surface slow type-checking as warnings (use 100 ms) [S5],[S15]. Deeper: `-driver-time-compilation`, `-Xfrontend -debug-time-function-bodies`, `-Xfrontend -debug-time-expression-type-checking`, `-stats-output-dir` [S13],[S1].
- **Detect:** absence in `OTHER_SWIFT_FLAGS` (opportunity); presence in Release/CI committed config (cleanup).
- **Fix:** add temporarily in Debug, never in Release. **auto, reversible; tool should remove after run**.
- **Impact:** diagnostic only; enables fixes (e.g. 97.7% faster after splitting expression [S44 search summary], 42 s -> 0.19 s in S16).
- **Risks:** noisy warnings; with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` they break the build; `-Xfrontend` flags go to every frontend (interleaved output) [S13]. Heavy `-debug-time-*` slows builds.
- **Sources:** S1, S5, S13, S15, S16.

### A21 `gcc-precompile-prefix-header`
- **What/why:** `GCC_PRECOMPILE_PREFIX_HEADER=YES` precompiles the prefix header; most effective when the prefix header and files it includes change rarely; frequent changes increase build time [S9].
- **Detect:** `GCC_PREFIX_HEADER` set (ObjC projects) and `GCC_PRECOMPILE_PREFIX_HEADER = NO`; or YES with a prefix header that imports frequently-edited headers.
- **Fix:** YES + keep prefix header to system/stable headers; prefer modules. **auto** for flag; **rec** for header content.
- **Impact:** unmeasured. Both (ObjC only).
- **Sources:** S9.

### A22 `headermap-and-header-search-paths`
- **What/why:** Header maps (`USE_HEADERMAP=YES`) resolve `"Foo.h"` fast; recursive `HEADER_SEARCH_PATHS` (`/**`) and `ALWAYS_SEARCH_USER_PATHS=YES` make the preprocessor stat many directories; `USER_HEADER_SEARCH_PATHS` bloat slows every ObjC TU. [K - no source fetched for numbers].
- **Detect:** `USE_HEADERMAP = NO`; `HEADER_SEARCH_PATHS`/`USER_HEADER_SEARCH_PATHS` containing `/**` or very long lists; `ALWAYS_SEARCH_USER_PATHS = YES`.
- **Fix:** `USE_HEADERMAP=YES`, `ALWAYS_SEARCH_USER_PATHS=NO`, replace recursive globs with explicit paths/module maps. **auto** for booleans; **rec** for path rewrite.
- **Impact:** unmeasured. Both.
- **Risks:** path removal breaks imports.
- **Sources:** [K]; related S6/S7 (module maps preferred).

### A23 `eager-linking-debug`
- **What/why:** `EAGER_LINKING=YES`: build system emits a TBD for Swift-only framework/dylib targets so dependents can link before the dependency finished linking [S9],[S5].
- **Detect:** Debug `EAGER_LINKING` != YES in a project with multiple Swift framework/dynamic-library targets (no effect on static libs or ObjC).
- **Fix:** Debug `YES`. **auto** (test; S5 says "test whether it helps").
- **Impact:** unmeasured; larger on deep dynamic module graphs. Debug.
- **Risks:** Applies only to Swift-only dynamic targets; ObjC-containing targets ignored.
- **Sources:** S1, S2, S5, S9.

### A24 `module-variant-drift`
- **What/why:** When targets importing the same module use different build options (`SWIFT_OPTIMIZATION_LEVEL`, `SWIFT_COMPILATION_MODE`, `OTHER_SWIFT_FLAGS`, preprocessor macros, `SWIFT_UPCOMING_FEATURE_*`), the build compiles separate module variants (e.g. SwiftUI built several times), inflating `SwiftEmitModule`/scan counts [S20],[S6],[S2].
- **Detect:** diff effective settings across targets that share dependencies; target-level overrides of keys above that differ from project-level; Build log "variant" counts.
- **Fix:** Move settings to project level/shared xcconfig; unify macros. **rec** (auto for pure duplication where values equal project level).
- **Impact:** unmeasured; reduces explicit-module task count. Both.
- **Sources:** S2, S6, S20.

### A25 `dead-code-stripping`
- **What/why:** `DEAD_CODE_STRIPPING=YES` passes `-dead_strip` to ld [S9].
- **Detect:** Debug setting.
- **Fix:** CONFLICT. zld README: turn off in Debug to speed linking [search summary: https://github.com/michaeleisel/zld]; Apple WWDC22: `-dead_strip` "is fast and usually reduces output size enough to pay for itself - measure with and without" [S11]. **rec: benchmark, do not auto-apply**.
- **Impact:** unmeasured with new linker.
- **Risks:** hides missing-symbol errors from unreachable code; selective loading pitfalls with ObjC categories [S11].
- **Sources:** S9, S11.

### A26 `linker-flags-all-load-no-dedup-no-exported`
- **What/why:** `-Wl,-all_load` allows parallel parsing of static libs; `-Wl,-no_deduplicate` skips the expensive dedup pass (Xcode passes it for Debug already); `-Wl,-no_exported_symbols` removes export-trie work for apps (2-3 s saved for ~1M exported symbols) [S11].
- **Detect:** `OTHER_LDFLAGS` lacking these in large apps with many static libs; export count via `dyld_info -exports <binary>`.
- **Fix:** add to Debug `OTHER_LDFLAGS`. **rec** (semantic risks).
- **Impact:** 2-3 s link-time example [S11].
- **Risks:** `-all_load` changes duplicate-symbol resolution order; `-no_exported_symbols` breaks apps hosting XCTest bundles or plugins linking back [S11].
- **Sources:** S11.

### A27 `linker-version-ld-prime`
- **What/why:** Xcode 14 ld64 ~2x faster for many projects [S11]; Xcode 15 new linker default [S49]. `-ld_classic` (or `-Wl,-ld_classic`) opts back to old linker and removes the speedup; in Xcode 27 ld64/`-ld_classic` is removed (secondary) [S33].
- **Detect:** `OTHER_LDFLAGS` containing `-ld_classic`/`-Wl,-ld_classic`/`-ld64`; Podfile post_install adding it.
- **Fix:** remove flag. **auto** (verify link success).
- **Impact:** ~2x link time for large apps (Xcode 14 data) [S11].
- **Risks:** Xcode 15.0.1/15.1 LTO assertion; "invalid use of branch fixup" bugs were reasons for the flag [S49]. `-ld64` breaks Xcode 27 [S33].
- **Sources:** S11, S33, S49.

### A28 `llvm-lto-incremental`
- **What/why:** `LLVM_LTO`: `YES` monolithic = slowest; `YES_THIN` ("Incremental") faster, less memory [S9].
- **Detect:** `LLVM_LTO = YES` (monolithic) or any LTO in Debug.
- **Fix:** Debug `NO`; Release use `YES_THIN` unless size/perf proves monolithic. **auto** for Debug; **rec** for Release.
- **Impact:** unmeasured. Release.
- **Risks:** Xcode 15.x LTO regression [S49]; thin LTO may give slightly less optimization.
- **Sources:** S9, S49.

### A29 `strip-settings-debug-off`
- **What/why:** `STRIP_INSTALLED_PRODUCT`, `STRIP_STYLE`, `STRIP_SWIFT_SYMBOLS`, `COPY_PHASE_STRIP` run `strip` in deployment post-processing [S9]. In Debug/Run builds stripping is wasted (it only runs on install/archive normally).
- **Detect:** Debug `COPY_PHASE_STRIP = YES`, `STRIP_INSTALLED_PRODUCT=YES` with `DEPLOYMENT_POSTPROCESSING=YES`.
- **Fix:** Debug `COPY_PHASE_STRIP=NO`, `DEPLOYMENT_POSTPROCESSING=NO`. **auto**.
- **Impact:** small. Debug.
- **Risks:** Release should keep stripping for size; `STRIP_SWIFT_SYMBOLS=NO` affects symbolication of external tools (use dSYM).
- **Sources:** S9; Debug semantic [K].

### A30 `enable-user-script-sandboxing-and-parallel-scripts`
- **What/why:** `ENABLE_USER_SCRIPT_SANDBOXING=YES` sandboxes scripts to declared inputs/outputs [S9]; paired with "Run Build Script Phases in Parallel" (`FUSE_BUILD_SCRIPT_PHASES=YES`, "script phases run concurrently once dependency analysis shows inputs ready" [S48]) it lets correctly-declared scripts overlap compilation [S5],[S1].
- **Detect:** `ENABLE_USER_SCRIPT_SANDBOXING = NO` or unset in older projects; `FUSE_BUILD_SCRIPT_PHASES` absent; scripts lacking I/O (see D1).
- **Fix:** After D1, enable both. **rec** (scripts that read undeclared files will fail).
- **Impact:** unmeasured; reduces serialization.
- **Risks:** CocoaPods/embed scripts frequently fail under sandbox (need declared xcfilelists); "FUSE" naming from WebKit bug, verify in Xcode UI.
- **Sources:** S1, S5, S9, S48.

### A31 `swift-cross-module-optimization`
- **What/why:** `-cross-module-optimization` (Other Swift Flags) erases module boundary for optimization; mostly a runtime perf lever for modularized projects, costs compile time; use Release only [S46]. If CMO is needed, missing `@inlinable` is usually the cause [S46]. There is no stable Xcode build-setting key I could verify.
- **Detect:** Release builds of heavily modularized apps with measurable runtime regressions; flag presence in Debug.
- **Fix:** Release only; **rec**.
- **Impact:** build time cost, runtime gain unmeasured.
- **Risks:** code-size changes; passing via SwiftPM `unsafeFlags` reportedly unhelpful [S46]; blocks SwiftPM dependency use of unsafeFlags.
- **Sources:** S46.

### A32 `build-library-for-distribution-cost`
- **What/why:** `BUILD_LIBRARY_FOR_DISTRIBUTION=YES` enables library evolution and emits `.swiftinterface` (extra emit step; resilience disables some optimizations) [S9].
- **Detect:** `BUILD_LIBRARY_FOR_DISTRIBUTION = YES` on internal targets not shipped as XCFramework; `-enable-library-evolution` in flags.
- **Fix:** `NO` for internal modules. **auto** when target is not distributed as binary.
- **Impact:** unmeasured. Both.
- **Risks:** required for binary XCFrameworks distributed to others; cross-compiler-version compat.
- **Sources:** S9 (semantics); cost statement partially [K].

### A33 `enable-debug-dylib`
- **What/why:** Xcode 16+ `ENABLE_DEBUG_DYLIB` splits Debug app code into `NAME.debug.dylib` + stub; required for Previews/modern dev features; incremental link/relaunch can benefit, but it changes layout [S9],[S47].
- **Detect:** `ENABLE_DEBUG_DYLIB = NO` on app targets using SwiftUI Previews; or YES with scripts that scan the executable.
- **Fix:** leave YES unless tooling incompatibility. **rec**.
- **Impact:** no benchmark found. 
- **Risks:** disabling breaks Previews; known launch failures when mismatched [forums].
- **Sources:** S9, S47.

### A34 `explicit-new-package-pif-builder` (Xcode 26 preview)
- **What/why:** `defaults write com.apple.dt.Xcode IDEEnableNewPackagePIFBuilder -bool YES` opts into the new Swift Build-based package build implementation (consistency/stability; not documented as a speed feature) [S8].
- **Detect:** Xcode 26 + SPM-heavy project.
- **Fix:** **rec** experimental only.
- **Impact:** unmeasured.
- **Sources:** S8.

---
# B. SWIFT CODE-LEVEL (category: swift-code-level)

General detection method: run build with `-Xfrontend -warn-long-function-bodies=100 -Xfrontend -warn-long-expression-type-checking=100` (A20) and parse warnings (file:line + ms). Static heuristics below are fallbacks; all fixes are **rec** (a tool may suggest, not auto-edit, except trivially safe `final`).

### B1 `type-check-complex-expressions`
- **What/why:** Constraint-solver search is exponential in worst case; operators (`+` has 17 stdlib overloads) x literal protocols (9 string-literal types) multiplies [S16]. Apple recommends simplifying dense one-line closures with nested ternaries [S7].
- **Detect:** warnings from A20; heuristic: lines with >=4 binary operators of mixed literal/number types; chains with `+`, `??`, `?:`; closures >1 line without explicit signature.
- **Fix:** split into named intermediate `let`s with explicit types; convert one-liners to `if`/`switch`. 
- **Impact:** 12-line string concat with type error: 42 s -> 0.19 s with `String(channel)` (M1 Pro, Swift 6) [S16]; `let result: Double = -(1+1) + -(1+1) - 1` 6.2 s; local variables took 410+ ms -> 7.1 ms (97.7%) in forum case [S43/S44]. Both clean and incremental for that file.
- **Risks:** more verbose; annotation alone isn't a reliable rule since checker must still validate it [S43].
- **Sources:** S7, S16, S43, S44.

### B2 `explicit-types-literals-collections`
- **What/why:** Inference is cheap for simple literals, costly in complex expressions; explicit types reduce work [S7]. Array/dictionary literals with mixed/heterogeneous elements are common slow spots [S44].
- **Detect:** large `[ ... ]`/`[k: v]` literals (>~20 elements) without type annotation; mixed int/double/enum cases; chained `map/flatMap/filter/reduce` w/o typed intermediates [S1].
- **Fix:** `let x: [String: Banana] = [...]`; typed intermediates; move big static data to JSON/plist resource or generated file in its own module.
- **Impact:** unmeasured per se; Apple's own contrived example `var bigNumber: Double = ...reduce` [S7].
- **Sources:** S1, S7, S21, S44.

### B3 `closures-explicit-return-types`
- **What/why:** Closures passed to generic functions without explicit signature force joint inference of closure and generic [S1].
- **Detect:** multi-statement closures to `map/reduce/sorted` lacking `-> T`; warnings from A20.
- **Fix:** `{ (x: Int) -> String in ... }`.
- **Impact:** unmeasured. 
- **Sources:** S1, S7.

### B4 `string-interpolation-vs-concatenation`
- **What/why:** Chains of `+` on strings/optionals multiply overload candidates; interpolation or `String(...)` avoids [S16],[S44].
- **Detect:** regex for lines with >=3 `+` where at least one operand is a literal; any line mixing `??` with `+` (reported 38 s -> 6.6 ms case [S44]).
- **Fix:** use interpolation, `joined()`, or `let` pieces.
- **Impact:** see B1.
- **Sources:** S16, S44.

### B5 `nil-coalescing-and-ternary-chains`
- **What/why:** `??` and `?:` nested with other operators are reported especially slow [S44], [S7].
- **Detect:** `??` count >=2 per expression; nested `? :`.
- **Fix:** `if let`/`switch`, typed temporaries.
- **Sources:** S7, S44.

### B6 `swiftui-body-decomposition`
- **What/why:** Large `body` with deep nested containers is one huge result-builder expression for the type checker; `@ViewBuilder` helper properties are less effective than separate `struct View` types which narrow checker scope [S1]. Developers report "unable to type-check in reasonable time" resolved by splitting body into subviews and chained `+` on `Text` into helpers [S53].
- **Detect:** `var body: some View` spanning ~50+ lines; nesting depth >4 of `Group/VStack/HStack`; long chains of modifiers; `Text + Text + ...`; A20 warnings in `*View.swift`.
- **Fix:** extract `struct SubView: View`, move conditional logic out of body, reduce `ViewBuilder` complexity.
- **Impact:** unmeasured aggregate; per-expression minutes -> ms in reported cases.
- **Risks:** more files/types; state plumbing; behavior of view identity unchanged if done carefully.
- **Sources:** S1, S3, S53.

### B7 `generics-protocols-associated-types`
- **What/why:** Heavy generic/overloaded chains and `some`/associated-type protocols raise solver and specialization work (S1 mentions "overloaded generic chains"); generic specialization needs visibility, WMO resolves cross-file [S14].
- **Detect:** deeply nested generic functions with many overloads; A20 warnings; many `where` constraints.
- **Fix:** concrete types at module boundaries; fewer overloads of same name; `@_specialize` only if profiling shows need.
- **Impact:** unmeasured. [mostly K beyond S1/S14].
- **Sources:** S1, S14.

### B8 `result-builders-and-dsl-complexity`
- **What/why:** Result builders (SwiftUI, custom DSLs) type-check bodies as one expression (S1 "reduce result builder complexity").
- **Detect:** custom `@resultBuilder` usage with large blocks; SwiftUI (B6).
- **Fix:** split blocks, avoid `AnyView` churn, smaller builders.
- **Impact:** unmeasured.
- **Sources:** S1.

### B9 `swift-macros-cost`
- **What/why:** Macros require building/linking swift-syntax and launching plugin processes; Xcode 26 downloads prebuilt swift-syntax automatically [S8]. Macro expansion can invalidate downstream modules even when output unchanged; heavy macro use (TCA) makes trivial edits rebuild much [S1],[S22].
- **Detect:** Package.swift dependency on `swift-syntax` or macro libs (TCA, swift-dependencies, SwiftData `@Model`); `.macro(` targets; many macro plugins per module (see E8).
- **Fix:** isolate macro-using code in few stable modules; ensure `swiftlang/swift-syntax` URL (not `apple/`) so prebuilts apply [S23]; Xcode 26+.
- **Impact:** swift-syntax: ~12 s -> ~23 s small app (M1 Ultra), +12 min on Xcode Cloud (2024 reports) [S37]; prebuilt reduced emit-module penalty 40 s -> 16 s (Xcode 16.4) [S23].
- **Risks:** prebuilts failed for some builds (`_SwiftSyntaxCShims`, redefinition of module with plugins) [S8],[S23].
- **Sources:** S1, S8, S22, S23, S24, S37.

### B10 `testable-import-debug-only`
- **What/why:** `@testable import` needs `ENABLE_TESTABILITY=YES`, which disables optimizations/strip; fine in Debug only (see A7).
- **Detect:** `@testable import` in non-test targets; Release config running tests.
- **Fix:** restrict to test targets; Release `ENABLE_TESTABILITY=NO`.
- **Sources:** S9, S2.

### B11 `access-control-final-private`
- **What/why:** `final`/`private`/`fileprivate` let the compiler devirtualize and shrink symbol search; with WMO `internal` can be inferred final [S14]. AvdLee lists as compile-time check: `final`, narrow visibility, prefer struct/enum, narrow ObjC bridging (`private` members stay out of generated header) [S1],[S7].
- **Detect:** `class X` without `final` and no subclass in repo (scan `: X`); `public`/`open` symbols with no cross-module users; `@objc`/`@objcMembers` on large classes.
- **Fix:** add `final` (auto-safe when no subclass in workspace and not `open`/mocked via subclass); narrow access (**rec**).
- **Impact:** mostly runtime perf; compile-time effect small/unmeasured (claim is weaker than commonly stated). Release mostly.
- **Risks:** `final` breaks subclass-based mocks/test doubles; narrowing access breaks `@testable` assumptions.
- **Sources:** S1, S7, S14.

### B12 `avoid-giant-files-and-types`
- **What/why:** Incremental/batch unit is the file; one 5,000-line file serializes and recompiles entirely on any edit; Signal example replaced a giant if-else with switch [S21]. Per-file ranking via `-driver-time-compilation` [S13],[S15].
- **Detect:** Swift files >1,000 lines; per-file times from `-debug-time-compilation`; top-N file share (S15 example: one file 0.3%).
- **Fix:** split types into files; keep related extensions separate. 
- **Impact:** unmeasured. [claims partly K].
- **Sources:** S13, S15, S21.

### B13 `extension-placement-and-code-organization`
- **What/why:** Putting many extensions of a hot type in one file couples recompilation; moving rarely-edited extensions to own files reduces incremental fan-out [K - no source].
- **Detect/Fix:** rec only.
- **Sources:** [K].

### B14 `codable-and-synthesized-conformance-cost`
- **What/why:** Synthesized Codable/Equatable/Hashable for large structs/enums with many cases/associated values generate large code and checks [K]; no source measured it (search found none).
- **Detect:** enums >50 cases or structs >40 stored properties with synthesized `Codable`/`Equatable`/`CaseIterable`; large IR files.
- **Fix:** hand-written `==`, `CodingKeys`, `switch`-based `hash(into:)`, split types.
- **Impact:** unmeasured. **rec**, [K].
- **Sources:** [K] (SE-0295 only on design: https://github.com/swiftlang/swift-evolution/blob/main/proposals/0295-codable-synthesis-for-enums-with-associated-values.md)

### B15 `delegate-protocols-vs-anyobject`
- **What/why:** `weak var delegate: AnyObject?` forces compiler to search the whole project and imported frameworks for the method; declare a protocol [S7].
- **Detect:** `AnyObject?`/`Any?` property followed by `delegate?.method` calls (selector-like dynamic lookup).
- **Fix:** define protocol, type the property.
- **Sources:** S7.

### B16 `lazy-var-closures-and-property-initializers`
- **What/why:** Multi-statement property-initializer and `lazy var` closures are type-checked as one closure body without annotations; inference cost similar to B3 [K].
- **Detect:** `lazy var x = { ... }()` without `: Type`.
- **Fix:** add explicit type annotation.
- **Impact:** unmeasured. [K]; related: Apple's example with explicit `var bigNumber: Double` [S7].
- **Sources:** S7, [K].

### B17 `objc-swift-bridging-surface`
- **What/why:** Only include headers Swift needs in the bridging header; mark internal Swift members `private` to keep them out of the generated `-Swift.h`; prefer blocks; use latest Swift language version (less inferred @objc) [S7].
- **Detect:** bridging header with >~20 imports or umbrella imports; `@objcMembers`; `@objc` on internal API.
- **Fix:** trim bridging header; categories/internal headers; drop `@objc`.
- **Impact:** unmeasured; larger on mixed projects (header imports are a frequent compile hotspot) [S6].
- **Sources:** S6, S7.

### B18 `reduce-api-surface-emit-module`
- **What/why:** In big modules `SwiftEmitModule` can exceed 60 s after a one-line change and can rival compile time; wide public API surface is a suspect [S1]. `@_exported import` umbrellas create hidden rebuild chains [S1].
- **Detect:** timing summary SwiftEmitModule vs CompileSwiftSources per target; `@_exported import`; `public`-heavy modules.
- **Fix:** interface/implementation separation, narrower public API, remove `@_exported`.
- **Sources:** S1, S22.

---
# C. PROJECT STRUCTURE / MODULARIZATION (category: project-structure/modularization)

### C1 `modularize-frameworks-packages`
- **What/why:** Incremental builds recompile only changed modules; stable modules are skipped; modules compile in parallel; ObjC/Swift boundary headers stop leaking. Apple: break monolithic frameworks into smaller modules with finer dependencies [S6]; fastred's DatabaseKit example [S15].
- **Detect:** one app target with >~500 Swift files or >50k lines; `CompileSwiftSources` for one target >50% of total; flat file tree with no module boundaries.
- **Fix:** extract stable layers (Core/Domain, Networking, UI kit) into local SPM packages or framework targets. **rec** (large refactor).
- **Impact:** LINE, Allegro and Gojek saw big wins when combined with cache (S26: clean 260 s -> 85 s with Bazel; S27: avg 30.96 -> 14.53, ~53%). Pure modularization alone unmeasured. Incremental mostly.
- **Risks:** more modules = more planning/emit overhead (planning up to 30 s per module in incremental builds [S1]); startup cost if dynamic [S11]; module variant duplication.
- **Sources:** S1, S6, S15, S26, S27.

### C2 `static-vs-dynamic-linking`
- **What/why:** Static: source change forces whole static library + TOC rebuilt; many static libs slow iterative builds. Dynamic: each dylib adds launch cost (load+fixups) [S11]. Faster linker moves sweet spot toward more static.
- **Detect:** Package products `.dynamic` vs `.static`/automatic; framework targets `MACH_O_TYPE` = `mh_dylib` vs `staticlib`; count of embedded frameworks in app; `ar` libs for actively edited code.
- **Fix:** keep actively developed code in dynamic frameworks (Debug) and stable code static; in Release use mergeable libs (C3). **rec**.
- **Impact:** unmeasured numerically; WWDC22 qualitative [S11].
- **Risks:** duplicate class warnings when static lib linked into multiple frameworks [S11]; ObjC category stripping.
- **Sources:** S11, S10.

### C3 `mergeable-libraries`
- **What/why:** `MERGED_BINARY_TYPE=automatic` on app target: debug builds treat deps like normal dynamic libs (fast links); release merges them into the binary (fast launch) [S10]. `MERGEABLE_LIBRARY`/`MAKE_MERGEABLE` for manual mode; `-no_exported_symbols` style flags reduce merged export size [search summary].
- **Detect:** Xcode >=15; app embeds many dynamic frameworks (>5) in Release; `MERGED_BINARY_TYPE` absent.
- **Fix:** add `MERGED_BINARY_TYPE = automatic` to app target (direct deps only; indirect deps need manual config). **rec** (behavioral change; test).
- **Impact:** keeps Debug builds on dynamic path; avoids static-lib link cost; primary win is launch time rather than build time. Debug unaffected, Release link may take longer.
- **Risks:** extensions sharing deps (binary size); only direct dependencies auto-merged [S10].
- **Sources:** S10, S11.

### C4 `umbrella-core-module-anti-pattern`
- **What/why:** A giant `Core`/`Common`/`Shared` module that everything imports rebuilds everything on any change and serializes the critical path [S1],[S27].
- **Detect:** module graph (Package.swift/pbxproj target deps) with a node of fan-in >~50% of modules and high churn (git log); `@_exported import` umbrellas.
- **Fix:** split by stable interface vs implementation; move frequently edited code up the graph.
- **Impact:** unmeasured.
- **Sources:** S1, S27.

### C5 `module-graph-critical-path-and-fan`
- **What/why:** Build wall-clock >= longest dependency chain; large targets in graph are the bottleneck even with remote cache [S27]. Out-of-date/inflated dependencies force serial builds [S6].
- **Detect:** compute DAG depth and per-target compile time (from `-showBuildTimingSummary` / `.xcactivitylog`); width vs depth; targets with fan-out>>fan-in on critical path.
- **Fix:** break the biggest node on critical path first; flatten chains; invert dependencies via protocol modules.
- **Impact:** unmeasured quantitatively.
- **Sources:** S6, S27.

### C6 `break-circular-and-upward-dependencies`
- **What/why:** Circular/upward deps serialize builds and force workaround umbrella targets; extract shared contracts into lower module [S1],[S4].
- **Detect:** cycle detection on target dependency graph; layering rules (Common/Core -> Services -> Features/UI) violated [S1].
- **Fix:** extract interfaces; dependency inversion. **rec**.
- **Sources:** S1, S4.

### C7 `target-dependencies-accurate-and-dependency-order`
- **What/why:** Missing dependencies break builds; extra ones block parallelism; schemes should use "Dependency Order" [S6]. Parallelize Build and implicit dependency settings live in the scheme.
- **Detect:** `.xcscheme` `<BuildAction parallelizeBuildables="NO">` or `buildImplicitDependencies="NO"`; superfluous `PBXTargetDependency` entries (cross-ref against actual imports).
- **Fix:** `parallelizeBuildables="YES"`; prune deps; Build Order = Dependency Order. **auto** for scheme flag; **rec** for pruning.
- **Impact:** unmeasured. Both.
- **Risks:** "Find Implicit Dependencies" ON is convenient; turning OFF requires explicit deps to be complete; implicit scanning cost unmeasured in sources [K].
- **Sources:** S6.

### C8 `split-test-targets`
- **What/why:** Split one test target depending on many modules into one test target per module so each suite runs as soon as its dependency builds [S6]; test targets should depend on module under test, not entire app [S1].
- **Detect:** test target with TEST_HOST = app and >N dependencies; one `Tests` target linking everything.
- **Fix:** per-module test targets/packages.
- **Impact:** unmeasured. 
- **Sources:** S1, S6.

### C9 `schemes-unit-vs-all-tests`
- **What/why:** Separate schemes: app build + unit tests only vs all tests (UI tests build and run only when needed) [S15].
- **Detect:** one scheme building all targets including UI tests for Cmd-B.
- **Fix:** split schemes; use test plans; uncheck "Build" for UITests in run scheme.
- **Sources:** S15.

### C10 `dev-only-and-preview-targets`
- **What/why:** A small "playground/dev app" target or generated workspace excluding modules you are not working on makes builds, indexing, and Xcode more responsive (Allegro's workspace generator; Tuist focused projects) [S26]. Preview-specific tiny app target avoids building full app for SwiftUI Previews [K].
- **Detect:** one monolith scheme used for all work; Previews failing/slow in app target.
- **Fix:** create feature playground apps; use Tuist focus/XcodeGen.
- **Sources:** S26, [K].

### C11 `asset-and-resource-modularization` -> see E10.

### C12 `number-of-targets-and-platform-multiplication`
- **What/why:** Each added platform (watchOS etc.) builds shared packages once per platform/arch; many targets add planning/Info.plist/codesign overhead [S1].
- **Detect:** targets count; supported platforms vs actually needed.
- **Fix:** trim unused platform destinations; share only where needed. 
- **Sources:** S1.

### C13 `workspace-layout-local-packages`
- **What/why:** Local packages in same workspace edit-in-place (Xcode 26 fixed local package edits propagation [S8]); branch-pinned or many remote packages add resolve cost.
- **Detect:** mix of local and remote; embedded `.xcodeproj` in workspace not listed (Apple: drag project into navigator or target won't rebuild when it changes [S6]).
- **Sources:** S6, S8.

---
# D. SCRIPTS AND PHASES (category: scripts-and-phases)

### D1 `run-script-inputs-outputs`
- **What/why:** By default Run Script phases run every build, serially; with at least one input and one output declared (or `.xcfilelist`), Xcode runs only if inputs changed/outputs missing [S6]. Missing declarations are the #1 zero-change overhead (`PhaseScriptExecution`) [S1].
- **Detect:** pbxproj `PBXShellScriptBuildPhase` with empty `inputPaths`/`outputPaths` (and empty `inputFileListPaths`/`outputFileListPaths`), or `alwaysOutOfDate = 1`; "Based on dependency analysis" unchecked.
- **Fix:** add inputs/outputs or xcfilelists; for no-input scripts use stable dummy input and static output; check "Based on dependency analysis". **rec** (tool may scaffold but needs script semantics); no-op safe cases auto.
- **Impact:** AvdLee: Helm zero-change 70 s -> 9 s after fixes (incl. other items) [S4]; Sentry upload guard 6.3 s/incremental [S5].
- **Risks:** wrong declarations cause stale outputs/skipped scripts; sandboxing (A30) will fail loudly.
- **Sources:** S1, S4, S5, S6.

### D2 `guard-release-only-scripts`
- **What/why:** Symbol uploads (Crashlytics/Sentry), release tooling, network calls should skip in Debug/Simulator [S1].
- **Detect:** script text containing `upload-symbols`, `sentry-cli`, `run` from Crashlytics/Firebase, `curl`, without `${CONFIGURATION}`/`${PLATFORM_NAME}`/`ACTION` guard.
- **Fix:** wrap `if [ "${CONFIGURATION}" == "Release" ]; then ... fi`. **auto-ish** (wrap whole script; verify).
- **Impact:** 6.3 s/incremental (Sentry) [S5].
- **Sources:** S1, S5.

### D3 `linters-in-build-phase-swiftlint`
- **What/why:** SwiftLint in build phase: ~10 s per incremental build on WeTransfer main target; `--quiet` <1 s; linting only changed files saved ~15 s/build across targets [S5]. Linters/formatters that touch timestamps without changing content force replanning of Swift modules [S1],[S22].
- **Detect:** script phase calling `swiftlint`/`swiftformat`/`swiftgen`/`sourcery`/`R.swift`; `--fix` or formatters in build phase.
- **Fix:** move to pre-commit/CI; or run only on changed files; or SwiftPM build-tool plugin (but plugins add overhead [S5],[S1]); guard by configuration. **rec**.
- **Impact:** 10-15 s/build in WeTransfer example [S5].
- **Risks:** loses inline warnings in Xcode if moved off build phase.
- **Sources:** S1, S5, S22.

### D4 `codegen-tools-sourcery-swiftgen-rswift`
- **What/why:** Generators in build phase re-run and rewrite files each build (timestamp invalidation, replanning) [S1]. Rugby note: SwiftGen-generated code can change binary hashes [S28].
- **Detect:** scripts calling generators with no input/output lists; generated files checked in vs not.
- **Fix:** run on demand/pre-commit, write only on content change (diff before write), declare I/O.
- **Sources:** S1, S28.

### D5 `swiftpm-build-tool-plugins-overhead`
- **What/why:** Plugins add overhead even when producing no commands; prebuilt-plugin invalidated cache at WeTransfer; switching to a regular plugin reduced invalidations [S5]. Plugins that run on incremental builds without input changes are flagged [S1].
- **Detect:** Package.swift `plugins:` entries; `.plugin(` targets; `swiftlint` plugin usage.
- **Fix:** remove or restrict (use `-skipPackagePluginValidation` on CI for prompts only, not speed).
- **Sources:** S1, S5.

### D6 `crashlytics-firebase-upload-debug`
- Specific instance of D2. Detect: Run Script `"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"` or `${PODS_ROOT}/FirebaseCrashlytics/run` without config guard; also with `DEBUG_INFORMATION_FORMAT=dwarf` (no dSYM to upload). Fix: guard to Release. **auto-ish**. Impact seconds/incremental [S5 analog]. Sources: S5, S1.

### D7 `cocoapods-generated-phases`
- **What/why:** `[CP] Embed Pods Frameworks`, `[CP] Copy Pods Resources` run each build and re-sign; AvdLee says do NOT attempt CocoaPods-specific tweaks (`COCOAPODS_PARALLEL_CODE_SIGN`, linkage changes) because they regress unpredictably; recommend migrating to SPM [S1].
- **Detect:** Podfile, `Pods/` dir, `[CP]` script phases; `Pods-*.xcfilelist` presence (output lists exist, so mostly fine).
- **Fix:** **rec** SPM migration or precompiled pods (E4).
- **Sources:** S1.

### D8 `zero-change-build-overhead`
- **What/why:** No-edit rebuild overhead: `PhaseScriptExecution`, `CodeSign` (scales with binary count), `ValidateEmbeddedBinary`, `CopySwiftLibs`, `ProcessInfoPlistFile`, `ExtractAppIntentsMetadata` (Xcode-driven) [S1]. >5 s on Apple Silicon indicates script/codesign overhead [S1]. Planning swift module up to 30 s/module incrementally [S1].
- **Detect:** run zero-change build with timing summary; categorize per above.
- **Fix:** per-category: D1/D2, fewer embedded frameworks (C3/static), A11.
- **Impact:** Helm 70 s -> 9 s zero-change [S4].
- **Sources:** S1, S4.

### D9 `task-backtraces-diagnosis`
- **What/why:** Scheme > Build > Build Debugging > "Task Backtraces" (Xcode 16.4+) shows why each task re-ran; reveals timestamp-touching tools, nondeterministic input order [S1],[S22].
- **Detect/Fix:** diagnostic; enable when planning/emit dominate incremental builds. **rec**.
- **Sources:** S1, S22.

### D10 `copy-large-resources-and-asset-size`
- **What/why:** Large resource copy phases and `CopyPNGFile`/asset compile dominate clean builds; Apple notes these are uncacheable categories [S19],[S30].
- **Detect:** Copy Bundle Resources with large media (>~50 MB), bundled fonts/video/DBs; `CompileAssetCatalogVariant` times.
- **Fix:** move bulk assets to on-demand resources/download or dev-only bundles; trim image sets; skip in Debug.
- **Sources:** S19, S30, S32.

---
# E. DEPENDENCIES (category: dependencies (SPM/CocoaPods/Carthage))

### E1 `spm-pin-versions-not-branches`
- **What/why:** `branch:` pins force network checks on fresh resolves; use tags/`revision:` [S1].
- **Detect:** Package.swift/pbxproj `XCRemoteSwiftPackageReference` with `kind = branch`.
- **Fix:** pin version/revision. **auto** (needs resolved revision).
- **Sources:** S1.

### E2 `spm-resolution-time-and-cache`
- **What/why:** `xcodebuild clean` triggers re-resolve; Firebase and large graphs touch many files [S38]; old TargetSourcesBuilder bug caused >12 min start for firebase-ios-sdk (SR-13259; old).
- **Detect:** timing of "Resolve Package Graph"; `Package.resolved` absent from VCS; large git-heavy dependencies.
- **Fix:** commit `Package.resolved`; CI flags `-clonedSourcePackagesDirPath <dir>` + cache dir keyed on `Package.resolved` [S34],[S35]; `-disableAutomaticPackageResolution`/`-onlyUsePackageVersionsFromResolvedFile` [K - not verified in fetched text]; SPM registry (Tuist registry docs) [S34].
- **Impact:** CI example ~5 min build before caching [S35]; no precise number.
- **Sources:** S34, S35, S38.

### E3 `spm-binary-targets-xcframeworks-heavy-deps`
- **What/why:** Heavy third-party (Firebase, GoogleMaps, Realm) as prebuilt XCFramework binary targets avoid compiling from source; firebase-ios-sdk Package.swift already downloads prebuilt zips from dl.google.com for many products [search result swiftpackageindex build logs].
- **Detect:** deps from source (`.package(url:)`) with large source size: Realm (realm-swift), swift-syntax (macros), grpc, abseil, Kingfisher etc.; check if package offers `.binaryTarget`.
- **Fix:** prefer vendor binary distribution or in-house XCFrameworks (build with `BUILD_LIBRARY_FOR_DISTRIBUTION=YES`, optionally mergeable [S10]). **rec**.
- **Impact:** unmeasured (swift-syntax: see B9).
- **Risks:** Xcode version/Swift ABI compat; debugging without source; supply chain trust.
- **Sources:** S10, search results (SPI logs).

### E4 `cocoapods-precompiled-rugby-cocoapods-binary`
- **What/why:** Rugby caches pods as prebuilt binaries and removes pod targets from the project (also speeds indexing); no numbers published [S28]. cocoapods-binary-cache README: ~10% build-time reduction on a project with ~15% of code from pods [S29].
- **Detect:** Podfile with >20 pods; heavy pods (Realm, Firebase, Alamofire); clean build dominated by Pods.xcodeproj targets.
- **Fix:** adopt Rugby/cocoapods-binary-cache/PodBuilder. **rec**.
- **Risks:** ObjC must use `@import`; tests via Xcode UI problematic; generated code changes hashes [S28]; header-only/dev pods limitations [S29].
- **Sources:** S28, S29.

### E5 `cocoapods-to-spm-migration`
- **What/why:** AvdLee: top long-term improvement; SPM gives caching out of the box, better parallelism, no xcconfig regeneration, explicit-module support [S1].
- **Detect:** Podfile/Podfile.lock; no `Package.resolved`.
- **Fix:** migrate pod by pod; **rec** (also CocoaPods trunk read-only 2026? [unverified]).
- **Sources:** S1.

### E6 `carthage-prebuilt-frameworks`
- **What/why:** Carthage builds dependencies only when the dependency list changes; initial build 5-15 min [S15]; LINE: 15-20 min locally, Rome caching [S27].
- **Detect:** Cartfile; `Carthage/Build`.
- **Fix:** cache `Carthage/Build` keyed on `Cartfile.resolved` (or Rome); use `--use-xcframeworks`. **rec**.
- **Sources:** S15, S27.

### E7 `tuist-module-cache-and-xcode-cache`
- **What/why:** Tuist module cache stores per-module binaries (needs Tuist project generation); Tuist Xcode cache = remote compilation cache for any project [S50],[S17]. Tuist claims module cache outperforms compilation cache; can combine [S17].
- **Detect:** tuist presence (`Project.swift`, `Tuist/`); or any project on Xcode 26.
- **Fix:** `tuist cache` / `tuist setup cache`. **rec**.
- **Impact:** see A16 table [S17] (vendor benchmarks, Oct 2025).
- **Sources:** S17, S50.

### E8 `swift-syntax-prebuilts-for-macros`
- **What/why:** SwiftPM/Xcode download prebuilt swift-syntax (swift.org) instead of compiling it [S24],[S8]. Xcode 16.4: opt-in `defaults write com.apple.dt.Xcode IDEPackageEnablePrebuilts YES`; swift build `--enable-experimental-prebuilts` [S23]. Xcode 26: automatic [S8]. Disable switch if breaking: `IDEPackageEnablePrebuilts NO` [S8].
- **Detect:** Package.swift with `swift-syntax` dep using `apple/swift-syntax` URL (blocks prebuilts [S23]); Xcode 16.4 without default set; macro targets present.
- **Fix:** update to `https://github.com/swiftlang/swift-syntax`; Xcode 16.4: set default; Xcode 26: nothing. **auto** for URL (if you own Package.swift), user default **rec**.
- **Impact:** Emit-module penalty 40 -> 16 s [S23]; Xcode 26 beta tester clean build 6-20 s vs 23 s (forum anecdote); Swift 6.2 says "significantly improves clean build times" [S24].
- **Risks:** prebuilts not used for plugins/plugin tools; mixed forum reports they may still build from source on iOS targets [S23, search result].
- **Sources:** S8, S23, S24.

### E9 `bazel-remote-cache-and-build-systems`
- **What/why:** Bazel remote cache shares artifacts per action; Allegro clean 260 s -> 85 s [S26]; LINE avg 53% faster [S27]; Gojek 3x median (snippet only) and Spotify p75 ~30 s (snippet only) [S54].
- **Detect:** very large monorepo (>1M LoC), CI > 30 min.
- **Fix:** **rec** (huge migration). 
- **Risks:** large targets limit gains [S27]; local-path misses require monitoring [S26]; maintenance cost.
- **Sources:** S26, S27, S54.

### E10 `xcremotecache-spotify`
- **What/why:** Producer on CI uploads per-target artifacts keyed by fingerprint; consumers skip compile+link when fingerprints match [S25]. No numbers published.
- **Detect:** Xcode 11.4+..14 style project, multi-target, git repo, no SPM deps (not supported), needs `SWIFT_USE_INTEGRATED_DRIVER=NO` for Xcode 14+ [S25].
- **Fix:** adopt only if Xcode 26 compile cache is insufficient. **rec**.
- **Risks:** SPM unsupported; maintenance; conflicts with compile cache (needs integrated driver).
- **Sources:** S25.

### E11 `bitrise-build-cache-and-xcode-cloud`
- **What/why:** Bitrise Build Cache CLI wraps xcodebuild, injects cache flags, runs local gRPC proxy [S18]; Xcode Cloud restores DerivedData if "Clean" unchecked, not shared across branches/workflows [S39],[S55].
- **Detect:** CI provider.
- **Impact:** Bitrise "up to 30%" (vendor) [S21].
- **Risks:** Bitrise wrapper skips Xcode UI builds [S18].
- **Sources:** S18, S21, S39, S55.

---
# F. ENVIRONMENT / XCODE PREFS (category: hardware/environment/xcode-prefs)

### F1 `show-build-operation-duration-and-timing-summary`
- **What/why:** Measure first. `defaults write com.apple.dt.Xcode ShowBuildOperationDuration -bool YES` [S15]; Product > Perform Action > Build With Timing Summary / `xcodebuild -showBuildTimingSummary` [S6]; Build Timeline in Report navigator [S5].
- **Detect:** pref missing.
- **Fix:** **auto** (defaults write; reversible).
- **Impact:** diagnostic. Summed task time can exceed wall-clock because of parallelism (281 s Swift compile in a 37.3 s clean build) [S5].
- **Sources:** S5, S6, S15.

### F2 `concurrent-compile-tasks-defaults`
- **What/why:** `defaults write com.apple.dt.Xcode IDEBuildOperationMaxNumberOfConcurrentCompileTasks <n>`; default = core count; applies to next build; `xcodebuild -jobs <n>` per build [S42].
- **Detect:** pref present with value < core count, or machine with memory pressure.
- **Fix:** set equal to `sysctl -n hw.ncpu` (or lower if RAM-constrained). **auto**.
- **Impact:** usually none above default (gists only; unmeasured).
- **Risks:** too many jobs cause memory pressure/swap (esp. Release/WMO).
- **Sources:** S42.

### F3 `ide-index-disable`
- **What/why:** `IDEIndexDisable` disables the indexer, saving CPU/RAM during builds but removing autocomplete/jump-to-def/search [K - name from community gists].
- **Detect:** pref presence.
- **Fix:** **rec** only for CI/headless; not for developers.
- **Sources:** [K]; related S41.

### F4 `deriveddata-on-fast-local-disk-and-exclusions`
- **What/why:** DerivedData is the main build write target; keep it on fastest local SSD, not network volumes; over-provision SSD [S21]. AV tools scanning it hurt; asked/discussed on Apple forums but no authoritative speed number [S40]. `.noindex` folder names (`Index.noindex`, `ModuleCache.noindex`, `CompilationCache.noindex`) are intended to opt out of Spotlight [K - not verified]. Time Machine exclusion is [K].
- **Detect:** DerivedData path in workspace settings pointing to network/external HDD; `mdutil`/AV config; DerivedData size (CompilationCache can double it [Apple forum 779612]).
- **Fix:** set DerivedData location; exclude `~/Library/Developer/Xcode/DerivedData` from AV/Time Machine. **rec/auto for tmutil** (`tmutil addexclusion`).
- **Impact:** unmeasured.
- **Sources:** S21, S40.

### F5 `apple-silicon-ram-thermal`
- **What/why:** XcodeBenchmark (Xcode 16.2): M4 Pro Mac mini compiled the project 35% faster than M2 Pro; maximize P-cores [S21]. Thermal throttling on CI Macs: `pmset -g therm` and `CPU_Speed_Limit` <100 [S31].
- **Detect:** `sysctl -n machdep.cpu.brand_string` (Intel vs Apple Silicon), `hw.memsize`, `pmset -g therm`, `uname -m` under Rosetta (`sysctl sysctl.proc_translated`).
- **Fix:** hardware upgrade; run Xcode natively, not under Rosetta. **rec**.
- **Sources:** S21, S31.

### F6 `xcode-version-upgrade-and-multiple-copies`
- **What/why:** Xcode 14 linker ~2x [S11]; Xcode 26 caching/explicit modules/prebuilts [S8]; Xcode 27 faster scanner (secondary) [S33]. Multiple Xcode copies/betas share DerivedData ModuleCache but invalidate on version mismatch (cache churn) [K]; pin `xcode-select`.
- **Detect:** `xcodebuild -version`; `/Applications/Xcode*.app` list; `xcode-select -p`.
- **Fix:** upgrade within same major toolchain per project; delete unused copies; per-Xcode DerivedData dir on CI.
- **Sources:** S8, S11, S33.

### F7 `xcodebuild-vs-ide-and-simulator-vs-device`
- **What/why:** Tools wrapping xcodebuild (Bitrise cache) do not intercept IDE builds [S18]; device builds sign and install (more steps) vs simulator [K]. Release/device-only steps (`CodeSign`, install) add per-build cost [S1].
- **Detect/Fix:** use simulator Debug for iteration; **rec**.
- **Sources:** S1, S18.

### F8 `swift-explicit-planning-bugs-xcode-26x`
- **What/why:** Planning-phase performance bugs: macro plugin order nondeterminism (108/375 modules replanned; no-change build 127 s vs 15 s) fixed in Swift Build PR #1203 (Swift 6.4/Xcode 27); swift-driver path-cache lock (planning median 11.6-18.5 s -> 2.5-4 s with PR #2220) [S22].
- **Detect:** many modules + several macro plugins on Xcode 26.x; "Planning Swift module" dominates incremental builds.
- **Fix:** give macro plugins only to modules that use them; upgrade to Xcode 27. **rec**.
- **Sources:** S22.

---
# G. CI-SPECIFIC (category: CI-specific / caching)

### G1 `ci-derived-data-cache`
- **What/why:** Persisting DerivedData lets xcodebuild do incremental builds, but mtime on restored files changes and forces rebuilds; restore timestamps (git-restore-mtime) or tar preserve [S36]. Xcode Cloud restores DerivedData only if Clean unchecked; not shared across branches [S39],[S55].
- **Detect:** CI config w/o cache steps or with `xcodebuild clean build` every time.
- **Fix:** cache DerivedData keyed by Xcode version+lockfile; preserve mtimes; or use compilation cache (A16) which is content-addressed and not mtime-based [S18]. **rec**.
- **Impact:** unmeasured; Mac mini CI user: incremental 8 min vs 1-2 min local even with fixed derivedDataPath—cause may be throttling [S31].
- **Sources:** S18, S31, S36, S39, S55.

### G2 `ci-spm-cache-clonedsourcepackagesdirpath`
- **What/why:** `-clonedSourcePackagesDirPath <dir>` (the spelling seen in SPI logs is `-IDEClonedSourcePackagesDirPathOverride`; verify via `xcodebuild -help`) + cache keyed on `**/Package.resolved` [S34],[S35].
- **Fix:** **auto** in CI YAML.
- **Impact:** CI ~5 min before caching [S35].
- **Sources:** S34, S35.

### G3 `ci-skip-validation-flags`
- **What/why:** `-skipPackagePluginValidation` and `-skipMacroValidation` avoid interactive trust prompts/failures for plugins/macros on CI (correctness, not speed) [search: Swift Package Index build logs].
- **Detect:** CI `xcodebuild` invocations lacking them in macro/plugin projects (failures "must be enabled before it can be used").
- **Fix:** add flags. **auto** (security tradeoff: trust implied).
- **Sources:** SPI build logs https://swiftpackageindex.com/builds/18DA3489-72B8-4EDB-8C29-8CF9786FDBDE (shows usage only).

### G4 `ci-test-parallelization-and-sharding`
- **What/why:** `-parallel-testing-enabled YES` and `-parallel-testing-worker-count <n>` run simulator clones in parallel; shard across runners [S21].
- **Detect:** xcodebuild test w/o flags; Test Plan `parallelizable`.
- **Fix:** **auto** flag; **rec** sharding. Use `build-for-testing`/`test-without-building` to split [K].
- **Risks:** tests with shared state flake.
- **Sources:** S21.

### G5 `ci-index-store-off`
- See A8; CI-only `COMPILER_INDEX_STORE_ENABLE=NO` [S41]. Caveat Periphery/index consumers.

### G6 `ci-warm-vs-cold-runners-and-slo`
- **What/why:** Warm persistent runners (self-hosted Mac minis, Namespace volume caches) vs cold ephemeral VMs; vendor claims e.g. WarpBuild 25 -> 8 min (vendor) [S5]; define SLO (e.g. PR build <10 min) and alert [S21].
- **Fix:** **rec**.
- **Sources:** S5, S21.

### G7 `ci-compilation-cache-remote`
- See A17; Xcode 26.
- Notes: first-run cold, populate on main-branch builds; consumers need identical paths/Xcode [S51].

### G8 `measure-regressions-continuously`
- **What/why:** 6 s regressions x 100 builds x 10 devs = 1 h 40 min/day [S5]; track clean vs incremental p75/p95 (RocketSim Insights, Xcode Cloud analytics).
- **Fix:** **rec**.
- **Sources:** S5.

---
## Known conflicts and gaps (read before trusting numbers)
1. Explicit modules: Bitrise Xcode 16 beta-1 benchmark showed 1.7-43% slower clean builds [S20], while Apple makes them default in Xcode 26 and cache requires them [S8],[S19]; AvdLee still says "benchmark" [S2]. Trust: Apple release notes for defaults, Bitrise for historical perf; re-measure on Xcode 26+.
2. Compilation caching gains range 5-14% (AvdLee) to 19-77% (Tuist vendor benchmarks) with a "no change" CI report [S2],[S17],[S31]. Gains depend on SPM share; SPM deps not cacheable as of 26 beta [S19] (may have changed in later 26.x/27; unverified).
3. `DEAD_CODE_STRIPPING`: zld README (turn off in Debug) vs WWDC22 (usually pays for itself) [S11].
4. swift-syntax prebuilts: Xcode 26 notes say automatic [S8]; forums report some setups still build from source and iOS prebuilts missing [S23]. Verify per project.
5. Many percentage claims on "skill" pages (40-60% for compilation mode, 40-50% ONLY_ACTIVE_ARCH, 3-5 s dwarf) are unverified; not used as evidence here.
6. Xcode 27 facts (ld64 removal, unique module names) come from a personal blog quoting release notes [S33]; Apple's Xcode 27 notes were not retrievable.
7. Apple docs S6/S7 were read via JSON endpoint; S9 (build settings reference) was partially read (200k of 211k chars; keys `SWIFT_ENABLE_BATCH_MODE`, `VALIDATE_PRODUCT`, `USE_HEADERMAP`, `ENABLE_BITCODE`, `SWIFT_USE_INTEGRATED_DRIVER`, `CLANG_ENABLE_EXPLICIT_MODULES` descriptions not confirmed there).
8. No source found for: Codable/Equatable synthesis cost, extension placement, `lazy var` closures, Spotlight/Time Machine exclusion benefit, IDEIndexDisable impact, header-map settings numbers, `FUSE_BUILD_SCRIPT_PHASES` official docs, `-onlyUsePackageVersionsFromResolvedFile`. Tagged [K].
9. Swift forum "swiftrocks.com" posts (Bruno Rocha), Emerge/Noah Martin, Michael Eisel blog, Uber/Lyft/Airbnb posts were not retrievable (404 or not returned in search); not used.
10. Gojek (HTTP 403) and Spotify numbers are from search snippets only.

## Suggested CLI architecture notes
- Tier 1 auto-apply (safe, config-scoped): A1, A2, A3, A4 (Debug only), A5, A7 (Release), A9, A10, A11, A15 (unless XCRemoteCache), A29, A32 (if not distributed), C7 scheme flags, E1, F1, F2, G2, G3, G4.
- Tier 2 apply with benchmark gate (A/B timing before/after, auto-revert): A13, A16, A23, A25, A26, A28, C3, E8 URL fix, A12.
- Tier 3 recommend-only: all B*, C*, D* (except D2 scaffolding), E3-E7, E9-E11, F*, G1/G5-G8.
- Always measure: 3 clean + 3 incremental + 1 zero-change builds before/after (AvdLee method [S4]); compare `-showBuildTimingSummary` and `.xcactivitylog`.
