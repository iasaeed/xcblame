# xcblame report schema: v0.2 members

The contract between the three v0.2 lanes. It lists every member added to the JSON report document in v0.2, its
type, when it is `null`, what it means, which lane fills it, and the invariant it must obey. The Swift types live in
`Sources/XcblameKit/Reporters/ReportDocument.swift` (nested in `ReportDocument`) and
`Sources/XcblameKit/Reporters/TaskIndex.swift`. `Tests/XcblameKitTests/Reporters/SchemaContractTests.swift` pins every
member name. Renaming, removing or retyping a member breaks the contract; a lane that needs a change stops and asks.

Lanes:
- **A**: build description and graph, critical path, what-if, utilization, attribution (files, hotspots), build kind,
  task index.
- **B**: `xcblame build` wrapper, process wall, history.
- **C**: HTML reporter, redactor, report budget and truncation, HTML output, saved-report re-render.

## General rules (unchanged from schema v1, DESIGN §8.1)

- `schemaVersion` stays `"xcblame.report/1"`. Every v0.2 member is additive.
- A `T?` member always serializes, as `null` when unknown (`@Null`); it is never omitted. Unknown is never `0`, `""`
  or `[]`. A `null` member has a reason in the nearest `notes` array.
- Every capped list `x` has `xTotal: Int` (rows before capping) and `xShownShare: Double?` (share of the measure the
  shown rows cover, `null` when the measure total is 0 or the list is `null`). When `x` is `null`, `xTotal` is `0`
  unless the rows were computed and then withheld (the v1 `targets` rule).
- Times are seconds as `Double`, rounded to 6 decimals (`round6`). Time points (`start`, `end`) are seconds from the
  session window start (`Analysis.sessionStart`), after clamping. Shares are fractions in [0, 1], not percent.
- Numbers withheld by a failed check (V1 withholds every timing number, V6 the rollups) are `null`, as in v1.
- Keys serialize sorted (`JSONReporter`). Two runs over the same input are byte-equal.

`--top`: an integer ≥ 1 or `all`. `all` is resolved to `Int.max` before the pipeline, so `topN` then serializes as
`9223372036854775807`. Default: 15 for text and json, `all` for html. A capped list is "complete" when
`x.count == xTotal`; renderers test that, not `topN`.

## Top level

| Member | Type | Null when | Meaning | Lane | Invariant |
|---|---|---|---|---|---|
| `graph` | `Graph` | never | Which build description the task DAG came from. | A | see Graph |
| `criticalPath` | `CriticalPath?` | no path computed (no timing, V1 failed, or engine not run) | Critical path over the session window. | A | V3 |
| `timing` | `TimingSection` | never | Sweep-line results of §6.3 beyond the `build` headline. | A (B: `processWall`) | see TimingSection |
| `files` | `[FileRow]?` | attribution not computed | Compile time per file, ranked by `seconds`, first `topN`. | A | V9 |
| `filesTotal` | `Int` | never | File rows before capping (0 while `files` is null). | A | `files.count ≤ filesTotal` |
| `filesShownShare` | `Double?` | `files` null or compile task time 0 | Σ shown `seconds` / Σ all file `seconds`. | A | in [0, 1] |
| `hotspots` | `[Hotspot]?` | no hotspot source in the log, or engine not run | Type-check hotspots, ranked by `ms × onPathWeight`, first `topN`. | A | deduped by `file:line:col` |
| `hotspotsTotal` | `Int` | never | Hotspot rows before capping. | A | `hotspots.count ≤ hotspotsTotal` |
| `hotspotsShownShare` | `Double?` | `hotspots` null or total ms 0 | Σ shown `ms` / Σ all `ms`. | A | in [0, 1] |
| `findings` | `[Finding]` | never (`[]` until v0.3) | Rule findings in fix-plan order. | v0.3 | `findings.count ≤ findingsTotal`; never dropped by truncation |
| `findingsTotal` | `Int` | never | Findings before capping. | v0.3 | |
| `ruleDocs` | `[String: RuleDoc]` | never (`{}` until v0.3) | `rules explain` text keyed by `ruleId`, only for rules present in `findings`. | v0.3 | keys ⊆ `findings[].ruleId` |
| `truncation` | `Truncation` | never | Ordered record of the budget pass. | C | `steps` empty unless a step removed rows |
| `redacted` | `Bool` | never | True once `Redactor.redact` ran on this document. | C | true ⇒ no `$HOME`, user, host, repo root or DerivedData hash string anywhere in the document |

`taskIndex` is **not** a document member: it is the separate `TaskIndex` value passed to `HTMLReporter.render` and
embedded in the HTML blob only (§8.2.2). `--format json` never contains it.

## `build` (added member)

