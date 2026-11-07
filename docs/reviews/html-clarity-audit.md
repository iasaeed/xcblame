# HTML report clarity audit (2026-11-02)

Reader: a junior iOS developer who has never heard of a critical path, a build description or a validator.
Question asked of every element: "can I understand this, and do I know what to do next, without leaving the page?"

Pages audited (generated from the repo fixtures with the v0.5 template, `070f96c`):

| Page | Command |
|---|---|
| analyze | `xcblame analyze fixtures/logs/cli-xcode26-dd/5E3BDB3A….xcactivitylog --build-description fixtures/logs/cli-xcode26-dd/xcbuilddata --format html` |
| doctor | `xcblame doctor fixtures/projects/AcmeApp --offline --format html` |
| compare | `xcblame compare <cli-xcode26 clean> <cli-xcode27.1b clean> --format html` |
| trend | `xcblame trend --format html` after four `analyze` runs in a scratch directory |
| why | `xcblame why --log <cli-xcode26-why incremental> --format html` after analyzing the clean log in the same directory |

Before/after screenshots: the scratchpad `html-clarity/before` and `html-clarity/after` folders named in the change report.

Legend: **T** term without a definition on the page, **U** number without a unit or without "how computed",
**N** null or `—`/`unknown` without a reason next to it, **H** content hidden (collapse, tab, hover, truncation) without
a visible count, **L** chart without a legend or axis labels, **P** table without a one-line purpose, **A** finding or
section without "what to do next", **I** text that only makes sense if you know xcblame internals.

## Whole page (all five kinds)

1. **A** No entry point. The page opens on a title, a path and seven tiles; nothing says what was measured, which number
   matters, or what to do first. A junior has to read every section to find the action.
2. **T** No glossary. Terms used without a definition anywhere: critical path, busy, task time, wall/log span, process
   wall, lane, parallelism, utilization, serial threshold, idle gap, wait, emit-module, planning, PCM, explicit modules,
   module variant, batch, exact/estimated/wmo, type-check, signature, backtrace, build description, basis
   dag/byTiming/mixed/inferred, MAD, noise band, indicative, impact band S/M/L/XS/?, confidence, provenance, shadowed,
   overlay, fix kinds (overlay/cli/project/defaults/recommend), `+V`, on-path weight, owner, what-if, redacted,
   degraded, V1–V15, rule ids (SET-016…).
3. **P** No section says what it shows or what to do with it. Section headers are a noun and a count
   ("Targets shown 13 of 13 (100.0% of task time)").
4. **H** Notes that explain nulls (`notes[]`, e.g. `processWall: only measured by xcblame build`) sit in a collapsed
   "Report notes (4)" list at the bottom of the summary, far from the value they explain.
5. **I** The index bar names sections but not what they are for; "Fixed costs" and "Module graph" mean nothing to a
   junior.
6. Readability bug: the Files table's first column is a `<th>` with `white-space: nowrap`, so long DerivedData paths
   push every other column off-screen on a 13" laptop (seen on analyze and why).
7. Color carries meaning alone in several places: kind-mix bars (no text without hover), the utilization strip shading
   (serial vs idle), compare bars (red/green, the text value is there but not "slower"/"faster").

## analyze

### Summary (header)
- **T/U** Tiles "Log span", "Process wall", "Busy", "Task time", "CPU", "Parallelism 7.72×", "Tasks": no definition; a
  junior cannot tell why task time (127 s) is larger than the span (16.7 s).
- **N** "Process wall: unknown (processWall: only measured by `xcblame build`)" is good, but it is the only tile that
  says why; "CPU" says "from 282 tasks with CPU data" without saying the rest had none.
- **T** Badges "inferred", "clean build", "12 pass · 1 warn", "redacted", "Reader slf v11": jargon with no hover or link
  explanation of what passing means.
- **H** "Report notes (4)" collapsed.
- **A** Nothing says "your build is bound by X; look at Y".

### Critical path timeline
- **T** "critical path", "segment linked by timing, not the DAG", "wait", "serial threshold (2 lanes)", "serial
  stretch", "idle gap", "running tasks", "basis mixed": none defined.
- **L** Legend exists but the utilization strip has no y-axis scale (only "peak 29"); the axis has no "seconds since the
  build started" label; gaps are not labelled as idle/wasted time.
- **U** "shown 108 of 108 (100.0% of path seconds), span 16.5 s, basis mixed": "path seconds" and "basis" unexplained.
- **H** "Path segments as a table (108)" and "Waits on the path (1)" are collapsed `<details>` holding tables with
  numbers. Hover tooltips are the only way to read a segment's name on the canvas.
- **I** Notes "slack: 108 of 583 DAG tasks have zero slack (on a longest path at unlimited cores, 16.891 s)" and "DAG for
  planned tasks and Swift jobs; byTiming for explicit-module tasks…" assume DESIGN §6.2.
- **A** No "what to do": shortening the path is the only thing that makes a clean build faster; the page never says so.

### Targets
- **P** Caption says "Select a row to list its tasks" but not what the table is for.
- **T** Columns "Owner", "On path", "What-if", "Kind mix", "Busy" undefined; owners `localPackage`, `remotePackage`,
  `systemModules`, `buildSystem` are internal enum names.
- **N** "unknown" cells in What-if carry the reason only in a hover `title`.
- **L** Kind mix bar: color only; percentages only on hover.
- **A** No guidance ("targets with large on-path seconds are the ones worth splitting or speeding up").

### Files
- **T** "Granularity" values `exact`, `batch 3 files`, `estimated`, `wmo`; "Type-check"; "On path".
- **N** "unknown" type-check cells explain themselves only on hover.
- Layout bug (above): other columns invisible.
- **P/A** No purpose line; no hint that the slowest file is where to look for slow-to-type-check code.

