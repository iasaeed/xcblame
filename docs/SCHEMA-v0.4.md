# xcblame schema and contract: v0.4 "CI"

The contract between the three v0.4 lanes. It freezes the new report members, the three new documents (compare, trend,
baseline), the four new text formats, the `xcblame schema` output, exit code 3, the CLI wiring, the HTML view DOM
contracts and the file ownership. Types live in `Sources/XcblameKit/` (`Reporters/ReportDocument.swift`,
`Compare/`, `Trend/`, `Env/GitInfo.swift`, `Env/BuildContext.swift`, `Reporters/Formats/`, `Reporters/Schema/`).
`Tests/XcblameKitTests/Reporters/SchemaV04ContractTests.swift` pins every member name (and `V04Samples` there holds one
sample value of each document). Renaming, removing or retyping a member breaks the contract; a lane that needs a change
stops and asks.

Lanes (disjoint files, see "File ownership and lane notes"):
- **A Formats** (`markdown`, `github`, `junit`, `agent`, `xcblame schema`).
- **B Compare** (`Baseline`, `Regression`, `compare`, `baseline`, `--baseline` / `--fail-if-slower`, the compare HTML view).
- **C Trend and CI** (`trend`, git capture and build context, retention, the trend HTML view, workflows, examples, formula).

## General rules (v0.2 and v0.3 rules unchanged)

- Every `schemaVersion` major stays 1: `xcblame.report/1`, `xcblame.compare/1`, `xcblame.trend/1`,
  `xcblame.baseline/1`. Every v0.4 report member is additive.
- A `T?` member always serializes, as `null` when unknown; it is never omitted, never `0`, `""` or `[]` (new top-level
  report members use `@Added`, new members of the new documents use `@Null`). The one exception is `EnvSnapshot`, whose
  members have always been omitted when nil, so `environment.git` is omitted too.
