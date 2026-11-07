# How the Xcode build works and where the time goes (reference for a build-time analysis CLI)

Research date: 2026-10-30. Covers Xcode 15, 16, 26 and 27 (Xcode 27 / Swift 6.4 shipped 2026-09-14 per a third-party write-up; its release notes are on developer.apple.com).

Confidence tags: [P] primary (Apple docs/release notes, swift.org, swiftlang repos, WWDC); [S] secondary (engineering blog, forum report, vendor docs); [B] my background knowledge, not verified from a fetched source; [?] unverified or conflicting.

Dated sources (older than a year, on a fast-moving topic): WWDC18 notes, WWDC22 notes, Jesse Squires 2017, Allegro 2020, Spotify (~2018), fastred list, the swift.org Driver.md/CompilerPerformance.md pages. The structure they describe has held up. Specific numbers and defaults in them have not.

---

## 0. Executive summary of what matters for tool design

1. `xcodebuild`/Xcode are thin clients of a separate build-service process (`SWBBuildService`, the open-sourced "Swift Build"). It runs llbuild in-process. The pipeline is: project model (PIF) -> cached build description (planning) -> llbuild manifest -> task execution. Time is spent in planning, in task execution, and in dynamic tasks the compilers add during the build.
2. The Xcode 26 "planning" phase is now a measurable cost for large package graphs. It was reported at 60s to over an hour on large workspaces, with no Apple response in the thread.
3. Summed per-category times in `-showBuildTimingSummary` are CPU-task sums, not wall time. Rank by critical path and wall impact.
4. Swift per-file attribution is weak. In batch mode Xcode only times at batch granularity. The `-driver-time-compilation` flag silently prints nothing through Xcode's integrated driver. Reliable per-file or per-function data needs `-stats-output-dir` JSON, `-debug-time-*` frontend flags, or parsing `.xcactivitylog`.
5. The `.xcactivitylog` (SLF) format changes between Xcode versions (SLF v12 in Xcode 26.2+ per XCLogParser docs). A parser needs per-version handling.
6. Xcode 27 removed `ld64`/`-ld_classic`. Xcode 26 made explicit Swift modules the default. Compilation caching is opt-in, and in Xcode 27 it gains path prefix-mapping settings.

---

## 1. Pipeline end to end

### 1.1 Process model and lifecycle [P]

Source: Swift Build architecture doc, https://raw.githubusercontent.com/swiftlang/swift-build/main/SwiftBuild.docc/Architecture/build-system-architecture.md (also https://github.com/swiftlang/swift-build).

- A client (Xcode, SwiftPM, xcodebuild) starts one `SWBBuildService` process on demand. Messages go over a pipe. llbuild runs inside that service process and calls back into it for dynamic work and task actions.
- Lifecycle:
  1. The client sends the PIF (Project Interchange Format), a JSON project model. Objects are signed, and only objects the service lacks are transferred. PIF "changes rarely" by design. Source: https://raw.githubusercontent.com/swiftlang/swift-build/main/SwiftBuild.docc/Core/project-interchange-format.md
  2. A build request arrives with the workspace context (scheme, run destination, parameters).
  3. `BuildDescriptionManager` looks for a cached build description, in memory or on disk, keyed by the build inputs. If found, planning is skipped.
  4. On a miss, `ProductPlanner` makes a `ProductPlan` per target. `TaskProducer`s (roughly one per build phase) run in parallel, and a serial queue aggregates them into the `BuildPlan`.
  5. The `BuildPlan` becomes a `BuildDescription` plus a JSON llbuild manifest (a serialized dependency graph).
  6. llbuild executes the manifest. Task actions run in-process. Clang and Swift compilation request dynamic tasks mid-build.