### Type-check hotspots
- **T** "type-check only", "Weight", "Source debugTimeFunctionBodies", "×3".
- **N** When absent: "not applicable: hotspots: no type-check timing in this log (no -debug-time-function-bodies…)" —
  correct, but no "how to get it" (`build --deep`, or `-Xfrontend -debug-time-function-bodies`).

### Findings and fix plan
- **I** Card title starts with the rule id (`ENV-001`), then a long title; the card is a definition list of internals:
  Impact "? (not measured on this build)", Confidence "medium", Scope, Fix "defaults", Mechanism, Risk, Evidence.
- **T** Impact band letters, `?`, basis (`pathShare`, `measured`), confidence levels, fix kinds, `+V`, mechanism,
  overlay, provenance badges ("project settings (AcmeApp.xcodeproj)"), "shadowed".
- **A** No "is it safe to try?" in words; no plain "what's wrong / why it costs time".
- **H** "Why and how to fix" collapsed (text only, acceptable, but it carries the only plain-language summary).

### Incremental why / fixed costs / module graph
- See the why page below for #7.
- Fixed costs: **T** classes `planning`, `sdkStatCache`, basis `static`/`zero-change build`/`history > 80%`; **U**
  "Per day" depends on an assumption shown as a badge only; no chart. **H** per-class task lists hidden behind a row
  click with no visible count.
- Module graph: **T** "depth", "fan-in", "fan-out", "blockers", "umbrella candidates", "module variants", "PCM tasks",
  "redundant variants", "macro plugins", "1v/2m" node badges; **L** no legend for the dashed thick edges or the badges
  (the hint line mentions edges only); edges have no direction arrows; **A** no "what to do".

### Environment and validation
- **I** Checks listed as "V5 per-rule sums match Xcode's timing summary — warn — WriteAuxiliaryFile: 86 tasks vs
  summary 85": the reader does not know whether a warn invalidates the numbers.
- **T** "Basis", "Signature", "Task keys", "Reader", "Decode warnings", "kind table", "Developer dir".
- **H** "Build, metrics and timing notes (N)" collapsed.

## doctor
- **A** No top-3: 21 findings, all with impact `?`, in fix-plan order; the reader cannot tell which three matter.
- **T** "offline: confidence one step lower", "Rules evaluated", "Suppressed: dedupe or conflicts", "Not applicable: with
  reasons", "Generator none (project edits allowed with --edit-project)", "Settings offline resolver".
- **I** Mechanism lines such as "shadowed by project settings (AcmeApp.xcodeproj): cli on CI (only if the oracle
  confirms the value changes), --edit-project (remove the shadowing value), or recommend".
- **H** Passed / Not applicable / Suppressed lists collapsed (text only; count visible in the summary).
- Build-only sections say "doctor runs no build" without saying which command fills them.

## compare
- **A** Verdict badge "indicative +10.3 s (+57.0%)" with no human sentence: the Xcode version differs, so this is not
  a code regression, and the page does not say so in words.
- **T** "indicative", "wall basis log span", "noise band", "pooled MAD", "Busy", "Critical path", "phase", "(waiting)".
- **U** Diverging bars per phase and per path target are scaled per block, not on one axis; the text value is there
  but not the word "slower"/"faster".
- **L** The noise band is text only, not drawn.
- **P** Environment / Why / Phases / Targets / Path / New tasks / Removed tasks / Settings blocks have no purpose
  line. Attribution kinds `env`, `phase`, `target`, `path`, `task` are badges without definitions.
- **H** "Compare notes (N)" collapsed.

## trend
- **T** p50, p75, p95, busy p50, "Xcode-change markers", "entry id".
- **L** Sparkline has min/max only as `y` axis ends; no axis title; markers show only the new version.
- **H** "Points (4)" collapsed `<details>` holding the table of values.
- **A** No sentence saying whether the builds are getting slower.

## why
- **T** Cause classes (`inputChanged`, `scriptPhase`, `settingsChanged`, `upstreamInterface`, `timestampChurn`,
  `planning`, `firstBuild`, `forced`, `driverRemark`, `unknown`) and sources (`backtrace`, `signature`, `mtimeChurn`…)
  shown as raw identifiers. "V15 pass · causes 10.1 s of 10.1 s executed": V15 unexplained. "basis previous build".
- **H** Ranking tabs: "By critical-path seconds" hidden behind a tab (count not shown on the tab).
- **L** No chart of the executed time by cause class.
- **A** The unknown row shows the hint command, but not what it does or when to run it.

## Top problems (ranked by how much they block a junior)

1. No "start here": nothing says what was measured, the key number, or the next three actions (all pages).
2. No glossary: 40+ terms of art and internal identifiers used without a definition (all pages).
3. Findings lead with rule ids and internals; they do not say in order what is wrong, why it costs time, how much, how
   sure we are, what to change, and whether it is safe.
4. Sections have no purpose line or "what to do", and column headers have no definitions.
5. Reasons for `unknown` values sit in a collapsed notes list at the bottom instead of next to the value.
6. Tables with numbers are hidden in collapsed `<details>` (path segments, waits, trend points), and capped lists do
   not say how to get every row.
7. Charts lack legends/axis titles or are missing where a picture helps (where wall time goes, task time by kind,
   targets on-path vs total, hotspots per file, why by cause class, fixed costs per class).
8. Validation checks are ids plus internal titles; a warn/fail does not say what it means for the numbers.
9. Compare and trend have no human verdict; noise band and "indicative" are unexplained and not drawn.
10. Layout and color: Files paths push columns off-screen; several charts rely on color only.

Each fix is listed in the change's commit message and checked by `HTMLClarityTests`.