- A capped array has `<name>Total` and `<name>ShownShare` (share of the table's measure, `null` when the measure is 0).
- Keys sort, two runs over the same input are byte-equal, times are seconds rounded to 6 decimals, dates are ISO 8601,
  ratios are fractions (0.052 is +5.2 %).
- Redaction: `Redactor.redact(_:context:)` has overloads for `ReportDocument`, `CompareDocument` and `TrendDocument`;
  each sets `redacted` and fails closed. A `Baseline` holds no paths and is never redacted.
- Documents are decoded with `JSONReporter.decoder()`; unknown keys are ignored (forward compatibility).

## Report members added in v0.4

| Member | Type | Null / empty when | Meaning | Lane |
|---|---|---|---|---|
| `regression` | `Regression?` | no `--baseline`, or the baseline could not be evaluated (then a note says why) | This build against a baseline ("Regression" below). An absent baseline adds no note (v0.3 precedent: `project`, `doctor`). | B |
| `diagnostics` | `[DiagnosticEntry]` | `[]` when there is no error or warning | Deduped errors then warnings, ordered errors first, then occurrences descending, file, line, message. At most `min(topN, 100)` rows. Filled in `ReportDocument.make`. | done |
| `diagnosticsTotal` | `Int` | never | Unique errors plus warnings (`diagnosticsSummary.errors + .warnings`) before the cap. | done |
| `diagnosticsShownShare` | `Double?` | no error or warning | Occurrences of the shown rows / occurrences of all errors and warnings. | done |
| `build.scheme`, `build.configuration`, `build.destination` | `String?` | build context not captured (`null` plus the existing `build.notes`; a doctor report has none) | `-scheme`, `-configuration`, normalized destination `platform [arch]` (`macOS arm64`, `iOS Simulator`; no device name, see "Fix notes"). | C fills `BuildContext` |
| `environment.git` | `GitInfo?` | not in a git repository, git missing, or not captured | Branch, commit, dirty flag of the repository in the current directory. Omitted from the JSON when nil. | C fills `GitInfo.capture` |

**DiagnosticEntry**: `severity` (`error` / `warning`), `file: String?`, `line: Int?` (1-based), `column: Int?` (1-based),
`message` (first line, at most 300 characters), `occurrences: Int`. The `agent` format and the `github` annotations read
these; nothing else carries diagnostic text.

**GitInfo** (`environment.git`): `branch: String?` (nil on a detached HEAD), `commit: String?` (40 hex), `dirty: Bool?`
(uncommitted changes to tracked files; untracked files do not count), `remoteHost: String?` (host of `remote.origin.url`
only, such as `github.com`: no user, password, path or port). It describes the checkout running xcblame, like the rest
of `environment`, not necessarily the one that built a log analyzed later. The probe goes through `EnvSnapshot.Probe`
(argv in, trimmed stdout out, 2 s timeout), so tests inject it. `EnvSnapshot.capture` already calls
`GitInfo.capture(probe:)`; the stub returns nil.

**BuildContext**: `scheme`, `configuration`, `destination` (all optional). `ReportPipeline.Options.buildContext` carries
it into `build.*` (`ReportDocument.applying(buildContext:)`). Lane C produces it: for `build` from `-scheme`,
`-configuration` and `-destination` in the xcodebuild arguments; for `analyze` from the log manifest's scheme
(`LogManifest.schemeName`; `ModelLoading.swift` may carry it) and nothing else (a log names no configuration or
destination, those stay null with a note). Two documents whose scheme, configuration or destination are both known and
different never compare (see "Key matching").

## Regression (`regression`, `CompareDocument.regression`)

`ReportDocument.Regression` is `Codable`, `Sendable`, `Equatable`:

| Member | Type | Meaning |
|---|---|---|
| `baseline` | `BaselineRef` | `source` (`file` / `history` / `report`), `ref` (path, history id or report path, redactable; null when none), `savedAt`, `kind`, `scheme`, `configuration`, `destination`, `xcode` (all null when unknown), `runs` (runs behind the baseline medians). |
| `verdict` | `String` | `faster` / `slower` / `same` with at least 3 runs on each side, `indicative` with fewer (the sign of `wall.delta` still tells the direction). |
| `wallBasis` | `String` | `processWall` when every run on both sides has `timing.processWall`, else `span` (`build.span`). One basis for all three numbers' `wall`; `busy` is `build.busy`, `criticalPath` is `criticalPath.span`. |
| `wall`, `busy`, `criticalPath` | `Delta` | `baseline`, `current`, `delta` (`current - baseline`), `deltaPct` (`delta / baseline`): seconds, medians over runs, each member null when unknown (deltaPct also when `baseline` is 0). |
| `noiseBand` | `NoiseBand` | `method` (`mad` / `threshold`), `pooledMad` (null under `threshold`), `madMultiplier` (3), `minPct` (0.02), `band` (seconds, null under `threshold`), `runsBaseline`, `runsCurrent`. |
| `attribution` | `[Attribution]` | `kind`, `subject`, `detail` (one line), `deltaSeconds` (null for env). Ordered by `kind` rank `env`, `phase`, `target`, `path`, `task`, `setting` (environment first, DESIGN §6.10), then by \|deltaSeconds\| descending. |
| `thresholdPct` | `Double?` | `--fail-if-slower` / `--threshold` as a fraction; null when not given. |
| `allowancePct` | `Double` | 0.05, added to the threshold under `indicative`. |
| `failed` | `Bool` | A threshold was given and exceeded. Always false without a threshold. Exit 3. |
| `notes` | `[String]` | Why a number is null, why attribution is short, which basis was forced. |

### Noise model (DESIGN §6.10, frozen)

Let `a` be the baseline runs and `b` the current runs, `wall` the metric of `wallBasis`.
- Median of an even count is the mean of the two middle values. `MAD(x) = median(|x_i - median(x)|)`, unscaled; one run has
  MAD 0.
- Both sides have at least `minRunsForBand` (3) runs: `pooledMad = sqrt((MAD(a)^2 + MAD(b)^2) / 2)`,
  `band = max(madMultiplier * pooledMad, minPct * median(a))` seconds. `|delta| > band` gives `slower` (delta > 0) or
  `faster`; otherwise `same`. This is exactly "`|Δ| > 3 × pooled MAD` and `> 2 %`". `noiseBand.method = "mad"`.
- Fewer runs on either side: `verdict = "indicative"`, `noiseBand.method = "threshold"`, `pooledMad` and `band` null.
- `failed`: false without `thresholdPct`. With a verdict other than `indicative`: `verdict == "slower"` and
  `wall.deltaPct > thresholdPct`. With `indicative`: `wall.deltaPct > thresholdPct + allowancePct`. Comparisons are strict.
- `median(a) == 0` or null: `verdict = "indicative"`, `failed = false`, with a note.

### Key matching

`Regression.evaluate(current:baseline:)` compares a build with a baseline when `kind`, `scheme`, `configuration` and
`destination` agree; a field that is null on either side is not compared and `regression.notes` names it. Destinations
agree on the platform, and on the architecture only when both sides have one (`macOS` matches `macOS arm64`). Two known, different values throw
`XcblameError.usage` (exit 2) naming the field and both values. A different inferred Xcode version, or a different
`machine`, is not refused: it is the first `env` attribution (`26.0 -> 26.1 (inferred)`). Attribution beyond `env` needs
a reference with rows: a baseline file has none (summaries only), so `kind` `phase`, `target`, `path` come from
`Regression.evaluate(current:reference:referenceRef:options:)` (compare, or a history baseline), and `task` from
`Baseline.tasks` digests (new tasks only, no removed-task seconds) or task rows; `setting` from findings evidence.

## CompareDocument (`xcblame.compare/1`)

`xcblame compare <a> <b> [--threshold <pct>] [--format text|json|html|markdown|github|agent]` (`junit` exits 2). `a` is the reference, `b` the build under test;
every delta is `b - a`. Each operand is a saved report JSON, a build log (anything `analyze` reads) or a history entry
id; several runs of one side are not an operand form in v0.4 (use `baseline save` for medians). `--threshold` sets
`regression.thresholdPct` and exit 3 as for `--fail-if-slower` (the reference acts as a one-run baseline, so the verdict
is `indicative` and the 5 % allowance applies).

| Member | Type | Meaning |
|---|---|---|
| `schemaVersion`, `tool`, `generatedAt` | | `xcblame.compare/1`; `tool` as in the report. |
| `a`, `b` | `Side` | `label`, `source` (redactable), `runs`, `generatedAt`, `toolVersion`, `kind`, `scheme`, `configuration`, `destination`, `xcode`, `wall`, `busy`, `criticalPath` (medians), `tasks`, `errors`, `warnings`, `degraded`, `git`, `machine`. A trimmed summary: no tables. |
| `regression` | `ReportDocument.Regression` | The headline. Baseline source is `report`. |
| `env` | `[EnvDiff]` | Differing fields only: `field`, `a`, `b` (strings). Order of `field`: `kind`, `scheme`, `configuration`, `destination`, `xcode`, `xcodeSelected`, `macOS`, `hwModel`, `cores`, `memGB`, `rosetta`, `ciProvider`, `branch`, `commit`, `dirty`, `toolVersion`. Environment first (DESIGN §6.10). |
| `envCompared` | `Int` | Number of fields compared (the HTML says "N of M differ"). |
| `phases` | `[Row]?` | One row per phase key: `key`, `status` (`changed` / `same` / `added` / `removed`), `seconds` (task time, `Pair`), `tasks` (`Pair`), `isOther`. Null when a side withheld rollups, with a note. |
| `targets`, `targetsTotal`, `targetsShownShare` | `[Row]?`, `Int`, `Double?` | Same rows per target (task time), by \|delta\| descending, capped at `--top` (default 25; html all). The share is of total \|delta\|. The `other` row keeps the partition. |
| `criticalPath` | `CriticalPathDiff?` | `span` (`Pair`), `byTarget` (`[Row]`, on-path seconds per target, `tasks` null), `byTargetTotal`, `byTargetShownShare`, `notes`. Null when a side has no path. |
| `tasks` | `TaskDiff` | New and removed executed tasks, matched as a multiset on `(rule, target, sigDigest)` from the task rows: `available`, `added` / `removed` (`TaskRef`: `rule`, `target`, `kind`, `seconds`, `onPath`), `addedTotal` / `removedTotal`, `addedShownShare` / `removedShownShare`, `notes`. `available = false` (empty lists, a note) when a side has no rows, such as a saved report that is not a history entry. |
| `settings` | `[SettingDiff]?` | From `findings[].evidenceDetails` of kind `setting`, joined on `ref`: `ref`, `a`, `b`, `provenanceA`, `provenanceB`, only where value or provenance differs. Null (with a note) when neither side has setting evidence. |
| `notes`, `truncation`, `redacted` | | As in the report. `truncation.steps` names `targets`, `tasks`, `settings`, `taskIndexA`, `taskIndexB`. |

`Pair` is `{a, b, delta, deltaPct}` (each nullable, `delta = b - a`, `deltaPct = delta / a`).

The HTML compare page embeds this document plus the HTML-only members `taskIndexA` and `taskIndexB` (the `TaskIndex` of
each side when its operand was a log; each side held to half the data budget, DESIGN §8.2.2). `--format json` never has
them.

## TrendDocument (`xcblame.trend/1`)

`xcblame trend [--kind K] [--scheme S] [--since D] [--by xcode|branch|commit|machine] [--format text|json|html]`.
`--since` is `YYYY-MM-DD` (local midnight) or `<n>d` (n days before `now`).

| Member | Type | Meaning |
|---|---|---|
| `schemaVersion`, `tool`, `generatedAt` | | `xcblame.trend/1`. |
| `filter` | `Filter` | `kind`, `scheme`, `since` (Date), `by` (all null when not given). |
| `entriesTotal` | `Int` | History entries read, before the filter. |
| `entriesUsed` | `Int` | Entries that passed the filter and became points; `sum(groups[].entries)`. |
| `groups` | `[Group]` | One per distinct `--by` value, key ascending, `unknown` last (entries without the value); one group with null `key` without `--by`. `Group`: `key`, `entries`, `series`. |
| `groups[].series` | `[Series]` | One per build kind, kind ascending. `Series`: `kind`, `points`, `wall`, `busy` (`Percentiles`), `xcodeChangeMarkers`. |
| `points` | `[Point]` | Oldest first. `id` (history entry id, what `history show` takes), `time`, `wall`, `busy`, `xcode`, `commit` (full hash), `branch`, `machine`. |
| `Percentiles` | | `n` (points that have the metric), `p50`, `p75`, `p95`: linear interpolation between order statistics (R-7: `h = (n-1)p`, `x[floor h] + frac(h) * (x[floor h + 1] - x[floor h])`), so `p50` is the median; null when `n = 0`. |
| `xcodeChangeMarkers` | `[XcodeChange]` | Between consecutive points whose `xcode` differs and is known on both: `atId` (first point on the new version), `from`, `to`, `time`. Empty under `--by xcode`. |
| `notes`, `redacted` | | Why entries were skipped (undecodable, no timing), `--since` resolution. |

Point values: `wall` is `build.span` (never `processWall`, so entries made by `analyze` and by `build` stay comparable),
`busy` is `build.busy`, `xcode` is `xcode.value`, `commit` and `branch` come from `environment.git` (null for entries
written before v0.4), `machine` is `<hwModel>/<logical cores>c/<memory GB>g` (`Mac15,14/28c/96g`) or null without
`environment`. `--scheme` matches `build.scheme` exactly; entries with a null scheme are excluded by it, with a note.
History entries are summaries (DESIGN §8.3); trend never reads task rows.

## Baseline (`xcblame.baseline/1`, `.xcblame/baseline.json`)

Summaries only, meant to be committed: no absolute paths (`source.refs` are basenames or history ids), no task command
lines, no file or hotspot rows. `xcblame baseline save [--from R]... [--kind K] [--last N] [-o file] [--with-tasks]`
(`--from` is a saved report, a log or a history id, repeated for one run each; or `--kind` / `--last` picks history
entries; default one run, newest; the runs must share one build key, otherwise exit 2) and
`baseline show [file] [--json]`.

| Member | Type | Meaning |
|---|---|---|
| `schemaVersion`, `tool`, `savedAt` | | `xcblame.baseline/1`. |
| `source` | `{kind, refs}` | `kind`: `report` / `history` / `log`; `refs`: one per run (basenames only). |
| `key` | `{kind, scheme, configuration, destination, xcode}` | The build identity ("Key matching"); `xcode` is the inferred version. |
| `wallBasis`, `runs` | `String`, `Int` | `processWall` or `span` (one basis for all runs), runs behind the medians. |
| `wall`, `busy`, `criticalPath` | `{median, mad}` | Seconds, unscaled MAD, null when unknown. |
| `git` | `GitInfo?` | `environment.git` of the first run. |
| `machine` | `String?` | As in trend. |
| `tasks` | `{total, ids}?` | Optional (`--with-tasks`): `ids` = sorted unique 16-hex digests, the first 8 bytes of SHA256(`rule \t target \t sigDigest`) over the executed tasks of the median-wall run. |
| `notes` | `[String]` | |

## Formats

The four formats render one `ReportDocument` (analyze, build, saved report, and `doctor`; for a doctor document
(`input.layout == "project"`) the header says doctor, build-only sections are skipped and findings get the room).
They are pure functions of the document plus `FormatOptions` (`maxBytes`, `configURL`, `reproduceCommand`,
`workspaceRoot`): no environment reads, no clock, so two runs are byte-equal. `ReportPipeline.renderFormat` routes
them; `renderTextFormat` (CLI) does the I/O. Output is UTF-8 with `\n` line ends and ends with one newline, no ANSI,
no emoji. Defaults per format (`ReportBudget.Format`): redact on for `markdown`, `github`, `agent`; budgets in the
table. `--max-report-bytes` overrides the cap (bytes of the rendered body, UTF-8). V13 (JSON size) is not applicable for
these formats (`ReportPipeline.Options.checksSize` false), the reporter enforces its own cap.

| Format | Default cap | Redact | `--format` |
|---|---|---|---|
| `markdown` | 64 KB (65,536 bytes) | on | PR comment body |
| `github` | 64 KB | on | the same body plus annotations and step summary |
| `junit` | none | off | JUnit XML |
| `agent` | 8 KB (8,192 bytes) | on | plain text for an LLM agent |

### markdown (PR comment)

First line is the sticky-comment marker `<!-- xcblame:report -->` (a workflow updates the comment that carries it).
Body, in this order (`{x}` filled from the document, absent parts omitted, never `0` for unknown):

```
<!-- xcblame:report -->
## xcblame: {scheme or "build"} {kind}, {wall} wall

{regression headline, only with `regression`: "**slower** +0.90 s (+5.2 %) vs baseline (median of 5 runs, noise band 0.60 s)"
 or "**indicative** +0.90 s (+5.2 %), 1 run per side: not outside the noise band" ; "FAILED: over the 5 % threshold" when failed}
{or, without regression: "No baseline: pass `--baseline .xcblame/baseline.json` to compare."}

| Metric | Now | Baseline | Delta |
|---|---|---|---|
| Wall | 18.14 s | 17.24 s | +0.90 s (+5.2 %) |
| Busy | ... | ... | ... |
| Critical path | ... | ... | ... |
(without regression: only "Now", columns Baseline and Delta dropped)

{errors/warnings line: "0 errors, 1 warning"}

### Critical path
| # | Target | Work | Seconds | Share |
(top 5 segments of `criticalPath.segments`; "N of M segments, X % of the path" footer)

### Findings
1. **SET-016** (S, high) {title}: {first evidence}. Fix: `{first fixCommands entry}`
(top 3 of `findings`, "N of M findings" footer; "No findings." when none)

<details><summary>Details</summary>

#### Targets
(top 10 `targets` rows: target, owner, task time, on-path s; "N of M targets")

#### Attribution
(`regression.attribution`, env first, top 10)

#### Diagnostics
(`diagnostics`: "error: path:line: message (xN)", errors then warnings, top 20)

#### Environment and validation
(Xcode and its source, macOS, model, cores, git branch and commit, validation "13 pass, 1 warn", degraded notes)

</details>

<sub>xcblame {tool.version}, xcblame.report/1{, redacted}</sub>
```

Table cells never contain `|` or newlines (escaped as `\|` and a space); text is the document's, never HTML.
**Budget.** The part above `<details>` is mandatory and fits any realistic cap (under 8 KB). When the body exceeds
`maxBytes`, drop in this order, each step only while still over: Diagnostics rows beyond 5, Targets rows beyond 5,
Diagnostics, Attribution, Targets, Environment, finding evidence beyond one line, critical-path rows beyond 3; then
append one line `_Truncated to fit {cap}: {steps}. Full detail: {reproduceCommand or "xcblame analyze <input> --format json --top all"}_`
before the footer. If the mandatory part alone does not fit, cut at the last whole line that leaves room for the
truncation line. The rendered body is never longer than `maxBytes`, whatever the cap (a cap below ~200 bytes yields
only the marker line and the truncation line).

### github

`body` is byte-equal to the `markdown` body. The CLI also:
- writes each annotation as one line on **stderr** (the runner reads workflow commands from both streams; stdout stays
  the pure comment body, so `xcblame ... --format github | gh pr comment --body-file -` works);
- appends `body` plus a blank line to the file named by `$GITHUB_STEP_SUMMARY` when the variable is set (created when
  missing; a write failure is a stderr warning, never an error; an append that would take the file over 1 MiB is skipped
  with a warning).

Annotations (`FormatOutput.annotations`), at most 10 `::warning` and 10 `::error` (the runner shows 10 of each per
step), in this order:
1. `::error file={f},line={l},col={c},title=xcblame::{message}` for each `diagnostics` row with severity `error` that has
   a file, by `occurrences` descending;
2. `::warning file={f},line={l},col={c},title=xcblame::{message}` for each `warning` diagnostic that has a file, then
   `::warning file={f},line={l},col={c},title=xcblame hotspot::{decl} {ms} ms (type-check)` for the top hotspots
   (`hotspots[]`, `ms >= 100`);
3. file-less `::error title=xcblame::{N} build errors` / `::warning title=xcblame::build is slower than the baseline by
   {pct}` (the last one when `regression.failed`).

`{f}` is repo-relative: a leading `FormatOptions.workspaceRoot + "/"` or `$REPO/` is stripped; an absolute path outside
the workspace (or `..`, `~`) becomes a file-less annotation carrying the file name and line in its text; an entry with no file is
not annotated. The repo-relative path is taken from the unredacted document, before redaction. Escaping: message `%` to `%25`, `\r` to `%0D`, `\n` to `%0A`;
properties additionally `:` to `%3A` and `,` to `%2C`; `##[` to `##\[` in messages and in the body (the runner's legacy
command syntax).

### junit

One `testsuite` named `xcblame`, one `testcase` per check. Budgets come from `FormatOptions.configURL`
(`.xcblame/config.json`, key `budgets`: `{"wall": 120, "incremental": 15, "criticalPath": 90, "targets": {"App": 40}}`,
seconds, every member optional; a missing file or key means no budget testcases; a malformed file is a stderr warning).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<testsuites name="xcblame" tests="4" failures="1" errors="0" skipped="0" time="18.140">
  <testsuite name="xcblame" tests="4" failures="1" errors="0" skipped="0" time="18.140" timestamp="2023-11-14T22:13:20Z">
    <properties>
      <property name="kind" value="clean"/> <!-- also scheme, configuration, destination, xcode, tool, commit, branch when known -->
    </properties>
    <testcase classname="xcblame.build" name="validation" time="0"/>
    <testcase classname="xcblame.budget" name="wall" time="18.140"><failure message="wall 18.14 s exceeds budget 15.00 s" type="BudgetExceeded">wall: 18.14 s (budget 15.00 s)</failure></testcase>
    <testcase classname="xcblame.regression" name="wall" time="18.140"><failure message="slower than baseline by 5.2 % (threshold 5 %)" type="Regression">...</failure></testcase>
  </testsuite>
</testsuites>
```
Testcases, in this order, each only when applicable: `xcblame.build / validation` (fails when `degraded` or a check
failed, `message` names the check); `xcblame.budget / wall` (time = wall, fails over `budgets.wall`; `incremental`
replaces it when `build.kind == "incremental"` and the key is set); `xcblame.budget / criticalPath`;
`xcblame.budget / target:{name}` per `budgets.targets` entry (time = the target's task time; a target missing from the
document is `skipped`); `xcblame.regression / wall` (only with `regression`; fails when `failed`). With no config and no
regression the suite holds the `validation` testcase only. `time` is seconds with 3 decimals; text is XML-escaped
(`& < > " '`) and stripped of characters illegal in XML 1.0. `timestamp` is `generatedAt`. No host name.

### agent

Plain text for an LLM, deterministic, no markdown tables. Sections in this order; a section with nothing to say is
omitted:

```
xcblame {version} agent report (xcblame.report/1)
result: {succeeded|failed} ({E} errors, {W} warnings)
ERRORS ({unique} unique, {occurrences} occurrences)
- {file}:{line}:{col}: {message} (x{n})
WARNINGS ({unique} unique, {occurrences} occurrences)
- ...
BUILD
kind: clean; scheme: App; configuration: Debug; destination: macOS arm64; xcode: 26.0 (inferred)
wall: 18.14 s; busy: 18.07 s; critical path: 18.14 s; tasks: 577
regression: slower +0.90 s (+5.2 %) vs baseline (median of 5 runs), threshold 5 %, FAILED
CRITICAL PATH (top 3 of 63 segments)
1. 4.20 s (23 %) {target}: {label}
FINDINGS (top 3 of 4)
1. SET-016 [S, high] {title}. Fix: {first fixCommands entry}
NOTES
- {document notes that explain a null, at most 5}
```
Errors first (deduped, `diagnostics`, errors before warnings, occurrences descending, `message` cut at 200
characters), then the summary. The summary (BUILD, CRITICAL PATH, FINDINGS, NOTES) is at most 6,000 bytes (about 1,500
tokens at 4 bytes per token) and is never dropped; the rest of the cap goes to diagnostics. When over the cap: drop
warnings from the tail, then errors from the tail down to 20; the headings keep their totals and a line
`... {n} more {errors|warnings} not shown (xcblame analyze <input> --format json)` closes the list. `result` is `failed`
when `diagnosticsSummary.errors > 0`.

## JSON Schema (`xcblame schema`)

`xcblame schema [--version 1] [--document report|compare|trend|baseline|all]` prints JSON Schema draft 2020-12 to
stdout (pretty, sorted keys, final newline); `--document` defaults to `report` (DESIGN §3.2: the schema of the report
format), `--version` accepts the schema major (only 1; anything else exits 2 listing the known ones).

- Root keys: `$schema` (`JSONSchema.dialect`), `$id` (`urn:xcblame:schema:{document}:1`), `title`, `type: "object"`,
  `required`, `properties`, `$defs`. `all` has `$defs` {report, compare, trend, baseline} (each a full schema with
  `$id`-less body) and `oneOf` of four `$ref`s.
- `schemaVersion` is a `const` (`xcblame.report/1`, ...).
- `required` lists every member that always serializes (so, all non-`@Added` members of the document type, and all
  `@Added` / `@Null` members: they serialize as `null`); a nullable member is `"type": ["string", "null"]` etc.;
  `additionalProperties` stays `true` (additive changes keep version 1).
- Dates are `{"type": "string", "format": "date-time"}`; `Int` is `integer`; enums that are `String` in Swift list their
  values as `enum` only where this document says the values are closed (`verdict`, `By`, `status`, `Regression.wallBasis`,
  `severity` of `DiagnosticEntry`); open vocabularies (`kind`, rule ids) are plain strings.
- Generated from Swift where possible; hand-written mirror tables in `JSONSchema.swift` are acceptable when a test
  encodes `V04Samples`-style sample documents and validates them (Lane A writes a small validator in the tests) and a
  second test compares `required` with the encoded key set of each sample (so a new member cannot be forgotten).
- `taskIndex` (HTML only) is documented in the report schema under `properties` as optional (not in `required`), as are
  `taskIndexA` / `taskIndexB` for compare.

## Exit codes

DESIGN §8.4 unchanged; code **3** is now live: `analyze` or `build` with `--baseline` and `--fail-if-slower`, or
`compare --threshold`, when `regression.failed`.
- `build` keeps xcodebuild's code when it is non-zero (a failed build is not "slower"); exit 3 only when xcodebuild
  succeeded. With `--exit-code xcblame` an analysis or validation failure (1) wins over 3.
- A failed validation check (exit 1) wins over 3 in `analyze`.
- A baseline that cannot be read exits 5 (`logNotFound`: unreadable file) or 1 (`regression: ...` not evaluable); a key
  mismatch exits 2.
- `--fail-if-slower` without `--baseline` is a usage error (2).
- `build --baseline`: when the analysis itself fails (no log, undecodable log) the gate cannot be evaluated, so the exit is
  1 even in the default `--exit-code xcodebuild` mode (stderr says so); xcodebuild's own non-zero code still wins.

## Frozen CLI wiring (done in phase 1)

- `--format text|json|html|markdown|github|junit|agent` in `GlobalOptions` (`sarif`, `chrome-trace` stay unknown, exit
  2). `GlobalOptions.resolvedRedact` = `redact ?? format.budgetFormat.redactsByDefault`.
- `analyze`, `build` and `doctor` render the four formats through `renderTextFormat` (`Sources/xcblame/TextFormats.swift`).
  `OutputFormat.measuresJSONSize` is true for `text` and `json`: only they run V13 on the JSON.
- `RegressionFlags` (`--baseline <file>`, `--fail-if-slower <pct>`) is an `@OptionGroup` of `analyze` and `build`.
  `--fail-if-slower` is a percentage (5 means 5 %), converted to the fraction `thresholdPct`.
- Subcommands registered: `compare`, `trend`, `baseline save|show`, `schema`. `trend` accepts
  `--format text|json|html`, `compare` also `markdown|github|agent` (others exit 2); both take `-o`, `--open`, `--browser`,
  `--xcblame-dir` and the other global flags.
- Marked blocks that lanes fill (`// v0.4 lane X (begin)` ... `// v0.4 lane X (end)`):
  - Lane B: `AnalyzeCommand.run` (evaluate before redaction, exit 3 after emit), `BuildCommand.analyze` / `run` (evaluate,
    exit 3), `CompareCommand.run`, `BaselineCommand.Save.run` / `Show.run`. Phase 1 already calls the stubs there, so
    `--baseline` reaches `Baseline.load` (`not implemented`, exit 1).
  - Lane C: `AnalyzeCommand` and `BuildCommand.pipeline` (set `options.buildContext`), `TrendCommand.run`.
  - Lane A: `SchemaCommand.run`.
- Stubs fail with `XcblameError.notImplemented` (exit 1, `error: not implemented in this build: <what> (v0.4 lane X)`);
  every lane's stub tests (`*StubTests`, `FormatsCLITests`, `CompareCLITests`) are replaced by the real tests.

## HTML views

One template, three kinds of document. The page dispatches on `schemaVersion`'s name part: `xcblame.report` renders the
report sections (unchanged); `xcblame.compare` shows only `<section id="compare">` and calls `renderCompare(doc)`;
`xcblame.trend` shows only `<section id="trend">` and calls `renderTrend(doc)`; any other name shows "this page cannot show
it". The dispatch also fills the index bar, sets `data-first-paint` and `data-rendered="all"` on `body`, and reports a
thrown error into `#js-errors`. The sections are `hidden` by default and stay hidden in report documents.

Template regions (each lane edits only its own, and `make template` regenerates `ReportTemplate.swift`):
`<!-- xcblame:compare:start -->` ... `end`, `/* xcblame:compare:css:start */` ... `end`, `// xcblame:compare:js:start`
... `end` (and the same for `trend`). The JS regions hold `function renderCompare(doc)` / `function renderTrend(doc)`
(function declarations inside the page IIFE: `el`, `$`, `int`, `secs`, `pct`, `makeTable`, `setCounts`, `reportError`,
`copyText` are in scope). Rules of §8.2.6 apply: every data string goes in as text, no network, no `innerHTML` with data,
tables page at 200 rows, no DOM node per task.

### DOM contract: compare (`#compare`)

`#compare` has `data-total` = `targetsTotal` and `data-shown` = rows rendered in `#cmp-targets`. Inside `#cmp-body`:

| Id / selector | Content | `data-total` |
|---|---|---|
| `#cmp-sides` | two `.cmp-side[data-side="a"|"b"]` header cards (`Side` members, environment first) | |
| `#cmp-headline` | `#cmp-verdict[data-verdict]` (`faster` / `slower` / `same` / `indicative`), `#cmp-wall`, `#cmp-busy`, `#cmp-path-span` (each `data-delta` = seconds, text = value and delta), `#cmp-band[data-method]` (the noise band in words), `#cmp-failed` only when `regression.failed` | |
| `#cmp-env` | table, one `tr[data-row]` per `env` entry; "no environment differences" line when empty. First block of the page after the headline | `env.length` |
| `#cmp-attribution` | `li[data-row]` per `regression.attribution`, env first | `attribution.length` |
| `#cmp-phases` | diverging bars, one `[data-row]` per `phases` row | `phases.length` |
| `#cmp-targets` | sortable table, `[data-row]` per `targets` row, paged by 200 | `targetsTotal` (`data-shown` = rendered) |
| `#cmp-path` | critical-path composition, `[data-row]` per `criticalPath.byTarget` row | `criticalPath.byTargetTotal` |
| `#cmp-tasks-added`, `#cmp-tasks-removed` | `[data-row]` per `tasks.added` / `tasks.removed` | `tasks.addedTotal` / `tasks.removedTotal`; `tasks.available == false` shows the note and total 0 |
| `#cmp-settings` | `[data-row]` per `settings` entry; "not applicable" with the note when null | `settings.length` (0 when null) |
| `#cmp-timeline` | present only when `taskIndexA` and `taskIndexB` exist: two canvases on one time axis (`data-axis-seconds` = the longer span) | |

### DOM contract: trend (`#trend`)

`#trend` has `data-total` = `entriesUsed` and `data-shown` = points rendered (all, as SVG marks, never a DOM node per
history entry beyond the accessible table). Inside `#trend-body`:

| Id / selector | Content | `data-total` |
|---|---|---|
| `#trend-filter` | the `filter` in words and `entriesUsed` of `entriesTotal` | |
| `.trend-group#trend-group-{i}[data-key]` | one per `groups[i]` (`data-key` = key or empty) | `groups[i].entries` |
| `figure.trend-series#trend-series-{i}-{kind}[data-kind]` | SVG small multiple: wall line with p50 and p95 rules, one `.trend-point[data-id]` mark per point (title text = id, time, wall, xcode, commit), and a table of the same points, one `tr[data-row]` each | `series.points.length` |
| `.trend-p50`, `.trend-p75`, `.trend-p95` (inside a series) | text, `data-value` = seconds (absent when null) | |
| `.trend-marker[data-at-id][data-from][data-to]` | one per `xcodeChangeMarkers` entry, drawn as a vertical rule | |
| `#trend-notes` | `notes` | |

`make template` is required after editing `report.html`; **both HTML lanes run it, and any `ReportTemplate.swift`
merge conflict is resolved by regenerating it (`make template`), never by hand.** `HTMLTemplateTests` and
`HTMLTemplateV04Tests` fail when the template and its embedded copy drift.

## File ownership and lane notes

Entry points (phase 1 behaviour in brackets):

| File | Symbol | Owner |
|---|---|---|
| `Reporters/Formats/{Markdown,GitHub,JUnit,Agent}Reporter.swift` | `render(_:options:)` [throws `notImplemented`] | A |
| `Reporters/Schema/JSONSchema.swift` | `JSONSchema.render(_:version:)` [throws] | A |
| `Compare/Baseline.swift` | `Baseline.make(from:source:taskRows:now:)`, `load(from:)`, `save(to:)` [throw] | B |
| `Compare/Regression.swift` | `Regression.evaluate(current:baseline:options:)`, `evaluate(current:reference:referenceRef:options:)` [throw] | B |
| `Compare/Compare.swift` | `Compare.run(a:b:options:)` [throws] | B |
| `Reporters/TextReporter+Regression.swift` | `TextReporter.regressionLines(_:)` [returns `[]`] | B |
| `Reporters/HTML/HTMLReporter+Compare.swift` | `HTMLReporter.renderCompare(_:taskIndexA:taskIndexB:options:)` [throws] | B |
| `Trend/Trend.swift` | `Trend.run(history:options:now:)` [throws] | C |
| `Reporters/HTML/HTMLReporter+Trend.swift` | `HTMLReporter.renderTrend(_:options:)` [throws] | C |
| `Env/GitInfo.swift` | `GitInfo.capture(probe:)` [returns nil] | C |
| `Env/BuildContext.swift` | `BuildContext` constructors from xcodebuild arguments and a log manifest [type only] | C |
| `History/Retention.swift` | `Retention.apply(stateDir:policy:now:)`, `dedupeHistory(directory:)` [throw] | C |

**Shared files nobody edits after phase 1** (a change request goes to the orchestrator): `Reporters/ReportDocument.swift`
(and `+Make`, `+Doctor`), `Reporters/ReportPipeline.swift` (`FormatOptions`, `FormatOutput`, `renderFormat`,
`Options.buildContext`), `Reporters/Nullable.swift`, `Reporters/HTML/Redactor.swift`, `Reporters/HTML/HTMLReporter.swift`,
`Sources/xcblame/{GlobalOptions,Xcblame,ExitCode,RegressionFlags,TextFormats,DoctorCommand}.swift`,
`Env/EnvSnapshot.swift` (the struct), `Compare/CompareDocument.swift`, `Trend/TrendDocument.swift`,
`Resources/report.html` outside the marked regions, `Reporters/HTML/ReportTemplate.swift` (regenerated by the
orchestrator after the merge; lanes B and C each run `make template` locally, and a conflict is resolved by
regenerating), `docs/SCHEMA-v0.4.md`, `Tests/XcblameKitTests/{StubSupport.swift, Reporters/SchemaV04ContractTests.swift,
HTMLTemplateV04Tests.swift}`, `Tests/xcblameTests/CLIRunner.swift`.

### Lane A: Formats

Owns `Reporters/Formats/*`, `Reporters/Schema/*`, `Sources/xcblame/SchemaCommand.swift`, the `ReportBudget.Format` enum
(cases, `defaultMaxBytes`, `redactsByDefault` already set; add helpers in `Reporters/Formats/` rather than in
`ReportBudget.swift`), tests `Tests/XcblameKitTests/Formats*`, `Schema*` and `Tests/xcblameTests/Formats*`, `Schema*`.
Fill the four reporters and `JSONSchema.render` per "Formats" and "JSON Schema". Notes:
- Byte caps are in UTF-8 bytes and hard; test the 500-target synthetic log (`Scripts/make-large-fixture.sh`) at 64 KB.
- Render from the document only; the CLI hands over an already redacted document (`$REPO`, `$HOME` tokens appear in
  paths). `github` strips `$REPO/` and `workspaceRoot`.
- `diagnostics` is the only source of error and warning text; there is no raw diagnostic stream.
- Replace the stub tests (`FormatsStubTests`, `SchemaStubTests`, `FormatsCLITests`); keep the budget and route tests.
- Do not touch `ReportDocument`; if a format needs a member, stop and ask.

### Lane B: Compare

Owns `Compare/{Baseline,Compare,Regression}.swift` and new files in `Compare/` (a `CompareTextReporter`, helpers),
`Sources/xcblame/{CompareCommand,BaselineCommand}.swift`, `Reporters/TextReporter+Regression.swift`,
`Reporters/HTML/HTMLReporter+Compare.swift`, the compare regions of `report.html` (markup, CSS, JS), the
`// v0.4 lane B` blocks of `AnalyzeCommand` and `BuildCommand`, tests `Compare*`, `Baseline*`, `Regression*` (kit and
CLI). Notes:
- Implement the noise model exactly as in "Noise model"; unit-test the boundaries (exactly 3 runs, exactly 2 %, exactly
  the threshold, zero baseline, one run per side, both bases of `wall`).
- `compare` operands: report JSON, a log (load through the same path `analyze` uses; `ModelLoading.swift` helpers),
  or a history entry id (`History.show` also gives the task rows for `Compare.Input.taskRows`).
- The compare HTML embeds `taskIndexA` / `taskIndexB` only for log operands; both lanes' HTML work uses
  `HTMLReporter.filledTemplate(toolVersion:generatedAt:title:)`, `escapeScriptData` and `Redactor.redact(CompareDocument)`.
- `Regression.evaluate` is also called from `build`; with several history runs of the same build key it may pass them as
  `current`.
- Edit only the compare regions of `report.html`; run `make template`.

### Lane C: Trend and CI

Owns `Trend/{Trend}.swift` and new files in `Trend/`, `Sources/xcblame/TrendCommand.swift`, `Env/GitInfo.swift` and
`Env/BuildContext.swift` (the wiring into `EnvSnapshot.capture` is done; `ModelLoading.swift` may carry the manifest
scheme), `History/Retention.swift` and the `history prune` extension in `HistoryCommand.swift`,
`Reporters/HTML/HTMLReporter+Trend.swift`, the trend regions of `report.html`, `.github/workflows/{ci,release}.yml`,
`examples/{github-action,danger}/`, `Formula/xcblame.rb`, the Makefile `release` target, the `.xcblame/.gitignore` writer
(`stateIgnoreLines` in `Build/StateFiles.swift`; today it ignores `history/ snapshots/ reports/ results/ logs/ cache/`
and leaves `baseline.json` and `config.json` committed: extend only if a new folder needs it, and add the old text to
`previousStateIgnores`), the `// v0.4 lane C` blocks, tests `Trend*`, `Retention*`, `GitInfo*`. Notes:
- Retention applies to `results/`, `logs/`, `reports/` (newest 200 or 90 days, by file time) and dedupes history by log
  (keep the oldest entry per log identity, see "Fix notes"); `history prune` runs both.
- The workflow examples upload the HTML report as an artifact and post the `markdown` comment; the release workflow and
  formula are templates (publishing is out of scope: no remote yet).
- Edit only the trend regions of `report.html`; run `make template`.
- `Point.commit` and `branch` are null for history written before v0.4; say so in `notes` instead of guessing.

## Decisions taken in phase 1

- `diagnostics` (+ `diagnosticsTotal`, `diagnosticsShownShare`) and `build.scheme|configuration|destination` were added to
  the report: the `agent` format and `github` annotations need diagnostic text and file/line, and baselines, compare and
  trend key on scheme, configuration and destination; neither existed in v0.3 (DESIGN §8.1 sketches them).
- `wall` is `processWall` only when both sides have it, else `build.span`; trend always uses `build.span`.
- `--format github` writes annotations to stderr, the comment body to stdout or `-o`.
- Doctor documents render in the four formats.
- `regression` is null without a note when no baseline was asked for.
- `junit` budgets live in `.xcblame/config.json` (`budgets`), read by the reporter through `FormatOptions.configURL`.

## Integration notes (2026-11-02)

What the merge of lanes A, B and C changed or settled; the contract above is otherwise unchanged.

API additions the lanes reported:
- `MarkdownReporter.render(_: CompareDocument, options:)` (lane A) renders the compare comment. `compare --format markdown`
  prints it, `github` prints the same body (a compare has no file and line, so no annotations) and appends it to
  `$GITHUB_STEP_SUMMARY`, `agent` prints it without the sticky-comment marker under the 8 KB agent cap. `junit` stays a
  usage error (2) for compare, as `sarif` and `chrome-trace` do everywhere.
- `Regression.NotEvaluable` (lane B) is a baseline that cannot be used as one (not a baseline, a newer major, incomplete):
  exit 1. An unreadable file is exit 5, a key mismatch exit 2 (`XcblameError.usage`).
- `Retention.apply(stateDir:policy:now:)`, `Retention.dedupeHistory(directory:)`, `GitInfo.capture(in:)`,
  `BuildContext.from(...)` (lane C).
- `FormatText.mentionSafe(_:)` (integration), used by `FormatText.markdown` and the `github` annotation messages.

Decisions:
- A log operand of `compare` and `baseline save --from` carries `build.scheme`, `.configuration` and `.destination`
  (manifest scheme, then the build request of the build description), the same as `analyze`, so baseline keys match on
  them. It still has no environment snapshot.
- Wall basis: a baseline made from the process wall (`xcblame build`) against a run without one (a log analyzed afterwards)
  leaves `wall` unknown with a note, so the verdict is `indicative`; busy and critical path are still compared.
- `build --baseline`: an unusable baseline is printed, noted in the report and decides the exit code only when xcodebuild
  succeeded (xcodebuild's own code wins). Exit 3 likewise.
- Retention is fixed at 200 entries / 90 days and ignores `history prune --keep` and `--older-than`, which apply to
  `history/` only. It runs after `history prune`, `trend`, `build` and `analyze --format html`.
- History dedupe keeps the oldest entry of a log (`History.save` keeps the existing entry when the newest one is the same
  log; `history prune` removes the later duplicates of a log that was analyzed again after another one).
- Redaction replaces `git.remoteHost` (report `environment.git`, compare `a.git` / `b.git`) with `$REMOTE`; branch names and
  commits are not secrets and stay. `$REMOTE` is a token like `$HOST`.
- `@user` in a compiler message, finding title, target name or annotation of `markdown` / `github` is written as
  `` `@user` `` (outside existing code spans), so a pull request comment never notifies an account. `agent` and `junit`
  are not posted and keep the text as is.
- HTML: `PAGE`, `tables` and `makeTable` are declared above the `schemaVersion` dispatch and shared by the report, compare
  and trend regions (the compare tables and the trend points tables are `makeTable` tables); the compare headline's
  critical-path cell is `#cmp-path-span`, `#cmp-path` is only the composition block, and every id is unique per page.
- `ci.yml` builds, tests, writes the HTML report, the `github` comment body (with the step summary) and the report schema
  from the fixture log, and uploads them as artifacts.
- Test isolation: CLI tests run the binary with a throwaway `XCBLAME_CACHE_DIR` per call. `CLITests.testAnalyzeRulesSummaryAndProjectFindings`
  was order- and load-dependent: AcmeApp has remote packages, so `analyze --project` goes offline at once on a cold
  settings-oracle cache but runs a real `xcodebuild -showBuildSettings` (5 s cap, 3 to 5 s measured) once an earlier test left
  checkouts in the shared `.build` cache, and the two paths differ in `settingsSource` and finding confidence. The test now
  passes `--offline` and asserts the offline resolver's result.

Exit-criteria numbers (DESIGN §11 v0.4, measured 2026-11-02):
- PR comment on a 500-target synthetic log through the CLI (`analyze --model-json`, `SyntheticModel.large(4000 tasks, 500
  targets)`): 3,285 bytes for `markdown` and for `github`, with the default rows and with `--top all`; the worst-case
  document of the unit tests (500 targets, 40 errors, 60 warnings, 30 long findings): 7,781 bytes uncapped. Cap: 65,536.
- `compare` of `fixtures/logs/cli-xcode26` clean (Xcode 26.0, 18.14 s) against `cli-xcode27.1b` clean (Xcode 27.1, 28.49 s):
  `indicative +10.35 s (+57.0 %)`, one run per side, so "no noise band: 1 run on b, 1 on a (3 on each side give a band)". The
  environment difference (`xcode 26.0 -> 27.1`) is the first attribution and the first block after the headline in the text
  output and in the HTML (DOM order: `#cmp-sides`, `#cmp-headline` with `#cmp-band`, `#cmp-env`, `#cmp-attribution`,
  `#cmp-phases`, `#cmp-targets`, `#cmp-path`, tasks, settings, `#cmp-timeline`); the page is 385,261 bytes with no JS error.
  A numeric band needs 3 runs per side (unit tests cover it; the two fixture logs are single runs).

## Fix notes (code review v0.4)

Changes of format or behaviour made after `docs/reviews/code-review-v0.4.md` and its verifier findings.

- **Destination vocabulary.** `build.destination` is `platform [arch]` for every source: `-destination platform=iOS
  Simulator,name=iPhone 17,OS=26.0` is `iOS Simulator`, `platform=macOS,arch=arm64` is `macOS arm64`, `generic/platform=iOS`
  is `iOS`; the build request gives `macOS arm64` / `iOS Simulator arm64`. Device names, ids and OS versions are not part of
  it; a variant replaces the platform (`platform=macOS,variant=Mac Catalyst,arch=arm64` and the build request's
  `sdkVariant` `iosmac` are `Mac Catalyst arm64`, `variant=Designed for iPad` is `Designed for iPad`), and platform and
  variant names are case-folded (`platform=macos` is `macOS`). Two destinations are the same when the platforms are equal and the architectures are equal or
  one side has none (`BuildContext.destinationsAgree`). Agreement is not transitive (`macOS` agrees with `macOS arm64` and with `macOS x86_64`, those two do not), so
  every run of a side or a baseline is checked against the merged destination of all runs; `baseline save --last N`
  over such runs is a usage error (exit 2) naming the runs (history ids) that differ. Baseline selection from history
  and the runs of one baseline use the same rule, so `build` and `analyze` entries of one build are one group (the baseline keeps
  the destination that names an architecture). History entries written before this change may carry a device name
  (`iOS Simulator iPhone 17`); they no longer match a newer entry and fall out of the group.
- **Task digests.** `TaskIndexRow.sigDigest` is the first 16 hex digits of SHA256 of the command line (or title) after the
  machine-specific paths are normalized (`History.portable`): every project root (each distinct `cd <dir>` of the first 200
  tasks' command details, without the `.xcodeproj` / `.xcworkspace` name) becomes `$REPO`; the Xcode developer dir
  (`/Applications/<any name>.app/Contents/Developer`, so `Xcode.app` and `Xcode_26.0.app` agree, and the report's
  `environment.developerDir` when known) `$DEVELOPER_DIR`; a DerivedData folder (the path above `Build/Intermediates.noindex`
  or `Build/Products`: the default one, one inside the repo, or any `-derivedDataPath`) `$DERIVED_DATA`; any home folder's
  user name `$USER`. There is no digest version marker in the history entry or the baseline, so
  `Baseline.tasks.ids` and `taskIndexRows` written before this change do not match digests made now (every task reads as
  new): save the baseline again with `--with-tasks`.
- **Log identity.** A history entry stores `logId` (top level, next to `taskIndexRows`; omitted when unknown):
  `uuid:<UUID>` when the log's file name is a UUID (Xcode's own names, shared with the snapshot folder), else
  `sha256:<hex>-<size>` over the first 1 MiB, the last 64 KiB and the size of the log file (the `Info.plist` of a folder such as an
  `.xcresult`). `History.save` keeps the existing entry only when the newest entry has the same identity, and
  `Retention.dedupeHistory` removes later entries with an identity an older entry has; an entry without `logId` is
  identified by the UUID name of its `input.path`, else it is never a duplicate. The basename alone is never a key. A `sha256:` identity of a log over 1 MiB written before the tail was hashed differs from a new one (the entries stay separate).
- **Regression notes.** `regression.notes` gains: the key fields that were null on a side and so not compared
  (`key: configuration, destination unknown on ...`), and, with `--fail-if-slower`, a remark when the wall is not
  comparable (a `processWall` baseline checked by a run without a process wall); the CLI also prints a stderr warning then.
- **`analyze <history id>`.** The `analyze` argument may be a history entry id or a unique prefix (what `history list`
  shows) in `<xcblame-dir>/history`: the stored report is re-rendered like a saved JSON report (no new history entry, rules
  not run again). An existing path wins over an id; no match is exit 5, several matches exit 2. The stored entry is the
  trimmed report (25 rows of files, hotspots and top tasks).
- **Repo-relative paths and redaction.** For the four text formats the CLI makes the file paths and messages of diagnostics,
  hotspots and file rows repo-relative (`$GITHUB_WORKSPACE`, else the git root of the working directory) on the unredacted
  document, then redacts. Before, redaction rewrote the home first and the workspace prefix no longer matched, so the
  `github` annotations were dropped whenever `$GITHUB_WORKSPACE` was not the working directory's repository.
- **`junit` target budgets.** `--format junit` defaults to `--top all`, so a budgeted target below the 15th row is
  evaluated. With an explicit `--top` (or a saved report cut that way) a target missing from the shown rows is `skipped`
  with a message saying so.
- **`agent`.** At the 20-error floor the diagnostics block is clipped (closed by `[truncated]`), never BUILD, CRITICAL PATH,
  FINDINGS or `next:`. The `NOTES` line of the report now reads `not produced yet: incremental causes (v0.5)`;
  `analyze --no-rules` adds `findings: not produced (--no-rules)`.
- **`trend --since`** leaves out entries that have no time and counts them in `notes`.
- **`release.yml`.** The Apple secrets are step-level `env` of Codesign and Notarize only; every action is pinned by full
  commit SHA with a version comment.
- **Runner commands and mentions.** `##[` becomes `##\[` (and a line-leading `::` gets a backslash) in `FormatText.clip`,
  so every text format (`github`, `agent`, `markdown`, compare) is escaped before its budget is fitted and no cap cuts a
  body mid-line. `mentionSafe` scans left to right like CommonMark: a backslash escapes only outside a code span, a span
  closes at a backtick string of its own length; the Dangerfile's `mention_safe` does the same.
