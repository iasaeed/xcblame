# xcblame schema and contract: v0.5 "Deep and Why"

The contract between the three v0.5 lanes. It freezes the new report members (`incremental`, `fixedCosts`,
`moduleGraph`, `deep`, `build.cache`), the history row extension, the `why` command and the `build` flags, the deep
DerivedData and wrapper xcconfig, the HTML view DOM contracts (#7-#9), the planted-cause fixture, and the file ownership.
Types live in `Sources/XcblameKit/Reporters/ReportDocument.swift` (MARK "v0.5 members"), `Deep/`, `Why/` and
`Graph/{FixedCosts,ModuleGraph,ModuleVariants,CacheMetrics}.swift`.
`Tests/XcblameKitTests/Reporters/SchemaV05ContractTests.swift` pins every member name (`V05Samples` there holds one
populated sample of each member and validates it against `xcblame schema`). Renaming, removing or retyping a member
breaks the contract; a lane that needs a change stops and asks the integrator.

Lanes (disjoint files, see "File ownership and lane notes"):
- **A Deep** (`build --deep`, `--deep-scope`, `--exact-files`, toolchain probe, wrapper xcconfig, deep DerivedData,
  stats-dir and ftime-trace readers, `estimated` file rows).
- **B Why** (`why`, `build --runs/--kind/--touch`, cause attribution, V15, history capture, DYN-002, the why view).
- **C Graph** (fixed costs, module graph and variants, cache counters and the `cached` / `previews` kinds, the
  fixed-cost and module-graph views).

A parallel probe lane answers MV-2 (Task Backtraces mechanism), MV-6 (stats-dir key format), MV-7 (ftime-trace under
explicit modules), MV-8 (driver remarks) and MV-12 (cache counters) in `docs/research/probes-v0.5.md`. Everything that
depends on those answers is behind a pluggable reader (`CauseEvidenceProvider`, `StatsDirReader`, `FTimeTraceReader`,
`CacheMetrics`); lanes adapt the reader to the probe doc when it lands, never the contract.

## General rules (v0.2-v0.4 rules unchanged)

- `schemaVersion` stays `xcblame.report/1`; every v0.5 member is additive (`@Added`: a v0.4 saved report decodes with
  them null). `tool.version` is `0.5.0`.
- §8.1 null+note: a member that does not apply is `null` with a reason in the nearest `notes`. Phase 1 leaves
  `incremental` with the existing note `not produced yet: incremental causes (v0.5)` and adds one note
  `not produced yet: fixedCosts, moduleGraph, build.cache (v0.5)` (it names only the members still null; lane C's
  `// v0.5 lane C` block in `ReportDocument+Make` builds it). Each lane replaces its part with the real reason
  (`incremental: not applicable — this is a clean build (no previous work to compare)` (`CauseEngine.cleanNote`),
  `moduleGraph: null because the log has no target`, ...). `deep` is null **without**
  a note when `--deep` was not given (the `regression` precedent). Integration: both phase-1 notes are gone; a pipeline
  report without the command step (`--model-json`, selftest) keeps `incremental: null because cause attribution runs
  only in analyze of a build log, build and why (against history)` (`CauseEngine.pendingNote`).
- A capped array has `<name>Total` and `<name>ShownShare`. New capped arrays: `causes[].tasks`, `fixedCosts[].tasks`,
  `moduleGraph.variants.perModule`, `moduleGraph.nodes`, `moduleGraph.edges`. Not capped: `incremental.causes` (every
  cause, `unknown` last), `fixedCosts` (one row per class), `longestChain`, `criticalChain`. `fanIn`, `fanOut` and
  `blockers` are top-10 ranking views of the nodes, not tables (`targets` is their total).
- Every total, sum and partition (V15) is computed on the full model before `--top` or the HTML budget cut rows.
- Times are seconds rounded to 6 decimals (`ReportDocument.round6`); ratios are fractions; paths stay absolute in the
  document and are redacted by the Redactor with everything else (the generic walk covers new members).

## Report members added in v0.5

| Member | Type | Null when | Lane |
|---|---|---|---|
| `incremental` | `Incremental?` | clean build, `clean-action`, doctor document, timing withheld (V1), or attribution failed (note) | B |
| `fixedCosts` | `[FixedCost]?` | doctor document, timing withheld, nothing executed | C |
| `moduleGraph` | `ModuleGraph?` | doctor document, no target in the log | C |
| `deep` | `Deep?` | `--deep` not given (no note) | A |
| `build.cache` | `BuildCache?` | the log has no build-level cache counter (most builds; note) | C |

### `incremental` (DESIGN §6.6)

Non-null for every non-clean build report (`incremental`, `zero-change`, `cached`; `index`/`previews`/`analyze` too when
they executed tasks). Every executed task (the tasks that entered timing: `build.tasks`; reused tasks are up to date and
never attributed) gets exactly one primary cause.

| Member | Type | Meaning |
|---|---|---|
| `basis` | `previousIndex` \| `currentLogOnly` | `previousIndex`: a history task index of the same build key (scheme, configuration, destination) was compared. `currentLogOnly`: none exists; only backtraces and static script I/O apply, everything else is `unknown (no previous build recorded)`. |
| `previousBuild` | `{id, time}?` | History entry id and time of the compared build; null under `currentLogOnly`. |
| `causes` | `[Cause]` | Every cause with ≥ 1 task, by `seconds` descending, `unknown` always last and always present (seconds 0 when every task has a cause). |
| `unknownSeconds`, `unknownShare` | `Double`, `Double?` | Seconds of the `unknown` cause and its share of `v15.executedSeconds` (null when 0 task time). Always shown (text, HTML) with the `why --backtraces` hint. |
| `byTaskTime` | `[String]` | Cause ids by `seconds` descending, ties by id. |
| `byPathSeconds` | `[String]` | Cause ids by `pathSeconds` descending (causes with 0 path seconds last); empty without a critical path. The two rankings are never added. |
| `v15` | `{status, executedSeconds, sumOfCauses}` | `status` `pass` / `fail` / `skipped` (closed); `executedSeconds` = `build.taskTime`; `sumOfCauses` = Σ `causes[].seconds`. |
| `procedure` | `Procedure?` | Only for a `why` run with xcodebuild arguments; null for `analyze`, `build` and `why` without `--`. |
| `notes` | `[String]` | Why a source was not available (`backtraces: unavailable (MV-2)`), what the previous index lacked, and the comparison limits that apply to this build (`limit: …`, one each, see "Integration notes"). |

**Cause**: `id` (`<class>:<subject>`, or `unknown`; stable across runs of the same input), `class` (closed, below),
`cause` (one line for humans), `source` (closed, below: the evidence that decided it), `subject` (file, target, phase
or setting; null for `unknown`), `evidence` (`<source>: <detail>` lines of the primary evidence), `secondaryEvidence`
(`<source>: <detail>` of later-precedence evidence that also matched; kept, never counted), `tasks` / `tasksTotal` /
`tasksShownShare` (by seconds, `--top`; html all), `seconds` (Σ task time of its tasks, including tasks rebuilt through a
`ruleInputRebuilt` chain rooted at it), `pathSeconds` (Σ critical-path seconds; null without a path), `ruleId` (the rule
that explains it: `PHASE-001` for a script without outputs, `DYN-002`, `DYN-005`, `ENV-008`; null when none).

**CauseTask** (also used by `fixedCosts[].tasks`): `key` (task key or null), `label` (`Explain.label` style, no command
line), `target`, `kind` (`TaskKind` raw value), `seconds`, `pathSeconds` (0 off the path, null without a path), `taskId`
(model id; null when re-rendered from history).

**Classes** (`Incremental.classes`, `CauseClass`, display order): `inputChanged` (an input file's content changed: an
edit, `--touch`), `scriptPhase` (no declared outputs, `alwaysOutOfDate`, no inputs), `settingsChanged` (signature
digest or command line differs), `upstreamInterface` (a dependency's emitted module changed), `timestampChurn` (mtime
newer, content hash equal: DYN-002), `planning` (re-plan without compiles; 2+ macro plugins per module on Xcode 26.x,
ENV-008 / DYN-003), `firstBuild` (`ruleNeverBuilt`, or no previous counterpart under `previousIndex`), `forced`
(`ruleForced`, `ruleHadInvalidValue`), `driverRemark` (only a `-driver-show-incremental` remark explains it), `unknown`.

**Sources** (`Incremental.sources`, `EvidenceSource`, the precedence of §6.6, first wins): `backtrace` (1),
`script` (2), `signature` (3), `upstreamInterface` (4; Xcode 27.0 false trigger swift-driver#2214 → `DYN-005`),
`mtimeChurn` (5), `planning` (6), `driverRemark` (7), `unknown` (8). A backtrace of kind `ruleInputRebuilt` points at
the upstream task (`CauseEvidence.rootTaskId`); the engine follows it to the root and the task joins the root's cause.

### Cause attribution (engine)

- `CauseEngine.attribute(document:context:)` runs every `CauseEngine.providers` entry (one `CauseEvidenceProvider` per
  `EvidenceSource`) over a `CauseContext` (model, executed task ids, current rows, `PreviousIndex`,
  `TaskIdentity.Match`es, `ProjectModel?`, `OutputHashes.Capture?`, inferred Xcode). Providers are pure, independent and
  never run processes; the engine keeps per task the lowest-precedence-number evidence as primary.
- `TaskIdentity.match` matches current to previous rows: by task key first (same key, different `sigDigest` is the
  `signature` signal), then `(rule, target, sigDigest)` as a multiset.
- `CauseEngine.attach(to:model:historyDir:project:)` is the command-level step of `analyze` and `build`: it reads the
  previous index (`History.previousIndex`) **before** the current build is saved, attributes, and applies the result with
  `ReportDocument.applying(incremental:)` (which also replaces the V15 row). It never throws: a failure leaves
  `incremental` null with a note. `project` is nil in phase 1 (the rules load the project after the pipeline); the
  script provider may load `ProjectModel` itself from the container the log names (`ProjectLocator`), best effort.

### V15

`V15.evaluate(sumOfCauses:executedSeconds:)` → `pass` when `|sum - executed| ≤ V15.toleranceSeconds` (0.001), else
`fail`; `skipped` while not computed. `Validator.checkV15(_:executedSeconds:)` maps it to the Validator row: `pass`,
`fail` (degrades the report, §6.11), or `notApplicable` with a note when `incremental` is null. Phase 1 returns
`notApplicable` with `skipped: incremental attribution not produced yet (v0.5)` (the Validator has no `skipped` status;
`skipped` exists only in `incremental.v15.status`).

### `fixedCosts` (DESIGN §6.8)

One row per class, largest `seconds` first, then classes with null seconds.

| Member | Meaning |
|---|---|
| `class` | Open vocabulary, `FixedCost.classes`: `scripts`, `codesign`, `validate`, `embedCopy`, `infoPlist`, `appIntents`, `executionPolicy`, `planning`, `sdkStatCache` (first build in a DerivedData only), `packageResolution`, `swiftPlanning`, `macroBuilds`, `outsideLog`. |
| `seconds` | Task time of the class in this build; null for a `static` row whose tasks did not run here. |
| `perDay` | `seconds × perDayAssumedBuilds`; null when `seconds` is null. |
| `perDayAssumedBuilds` | Builds per day behind `perDay`. |
| `perDayBasis` | `history` (this scheme's builds per day over the last 14 days of history), `config` (`buildsPerDay` in `<xcblame-dir>/config.json`), `assumed` (50). The HTML and text label `assumed` as "assumption". Precedence: config, then history, then assumed. |
| `basis` | `zeroChange` (executed in a zero-change build), `historyFrequency` (in > 80 % of this scheme's incremental builds in history, ≥ 5 builds), `static` (scripts without outputs, upload scripts, linters, build-tool plugins). |
| `tasks`, `tasksTotal`, `tasksShownShare` | The class's tasks (`CauseTask`), `--top`. |

`FixedCosts.compute` (inside the pipeline) gives `zeroChange` and `static` rows with `assumed` per day;
`FixedCosts.applyingHistory(to:historyDir:configURL:)` (after the pipeline, in `analyze` and `build`) adds
`historyFrequency` rows and re-bases `perDay`. A clean build has rows too (planning, SDK stat cache, scripts).

### `moduleGraph` (DESIGN §6.9, §8.2.2)

| Member | Meaning |
|---|---|
| `source` | `targetGraph` (`target-graph.txt` of the matched description), `project` (integration: `PBXTargetDependency` and linked package products of an `.xcodeproj` named by `--project` / `-project` or by the log's DerivedData, read-only, only without a target graph), `log` (task targets, no edges), `none`. |
| `targets`, `depth` | Target count; longest dependency path in edges (null without edges). |
| `longestChain`, `longestChainSeconds` | `[{target, seconds}]` root first, weighted by on-path seconds; empty / null without a critical path. |
| `fanIn`, `fanOut` | Top 10 `{target, count}`. |
| `umbrellaCandidates` | Fan-in > 50 % of the targets. |
| `cycles` | `[[String]]`, each cycle's targets; empty when acyclic. |
| `blockers` | Top 10 `{target, gatedSeconds}`: task seconds of dependents that start after the target's emit-module (else last task) ends. |
| `macroPluginsPerModule` | `{module, plugins, names}` from `-load-plugin-executable <path>#<Name>` in the module's Swift command lines; most plugins first. |
| `variants` | Null without a modules report (note). `{modules, pcmTasks, redundantTasks, redundantSeconds, causes, perModule, perModuleTotal, perModuleShownShare}`; `perModule[]` = `{module, variants, flags, causes, pcmTasks, redundantSeconds}` for modules with ≥ 2 variants. `causes` closed: `languageMode` (`-fapinotes-swift-version`, `__swift__`), `swiftPackage` (`SWIFT_PACKAGE`), `macros` (other `-D`), `other`. Redundant = beyond the first variant (V12). |
| `criticalChain` | Target names of the critical chain, root first. |
| `nodes`, `nodesTotal`, `nodesShownShare` | `{id, name, owner, depth, variants, macroPlugins, onPathSeconds, taskTime, collapsed}`. Past `ModuleGraph.nodeCap` (300) targets, targets outside the critical chain and its direct neighbours fold into one node per owner: `id` `more:<owner>`, `name` `N more modules (<owner>)`, `collapsed` N. `nodesShownShare` = plain nodes / `nodesTotal`. |
| `edges`, `edgesTotal`, `edgesShownShare` | `{from, to, critical}` over node ids (`from` depends on `to`); edges into a collapse group are merged. `critical` when both ends are consecutive on `criticalChain`. |
| `notes` | Source fallbacks, missing modules reports. |

The HTML budget (§8.2.3 step 4) calls `HTMLReporter.collapsedModuleGraph(_:keep:)` from `ReportBudget.Pass.moduleGraph()`
(floor: the critical chain); totals never change.

### `deep` and `build --deep` (DESIGN §5.8, §6.4, §7.5)

| Member | Meaning |
|---|---|
| `enabled` | False when `--deep` aborted before building (a target lost a pre-existing flag in the oracle check, MV-3; the probe failed): the build then ran without deep flags in the user's DerivedData and `notes` says why. |
| `scope` | `swift` / `clang` (canonical order). |
| `flagsInjected` | Flags as delivered (`-Xfrontend -debug-time-function-bodies`, `-Xfrontend -debug-time-expression-type-checking`, `-Xfrontend -stats-output-dir -Xfrontend <dir>`, `-ftime-trace`, `-ftime-trace-granularity=500`). |
| `flagsDropped` | `{flag, reason}`: not supported by the toolchain (not in its help text, or the probe failed); empty when every flag of the scope is supported. |
| `flagsNotInjected` | `{flag, reason}` (integration): supported flags left out on purpose, the `-warn-long-*` pair "off by default" (warnings-as-errors projects would fail, [OC] A20). |
| `shadowed` | `<target>: <KEY>` whose effective value did not change with the wrapper: "shadowed (command line did not win, MV-3)", not counted as injected. |
| `derivedData`, `derivedDataBytes` | The deep DerivedData and its size. |
| `wrapper` | `.xcblame/tmp/wrapper-<Config>.xcconfig`. |
| `exactFiles` | `{rebuiltTargets, note}` with `--exact-files`, else null. `note` always says the build shape changed. |
| `sources` | `{debugTime, warnLong, statsDir, ftimeTrace}`: rows each reader produced before the user-code filter and dedupe. |
| `notes` | Probe results, oracle check, reader failures. |

**Deep DerivedData**: `DeepDerivedData.directory(for: container, home: OracleCache.home())` =
`<home>/deep/<first 16 hex of sha256(container path)>/` (`~/Library/Caches/xcblame/deep/...`, `$TMPDIR/xcblame/deep/...`
when that is not writable, `XCBLAME_CACHE_DIR` respected). DESIGN §5.8's `dd-deep/<project-hash>/` is replaced by
this. Entries carry a marker file and are pruned with the oracle-cache rules (`keepDays` 30, least recently used first
past `DeepDerivedData.maxBytes` 20 GiB) by `history prune` and `build --deep`; the build passes
`-derivedDataPath <dir>` (a user `-derivedDataPath` with `--deep` is a usage error, exit 2).

**Wrapper xcconfig** (§7.5, shared with v0.6 `--overlay`): `WrapperXCConfig.plan` writes
`<xcblame-dir>/tmp/wrapper-<Config>.xcconfig` (`<Config>` = `-configuration`, else `Default`); `tmp/` joins
`.xcblame/.gitignore` (`stateIgnoreLines`, the old text in `previousStateIgnores`). Contents, in order: `#include` of the
user's own `-xcconfig <file>` (removed from the arguments), `#include` of `$XCODE_XCCONFIG_FILE` (then unset for the
child), `#include` of the overlay (v0.6), then the injected lines `OTHER_SWIFT_FLAGS = $(inherited) ...` /
`OTHER_CFLAGS = $(inherited) ...`, each ending `// xcblame --deep`. The arguments gain `-xcconfig <wrapper>`.

**Toolchain probe**: `ToolchainProbe.run(probe:)` runs `xcrun swift-frontend -help` (and `-help-hidden` when a flag is
missing from `-help`) and `xcrun clang --help` through an injectable `EnvSnapshot.Probe`, 10 s each; a flag missing from
both is dropped with a reason. Never runs xcodebuild.

**Oracle check**: before building, the settings oracle runs without and with the wrapper (lane A may add
`Settings/SettingsOracle+Wrapper.swift` for the `-xcconfig` pass-through); `WrapperXCConfig.check` lists shadowed keys
and lost flags. Any lost flag aborts `--deep` (`deep.enabled = false`). Tests never run xcodebuild against real projects:
fixtures only, scratch DerivedData, `XCBLAME_XCODEBUILD` fakes.

**Readers** (pluggable, adapt to MV-6 / MV-7 in the probe doc): `StatsDirReader.read(directory:model:)` and
`FTimeTraceReader.read(counted:model:)` return `HotspotValue` rows with `source` `statsDir` / `ftimeTrace`. File-level
rows have `line` 0 and `col` 0 and are deduped per `file:0:0:source`; located rows dedupe by `file:line:col` like the
debug-time rows. `Hotspots.mergeDeep` merges them (user-code filter, weight 1 on path / 0.25 off, §6.5) and returns
`deep.sources`. Hotspot `source` vocabulary is now `debugTimeFunctionBodies`, `debugTimeExpression`, `warnLong`,
`statsDir`, `ftimeTrace`.

**`estimated` file rows** (§6.4): `FileAttribution.estimatedRows` splits a batch's seconds by each member's share of
the batch's type-check ms, one row per member with `granularity` `estimated`, `batchSize` and `taskId` of the batch; the
batch row stays; V9 never sums `estimated` with `exact`. The `files` note names the estimated rows.

**`--exact-files`**: after the deep build, `ExactFiles.plan` picks the targets of the top `ExactFiles.topK` (5) batches
and rebuilds only them in the deep DerivedData with `SWIFT_ENABLE_BATCH_MODE = NO` added to the wrapper; the report is of
that second build, `deep.exactFiles` names the targets and says the build shape changed.

### Build kinds and `build.cache` (DESIGN §6.7)

- `BuildKind.vocabulary`: `clean`, `incremental`, `zero-change`, `clean-action`, `cached`, `index`, `previews`,
  `analyze`, `archive`, `test`. `cached` and `previews` are produced by lane C in `BuildKind.cachedOrPreviews`
  (checked right after `index` / action and before the count rules): `previews` from the Previews arena (description
  directory path under `.../Previews/...` or a previews build request, MV-17), `cached` when `build.cache.hits > 0`.
  Previews, index and analyze stay out of trends and baselines by default (unchanged rule; lane C adds `previews` to the
  exclusion where `index` is excluded today, if anywhere).
- `build.cache`: `{hits, misses, replayedTasks, replayedTasksHeuristic, source}`; `source` closed: `buildOperationMetrics`,
  `casRemarks`, `history` (the replay heuristic alone). `replayedTasks` (integration) is exact: the tasks whose own
  output is `Cache hit` (MV-12), null when no task printed `Cache hit` or `Cache miss`. `replayedTasksHeuristic` is the
  labelled heuristic of §6.7 (a compile with cache-hit remarks, or < 5 % of its previous duration with an unchanged
  signature); never a per-task fact, and null whenever `replayedTasks` is set. `CacheMetrics.compute(model:counted:)`
  reads MV-12's counters.

## History task index (DESIGN §8.3)

`History.TaskIndexRow` keeps its 7-element array `[key, rule, target, kind, sigDigest, durationMs, onPath]`. When `why`
captured any hash for the task, three trailing elements follow: `outputHash` (first 16 hex of SHA256 of the emitted
`.swiftmodule`, or `.abi.json` when present; emit-module tasks), `outputBytes`, `inputHashes` (`{portable path: 16 hex}`
with paths normalized by `History.portable`, executed tasks only); each may be null. Rows without them stay 7 long, so
entries written before v0.5 and by `analyze` / `build` are unchanged. `OutputHashes.capture(model:derivedData:)` makes
the capture; `History.save(document:model:directory:capture:)` writes it; `History.previousIndex(for:directory:)` finds
the newest entry of the same build key that is not the document's own log.

## `xcblame why` (DESIGN §3.2, §6.6)

```
xcblame why [--touch <file>] [--show-incremental] [--backtraces] [--log <path>] [--timeout <s>]
            [--xcblame-dir <dir>] [--format text|json|html] [-o <file>] [--open] [--browser <app>] [global flags]
            [-- <xcodebuild args>]
```

- **With xcodebuild arguments** (`WhyProcedure.run`): settle build, then the measured build: unchanged (`mode`
  `zeroChange`) or after touching `--touch <file>` (`mode` `touch`, mtime only, content untouched). Each build runs
  through `XcodebuildRunner` (snapshots, logs, `XCBLAME_XCODEBUILD`); the settle build is saved to history with its
  capture (`OutputHashes`), and the measured build is attributed against the settle build's index (`basis`
  `previousIndex`), then saved with its own capture. In `zeroChange` mode, when the measured build executed compile or
  plan tasks (`BuildKind.workKinds`), one more zero-change build (`role` `repeat`) runs; if it also executes them, a
  `DYN-002` finding is added (built directly in `Why/`, rule text from RULES.md DYN-002, `ruleDocs["DYN-002"]`; the rule
  catalog is not changed in v0.5).
- `--show-incremental` adds `OTHER_SWIFT_FLAGS = $(inherited) -driver-show-incremental` on every build of the
  procedure, so remarks become `driverRemark` evidence (MV-8): on the command line (appended to a command-line
  `OTHER_SWIFT_FLAGS=` when the arguments have one), or as a wrapper line when the arguments already pass an xcblame
  wrapper (`-xcconfig <xcblame-dir>/tmp/wrapper-*.xcconfig`; integration, see "Integration notes").
- `--backtraces`: `EnableBuildBacktraceRecording=YES` in the environment of every xcodebuild of the procedure (MV-2:
  works on 26.0.1 and 27.1, writes no file; the settle build uses the same mechanism as the measured one). The phase-1
  plan of a temporary `.xcblame-<name>.xcscheme` copy is obsolete (a scheme file starting with `.` is not listed, and
  the attribute exists only on 27.1); the user's scheme is never edited.
- **Without arguments**: the latest log of the project in the current directory (or `--log <path>`, anything `analyze`
  reads) is explained against `History.previousIndex`; `procedure` is null; a log with no previous entry gives
  `basis` `currentLogOnly`. Nothing is built.
- Output: the report document (all members) with `incremental` filled; text prints the header, INCREMENTAL CAUSES,
  critical path, targets, validation; html shows sections 1, 7, 2, 3, 10 (`HTMLReporter.renderWhy`, title
  `xcblame why`, file kind `why`). `--format markdown|github|junit|agent` is a usage error in v0.5.
- `--touch`, `--show-incremental` and `--backtraces` need xcodebuild arguments; `--log` with arguments is a usage error.

**Exit codes** (DESIGN §8.4, unchanged table): 0 success (whatever the causes); 1 internal error, analysis unavailable,
a failed validation check (V15 `fail` included), or the procedure aborted because a build failed, timed out or wrote no
log (stderr names the build role and xcodebuild's code; 6 stays reserved for `verify`); 2 usage; 5 no log found or not
readable (without arguments). `build` keeps its own rules (xcodebuild's code by default).

**`build --runs <n> --kind clean|incremental|zero-change --touch <file>`** (lane B): `WhyProcedure.prepare` before each
measured run: `clean` runs `xcodebuild clean` with the same arguments, `zero-change` builds once first, `incremental`
builds once then touches `--touch` (required with `--kind incremental`; `--touch` alone means `incremental`). `--runs n`
repeats prepare + build n times, analyzes and saves each run, and prints / writes the last run's report plus one line per
run; exit code is the worst xcodebuild code (default mode). Every run lands in history, so `baseline save --last n`
gets its medians.

## JSON Schema

The mirror tables in `Reporters/Schema/JSONSchema.swift` carry every v0.5 member (`Incremental`, `IncrementalCause`,
`CauseTask`, `IncrementalV15`, `IncrementalProcedure`, `ProcedureBuild`, `IncrementalPreviousBuild`, `FixedCost`,
`ModuleGraph` and its parts, `Variants`, `ModuleVariant`, `GraphNode`, `GraphEdge`, `Deep`, `DeepDroppedFlag`,
`DeepExactFiles`, `DeepSources`, `BuildCache`). Closed enums listed: `Incremental.basis`, `classes`, `sources`,
`v15.status`, `procedure.mode`, `procedure.backtraces`, `ProcedureBuild.role`, `FixedCost.perDayBasis`, `.basis`,
`ModuleGraph.source`, variant causes, `deep.scope`, `BuildCache.source`. Open: `FixedCost.class`, kinds, rule ids.
Lanes do not edit the schema file: a member change goes to the integrator as a note, with the sample in
`V05Samples` (the strict validator test fails on a member the table forgot).

## Text

`TextReporter.render` calls, after the hotspots and before the findings: `incrementalLines` (lane B,
`TextReporter+Why.swift`), `fixedCostLines` and `moduleGraphLines` (lane C, `TextReporter+Graph.swift`). Each returns
`[]` when its member is null. INCREMENTAL CAUSES: one line per cause of `byTaskTime` (top `topN`, then `unknown` always),
`seconds`, share of executed time, `pathSeconds`, `ruleId`; a second line `by path seconds: …`; then `V15 pass|fail`.
FIXED COSTS: class, seconds, per day, `(assumption: 50 builds/day)` when `assumed`. MODULE GRAPH: targets, depth,
longest chain, top blockers, variants summary (`64 modules, 79 redundant PCM tasks, 7.6 s`).

## HTML views (DESIGN §8.2.4 #7-#9)

> **Amended 2026-11-08 (cockpit, DESIGN §8.2.5 "Cockpit decision"):** the ids, `data-*` attributes and
> `data-total` / `data-shown` contracts below are unchanged; only the presentation changed (light theme, sections
> collapsed under a first screen, no index bar, no glossary or what-lines, definitions in docs/REPORT.md).

Template regions (each lane edits only its own; `make template` regenerates `ReportTemplate.swift`, a conflict there is
resolved by regenerating, never by hand): markup `<!-- xcblame:why:start -->` … `end` (and `fixedcosts`,
`modulegraph`) between `#findings` and `#environment`; CSS `/* xcblame:<name>:css:start */` … `end` after the trend CSS;
JS `// xcblame:<name>:js:start` … `end` after the trend JS, holding `function renderWhy(doc)`,
`function renderFixedCosts(doc)`, `function renderModuleGraph(doc)`. The shared helpers (`el`, `$`, `int`, `secs`,
`pct`, `makeTable`, `setCounts`, `naLine`, `copyText`, `reportError`) are in scope. Rules of §8.2.6 apply: data strings
as text only, no network, tables page at 200 rows, no DOM node per task.

**Dispatch (shared code, frozen)**: the three sections start `hidden`. For an `xcblame.report` document the index adds
them before Environment, each only when its member is non-null (`D.incremental`, `D.fixedCosts`, `D.moduleGraph`),
unhides it and renders it lazily like the other sections. A **why document** (`D.incremental.procedure != null`) shows
sections 1, 7, 2, 3, 10: `#why` is moved after `#summary`, and `#files`, `#hotspots`, `#findings`, `#fixedcosts`,
`#modulegraph` stay hidden. Each section's own `data-total` / `data-shown` are set by its render function.

### DOM contract: why (`#why`)

`#why` has `data-total` = `incremental.causes.length` and `data-shown` = cause rows rendered in the active ranking tab.
Inside `#why-body`:

| Id / selector | Content | `data-total` |
|---|---|---|
| `#why-summary` | basis, previous build id and time, executed seconds, procedure (mode, touched file, builds, backtraces) | |
| `#why-v15[data-status]` | V15 status (`pass` / `fail` / `skipped`) with `executedSeconds` and `sumOfCauses` | |
| `#why-unknown[data-share]` | the unknown row, always visible: seconds, share, and the `xcblame why --backtraces -- …` hint as copyable text | |
| `#why-tabs` | two buttons `[data-tab="task"]`, `[data-tab="path"]` (`aria-selected`), never a summed column | |
| `#why-by-task`, `#why-by-path` | one `[data-row][data-cause-id]` per id of `byTaskTime` / `byPathSeconds` | `byTaskTime.length` / `byPathSeconds.length` |
| `#why-tree` | `details.why-class[data-class]` per class present (order of `Incremental.classes`) → `.why-cause[data-cause-id]` (cause, source badge, seconds, path seconds, ruleId) → a `makeTable` of its `tasks` (`[data-row]`, paged) | per cause: `tasksTotal` on `.why-cause` |
| `#why-notes` | `incremental.notes` | |

### DOM contract: fixed costs (`#fixedcosts`)

`#fixedcosts` has `data-total` = `fixedCosts.length`, `data-shown` = rows rendered. Inside `#fc-body`: `#fc-table` (a
`makeTable`: class, basis badge, seconds, per day, builds/day with `.fc-assumption` "assumption" label when
`perDayBasis == "assumed"`; one `[data-row][data-class]` per row, expandable to its tasks); `#fc-total[data-seconds]`
(Σ non-null seconds, never shown as a per-build saving); `#fc-notes`.

### DOM contract: module graph (`#modulegraph`)

`#modulegraph` has `data-total` = `moduleGraph.nodesTotal`, `data-shown` = plain (non-collapsed) nodes drawn. Inside
`#mg-body`:

| Id / selector | Content | `data-total` |
|---|---|---|
| `#mg-summary` | source, targets, depth, cycles count, longest chain seconds | |
| `#mg-zoom-in`, `#mg-zoom-out`, `#mg-reset` | buttons; reset is 1:1 at the origin | |
| `svg#mg-svg` > `g#mg-viewport[transform]` | the layered graph | |
| `.mg-node[data-id][data-depth][data-owner]` | one `<g>` per node (rect + text, `<title>` with name, owner, seconds), badges `.mg-variants`, `.mg-macros` when > 0 | |
| `.mg-node.mg-collapsed[data-count]` | a collapse group | |
| `.mg-edge[data-from][data-to]` | one path per edge; `.mg-critical` for `critical` edges (color, width and a dash pattern: color never alone) | `edgesTotal` on `svg#mg-svg` as `data-edges-total` |
| `#mg-chain` | `longestChain` as an ordered list | |
| `#mg-fanin`, `#mg-fanout`, `#mg-blockers`, `#mg-macros`, `#mg-cycles` | small tables / lists | their lengths |
| `#mg-variants` | `makeTable` of `variants.perModule` (`[data-row]`), header "shown N of `perModuleTotal`"; "not applicable: <note>" when `variants` is null | `perModuleTotal` |
| `#mg-table` | the accessible equivalent of the SVG: one `[data-row]` per node | `nodes.length` |
| `#mg-notes` | `moduleGraph.notes` | |

**SVG pattern** (the xcpurge pattern of DESIGN §8.2.4 #9): layer = `depth` (leaves at 0, drawn left to right or bottom
to top), nodes in a layer ordered by the barycenter of their neighbours (two sweeps), edges as cubic Bézier paths;
everything inside one `<g id="mg-viewport" transform="translate(tx ty) scale(k)">`. Zoom buttons multiply `k` by 1.25 /
0.8 around the viewport centre; ⌘/Ctrl + wheel zooms around the cursor and a plain wheel scrolls the page (v0.5
decision, the xcpurge behaviour); pointer drag pans (pointer capture, no text
selection); reset sets `translate(0 0) scale(1)`. The transform is written with `setAttribute` only. Clicking a node (or
Enter on its focused `<g tabindex>`) calls the page's `openTarget(name)`, the Targets drawer. Above 300 targets the
document already holds collapse groups; the page never collapses on its own. Print: the SVG prints as is (no canvas).

## Planted-cause fixture (`fixtures/projects/AcmeWhy/`, lane B)

Generated by `Scripts/make-why-fixture.sh` (idempotent, no network, no signing); the generated tree is committed so
tests need no script run. It is built only by opt-in tests (`XCBLAME_E2E=1`) with `xcodebuild -derivedDataPath
<scratch> CODE_SIGNING_ALLOWED=NO` for `platform=macOS`; never against a real project.

- Targets: `AcmeWhyApp` (macOS app, depends on `WhyKit`), `WhyKit` (framework, depends on `WhyCore`), `WhyCore`
  (framework), plus a local package `Packages/WhyUtils` (library product used by `WhyKit`).
- Planted causes and the build that shows each (expected primary cause, `expected.json`):
  1. Script phase `Stamp` in `AcmeWhyApp` with inputs and **no outputs** → every zero-change build: class
     `scriptPhase`, source `script`, `ruleId` `PHASE-001`.
  2. `--touch WhyCore/Core.swift` → class `inputChanged`, source `backtrace` when MV-2 allows, else `signature` /
     `mtimeChurn` per the probe doc; the dependents' rebuilds join it as root.
  3. A settings flip: `WHY_FLAG` in `Config/Why.xcconfig` read by `OTHER_SWIFT_FLAGS = $(inherited) -D$(WHY_FLAG)`;
     the script toggles it (`make-why-fixture.sh --flip`) → class `settingsChanged`, source `signature`.
  4. Two macro plugins on one module: **not buildable offline** (a `.macro` target needs swift-syntax, which is not
     available without network), so planted only as a static case: `Packages/WhyMacros/Package.swift` declares two
     `.macro` targets used by `WhyKit` in the ProjectModel, never built; lane C's tests read it through
     `ProjectModel.load` and a synthetic model whose Swift command lines carry two `-load-plugin-executable` flags
     (`macroPluginsPerModule`, ENV-008 / `planning` evidence), and `expected.json` marks it `static`.
- `expected.json`: `[{scenario: "zeroChange"|"touch"|"flip", primaryCause: {class, source, subject, ruleId},
  minShare: 0.9}]` plus `{scenario: "macroPlugins", static: true, module: "WhyKit", plugins: 2}`. Exit criterion
  (DESIGN §11 v0.5): the planted cause is primary for ≥ 90 % of executed task time, V15 holds, the unknown share is
  reported.

## Frozen CLI wiring (done in phase 1)

- `xcblame why` registered (`Sources/xcblame/WhyCommand.swift`), flags and usage checks as above; `run` throws
  `notImplemented` (exit 1) inside the `// v0.5 lane B` block.
- `build` accepts `--deep`, `--deep-scope swift,clang` (needs `--deep`; parsed by `DeepScope.parse`), `--exact-files`
  (needs `--deep`), `--runs n` (≥ 1), `--kind clean|incremental|zero-change` (`incremental` needs `--touch`), `--touch
  <file>`. `--deep` → `notImplemented("build --deep (v0.5 lane A)")`; `--kind`, `--touch` or `--runs > 1` →
  `notImplemented("build --runs/--kind/--touch (v0.5 lane B)")`, both before xcodebuild runs. `--overlay` is v0.6.
- `ReportPipeline.Options.deep: DeepRun?` carries a deep build into the pipeline (`Explain.run(…, deep:)`,
  `ReportDocument.make(…, deep:)`); `ReportDocument.applying(incremental:)` sets `incremental` and the V15 row.
- Marked blocks (`// v0.5 lane X (begin)` … `(end)`), each lane edits only its own:
  - Lane A: `BuildCommand.run` (`--deep`), `Explain.run` (`Hotspots.mergeDeep`, `FileAttribution.estimatedRows`,
    `deepSources`), `ReportDocument+Make` (`document.deep`).
  - Lane B: `BuildCommand.run` (`--kind/--touch/--runs`), `BuildCommand.analyze` and `AnalyzeCommand.run`
    (`CauseEngine.attach` before history save), `WhyCommand.run`.
  - Lane C: `Explain` (`CacheMetrics`, `FixedCosts.compute`, `ModuleGraph.compute`), `BuildKind.classify` and
    `cachedOrPreviews`, `ReportDocument+Make` (the not-produced note, `fixedCosts`, `moduleGraph`, `build.cache`),
    `BuildCommand.analyze` and `AnalyzeCommand.run` (`FixedCosts.applyingHistory`), `ReportBudget.Pass.run` and
    `moduleGraph()`.
- Stubs throw `XcblameError.notImplemented("<what> (v0.5 lane X)")` where the real function may fail (I/O, process);
  pure engines return nil / `[]` / their input unchanged. Each lane replaces its `*StubTests` and CLI stub tests.

## File ownership and lane notes

**Shared files nobody edits after phase 1** (a change request goes to the integrator): `Reporters/ReportDocument.swift`,
`Reporters/ReportPipeline.swift`, `Reporters/Nullable.swift`, `Reporters/Schema/JSONSchema.swift` (members via a note),
`Reporters/HTML/ReportTemplate.swift` (regenerated after the merge), `Resources/report.html` outside the marked
regions, `Sources/xcblame/{GlobalOptions,Xcblame,ExitCode}.swift`, `History/History.swift` (`TaskIndexRow` is frozen),
`Build/StateFiles.swift`, `docs/SCHEMA-v0.5.md`, `Tests/XcblameKitTests/{StubSupport.swift,
Reporters/SchemaV05ContractTests.swift, HTMLTemplateV05Tests.swift}`, `Tests/xcblameTests/CLIRunner.swift`. Files with
marked blocks of several lanes (`Explain.swift`, `ReportDocument+Make.swift`, `BuildCommand.swift`,
`AnalyzeCommand.swift`) are edited only inside one's own blocks.

### Lane A: Deep

Owns `Deep/*`, `Graph/Hotspots+Deep.swift`, `Graph/FileAttribution+Estimated.swift`, optionally
`Settings/SettingsOracle+Wrapper.swift` (new), the `// v0.5 lane A` blocks, tests `Deep*` (kit and CLI). Notes:
- `build --deep` flow: `DeepScope.parse` → `ToolchainProbe.run` → `DeepFlags.plan` → `DeepDerivedData.prepare` →
  `WrapperXCConfig.plan` + oracle `check` (abort on a lost flag) → `write` → the existing `XcodebuildRunner.run` with the
  rewritten arguments (`-derivedDataPath <deep dir>`, `-xcconfig <wrapper>`) → `--exact-files` second build → set
  `options.deep` in `BuildCommand.analyze`'s pipeline (`DeepRun`). `XcodebuildRunner` itself needs no change beyond
  `unsetEnvironment` (add an `environment:` parameter in a `// v0.5 lane A` block if needed).
- The readers return unfiltered `HotspotValue` rows; filter and rank in `mergeDeep`. Fixtures for stats-dir and
  ftime-trace JSON go in `fixtures/deep/` (synthetic, small), shaped after the probe doc.
- Update the `files` note in your `ReportDocument+Make` block only if you add one; otherwise ask the integrator to
  drop "estimated rows not produced" when the rows land.
- `history prune` should also prune the deep cache (`DeepDerivedData.prune`): one call in `HistoryCommand.swift` next
  to the oracle-cache prune, marked `// v0.5 lane A`.

### Lane B: Why

Owns `Why/*`, `Sources/xcblame/WhyCommand.swift`, `History/History+Why.swift`, `Analyzers/ValidatorChecks+V15.swift`,
`Reporters/HTML/HTMLReporter+Why.swift`, the why template regions, `Reporters/TextReporter+Why.swift`,
`Scripts/make-why-fixture.sh`, `fixtures/projects/AcmeWhy/`, the `// v0.5 lane B` blocks, tests `Why*`, `Cause*`,
`V15*` (kit and CLI). Notes:
- `attach` must read the previous index before `saveHistory` (the blocks are placed so); under `build --runs`, run i
  compares with run i−1.
- Every executed task in exactly one cause; V15 on the full model; `unknown` always present.
- DYN-002 is a `Finding` built in `Why/` (no catalog change); add `ruleDocs["DYN-002"]`.
- The HTML why view is the report page (sections 1, 7, 2, 3, 10 by the shared dispatch); `renderWhy` fills `#why-body`.

### Lane C: Graph

Owns `Graph/{FixedCosts,ModuleGraph,ModuleVariants,CacheMetrics}.swift`, the `cachedOrPreviews` body in
`Graph/BuildKind.swift`, `Reporters/HTML/HTMLReporter+Graph.swift`, the fixedcosts and modulegraph template regions,
`Reporters/TextReporter+Graph.swift`, the `// v0.5 lane C` blocks, tests `FixedCosts*`, `ModuleGraph*`, `Variants*`,
`CacheMetrics*`. Notes:
- Module graph and variants from the fixtures' snapshots (`fixtures/logs/cli-xcode26*` carry `xcbuilddata` with
  `target-graph.txt`; add modules-report CSVs under a fixture snapshot if none has them).
- Macro plugins from Swift command lines (`-load-plugin-executable`); the static two-plugin case of AcmeWhy is a
  ProjectModel/synthetic test.
- `fixedCosts` for a clean build is non-null (planning, SDK stat cache, scripts); `config.json` `buildsPerDay`
  (integer) is read by `applyingHistory`.
- Keep `nodes` ≤ 300 plain nodes in `compute`; the budget step collapses further only for size.

## Decisions taken in phase 1

- Deep DerivedData lives at `<cache>/deep/<sha16(container)>/` (not DESIGN §5.8's `dd-deep/<project-hash>/`), so it
  shares `OracleCache.home()` and its prune rules.
- `.xcblame/.gitignore` gains `tmp/` (the wrapper xcconfig); the v0.4 text is upgraded in place.
- V15 has no new Validator status: `notApplicable` with a `skipped: …` note until lane B; `skipped` exists only in
  `incremental.v15.status`.
- `incremental.causes` is never capped (tasks inside are); `unknown` is always the last cause.
- `deep` is null without a note when not requested; the other new members carry the null+note rule.
- History rows grow by three optional trailing elements only when `why` captured hashes; no digest version marker.
- `why` keeps DESIGN §8.4: a failed or timed-out procedure build is exit 1, not 6 (6 is `verify`).
- The three new HTML sections render only when their member is non-null, so phase 1 pages are unchanged.
- `why` without `--` takes `--log <path>` (not a positional argument, which would clash with the arguments after `--`).

## Integration notes (2026-11-02)

Lanes A Deep, B Why and C Graph merged onto the phase-1 skeleton; these are the contract changes the integration made.
`SchemaV05ContractTests` pins each member and `V05Samples` carries a populated sample of each.

**API additions**
- `XcodebuildRunner.run(…, environment: [String: String]? = nil, unsetEnvironment: [String] = [])`: `environment` is
  merged over xcblame's own environment for the child only, then every `unsetEnvironment` name is removed. `why
  --backtraces` passes `EnableBuildBacktraceRecording=YES` this way; `build --deep` removes `XCODE_XCCONFIG_FILE` this
  way once the wrapper includes it. Neither changes xcblame's process environment any more (the lanes used
  `setenv`/`unsetenv` with a restore).
- `build.cache.replayedTasks: Int?` (`@Added`): the exact count of `Cache hit` task outputs, next to the counters. The
  27.1 hit fixture has 113 counter hits and 112 `Cache hit` lines: `hits` 113, `replayedTasks` 112, kind `cached`, V11
  pass, and the kind evidence (so the V11 detail) says `task output "Cache hit": 112 replayed task(s) (1 counted hit(s)
  without a matching task line)`. The `cache: … replayed …` build note stays as the per-rule breakdown.
- `deep.flagsNotInjected: [{flag, reason}]` (`@Added`): the `-warn-long-*` pair, off by default. `deep.flagsDropped` now
  holds only flags the toolchain does not support, so it is empty on a current toolchain.
- `moduleGraph.source` gains `project`: without a target graph, `ReportPipeline.moduleGraphProject(explicit:logURL:
  description:)` loads the `.xcodeproj` named by `analyze --project` / `build … -project`, else the one the log's
  DerivedData names, with `ProjectModel.load` (read-only), and `ReportPipeline.Options.project` hands it to
  `ModuleGraph.compute`. Edges are `PBXTargetDependency` names and linked package products whose both ends were built.
  Workspaces and packages keep `log`. `swift package show-dependencies` is never run (it writes into the package); a
  graph note says so. `ReportDocument.ModuleGraph.sources` is the closed list.
- `WrapperXCConfig.existing(in:xcblameDir:)` and `append(_:to:)`: `why --show-incremental` adds its line to an xcblame
  wrapper already on the arguments instead of a command-line setting. Precedence checked with `-showBuildSettings` on
  a copy of AcmeWhy (Xcode 26.0.1): the `-xcconfig` level sits above command-line `KEY=VALUE`, its `$(inherited)` takes
  the command-line value (`-DWHY_A -driver-show-incremental -DDEEP_WRAPPER`), and two assignments of one key in one
  xcconfig chain through `$(inherited)`. So both deliveries compose; the wrapper line keeps all injected flags at one
  level.
- `CauseEngine.pendingNote` replaces the phase-1 `not produced yet: incremental causes (v0.5)`; the `files` note names
  `estimated` rows (`estimated N rows (M batches split by type-check ms, not added to exact)`) or says why there are
  none, instead of `estimated rows not produced`.

**Limits of the previous-index comparison** (one `incremental.notes` line each, only when the build has tasks they touch)
1. `limit: N executed task(s) have no counterpart in build <id>, whose task index holds only the tasks that build ran;
   a settings change on them is invisible`.
2. `limit: N per-file Swift compile or driver job task(s) cannot be matched to build <id> by key (their keys change
   between builds); they are matched by rule, target and command digest only, and a per-file compile takes its module
   task's cause` (on the probe fixtures: the `SwiftDriverJobDiscovery` tasks).
3. `limit: N script task(s) are left out of the signature signal (a script's command exports the build environment,
   which differs per xcodebuild run)`.
The newest-entry contract of `History.previousIndex` is unchanged.

**HTML** The report page keeps ids unique across all sections (`HTMLTemplateV05Tests` checks an analyze page with all
three v0.5 members, a why page and a doctor page in headless Chrome: no JS error, no duplicate id, `data-total` on each
shown v0.5 section). Module graph wheel zoom: ⌘/Ctrl + wheel zooms at the cursor, a plain wheel scrolls the page
(xcpurge behaviour; DESIGN §8.2.4 v0.5 decision). The merged template was 153.8 KB, over the 150 KB budget; simple
callbacks became arrow functions and the v0.5 region comments were shortened (148.9 KB), with no behaviour change.

**Template budget (2026-11-02).** The clarity pass (DESIGN §8.2.5 clarity decision, [reviews/html-clarity-audit.md](reviews/html-clarity-audit.md)) raised the template budget to 240 KB (template 223 KB); the 8 MB file cap and every DOM contract of this document are unchanged.

**Opt-in end-to-end tests** `make e2e` runs `WhyE2ETests` and `DeepE2ETests` with `XCBLAME_E2E=1`.

## Clarity additions (2026-11-03, junior-reader review round 2)

Additive members (`@Added`, so saved reports decode); `SchemaTests` validates them in strict mode.

- `findings[].inXcode: [String]`: where to make the change in Xcode, one line per change, with the Build Settings
  labels of `XcodeSettingLabels` (`Build Settings › Compilation Mode (SWIFT_COMPILATION_MODE) for 4 targets, Debug:
  Whole Module → Incremental (singlefile)`), a Run Script phase step, a package dependency rule, or the `defaults
  write` line. Empty for generated projects (the evidence names the generator-source change) and when there is none.
- `findings[].estimatedBand: String?`: the rule catalog's band (`XS`/`S`/`M`/`L`, the first word of the catalog impact
  line) when `impactBand` is `?`; nil when the cost was measured or the catalog has no band. `RulePlan.isHousekeeping`
  is `effectiveBand == nil` (`effectiveBand` = measured band, else the estimate): confidence is shown on each action
  but never demotes a finding with a band, so an offline doctor lists the same actions as an online one; the catalog
  band ranks them (band, then severity, then confidence); text shows `~M`, markdown and HTML
  "estimated impact: M (catalog estimate, not measured on your build)".
- `fixPlan[].kind: String?`: `verify` / `fix` / `check` / `manual` / `command`. `ReportDocument.fixPlan(_:)` (replaces
  v0.3 invariant 4): findings in fix-plan order with every guard moved before the edits that assume it
  (`RulePlan.prerequisites`: PHASE-002 before SET-004, PHASE-001 before SET-030); each finding's `fixCommands` in
  order; `xcblame verify --rules <id> --mechanism cli` before a build-setting `--edit-project` that has no verify step;
  `xcblame build -- <your xcodebuild args>` (`check`) before a script-phase `--edit-project`; one `manual` step per
  `inXcode` line of a `recommend` finding without commands (`command` is then the Xcode change, not a shell command).
  `xcblame verify` and `xcblame fix` ship in xcblame 0.6 (`ReportDocument.isFutureCommand`): their steps carry the note
  `available in xcblame 0.6`, every output labels them, HTML keeps them (and any `<placeholder>` command) out of the copy
  buttons, and a finding with such commands gets its `inXcode` lines as `manual` steps first, the path you can run
  today. Text, markdown and HTML print "commit your changes first" above a plan with a project edit or a manual step
  (`ReportDocument.planEditsProject`). `RulePlan.isHousekeeping` (no measured or estimated band) splits the HTML
  plan and the "Start here" actions into actions and housekeeping.

- Compare (`xcblame.compare/1`, additive): `tasks.changed: [TaskChange]` (`rule`, `target`, `kind`, `title`,
  `seconds: ComparePair`, `onPath`), `tasks.changedTotal`, `tasks.changedShownShare`, `TaskRef.title`. Rows left over
  by the `(rule, target, sigDigest)` multiset match are paired by stable task key, then by `TaskIdentity.outputShape` (rule, target, title):
  a new Xcode rewrites every key and command line, so the same compile shows as changed, not as one new and one
  removed task (26.0 vs 27.1 fixtures: 405 new + 395 removed become 20 new, 10 removed, 385 changed).
  `History.TaskIndexRow.title` is in memory only (rows made from a model); history entries keep their layout, so a
  compare against a history entry pairs by digest only, and says so in a `tasks:` note.
- `incremental.causes[].whatToDo: String?`: one line on what to do ("Nothing to change: …" for Xcode's own work or an
  expected recompile). An `inputChanged` cause whose Swift compiles recompiled other files says so, counting the files
  of the edited file's own module (the target whose compile names it) without the file itself, and the files of other
  modules separately: `Your edit to Models.swift recompiled 16 other files of module LocalizeCore (since build <id>):
  files in the same module that depend on it were recompiled` (`CauseEngine.recompiled`); `whatToDo` says splitting
  the module or reducing dependencies on the file shrinks the blast radius (and, for other modules, to keep the
  module's public interface stable).
- V12 is evaluated when rules ran (`merge(rules:)`): `pass` when no finding's `impactSeconds` exceeds the build's task
  time (the log span when task time is unknown; rules measure task time as well as path seconds),
  `warn` naming the ones that do, `notApplicable` without a measured saving; the "land later (V12 v0.3, V15 v0.5)"
  validation note is now "checks marked not applicable had nothing to check in this report (each one says why)".
