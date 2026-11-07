# Code review: xcblame v0.5 "Deep and Why"

Range: `git diff 6815eff..070f96c` (probes 435b2fd, skeleton e42f819, lanes A/B/C, integration 070f96c).
Requirements: DESIGN §5.8, §6.4-§6.9, §7.5, §8.2.4 rows 7-9, §11 v0.5; contract docs/SCHEMA-v0.5.md; formats from
docs/research/probes-v0.5.md. Review only: read-only, nothing committed. Findings were traced through the code; anything
without a concrete failing input is marked PLAUSIBLE.

**Verdict: FIX-FIRST** (no blocker; 3 majors that give wrong results on ordinary command combinations).

## Majors

### History and attribution

- `Sources/xcblame/BuildCommand.swift:195` (with `Sources/XcblameKit/History/History+Why.swift:37-41`): major:
  `build --deep` builds are saved to history under the normal build key (scheme, configuration, destination), and no
  consumer filters them out. `History.previousIndex` matches on that key alone. So the next ordinary `build` or
  `analyze` uses the deep build's task index as its previous build. Every executed Swift compile has the same task key
  but a different command digest (the injected `-Xfrontend -debug-time-*` / `-stats-output-dir` flags), so
  `SignatureEvidenceProvider` makes them all `settingsChanged`. The second `build --deep` (incremental in the deep
  DerivedData) gets the same misattribution against the previous normal build. Trend, baseline (`baseline save --last
  n`) and `FixedCosts` history frequency also take in instrumented, separately cached builds.
  Scenario: `xcblame build -- …` (clean), `xcblame build --deep -- …`, edit one file, `xcblame build -- …` → the
  causes say "Settings or command lines of <every target> changed since build <deep id>" instead of `inputChanged`.
  Fix: skip entries with `deep != null` in `previousIndex`, in the trend/baseline selection and in
  `FixedCosts.loadHistory` (or add `deep` to the build key). The cheapest option is not saving deep builds unless
  asked.

### Build flags

- `Sources/xcblame/BuildCommand.swift:75-80, 458, 474`: major: `--deep` combined with `--kind`, `--touch` or
  `--runs > 1` runs the preparation in the wrong DerivedData. `run()` calls `prepareDeep()` before it branches to
  `preparedRuns()`. `preparedRuns` then calls `WhyProcedure.prepare` with `self.xcodebuildArguments` (no deep
  `-derivedDataPath`, no wrapper), so the clean / settle / touch step runs in the user's own DerivedData. Then
  `single.run()` (still `deep == true`) runs `prepareDeep()` again and measures in the deep DerivedData.
  Scenarios:
  - `build --deep --kind clean` runs `xcodebuild clean` on the user's DerivedData. That wipes the incremental state
    §5.8 promises `--deep` never touches, and the measured deep build is not clean.
  - `--kind zero-change` / `--kind incremental --touch f` measure a deep build whose state has nothing to do with
    the preparation.
  - Probe, oracle check, wrapper and (with `--exact-files`) a full extra deep build run once more than there are runs.

  Fix: reject the combination in `validate()`, or call `prepareDeep()` once and pass the deep arguments and
  `unsetEnvironment` to `WhyProcedure.prepare` and to each run.

### HTML budget

- `Sources/xcblame/GlobalOptions.swift:60` with `Sources/XcblameKit/Why/CauseEngine.swift:98` and
  `Sources/XcblameKit/Reporters/HTML/ReportBudget.swift:61-73`: major (size magnitude PLAUSIBLE, mechanism confirmed):
  HTML runs with `topN = .max`, so `incremental.causes[].tasks` lists every executed task. For a zero-change build,
  `fixedCosts[].tasks` does too. The budget pass has no step for either member. A large non-clean build (tens of
  thousands of executed tasks, each CauseTask carrying a long task key, label and target) therefore falls through to
  `lastResort`. That drops `taskIndex`, the critical path, targets and files and keeps the oversized incremental lists.
  The §11 v0.2 exit criterion ("50k-task synthetic ≤ 8 MB with unchanged Totals") is untested for non-clean builds:
  `CauseEngine.attach` runs only in the commands, never in the synthetic HTML tests. `History.trimmed` does not trim
  these lists either, so `build --format html` history entries hold every task twice (rows + causes).
  Fix: add a budget step that caps `causes[].tasks` / `fixedCosts[].tasks` (e.g. 200, then 25 per cause, with
  `tasksShownShare` rescaled, never dropping a cause or `unknown`). Trim them in `History.trimmed`. Add a synthetic
  incremental case to the 50k HTML test.

