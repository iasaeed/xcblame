# v0.5 "Deep and Why" probes (MV-2, MV-6, MV-7, MV-8, MV-12, MV-16/17 cheap part)

Date: 2026-11-02. Host: macOS 27.0. Xcodes: 26.0.1 (17A400, default) and 27.1 beta (27A9269, `DEVELOPER_DIR=/Applications/Xcode-27.1-beta.app/Contents/Developer`).
Subject: a scratch copy of AcmeApp (macOS app + local package `LocalizeCore` + swift-syntax). The real repository was not touched.

Every build used the same harness (scratchpad `probe/xb.sh`):

```
xcodebuild -project AcmeApp.xcodeproj -scheme <AcmeApp|xcblame-AcmeApp> -configuration Debug \
  -destination platform=macOS,arch=arm64 -clonedSourcePackagesDirPath <scratch>/spm<26|27> \
  -derivedDataPath <scratch>/dd/<name> [-resultBundlePath <scratch>/results/<run>.xcresult] \
  CODE_SIGNING_ALLOWED=NO [extra settings] build
```

Raw outputs (stdout logs, DerivedData, result bundles, helper scripts `insp.py`, `bt.py`, `btsum.py`, `att.py`, `stats.py`, `incr.py`, `snap.py`) are in the session scratchpad `probe/` folder; they are not part of the repository. The fixtures listed per section are.

## Summary

| MV | Verdict | Mechanism / key fact |
|---|---|---|
| MV-2 | **Solved, both Xcodes.** | Env var `EnableBuildBacktraceRecording=YES` on the `xcodebuild` process works on 26.0.1 and 27.1. The defaults key `com.apple.dt.XCBuild EnableBuildBacktraceRecording` also works (26.0.1, tested). Scheme attribute `enableTaskBacktraces = "YES"` on `<BuildAction>` exists only in 27.1 (26.0.1 ignores it). A copied scheme is picked up only if its file name does not start with `.`. Frames land in SLF (attachment + emitted text), in the xcresult build log (attachment + emittedOutput) and in xcodebuild stdout. |
| MV-6 | **Verified, both Xcodes.** | One JSON per frontend job: `stats-<epochUsec>-swift-frontend-<Module>-<firstInput.swift\|all>-<triple_with_underscores>-<outputType>-<Onone…>-<number>.json`. Timers use the short form `time.swift.<phase>.<wall\|user\|sys\|instr>` plus one job total `time.swift-frontend.<jobname>.<suffix>`. |
| MV-7 | **Verified, both Xcodes; caveats.** | Trace is `<objdir>/<basename>.json` next to `<basename>.o`. Xcode puts `-ftime-trace` into a `*-common-args.resp` response file, so the CompileC command line in the log does not show it, and the `Time trace json-file dumped to` line is **never** printed. Explicit-module PCM builds produce no trace. With compilation caching, a cache hit produces no trace. |
| MV-8 | **Partial on 26, worse on 27.** | Remarks appear only in the `Planning Swift module X` section (SLF messages + emitted text, xcresult messages, category `Remark`). The post-compile remarks (`Queuing because of dependencies discovered later`, `Scheduling invalidated`) reach only xcodebuild stdout on 26.0.1 and appear nowhere on 27.1. |
| MV-12 | **Verified, both Xcodes; per-task replay IS visible.** | 26.0.1: legacy flat `{"clangCacheHits","clangCacheMisses","swiftCacheHits","swiftCacheMisses"}`. 27.1: `{"counters":{…},"taskCounters":{"<RuleName>":{"cacheHits"\|"cacheMisses":n}}}`, zero keys omitted. Every cacheable task's own output is the single line `Cache hit` or `Cache miss`. |
| MV-16/17 (cheap part) | **Differs by version.** | Without `-resultBundlePath`: 26.0.1 writes **no** `.xcactivitylog` (the manifest stays `logs = {}`); 27.1 writes one. On both versions, such a build also **deletes earlier logs of the same scheme** from `Logs/Build`. |