| Member | Type | Null when | Meaning | Lane | Invariant |
|---|---|---|---|---|---|
| `build.kind` (v1) | `String?` | not classified | `clean` / `incremental` / `zero-change` / `clean-action` / `index` / `analyze` / `archive` / `test` (§6.7); `cached` and `previews` land with v0.5 (MV-17). | A | V11 |
| `build.kindEvidence` | `[String]` | never | Signals behind `kind`, strongest first, e.g. `"build-request.json action=build"`, `"0 reused tasks"`. | A | empty iff `kind` is null |

## Graph (`graph`)

| Member | Type | Null when | Meaning | Lane | Invariant |
|---|---|---|---|---|---|
| `basis` | `String` | never | `snapshot` (from `<xcblame-dir>/snapshots/<log-uuid>/`), `live` (DerivedData `XCBuildData/<signature>.xcbuilddata`) or `none`. | A | `none` ⇔ `signature`, `path`, `commands` all null |
| `signature` | `String?` | `basis == none` or the description has no signature | Build description signature (hex). | A | |
| `path` | `String?` | `basis == none` | Directory read (redactable path). | A | |
| `commands` | `Int?` | `basis == none` | Commands in `manifest.json`. | A | |
| `keyedTasks` | `Int` | never | Model tasks with a task key (`BuildTask.taskKey != nil`). | A (filled today) | `keyedTasks + unkeyedTasks == build.tasksInModel` |
| `unkeyedTasks` | `Int` | never | Model tasks without a task key. | A (filled today) | |
| `notes` | `[String]` | never | Why `none`, consistency-check failures (§6.2 step 5), match coverage. | A | |

Phase 1 fills `basis: "none"` and both counts. Until Lane A lands, a non-nil `BuildDescription` maps to
`basis: "live"` with a note; Lane A decides `snapshot` vs `live`.

## CriticalPath (`criticalPath`)

| Member | Type | Null when | Meaning | Lane | Invariant |
|---|---|---|---|---|---|
| `span` | `Double` | – | Path span: first segment start to last segment end. | A | `span ≤ build.span`; `Σ segments.seconds + Σ waits.seconds == span` (±1e-6 per item) |
| `basis` | `String` | – | `dag` (every segment `dag`), `inferred` (every segment `inferred`), `mixed` (anything else, e.g. `dag` + `byTiming`). | A | consistent with segment bases |
| `segments` | `[PathSegment]` | – | Path in time order. | A | ordered, disjoint, last `end` == latest task end |
| `segmentsTotal` | `Int` | – | Segments before capping. v0.2 never caps segments. | A | == `segments.count` in v0.2 |
| `segmentsShownShare` | `Double?` | Σ segment seconds 0 | Σ shown segment `seconds` / Σ all segment `seconds`. | A | `1.0` in v0.2 |
| `waits` | `[PathWait]` | – | Gaps on the path where nothing on the path ran (§6.2 inference `cur.start - pick.end > eps`). | A | disjoint from segments |
| `whatIf` | `[WhatIf]?` | `basis == inferred` (filled for `dag` and `mixed`, Lane A note) | Per target, saving if its tasks took 0 or half the time. Ranked by `savingIfZero`. | A | each saving ≤ `span`; `savingIfHalf ≤ savingIfZero` |
| `notes` | `[String]` | – | Fallback reasons, eps used, dropped description. | A | |

### PathSegment (`criticalPath.segments[]`)

| Member | Type | Null when | Meaning | Invariant |
|---|---|---|---|---|
| `start`, `end` | `Double` | – | Seconds from window start. | `start < end` |
| `seconds` | `Double` | – | `end - start`. | |
| `share` | `Double?` | `span == 0` | `seconds / span`. | Σ share + Σ wait share == 1 |
| `basis` | `String` | – | `dag` / `byTiming` / `inferred`. | |
| `target` | `String?` | build-system step with no target | Target name, as in `targets[].name`. | |
| `targetId` | `Int?` | as `target` | `BuildModel.targets` index. | |
| `label` | `String` | – | Short human label: kind or rule plus file, e.g. `"emit-module LocalizeCore"`. No command lines. | |
| `taskIds` | `[Int]` | – | Model task ids in path order (consecutive same-target tasks may share one segment). | non-empty; ids valid in `BuildModel.tasks` |

### PathWait (`criticalPath.waits[]`): `start: Double`, `end: Double`, `seconds: Double` (`end - start`).

### WhatIf (`criticalPath.whatIf[]`)

| Member | Type | Null when | Meaning |
|---|---|---|---|
| `target` | `String` | – | Target name. |
| `targetId` | `Int?` | no model target | `BuildModel.targets` index. |
| `savingIfZero` | `Double` | – | `span` minus the longest path with every task of the target at duration 0 (lower bound, unlimited cores). |
| `savingIfHalf` | `Double` | – | Same with durations halved. |

## TimingSection (`timing`)