## Minors (one line each)

- `Sources/XcblameKit/Why/CauseProviders.swift:296-300` (minor): `mtimeChurn` never checks mtime; any re-run task whose inputs keep their hash is `timestampChurn`/DYN-002, so `why --touch X` without `--backtraces` labels dependents' recompiles DYN-002 with their own file as subject instead of joining X. Fix: require the touched/changed file set, or a mtime newer than the previous build start, as §6.6 step 5 says.
- `Sources/XcblameKit/Reporters/ReportDocument+Make.swift:376` (minor): with `estimated` rows, `filesShownShare` divides by Σ seconds of batch **and** estimated rows (the same batch seconds counted twice). The estimated rows are also appended after the sorted rows, so `--top 15` usually cuts all of them. Fix: exclude `estimated` from the denominator and sort/merge the rows.
- `Sources/XcblameKit/Graph/FileAttribution+Estimated.swift:16` (minor): the per-file split adds `-debug-time-function-bodies` ms, the nested `-debug-time-expression-type-checking` ms and warn-long duplicates of the same locations, which skews the shares. Fix: use one source (function bodies) per file.
- `Sources/XcblameKit/Deep/FTimeTraceReader.swift:154` (minor): the trace is read before the `Cache hit` check. The deep DerivedData persists, so a cache-hit TU reports the stale `.json` of an earlier miss as current. No size cap: a 100 MB trace goes through `JSONSerialization` whole. Fix: check `Cache hit` first, skip a trace older than the task start, and cap the bytes (e.g. 64 MB).
- `Sources/XcblameKit/Deep/ExactFiles.swift:41` (minor): `SWIFT_ENABLE_BATCH_MODE = $(XCBLAME_BATCH_MODE_…:default=YES)` forces YES on every target that is not rebuilt, overriding a project's own `NO`, so more targets change signature than the comment claims. Two targets whose c99 identifiers coincide (`My-App` / `My_App`, line 50) share one switch. Fix: default to the oracle's per-target value, or note the collision.
- `Sources/XcblameKit/Deep/WrapperXCConfig.swift:77` (minor): `#include "<path>"` does not escape `"` in the path, and a `$(` in a path is expanded by the xcconfig parser (also `DeepFlags.xcconfigQuoted` for the stats dir). Fix: reject such paths with a usage error.
- `Sources/xcblame/BuildCommand.swift:469` (minor): earlier `--runs` iterations set `-o /dev/null` but keep `--open`, so `build --runs 3 --format html --open` runs `/usr/bin/open /dev/null` twice. Fix: clear `global.open` for those runs too.
- `Sources/XcblameKit/Why/WhyProcedure.swift:229` (minor): `withAction` treats every flag outside a short list as taking a value, so `-parallelizeTargets build` keeps `build` and `--kind clean` runs `build clean` (a full build before the clean). Fix: list the boolean flags `xcodebuild -help` documents, or only strip known action words.
- `Sources/XcblameKit/Graph/CacheMetrics.swift:71` (minor): `Cache hit`/`Cache miss` are counted on any task, a script phase printing that line included. Fix: restrict to the cacheable rules (`CompileC`, `SwiftCompile`, `SwiftEmitModule`, `PrecompileModule`, `SwiftExplicitDependency*`).
- `Sources/XcblameKit/Graph/BuildKind.swift:131` (minor): `previews` matches any `derivedDataPath` containing `/Previews/` (e.g. `-derivedDataPath ~/Previews/dd`); the build is then classified `previews` and dropped from trends. Fix: require the Xcode arena layout (`…/Intermediates.noindex/Previews/` or `UserData/Previews`).
- `Sources/XcblameKit/Graph/FixedCosts.swift:221` (minor): builds per day is the median over days **with** builds only, which overstates per-day costs for a scheme built on 3 of 14 days. The `scripts` static row (line 61) lists every executed script phase, including ones with declared outputs that ran because of an edit. Fix: count the empty days, and keep `static` to scripts the project shows without outputs.
- `Sources/XcblameKit/Graph/ModuleGraph.swift:278` (minor): blockers cost O(V·(V+E) + V·T) (per node BFS plus a scan of every dependent's tasks). That is fine at 300 targets, but seconds at 2k targets × 50k tasks. Fix: walk the targets in topological order and use prefix sums over tasks sorted by start.
- `Sources/XcblameKit/History/History+Why.swift:27` (minor): `previousIndex` is "newest other entry", so `analyze` of an older log compares it with a later build. This is in the contract, but no `limit:` note says so. Fix: skip entries newer than the document's log, or add the note.
- `Tests/xcblameTests/WhyE2ETests.swift:78` (minor, requirement gap): the planted-cause share is computed over the scenario target's tasks (or the script phase only), not over the build's executed task time as §11 v0.5 states. The flip scenario is also checked only with backtraces, although SCHEMA lists source `signature`. Fix: assert both the subset share and the whole-build share, or amend §11.
- `Tests/XcblameKitTests/Reporters/SchemaV05ContractTests.swift:154` (minor): the strict schema validation runs on the hand-built `V05Samples`. No real `incremental`/`deep`/`build.cache` document from a fixture run (CauseEngine on the `*-why` logs, CacheMetrics on the 27.1 hit log) is validated, so a member a real run emits differently would pass. Fix: validate the JSON of `WhyCLITests` / the cache fixture report.

## Checked and fine

- No write into the project folder except `<xcblame-dir>/tmp/` (cwd): the deep DerivedData, the toolchain-probe cache and the stats dir live under `OracleCache.home()`. `OutputHashes`, `ProjectModel.load` and the ftime/stats readers only read. `why --touch` sets mtime only (never rewrites content) and does not restore it, as the contract specifies. It follows a symlink and accepts a path outside the project (the user's choice).
- `XcodebuildRunner.run(environment:unsetEnvironment:)` sets `process.environment` for the child only (`xcrun` passes it through). The oracle uses `/usr/bin/env -u`. The settle and measured builds share the backtrace mechanism. No env values reach the reports.
- Oracle check: if either `-showBuildSettings` fails, the check is skipped with a note and `--deep` stays enabled. It never disables `--deep` because the oracle was offline. Timeouts: 60 s per oracle run, 10 s per probe.
- Backtraces: the root is `frames.last`, read by category/frameKind keys, and the 26/27 wording only splits `ruleHadInvalidValue` on "every incremental build", which both versions contain. Malformed JSON gives nil, not a crash. Chain cycles are bounded by `visiting`. Per-file compiles inherit `SwiftDriver Compilation`.
- CauseEngine: one primary cause per executed task, providers in precedence order, `unknown` always last and never budget-cut, the two rankings never summed, V15 compared on the same clamped intervals as `build.taskTime`, `currentLogOnly` without history.
- Stats files: regex and short-form timers per MV-6, phases never summed, 27.1 extra timers ignored for `ms`. The existing `typeCheckMsByFile` now excludes file-level deep rows (no double count).
- CacheMetrics: both shapes, zero keys omitted, kind `cached` ordered after index/action, V11 evidence.
- History rows: older readers use the same `TaskIndexRow` decoder (an unkeyed container tolerates extra elements). Input hashing is capped at 5,000 files of ≤ 32 MiB.
- HTML #7-#9: data strings are set with `textContent`/`createTextNode`/`setAttribute` only (no `innerHTML` in the diff). The arrow-function rewrite touches no `this`/`arguments`. Zoom follows the v0.5 decision.
- Variants: 64 modules / 79 redundant match DESIGN. The 155 PCM tasks (143 Swift-side + 12 `PrecompileModule`) are explained in `VariantsTests`.

## Tests deleted or weakened

- Deleted: `CacheMetricsStubTests`, `CauseStubTests`, `DeepStubTests`, `FixedCostsStubTests`, `ModuleGraphStubTests`, `V15StubTests`, `VariantsStubTests`, `WhyStubTests`. They were phase-1 stubs replaced by real suites, as the contract plans. OK.
- `TrendCLITests`: byte equality replaced by document equality without `generatedAt`, plus an equal byte count. A real flake fix; OK.
- `GraphReportTests` V9: "estimated next to exact fails" became "estimated never summed". This matches §6.4; OK.
- Frozen phase-1 files `SchemaV05ContractTests`, `HTMLTemplateV05Tests`: lane B and the integration replaced the stub assertions (null members, phase-1 notes, V15 `notApplicable`) with real ones. This is a process deviation (frozen files) but not a weakening.
- E2E (`WhyE2ETests`, `DeepE2ETests`) are gated on `XCBLAME_E2E=1` per contract. The exit criteria are not checked in the default suite (see the WhyE2E minor above).

## Private names

`git diff 6815eff..070f96c -- Sources Scripts examples`: no new hit. New hits in Tests (all "the corpus app name", taken from the
probe fixtures): `Tests/XcblameKitTests/{BacktraceParsingTests,CauseEngineTests,DeepTestSupport,DeepTests,
FixedCostsTests,GraphReportTests,ModuleGraphHTMLTests,ModuleGraphTests,StatsDirReaderTests,VariantsTests,
WhyTestSupport}.swift`, `Tests/xcblameTests/DeepCLITests.swift`. None of the private corpus project names or
the restricted names appear.

## Re-check (fix round + clarity)

Range: `git diff 070f96c..c379dbb` (fix round 64b5c1c…1714969, hermetic oracle test 9a0be5c, clarity rounds 1-2 up to
01eaf10, and c379dbb "Confidence never demotes a finding with a band", which landed during the review). Read-only. I
ran `swift test --filter "WhyHistoryTests|RulesEngineTests|CauseEngineTests|DeepCLITests"` (38 pass). I checked
`SWIFT_ENABLE_BATCH_MODE = $(…:default=$(inherited))` with `xcodebuild -showBuildSettings` on a scratch copy of AcmeWhy
(Xcode 26.0.1): YES where the variable is unset, NO on the chosen target. I checked the setting labels against Xcode
26.0.1's own `Apple Clang.strings` / `Swift Compiler.strings` / `CoreBuildSystem.strings`.

**Verdict: FIX-FIRST** (2 majors: one is the rest of M1, one is new).

### Majors from the first review

- M1 (deep builds in history): **partly fixed, reopened.** `previousLookup`, `Trend`, `Baseline.selectHistory` and
  `FixedCosts.loadHistory` all skip entries that have `deep`. The skip note is emitted once (asserted in
  `WhyHistoryTests`). Compare by history id still accepts a deep entry, which is fine because the user chose it.
  Still open: the case where the *current* document is the deep build (see the new major 1).
- M2 (`--deep` with `--kind/--touch/--runs`): **fixed.** `prepareDeep()` runs once (`preparedArguments`). The deep
  `-derivedDataPath`, the wrapper and `unsetEnvironment` reach `WhyProcedure.prepare` and every run. `--kind clean`
  cleans the deep DerivedData only (DeepCLITests checks 4 calls, all in the deep DerivedData, `XCODE_XCCONFIG_FILE`
  unset). The stats folder is reset after each preparation and before each measured run. With `--exact-files`, the
  first deep build and the rebuild plan happen once; the runs reuse the exact-files wrapper.
- M3 (HTML budget for cause and fixed-cost task lists): **fixed.** Step 0b `causeTasks` runs after `topTasks` and
  before `hotspots`. It keeps 200 tasks per entry, then 25. Shares are rescaled. No cause or class is dropped
  (`unknown` included), and the step is recorded as `incrementalTasks` / `fixedCostTasks`. `History.trimmed` caps
  both lists at `topRows`. The 50k incremental test is realistic: 21 causes, 6k fixed-cost tasks, long keys, no
  `lastResort`, critical path kept.

### Minors from the first review (one line each)

- mtimeChurn: fixed (needs an input with an mtime newer than `PreviousIndex.start`).
- estimated rows share and sort: fixed (left out of the denominator, interleaved by seconds).
- per-file type-check from one source: fixed (function bodies > expressions > warn-long).
- ftime-trace: fixed (`Cache hit` is checked first, stale traces are counted, 64 MB cap).
- ExactFiles: fixed (`default=$(inherited)` confirmed with xcodebuild; colliding c99 names are refused with a note).
- xcconfig paths with `"` / `$(`: fixed (`requireExpressible` covers the includes and the stats folder).
- `--open` on earlier runs: fixed.
- `withAction`: fixed (explicit `booleanFlags` list).
- CacheMetrics: fixed (cacheable kinds only).
- previews substring: fixed (arena layout plus a heuristic marker).
- fixed costs per day / static scripts: fixed. Builds per day is now "per active day" and labelled that way. Static
  scripts are those without outputs, per ProjectModel or Xcode's warning.
- ModuleGraph blockers cost: fixed (bitsets and suffix sums; dependents reached only through a cycle's back edge are
  now not counted, as documented).
- `previousIndex` picking a later build: fixed (a `limit:` note when the entry is newer than `logEnd`).
- WhyE2E share: **still open.** The whole-build share is now computed but only asserted `> 0`. The comment says it is
  2-40 % on AcmeWhy, far below §11's "≥ 90 % of executed task time", and §11 was not amended. Either amend §11 (the
  planted cause holds ≥ 90 % of its scenario's tasks) or plant causes that dominate the build.
- Schema validation of real documents: fixed (`testRealV05MembersValidateAgainstTheSchema`).

### New findings

1. `Sources/XcblameKit/Why/CauseEngine.swift:246` (with `History/History+Why.swift:65`): major: when the
   *current* document is a `build --deep`, its previous build is the newest **ordinary** build of the key. Every
   executed Swift compile has the same key but carries the injected `-Xfrontend -debug-time-*` / `-stats-output-dir`
   flags, so `SignatureEvidenceProvider` (precedence 3) marks them all `settingsChanged`. M2 now makes this path
   common.
   Scenario: `xcblame build -- …`, then `xcblame build --deep --kind incremental --touch Core.swift --runs 3 -- …`.
   Every run's causes say "Settings or command lines of WhyCore changed since build <ordinary id>". The
   "run i is compared with run i-1" promise is false under `--deep`.
   Fix: when `document.deep != nil`, look up only deep entries (the previous deep build of the key); otherwise skip
   them, as now.
2. `Sources/XcblameKit/Reporters/ReportDocument+Doctor.swift:92,95` and `Resources/report.html:3089`: major
   (clarity requirement): the plan sends a junior to commands that do not exist in v0.5. There is no `verify` or
   `fix` subcommand (`Xcblame.swift:14`; both are v0.6 in §11). The HTML says "Run the commands in a terminal … in
   this order", and "Copy the N commands" copies `xcblame verify …`, `xcblame fix …` and the literal placeholder
   `xcblame build -- <your xcodebuild args>`, which zsh parses as a redirect. No output says these commands come in
   v0.6. Text and markdown print the same steps.
   Fix: label `verify` / `fix` steps "available in xcblame 0.6", keep them out of the copy button, and make
   `manual` / `inXcode` the runnable path until then.
3. `Sources/XcblameKit/Reporters/ReportDocument+Doctor.swift:128`: minor: V12 compares `impactSeconds` with the
   log span, but several rules measure **task time** (SET-001: the sum of WMO compile seconds; DEP heavy deps: the
   task time of package targets). On any parallel build these legitimately exceed the wall time.
   Scenario: a 60 s clean build with 120 s of WMO compiles gives V12 warn "SET-001 claims 120.000 s of a 60.000 s
   build". DESIGN's V12 is "saving ≤ the measured cost it is based on".
   Fix: compare against `build.taskTime` for task-time bases (or against `Measured.basis`), and the span only for
   path or what-if claims.
4. `Sources/XcblameKit/Rules/XcodeSettingLabels.swift:13`: minor: `GCC_OPTIMIZATION_LEVEL` 1 is "Fast [-O, O1]"
   in Xcode 26.0.1 (`Apple Clang.strings`), not "Fast [-O1]". Every other value label I could check matches Xcode:
   SWIFT_COMPILATION_MODE, SWIFT_OPTIMIZATION_LEVEL, GCC 0/2/3/s/fast/z, DEBUG_INFORMATION_FORMAT, LLVM_LTO
   No/Monolithic/Incremental, CLANG_ENABLE_MODULES, and the CoreBuildSystem names.
5. `Sources/XcblameKit/Why/CauseEngine.swift:334-356`: minor: `recompiled` counts the edited file itself among
   "files … that depend on X" (off by one). It picks the target with the most compiled files. So an edit to a public
   declaration in package `Core` that recompiles 40 files of `App` reads "recompiled 40 files of module App", and
   `whatToDo` says "split App into smaller modules". `whatToDo` also says "keep its declarations private or internal
   (and avoid @testable imports)". Inside one module `internal` is visible to every file, and `@testable` only
   matters across modules, so neither reduces same-module recompiles.
   Fix: exclude the subject's own compile. When the module differs from the subject's, say "module interface of
   Core changed" and give the upstreamInterface advice. Advise `private` / `fileprivate` only.
6. `Sources/XcblameKit/Why/TaskIdentity.swift:80`: minor: `outputShape` (rule, target, title) pairs same-titled
   tasks longest-to-longest. Two Run Script phases named "Run Script" in one target are leftovers in every compare,
   because script command text exports the per-invocation environment. They get cross-paired.
   Scenario: A has p1 5 s and p2 2 s; B has p1 1 s and p2 6 s. The rows show +1 s and −1 s instead of −4 s and
   +4 s. Net and attribution stay right.
   Fix: pair by `stableKey` first, then by title.
7. `Sources/XcblameKit/Compare/Compare.swift:189`: minor: with a history-id operand (rows have no `title`), Xcode
   26→27 compares fall back to N new + N removed silently. The contract says so (SCHEMA-v0.5), but no note does.
   Fix: add a `tasks:` note when either side's rows have no titles.
8. `Sources/XcblameKit/Resources/report.html:1012`: minor: any cause whose `whatToDo` starts "Nothing to change"
   goes under "Xcode's own work (not yours to change)". That includes `inputChanged` without a module count, which is
   the user's own edit. Fix: route `inputChanged` to its own line.
9. `Tests/XcblameKitTests/HTMLClarityTests.swift:305` (minor, missing test): the PHASE-002-before-SET-004 check is
   inside `if let`, so it passes when the fixture has neither finding. No unit test calls `RulePlan.ordered`.
   Fix: a direct test with SET-004 listed before PHASE-002 (and SET-030 before PHASE-001).

Checked and fine: `RulePlan.ordered` (DFS with a cycle guard; stable otherwise; currently PHASE-002 has band S and
SET-004 is "Measured", so the actions/housekeeping split never puts a guard after its edit). `verify` is inserted only
before a SET-/SRC- `--edit-project` that has no verify step. Plan steps come from one `fixPlan`: text and markdown cap
by `--top` with "shown X of Y", HTML shows all steps split into two `<ol>`s (their numbering restarts in the
housekeeping list; cosmetic). V12 cannot fail on doctor documents (no checks) or without rules (stays
notApplicable). Tasks tile `tasks` / `tasksReused` / `tasksInModel` are unchanged schema members. Template: no
`innerHTML`; `el()` uses `textContent` / text nodes; data hrefs only `https?:` sources or fixed anchors; 75 glossary
ids, unique, with no dangling `#g-` link. `report.html` (267,301 B ≤ 280 KB) matches the embedded template. Redaction
is a generic JSON walk, so `inXcode`, `whatToDo` and titles are covered. V2: a key with configuration or destination
unknown on one side matches with a `basis:` note; when both sides are unknown it matches without a note (as before).
Hermetic oracle: `executable:` defaults to `/usr/bin/xcodebuild`, so production is unchanged; the oracle has always
used `/usr/bin/xcodebuild` while builds use `xcrun xcodebuild`, and both honour `DEVELOPER_DIR`.

### Tests changed in this range

- RulesEngine: weakened. Plan equality became "every command present (count ≥)". The per-finding order the comment
  claims is not asserted. Acceptable only together with a RulePlan unit test (new finding 9).
- TextReporterDoctor, SchemaContract, SchemaV04/V05, HistoryTests: updated for additive members and the new plan
  wording. Not weaker.
- HTMLBrowser, HTMLDoctor, HTMLTemplate: wording updated, budgets raised 150→280 KB and 250→340 KB. Matches the
  DESIGN decision. The chrome-trace assertion was replaced because that format does not exist: a correction.
- OracleCacheTests: stronger (fake xcodebuild, argv and tree-hash assertions, no network).
- WhyE2E: the whole-build share is asserted only `> 0`. Too weak against §11's 90 % (see the open minor above).
  The flip-without-backtraces case accepts "limit notes or kind clean", so it documents the gap rather than
  checking `signature`.
- CauseEngine and CLI clean-note strings: wording only. BuildKindCache evidence: heuristic suffix, plus a new layout
  test. The FixedCosts `buildsPerDay` value changed with the new definition. The DeepCLI batch-mode line was
  updated with the fix.

### Private names

`git grep -il <private project names> -- Sources Scripts examples README.md`:
no hit. New in Tests: one "the corpus app name" path in `DeepTests.swift` (probe fixture, as before). The untracked
`docs/reviews/html-junior-reader-review.md:205` contains "the corpus app name" twice; scrub it before committing.