- Tools are described by data-driven xcspec plists (Tool / Compiler / Linker specs, with `CommandLine` templates). Source: https://raw.githubusercontent.com/swiftlang/swift-build/main/SwiftBuild.docc/Core/xcspecs.md
- History: llbuild-based "new build system" became the default in Xcode 10 (WWDC18 session 415 notes: https://wwdcnotes.com/documentation/wwdc18-415-behind-the-scenes-of-the-xcode-build-process/). Swift Build was open-sourced in Feb 2025 (https://swift.org/blog/the-next-chapter-in-swift-build-technologies/). It is used by Xcode and as a preview SwiftPM backend (`--build-system swiftbuild`) per WWDC25 session 245 (https://developer.apple.com/videos/play/wwdc2025/245).
- Target specialization: at most one instance of a target per platform is built in a build. A consolidation prepass avoids extra specializations. Source: https://raw.githubusercontent.com/swiftlang/swift-build/main/SwiftBuild.docc/Core/target-specialization.md

Log-visible planning steps, seen in an Xcode 27 RC build log (Swift Package Index, 2026-09): `ComputePackagePrebuildTargetDependencyGraph`, `Prepare packages`, `CreateBuildRequest`, `SendProjectDescription`, `CreateBuildOperation`, `ComputeTargetDependencyGraph`, `GatherProvisioningInputs`, `CreateBuildDescription`. The log prints a "Build description signature" and an `XCBuildData/<hash>.xcbuilddata` path. Source: https://swiftpackageindex.com/builds/19940777-0921-4E8C-A2E7-D5CEC59265D8 [S]

### 1.2 Planning-phase costs

- Xcode 26 reports (Swift Forums, user reports through Feb 2026): "Compute target dependency graph for package preparation" is rebuilt every build with no caching. Per the reporters' reading of the swift-build source, the in-memory PIF cache has a 60s TTL, `.playground` files and non-deterministic `path:` target groups can change the PIF signature and invalidate the build description cache, and `SWBBuildService` used 12-15 GB RAM at about 2,100 targets. Reported times ran from about 1.6s (tiny) to 60-90s per no-op build (160 packages, 2,122 targets) to over an hour at 700 MB+ of PIF. No Apple reply is in the thread (FB22007592 is cited). [S] https://forums.swift.org/t/target-dependency-graph-computation-performance-too-slow/81552
- Package resolution ("Resolve Package Graph") is a separate pre-build step. Reports run 10-40s on small changes. CI usually caches `SourcePackages`. [S] https://forums.swift.org/t/xcodebuild-resolve-package-graph-is-very-slow/58622
- `GatherProvisioningInputs` in `xcodebuild` incremental builds took about 7s versus about 1s in the Xcode GUI through Xcode 16.x. The cause was network calls to developerservices2.apple.com, triggered even without `-allowProvisioningUpdates` when an Apple account was configured in Xcode. Reported fixed in Xcode 26 (it now contacts ocsp2.apple.com). User reports, with only a DTS "please test the latest" reply. [S] https://www.developer.apple.com/forums/thread/756120

### 1.3 Task catalog by stage

Task names verified from logs or docs are marked [P/S]. Others are [B].

| Stage | Task / tool | Notes |
|---|---|---|
| Prep | `SwiftDriver` / `SwiftDriver Compilation Requirements` / "Planning Swift module" | In-process swift-driver planning. See 1.4 and 2.1. [P] swift-driver.md |
| Dependency scan | built-in scan task (no process spawn), `SwiftExplicitDependencyGeneratePcm`, `PruneExplicitPrecompiledModules`, `ClangStatCache` | Explicit-modules era. [S] SPI Xcode 27 log; scan is a built-in task per WWDC24 10171 |
| Swift module emission | `SwiftEmitModule` | Dependents (and the debugger) need it. Often the incremental-build long pole in macro-heavy or large modules. [S] AvdLee skill |
| Swift compile | `SwiftCompile` (per-file `builtin-SwiftPerFileCompile`), formerly `CompileSwiftSources` | Per-batch. [S] |
| C/ObjC | `CompileC` | Allegro 2020 clean build: 49 tasks, 174s. [S] |
| Resources | `CompileAssetCatalog` (actool), `CompileStoryboard`/`CompileXIB` (ibtool), `DataModelCompile` (momc), Metal compile, App Intents metadata, `ProcessInfoPlistFile`, `CpResource`, string catalog compile | [B]. momc does a planning-time preflight to find its outputs. [P] architecture doc. actool single-image edit slow-recompile anecdote: https://developer.apple.com/forums/thread/86103 [S] |
| Scripts | `PhaseScriptExecution` | Serial by default, runs every build unless inputs/outputs are declared. See 1.5. [P] |
| Link | `Ld` / `Libtool` | One link task per product. Needs dependency products, or only a text stub (.tbd) with eager linking. |
| Debug info / post-link | `GenerateDSYMFile` (dsymutil), `Strip`, `SymbolStrip`, `CodeSign`, `Touch`, `ValidateEmbeddedBinary`, `Validate`, `RegisterExecutionPolicyException` | `strip`, `codesign` and `dsymutil` are in-place mutators with an enforced serial order (see 1.5). [P] mutable-outputs.md |
| Embed | `PBXCp` copy of frameworks, `CopySwiftLibs`, embed and sign | [B] and [P] (mergeable doc mentions `PBXCp -exclude_subpath`, `codesign --generate-pre-encrypt-hashes`) |

### 1.4 Swift in the build graph [P]

Source: https://raw.githubusercontent.com/swiftlang/swift-build/main/SwiftBuild.docc/Architecture/swift-driver.md and dynamic-tasks.md.

- The legacy integration ran `swiftc` as a subprocess. Both Swift Build and the driver parallelized, so process counts multiplied (about n x n). Swift Build also had to wait for `swiftc` to finish before it could use the module.
- The current integration calls swift-driver as a library (`libSwiftDriver`). It creates two planned tasks per target. `SwiftDriver Compilation` produces `.o` files (unblocks the linker). `SwiftDriver Compilation Requirements` produces only the module, in parallel (unblocks dependents sooner).
- A planned gate task declares source inputs and object outputs. It requests dynamic tasks: driver planning runs in-process, then each frontend job becomes a dynamic task (`SwiftDriverJobTaskAction`). The link waits for the gate.
- Swift Build hands Swift's incremental state to the driver. It always asks the driver which jobs to run. llbuild re-runs the gate task, and the driver then decides which frontends actually run.
- Compilation modes: WMO is one long-lived process. Single-file mode (a process per file) is no longer exposed in the Xcode UI. Batch mode (n processes for m files) is now called "incremental" and is the default.

### 1.5 What parallelizes and what serializes

From WWDC22 "Demystify parallelization in Xcode builds" (notes: https://wwdcnotes.com/documentation/wwdc22-110364-demystify-parallelization-in-xcode-builds/) [P/S] and Apple "Improving the speed of incremental builds" (https://developer.apple.com/documentation/xcode/improving-the-speed-of-incremental-builds.md) [P]:

- The graph is task-level (inputs and outputs). The critical path (longest dependent chain) sets the floor on build time. The Xcode build timeline (Xcode 14+) shows lanes (rows at a time = parallelism) and gaps (blocked downstream work).
- Target parallelism: "Parallelize Build" with Build Order = Dependency Order. Fewer or finer dependencies give more parallelism. A target that depends on many children cannot start until all finish. Monolithic frameworks cause over-rebuilding.
- Script phases: by default they run serially with respect to other tasks and run every build (see section 7). `FUSE_BUILD_SCRIPT_PHASES=YES` lets consecutive scripts run in parallel if inputs and outputs are complete. `ENABLE_USER_SCRIPT_SANDBOXING` enforces declared inputs and outputs. Apple WWDC25 lab: shell script phases (linters) are "the most common cause of extra build time". Source: https://developer.apple.com/forums/thread/791268
- Xcode 14 (Swift 5.7) eager module emission (emit-module separate from `.o` compile) and eager linking (link against a `.tbd` stub; needs Swift-only, dynamically linked dependency). Xcode 15 extended eager compilation to Archive builds and auto-generates `.tbd` stubs so changes that do not change exported symbols no longer relink transitive dependents. Source: https://developer.apple.com/documentation/xcode-release-notes/xcode-15-release-notes.md [P]
- Mutating tools (`strip`, `codesign`, `dsymutil` flows) run in a serial order enforced by gates. Directory outputs are unsupported, and rerun decisions for mutators cascade from the upstream command. Source: https://raw.githubusercontent.com/swiftlang/swift-build/main/SwiftBuild.docc/TaskConstruction/mutable-outputs.md [P]
- Linking is one task per product and mostly serial (Xcode 14's ld64 became about 2x faster by using more cores: https://wwdcnotes.com/documentation/wwdc22-110362-link-fast-improve-build-and-launch-times/ [S]).
- Mergeable libraries: release builds add `-make_mergeable` metadata and merge at link. Debug builds re-export (`-reexport_framework`) instead, and copy and re-sign the dependencies into a special directory. Source: https://raw.githubusercontent.com/swiftlang/swift-build/main/SwiftBuild.docc/TaskConstruction/mergeable-libraries.md [P]
- Timing quirk: Xcode's per-target build time attribution is task-sum based. Sum of categories exceeds wall time under parallelism [S] https://www.claudepluginhub.com/skills/avdlee-xcode-build-skills/xcode-compilation-analyzer
- Anecdote [S, single user, unresolved cause]: a 290-file app compiled in one serial batch and took 15 minutes. The thread first attributed it to `ENABLE_USER_SCRIPT_SANDBOXING`. The final finding was one ~5,000-line function that took 8-9 minutes to optimize, fixed with `@_optimize(none)`. https://developer.apple.com/forums/thread/816605. This shows the "typecheck-only" flags miss optimizer and LLVM time.

---

## 2. Swift compiler internals that affect time

### 2.1 Compilation model [P]

Source: https://github.com/swiftlang/swift/blob/main/docs/CompilerPerformance.md and docs/Driver.md.

- The driver runs frontend jobs. Primary-file mode (default): each frontend reads all module files but compiles only its primary files. Single-file mode with N files costs about N^2 parses (100 files means 10,000 parses). Batch mode (`-enable-batch-mode`): one frontend per CPU, so 400 parses on 4 CPUs.
- WMO (`-wmo`): one frontend, 100 parses, compiles serially, always rebuilds everything, and enables whole-module optimizations. WMO with `-Onone` is "rarely a good configuration". Xcode defaults are Debug = primary-file + `-Onone`, Release = WMO + `-O`.
- Phases: AST (parse, Sema, typecheck) is the same in all modes. SIL generation always runs. SIL optimization runs only with optimization. IRGen and LLVM always run. `-num-threads` affects only IRGen and LLVM. AST and SIL are single-threaded. In one sample profile about 66% of the time was in Sema, mostly deserializing external definitions.
- Problem areas the doc lists: over-approximate incremental dependencies (too many frontends rerun), too many non-primary definitions typechecked, expression constraint solving (super-linear or exponential), SIL optimizer analyses that fail to cache subproblems, and IRGen of some large value types.
- Xcode 15 fixed a case where "Swift modules with a very large number of extensions may experience slow build times" (109543968). Source: Xcode 15 release notes link above.

### 2.2 Type checker

- Apple guidance: explicit types, avoid complex one-line closures, avoid `AnyObject` delegates (forces broad lookup). https://developer.apple.com/documentation/xcode/improving-build-efficiency-with-good-coding-practices.md [P]
- Cause: overload disjunctions plus literal defaulting plus operators plus closures give an exponential search. Background: https://cocoawithlove.com/blog/2016/07/12/type-checker-issues.html (2016) [S], https://danielchasehooper.com/posts/why-swift-is-slow/ [S].
- Swift 6.4 (Xcode 27) adds disjunction pruning and better binding inference. Reported timings: `Array(1...5).filter.map.reduce` about 300 ms to about 4 ms. Several "too complex" cases are now instant. Not yet in diagnostic mode. A regression report exists (swiftlang/swift#90847). https://forums.swift.org/t/recent-improvements-to-the-type-checker/87048 [S, by compiler author]
- Frontend knobs [P] (FrontendOptions.td, https://raw.githubusercontent.com/swiftlang/swift/main/include/swift/Option/FrontendOptions.td): `-solver-expression-time-threshold=`, `-solver-memory-threshold=`, `-solver-scope-threshold=`.

### 2.3 Optimization

- `-Onone` vs `-O`: `-O` adds SIL optimization (single-threaded per frontend) and heavier LLVM. WMO with `-O` is typical for Release. `-cross-module-optimization` and `-enable-default-cmo` ("conservative cross-module optimization") are real flags [P] (Options.td, https://raw.githubusercontent.com/swiftlang/swift/main/include/swift/Option/Options.td). An Xcode 27 explicit-module log shows `-experimental-emit-module-separately -disable-cmo` on the driver line [S, SPI log]. I found no quantified build-time cost of CMO [?].
- `-experimental-skip-non-inlinable-function-bodies` exists ("Skip type-checking and SIL generation for non-inlinable function bodies") [P].

### 2.4 Incremental compilation and `.swiftdeps` [P unless noted]

Sources: https://github.com/swiftlang/swift/blob/main/docs/DependencyAnalysis.md, https://github.com/swiftlang/swift/blob/main/docs/Driver.md.

- Each file has provides and depends sets. A changed file invalidates files that depend on what it provides. Provides are computed after typechecking. Depends are recorded via instrumented lookups.
- Kinds: top-level (module-scope names), nominal (type use, extensions that change shape), member (specific member, plus an empty-name entry that covers "any non-private member added"), dynamic-lookup (`AnyObject` member access, `@objc`).
- External: imported Swift module files and Clang headers go in `depends-external`, and every file shares the same external list. Any external change rebuilds the whole module (so cross-module changes are coarse).
- Only frontend jobs are skippable. Module merge and link always run. The compiler knows a file changed, not what changed, so the driver may find mid-build that more files need compiling.
- Enabled via `-incremental` plus `swift-dependencies` entries in the output file map. WMO and incremental do not mix.
- The current swift-driver treats an external module as unchanged only if its mtime is before the previous build's start time (from the build record), per a bazel issue discussion [S]: https://github.com/bazelbuild/rules_swift/issues/1974. Downstream modules recompile all files when a dependency's `.swiftmodule` interface changes.
- Private stored-property changes alter the `.swiftmodule` (type layout, debugger needs, per-file merge). Function-body edits do not. That triggers downstream module rebuilds in Xcode and Bazel. Library evolution (ABI from `.swiftinterface` only) is a theoretical workaround, but same-package dependents and `@testable` need more. https://forums.swift.org/t/many-private-changes-cause-swiftmodule-to-change/80271 [S]
- Debugging flags: `-driver-show-incremental` ("With -v, dump information about why files are being rebuilt"), `-driver-show-job-lifecycle`. Remarks include "could not read build record" and "Reading dependencies from X.swiftdeps". Tip from that thread: wrap top-level types in an enclosing type or extension so the dependency system is more selective. https://forums.swift.org/t/optimizing-and-debugging-incremental-build-time-in-swift-5-5/49379 [S, 2021]
- Gap [?]: I could not retrieve a description of swift-driver's fine-grained (post Swift 5.4) dependency graph, the `.priors` file, or exact cascading rules. The repo doc above does not use "cascading". Consult swift-driver's `Sources/SwiftDriver/IncrementalCompilation` source.

### 2.5 Module interface and library evolution

- `BUILD_LIBRARY_FOR_DISTRIBUTION` = `-enable-library-evolution` + `-emit-module-interface` (`.swiftinterface`). Swift team guidance: do not use it for frameworks always built together with the app (https://swift.org/blog/library-evolution/ [P]). A quantified build cost was not found [?].

### 2.6 Explicit modules, swift-driver, scanner

- Implicit builds: an `import` triggers a filesystem search and possibly a sub-invocation building `.swiftinterface` or `.pcm`. Concurrent compilers race on locks, and the build system cannot see or schedule it. Explicit: a scanner (`libSwiftScan`) outputs a module graph, the driver turns it into explicit invocations, and the build system schedules module builds as tasks (`SwiftExplicitDependencyGeneratePcm` etc.). https://forums.swift.org/t/evolving-how-swift-is-built-driver-as-a-library-explicitly-built-modules-and-beyond/61102 [P, 2022]
- Xcode 15: opt-in Clang explicit modules (`_EXPERIMENTAL_CLANG_EXPLICIT_MODULES`). Xcode 16: all C/ObjC explicit by default; Swift via "Explicitly Built Modules" preview (`_EXPERIMENTAL_SWIFT_EXPLICIT_MODULES`); LLDB can reuse explicit modules (release note 84105971). Xcode 26: Swift explicit modules default for all Swift targets. Opt-out `SWIFT_ENABLE_EXPLICIT_MODULES=NO`. Stays off for Swift < 5 and for Swift/C++ interop targets (release notes 125244407, 146404229, 152118892): https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes.md [P]
- Cost model (WWDC24 10171): each source's compile splits into scan, module build, source build. Scan is a built-in task (no process spawn, shares cache between files). Clean builds also build modules. Module variants (distinct build-setting hashes: preprocessor macros, language mode, ARC) rebuild the same module repeatedly (UIKit 4 variants in the demo, reduced by removing one macro). Diagnose with "Build with Timing Summary" and the "Generate Clang modules report" entry. https://wwdcnotes.com/documentation/wwdc24-10171-demystify-explicitly-built-modules/ [S], https://developer.apple.com/videos/play/wwdc2024/10171/ [P]
- Measured early results were mixed: Xcode 16 beta 1/2, clean builds were slower with explicit Swift modules (Tuist 50.1s to 57.8s, BackyardBirds 21s to 30s, pocketcasts 119s to 121s; NetNewsWire 24.3s to 29.7s). Betas, M1-class, single runs. https://www.bitrise.io/blog/post/demystifying-explicitly-built-modules-for-xcode, https://useyourloaf.com/blog/xcode-explicitly-built-modules/ [S]
- Xcode 27 (Swift 6.4): dependency scanner optimized (less repeated setup and header lookup per scan action). As a consequence every Clang module reachable from one scan action must have a unique module name, or the scan may error (136303612). Typical triggers: vendored modulemaps redeclaring SDK modules, or the same module name on multiple header search paths. https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes.md [P]
- swift-driver replaced the legacy C++ driver as default (Swift 5.7, per forum post above). Early integrated-driver reports of slower incremental builds (55s vs 162s) exist [S, 2022].

### 2.7 Macros and swift-syntax

- Cost: swift-syntax must be built for the host. Reports: small app 12s to 23s (Debug, M1 Ultra), Release CI doubling from 15 to 30 minutes with a no-op macro, and Debug clean builds 44s to 338s for a heavy macro (expansion bloat plus swift-syntax). https://forums.swift.org/t/compilation-extremely-slow-since-macros-adoption/67921 [S, late 2023]
- Mitigation: SwiftPM prebuilts for swift-syntax. Swift 6.1.1 / Xcode 16.4 opt-in (`defaults write com.apple.dt.Xcode IDEPackageEnablePrebuilts YES`, or `swift build --enable-experimental-prebuilts`). Prebuilts are only for macro targets, built in release mode, and only for `swiftlang/swift-syntax` references. https://forums.swift.org/t/preview-swift-syntax-prebuilts-for-macros/80202 [P-ish, by the implementor]. Reported savings: Emit Swift Module penalty 40s to 16s, about 3 minutes on a Linux build, clean 180s to 120s on M4 Pro [S].
- Xcode 26: enabled automatically (release note 151701829). There is a known `_SwiftSyntaxCShims` failure with the workaround `IDEPackageEnablePrebuilts NO` (152253497). [P]
- Incremental cost: reports of macro re-expansion in "Emit Swift Module" slowing incremental builds (36s to 74s versus Xcode 16.4) with compilation caching on. https://forums.swift.org/t/about-swift-shared-cache-across-machines/81850 [S]

### 2.8 Swift 6 strict concurrency cost [?]

I found no measurement. Apple docs describe diagnostics volume, not build time (https://developer.apple.com/documentation/swift/adoptingswift6.md). One non-primary guide claims "complete" slows builds without numbers. In Swift 6 language mode, `SWIFT_STRICT_CONCURRENCY` is treated as complete regardless (forum reports). A tool should A/B `-strict-concurrency=minimal` vs `complete` with per-function type-check timings. Treat any claim as unverified.

---

## 3. Clang / ObjC side

- Modules and module maps: framework imports with the framework name (`<UIKit/UIKit.h>`) let Clang use module maps. It loads and processes headers once and caches the result on disk. Textual `#import "X.h"` bypasses that. `DEFINES_MODULE` enables a module map for your framework. Modules must be self-contained and context-free. Different compile options force a recompile of the module (a variant). Sources: Apple docs https://developer.apple.com/documentation/xcode/improving-the-speed-of-incremental-builds.md and https://developer.apple.com/documentation/xcode/improving-build-efficiency-with-good-coding-practices.md [P]
- Module cache is keyed by a hash of the `-fmodules` arguments (WWDC18) [S]. In Xcode 16+ with explicit modules the cache is replaced by explicit `.pcm` tasks. An Xcode 27 log shows `ModuleCache.noindex`, `SDKStatCaches.noindex`, `-fmodules-prune-interval=86400 -fmodules-prune-after=345600`, `-validate-clang-modules-once`, `-ivfsstatcache` [S].
- Header maps point Clang at project headers and can prepend framework names. Use framework-qualified imports for your own framework's headers. (WWDC18 [S])
- Bridging header and generated `-Swift.h`: smaller headers are faster. Apple: put only needed symbols in the bridging header, mark Swift members `private` to keep them out of the generated header, and prefer the latest Swift language mode (older modes infer more `@objc`). [P] https://developer.apple.com/documentation/xcode/improving-build-efficiency-with-good-coding-practices.md
- Bridging headers are chained via a generated `ChainedBridgingHeader.h`. The absolute path to the real bridging header made cache keys path-dependent (swiftlang/swift#84088). Settings: `SWIFT_ENABLE_PREFIX_MAPPING`, `CLANG_ENABLE_PREFIX_MAPPING`. [S] https://forums.swift.org/t/about-swift-shared-cache-across-machines/81850
- PCH: Apple's two fetched docs and WWDC24 10171 do not discuss PCH. I found no primary source on PCH behavior under explicit modules in Xcode 26/27 [?]. A Bitrise write-up lists PCH among cache settings but gives no detail [S].
- Dependency tracking: Clang emits a `.d` listing included headers, and the build system rebuilds sources when those change. Swift Build's "dependency info" format also exists (missing-input dependencies are not implemented, so a newly appearing header earlier in the search path is not caught). https://raw.githubusercontent.com/swiftlang/swift-build/main/SwiftBuild.docc/TaskConstruction/discovered-dependencies.md [P]
- Clang time analysis: `-ftime-trace` (Chrome-trace JSON next to the output unless a path is given; `-ftime-trace-granularity` default 500 us; `-ftime-trace-verbose`), `-fproc-stat-report` and `CC_PRINT_PROC_STAT[_FILE]`. https://clang.llvm.org/docs/UsersManual.html [P]. In Xcode, pass via `OTHER_CFLAGS`/`OTHER_CPLUSPLUSFLAGS` (WebKit uses this: https://github.com/WebKit/WebKit/wiki/Analyzing-Build-Performance [S]). Aggregate with ClangBuildAnalyzer (https://github.com/aras-p/ClangBuildAnalyzer). Confirmation that the flag works for `.m` files with explicit modules and caching was not found [?].
- Estimated time shares from one blog (header parsing about 40%, codegen 30%, link 20%) are the author's estimates, not measurements: https://wywwwwei.github.io/2025/05/01/ios-build-optimization/ [weak S].

---

## 4. Linking

- Static vs dynamic (WWDC22 "Link fast"): static linking costs build time and size. Dynamic costs launch time. Selective loading pulls `.o` from archives only for undefined symbols. `-all_load`/`-force_load` allow parallel archive parsing but can create duplicate symbols (pair with `-dead_strip`). `-no_exported_symbols` skips the exports trie. `-no_deduplicate` skips costly merging (Xcode already uses it for Debug). https://wwdcnotes.com/documentation/wwdc22-110362-link-fast-improve-build-and-launch-times/ [S]
- Mergeable libraries (WWDC23, Xcode 15): dynamic-library build speed, static-like launch. `MERGED_BINARY_TYPE` = automatic/manual, `MERGEABLE_LIBRARY`. Debug re-exports. Release merges (metadata roughly doubles the dylib size). https://wwdcnotes.com/documentation/wwdc23-10268-meet-mergeable-libraries/ [S] and Swift Build doc in 1.5 [P].
- New linker (ld_prime): Xcode 15 "A new linker has been written to significantly speed up static linking," default for macOS/iOS/tvOS/visionOS and for mergeable libraries. Classic `-ld64`/`-ld_classic` stayed until removed (release notes). No numbers were given. [P] https://developer.apple.com/forums/thread/736203 (quotes the Xcode 15 notes; the notes themselves: https://developer.apple.com/documentation/xcode-release-notes/xcode-15-release-notes.md). Xcode 16: new code-dedup algorithm improves link time (enabled in release builds), `-ld_classic` deprecated (125995452, 128502299). Xcode 27: "The ld64 linker has been removed and the `-ld_classic` option is no longer supported" (165165518). https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes.md [P]
- Independent benchmark: Chromium says ld-prime is faster than LLD for local arm64 macOS development ("up to 4-6x" depending on config), but only for local, non-cross, non-ThinLTO builds. https://chromium.googlesource.com/chromium/src.git/+/main/docs/apple_platform_linkers.md [S]
- Known ld_prime behavior changes: stricter duplicate-symbol errors with `-ObjC`/`-force_load` (https://developer.apple.com/forums/thread/739396), duplicate-library warnings by default, LTO issues. [S]
- LTO: Spotify found a static library built with `-O4` (LTO) made link slow. `linkTimeOptimize()` was 51.3% of link time. Dropping to `-O3` cut link time about 51%. Old (~2018) ld64 profiling, direction still relevant. https://engineering.atspotify.com/shaving-off-time-from-the-ios-edit-build-test-cycle/ [S]
- dSYM: that post measured dSYM generation at about 25 s of an 82 s cycle (~2,000 objects). Switching Debug to DWARF (no dSYM) saved about 25 s. `dsymutil` exists because ld ignores debug info during incremental builds (https://jonasdevlieghere.com/dsymutil-statistics [S]). Xcode 16: DWARF 5 is the default debug-info format for macOS 15/iOS 18+ targets (release note 110925733). [P]
- Linker stats: `-Xlinker -print_statistics` is named in XCLogParser's README. I could not verify its output format or that ld_prime supports it [?].
- Reports that `Ld` runs even with no code change (30 s): https://developer.apple.com/forums/thread/126212 [S]. Xcode 15 added dependency tracking for files referenced by `OTHER_LDFLAGS` (92049062), which can cause relinks if flags point at non-SDK-relative paths.

---

## 5. Xcode 26 and newer build features

### 5.1 Compilation caching

- Xcode 26: opt-in; "Enable Compilation Caching" (`COMPILATION_CACHE_ENABLE_CACHING`), covers Swift and C-family, helps most on branch switches and clean builds. Fixed to work with Previews. https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes.md [P]. Group-lab confirmation (local, Swift + Clang): https://developer.apple.com/forums/thread/791268
- Mechanism (LLVM CAS): per-task cache keys computed after dependency scanning from sources, command line and imported modules. Outputs stored by hash, key to hash mapping. Store defaults to `DerivedData/CompilationCache.noindex`. `clean` does not remove it. A remote cache plugs in through a gRPC service. Settings seen: `COMPILATION_CACHE_ENABLE_PLUGIN`, `COMPILATION_CACHE_REMOTE_SERVICE_PATH`, `SWIFT_ENABLE_COMPILE_CACHE`, `CLANG_ENABLE_COMPILE_CACHE`, `SWIFT_ENABLE_EXPLICIT_MODULES`, `SWIFT_USE_INTEGRATED_DRIVER`, `COMPILATION_CACHE_CAS_PATH`, `COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS` (hit/miss remarks). https://bitrise.io/blog/post/lifting-the-hood-on-build-cache-for-xcode, https://tuist.dev/en/docs/guides/features/cache/xcode-cache, https://forums.swift.org/t/pitch-compilation-caching-support-in-swiftpm/88079 [S]
- Limits: local only by default. Path-sensitive keys (absolute paths, bridging header) until prefix mapping. Macros can produce false misses. Not all tasks cacheable (Tuist, Xcode 26.0.1; SwiftPM package targets not cacheable in Xcode 26 per Xcode 27 reports [?]). If DerivedData already has outputs, Xcode uses local files and skips the cache query (0% remote hit). Cache growth with no built-in cap was reported in Xcode 26 [S].
- Xcode 27: `COMPILATION_CACHE_LIMIT_SIZE`, `COMPILATION_CACHE_CAS_PATH`, and prefix-mapping settings (`SWIFT_ENABLE_PREFIX_MAPPING`, `SWIFT_ENABLE_PROJECT_PREFIX_MAPPING`, `CLANG_ENABLE_PREFIX_MAPPING`, `CLANG_ENABLE_PROJECT_PREFIX_MAPPING`). With prefix mapping, keys are independent of project and DerivedData location. Changing these settings invalidates all keys. Sources are Tuist docs and GitHub issues, not Apple notes. I could not find these in the Xcode 27 release notes. [S] https://tuist.dev/en/docs/guides/features/cache/xcode-cache, https://github.com/Spoken-Margins/spoken-margins-native/issues/1331, https://github.com/vmihalachi/laching/issues/151
- Reported numbers (each anecdotal): Tuist, Wikipedia clean build 24% faster with a local cache, Tuist CLI 77% [S, https://canary.tuist.dev/blog/2025/10/22/xcode-cache]. Bitrise 19-55% [S]. Forum: 170s to 61s once seeded. An Xcode 27.0 single-project probe: 194.97s cold, 34.36s rebuilt with caches hit 244/244 cacheable tasks (secondhand from a search summary of https://github.com/nickysemenza/cubby/pull/1742; not fetched). Contrary: a Dec 2025 note recorded clean builds 49-75s vs 35-37s baseline (Peekaboo; not confirmed, page not retrievable). First build pays a bootstrap cost.
- Hit rate caveat: the Bitrise sample log shows a lookup of 135 ms for a hit. Latency to a remote cache can dominate for small tasks.
- SwiftPM pitch (Swift forums, 2026): `--enable-build-caching`, prefix mapping on by default with caching, size limit, diagnostic remarks; reported clean debug 67-75% faster on SwiftPM, SwiftSyntax, Vapor with a 12-core machine. https://forums.swift.org/t/pitch-compilation-caching-support-in-swiftpm/88079 [P-ish pitch]

### 5.2 Other Xcode 26/27 items

- Explicit Swift modules default (Xcode 26) and scanner speedups (Xcode 27), see 2.6.
- swift-syntax prebuilts automatic (Xcode 26), see 2.7.
- Swift Build open source and SwiftPM preview backend (WWDC25 session 245, https://developer.apple.com/videos/play/wwdc2025/245).
- Xcode 26 fixes: synchronized group folders had non-deterministic file order causing unnecessary rebuilds (151472630); a compile failure with compiler caching on (153298732). https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes.md
- WWDC26: Apple's "What's new in Xcode 27" (session 258) page contains nothing on build performance. https://developer.apple.com/videos/play/wwdc2026/258/ . I did not find a dedicated WWDC26 build-performance session. A SwiftUI-related build-time improvement ("ContentBuilder") is mentioned on https://developer.apple.com/wwdc26/guides/swiftui/ [S, from search summary]. "Enhanced build timeline" in Xcode 26/27: no Apple source found [?].
- Xcode 27 release notes also: ld64 removed (Linking), Swift dependency scanner optimization (Swift Compiler). No other Build System section appeared in that notes file when I searched headings.

---

## 6. Diagnostics

| Mechanism | What it prints and where | Caveats and versions |
|---|---|---|
| `xcodebuild -showBuildTimingSummary` / Product > Perform Action > Build with Timing Summary | After the build: "Build Timing Summary" with lines `Category (N tasks) | X.XXX seconds`, then `** BUILD SUCCEEDED ** [N sec]`. Example (warm build): `PhaseScriptExecution (6 tasks) | 23.350 seconds`, `ValidateEmbeddedBinary (2 tasks) | 2.424 seconds`. Clean examples show `CompileC`, `CompileSwiftSources`, `CompileStoryboard`. Also hosts the "Generate Clang modules report" entry (and a Swift modules report). Newer category names include `SwiftEmitModule` and "Planning Swift module". | Sums parallel tasks, so total exceeds wall time. Incremental builds show only executed tasks. Apple documents it at https://developer.apple.com/documentation/xcode/improving-the-speed-of-incremental-builds.md [P]. Example format: https://blog.allegro.tech/2020/12/speeding-up-warm-builds.html [S, 2020]. The Allegro post said the menu version failed in Xcode 12.2. |
| Build timeline | Report navigator > build log > assistant editor. Rows = parallelism, gaps = blocked work, colors per target. Xcode 14+. https://wwdcnotes.com/documentation/wwdc22-110364-demystify-parallelization-in-xcode-builds/ [S] | UI only. Underlying data are the `.xcactivitylog` sections. No Xcode 26/27 change found [?]. |
| `ShowBuildOperationDuration` | `defaults write com.apple.dt.Xcode ShowBuildOperationDuration -bool YES` shows build duration in the activity bar. [S] https://github.com/fastred/Optimizing-Swift-Build-Times | Whether this is on by default in recent Xcode: unverified [?]. |
| `.xcactivitylog` (SLF) | Gzip'd SLF0 stream under `DerivedData/.../Logs/Build`. Section timestamps are doubles (reference-date seconds, little-endian). Per-task metrics (`wcStartTime`, `wcDuration`, `utime`, `stime`) live in `TaskMetrics` attachments. `xcodebuild` writes it only with `-resultBundlePath` (per XCLogParser). XCLogParser reporters: json, flatJson, summaryJson, chromeTracer, issues, html, and `swiftFunctionTimes`/`swiftTypeCheckTimes` when the debug-time flags were used. https://github.com/spotify/XCLogParser/blob/master/docs/Xcactivitylog%20Format.md, https://www.github.com/MobileNativeFoundation/XCLogParser [S] | Format versioned. SLF v11 adds attachments, v12 (Xcode 26.2+) adds an extra integer. XCLogParser lists Xcode 16.4 as its tested version and calls itself alpha. |
| `-Xfrontend -debug-time-function-bodies` | Per-function typecheck time, sorted: `<ms> <file>:<line>:<col> <signature>`. Flag exists in current FrontendOptions.td ("Dumps the time it takes to type-check each function body") [P]. | Typecheck only. With multiple frontends the output interleaves across jobs. Appears in the build log under the compile task. |
| `-Xfrontend -debug-time-expression-type-checking` | Same, per expression. Present in FrontendOptions.td [P]. | Typecheck only. |
| `-Xfrontend -warn-long-function-bodies=N`, `-warn-long-expression-type-checking=N` | Warnings (Xcode issues) when over N ms. Present in FrontendOptions.td ("Warns when type-checking a function takes longer than <n> ms") [P]. | Described as experimental/unsupported (2017 blog, https://www.jessesquires.com/blog/2017/09/18/measuring-compile-times-xcode9/ [S]). Very low N gives unfixable noise. |
| `-driver-time-compilation` | In theory a table of user/system/wall per job. [P] CompilerPerformance.md. | In Xcode 13.3.1 (Swift 5.6) it printed nothing. A reply said the swift-driver flag appears to do nothing (PR swift-driver #262 closed). https://forums.swift.org/t/driver-time-compilation-flag-in-xcode-13-3-1/56884 [S]. I did not test it with Xcode 26's driver-as-library. Treat as unreliable [?]. |
| `-Xfrontend -stats-output-dir <dir>` | One JSON file per frontend job (names like `stats-...-swift-frontend-<module>-<file>.swift-<triple>-o-Onone-....json`) with counters and timers, e.g. `AST.NumSourceLines`, `time.swift.Parsing.wall`. Works via `OTHER_SWIFT_FLAGS=-stats-output-dir .stats` in Xcode builds (SPI logs). `utils/process-stats-dir.py` aggregates and compares. [P] CompilerPerformance.md; format evidence [S] SPI logs | Directory must exist and be writable (otherwise "Error opening -stats-output-dir file"). Pestov noted the "LLVM pipeline.wall" timer had been accidentally removed and he would restore it (2022) [S]. Per-function timers are not included. |
| `-trace-stats-events` (with stats-output-dir) | Experimental CSV trace: `Time, Live, IsEntry, EventName, CounterName, CounterDelta, CounterValue, EntityName, EntityRange`. | Very verbose. |
| `-Xfrontend -debug-time-compilation` | Used by older guides (fastred) and a 2026 skill (AvdLee) to rank slow files. | Not found in FrontendOptions.td on main [?]. Probably gone or moved. Prefer `-stats-output-dir`. |
| `-driver-show-incremental`, `-driver-show-job-lifecycle` | Remarks on why jobs were or were not scheduled. | Xcode may filter the remarks. A workaround (`defaults write com.apple.dt.XCBuild EnableSwiftBuildSystemIntegration 0`, Swift 5.5 era) is from the 2021 thread above. Status in Xcode 26 unverified [?]. |
| `COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=YES` | Cache hit/miss remarks in the build log. [S] Tuist docs. | Xcode 26+. |
| Clang `-ftime-trace`, `-fproc-stat-report` | See section 3. | |
| Linker `-Xlinker -print_statistics` | Named in XCLogParser README [S]. | Output and ld_prime support unverified [?]. |
| llbuild build debugging | `build.trace` under `Build/Intermediates.noindex/XCBuildData/buildDebugging-*`, `build.db` (SQLite), manifest `.xcbuild`. https://gist.github.com/lalunamel/716de8bb16cbf1d942324fc2120931ee [weak S, ~Xcode 12.3] | Slows the build. Not verified for Xcode 26. |
| `swbuild` and `SWBBuildService` | Swift Build ships a `swbuild` CLI. The service can be attached to for debugging. https://github.com/swiftlang/swift-build [P] | Not a timing tool. |

Batch mode notes: In batch mode Xcode's per-file timing is only granular to the batch (Shier, forum above). `-disable-batch-mode` gave per-file timings but changes the build shape. A Swift Package Index-style `OTHER_SWIFT_FLAGS` string combination is the most reproducible setup.

---

## 7. Incremental vs clean: why incremental degrades

Mechanism: llbuild reruns a task when its signature changes (hash of input stat info, paths, command line, task metadata such as compiler version) or when its discovered dependencies (`.d`) change (WWDC18 notes: https://wwdcnotes.com/documentation/wwdc18-415-behind-the-scenes-of-the-xcode-build-process/ [S]). For Swift, the driver then makes its own decision (2.4).

Common causes:

1. Run Script phases with no declared inputs or no outputs run every build, and are serialized. Apple lists the four run conditions: no inputs, no outputs, inputs changed, outputs missing. You must declare at least one input and one output. "Based on dependency analysis" must also be set. Allegro cut a warm build from 27.2s to 7.5s this way. https://developer.apple.com/documentation/xcode/improving-the-speed-of-incremental-builds.md [P], https://blog.allegro.tech/2020/12/speeding-up-warm-builds.html [S].
2. Scripts or tools that rewrite files other tasks consume (generated sources, plists, xcconfig-derived settings). An Apple Forums report ties a script touching an xcconfig for a CocoaPods dependency to recompiling every build [S, https://developer.apple.com/forums/thread/787964]. A claim that touching `Info.plist` forces a rebuild: I found no source [?].
3. Build-setting or command-line changes. Any change to the compile command changes the task signature. A per-target macro or language-setting difference also creates a new module variant (WWDC24 10171).
4. Swift dependency fan-out (2.4): changes to widely used types or protocols, many extensions, member additions on a type with many dependents (the empty-member entry). The 2025 blog case study reports one public protocol change forcing near-total recompile [weak S].
5. Cross-module cascades: a `.swiftmodule` change (including private stored properties) recompiles all files of every dependent module in the project. Clang `-fmodules` or umbrella-header changes behave similarly. Large monolithic frameworks make this worse (Apple doc).
6. Xcode 15 TBD stubs reduce relinks when exports do not change. Without them, a changed dependency relinks transitive dependents.
7. Macros: `SwiftEmitModule` re-expansion on incremental builds (36s to 74s report, 2.7).
8. Planning-phase overhead on zero-change builds (1.2), and PIF signature instability (playground files, non-deterministic `path:` groups) invalidating the cached build description.
9. Non-deterministic inputs: Xcode 26 fixed synchronized-group file order causing unnecessary rebuilds (release note 151472630).
10. Link-time cost that persists on no-op builds: `Ld` and dSYM with many objects (Spotify, Apple forum above).
11. Toolchain or environment: Xcode or SDK version change invalidates descriptions and module caches [B]. CI with a fresh checkout, ephemeral DerivedData, or different workspace path loses reuse. A fresh checkout giving new mtimes is the usual explanation, but it was an unconfirmed reply summary and not verified in the thread itself. Path differences matter for compilation cache keys without prefix mapping (see 5.1). `clean` does not delete the compilation cache. Deleting DerivedData does delete the default store.
12. Network-dependent steps (provisioning) in `xcodebuild` (1.2).

DerivedData invalidation causes beyond those above (explicit module cache invalidation, build.db corruption) were not found in primary sources [?].

---

## 8. Implications for a build-time CLI (design notes, brief)

- Wall time vs summed task time: compute the critical path from timestamps (start and end per task from the `.xcactivitylog` sections or a timeline export), not just per-category sums.
- Distinguish planning, scan/module, compile, link, post-link, scripts. Use task-name prefixes. Task names have changed (`CompileSwiftSources` to `SwiftCompile`, plus `SwiftDriver`, `SwiftEmitModule`, `SwiftExplicitDependencyGeneratePcm`), so keep the mapping version-aware.
- Expect Swift per-file times to be batch-attributed. For file or function accuracy, offer an opt-in re-run with `-stats-output-dir` and `-debug-time-function-bodies`, merging results.
- Detect scripts without inputs/outputs from the project and from the log (PhaseScriptExecution appearing in incremental builds).
- Detect module variants from the "Clang/Swift modules report" in the timing summary.
- Flag compilation-cache state (setting on, hit/miss remarks) and cache-key path sensitivity.

---

## 9. Sources read (distinct, 30+)

Apple/primary: Xcode 15/16/26/27 release notes; improving-the-speed-of-incremental-builds; improving-build-efficiency-with-good-coding-practices; WWDC24 10171; WWDC26 258; WWDC25 245 (search summary only); swift-build docs (architecture, swift-driver, dynamic-tasks, discovered-dependencies, mergeable-libraries, mutable-outputs, target-specialization, PIF, xcspecs); swift repo docs (Driver, DependencyAnalysis, CompilerPerformance); Options.td and FrontendOptions.td; swift.org Swift Build blog; Clang UsersManual; Swift Forums (explicit modules, prebuilts, shared cache, type checker, incremental debugging, private-change swiftmodule, target graph, pitch for SwiftPM caching, macros); Apple Developer Forums (756120, 816605, 791268, 736203).
Secondary: wwdcnotes (WWDC18 415, WWDC22 110364 and 110362, WWDC23 10268, WWDC24 10171); Bitrise (lifting the hood, demystifying); Tuist docs and blog; Use Your Loaf; Allegro; Spotify; Jesse Squires; fastred; XCLogParser; Chromium linker doc; SPI build logs; wywwwwei blog; AvdLee skills; Cocoa with Love.

## 10. Failures and gaps

- tuist.dev blog (HTTP 403), medium.com/dimillian (403), swift-driver Documentation/Design.md (404), the LLVM Rastogi PDF (binary, unread), the Peekaboo performance doc (only a directory page). Skipped after one attempt each.
- Unverified: ShowBuildOperationDuration default state; Xcode 26/27 timeline changes; PCH under explicit modules; swift-driver fine-grained dependency details; strict concurrency build cost; `-driver-time-compilation` under the Xcode 26 integrated driver; `-Xfrontend -debug-time-compilation` current status; ld_prime `-print_statistics`; Info.plist-touch invalidation; quantified CMO and library-evolution costs; the Cubby/Xcode 27 numbers (secondhand).
- Conflicts: (a) Swift explicit modules in Xcode 26: Apple notes say default-on, a Dec 2025 third-party note (Peekaboo, beta era) said caching needed explicit modules and flags were missing. Trust the Apple notes. (b) Compilation caching speedups range from -40% (slower) to +77%. These are single-project anecdotes, and the SwiftPM pitch's 67-75% is for SwiftPM packages themselves. (c) Early explicit-module benchmarks showed slowdowns on betas. The Apple claim is better scheduling, and I found no stable release-era benchmark.