| Member | Type | Null when | Meaning | Lane | Invariant |
|---|---|---|---|---|---|
| `utilization` | `Utilization?` | no timing / V1 failed / not computed | Average running tasks per bucket from all timed tasks, before truncation. | A | `lanes.count ≤ 4000`; `lanes.count × bucketSeconds ≥ build.span` |
| `serialStretches` | `[SerialStretch]?` | no timing, V1 failed, or not computed | Windows ≥ 1 s with running lanes ≤ threshold: the `topN` longest, sorted by `start`. | A | each `end - start ≥ 1`; disjoint |
| `serialStretchesTotal` | `Int` | never | Stretches before capping (0 while null). | A | |
| `serialStretchesShownShare` | `Double?` | list null or `serialSeconds == 0` | Σ shown lengths / `serialSeconds`. | A | |
| `serialThresholdLanes` | `Int?` | no timing, V1 failed, or not computed | `max(1, floor(0.10 × physicalCores))`; without a core count `max(1, floor(0.10 × peakLanes))` with a note (Lane A note). | A | ≥ 1 |
| `serialSeconds` | `Double?` | as `serialStretches` | Σ length of all stretches. | A | ≤ `build.busy` |
| `idleGaps` | `[Gap]?` | no timing / not computed | Spans > 100 ms with no task running: the `topN` longest, sorted by `start`. | A | Σ all gaps ≤ `build.idle` |
| `idleGapsTotal` | `Int` | never | Gaps before capping. | A | |
| `idleGapsShownShare` | `Double?` | list null or Σ gaps 0 | Σ shown gap lengths / Σ all gap lengths. | A | |
| `peakLanes` | `Int?` | V1 failed or no timing | Peak concurrency. | filled today | `== build.parallelism.peak` |
| `processWall` | `Double?` | not run through `xcblame build` | xcodebuild process wall time. | B (via `ReportPipeline.Options.processWall`) | ≥ `build.span` − 0.5 s |
| `outsideLogSeconds` | `Double?` | `processWall` null, V1 failed or no timing | `max(0, processWall − build.span)`. | filled today from `processWall` | |
| `notes` | `[String]` | never | Reasons for every null member. | A | |

- **Utilization**: `bucketSeconds: Double` (= `max(0.1, span / 4000)`), `lanes: [Double]` (bucket `i` covers
  `[i × bucketSeconds, (i+1) × bucketSeconds)`).
- **SerialStretch**: `start: Double`, `end: Double`, `lanes: Int` (most lanes running inside the stretch,
  ≤ `serialThresholdLanes`).
- **Gap**: `start: Double`, `end: Double`.

## Target rows (`targets[]`, added members)

`targets` (v1, the `rollups.byTarget` of DESIGN §8.1) keeps its members and gains:

| Member | Type | Null when | Meaning | Lane | Invariant |
|---|---|---|---|---|---|
| `owner` | `String?` | not classified | `app` / `localPackage` / `remotePackage` / `pods` / `macroPlugin` / `systemModules` / `buildSystem` / `unknown`. | A | `null` on the `other` row |
| `onPathSeconds` | `Double?` | `criticalPath` null | Σ `seconds` of path segments of this target. | A | Σ over rows ≤ `criticalPath.span` |
| `whatIfSeconds` | `Double?` | `criticalPath.whatIf` null or no entry for the target | That target's `whatIf.savingIfZero`. | A | == the matching `whatIf` entry |
| `busy` | `Double?` | not computed / V1 failed | Union of this target's task intervals. | A | ≤ `taskTime`; ≤ `build.busy` |
| `kinds` | `[Row]?` | not computed / rollups withheld | Task time per kind for this target (v1 `Row`: `key`, `tasks`, `taskTime`, `share`, `isOther`); `share` is of the target's `taskTime`. Never capped. | A | partition: Σ `taskTime` == row `taskTime`, Σ `tasks` == row `tasks` |

## FileRow (`files[]`)

| Member | Type | Null when | Meaning | Invariant |
|---|---|---|---|---|
| `path` | `String` | – | Source file path (redactable). For a `batch` row: the first member in sorted order. | |
| `target` | `String?` | task has no target | Target name. | |
| `targetId` | `Int?` | as `target` | `BuildModel.targets` index. | |
| `seconds` | `Double` | – | `exact`: task time; `batch`: the whole batch's time, once; `estimated`: share of the batch by type-check ms; `wmo`: the module compile. | never a batch duration copied onto each member |
| `granularity` | `String` | – | `exact` / `batch` / `estimated` / `wmo` (§6.4). | |
| `batchSize` | `Int?` | not `batch`/`estimated` | Files in the batch. | == `members.count` |
| `members` | `[String]?` | not `batch`/`estimated` | All file paths of the batch, sorted. | |
| `onPath` | `Bool` | – | The file's compile task is on the critical path (false when `criticalPath` is null). | |
| `typeCheckMs` | `Double?` | no type-check timer for the file | Σ hotspot ms for the file. | |
| `taskId` | `Int?` | several tasks | Model task id of the compile task. | |

V9: Σ `exact` rows of a target ≤ that target's compile task time; `estimated` rows are never summed with `exact` ones.

