# Data sources for measuring/analyzing an Xcode build and reading/modifying project config

Research date: 2026-10-30. Covers Xcode 15, 16, 26, 27. Local machine at research time: Xcode 26.0.1 (17A400), macOS 27 beta.
Legend: [V] = verified in a fetched primary or near-primary source (URL given). [S] = secondary/third-party. [U] = unverified / from general knowledge / could not confirm.
No code was run (no shell available in this session); format claims come from sources, plus a few local file reads noted as [LOCAL].

---------------------------------------------------------------------
## 0. TL;DR matrix (what actually works on Xcode 16 / 26 / 27)

| Need | Reliable source | Notes |
|---|---|---|
| Per-target wall time, per-task wall time | .xcactivitylog (SLF) | Section start/end doubles; per-task TaskMetrics attachment (wcStartTime/wcDuration/utime/stime/maxRSS) in log version >= 11 |
| "Why did this task re-run" | .xcactivitylog attachment `TaskBacktrace` (ruleSignatureChanged, ruleInputRebuilt, ruleNeverBuilt, ...) | New in late-2025 Xcodes (XCLogParser fix in v0.2.43, 2025-11-21) |
| Per-FILE Swift compile time | Not reliable from activity log | In batch mode every file in a batch reports the batch's full span (XCLogParser PR #256). Use `-warn-long-*` / `-debug-time-function-bodies` (per function/expr), or `-stats-output-dir` (per frontend job), or disable batch mode |
| Per-function / per-expression type-check cost | `-Xfrontend -debug-time-function-bodies`, `-debug-time-expression-type-checking`, `-warn-long-function-bodies=N`, `-warn-long-expression-type-checking=N` | All four still defined in swift main Options.td; still used in 2025-26 tooling |
| Phase totals (SwiftCompile, Ld, CompileC, SwiftEmitModule...) | `xcodebuild -showBuildTimingSummary` (or activity log) | Text, aggregated per task name; not per file |
| Why files rebuild (Swift incremental) | `-driver-show-incremental` (+ `-driver-show-job-lifecycle`) | Remarks may be hidden by Xcode's build-system integration; see sec. 3 |
| C/ObjC per-TU cost | `-ftime-trace` (JSON per TU) | Path printed in log: "Time trace json-file dumped to ..." |
| Linker detail | `-Xlinker -print_statistics` was ld64-only; ld64 REMOVED in Xcode 27 | ld_prime support unverified |
| Project model | pbxproj (OpenStep plist) or, NEW in Xcode 27.2, `project.xcproj` JSON | Parsers must handle both |

DEAD or doubtful flags:
- `-Xfrontend -debug-time-compilation`: DEAD. "unknown argument" since Xcode 12.5.1. [V] https://developer.apple.com/forums/thread/688502
- `-driver-time-compilation`: accepted but reported to print nothing under swift-driver (Xcode 13.3.1 thread); status in Xcode 26 NOT verified. [S] https://forums.swift.org/t/driver-time-compilation-flag-in-xcode-13-3-1/56884
- `-print-stats`: only meaningful in assert compilers; useless on shipping Xcode. [V] CompilerPerformance.md
- `-ld_classic` / ld64: removed in Xcode 27. [V] https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes.md ("The ld64 linker has been removed and the -ld_classic option is no longer supported." 165165518)
- `SWIFT_USE_INTEGRATED_DRIVER=NO`: reported gone in Xcode 26.5 (setting no longer appears). [S] https://github.com/MobileNativeFoundation/XCLogParser/pull/256

---------------------------------------------------------------------
## 1. .xcactivitylog