## MV-2: Task Backtraces without the GUI

### Where the switch lives (toolchain grep)

- 26.0.1: no IDE-side option. `SwiftBuild.framework` and the `SWBBuildService` bundle hold `recordBuildBacktraces` (an `SWBBuildRequest` property) and `enableBuildBacktraceRecording`. The string `EnableBuildBacktraceRecording` sits in `SWBCore` next to the other build-request feature flags (`EnableBuildSystemStaleFileRemoval`, `GeneratePrecompiledModulesReport`). `SWBUtil` contains the defaults domain string `com.apple.dt.XCBuild`. `grep enableTaskBacktraces` over `/Applications/Xcode.app/Contents/{Frameworks,PlugIns}` finds nothing, and `xcodebuild -help` has no backtrace option.
- 27.1: `IDEFoundation` adds `IDEBuildSchemeAction.enableTaskBacktraces` with `setEnableTaskBacktracesFromUTF8String:fromXMLUnarchiver:` (a scheme XML attribute, listed between `runPostActionsOnFailure` and `enableModulesReport`). `IDEKit` and `IDEXCBuildSupportCore` also reference it, and so does `SwiftPM.framework`.
- `defaults read com.apple.dt.Xcode | grep -i backtrace` finds only the unrelated `IDEAlwaysShowBacktraceInEditorUserDefaultsKey`. Before the test the `com.apple.dt.XCBuild` domain did not exist.

### Mechanisms tested (control: no flag gives 0 frames on both Xcodes)

| Mechanism | 26.0.1 | 27.1 | `build-request.json` |
|---|---|---|---|
| `EnableBuildBacktraceRecording=YES xcodebuild …` (env) | works | works | no `recordBuildBacktraces` key (the service-side feature flag is used) |
| `defaults write com.apple.dt.XCBuild EnableBuildBacktraceRecording -bool YES` | works (deleted again afterwards, plist removed) | not tested | no key |
| Scheme copy `xcshareddata/xcschemes/xcblame-AcmeApp.xcscheme` with `enableTaskBacktraces = "YES"` on `<BuildAction>`, built with `-scheme xcblame-AcmeApp` | ignored (0 frames) | works | `"recordBuildBacktraces": true`, which also creates a new build description (new signature) |
| Same copy named `.xcblame-AcmeApp.xcscheme` | not listed | `xcodebuild: error: The project named "AcmeApp" does not contain a scheme named ".xcblame-AcmeApp".` (exit 65); `-list` omits it | — |

**Side effect of toggling the mechanism.** The first build after switching (no flag to env var, env var to scheme copy) re-runs `CopySwiftLibs` and `ProcessInfoPlistFile` with `ruleSignatureChanged`, because their signatures include the environment or request. A second consecutive build with the same mechanism shows only the always-run `ClangStatCache` frame. So `why --backtraces` must use the same mechanism for the settle build and the measured build.

### Format in the SLF

The attachment is in the task's own section (`IDEFoundation.IDEActivityLogSectionAttachment`). Tokens: id string, int `1`, int `0` (type major/minor version 1.0, the same as the xcresult `typeMajorVersion`/`typeMinorVersion`), then a JSON (`*`) token holding an **array of frames**, one attachment per task:

```
cls IDEFoundation.IDEActivityLogSectionAttachment / str com.apple.dt.ActivityLogSectionAttachment.TaskBacktrace / int 1 / int 0 /
json [{"description":"signature of 'Copy Swift standard libraries into AcmeApp.app' changed",
       "identifier":{"storage":{"task":{"_0":[0,80,48,58,116,97,…]}}},
       "frameKind":{"genericTask":{}},"category":{"ruleSignatureChanged":{}}}]
```

Frame keys: always `category`, `description`, `frameKind`, `identifier`; chained frames add `previousFrameIdentifier`. Enum values are single-key objects (`{"ruleInputRebuilt":{}}`). JSON key order varies between frames.