## Hotspot (`hotspots[]`)

| Member | Type | Null when | Meaning |
|---|---|---|---|
| `file` | `String` | – | Source path (redactable). |
| `line`, `col` | `Int` | – | 1-based. |
| `declaration` | `String` | – | Declaration or expression text as the compiler printed it, e.g. `StringsView.body`. |
| `kind` | `String` | – | `functionBody` / `expression` / `other`. |
| `ms` | `Double` | – | Milliseconds, summed over `occurrences`. |
| `source` | `String` | – | `debugTimeFunctionBodies` / `debugTimeExpression` / `warnLong` / `statsDir` / `ftimeTrace`. |
| `onPathWeight` | `Double` | – | 1 if the file's compile task is on the critical path, else 0.25 (§6.5); 1 when `criticalPath` is null. |
| `occurrences` | `Int` | – | Deduped occurrences (≥ 1). |
| `target` | `String?` | unknown | Target name. |
| `taskId` | `Int?` | unknown | Model task id the text came from. |

## Finding (`findings[]`, populated from v0.3)

| Member | Type | Null when | Meaning |
|---|---|---|---|
| `ruleId` | `String` | – | e.g. `SET-024`. |
| `title` | `String` | – | One line. |
| `severity` | `String?` | rule has none | §7.1 severity. |
| `impactBand` | `String?` | no impact | `S` / `M` / `L` band. |
| `impactSeconds` | `Double?` | not measurable | Estimated saving. V12: ≤ the measured cost; ≤ what-if for "shortens this build". |
| `impactBasis` | `String?` | as `impactSeconds` | `pathShare` / `taskTime` / `whatIf` / ... |
| `confidence` | `String` | – | `high` / `medium` / `low`. |
| `evidence` | `[String]` | – | One line per item; truncation keeps ≥ 3. |
| `fixKind` | `String?` | no fix | §7.3 fix kind. |
| `risk` | `String?` | – | Risk text. |
| `mechanism` | `String?` | – | `hook` / `cli` / ... (§7.5). |

**RuleDoc** (`ruleDocs[ruleId]`): `title: String`, `summary: String`, `fix: String`, `sources: [String]` (URLs).

## Truncation (`truncation`)

`steps: [TruncationStep]` in the order applied (§8.2.3). Each step:

| Member | Type | Null when | Meaning |
|---|---|---|---|
| `step` | `String` | – | `topTasks` / `hotspots` / `files` / `taskIndex` / `moduleGraph` / `targets` / `serialStretches` / `idleGaps` / `tasksWithoutTiming` / `decodeWarnings` / `findingsEvidence` / `diagnostics` / `lastResort` (Lane C note). |
| `kept` | `Int` | – | Rows kept after the step. |
| `total` | `Int` | – | Rows before any truncation (the matching `*Total`). |
| `shownShare` | `Double?` | measure total 0 | Share of the measure the kept rows cover. |

Invariant: truncation removes rows only. Every `*Total`, sum, partition (with its `other` row), `timing.utilization`
and `criticalPath` is computed before it and stays unchanged (V6, V13). `ReportBudget.apply` updates the capped list,
its `*ShownShare`, and appends the step; it never changes a `*Total`.

## TaskIndex (HTML only, `Sources/XcblameKit/Reporters/TaskIndex.swift`)

One entry per shown task in every column (`start.count == dur.count == lane.count == target.count == kind.count ==
label.count == onPath.count`). Sorted by `start`, then `lane`.

| Member | Type | Null when | Meaning | Lane |
|---|---|---|---|---|
| `start` | `[Int]` | – | Milliseconds from the session window start (rounded). | A |
| `dur` | `[Int]` | – | Duration in milliseconds (rounded, ≥ 0). | A |
| `lane` | `[Int]` | – | Greedy lane packing, 0-based; no two tasks in one lane overlap. | A |
| `target` | `[Int]` | – | Index into `targets`. | A |
| `kind` | `[Int]` | – | Index into `kinds` (`TaskKind` raw values). | A |
| `label` | `[Int]` | – | Index into `labels` (title, no command line, keys or signatures). | A |
| `onPath` | `[UInt8]` | – | 1 if on the critical path, else 0. | A |
| `targets`, `kinds`, `labels` | `[String]` | – | Interned string tables; a task without a target uses an entry `"(no target)"`. | A |
| `dropped` | `[Dropped]` | – | Per `target` (index into `targets`) and `lane`: `tasks: Int`, `seconds: Double` removed by truncation step 3. | C |
| `taskIndexTotal` | `Int` | – | Tasks the full index holds before truncation: Lane A sets it to `build.tasks` (tasks that entered timing; reused, invalid and untimed tasks are not in the index). The stub returns `model.tasks.count`. | A |
| `taskIndexShownShare` | `Double?` | stub, or Σ duration 0 | Σ shown `dur` / Σ all durations. | A, then C |

`TaskIndex.make(model:analysis:document:)` builds the full index (Lane A); `ReportBudget.apply` thins it (Lane C).