### 1.1 Container
- Gzip-compressed binary-ish text in SLF ("Serialized Log Format"). Files are typically KB to low-MB; large builds can take ~45 s to parse with XCLogParser. [S] https://community.tuist.dev/t/server-side-xcactivitylog-processing/928
- Location: `~/Library/Developer/Xcode/DerivedData/<Name>-<28 lowercase letters>/Logs/Build/<UUID>.xcactivitylog` plus `Logs/Build/LogStoreManifest.plist`. Sibling dirs: Logs/Test, Logs/Launch, Logs/Localization, Logs/Package ("Resolve Packages" logs). [LOCAL] confirmed on this machine; XCLogParser README https://github.com/MobileNativeFoundation/XCLogParser
- xcodebuild: README says since Xcode 11 xcodebuild only writes the activity log when `-resultBundlePath` (ending .xcresult) is given. [V README] CONFLICT: an Apple forum post claims `xcodebuild build` (build-only) produces no .xcresult at all (https://developer.apple.com/forums/thread/801326). Treat "does a plain xcodebuild build leave an xcactivitylog in DerivedData" as needing a local test. [U]
- DerivedData dir name = `<ProjectOrWorkspaceName>-<hash>`. Hash = MD5 of absolute .xcodeproj/.xcworkspace path -> two big-endian UInt64 halves -> each encoded as 14 base-26 letters ('a'..'z'), concatenated = 28 chars (matches local dirs such as `Modular-goznbaztmdorxveeraiquumzdpmb`). [S] WebKit script https://webkit.googlesource.com/WebKit/+/068417b470c667101c87b9dfe43b6fbc25c4ea12/Tools/Scripts/webkitpy/xcode/__init__.py and https://pilky.me/finding-derived-data/ ; XCLogParser has an `XcodeHasher` in loglocation (not fetched; 404 on guessed path). Robust alternative: read `<DerivedDataDir>/info.plist` key `WorkspacePath` and match (for plain projects it holds the project path). [S] pilky.me
- Custom locations: global `IDECustomDerivedDataLocation` in `defaults read com.apple.dt.Xcode` (XCLogParser LogFinder reads it); per-workspace `xcuserdata/*/WorkspaceSettings.xcsettings` (`IDEWorkspaceUserSettings_DerivedDataLocationStyle`); `xcodebuild -derivedDataPath X` puts Logs/Build directly under X. XCLogParser order: explicit path > `--derived_data` > IDECustomDerivedDataLocation > default. [V] https://raw.githubusercontent.com/MobileNativeFoundation/XCLogParser/master/Sources/XCLogParser/loglocation/LogFinder.swift
- Git worktrees get separate DerivedData entries (path differs). [S] https://clawhub.ai/alexissan/xcode-build-analyzer
- Latest log: XCLogParser picks newest `.xcactivitylog` by file mtime (not manifest). Manifest ordering by timeStartedRecording is the alternative. [V LogFinder.swift]

### 1.2 LogStoreManifest.plist  [LOCAL sample]
```
<dict>
  logFormatVersion = 11                      (integer; Xcode 26.0.1 local)
  logs = { "<UUID>" = {
      className = IDECommandLineBuildLog      (GUI builds: IDEActivityLogSection-family; XCLogParser maps via LogManifestEntryType.buildFromClassName)
      domainType = Xcode.IDEActivityLogDomainType.BuildLog
      fileName = <UUID>.xcactivitylog
      hasPrimaryLog = true
      primaryObservable = { highLevelStatus = "S", totalNumberOfErrors, totalNumberOfWarnings, totalNumberOfAnalyzerIssues, totalNumberOfTestFailures }
      signature / title = "Resolve Packages"  (build logs: scheme-ish title like "Build <Scheme>")
      timeStartedRecording / timeStoppedRecording = real, seconds since 2001-01-01  (e.g. 814944783.16 = 2026-10-29)
      uniqueIdentifier = <UUID>
  } }
```
XCLogParser requires keys: fileName, title, uniqueIdentifier, `schemeIdentifier-schemeName` (used as scheme), timeStartedRecording, timeStoppedRecording, className; sorts newest first; any missing key throws invalidLogManifest. [V] https://raw.githubusercontent.com/MobileNativeFoundation/XCLogParser/master/Sources/XCLogParser/logmanifest/LogManifest.swift
Linking a log to scheme: manifest `schemeIdentifier-schemeName`. Linking to configuration: not in manifest (that I could verify); it is in target section titles `=== BUILD TARGET X OF PROJECT Y WITH CONFIGURATION Debug ===` (regex in XCLogParser: `BUILD( AGGREGATE)? TARGET (.*?) OF PROJECT`). [V] https://raw.githubusercontent.com/MobileNativeFoundation/XCLogParser/master/Sources/XCLogParser/parser/ParserBuildSteps.swift

### 1.3 SLF token format
Spec doc (older, v0.2.34): https://github.com/MobileNativeFoundation/XCLogParser/blob/v0.2.34/docs/Xcactivitylog%20Format.md
Lexer source (current): https://github.com/MobileNativeFoundation/XCLogParser/blob/master/Sources/XCLogParser/lexer/Lexer.swift ; token enum https://github.com/MobileNativeFoundation/XCLogParser/blob/master/Sources/XCLogParser/lexer/LexerModel.swift
- Header: literal `SLF` then (in the doc's sample) `0` then first int = log version (10 in Xcode 10/11 beta; 11 now). Lexer throws invalidLogHeader if "SLF" missing.
- Each token = payload (chars [0-9a-f]) + delimiter char + optional body:

| Token | Delim | Payload | Body |
|---|---|---|---|
| int | `#` | unsigned 64-bit | none (e.g. `200#`) |
| double | `^` | 16 hex chars, little-endian bytes of IEEE-754 (byte-swap then Double(bitPattern:)) | none (e.g. `afd021ebae48c141^`) |
| null | `-` | none | none |
| string | `"` | length | that many chars (`5"Hello`) |
| array/list | `(` | element count | elements follow as class instances/values (`22(`) |
| className | `%` | length | name; each class name appears once, before first instance (`21%IDEActivityLogSection`) |
| classNameRef (instance) | `@` | index into class-name table (doc says zero-based; Lexer summary says 1-based - verify) | none (`2@`) |
| json | `*` | length | raw JSON text (newer logs; used in attachments) |

  The v0.2.34 doc lists 7 types and does NOT mention json; the current Lexer has an 8th `json` token (`*`). [V LexerModel.swift]
- Only instance START is marked. No end marker and no property names: a parser must know each class's field order (hence version-gated hand-written parsers).
- CONFLICT on string length units: v0.2.34 doc says UTF-16 code units (NSString) and recommends reading as ASCII. XCLogParser v0.2.49 (2026-07-07) changed to "SLF strings using UTF-8 byte lengths ... preserves embedded NUL bytes". Trust the 2026 release (newer, code change). Practical advice: operate on raw bytes and count UTF-8 bytes. [V] https://github.com/MobileNativeFoundation/XCLogParser/releases
- Doubles are `timeIntervalSinceReferenceDate` (seconds since 2001-01-01 00:00 UTC; add 978307200 for Unix epoch).

### 1.4 Class model and field order
Source: https://raw.githubusercontent.com/MobileNativeFoundation/XCLogParser/master/Sources/XCLogParser/activityparser/IDEActivityModel.swift and ActivityParser.swift (same dir).
Classes (private IDEFoundation.framework): IDEActivityLog (version Int8, mainSection), IDEActivityLogSection (+ subclasses IDECommandLineBuildLog, IDEActivityLogMajorGroupSection, IDEActivityLogCommandInvocationSection all parsed by the same routine), IDEActivityLogUnitTestSection, DBGConsoleLog (logConsoleItems: IDEConsoleItem{adaptorType,content,kind,timestamp}), IDEActivityLogMessage (+ AnalyzerResultMessage, AnalyzerControlFlowStepMessage, AnalyzerEventStepMessage, ActionMessage), DVTDocumentLocation / DVTTextDocumentLocation (+ Xcode3ProjectDocumentLocation, IDELogDocumentLocation, IBDocumentMemberLocation, DVTMemberDocumentLocation), IDEActivityLogSectionAttachment.

IDEActivityLogSection field order as read:
1. sectionType(int), domainType, title, signature (strings)
2. timeStartedRecording, timeStoppedRecording (doubles)
3. subSections (list)
4. [Xcode 27.0+: an extra int, "most likely ended status", precedes text] then text (string; holds compiler output incl. `-debug-time-*` lines and warnings)
5. messages (list of IDEActivityLogMessage: title, shortTitle, timeEmitted, severity, type, location, categoryIdent, ...)
6. wasCancelled, isQuiet, wasFetchedFromCache (ints 0/1)
7. [Xcode 26.2+: optional extra int before subtitle] subtitle
8. location (document location)
9. commandDetailDesc (the command signature/line, e.g. "SwiftCompile normal arm64 ... (in target ...)"), uniqueIdentifier, localizedResultString, xcbuildSignature
10. attachments (only if log version >= 11)
11. `unknown` int, read only for command-line logs (leading extra int + class ref marks isCommandLineLog)
Attachments: each is class `IDEFoundation.IDEActivityLogSectionAttachment` with identifier suffix:
 - `TaskMetrics`: major, minor, JSON {utime, stime, maxRSS, wcStartTime, wcDuration} (UInt64; units not stated in source; a 3rd-party script reads wcDuration as microseconds [S])
 - `TaskBacktrace`: JSON frames [{category, description}], category in {ruleHadInvalidValue, ruleSignatureChanged, ruleNeverBuilt, ruleInputRebuilt, ruleForced, dynamicTaskRegistration, dynamicTaskRequest}  -> causal "why did this task run"
 - `BuildOperationMetrics` (full id `com.apple.dt.ActivityLogSectionAttachment.BuildOperationMetrics`): {counters:[String:Int], taskCounters:[String:[String:Int]]}; legacy Xcode 15.3 - 26.3 shape = {clangCacheHits, clangCacheMisses, swiftCacheHits, swiftCacheMisses} (compilation-cache metrics).
Version history from XCLogParser releases (https://github.com/MobileNativeFoundation/XCLogParser/releases): 0.2.43 (2025-11-21) TaskBacktrace + BuildOperationMetrics parse fixes (an unknown attachment id broke Tuist cache on Xcode 26 RC: https://community.tuist.dev/t/error-when-storing-the-cache-binaries-with-xcode-26-0-rc/751); 0.2.45 (2025-12-10) int token moved in Xcode 26.2; 0.2.46 (2026-03-03) tolerant metrics; 0.2.47 (2026-04-24) metrics format for Xcode 26.4, ignore stale substep timestamps; 0.2.48 (2026-06-09) Xcode 27 sections; 0.2.49 (2026-07-07) UTF-8 byte lengths; 0.2.50 (2026-10-27) perf fix. Lesson: SLF parsers break on every Xcode minor; pin and fail loudly; keep a fallback.
- Detecting producing Xcode version: SLF has NO explicit Xcode version field (only log format int 10/11). XCLogParser sniffs by token shape (26.2+/27.0+ extra ints, attachment ids). Other hints: toolchain paths in command lines (`/Applications/Xcode_X.app/...`), SDK names, presence of ScanDependencies/PrecompileModule (>=16), BuildOperationMetrics (>=15.3 legacy form). Record `xcodebuild -version` alongside each captured log. [inference]

### 1.5 XCLogParser pipeline and reporters
README: dump | parse | manifest; reporters json, flatJson, summaryJson, chromeTracer, issues, html; `--derived_data`, `--strictProjectName`, `--machine_name`, `--redacted`. Compatible with Xcode 16.4/Swift 6.0 per README; releases extend to 27. [V] https://github.com/MobileNativeFoundation/XCLogParser
JSON step schema (https://github.com/MobileNativeFoundation/XCLogParser/blob/master/docs/JSON%20Format.md): type main|target|detail; detailStepType; duration; startTimestamp/endTimestamp; compilationDuration / compilationEndTimestamp (targets: compile end can precede target end because linking happens later); fetchedFromCache; swiftFunctionTimes {durationMS, occurrences, line, column, file, signature} (needs -debug-time-function-bodies); swiftTypeCheckTimes (needs -debug-time-expression-type-checking); buildStatus; schema.
Step classification `getDetailType(signature:)` (BuildStep.swift): prefixes "CompileC ", "CompileSwift ", "Ld ", "PhaseScriptExecution ", "Libtool ", "CopySwiftLibs ", "CompileAssetCatalog", "CompileStoryboard ", "WriteAuxiliaryFile ", "LinkStoryboards ", "CpResource ", "MergeSwiftModule ", "CompileXIB ", "CompileSwiftSources ", "PrecompileSwiftBridgingHeader ", "ValidateEmbeddedBinary ", "Validate "; everything else -> other. Upstream master does NOT yet recognize `SwiftCompile`/`SwiftDriver`/`SwiftEmitModule`: PR #256 (open as of 2026-10-20) fixes it; without it nearly the whole modern Swift build is classified `other`. [V] https://github.com/MobileNativeFoundation/XCLogParser/pull/256 and https://raw.githubusercontent.com/MobileNativeFoundation/XCLogParser/master/Sources/XCLogParser/parser/BuildStep.swift
Per-file synthesis: `getSwiftIndividualSteps` splits a compile section into one step per `\s([^\s]+\.swift)` match in commandDetailDesc (skips `com.apple.xcode.tools.swift`), copying the whole step's duration to each file. [V] IDEActivityLogSection+Parsing.swift. => summing per-file durations over-counts.
Swift timing lines are matched by carriage-return-separated records, tab-split into 3 fields: `0.14ms<TAB>/path/File.swift:10:12<TAB>someMethod(param:)` (SwiftCompilerFunctionTimeOptionParser; Xcode text uses `\r` terminators). `parseNameAndLocation` splits on ':' so paths containing ':' break. [V]
Clang trace path: regex `Time trace json-file dumped to (.*?)\r` on the step text, and the step's command must contain `-ftime-trace`. Linker: `-print_statistics` text parsed into LinkerStatistics (total, option parsing, object file processing, resolve symbols, build atom list, run passes, write output; pageins/outs/faults; file counts/sizes). [V] ClangCompilerParser.swift, LinkerStatistics.swift

### 1.6 Task names / what changed across Xcode versions
- Legacy (<=Xcode 13 / legacy driver): one `CompileSwift normal <arch> <file>` per file (non-batch) or per-target `CompileSwiftSources` aggregate; `MergeSwiftModule`.
- Xcode 14+ (integrated swift-driver): per target `SwiftDriver <Module> normal arm64 com.apple.xcode.tools.swift.compiler (in target ...)` (planning), `SwiftDriver Compilation Requirements`, `SwiftCompile normal arm64 Compiling\ F1.swift,\ F2.swift (in target 'M' from project 'P')` (batch) or `SwiftCompile normal arm64 /path/File.swift` (single), `SwiftEmitModule normal arm64 Emitting\ module\ for\ M`, `SwiftDriverJobDiscovery`. Both legacy and new spellings can coexist in one log (423 of 457 targets in the PR's sample log). [V PR #256]
- Xcode 16+ explicit modules: build log "surfaces this work as explicit tasks": per-file dependency scan tasks (`ScanDependencies <file> normal arm64 objective-c`, `builtin-ScanDependencies -o <x>.o.scan -- clang ...`), module compile tasks that are top-level (not attached to a target) `PrecompileModule .../ExplicitPrecompiledModules/<Mod>-<HASH>.scan` with `builtin-precompileModule`, and Swift planning "scans all module sources during its planning task". Module variants differ by hash (command-line set). [V] https://developer.apple.com/documentation/xcode/building-your-project-with-explicit-module-dependencies.md ; https://developer.apple.com/videos/play/wwdc2024/10171/ ; real lines in https://swiftpackageindex.com/builds/8E811867-D2C4-47C3-A42E-BF0EC617660C (Xcode 27 builds; also shows `builtin-SwiftPerFileCompile <File>.swift` and `Using response file: ...-common-args.resp`).
- Explicit Swift modules default for all Swift targets starting Xcode 26 (opt-out `SWIFT_ENABLE_EXPLICIT_MODULES=NO`; not default for Swift <5 mode or Swift/C++ interop). [V] https://developer.apple.com/documentation/xcode-release-notes/xcode-26-release-notes.md (items 125244407, 146404229, 152118892). Build setting "Explicitly Built Modules" in Apple doc.
- Xcode 26: Compilation Caching opt-in ("Enable Compilation Caching", 149700201) -> cache hit/miss counters in BuildOperationMetrics. Xcode 27: dependency scanner optimized; Clang module names must be unique per scan (136303612). [V] release notes URLs above / xcode-27-release-notes.md
- Timeline task names in Xcode GUI "Build With Timing Summary" report also produce Clang/Swift "modules report" (variant counts per module); unverified that `xcodebuild -showBuildTimingSummary` prints them. [V WWDC24-10171 for GUI]
- Known bug affecting timing interpretation: Xcode 27.0 / swift-driver 1.168.6: SwiftEmitModule re-runs after body-only edits (emit-module skip check compares output mtimes), adding 1.3-1.5 s per build on a 17-module app; `-driver-show-incremental` gives no reason. [V] https://github.com/swiftlang/swift-driver/issues/2214

### 1.7 What timings the log gives (summary)
- per target: yes (children of main section; start/end doubles; caveat link finishes after compile).
- per task: yes (every subsection; plus TaskMetrics wcDuration/utime/stime/maxRSS if present).
- per swift-frontend invocation: partially: batch SwiftCompile section covers one frontend batch; with `-driver-show-job-lifecycle` / parseable output extra. Per-file inside a batch: NOT separately timed (each file = batch span).
- critical path: compute from target start/stop + dependency graph; tasks overlap; XCLogParser total "step time" can exceed wall time (5.9 min build showed 318 min of step time). [V PR #256]

---------------------------------------------------------------------
## 2. xcodebuild output, -showBuildTimingSummary, .xcresult

- `-showBuildTimingSummary` prints at end of build, one row per task-type: `<TaskName> (<N> tasks) | <S.SSS> seconds` then `** BUILD SUCCEEDED ** [92.620 sec]`. Samples:
  * 2020-era: `CompileStoryboard (29 tasks) | 87.128 seconds`, `CompileSwiftSources (4 tasks) | 54.144 seconds`, ..., incremental: `CompileSwiftSources (1 task) | 1.245 seconds` [S] https://www.onswiftwings.com/posts/build-time-optimization-part1/
  * Modern: `CompileC (2770 tasks) | 649.139 seconds`, `SwiftCompile (209 tasks) | 75.789 seconds`, `Ld (57 tasks) | 9.891 seconds`, `SwiftEmitModule (27 tasks) | 9.002 seconds`, `SwiftDriver (27 tasks) | 4.057 seconds`, `SwiftDriver Compilation Requirements (27 tasks) | 0.237 seconds` [S, ~2023] https://developer.aliyun.com/article/1275408
  * Note singular "1 task". Summed phase seconds exceed wall time (parallelism). Third-party parser: any line ending " seconds"; split on last `|`; name regex `^(.+?)\s*\((\d+)\s+tasks?\)$` [V] https://raw.githubusercontent.com/AvdLee/Xcode-Build-Optimization-Agent-Skill/main/scripts/summarize_build_timing.py
  * Skill guidance: watch `SwiftEmitModule` (60 s+ after one-line change in huge module) and "Planning Swift module" (~30 s per module in incremental builds) [S] https://github.com/AvdLee/Xcode-Build-Optimization-Agent-Skill ("Planning Swift module" string not independently verified).
- Per-task stdout lines are the task title then the command (`CompileC <obj> <src> normal arm64 objective-c com.apple.compilers.llvm.clang.1_0.compiler (in target 'T' from project 'P')`, `Ld ...`, `SwiftCompile normal arm64 ...`, `ScanDependencies ...`, `PrecompileModule ...`, `builtin-*` lines for in-process tasks; `Using response file:`). These are the same strings as commandDetailDesc in the activity log. [S real logs] https://swiftpackageindex.com/builds/8E811867-D2C4-47C3-A42E-BF0EC617660C
- `xcodebuild -json`: no JSON build log. JSON only for `-list -json`, `-showBuildSettings -json` (documented usage says -json implies -quiet) [S] https://gist.github.com/mhamilt/3b8b9e03160b20ec5c1c246f3946e1d8. `-showBuildSettings -json` shape (third-party description): top-level ARRAY of `{ "action": "build", "target": "<T>", "buildSettings": {...} }` [S] https://app.unpkg.com/xc-mcp@3.2.0/files/dist/utils/build-settings-parser.js . Text form: `Build settings for action build and target X:` then `    KEY = value` lines [V] https://docs.rs/crate/xclog/latest/source/src/build_settings.rs . Xcode 16: `-showBuildSettings` uses the new build system to match real builds (58870112). [V] https://developer.apple.com/documentation/xcode-release-notes/xcode-16-release-notes.md
- `-resultBundlePath X.xcresult` + `xcrun xcresulttool` (man page https://keith.github.io/xcode-man-pages/xcresulttool.1.html): `get build-results` (build action details: errors, warnings, analyzerWarnings), `get test-results summary|tests|insights|test-details|activities|metrics`, `get log --type build|action|console`, `get content-availability`, `get [object] --format json|raw --id`, `export diagnostics|attachments|metrics|object`, `formatDescription`, `merge`, `metadata`, `graph`, `compare`. Use `--schema` / `help get <sub>` to print JSON Schema per version. [V man page]
  * Legacy `get --format json --path` is deprecated since Xcode 16 and needs `--legacy` ("This command is deprecated and will be removed in a future release, --legacy flag is required to use it."). [V] https://developer.apple.com/forums/thread/763888
  * Xcode 16 `get build-results` reportedly omits some warnings vs `get --legacy` (Apple asked for Feedback). [V thread, unresolved] https://developer.apple.com/forums/thread/769351
  * Per-task timings: NO evidence that `get build-results` carries per-task timings (documented fields are issues and basic status). `get log --type build` exists but its output schema is undocumented in anything I fetched [U]; the xcresult's build log is probably the same activity-log content, so the xcactivitylog route remains the proven per-task source. [U]

---------------------------------------------------------------------
## 3. Swift compiler timing/diagnostic flags (status Xcode 16/26/27)

Primary doc: https://github.com/swiftlang/swift/blob/main/docs/CompilerPerformance.md (headings: factors affecting performance; compilation modes; known problem areas; "How to diagnose compilation performance problems" -> Tools and options; isolating a regression; finding general improvements; reporting bugs). It does NOT mention `-warn-long-*`, `-ftime-trace` or `-Rmodule-loading`.
Options source of truth: https://raw.githubusercontent.com/swiftlang/swift/main/include/swift/Option/Options.td and FrontendOptions.td.

From CompilerPerformance.md "Tools and options" [V]:
- Driver: `-driver-time-compilation` -> table "Driver Compilation Time" with user/system/user+system/wall columns and one row per job, e.g. `0.0000 ( 82.0%)   0.0001 ( 59.5%)   0.0001 ( 69.0%)   0.0284 ( 58.0%)  {compile: t-177627.o <= t.swift}`.
- `-Xfrontend -debug-time-function-bodies`: typecheck time per function, sorted: `9.16ms  test.swift:15:6 func find<R>(_ range: R, value: R.Element) -> R where ...` (real-world raw lines are TAB separated: ms<TAB>file:line:col<TAB>signature, per XCLogParser parser).
- `-Xfrontend -debug-time-expression-type-checking`: `6.35ms  test.swift:19:8`.
- `-Xfrontend -print-stats`: counters like `361 Constraint solver overall - # of solution attempts`; most counters assert-build only. `-print-clang-stats`; `-print-inst-counts`.
- `-Xfrontend -stats-output-dir <dir>`: JSON per driver/frontend job, e.g. `"AST.NumSourceBuffers": 1`; timers in seconds. `-trace-stats-events` -> CSV `Time,Live,IsEntry,EventName,CounterName,CounterDelta,CounterValue,EntityName,EntityRange`. Post-process with `utils/process-stats-dir.py` (`--compare-stats-dirs old new` -> columns old,new,delta_pct,name; `--select-module`, `--group-by-module`, `--markdown`, `--catapult`, `--lnt`, `--render-profiles`).
- Driver diagnosis: `-driver-print-actions`, `-driver-print-bindings`, `-driver-print-jobs`, `-driver-show-incremental`, `-driver-show-job-lifecycle`; `.swiftdeps` files.
Stats file details [V] https://raw.githubusercontent.com/swiftlang/swift/main/utils/jobstats/jobstats.py :
 * filename regex: `stats-<startUsec>-swift-<kind>-<module>-<input>-<triple>-<out>-<opt>-<random>[-...].json` (kind = frontend|driver; "pid" is a random number).
 * timer keys: `time.swift-<jobkind>.<module>-<input>-<triple>-<out>-<opt>.<timerkind>` (wall/user/sys; seconds, floats). CONFLICT: CompilerPerformance.md sample shows shorter `time.swift.Parsing.wall`-style keys; jobstats.py (the actual consumer) uses the long form. Trust jobstats.py; inspect a real file. Per-phase timers inside (e.g. "LLVM pipeline.wall", mentioned by S. Pestov) exist. [S] https://forums.swift.org/t/driver-time-compilation-flag-in-xcode-13-3-1/56884
 * counters e.g. `Driver.NumDriverJobsRun`, `Driver.NumDriverJobsSkipped`.
 * Works from Xcode via `OTHER_SWIFT_FLAGS="-Xfrontend -stats-output-dir -Xfrontend <dir>"`; Swift Package Index builds pass `-stats-output-dir .stats` (stats-file write errors when dir unwritable). [S] https://swiftpackageindex.com/builds/712EA38F-BC9A-46E8-9837-398C2B8662B0
 * In batch mode one frontend job has several primaries -> one stats file per job, not per file (inference from filename schema having one `<input>`) [U].

Flag status table
| Flag | Status 2026 | Evidence |
|---|---|---|
| `-Xfrontend -debug-time-function-bodies` | works; help "Dumps the time it takes to type-check each function body" | Options.td (FrontendOptions); used by qonto parser https://github.com/qonto/SwiftCompilationTimingParser and AvdLee skill |
| `-Xfrontend -debug-time-expression-type-checking` | works | same |
| `-Xfrontend -warn-long-function-bodies=N`, `-warn-long-expression-type-checking=N` | works (Swift 6.1 forum report, 2025); help "Warns when type-checking a function takes longer than <n> ms". Frontend options = UNSUPPORTED, may be removed without notice | https://forums.swift.org/t/expect-and-warn-long-expression-type-checking/77931 ; https://forums.swift.org/t/how-do-i-optimize-compile-times/71938?page=2 |
| `-Xfrontend -debug-time-compilation` | DEAD (>= Xcode 12.5.1) | https://developer.apple.com/forums/thread/688502 ; not in current Options.td |
| `-driver-time-compilation` | defined (Options.td: "Prints the total time it took to execute all compilation tasks") but reported silent in new driver | forum 56884; swift-driver README does not mention it |
| `-Xfrontend -stats-output-dir` | works | Options.td ("Directory to write unified compilation-statistics files to") |
| `-print-stats` | useless in release compilers | CompilerPerformance.md |
| `-driver-show-incremental` | works in swift-driver (Reporter created when `.showIncremental`) | https://raw.githubusercontent.com/swiftlang/swift-driver/main/Sources/SwiftDriver/IncrementalCompilation/IncrementalCompilationState.swift ; Options.td ("With -v, dump information about why files are being rebuilt") |
| `-driver-show-job-lifecycle` | works (Driver.swift `showJobLifecycle`) | https://raw.githubusercontent.com/swiftlang/swift-driver/main/Sources/SwiftDriver/Driver/Driver.swift |
| `-driver-print-jobs` / `-###` | defined | Options.td |
| `-explain-module-dependency[-detailed]` | new driver only | Options.td ("Emit remark describing why compilation may depend on a module with a given name") |
| `-Rmodule-loading` | exists (`remark_loading_module`: "Emit remarks about loaded module") | Options.td |
| `-save-optimization-record` | exists (YAML) | Options.td |
| `-emit-dependencies-path` (Make-style deps), `-emit-reference-dependencies` (swiftdeps) | exist | FrontendOptions.td |
| batch tuning `-driver-batch-count/-size-limit/-seed` | exist | Options.td |
| `-disable-batch-mode` | gives per-file instead of per-batch timings in Xcode | forum 56884 [S] |
Warning text (parseable from activity log `messages`/text): `<file>:<line>:<col>: warning: <kind> '<name>' took <N>ms to type-check (limit: <M>ms)` with kind in {global function, instance method, getter, initializer, type-check?}; expression form `expression took <N>ms to type-check (limit: <M>ms)`. Regexes used by AvdLee diagnose_compilation.py: [V] https://raw.githubusercontent.com/AvdLee/Xcode-Build-Optimization-Agent-Skill/main/scripts/diagnose_compilation.py . Caveats: only emitted for files actually recompiled (clean-ish builds); swift-testing `#expect` macros inflate times.
Incremental remarks (from `-driver-show-incremental`): "remark: Incremental compilation: Disabling incremental build: could not read build record", "...Scheduling all post-compile jobs because something was compiled", "Queuing <file> (initial)", "Queuing <file> because of dependencies discovered later", "Scheduling invalidated ...", "Incremental compilation has been disabled". [S] https://forums.swift.org/t/optimizing-and-debugging-incremental-build-time-in-swift-5-5/49379 ; https://github.com/manaflow-ai/cmux/issues/13518 . In Xcode the remarks appear under the "Compile Swift Source files" log entry, but Xcode's new build-system integration can hide them; workaround `defaults write com.apple.dt.XCBuildEnableSwiftBuildSystemIntegration`... actual key per thread: `defaults write com.apple.dt.XCBuild EnableSwiftBuildSystemIntegration 0` (2021-era, effect on Xcode 26 unverified). Alternatively copy the swiftc command from the log and run it in a shell.
Dependency files: `.swiftdeps` = opaque, "not guaranteed stable across compiler versions" (Driver.md); fine-grained version is an LLVM bitstream with signature+version, node kinds topLevel/nominal/member/dynamicLookup/externalDepend (DependencyAnalysis.md). Blog claims of YAML .swiftdeps are outdated (CONFLICT; trust Apple docs + source). [V] https://raw.githubusercontent.com/swiftlang/swift/main/docs/Driver.md ; https://raw.githubusercontent.com/swiftlang/swift/main/docs/DependencyAnalysis.md ; [S] legacy reader summary from https://gitea.com/KirillArkhipov/swift/src/branch/main/lib/AST/FineGrainedDependencyFormat.cpp (page needed login at fetch time; snippet only via search). Don't parse it; use the driver's reporting.
Parseable output: `-parseable-output` (swift-driver DriverParseableOutput.md) gives JSON began/finished/skipped messages with pid and usage; not fetchable (404 on guessed path). [U]

---------------------------------------------------------------------
## 4. clang
- `-ftime-trace[=path]`: "Write a Chrome tracing-format JSON time trace for the compilation"; without a path derives JSON name from the output; `-ftime-trace-granularity` default 500 microseconds; `-ftime-trace-verbose` adds filenames, 2-3x bigger. [V] https://clang.llvm.org/docs/UsersManual.html . In Xcode set via OTHER_CFLAGS; log prints "Time trace json-file dumped to <path>". [V] ClangCompilerParser.swift
- ClangBuildAnalyzer (aras-p): `--start dir`, `--stop dir capture`, `--all dir capture`, `--analyze capture`; reads all `*.json` next to object files; aggregates parse/codegen per file, template instantiation, functions, expensive headers; linking/LTO not captured; ClangBuildAnalyzer.ini controls counts; no Xcode-specific guidance. [V] https://github.com/aras-p/ClangBuildAnalyzer
- `-ftime-report`: not covered by any fetched source (prints phase table to stderr). [U]
- Xcode 16+ explicit modules: per-TU `ScanDependencies` tasks and `PrecompileModule` tasks are separate timed steps; a -ftime-trace for precompile tasks is not documented. [U]

---------------------------------------------------------------------
## 5. Linker
- Xcode 14: faster ld64 ("twice as fast for many projects"); flags -all_load, -dead_strip, -no_exported_symbols, -no_deduplicate; `dyld_info -exports/-fixup`. [V] https://developer.apple.com/videos/play/wwdc2022/110362/ (no ld_prime mention).
- Xcode 15: new linker ("ld_prime"); `-ld_classic` and `-Wl,-ld64`/`-ld_prime` selectors; Apple has not released ld_prime source; options differ (platform_version subsumes old ones). [S] https://developer.apple.com/forums/thread/749558 and others. Xcode 16: `-ld_classic` deprecated (128502299), new code-dedup algorithm improves static link time and is default in release builds (125995452). [V] xcode-16-release-notes.md
- Xcode 27: ld64 removed, `-ld_classic` unsupported (165165518). On 27.0 GA a third-party test found `-Wl,-ld_classic` => "ld: warning: -ld_classic is no longer supported and will be ignored" exit 0; `-Wl,-ld64` fails. [S] https://blakecrosley.com/blog/xcode-27-build-failures-ld64-clang-modules (secondary, author's own testing).
- `-Xlinker -print_statistics`: ld64 man text "Logs information about the amount of memory and time the linker used." XCLogParser parses it from ld64 output (fields above). Whether ld_prime/Xcode 27 emit the same text is NOT verified -> treat linker statistics as unavailable until tested on target Xcode. [V XCLogParser README/LinkerStatistics.swift; U for ld_prime]
- `-why_load` (alias -whyload): logs why each archive member is loaded; `-t` (trace), `-map <file>` (link map): ld64 documentation; ld_prime support unverified. [S] ld.1 at https://opensource.apple.com/source/ld64/ld64-96.5/doc/man/man1/ld.1.auto.html (old). Safer measurable signals: Ld task duration (xcactivitylog/timing summary), Ld TaskMetrics maxRSS, size of linker input.

---------------------------------------------------------------------
## 6. Project model

### 6.1 Formats
- classic `project.pbxproj`: OpenStep ASCII plist, header `// !$*UTF8*$!`, top-level keys archiveVersion, classes, objectVersion (Xcode 16: 77 via synchronized folders), objects (dict keyed by 24-hex IDs), rootObject. [V partly] https://raw.githubusercontent.com/tuist/XcodeProj/main/Sources/XcodeProj/Objects/Project/PBXProj.swift (archiveVersion, objectVersion, classes "appears to always be empty", rootObject, objects) ; XcodeProj docs say JSON-converted projects get objectVersion 77.
- NEW: Xcode 27.2 (Oct 2026) introduces JSON `project.xcproj` replacing project.pbxproj inside the .xcodeproj bundle; new projects default to it; existing ones convert via File inspector > Project Format or `xcodebuild -project MyApp.xcodeproj -convert-project "Xcode Project"` [S: this command line appears in one aggregator summary; unverified]; opens only in Xcode 27+; Apple open-source Swift package `apple/xcode-project-format` (Apache 2.0; `XCSchema.Project(jsonRepresentation:)`); Xcode 27.2 ships `xcprojformatter`. Structure [S sarunw]: top-level `default-configuration`, `configurations`, `localizations`, `files` (groups with kind/path/name/children and per-file `target-membership` like "App/compile-sources"), `targets` (name, id, product, product-type, build-phases by name, build-settings), project `build-settings`, `last-upgrade`. Build settings written once, with conditions in key: `DEBUG_INFORMATION_FORMAT[config=Debug]`. IDs only on targets and products. Sources: https://www.infoq.com/news/2026/10/xcode-json-project-format/ (2026-10-12), https://sarunw.com/posts/xcode-json-project-format-xcproj/ , https://raw.githubusercontent.com/tuist/XcodeProj/main/Documentation/json-project-format.md
  Implication: any CLI must read both; classic `.pbxproj` still works in Xcode 27.
- Object types (isa): PBXProject, PBXNativeTarget, PBXAggregateTarget, PBXLegacyTarget, XCBuildConfiguration, XCConfigurationList, PBXSourcesBuildPhase / PBXFrameworksBuildPhase / PBXResourcesBuildPhase / PBXCopyFilesBuildPhase / PBXHeadersBuildPhase / PBXShellScriptBuildPhase, PBXBuildFile, PBXFileReference, PBXGroup, PBXVariantGroup, PBXTargetDependency, PBXContainerItemProxy, PBXReferenceProxy, XCSwiftPackageProductDependency, XCRemoteSwiftPackageReference, XCLocalSwiftPackageReference, Xcode 16 PBXFileSystemSynchronizedRootGroup (+ BuildFileExceptionSet, GroupBuildPhaseMembershipExceptionSet). [S/V partially: XcodeProj PBXProj.swift exposes fileSystemSynchronized* accessors]
- PBXShellScriptBuildPhase keys: name, inputPaths, outputPaths, inputFileListPaths, outputFileListPaths (base-class keys), shellPath, shellScript, showEnvVarsInLog (written only when non-default, "0"/"1"), alwaysOutOfDate ("1" => script runs every build; written only when set), dependencyFile, runOnlyForDeploymentPostprocessing. [V] https://raw.githubusercontent.com/tuist/XcodeProj/main/Sources/XcodeProj/Objects/BuildPhase/PBXShellScriptBuildPhase.swift . Semantics: no outputs + "Based on dependency analysis" => runs every build with the warning "Run script build phase 'X' will be run during every build because it does not specify any outputs..." [U-from-knowledge; the Apple doc page returned only its title] https://developer.apple.com/documentation/xcode/running-custom-scripts-during-a-build ; file lists are `.xcfilelist` one path/line, exposed as SCRIPT_INPUT_FILE_COUNT/SCRIPT_INPUT_FILE_<n>.
- Build-setting inheritance (low -> high): platform/system defaults, project xcconfig, project settings, target xcconfig, target settings; `$(inherited)` appends lower level; within an xcconfig later assignments override earlier unless using $(inherited). Apple's diagram and NSHipster disagree on whether project-file settings sit above or below the project xcconfig. Apple's help page: https://help.apple.com/xcode/mac/current/en.lproj/deva3af9b6ba.html ; https://nshipster.com/xcconfig . Command-line `VAR=value` overrides sit above all (xcodebuild man; not verified here [U]). Do not reimplement: ask `xcodebuild -showBuildSettings`.
- Schemes `.xcscheme` XML: `BuildAction` attributes `parallelizeBuildables`, `buildImplicitDependencies`, `runPostActionsOnFailure`, `buildArchitectures`; child `BuildActionEntries/BuildActionEntry` with `buildForTesting|Running|Profiling|Archiving|Analyzing` and a `BuildableReference`; missing attributes default YES. [V] https://raw.githubusercontent.com/tuist/XcodeProj/main/Sources/XcodeProj/Scheme/XCScheme+BuildAction.swift
- Workspace: `contents.xcworkspacedata` XML (`FileRef location="group:Path.xcodeproj"`) [U-from-knowledge].
- SPM: `swift package dump-package` (manifest JSON), `swift package show-dependencies --format json|text|dot|flatlist` (JSON includes local `path`; newer SwiftPM adds `traits`), `swift package describe --type json` [S] https://forums.swift.org/t/showing-dependencies/15962 ; commit adding traits. `Package.resolved` v3: top `originHash`, `pins[]` {identity, kind (remoteSourceControl...), location, state{revision, version|branch}}, `version: 3` [S] sample files e.g. https://github.com/thumbtack/thumbprint-ios/blob/main/Package.resolved . Xcode keeps SPM state in `DerivedData/<proj>/SourcePackages/workspace-state.json` ([LOCAL] version 7 with object.artifacts/dependencies/prebuilts) and `SourcePackages/checkouts`; `xcodebuild -resolvePackageDependencies` populates them.
- CocoaPods: Podfile.lock sections PODS, DEPENDENCIES, SPEC REPOS, EXTERNAL SOURCES, CHECKOUT OPTIONS, SPEC CHECKSUMS, PODFILE CHECKSUM, COCOAPODS; Pods/Pods.xcodeproj is a normal project. [S] https://rdoc.info/github/CocoaPods/Core/Pod/Lockfile
- Tuist: `Project.swift` / `Workspace.swift` / `Tuist.swift` manifests compiled by Tuist; `tuist generate` emits the Xcode project. [S] https://docs.tuist.dev/es/guides/develop/projects/manifests

### 6.2 Libraries
| Lib | Notes |
|---|---|
| tuist/XcodeProj (Swift, MIT) | ~2.2k stars; latest release 9.17.6 (2026-10-15); 9.17.0 (2026-09-17) added experimental project.xcproj; `XcodeProj(path:)`, `.pbxproj`, `write(path:)` keeps the format read, `write(path:format:.xcproj)` converts (old file left behind); `PBXProj(path:)`; deterministic UUID regeneration `invalidateUUIDs()`; JSON conversion drops lastKnownFileType, editor settings, build-phase file order, objectVersion etc. [V] https://github.com/tuist/XcodeProj , https://github.com/tuist/XcodeProj/releases |
| CocoaPods Xcodeproj (Ruby, MIT) | ~2.4k stars; `Xcodeproj::Project.open(...)`, `.save`; handles xcconfig/xcscheme/workspace; CLI `xcodeproj` diff/YAML; format fidelity and Xcode 27.2 JSON support not stated. [V] https://github.com/CocoaPods/Xcodeproj |
| mod-pbxproj (Python) | ~1.3k stars; `XcodeProject.load(...pbxproj)`, `add_file`, `add_other_ldflags`, `save()`; objectVersion support not stated. [V] https://github.com/kronenthaler/mod-pbxproj |
| Rust | `xcodeproj` crate v0.3.0 (2022, read-oriented, writing unfinished); `openstep-plist` (parse/serialize + serde); `serde-pbx` 0.1.0; Node/Rust `@xcodekit/xcode` (claims byte-identical round trip). [S] https://rust-digger.code-maven.com/crates/xcodeproj , https://docs.rs/openstep-plist , https://docs.rs/crate/serde-pbx/latest/source/Cargo.toml , https://github.com/mozharovsky/xcode/releases/tag/v0.1.0 |
| Apple apple/xcode-project-format | Swift package for project.xcproj encode/decode (v0.1.0 docs on Swift Package Index) [S] InfoQ |

### 6.3 Risks of rewriting pbxproj; safer alternative
- Hazards: opaque 24-hex IDs (new objects need unique IDs; libraries may regenerate deterministically -> huge diffs), section order/comment formatting differences, objectVersion drift (older Xcode refuses newer `objectVersion`; Xcode 16 "validates the format version of Xcode projects", 125385745), synchronized-folder exception sets, merge conflicts, silent loss of unknown keys, and now two on-disk formats where conversion is lossy (see "not preserved" list above). Round-trip test (read->write->git diff must be empty) before any edit.
- Safer: do not edit the project; add or generate an `.xcconfig` and pass `-xcconfig <file>` to xcodebuild, or override on the command line (`xcodebuild ... OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -warn-long-function-bodies=100' SWIFT_ENABLE_EXPLICIT_MODULES=NO`). AvdLee's script does the command-line override with `$(inherited)` plus `-derivedDataPath` to isolate logs. [V] diagnose_compilation.py. Caveats: command-line settings apply to all targets including packages (usually desirable for measurement); an `-xcconfig` flag gets overridden by target-level settings that lack `$(inherited)`.

---------------------------------------------------------------------
## 7. Dependency graph extraction
- Target graph: pbxproj/xcproj `PBXTargetDependency` + `XCSwiftPackageProductDependency` + "Link Binary" PBXBuildFile entries + scheme `buildImplicitDependencies=YES` (implicit deps inferred from linked products/imports). Cross-check with the activity log: the order and overlap of target section start/end times shows realized parallelism; `parallelizeBuildables` controls it.
- SPM graph: `swift package show-dependencies --format json` for packages, `Package.resolved` for pins, `workspace-state.json` in DerivedData for Xcode-resolved state.
- File-level import graph: regex scan for `import X`/`@testable import X`/`@_exported import`, `#import`/`@import` for ObjC. Authoritative alternative: dependency scanner.
- `swift-frontend -scan-dependencies` (frontend mode "Scan dependencies of the given Swift sources") and libSwiftScan produce a graph of Swift binary modules (.swiftmodule), textual interfaces (.swiftinterface), binary Clang modules (.pcm), module maps; the driver turns it into `-compile-module-from-interface` / `-emit-pcm` jobs. [V] https://forums.swift.org/t/evolving-how-swift-is-built-driver-as-a-library-explicitly-built-modules-and-beyond/61102 . JSON shape: top-level `mainModuleName`, `modules[]` entries keyed by `{"swift": name}` / `{"clang": name}` / `{"swiftPrebuiltExternal": ...}` with `modulePath`, `directDependencies`, `details`; Swift 5.9 added `swiftOverlayDependencies`. Exact schema NOT verified from a primary source; there was no versioned schema (changed in 5.9 and Xcode 27 notes). [S/U] https://github.com/apple/swift/pull/66936 . In Xcode, the `.scan` files under `ExplicitPrecompiledModules/` and `ScanDependencies` task output are the per-build equivalent.
- `-explain-module-dependency <name>` (new driver) emits a remark explaining why a module is a dependency.
- swiftdeps: file-level provides/depends (topLevel, nominal, member, dynamicLookup, depends-external) but opaque/unstable; prefer `-driver-show-incremental` output.
- Critical path from xcactivitylog: build DAG from target dependencies; for each target use [timeStartedRecording, timeStoppedRecording]; longest-weighted path where an edge exists if dependency target finished before dependent started AND declared dependency; cross-check using TaskMetrics wcStartTime/wcDuration for task-level path. Caveat: with explicit modules, module PrecompileModule tasks are top-level (not under a target), so target-only critical paths undercount them. [V] WWDC24-10171

---------------------------------------------------------------------
## 8. Machine / environment signals
- `sysctl -n hw.model hw.memsize hw.ncpu hw.perflevel0.physicalcpu hw.perflevel1.physicalcpu` (Apple Silicon P/E cores) [U-from-knowledge]; `xcodebuild -version`; `xcode-select -p`; `swift --version` / `swift-driver --version` (swift-driver version e.g. 1.168.6 with Xcode 27.0 per issue 2214).
- Thermal: `pmset -g therm` reports thermal/performance warning state, no admin; on Apple Silicon `pmset -g thermlog` often empty and CPU_Speed_Limit is Intel-era; finer data via `sudo powermetrics --samplers thermal,cpu_power -n 1`. [S] https://doc.vuo.org/2.4.4/manual/vuo-slows-down-when-my-computer-heats-up.xhtml ; https://mole.fit/blog/how-to-check-mac-temperature.md
- Time Machine: `tmutil isexcluded <path>`; `tmutil addexclusion [-p]`. [S] https://alexwlchan.net/til/2024/exclude-files-from-time-machine-with-tmutil/
- Spotlight: DerivedData subfolders end in `.noindex` (Build.noindex, Index.noindex, ModuleCache.noindex [LOCAL: ModuleCache.noindex confirmed]) which excludes them from Spotlight; `mdutil -s <volume>` shows indexing state [U-from-knowledge; the search found no source].
- Xcode defaults (`defaults read com.apple.dt.Xcode`): `IDEBuildOperationMaxNumberOfConcurrentCompileTasks` (community: set to hw.ncpu), `ShowBuildOperationDuration` (YES shows build time in toolbar), `IDEIndexDisable`, `IDECustomDerivedDataLocation`. Undocumented by Apple, may no longer work; sources are gists. [S] https://github.com/dmaclach/xcode-defaults ; https://gist.github.com/shahzadmajeed/f12f6263ab56ea70beac38bc113105f2
- DerivedData size (`du -sk` of the project dir), volume type/external (`diskutil info -plist <vol>`: SolidState, Internal, Protocol), free space, and whether `DerivedData` is a symlink (Xcode 26 notes fixed Previews failing when the path crossed a symlink, 149032016). [V partly] xcode-26-release-notes.md
- Also capture: macOS version, `SWIFT_ENABLE_EXPLICIT_MODULES`, compilation caching on/off, `SWIFT_COMPILATION_MODE`, `COMPILER_INDEX_STORE_ENABLE`, background indexing, concurrent Xcode instances/Index activity, Spotlight/AV load.

---------------------------------------------------------------------
## Conflicts and gaps (consolidated)
1. SLF string length unit: UTF-16 (old doc) vs UTF-8 bytes (XCLogParser v0.2.49, 2026-07). Trust the latter.
2. SLF classNameRef indexing 0-based (doc) vs 1-based (Lexer summary). Needs reading Lexer.swift directly.
3. Payload encoding: lexer scans lowercase hex payload chars; ints/lengths decimal vs doubles hex: summaries ambiguous. Re-read Lexer.swift before implementing.
4. Whether plain `xcodebuild build` leaves an xcactivitylog without -resultBundlePath: README vs forum disagree; unverified locally.
5. `-driver-time-compilation` on Xcode 26/27: unverified (only 2022 anecdote of no output).
6. Stats JSON key spelling: CompilerPerformance.md short keys vs jobstats.py long keys.
7. xcresult `get build-results` per-task timings: none found; `get log --type build` schema undocumented in fetched sources.
8. TaskMetrics attachment: units of wc* fields and the first Xcode version that writes it unverified; log format version 11 observed on Xcode 26.0.1.
9. ld_prime support for `-print_statistics`, `-why_load`, `-t`, `-map`: unverified. ld64 gone in Xcode 27 (Apple release notes), so XCLogParser LinkerStatistics may return nothing.
10. `swift-frontend -scan-dependencies` JSON schema, `-parseable-output` format, `.swiftdeps` layout: only partial/secondary evidence.
11. `xcodebuild -convert-project` command and `xcodebuild` support for project.xcproj builds: from aggregators, not Apple docs.
12. `mdutil`, `sysctl` key names, `contents.xcworkspacedata` shape, `-ftime-report` described from general knowledge, not fetched.
13. Several web pages were summarized by a small model; quotes/regexes there should be re-checked in source before relying on them.

## Source list (principal)
- https://github.com/MobileNativeFoundation/XCLogParser (README, releases, PR #256, Sources/XCLogParser/{lexer,activityparser,parser,loglocation,logmanifest}, docs/JSON Format.md, v0.2.34 Xcactivitylog Format.md)
- https://github.com/swiftlang/swift/blob/main/docs/{CompilerPerformance,DependencyAnalysis,DriverInternals,Driver}.md ; include/swift/Option/{Options,FrontendOptions}.td ; utils/{process-stats-dir.py,jobstats/jobstats.py}
- https://github.com/swiftlang/swift-driver (README; IncrementalCompilationState.swift; Driver.swift; issue 2214)
- Apple: Xcode 16/26/27 release notes (.md), explicit module docs, WWDC24-10171, WWDC22-110362, xcresulttool man (keith.github.io), forums 688502, 763888, 769351, 801326
- https://github.com/tuist/XcodeProj (+ releases, JSON format doc, source files) ; CocoaPods/Xcodeproj ; kronenthaler/mod-pbxproj
- https://github.com/AvdLee/Xcode-Build-Optimization-Agent-Skill (scripts) ; https://github.com/qonto/SwiftCompilationTimingParser ; https://github.com/aras-p/ClangBuildAnalyzer ; clang UsersManual
- InfoQ / sarunw on Xcode 27.2 JSON project format
- Swift forums: 56884, 49379, 61102, 77931, 71938
- Local reads: LogStoreManifest.plist (Build + Package), Xcode version.plist, workspace-state.json