- `identifier.storage.task._0` is a **byte array**. Decoded as UTF-8: `\0P0:target-AcmeApp-<guid>-:Debug:CopySwiftLibs <path>` for static tasks; `\0P2:target-…:Debug:<32-hex>`, `\0P0:target-…:Debug:<32-hex>` or `\0P2:::<32-hex>` for dynamic ones. The hex of a static task's bytes equals the section's `xcbuildSignature` slot (the slot is **uppercase** hex): 212/472 (clean), 26/54 and 17/45 (incrementals). Dynamic-task ids never match a slot (0/260), so attach frames to tasks **by containment** (the attachment is in the task's section), not by id.
- `identifier.storage.key._0` is a **string**: `<BuildKey.Node path=…>`, `<BuildKey.DirectoryTreeSignature path=…>` or `<BuildKey.DirectoryContents path=…>` (the only three seen).
- The emitted text of the same section also gets the frames as text, after any tool output: `…Ignoring --strip-bitcode because --sign was not passed\rBuild Backtrace:\rsignature of 'Copy Swift standard libraries into AcmeApp.app' changed\r`.

### Observed frames (category | frameKind | idKind | position | description template)

Incremental build, 26.0.1 (edit: new `public func` in `LocalizeCore/Models.swift` + comment in `AcmeApp/TableSelectionHeader.swift`; 54 attachments, 111 frames, chain lengths 1/2/4/6/7/8):

```
34 ruleNeverBuilt      | genericTask | task | first | '…' had never run
16 ruleInputRebuilt    | genericTask | task | first | an input of '…' changed                 (+previousFrameIdentifier)
15 ruleInputRebuilt    | file        | key  | chain | the producer of file '…' ran
15 ruleInputRebuilt    | genericTask | task | chain | an input of '…' changed
12 ruleHadInvalidValue | file        | key  | chain | file '…' changed                        (chain root)
 5 ruleInputRebuilt    | file        | key  | chain | an input of file '…' changed
 5 ruleInputRebuilt    | directory   | key  | chain | an input of signature of directory tree at '…' changed
 4 ruleHadInvalidValue | directory   | key  | chain | contents of '…' changed
 3 ruleHadInvalidValue | genericTask | task | first | '…' did not have up-to-date outputs
 1 ruleHadInvalidValue | genericTask | task | first | '…' is configured to run in every incremental build
 1 ruleInputRebuilt    | directory   | key  | chain | an input of contents of '…' changed
```

Clean build: `ruleNeverBuilt|genericTask` ×376 plus `dynamicTaskRequest|swiftDriverJob` ×96, `description: "task was scheduled by the Swift driver"`, with `previousFrameIdentifier` = the planning or emit-module task. Zero-change: `ClangStatCache` with `ruleHadInvalidValue` ("configured to run in every incremental build"). The first zero-change build after a clean build also re-runs 7 `CreateBuildDirectory` and `Write all-product-headers.yaml` tasks with "had never run" (26.0.1 only; not on 27.1). Not seen in these runs: `ruleForced`, `dynamicTaskRegistration`.

Real chain sample (26, `Link AcmeApp (arm64)`, 8 frames, root last):
`an input of 'Link AcmeApp (arm64)' changed` → … → `file '<P>/acmeapp/Sources/LocalizeCore/Models.swift' changed`.

**Per-file Swift compiles in an incremental build carry no reason**: `'Compiling Models.swift' had never run` (dynamic tasks are not in `build.db`). Their real cause is the frame of the parent `Compile LocalizeCore (arm64)` (`SwiftDriver Compilation …`) task: `an input of 'Compile LocalizeCore (arm64)' changed` → `file '…/Models.swift' changed`.

### 26.0.1 vs 27.1 differences (same categories and keys, different text)

| 26.0.1 | 27.1 |
|---|---|
| `signature of '…' changed` | `arguments, environment, working directory, or another component of the signature of '…' changed` |
| `'…' did not have up-to-date outputs` | `outputs of '…' were missing or modified` |
| `the producer of file '…' ran` | `the task producing file '…' ran` |
| `'…' is configured to run in every incremental build` | `'…' was configured to run in every incremental build` |
| file paths as `/tmp/…` | some file frames use `/private/tmp/…` (realpath) |
| package intermediates `LocalizeCore.build` | `LocalizeCore-t.build` |

### xcresult and stdout

`xcresulttool get log --type build` carries the same frames: `attachments: [{"uniformTypeIdentifier":"com.apple.dt.ActivityLogSectionAttachment.TaskBacktrace","typeMajorVersion":1,"typeMinorVersion":0,"data":"[{\"identifier\":…}]"}]` on the task subsection. Its `emittedOutput` ends with `"Build Backtrace:\nan input of 'Compile LocalizeCore (arm64)' changed\nfile '<P>/acmeapp/Sources/LocalizeCore/Diff.swift' changed\n"`. Plain stdout has the same `Build Backtrace:` blocks (9 in the 26 incremental).

### Implications for the parser

1. Decode the TaskBacktrace attachment of the task's section (JSON array). Use `category`/`frameKind` keys only: the text changes between 26 and 27. Decode `task._0` byte arrays to strings (strip the leading `\0`). Keep `key._0` strings as they are.
2. The root cause is the **last** frame of the chain. A chain ends in `ruleHadInvalidValue|file` ("file X changed"), `…|directory` ("contents of X changed"), `ruleSignatureChanged`, or `ruleNeverBuilt`. The first frame is the task itself.
3. For `SwiftCompile`/`SwiftEmitModule` dynamic tasks with `ruleNeverBuilt` in a non-clean build, inherit the cause from the module's `SwiftDriver Compilation` task frame in the same target. Do not count "had never run" as a primary cause there.
4. Treat `ClangStatCache` (always-run) and post-clean `CreateBuildDirectory` "never run" frames as noise.
5. Falls back to the `Build Backtrace:` text block in emittedOutput (xcresult/stdout) when only those are available. The text lines are the frame descriptions, first to root.
6. `why --backtraces` mechanism: prefer the **env var** (works on 26 and 27, needs no scheme copy and leaves no files). On 27.1+ the scheme copy is an option, named `xcblame-<name>.xcscheme`, not `.xcblame-…`. Run the settle build with the same mechanism. Update §6.6 (DESIGN), which proposes `.xcblame-<name>`.

Fixtures: `fixtures/logs/cli-xcode26-why/` and `fixtures/logs/cli-xcode27.1b-why/` (clean, zero-change and incremental logs with backtraces, `LogStoreManifest.plist`, `xcbuilddata/` snapshot, `xcresult-buildlog-inc.json.gz` of the incremental). Incrementals: 26 = `408C3D38-…`, 27.1 = `DC6A2EEF-…`. Current `xcblame analyze` decodes all of them with 0 warnings.

## MV-6: `-stats-output-dir`

Command: `'OTHER_SWIFT_FLAGS=$(inherited) -Xfrontend -stats-output-dir -Xfrontend <scratch>/stats26'` (the directory was created beforehand). Clean build, 105 files on each Xcode, about 850 KB in total.

- Filename: `stats-<µs since Unix epoch>-swift-frontend-<Module>-<input>-<triple, '-'→'_'>-<outputType>-<optLevel>-<number>.json`. Regex used (matched 105/105 on both): `^stats-(\d+)-(swift-frontend)-(.+?)-(all|.+?\.swift)-([a-z0-9_.]+)-([a-z]*)-(O[a-z]*)-(\d+)\.json$`.
  - `…-AcmeApp-StudioView.swift-arm64_apple_macos14.0-o-Onone-2835036085.json`: compile job (87, one per `SwiftCompile` task, named after its first primary file).
  - `…-AcmeApp-all-arm64_apple_macos14.0-swiftmodule-Onone-772671439.json`: emit-module job (9).
  - `…-AcmeApp-all-arm64_apple_macos14.0--Onone-3958402666.json`: empty output type, the dependency-scan job (9). It holds `AST.NumDepScanFilesystemLookups` and also `"Frontend.NumProcessFailures": 1` in a successful build, so do not read that counter as a failure.
  - No files for PCM, explicit-module or interface jobs, and no `swift-driver` files.
- Values are numbers only. Families: `Frontend.*`, `AST.*`, `Parse.*`, `Sema.*`, `SILModule.*`, `IRModule.*`, `LLVM.*`, `time.*`.
- Timers: **short form** `time.swift.<phase>.<wall|user|sys|instr>` (seconds; `instr` is an instruction count), e.g. `"time.swift.perform-sema.wall": 1.1659779548645020e+00`, `"time.swift.Type checking and Semantic analysis.wall"` (phase names contain spaces and commas, e.g. `time.swift.SIL verification, pre-optimization.wall`). Plus one job total: `"time.swift-frontend.AcmeApp-StudioView.swift-arm64_apple_macos14.0-o-Onone.wall": 2.3853335380554199e+00` (the job name without the `stats-<µs>-` prefix and `-<number>.json` suffix). Phases nest (`perform-sema` ≈ `Type checking and Semantic analysis`), so never sum phases.
- Counters, e.g. `"AST.NumSourceLines": 641`, `"Frontend.NumInstructionsExecuted": 27614768838`, `"Sema.NumConstraintScopes": 14793`.
- 26 vs 27.1 (union over all files): 27.1 adds timers `SIL-and-LLVM-processing`, `SIL-processing`, `SIL-mandatory-passes`, `load-storage-members`, `load-non-storage-members` (26 has `load-all-members`) and counters `Frontend.WallClockMicroseconds`, `Frontend.MaxMallocUsage`, `AST.NumMacroPluginDependencies`, `Sema.NumSolverBytesAllocated`, `Sema.MaxSolverBytesAllocated`. In 26: 137 distinct timer names; in 27.1: 141.

**Implications for the parser**: parse the filename with the regex above, and use the `time.swift-frontend.<job>.wall` key as the job span. Match the job to a log task by (module = target, first input file) for `o` jobs and (module, `swiftmodule`) for emit-module jobs. Rank phases by `time.swift.<phase>.wall` per job, picking a fixed set of top-level phases rather than summing, because of nesting. Key matching by "prefix `time.swift.` + last segment" works for both versions. The `[DS] §3` long form `time.swift-<jobkind>.<module>-<input>-…<timerkind>` exists only as the single job-total key.

Fixtures: `fixtures/deep/stats/xcode26/` and `fixtures/deep/stats/xcode27.1b/`: compile, emit-module and dep-scan job of the `AcmeApp` target, 0.6-11 KB each. They contain counters and module names only.

## MV-7: `-ftime-trace`

Command: `'OTHER_CFLAGS=$(inherited) -ftime-trace -ftime-trace-granularity=500'`. AcmeApp has no C/ObjC target of its own, but the swift-syntax package target `_SwiftSyntaxCShims` has one TU (`PlatformMutex.c`). Command-line settings reach package targets, so that TU is the probe.

- Location: `Build/Intermediates.noindex/swift-syntax.build/Debug/_SwiftSyntaxCShims.build/Objects-normal/arm64/PlatformMutex.json`, next to `PlatformMutex.o` (27.1: `_SwiftSyntaxCShims-t.build/…`). The name is the `.o` basename with `.json`.
- The flag is **not** on the CompileC command line in the log. Xcode moves it into `Objects-normal/arm64/<hash>-common-args.resp` (lines `-ftime-trace` and `'-ftime-trace-granularity=500'`). The log only shows `Using response file: …/7187679823f38a2a940e0043cdf9d637-common-args.resp`. The `ScanDependencies` builtin command line does contain it inline.
- `Time trace json-file dumped to` is **not printed** on either Xcode (0 hits in stdout, SLF and xcresult). Any parser keyed on that line (XCLogParser's approach) finds nothing.
- Explicit modules (default): 12 `PrecompileModule` plus 143 `SwiftExplicitDependencyGeneratePcm` tasks ran and none wrote a trace. Their command lines lack `-ftime-trace`, and `ExplicitPrecompiledModules/` holds only `.pcm/.d/.dia/.scan`. The TU trace does include `ReadAST`/`Module Load` events for the explicit PCMs it loads.
- Compilation caching (`COMPILATION_CACHE_ENABLE_CACHING=YES`, own CAS path): a cache **miss** writes the `.json`. A cache **hit** (second clean build) replays `.o/.d/.dia` and writes **no** `.json`.
- Trace shape: `{"traceEvents":[…],"beginningOfTime":…}`. Events `{"pid","tid","ts","ph":"X","dur","name","args":{"detail":…}}`, plus `ph` `b`/`e` (Source) and `M` (metadata). Summary events are named `Total <Name>` with `args: {"count": n, "avg ms": m}`, e.g. `Total ExecuteCompiler` dur 9313 µs (26) / 12010 µs (27). 26 has 50 events, 27.1 has 56; the names are the same apart from extra pass events.

**Implications for the parser**: do not rely on the log line. After the build, find traces by walking each executed `CompileC` task's output path (`.o` from the task title/command, replaced by `.json`), or glob `Objects-normal/*/*.json`, excluding `*-OutputFileMap.json`, `*-dependencies-*.json`, `*_const_extract_protocols.json` and `*.abi.json`. Aggregate the `Total *` events per TU. With caching on, mark TUs whose task output says `Cache hit` as "no trace (replayed)". `--deep` should state that PCM time is not covered by `-ftime-trace`. To see command-line flags, read the response file, since the log shows only `@`/`Using response file:`.

Fixtures: `fixtures/deep/ftime-trace/xcode26-PlatformMutex.json`, `xcode27.1b-PlatformMutex.json` (6-7 KB) and `xcode26-common-args.resp` (shows where the flag ends up).

## MV-8: `-driver-show-incremental`

Command: `'OTHER_SWIFT_FLAGS=$(inherited) -driver-show-incremental'` on a clean build, a zero-change build, a body-only edit (`StudioModel.swift` comment) and an interface edit (new `public func` in `LocalizeCore/Models.swift`).

Remark kinds per source, interface-edit build (counts):

| kind | 26 SLF msgs | 26 stdout | 26 xcresult | 27.1 SLF msgs | 27.1 stdout | 27.1 xcresult |
|---|---|---|---|---|---|---|
| Read dependency graph | 2 | 2 | 2 | 2 | 2 (as `note:`) | 2 |
| Scheduling changed input | 1 | 1 | 1 | 1 | 1 | 1 |
| Queuing (initial) | 7 | 7 | 7 | 7 | 7 | 7 |
| May skip current input / Skipping input | 25 / 19 | 25 / 19 | 25 / 19 | 25 / 19 | same | 25 / 19 |
| Traced | 6 | 22 | 6 | 6 | 6 | 6 |
| Invalidated externally / Newer / Integrating newer incremental import | 6 / 4 / 1 | same | same | 6 / 4 / 1 | same | same |
| Fingerprint missing for existing … | 64 | 490 | 64 | 66 | 66 | 66 |
| Reading dependencies from | 1 | 24 | 1 | 1 | 1 | 1 |
| **Queuing because of dependencies discovered later** | **0** | **16** | **0** | **0** | **0** | **0** |
| **Scheduling invalidated** | **0** | **16** | **0** | **0** | **0** | **0** |

- In SLF and xcresult the remarks are attached **only to the `Planning Swift module <X> (arm64)` section**: SLF `IDEActivityLogMessage` titles `Incremental compilation: …` (no `remark:` prefix), and the section's emitted text has lines `note: Incremental compilation: … (in target 'AcmeApp' from project 'AcmeApp' at path '…')`. In xcresult they are `messages` with `"category": "Remark"`. Remarks emitted later, during `SwiftDriverJobDiscovery` ("Discovering Swift tasks after 'Compiling Models.swift'"), are lost there.
- 26.0.1 stdout prints everything as `remark: Incremental compilation: …` lines (plus `note:` duplicates for some), including the discovery-time remarks.
- 27.1 stdout prints only the planning-time remarks, as `note: Incremental compilation: …`. The discovery-time remarks are gone everywhere, although the same 16 dependents were recompiled (25 `SwiftDriverJobDiscovery` steps).
- Real lines: `remark: Incremental compilation: Scheduling changed input  {compile: StudioModel.o <= StudioModel.swift}`; `remark: Incremental compilation: Queuing (initial):  {compile: StudioModel.o <= StudioModel.swift}`; `remark: Incremental compilation: Queuing because of dependencies discovered later:  {compile: Diff.o <= Diff.swift}` (26 stdout only); `remark: Incremental compilation: not scheduling dependents of StudioModel.swift; unknown changes`. Note the **two spaces** before `{compile:`.

**Implications for the parser**: use remarks only as low-precedence evidence (§6.6 step 7). From SLF/xcresult we get the initial scheduling (`Scheduling changed input`, `Queuing (initial)`, `Invalidated externally`, `Traced` chains). Cascades inside a module (`Queuing because of dependencies discovered later`) need the xcodebuild stdout capture on 26, and are not available on 27.1. Parse `{compile: <X>.o <= <X>.swift}` for the file. Strip the `note: `/`remark: ` prefix and the ` (in target …)` suffix. The flag changes `OTHER_SWIFT_FLAGS`, so it belongs to the `--deep`-style separate DerivedData, as already planned. Backtraces (MV-2) cover the same ground better: prefer them.

Fixtures: `fixtures/logs/cli-xcode26-incremental-remarks/` and `fixtures/logs/cli-xcode27.1b-incremental-remarks/` (clean, zero-change, body-edit and interface-edit logs + manifest), each with `xcodebuild-stdout-inc2-excerpt.txt` (stdout remark and task lines of the interface-edit build).

## MV-12: compilation-cache counters

Command: two builds in one DerivedData, first `build` then `clean build`, both with `COMPILATION_CACHE_ENABLE_CACHING=YES SWIFT_ENABLE_COMPILATION_CACHING=YES CLANG_ENABLE_COMPILE_CACHE=YES COMPILATION_CACHE_CAS_PATH=<scratch>/cas<26|27>`. The CAS grew to 330 MB. Clean build time went from 18 s to 5 s (26) and from 25 s to 6 s (27.1).

- `BuildOperationMetrics` attachment (type 1.0) on the **top-level build section**: in SLF near the `Build succeeded` section; in xcresult on subsection `Building project AcmeApp with scheme AcmeApp and configuration Debug`.
  - 26.0.1 (legacy flat shape, zeros present): miss build `{"clangCacheHits":0,"clangCacheMisses":13,"swiftCacheHits":0,"swiftCacheMisses":239}`; hit build `{"clangCacheHits":13,"clangCacheMisses":0,"swiftCacheHits":99,"swiftCacheMisses":0}`.
  - 27.1 (new shape, zero keys omitted): `{"counters":{"clangCacheMisses":14,"swiftCacheMisses":250},"taskCounters":{"CompileC":{"cacheMisses":1},"PrecompileModule":{"cacheMisses":13},"SwiftCompile":{"cacheMisses":87},"SwiftEmitModule":{"cacheMisses":9},"SwiftExplicitDependencyCompileModuleFromInterface":{"cacheMisses":5},"SwiftExplicitDependencyGeneratePcm":{"cacheMisses":149}}}`, and on the hit build `{"counters":{"clangCacheHits":14,"swiftCacheHits":99},"taskCounters":{"CompileC":{"cacheHits":1},"PrecompileModule":{"cacheHits":13},"SwiftCompile":{"cacheHits":87},"SwiftEmitModule":{"cacheHits":9},"SwiftExplicitDependencyGeneratePcm":{"cacheHits":3}}}`.
  - Without caching (all other runs) there is no `BuildOperationMetrics` attachment at all.
- Summary task: `Report compilation cache metrics` (stdout rule `CompilationCacheMetrics`) emits `note: 0 hits / 252 cacheable tasks (0%)` / `note: 112 hits / 112 cacheable tasks (100%)` (27.1: 264 / 113).
- **Per-task replay is visible.** The emitted output of every cacheable task (`Compiling Clang module X`, `Compiling X.swift`, `Emitting module for X`, `Compile PlatformMutex.c (arm64)`) is exactly `Cache miss` or `Cache hit` (SLF string `Cache hit\r`, xcresult `emittedOutput: "Cache hit\n"`). 26 counts: 252 misses, then 112 hits. These equal the metrics totals (13+239, 13+99).
- The hit build runs far fewer PCM tasks (26: 15 vs 155 `Compiling Clang module`), so the hit build's task set differs from the miss build's; counters are not per-same-task.
- No `CAS`/`replay` wording anywhere in the log.

**Implications for the parser**: support both metric shapes. Legacy: four flat keys. New: `counters` + `taskCounters[RuleInfo][cacheHits|cacheMisses]`, missing keys meaning 0. `cached` build kind = Σ hits > 0. Per-task "replayed" no longer needs the heuristic of §6.7: a task whose emitted output (trimmed) is `Cache hit` was replayed, and `Cache miss` was executed and stored. Correct DESIGN §5.6/§6.7 ("no per-task replay flag") and the [DS] note that the new shape starts at 26.4: 27.1 uses it, 26.0.1 uses the legacy one; versions in between were not tested.

Fixtures: `fixtures/logs/cli-xcode26-cache/` and `fixtures/logs/cli-xcode27.1b-cache/` (miss build, clean-action log, hit build, manifest, `xcbuilddata/` snapshot, `xcresult-buildlog-clean2.json.gz` of the hit build). Current `xcblame analyze` classifies the hit build as `clean` with 0 warnings; the `cached` kind is v0.5 work.

## MV-16 / MV-17 (cheap part): logs without `-resultBundlePath`

- 26.0.1, fresh DerivedData, `xcodebuild … build` without `-resultBundlePath`: build succeeded. `Logs/Build/` contains only `LogStoreManifest.plist` with `logs = {}`, so **no** `.xcactivitylog`. 27.1, same command: `Logs/Build/8FEA405F-….xcactivitylog` was written.
- On both versions, a build without `-resultBundlePath` in a DerivedData that already had logs **removed every earlier log of the same scheme**. 26: 7 `AcmeApp` logs → 0, only the `xcblame-AcmeApp` log left, no new log. 27.1: 4 `AcmeApp` logs → only the new one, with the `xcblame-AcmeApp` log kept. Builds with `-resultBundlePath` accumulate logs normally.
- Implication: `xcblame build` must keep passing `-resultBundlePath` on 26.x. CI `analyze` after a plain `xcodebuild build` finds no log on 26.0.1 and should say so with that hint. The log pruning means that a user's plain rebuild can delete the log that history references, so the snapshot/copy-on-capture design stays necessary. Previews/index arenas were not probed.

## Not done / blocked

- MV-17 previews and index builds: not probed (needs the IDE; see `ide-log-inventory.md`).
- The `com.apple.dt.XCBuild` defaults key was tested only on 26.0.1, from xcodebuild. Whether a GUI build in Xcode.app honours it (likely, since the same build service reads it) is unverified.
- Not seen: `ruleForced`, `dynamicTaskRegistration`. A failing build and a script phase with no outputs were not part of the runs.