## Entry points and file ownership

| File | Symbol | Phase 1 behavior | Owner |
|---|---|---|---|
| `Sources/XcblameKit/Graph/BuildDescription.swift` | `BuildDescription.load(directory:) throws -> BuildDescription` | throws `notImplemented` | A |
| `Sources/XcblameKit/Graph/BuildDescriptionLocator.swift` | `BuildDescriptionLocator.find(model:logURL:explicit:snapshotsDir:) -> BuildDescription?` | `nil` (explicit: `try? load`) | A |
| `Sources/XcblameKit/Reporters/TaskIndex.swift` | `TaskIndex.make(model:analysis:document:) -> TaskIndex` | empty columns, `taskIndexTotal = model.tasks.count` | A |
| `Sources/XcblameKit/Reporters/ReportDocument+Make.swift` | `ReportDocument.make(...)` (fills the members above) | null/empty defaults | A |
| `Sources/XcblameKit/Reporters/TextReporter.swift` | text rendering of new members | unchanged | A |
| `Sources/XcblameKit/Build/XcodebuildRunner.swift` | `XcodebuildRunner.run(arguments:xcblameDir:timeout:) throws -> Result` | throws `notImplemented` | B |
| `Sources/XcblameKit/History/History.swift` | `History.save(document:model:directory:) throws -> URL` | throws `notImplemented` | B |
| `Sources/xcblame/BuildCommand.swift` | `xcblame build` | runner stub → exit 1 | B |
| `Sources/xcblame/HistoryCommand.swift` | `xcblame history list\|show\|prune` | exit 1 | B |
| `Sources/XcblameKit/Reporters/HTML/HTMLReporter.swift` | `HTMLReporter.render(_:taskIndex:options:) throws -> Data` | throws `notImplemented` | C |
| `Sources/XcblameKit/Reporters/HTML/Redactor.swift` | `Redactor.redact(_:context:) -> ReportDocument`, `Redactor.Context.current()` | sets `redacted = true` only | C |
| `Sources/XcblameKit/Reporters/HTML/ReportBudget.swift` | `ReportBudget.apply(_:taskIndex:maxBytes:templateBytes:)` | no-op | C |
| `Sources/XcblameKit/Reporters/HTML/HTMLOutput.swift` | `HTMLOutput.write(_:to:kind:reportsDir:open:browser:isCI:) throws -> URL` | throws `notImplemented` | C |
| `Sources/xcblame/ReportReload.swift` | `loadSavedReport(at:) throws -> ReportDocument` | throws `notImplemented` | C |

## Wiring that is already in place (frozen)

- `ReportPipeline.Options` carries `buildDescription: BuildDescription?`, `physicalCores: Int?` and
  `processWall: Double?` into `ReportDocument.make`. `analyze` passes the locator result and, when `--env` captured
  them, `performanceCores + efficiencyCores` as physical cores (nil on `--no-env` or Intel). `build` (Lane B) sets
  `processWall`.
- `analyze` flow: load (saved `xcblame.report/` JSON → `loadSavedReport`, skipping the pipeline; else model) →
  `ReportPipeline.run` → `History.save(document:model:directory: <xcblame-dir>/history)` unless `--no-history`, only
  for real logs (not `--model-json`, not saved reports), with the unredacted document; `notImplemented` is ignored,
  any other error prints a warning and never fails `analyze` → `Redactor.redact(_, context: .current())` when
  `resolvedRedact` → render. `html`: `TaskIndex.make` (nil for a saved report) → `HTMLReporter.render` with
  `Options(redact:, maxBytes: --max-report-bytes ?? HTMLReporter.defaultMaxBytes, title: "xcblame report")` →
  `HTMLOutput.write(_, to: -o, kind: build.kind, reportsDir: <xcblame-dir>/reports, open: --open && !CI, browser:,
  isCI:)` → stdout prints `wrote <path> (html, N bytes) · checks …` and, without `--open`, `open "<path>"`.
  HTML never goes to stdout.
- `--build-description <dir>` is passed as `explicit`; `snapshotsDir` is `<xcblame-dir>/snapshots`; `logURL` is the
  selected log or bundle (nil for `--model-json`); `--no-build-description` skips the locator.
- `Redactor.isImplemented` (Lane C) gates the "report is NOT redacted" note in `analyze`; Lane C sets it to true and
  updates `CLITests.testRedactIsANoOpWithANote` in the same change.
- Exit codes: `XcblameError.notImplemented` maps to 1.

Frozen shared files (no lane edits them): `ReportDocument.swift`, `ReportPipeline.swift`, `GlobalOptions.swift`,
`AnalyzeCommand.swift`, `ModelLoading.swift`, `Xcblame.swift`, `XcblameError.swift`, `ExitCode.swift`.

## Lane B notes

- **Snapshot layout** (`<xcblame-dir>/snapshots/<log-uuid>/`, uuid = build log file name without extension): `manifest.json.gz`
  (gzip of the live `manifest.json`; a live `manifest.json.gz` is copied as is), `target-graph.txt`, `build-request.json`,
  `clangmodulesreport/`, `swiftmodulesreport/` (plain CSV folders, as in `fixtures/logs/cli-xcode26-dd/xcbuilddata`) and
  `SIGNATURE` (one line: the `<signature>.xcbuilddata` folder name). Files missing in DerivedData are skipped with a note.
  The description copied is the `<signature>.xcbuilddata` the log names (`BuildDescriptionLocator.signature(of:)`: the
  `Build description signature:` line, else the `CreateBuildDescription` key), even when the build reused it. Only a log
  without a signature, or a missing folder, falls back to the newest one written since the build started, else the
  newest one, with a note. `build` passes the snapshot to the locator through `snapshotsDir` (not `explicit`), and a
  snapshot whose signature differs from the log's gives way to the live description carrying the log's signature.
- **History entry** (`<xcblame-dir>/history/<yyyyMMdd-HHmmss>-<kind>.json.gz`, local time, `kind` = `build.kind ?? "unknown"`):
  one JSON object holding the report's own members at top level (so it still decodes as a `ReportDocument`; `files`,
  `hotspots`, `topTasks` cut to 25 rows, their `*Total` unchanged, their `*ShownShare` rescaled to the kept rows) plus
  `taskIndexRows: [[key|null, rule, target|null, kind, sigDigest, durationMs, onPath(0|1)]]`. Rows cover executed tasks
  only (reused, cache-fetched and untimed tasks are left out); `sigDigest` is the first 16 hex of
  SHA256(`commandDetails ?? title`); `onPath` is 1 for ids in `criticalPath.segments[].taskIds`, 0 when `criticalPath` is
  null. `analyze` and `build` both write the unredacted document; a save whose log (`input.path` basename) is the
  newest entry's log is skipped, so one log is one entry. Retention: newest 200 entries and 90 days, applied after
  every save. Pruning `<xcblame-dir>/history` also deletes `snapshots/<uuid>/` folders that no kept entry names (entry
  `input.path` basename = uuid) and that are older than 90 days or beyond the newest 200 by mtime (integration).
- **Runner** (`XcodebuildRunner.run(arguments:xcblameDir:timeout:executable:executablePrefix:)`): defaults to
  `/usr/bin/xcrun xcodebuild`; `Result` also carries `notes`, `timedOut`, `thermalBefore/After` and `capturedOutput`
  (`<xcblame-dir>/logs/<time>.xcodebuild.log`). A timeout returns exit code 124. `XCBLAME_XCODEBUILD=<executable>` makes
  `xcblame build` run that executable instead of `xcrun xcodebuild` (test hook for the CLI tests).
- `xcblame build` streams xcodebuild's stdout unchanged, so with `--format json` use `-o <file>` to get clean JSON.

## Lane C notes

- **Blob bytes.** `#xcblame-data` holds `JSONReporter.render(document)` (pretty-printed, sorted keys, trailing newline)
  with `"taskIndex" : {…}` spliced in as one compact line at its sorted top-level position. Removing that line gives
  the `--format json --top all` bytes of the embedded document exactly (tested); that document differs from the
  pipeline's only by truncation and by V13, which html measures on the final page (template included) against
  `--max-report-bytes`: `pass` when it fits, `warn` when even the last resort does not. Size never fails the command:
  `analyze` writes the page anyway, warns on stderr over the cap and notes the truncation steps otherwise (§8.2.3).
  The pipeline skips its JSON-size V13 for html (`ReportPipeline.Options.checksSize = false`). DESIGN §8.2.5 step 4 says "minified"; byte parity with the
  pretty JSON output won, and only `taskIndex` is compact.
- **Script-data escaping.** `</` → `<\/`, `<!--` → `<!--` (not `<\!--`: `\!` is not a JSON escape),
  U+2028/U+2029 → ` `/` `. A blob containing none of these is unchanged.
- **Truncation step names** beyond the table above: `topTasks` runs first, before `hotspots` (html uses `--top all`,
  so `topTasks` repeats every task already in `taskIndex` and no v0.2 section shows it; left in step 5 it was the last
  list trimmed, after every other list had hit its floor: the 50k synthetic came out at 0.6 MB with every list at its
  floor). Step 5 also records `serialStretches`, `idleGaps`, `tasksWithoutTiming` and `decodeWarnings` (floor 25
  each). `lastResort` can appear twice: dropping `taskIndex` (`total` = `taskIndexTotal`), then header-only (`total` =
  `build.tasks`). Header-only sets the capped lists to `null` with their `*Total` kept (computed, then withheld) and
  adds a note to `notes` and `timing.notes`. Step 4 (module graph) has no member yet; step 7 (diagnostics) has nothing
  to drop while only `diagnosticsSummary` is embedded.
- **Floors as stages.** Each list step runs filter → cap → floor (e.g. hotspots: < 10 ms dropped but never below 25
  rows, then top 500, then top 25), checking the size after each stage, and records one entry per list.
- **Folded `other` target row.** When step 5 folds rows into `other`, `tasks`, `taskTime`, `share` and
  `onPathSeconds` are summed; `kinds`, `busy` and `whatIfSeconds` become `null` (not mergeable without the tasks).
- **Task-index thinning** prunes unused `labels` and remaps `label`; `targets`/`kinds` tables are kept so `dropped`
  indexes stay valid. `taskIndexShownShare` = Σ shown `dur` / Σ all `dur` (all = the pre-truncation sum divided by
  the incoming share when Lane A set one).
- **Redactor tokens.** `~` (home), `$USER`, `$HOST` (also without `.local`), `$REPO` (nearest ancestor of the
  working directory holding `.git`, unless that is home), `/DerivedData/<Name>-$DDHASH` (28 lowercase letters).
  Host matches only where not glued to a letter or digit; the user name also where digits follow it (`/Volumes/ann2/`
  → `/Volumes/$USER2/`). Any other `/Users/<name>` or `/home/<name>` (a CI runner's or a colleague's home, not
  `/Users/Shared`) becomes `/Users/$USER` / `/home/$USER`, only where a path starts (string start, or after whitespace,
  `"`, `'`, `=`, `(`, `[`, `,`, `:`), never inside a URL or a deeper path. Every string value is walked, keys are not, and the task
  index's `targets` and `labels` get the same tokens. A failed round trip fails closed: `redacted` stays false and
  stderr says so.
- **Page counts.** Each `<section>` carries `data-total` / `data-shown`: `timeline` = `criticalPath.segmentsTotal`
  (0 when null) / segments embedded; `targets`, `files`, `hotspots`, `findings` = their `*Total` / rows embedded;
  `environment` = `validation.checks.count`; `summary` = `build.tasks`. `<body data-first-paint>` holds the ms at
  `performance.mark('xcblame:first-paint')`; `data-rendered="all"` appears once every section rendered.
- **Hint.** `AnalyzeCommand` already prints the `open "<path>"` hint, so `HTMLOutput.write` does not print it again;
  it only warns on stderr when `/usr/bin/open` fails.
- **Saved reports** decode with `JSONReporter.decoder()`; a missing member fails with exit 1 and
  `re-rendering a saved JSON report failed: <path> … (missing <key path>)`.

## Lane A notes (semantics pinned while implementing)

Two deliberate departures from the original tables, both for the reader's benefit; adopted at integration and folded into
the tables above:

- **`criticalPath.whatIf`** is filled whenever the path comes from the task DAG, i.e. `basis` `dag` **or `mixed`**;
  it is null only under `inferred`. On every AcmeApp fixture the DAG path is `mixed` (explicit-module tasks and
  build-system steps outside the manifest attach `byTiming`), so "null unless `dag`" would never show a what-if.
  Savings are `L − L_X` with `L` the weighted longest path at measured durations (unlimited cores), capped at `span`.
- **`timing.serialThresholdLanes`** without a physical core count (`--no-env`, Intel) is `max(1, floor(0.10 ×
  peakLanes))`, with a note in `timing.notes` (Lane A brief), instead of null.

Graph and matching:

- `graph.basis`: an explicit `--build-description` folder counts as `snapshot`. `graph.signature` comes from a
  `SIGNATURE` file or a `<hex>.xcbuilddata` folder name; when the folder names none it is the log's signature, with a
  note. The log's signature is the `Build description signature:` line, else the key of the `CreateBuildDescription`
  task (its signature slot holds the signature even when the description was reused: D822889B, 1724F45E).
- Key coverage (≥ 95 %) is a hard gate for every source (explicit `--build-description`, snapshot, live): below it
  the description is dropped before the DAG, the kind or the target graph read it, `graph.basis` is `none` and a
  `dropped:` note gives the coverage. The consistency check (§6.2 step 5) counts direct manifest edges between two
  executed commands only (no timing edge, no path through a phony gate).
- Key coverage counts *planned keyed tasks* only: a task key with the `0x00` prefix and a rule that is not a
  dynamic job (`SwiftCompile`, `SwiftEmitModule`, `SwiftDriver`, job discovery, PCM, `PrecompileModule`, interface
  compiles). Dynamic jobs carry `P0:` keys too, but are never manifest commands.
- Manifest directory nodes are spelled `X.swiftmodule/` on the input side and `X.swiftmodule` on the output side; edges
  compare them without the trailing slash.
- `fixtures/logs/cli-xcode26/xcbuilddata/manifest.json` is the 20E8B73D build's description (no SIGNATURE; 212 of
  212 planned keyed tasks are its commands).

Critical path:

- DAG path: from the latest-ending task, step to the DAG predecessor that ended last (the one that gated the start;
  ties: longer weighted chain). Edges: manifest (commands that did not run, phony gates included, are zero-weight virtual nodes with their direct edges, walked through; V and E stay manifest-sized); Swift jobs of target T
  by rule (planning → emit-module → T's `SwiftDriver Compilation Requirements`, planning → compiles → T's
  `SwiftDriver Compilation`; planning after both commands' inputs); explicit-module tasks (byTiming) after every
  target whose planning they follow and before its compiles, plus the explicit-module task that ended last before
  them; any task left without a predecessor (after the window start) after the task that ended last before it.
  Segment basis: `dag` for manifest commands and Swift jobs attached by rule, `byTiming` for the rest.
- What-if: one pass per target computes the longest path with the target at 0 and at half (both accumulators in the
  same pass), and only for targets with a zero-slack or on-path node; any other target lies on no longest path, so its
  savings are exactly 0. Per-task slack (§6.2 step 4) comes from one forward and one backward pass; no schema member
  carries it, so it stays internal (`PathResult.slack`) and a `criticalPath.notes` line counts the zero-slack tasks.
- One segment per path task. A gap ≤ 50 ms or an overlap moves the segment start to the previous end (so Σ segments +
  Σ waits = span exactly); a task wholly inside the previous segment joins its `taskIds`; zero-length tasks are walked
  through but never segments. The path starts at its first task (not necessarily 0); "the last task end" is the
  latest end among tasks with a positive duration.
- Inference: the constraint predecessor of §6.2 is a tie-breaker among the finishers within 50 ms of the latest one;
  candidates must start before the current task. Same-target "earlier phase" uses the step order planning <
  stat cache < scan/plan < PCM < emit-module < compile < gate < link < packaging < sign.
- What the two methods disagree on (fixtures 20E8B73D, 5E3BDB3A, 71374EE4): inference puts LocalizeCore's longest
  compile on the path because it happens to end just before the next PCM starts; the DAG shows AcmeApp's planning
  waits for LocalizeCore's emit-module (its swiftmodule), then AcmeApp's PCM chain. Spans and the ends of shared
  tasks agree exactly.

Kind, attribution, index:

- `build.kind` adds **`clean-action`** (a log of only planning/clean/gate tasks and no build-description task, the
  3-task clean logs). Order: build-request (`enableIndexBuildArena` → `index`; `action` analyze/archive/install/test),
  `clean-action`, `zero-change` (no compile, plan, emit-module, PCM or link task executed), `incremental` (reused >
  0), `clean` (signature line present), SLF `CreateBuildDescription` without the line → `incremental` (description
  reused), xcresult → `clean`; else null.
- Serial stretches are windows with 1 ≤ running lanes ≤ threshold; an idle instant ends a stretch (so `serialSeconds ≤
  busy`). Idle gaps include the lead-in from the window start and the tail to the window end.
- Owners: buckets → `systemModules` / `buildSystem`; `-load-plugin-executable` names → `macroPlugin`; a path or source
  under `/checkouts/` → `remotePackage`, `/Pods/` → `pods`; `.xcodeproj`/`.xcworkspace` path → `app`; `Package.swift`
  path inside the workspace root (or no root known) → `localPackage`; own sources elsewhere → `app`/`localPackage`;
  a target without evidence takes its project siblings' single class; else `unknown`. The `other` row has no owner.
- Files: compile tasks are `SwiftCompile`, `CompileC`, `CompileAssetCatalog*`, `CompileStoryboard*`, `CompileXIB*`;
  files are the absolute source paths on the first `commandDetails` line. `wmo` when the target's `SwiftDriver`
  command has `-whole-module-optimization`/`-wmo`. `estimated` rows are never produced (noted in `notes`).
  Per-granularity totals over all rows are in a `files:` entry of the top-level `notes`.
- Hotspots: only `SwiftCompile` output is read (the 4,187 lines in 20E8B73D's `SwiftEmitModule` output are not).
  Lines at one `file:line:col` inside one task add up (a property's accessors); across tasks the larger one wins;
  `occurrences` counts every merged line. The declaration drops its `@<location>` suffix. User code excludes paths
  containing `/checkouts/`, `/SourcePackages/`, `/DerivedData/`, `/Build/Intermediates.noindex/`, `/Build/Products/`,
  `/Library/Developer/` and paths under `/Applications/Xcode*`. Counts on 20E8B73D: 20,960 timer lines (1,158 with
  `<invalid loc>`), 1 warn-long diagnostic, 542 user rows after dedupe.
- TaskIndex: times in whole ms; a lane is free when its last end ≤ the next start (so zero-length rows can share
  one); labels are `<rule> <title>` with every path-like word cut to its basename, ≤ 120 characters.
- V3, V9 and V11 come from the `Explain` engines (they need the description, which `Validator.validate` does not
  get). `ReportPipeline.run` runs the engines once for both passes and merges their checks into
  `Result.validation`, so it matches `document.validation` check for check (integration). A failed V3/V9/V11
  withholds the path, the file rows and the kind.
