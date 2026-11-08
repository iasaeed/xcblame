# xcblame: design

> Naming: "AcmeApp" is the anonymised name of the reference app (a production app with 64 modules) that the fixtures and the measurements in this document come from.

Status: draft v2.1, 2026-10-31 (v1 reviewed in [REVIEW-2026-10-30.md](REVIEW-2026-10-30.md); resolutions in Appendix B; v2.1 adds the HTML report, §8.2, Appendix B row 39). Owner: xcblame core. Scope: the v1 product (local CLI + CI). Companion docs: [REQUIREMENTS.md](REQUIREMENTS.md) (numbered requirements and traceability) and [RULES.md](RULES.md) (rule catalog spec).

Citation keys used throughout:

| Key | File |
|---|---|
| [BP] | [research/research-build-pipeline.md](research/research-build-pipeline.md) |
| [ET] | [research/research-existing-tools.md](research/research-existing-tools.md) |
| [OC] | [research/research-optimizations-catalog.md](research/research-optimizations-catalog.md) |
| [DS] | [research/research-data-sources.md](research/research-data-sources.md) |
| [PP] | [research/research-dev-painpoints.md](research/research-dev-painpoints.md) (pain points A1-A16 = its ranked list items 1-16) |
| [TM] | [research/research-tool-mistakes.md](research/research-tool-mistakes.md) (requirements R1-R18) |
| [RL] | [research/real-log-inventory.md](research/real-log-inventory.md) (AcmeApp builds on Xcode 26.0.1 and 27.1 beta) |
| [OBS-n] | Observations made while writing this design, from the same [RL] scratch artifacts (SLF, xcresult JSON, DerivedData). Listed in Appendix A. |

---

## 1. Why

Xcode build time is a daily tax, and developers cannot see where it goes. Summed task time misleads (281 s of Swift compile inside a 37.3 s clean build, [PP] A2, https://www.avanderlee.com/optimization/analysing-build-performance-xcode/). Incremental builds do far more work than the edit justifies, and the cause is invisible: a 375-module project re-planned 108 modules on a no-change build, 127 s instead of 15 s, and Apple's answer was "your inputs are changing" ([PP] A1, https://forums.swift.org/t/slow-incremental-builds-because-of-planning-swift-module/84803). The biggest wins in the case studies were not compiler work: a script phase without outputs, SwiftLint, a dSYM upload, a driver flag (AutoScout24 103 s to 18 s incremental; Allegro warm build 27.2 s to 7.5 s; [PP] A6, [BP] §7).

The existing tools do not close this gap. XCLogParser, the only maintained OSS parser, broke five times in twelve months on Xcode 26/27, classifies modern Swift compiles as "other", reports 22,355 fake targets on an Xcode 27 log and has five fix PRs unreviewed ([TM] §1, R1/R2/R4). BuildTimeAnalyzer and xcprofiler depend on a 2016-era flag and are abandoned. Tuist Insights, RocketSim and Bitrise trend durations on a server but do not say why a build was slow or what to change ([ET] §4). The fastest-growing entrant is an LLM prompt skill (AvdLee, 1.27k stars in 7 months), which proves demand for "tell me what to fix and apply it" but has no deterministic attribution engine ([ET] §1.8).

xcblame is one signed Swift binary that runs the same way on a laptop and in CI. It MEASURES a build (wrapping `xcodebuild` or reading an existing log), EXPLAINS it (critical path on the build system's own dependency graph, parallelism, honest per-file attribution, why tasks re-ran, fixed costs, regressions), and FIXES it (a deterministic rule engine over ~100 catalogued optimizations, with a safe xcconfig overlay and an A/B verify harness that reverts anything that broke or slowed the build). Every number it prints is self-validated against the build's own wall clock and Xcode's own timing summary.

---

## 2. Users and jobs-to-be-done

| User | Job | What xcblame gives them | Evidence |
|---|---|---|---|
| Local developer (edit-build-run loop) | "Why did this one-line change take 40 s?" "Which file or function is slow?" | `xcblame analyze` on the last IDE build in under 2 s; `xcblame why` for zero-change and one-file-touch builds; hotspots with file:line and a rewrite pattern. | [PP] A1, A2, A4, W1-W2 |
| Local developer | "Is it me, my machine, or Xcode?" | Env capture (Xcode inferred from the log, macOS, chip, RAM, free disk, thermal, Rosetta, DerivedData volume, concurrency default) on every report; `trend --by xcode|machine`. | [PP] A5, A15, W5 |
| Tech lead / build owner | "What should we change, in what order, and did it work?" | `xcblame doctor` (static audit in seconds), `fix` (ranked plan with impact band, confidence, risk), `verify` (A/B, auto-revert on slower or broken). | [PP] W4, W7, W11; [ET] gap 7 |
| Tech lead | "Stop regressions creeping in" | Local history, `trend` (by commit when git capture is on), baseline file in the repo, `compare`. | [PP] A9, W8; [ET] gap 9 |
| CI owner | "Fail the PR that made the build 10 % slower; post a comment with the cause" | `xcblame build -- xcodebuild ...`, `--baseline`, `--fail-if-slower`, `--format github|markdown|junit|sarif`, exit codes, no backend. | [PP] A9; [TM] R12, R17; [ET] gap 8 |
| AI coding agent | "Give me the build errors and the top 3 causes in 2k tokens" | `--format agent`: errors first, token-budgeted summary, stable rule IDs. | [TM] R12 (xcbeautify#508) |

Non-users for v1: teams that want a hosted dashboard, a remote cache, or an IDE plugin (see §11 scope boundary).

---

## 3. Command surface

One executable, `xcblame`, built with swift-argument-parser. Global flags apply to every subcommand.

### 3.1 Global flags

| Flag | Meaning |
|---|---|
| `--format text\|json\|html\|markdown\|github\|junit\|sarif\|chrome-trace\|agent` | Output format. `text` on a TTY; `json` when stdout is not a TTY and `CI=true`. `html` (§8.2) is accepted by `analyze`, `compare`, `why`, `doctor`, `verify` and `trend`. It always goes to a file, never to stdout. `build` writes HTML alongside its normal output with `--html` (§3.2). |
| `-o`, `--output <path>` | Write the report to a file (stdout keeps a one-line summary). For `html` without `-o` the file is `.xcblame/reports/<yyyyMMdd-HHmmss>-<kind>.html`. `<kind>` is the build kind (`clean`, `incremental`, ...) or the command name (`doctor`, `compare`, `why`, `verify`, `trend`). |
| `--open [--browser <app>]` | After writing an `html` report, open it with `/usr/bin/open` in the default browser, or in `<app>`; if `<app>` fails, it falls back to the default browser with a warning. Without `--open`, xcblame prints the path and an `open "<path>"` hint. Ignored with a note when `CI=true`. |
| `--top <n>\|all` | Rows per ranked table (default 5 text, 25 json, `all` html). Every capped table states total rows and shown share ([TM] BTA#10). `all` lifts the cap (still subject to `--max-report-bytes`). |
| `--redact` | Replace `$HOME`, user name, host name, repo-root prefix and DerivedData hash with tokens. On by default for `markdown`, `github`, `agent` and `html` (`--no-redact` turns it off). |
| `--max-report-bytes <n>` | Hard cap (default 2 MB json, 8 MB html file including the template, 64 KB markdown, 8 KB agent). Truncation is reported in the report itself (html: ordered steps and a banner, §8.2.3). |
| `--explain` | Adds one-line glossary definitions under each section (critical path, busy, task time, emit module, planning, explicit modules, variant) ([PP] W6). `xcblame glossary` prints them all. |
| `--config <file>` | Default `.xcblame/config.json` (JSON only: no YAML dependency). Rule severities, ignores, thresholds, history retention, `buildsPerDay`. |
| `--no-color`, `--quiet`, `--verbose`, `--debug-parser` | Usual. `--debug-parser` prints the decode trace for the first failing record. |

### 3.2 Subcommands

| Command | Purpose | Key flags |
|---|---|---|
| `xcblame build [opts] -- <xcodebuild args>` | Run xcodebuild, own log capture, snapshot the build description (§5.11), analyze. Injects `-resultBundlePath` (if absent) and `-showBuildTimingSummary`. Returns xcodebuild's exit code by default. | `--deep`, `--deep-scope swift,clang`, `--exact-files`, `--runs <n>`, `--kind clean\|incremental\|zero-change`, `--touch <file>`, `--overlay` (deliver `.xcblame/overlay-*.xcconfig` through the command-line wrapper, §7.5), `--exit-code xcodebuild\|xcblame`, `--baseline <file>`, `--fail-if-slower <pct>`, `--timeout <s>`, `--git`, `--html` (also write `.xcblame/reports/<time>-<kind>.html`, §8.2), `--open` |
| `xcblame analyze [<path>]` | Analyze an existing build. `<path>` may be an `.xcactivitylog`, an `.xcresult`, a DerivedData folder, a saved xcblame JSON report (re-render only, e.g. `--format html` from a CI artifact), or omitted (latest build log of the project in cwd). | `--project`, `--workspace`, `--scheme`, `--derived-data <dir>`, `--list`, `--index <n>`, `--reader auto\|slf\|xcresult`, `--format html`, `--open` |
| `xcblame why [-- <xcodebuild args>]` | Explain incremental work. Default: run a settle build, then a zero-change build, and attribute every executed task. `--touch <file>` touches the file's timestamp only (a content-hash build recompiles just that file, §6.6). Without `--`, explains the latest log against the previous build's task index in history (§6.6). | `--touch`, `--show-incremental` (adds `-driver-show-incremental`), `--backtraces` (Task Backtraces via `EnableBuildBacktraceRecording=YES` in xcodebuild's environment, §6.6; MV-2), `--format html` |
| `xcblame doctor` | Static audit, no build. Reads project, xcconfigs, `xcodebuild -showBuildSettings -json`, schemes, SPM/CocoaPods/Carthage manifests, Xcode defaults, machine. Seconds. | `--offline`, `--configuration`, `--rules <ids>`, `--category`, `--fail-on <severity>`, `--format html` |
| `xcblame fix` | Print a fix plan from the latest analysis + doctor. Never writes without `--apply`. | `--rules <ids>`, `--apply` (overlay lines only), `--apply-defaults` (Xcode `defaults` changes), `--force-unverified`, `--install-hook`, `--revert [<plan-id>]`, `--uninstall-hook`, `--plan-out <file>`, `--from <history-id\|report.json>`, `--edit-project` (parsed, not in v0.6: exit 2) |
| `xcblame verify [-- <xcodebuild args>]` | A/B harness: N runs per arm through the same delivery mechanism as the final fix, success and task-set checks, noise band, auto-revert (§7.8). | `--runs <n>` (default 5), `--kind`, `--touch <file>`, `--rules`, `--one-by-one`, `--keep-on-tie`, `--max-minutes`, `--mechanism hook\|cli`, `--plan <id>`, optional `-- <xcodebuild args>` (default: from the plan's analysis), `--format html` |
| `xcblame compare <a> <b>` | Build-vs-build diff of two reports or logs: wall, critical path, phases, targets, files, env, settings. | `--threshold <pct>`, `--format html` |
| `xcblame trend` | Trend from `.xcblame/history/`: p50/p75/p95 by kind, scheme, Xcode, branch, commit, machine. | `--kind`, `--scheme`, `--since`, `--by xcode\|branch\|commit\|machine`, `--format html` |
| `xcblame history list\|show\|prune\|export` | Manage local history. | `--keep <n>`, `--older-than <days>` |
| `xcblame baseline save\|show` | Write or show a committed baseline (`.xcblame/baseline.json`, summaries only). | `--from <report>`, `--kind` |
| `xcblame env` | Print the environment capture used in reports. | |
| `xcblame rules list\|explain <id>` | Rule catalog with evidence and sources. | `--category`, `--json` |
| `xcblame glossary` | Definitions of every term the reports use. | |
| `xcblame schema [--version n]` | Print the JSON Schema of the report format. | |
| `xcblame selftest <corpus-dir>` | Run the parser and validators against a log corpus. | `--update-golden` (dev only) |

`--format html`, `--open` and `-o` work the same way on `analyze`, `compare`, `why`, `doctor`, `verify` and `trend`. `build --html` writes `.xcblame/reports/<time>-<kind>.html` in addition to its normal output: text on the terminal, or the `--format` that CI asked for. `--open` then opens that file. Section contents per command: §8.2.4.

**v0.6 decision (2026-11-05).** `fix` and `verify` follow docs/SCHEMA-v0.6.md: `fix --edit-project` is parsed and rejected (exit 2; project editing waits for MV-4, v0.7), `--force-unverified` also writes unverified non-`+V` steps, `--from` plans from a history entry or a saved report. `verify` takes `--touch` (with `--kind incremental`), `--plan` (default: the newest stored plan with the selected rules, else a fresh plan built as `fix` builds it, from the newest non-deep history entry and a doctor pass), and optional xcodebuild arguments after `--` (default: the scheme, configuration and destination of the plan's analysis). Exit 6 means verify aborted.

**v0.2 decision (2026-11-01).** `XCBLAME_XCODEBUILD=<executable>` makes `xcblame build` run that executable instead of `xcrun xcodebuild`; it is a test hook for the CLI tests, not a user option. `build` streams xcodebuild's stdout unchanged, so `build --format json` needs `-o <file>` to get clean JSON.

**v0.4 decision (2026-11-02).** `xcblame build` takes the xcodebuild arguments directly after `--` and never the word `xcodebuild` (`xcblame build --html --baseline .xcblame/baseline.json --fail-if-slower 10 -- -scheme App build`); `--git` is not a flag (branch, commit, dirty and the remote host are always captured into `environment.git`, §8.1), `--runs`, `--kind`, `--touch`, `--deep` and `--overlay` wait for v0.5 and v0.6, and each `compare` operand is a report JSON, a build log or a history entry id (`--format text|json|html|markdown|github|agent`, not `junit`).

### 3.3 `xcblame analyze` (mock, AcmeApp clean build, Xcode 26.0.1)

All numbers are recomputed from the r26 artifacts ([RL] scratch: `r26-xcresult-buildlog.json`, `slf26/`, `dd26/`) with the definitions in §5.5 (executed task = task-depth section with a rule name; 577 tasks) and §6.3 [OBS-6, OBS-13, OBS-14]. The path shown was computed with the timing fallback of §6.2; the DAG method must reproduce it (v0.2 exit criterion).

```
$ xcblame analyze
xcblame 0.4.0 · latest build log for AcmeApp.xcodeproj (DerivedData …/dd26)
  log     20E8B73D · SLF v11 · reader slf (no result bundle in DerivedData)
  xcode   26.0 inferred from task commands (MacOSX26.0.sdk, 25A352) · xcode-select now: 26.0.1
  build   CLEAN · scheme AcmeApp · Debug · macOS arm64 · succeeded · 1 warning
  host    Mac15,14 · 28 cores · 96 GB · thermal not recorded (log analyzed after the fact)
  graph   build description 6f0b463d (snapshot) · 747 commands · 212 tasks keyed, 365 not in manifest
TIME  log span 18.1 s · busy 18.1 s · idle 0.1 s · task time 139.8 s in 577 tasks (7.7x avg)
      CPU 123.3 s (278 tasks with metrics; 188 placeholder records ignored) · peak 29 lanes
      ≤ 2 of 28 cores busy for 7.5 s (41 %) · process wall unknown (`xcblame build` measures it)
CRITICAL PATH 18.1 s  basis: DAG for planned tasks, timing for dynamic tasks     s   share
   0.0– 1.8  planning: create build description 1.4 s                        1.8   10%
   1.8– 3.7  SDK stat cache (ClangStatCache, first build in this DerivedData)  1.9   10%
   3.7– 8.3  swift-syntax: SwiftSyntax emit-module 2.7 s, SwiftParser 0.8 s   4.6   25%
   8.3–11.2  LocalizeCore: planning 0.5 s, then 26 Clang PCM tasks 2.3 s      2.9   16%
  11.2–14.2  LocalizeCore compile (on path: Models.swift 3.0 s)               3.0   17%
  14.2–15.3  Clang PCMs for AcmeApp's variant (Foundation … SwiftUI)          1.1    6%
  15.3–17.6  AcmeApp compile (StudioView.swift 2.4 s)                         2.4   13%
  17.6–18.1  link AcmeApp.debug.dylib + stub, register, module reports        0.5    3%
TARGETS            task time  on path   note
  LocalizeCore       54.7 s    3.6 s    18 single-file frontends ran concurrently
  SwiftSyntax        39.8 s    2.7 s    swift-syntax 602.0.0, used as a library
  AcmeApp            13.9 s    2.9 s    asset catalog 3.4 s ran in parallel (off path)
  explicit modules   13.2 s    4.0 s    143 PCM tasks, 64 modules, 79 redundant variants
  SwiftParser        10.5 s    0.8 s
  build system        3.7 s    3.7 s    planning + SDK stat cache
  (6 more rows, 4.1 s)                   shown 6 of 12 rows = 97 % of task time
HOTSPOTS  type-check (from -debug-time-function-bodies already in this log) · user code · 4 of 4
  425 ms  Sources/AcmeApp/StudioView.swift:399   StringsView.body       inside on-path compile
  250 ms  Sources/AcmeApp/StudioView.swift:8     StudioView.body        inside on-path compile
  188 ms  Sources/AcmeApp/WorkflowViews.swift:7  TranslationsView.body
   62 ms  Sources/AcmeApp/StudioView.swift:394   expression (warn limit 50 ms)
FINDINGS 4 of 4                                                                 confidence
  S   SET-024  module variants: Swift 5 app vs Swift 6 packages, -D SWIFT_PACKAGE;     high
               PCM chains gate LocalizeCore and AcmeApp: ≤ 4.0 s on path
  S   DEP-012  swift-syntax compiled from source: 54.5 s task time, ≤ 4.6 s on path    medium
  XS  SRC-006  2 SwiftUI bodies: 0.68 s type-check inside an on-path compile           medium
  ?   SET-016  compilation caching off; covers app target; SPM packages unverified     medium
checks 13 pass, 1 warn (V5: WriteAuxiliaryFile 85 tasks/0.47 s vs summary 84/0.28 s) · saved history
```

### 3.4 `xcblame doctor` (mock, same project, no build)

AcmeApp facts used: XcodeGen-generated (`project.yml`), objectVersion 77, no xcconfig files, Debug `dwarf`/`-Onone`/`ONLY_ACTIVE_ARCH=YES`, Release `wholemodule`/`-O`, `SWIFT_VERSION=5.0`, scheme `parallelizeBuildables=YES`, no script phases, `LocalizeCore` depends on `SwiftSyntax` and `SwiftParser` products of swift-syntax 602.0.0, packages built in Swift 6 mode ([OBS-11], [OBS-15]). Confidence follows §7.1: no build, so no `high`.

```
$ xcblame doctor
xcblame 0.4.0 doctor · AcmeApp.xcodeproj (objectVersion 77, pbxproj) · Xcode 26.0.1 · 2.8 s
  generator  XcodeGen (project.yml) → project edits disabled; hook goes into project.yml
  settings   xcodebuild -showBuildSettings -json: 2 configurations x 2 targets + 8 package targets
  graph      2 project targets, 1 local package (LocalizeCore), 1 remote package (swift-syntax, exact)

PASS (12)  Debug: singlefile, -Onone, dwarf, ONLY_ACTIVE_ARCH=YES, batch mode on, integrated driver,
           explicit modules on · Release: wholemodule, -O, dwarf-with-dsym · scheme parallel builds,
           Dependency Order · no -ld_classic · no bitcode
N/A (6)    no script phases (PHASE-001..005) · no CocoaPods/Carthage · no dynamic Swift frameworks
           (SET-023) · no bridging header

FINDINGS                                                        impact  conf    fix
  DEP-012  swift-syntax 602.0.0 is a library dependency of           ?      medium  recommend
           LocalizeCore (SwiftSyntax, SwiftParser). Prebuilts cover
           macro targets only, so it compiles from source on every
           clean build. First: keep swift-syntax code in a stable
           leaf module; consider a binary target. Run `analyze`
           on a clean build to size it.
  SET-024  App target SWIFT_VERSION 5.0, packages build in Swift 6:   ?      medium  recommend
           SDK Clang modules get one variant per language mode.
  SET-016  COMPILATION_CACHE_ENABLE_CACHING not set (Xcode 26+).     ?      medium  overlay +V
           Covers project targets; SPM package caching unverified.
  ENV-004  DerivedData (392 MB) not excluded from Time Machine        ?      low     recommend
           (tmutil isexcluded = false). Needs measurement.

PLAN  1. `xcblame verify --rules SET-016 --kind clean --mechanism hook` (5 runs per arm)
      2. if kept: `xcblame fix --apply` writes .xcblame/overlay-Debug.xcconfig; the hook for
         XcodeGen is printed: configFiles: {Debug: .xcblame/hook-Debug.xcconfig}
```

**v0.3 decision (2026-11-01).** A project like AcmeApp, whose Debug values are written in the pbxproj (project or target `buildSettings`), shadows the overlay the hook includes from the project-level base xcconfig: those SET findings carry no overlay lines and offer `xcblame fix --rules <id> --edit-project` (`cli` first on CI, `recommend` for generated projects with the generator-source change as evidence). Shadowing is `SettingsOracle.isShadowed(…, byLevelAbove: .projectXCConfig)`: an assignment above the project xcconfig without `$(inherited)`.

### 3.5 Other outputs (shape only)

- `xcblame why` lists every task that ran in a zero-change build, each with exactly one primary cause (§6.6) and seconds, grouped by cause class (`script: no outputs declared`, `input mtime changed, content unchanged: X.swift`, `signature changed: OTHER_SWIFT_FLAGS`, `upstream module interface changed: CoreKit`, `backtrace: ruleInputRebuilt <- <task>`, `unknown`), with the fixing rule ID.
- `xcblame verify` prints a table per rule: arm, runs ok/total, p50 ± MAD, delta, verdict `kept` / `kept (tie)` / `reverted (slower)` / `reverted (within noise)` / `reverted (broke build)` / `reverted (task set changed)` / `reverted (no effect)` / `indicative`, the delivery mechanism, and the per-target scope of the change (v0.6 decision (2026-11-05).: `indicative` and `reverted (no effect)` added, SCHEMA-v0.6 Decision 11).
- `--format github` emits a markdown PR comment and `::warning file=...,line=...::` annotations for hotspots and diagnostics.
- `--format html` writes one self-contained page (§8.2). `xcblame analyze --format html --open` on the AcmeApp clean build writes about 0.2 MB: header, critical path timeline with a utilization strip, targets, files, hotspots, findings, environment and validation.

---

## 4. Architecture

### 4.1 Module map (SwiftPM targets; external dependency: swift-argument-parser only)

| Target | Responsibility | Key types |
|---|---|---|
| `XcblameCLI` (executable) | Commands, flag parsing, exit codes, TTY detection. No logic. | `BuildCommand`, `AnalyzeCommand`, ... |
| `Runner` | Spawns `xcodebuild` with injected args, streams output unchanged, forwards signals, measures process wall, owns timeouts, writes the command-line xcconfig wrapper (§7.5). | `XcodebuildInvocation`, `ArgInjector`, `XcconfigWrapper`, `ProcessClock` |
| `Locator` | Finds logs (explicit path, `-derivedDataPath`, per-workspace settings, `IDECustomDerivedDataLocation`, default; DerivedData matched by `info.plist` `WorkspacePath`), reads `LogStoreManifest.plist`, selects by class/domain/content (§5.2), waits for log completeness. | `LogCandidate`, `ManifestReader`, `IntegrityProbe` |
| `Gzip` | Streaming inflate over system `libz` (linked as a system library), trailer CRC32/ISIZE check, salvage of truncated streams. | `InflateStream` |
| `SLFParser` | Byte-level tokenizer and schema-table decoder for SLF v10-v13+. Streaming. | `SLFTokenizer`, `SLFDecoder`, `ClassSchemaTable`, `DecodeWarning` |
| `XCResultReader` | Runs `xcrun xcresulttool get log --type build` and decodes the JSON section tree incrementally; `get build-results` for issues. | `XCResultLogDecoder` |
| `BuildGraph` | Reads and snapshots the build description (`XCBuildData/<sig>.xcbuilddata/manifest.json`, `target-graph.txt`, `build-request.json`) and the modules reports; builds the task DAG (§5.11, §6.2). | `BuildDescriptionSnapshot`, `TaskDAG` |
| `BuildModel` | Reader-independent normalized model (common subset + optional SLF-only fields, §5.7), arena-allocated, string-interned. | `BuildModelBuilder`, `TaskClassifier`, `KindTable` |
| `Diagnostics` | Decodes, assembles and dedupes compiler/build diagnostics (§5.10). | `DiagnosticDecoder`, `Diagnostic` |
| `Env` | Machine and Xcode environment capture; Xcode version inference from the log (§5.9). | `EnvSnapshot`, `XcodeVersionInference` |
| `ProjectModel` | Read-only project understanding: pbxproj (OpenStep), Xcode 27.2 `project.xcproj` (JSON), xcconfig resolution, `-showBuildSettings -json`, schemes, workspace, SPM, CocoaPods/Carthage, generator detection. | `ProjectGraph`, `SettingsOracle`, `SettingProvenance` |
| `Analyzers` | Pure functions over `BuildModel` (+ `TaskDAG`, `ProjectModel`, history): timeline, critical path, utilization, attribution, hotspots, incremental cause, fixed cost, module graph, regression, validator. | `Analysis`, `Validator` |
| `Rules` | Data-driven rule catalog + engine (predicates over `ProjectModel`/`Analysis`/`EnvSnapshot`; signal dedupe). | `RuleSpec`, `Finding`, `RuleEngine` |
| `Fixers` | Plans and application: `OverlayWriter`, `HookInstaller`, `ProjectEditor`, `SchemeEditor`, `DefaultsWriter`, `CodeAdvisor`. | `FixPlan`, `AppliedChange`, `Backup` |
| `Verify` | A/B harness on `Runner` + `Analyzers`. | `ABRun`, `NoiseModel` |
| `Reporters` | text, json, html (embedded template, §8.2), markdown/github, junit, sarif, chrome-trace, agent; size budgets and ordered truncation; redaction; opening a written report. | `ReportDocument`, `Redactor`, `ReportBudget`, `HTMLReporter`, `ReportTemplate`, `ReportOpener` |
| `History` | `.xcblame/history/` store (summary + compact task index, §8.3), baselines, trend math, retention. | `HistoryStore`, `TaskIndex`, `Baseline` |

### 4.2 Data flow

```
          xcblame build -- <xcodebuild args>                     xcblame analyze [path]
                       |                                                  |
   Runner (inject -resultBundlePath, -showBuildTimingSummary,             |
   --deep flags, xcconfig wrapper, deep DerivedData) -> process wall      |
                       |                                                  |
                       v                                                  v
        Locator (manifest: class/domain/content selection, integrity wait, candidates)
                       |                                                  |
     BuildGraph.snapshot(XCBuildData/<sig>.xcbuilddata, modules reports) |  (build mode: right after exit)
                       |                                                  |
   .xcresult present? --yes--> XCResultReader ---+                        |
          | no / failed                          |                        |
          v                                      |                        |
   Gzip -> SLFParser -------------------------> BuildModelBuilder + TaskClassifier (KindTable vN)
                                                 |      + Diagnostics
                                                 v
                        BuildModel (tasks, targets, timings, attachments, diagnostics,
                        emitted timing text, timing-summary aggregates, task keys)
                                                 |
   ProjectModel ----+        TaskDAG (manifest edges + dynamic attachment) <- snapshot
   Env snapshot ----+-----> Analyzers -------------------------------> Validator (V1-V15)
   History index ---+          |                                             |
                               v                                             |
                     RuleEngine (RuleSpec catalog, signal dedupe) -> Findings
                               |
                 +-------------+--------------+
                 v                            v
         Reporters (formats, redact,    Fixers: plan -> overlay | hook | --edit-project
         size budget)                         |
                 |                            v
         History store  <-----------  Verify (same mechanism as the fix, checks, auto-revert)
```

### 4.3 Cross-cutting design rules

1. Analysis never fails the user's build. In `build` mode xcblame returns xcodebuild's exit code unless `--exit-code xcblame`. Parser or analyzer failure prints one warning and a partial report marked `degraded` ([TM] R17, TU#11168).
2. Read-only by default. Without flags, xcblame writes only inside `.xcblame/` (history, snapshots, tmp) and its cache directory. On first write it creates `.xcblame/.gitignore` that ignores `history/`, `snapshots/`, `reports/`, `tmp/`, `backup/` and keeps committed files (`config.json`, `baseline.json`, `overlay-*.xcconfig`, `hook-*.xcconfig`) tracked ([TM] R11).
3. No force unwraps, no `fatalError`, no `try!` in parsing or analysis code; lint gate in CI ([TM] XCM#38, XPJ#1055).
4. Linear or n log n algorithms only on log-sized inputs; no backtracking regex on untrusted text ([TM] R8, xcbeautify#138).
5. Bounded memory: the parser streams; the model interns strings; emitted compiler text is stored by offset into a memory-mapped temp file and materialized only for rows a report shows. Budget: 300 MB RSS for a 1 GB inflated log ([TM] R8).
6. Everything version-dependent lives in data tables with Xcode ranges (KindTable, ClassSchemaTable, RuleSpec applicability, known-issue table).
7. Titles are never used for decisions. They are displayed, and they may annotate tasks the structural classifier left as `other` (§5.5).

---

## 5. Data sources and exact formats we rely on

Confidence tags: [V-local] verified on the AcmeApp v11/v13 artifacts; [V] verified in a primary source by the research; [S] secondary; [MV-n] must-verify item in §10.

### 5.1 Source priority

| Need | Primary | Fallback | Notes |
|---|---|---|---|
| Task tree with start/duration | `xcresulttool get log --type build` JSON (Xcode 16+, needs a result bundle) | SLF parser on `.xcactivitylog` | Same BuildModel subset (§5.7). xcodebuild with `-resultBundlePath` wrote the bundle only to that path; `DerivedData/Logs/Build` held only `.xcactivitylog` + manifest [OBS-1]. IDE builds: unknown [MV-1], so the SLF parser is mandatory for IDE builds and Xcode 10-15. When both exist, SLF is still read for the SLF-only fields (§5.7). |
| Task dependency edges | Build description `manifest.json` (llbuild manifest) matched by signature (§5.11) | Timing inference (§6.2) | 747 commands with inputs/outputs for the AcmeApp clean build [OBS-12]. |
| Per-task CPU, RSS, precise wall | `TaskMetrics` attachment (enrichment only) | section start/stop doubles | Present from SLF v11 (Xcode 15.3) [TM] XLP#203; placeholder records excluded (§5.6). |
| Why a task ran | `TaskBacktrace` attachment | history task index diff, script I/O, mtimes, signatures, driver remarks | Not present in any AcmeApp log [OBS-3]; needs Task Backtraces [MV-2]. |
| Phase totals | Xcode's timing summary inside the log (`com.apple.dt.IDE.timing.aggregate` sections, 22 per AcmeApp log [RL]) | stdout `-showBuildTimingSummary` | Validation oracle (§6.11 V5); availability in IDE logs [MV-10]. |
| Module variants | `XCBuildData/clangmodulesreport/` and `swiftmodulesreport/` CSVs (per module: variant list and the flags that differ) | counting PCM tasks per module name | Written when `generatePrecompiledModulesReport` is true in the build request [OBS-15]. |
| Build kind facts | `build-request.json` (action, `enableIndexBuildArena`, configuration, command-line overrides, run destination) | log-derived counts (§6.7) | [OBS-15]. |
| Compilation-cache hit/miss | `BuildOperationMetrics` (build-level counters only) | `COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS` remarks | Absent in AcmeApp (caching off) [OBS-3]. |
| Per-function / expression type-check | `-debug-time-*` text in emitted output | `-warn-long-*` diagnostics | `--deep` or user-set flags. |
| Per frontend-job timers | `-stats-output-dir` JSON | none | `--deep`. |
| C/ObjC per-TU | clang `-ftime-trace` JSON | CompileC task times | `--deep`. |
| Project and settings | `-showBuildSettings -json` (values) + pbxproj/xcproj/xcconfig (provenance) | own resolver (`--offline`) | §7.4. |

### 5.2 Container, discovery, selection and integrity

- File: gzip stream `DerivedData/<Name>-<28 letters>/Logs/Build/<UUID>.xcactivitylog` plus `LogStoreManifest.plist` (`logFormatVersion`; per log `fileName`, `className`, `domainType`, `schemeIdentifier-schemeName`, `timeStartedRecording`/`timeStoppedRecording` in 2001-epoch seconds, `primaryObservable.highLevelStatus` S/W/E and issue counts) [RL]. Package resolution logs live in `Logs/Package` with their own manifest [RL]; read for SPM resolution cost.
- **Selection never uses titles.** Candidates = manifest entries in `Logs/Build` whose `domainType` is `Xcode.IDEActivityLogDomainType.BuildLog` and whose `className` is in the build-log class family (`IDECommandLineBuildLog` for xcodebuild [RL]; IDE logs use IDEActivityLogSection-family classes per [DS] §1.2, exact names [MV-15]). A clean action produces its own entry with the same class and domain [OBS-15], so each candidate is confirmed by content: the newest candidate whose decoded tasks include at least one executed task of a non-planning, non-clean kind (decode stops at the first such task, so the check costs milliseconds). `--list` shows candidates with time, scheme, status, kind; `--index` picks one. Order is manifest `timeStartedRecording`, file mtime as tiebreaker ([TM] XCP#22).
- DerivedData matching: `<dd>/info.plist` `WorkspacePath` equality, not hash recomputation [DS] §1.1. Search order: explicit path, `-derivedDataPath`, per-workspace `WorkspaceSettings.xcsettings`, `IDECustomDerivedDataLocation`, default. On failure, print every directory searched and the candidates found ([TM] XLP#214, BTA#30). If the DerivedData has no build log at all and the last invocation was plain `xcodebuild build`, the error says: "xcodebuild may not write an activity log without -resultBundlePath; run it through `xcblame build -- ...`" [MV-16].
- Integrity: after xcodebuild exits, poll the newest log until size is stable for 500 ms and the gzip trailer CRC32/ISIZE verify, up to `--timeout` (default 20 s). A truncated stream is inflated as far as possible and parsed as a partial build marked `degraded: truncated` ([TM] R7, XLP#139, XCP#34, TU#11168).

### 5.3 SLF token grammar (as observed in v11 and v13)

```
log        := "SLF0" token*
token      := int | double | string | json | classdef | instance | array | null
int        := DEC+ "#"                    first token = log format version: 11 (Xcode 26.0.1), 13 (27.1)
double     := HEX{16} "^"                 little-endian IEEE-754 bits; seconds since 2001-01-01
string     := DEC+ "\"" BYTE{n}           n = byte length, raw bytes (UTF-8); may contain CR, LF, NUL
json       := DEC+ "*" BYTE{n}            JSON text (attachments)
classdef   := DEC+ "%" BYTE{n}            defines next class-table entry
instance   := DEC+ "@"                    1-based index into class table (1@ = first class defined)
array      := DEC+ "("                    element count; elements follow
null       := "-"
```

Verified locally [V-local]: payload digits are decimal for `#`, `"`, `*`, `%`, `@`, `(` and hex only for `^`; class refs are 1-based [OBS-8]; 18,735 (v11) and 20,564 (v13) tokens decoded with zero errors by `tools/slftok.py`. Byte-length reading matches XCLogParser v0.2.49's UTF-8 fix; the old doc claimed UTF-16 units [DS] §1.3. AcmeApp paths are ASCII, so non-ASCII paths remain a corpus item [MV-5].

Class table observed in both versions, same order: 1 `IDECommandLineBuildLog`, 2 `IDEActivityLogCommandInvocationSection`, 3 `IDEActivityLogSection`, 4 `IDEDiagnosticActivityLogMessage`, 5 `IDEFoundation.IDEActivityLogSectionAttachment`, 6 `DVTDocumentLocation`, 7 `DVTTextDocumentLocation` [RL]. Other classes known from XCLogParser history (must be tolerated): `IDEActivityLogMajorGroupSection`, `IDEActivityLogUnitTestSection`, `IDEActivityLogMessage` and the analyzer message family, `DBGConsoleLog`, `IDEConsoleItem`, `Xcode3ProjectDocumentLocation`, `IDELogDocumentLocation`, `IBDocumentMemberLocation`, `DVTMemberDocumentLocation` [DS] §1.4. The top-level layout of IDE-produced logs (root class, the command-line-only trailing int of [DS] §1.4 item 11) is not in our corpus [MV-15].

Section record, leaf example "Create build request" [RL]:

```
v11 (20 tokens): 2@ int(sectionType) str(domainType) str(title) str(signature) dbl(start) dbl(stop)
                 null(subsections) null(text) null(messages)
                 int int int (wasCancelled, isQuiet, wasFetchedFromCache)  null null (subtitle, location)
                 str(commandDetails) str(uniqueIdentifier) null null (localizedResult, xcbuildSignature)
                 arr(attachments)
v13 (22 tokens): ... dbl dbl null null null  int int int int  null null  str str  null null  arr  int
```

Slot names follow XCLogParser's field order ([DS] §1.4). In this leaf the xcbuildSignature slot is `null`; in task sections it holds a hex string (§5.6). v13 adds two ints: one among the flag ints (XCLogParser #261/#262 identify it as `resultCode` placed before the three bools) and one trailing [RL] §format-1, [TM] XLP#261. Which v13 int is which must come from a failed-task fixture, not from position [MV-5].

### 5.4 Decoder strategy: schema table plus type-sequence sniffing

Positional decoding with fixed offsets caused every XCLogParser break ([TM] §1a). Our decoder:

1. Reads tokens lazily. For each `instance` it looks up the class name and the `ClassSchemaTable` row for `(className, logFormatVersion, layout)` where `layout ∈ {commandLine, ide}`. A row is a list of typed slots, each with a semantic name and an `optional` flag.
2. Matches actual token types against the row's slot types. On mismatch it tries the other known rows for that class and picks the one whose type sequence matches through the next class boundary. If none match, it consumes tokens to the next section instance at the same array depth (counted arrays make depth exact), keeps slots it can type-match by shape, and emits `DecodeWarning(schemaDrift, class, version, offset)`.
3. Unknown class names are opaque nodes, skipped by structure, one warning per class name ([TM] R1).
4. Attachments dispatch by identifier suffix (`TaskMetrics`, `TaskBacktrace`, `BuildOperationMetrics`); unknown identifiers kept as raw JSON up to 4 KB and ignored. Every JSON field optional ([TM] PR#235/#237, XLP#245/#251).
5. Semantic invariants after decode (failed task not `cancelled`, start ≤ stop, timestamps within the session window, §6.11). A violated invariant on a field decoded via a sniffed row downgrades that row and is reported ([TM] XLP#262).
6. Byte tokenizer; strings decoded on demand as UTF-8 with replacement ([TM] R14, PR#254).

### 5.5 Executed tasks, classification and attribution

**Executed task (structural definition).** A task is a section at task depth (a direct child of the build's top section: `Building ...` in xcodebuild logs, depth 2 in the xcresult tree; IDE layout per [MV-15]) whose `commandDetails` has a rule name, and whose domain is a build-log section, not a timing aggregate or a log/summary section. Nested sections (per-file children, Xcode 27's extra parent) are sub-spans used only for attribution. Rule: the unit is the outermost section with a rule name; a child with the same rule name as its parent is a sub-span. In r26 this yields 577 tasks (579 depth-2 sections minus `Prepare packages` and `Build Timing Summary`) [OBS-10]. This works for logs without any attachments (SLF < 11, Xcode ≤ 15.2) ([TM] XLP#203). `TaskMetrics` only enrich a task (precise start/duration, CPU, RSS); 111 of the 577 r26 tasks have none (planning tasks, `SwiftDriverJobDiscovery`), and they are still tasks [OBS-13].

Double counting check: Xcode 26 nests per-file children under batch tasks, so the naive sum of all SwiftCompile sections is 264.2 s versus 109.3 s in Xcode's summary [RL]; the structural unit gives 109.28 s [OBS-10].

**Classification** keys on, in order:

1. **Rule name**: first token of `commandDetails`, backslash-escaped spaces unescaped: `SwiftCompile`, `SwiftDriver`, `SwiftDriver Compilation`, `SwiftDriver Compilation Requirements`, `SwiftDriverJobDiscovery`, `SwiftEmitModule`, `EmitSwiftModule`, `SwiftExplicitDependencyGeneratePcm`, `SwiftExplicitDependencyCompileModuleFromInterface` (27), `PrecompileModule`, `ScanDependencies`, `ClangStatCache`, `CompileC`, `Ld`, `Libtool`, `PhaseScriptExecution`, `CompileAssetCatalogVariant`, `LinkAssetCatalog`, `GenerateAssetSymbols`, `ExtractAppIntentsMetadata`, `ProcessInfoPlistFile`, `CodeSign`, `CopySwiftLibs`, `RegisterExecutionPolicyException`, `RegisterWithLaunchServices`, `ValidateEmbeddedBinary`, `Validate`, `Touch`, `CreateBuildDescription`, `ComputeTargetDependencyGraph`, `ComputePackagePrebuildTargetDependencyGraph`, `SendProjectDescription`, `CreateBuildRequest`, `CreateBuildOperation`, `GatherProvisioningInputs`, `GenerateClangModulesReport`, `GenerateSwiftModulesReport`, `WriteAuxiliaryFile`, `MkDir`, `CreateBuildDirectory`, `Copy`, `CpResource`, `ExecuteExternalTool`, `builtin-*` [V-local, RL, OBS].
2. **Structure**: domain type, depth, parent rule, file list present in the signature.
3. **Command line**: the invoked tool path in emitted output (`swift-frontend`, `clang`, `ld`, `actool`, `ibtool`, `/bin/sh -c`) for unknown rule names ([TM] R2).

`KindTable` maps `ruleName → (TaskKind, Phase, xcodeRange)`; `TaskKind` is a closed enum (`swiftCompile`, `swiftPlan`, `swiftEmitModule`, `moduleScan`, `modulePrecompile`, `sdkStatCache`, `clangCompile`, `link`, `script`, `assets`, `resources`, `codesign`, `validate`, `copy`, `metadata`, `planning`, `packageResolution`, `aux`, `gate`, `clean`, `other`). Tasks matching nothing are `other`: listed under "unclassified" with rule names and seconds. Their title may be shown as an annotation ("looks like: Compile asset catalogs"), but never changes kind, phase, target or any number. More than 5 % of task time unclassified marks the report `degraded: classification` ([TM] R3, XLP#190/#201).

**Target attribution**: signature suffix `(in target 'X' from project 'Y'[ at path '…'])` (the ` at path` tail appears for package targets [OBS-5]); else an output path segment `/<Target>.build/` or `/<Target>-t.build/` (Xcode 27 SPM naming [RL]); else the manifest key prefix `target-<Name>-…` (§5.11); else bucket `explicit modules` (scan/PCM/interface tasks carry no target [OBS-4]) or `build system` (planning, `ClangStatCache`, aux). Targets come only from attributed tasks, never from "children of root" ([TM] R4, XLP#220).

### 5.6 Attachments and the task signature slot

- `TaskMetrics` (`com.apple.dt.ActivityLogSectionAttachment.TaskMetrics`, type 1.0): `{"wcStartTime":815073653931597,"utime":930677,"stime":1930138,"maxRSS":336084992,"wcDuration":2985189}`; wcStartTime/wcDuration in microseconds on the 2001 epoch, utime/stime microseconds CPU, maxRSS bytes [RL]. In the checked sample the section start (Unix 1793380846.595 = 2001-epoch 815073646.595) and duration (0.06654 s) agree with wcStartTime/wcDuration to the millisecond. **Placeholder records**: 188 of 466 r26 records have `maxRSS = 0` and `utime = stime = wcDuration` (e.g. `CreateBuildDirectory` with 98 µs each) [OBS-13]; such records are treated as "no CPU/RSS data" (timing from them is still accepted). CPU totals are reported with "N tasks with metrics" and are never extrapolated.
- `TaskBacktrace`: JSON frames `[{category, description}]`, categories `ruleHadInvalidValue`, `ruleSignatureChanged`, `ruleNeverBuilt`, `ruleInputRebuilt`, `ruleForced`, `dynamicTaskRegistration`, `dynamicTaskRequest` [DS] §1.4.
- `BuildOperationMetrics`: build-level compilation-cache counters (legacy `clangCacheHits/Misses`, `swiftCacheHits/Misses`; 26.4+ `counters`/`taskCounters`) [DS] §1.4. No per-task "replayed" flag exists in it, but per-task replay is visible in task output (v0.5 decision in §6.7).
- **Task signature (not an attachment)**: the `xcbuildSignature` string slot of a task section holds hex-encoded UTF-8: a 1-byte prefix (`0x00` for keyed tasks, `0x01`/`0x02` for others) followed by the task key, e.g. `P0:target-LocalizeCore-PACKAGE-TARGET:LocalizeCore-SDKROOT:macosx:SDK_VARIANT:macos:Debug:ExtractAppIntentsMetadata` [OBS-12]. After stripping the prefix, 212 decoded keys equal `manifest.json` command keys exactly; the others are dynamic tasks (SwiftCompile 87, PCM 143, PrecompileModule 12, Swift planning 9, SwiftEmitModule 9) that are not in the manifest. The xcresult JSON does not carry this slot; its only attachments are the 466 TaskMetrics.

### 5.7 xcresult build-log JSON and the common BuildModel subset

`xcrun xcresulttool get log --path R.xcresult --type build` (Xcode 16+): section tree `{title, domainType, duration (s), startTime (Unix epoch s, ms resolution), result, attachments[], messages[], subsections[], commandInvocationDetails{commandDetails, emittedOutput, exitCode}, location}`; Xcode 26: 770 sections, 12.4 MB; Xcode 27: 780, 13.4 MB [RL]. `--schema` output is stored per Xcode in the corpus; `get build-results` has no per-task timings; legacy `get --format json` needs `--legacy` since Xcode 16 [DS] §2. Streamed with a hand-written incremental scanner.

| BuildModel field | SLF | xcresult | Status |
|---|---|---|---|
| task rule name, commandDetails, target, kind | yes | yes | common |
| start, duration | doubles (sub-ms) / TaskMetrics µs | ms-rounded start, double duration | common at 1 ms resolution |
| result / exit code, messages, emitted output | yes | yes | common |
| TaskMetrics | yes | yes | common (optional per task) |
| wasCancelled, isQuiet, wasFetchedFromCache | yes | no | SLF-only, optional |
| uniqueIdentifier, task signature key (§5.6) | yes | no | SLF-only, optional |
| log format version, class layout | yes | n/a | SLF-only |

Reader agreement (v0.1 exit) is defined on the common subset: same executed-task set (matched by rule name + commandDetails + start within 2 ms), durations within 2 ms, same targets and kinds, same diagnostics. Cross-build task identity (history, `why`) uses the SLF task key, else the manifest command key, else `(ruleName, target, primary output path)`; when only an xcresult is available, the report says so and identity falls back to the last form.

### 5.8 Timing flags and their output formats (`--deep`)

| Flag (injected on the command line through the wrapper, §7.5) | Output and where | Parsing rule |
|---|---|---|
| `OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -debug-time-function-bodies'` | `<ms>ms\t<abs file>:<line>:<col>\t<decl>` lines, CR/LF separated, in the emittedOutput of the per-file compile section; 23,983 lines on AcmeApp 26 [RL] | Split on the first two TABs; location split from the right (`:col`, `:line`) so paths with `:` survive ([TM] XLP#100). Decl text differs by Xcode (26: `StringsView._@/path:399:25`, 27: `StringsView.body.getter@/path:399:25`), so identity is `file:line:col`. Repeats across batch sub-jobs deduped by key (max, count) ([TM] BTA#92). |
| `-Xfrontend -debug-time-expression-type-checking` | `<ms>ms\t<file>:<line>:<col>` | Same. |
| `-Xfrontend -warn-long-function-bodies=N`, `-warn-long-expression-type-checking=N` | Diagnostics: `warning: expression took 62ms to type-check (limit: 50ms)` [RL] | Via §5.10. Off by default in `--deep` (`SWIFT_TREAT_WARNINGS_AS_ERRORS` projects would fail, [OC] A20). |
| `-Xfrontend -stats-output-dir -Xfrontend <dir>` | One JSON per frontend job; filename `stats-<startUsec>-swift-<kind>-<module>-<input>-...json`; timers `time.swift-<jobkind>.<module>-<input>-...<timerkind>`; counters `AST.NumSourceLines`, `Driver.NumDriverJobsRun` [DS] §3 | Keys matched by suffix and segment; short-form keys accepted too [MV-6]. Batch granularity. |
| `OTHER_CFLAGS='$(inherited) -ftime-trace -ftime-trace-granularity=500'` | Chrome-trace JSON next to each `.o`; log text `Time trace json-file dumped to <path>` [DS] §4 | Aggregated per TU. Explicit modules/caching behavior [MV-7]. |
| `-driver-show-incremental` (in `why --show-incremental`) | Remarks such as `Queuing <file> because of dependencies discovered later` [DS] §3 | Used when present [MV-8]. |

Dead or unreliable, never used: `-Xfrontend -debug-time-compilation`, `-driver-time-compilation`, `-print-stats`, ld `-print_statistics` [DS] §0. `--deep` probes the toolchain (`swift-frontend -help`, `clang --help`) and drops unsupported flags with a note ([TM] BTA#61).

`--deep` runs in its own DerivedData outside the repository: `~/Library/Caches/xcblame/dd-deep/<project-hash>/` (or `$TMPDIR/xcblame/...` when the cache dir is not writable), because changing `OTHER_SWIFT_FLAGS` changes every Swift task signature and would wipe the user's incremental state and create module variants. Size is reported and `history prune --deep-cache` removes it. Whether a command-line `$(inherited)` keeps project-level `OTHER_SWIFT_FLAGS` (e.g. `-D` defines) must be verified [MV-3]; the injector compares `-showBuildSettings -json` with and without the injected args before building and aborts `--deep` if any target loses a pre-existing flag.

**v0.5 decisions (2026-11-02), timing flags (probes-v0.5 MV-6, MV-7).** Stats-dir timers are read in the short form
`time.swift.<phase>.<wall|user|sys|instr>` (both Xcodes), plus the one job total `time.swift-frontend.<job>.wall`; the
`[DS] §3` long form exists only as that job total, phases nest and are never summed, and the job is matched to its task by
(module, first input) from the file name. `-ftime-trace` reaches the compiler through Xcode's `*-common-args.resp`
response file, so the CompileC command line in the log never shows it and `Time trace json-file dumped to` is never
printed: traces are found next to each executed TU's `.o` (`<basename>.json`), explicit-module PCM builds write none, and
a compilation-cache hit writes none (the report notes both). The deep DerivedData is `<cache>/deep/<sha16(container)>/`
(docs/SCHEMA-v0.5.md), not `dd-deep/<project-hash>/`; the toolchain-unsupported flags are `deep.flagsDropped`, the
warn-long pair `deep.flagsNotInjected`. MV-3 on Xcode 26.0.1: a `-xcconfig` value sits above command-line `KEY=VALUE`
and its `$(inherited)` takes the command-line value, so the wrapper and command-line settings compose.

### 5.9 Environment capture and Xcode version inference

`Env` captures: `xcodebuild -version`, `xcode-select -p`, swift-driver version, macOS version, `sysctl hw.model hw.ncpu hw.memsize hw.perflevel0.physicalcpu hw.perflevel1.physicalcpu`, `sysctl.proc_translated`, `pmset -g therm` before and after a wrapped build, DerivedData path, size (bounded `du`), volume (`diskutil info -plist`), **free space on that volume**, symlink, `tmutil isexcluded`, `.noindex` presence, Xcode defaults (`IDEBuildOperationMaxNumberOfConcurrentCompileTasks`, `IDEIndexDisable`, `IDECustomDerivedDataLocation`, `IDEPackageEnablePrebuilts`), CI provider, git branch/sha/commit time (opt-in `--git`). Each probe has a 2 s timeout and degrades to `unknown` ([DS] §8, [OC] F1-F6).

**Which Xcode produced the log.** SLF has no Xcode version field and commands use `/Applications/Xcode.app` ([DS] §1.4). For `build` mode the version is the one xcblame invoked (`xcodebuild -version` of the selected developer dir). For `analyze`, `XcodeVersionInference` derives it from the log: SDK names in task commands (`MacOSX26.0.sdk`), the SDK build in the stat-cache file name (`macosx26.0-25A352`), the developer-dir path if it is not the default, swift-frontend/clang versions in emitted output when present, and the log format version. The result is `{value: "26.0", source: "inferred", evidence: [...]}`, never the current `xcode-select` value [OBS-16]. Trend and regression attribution group by the inferred version; when it is null, those reports say "Xcode unknown" and exclude the build from per-version statistics.

### 5.10 Diagnostics decoding

Diagnostics come from `IDEDiagnosticActivityLogMessage` (54 in the v11 clean log, 57 in v13 [RL]) and other message classes in SLF, or `messages[]` in the xcresult JSON, plus `get build-results` for an issue summary.

1. **Severity** from the message's severity/type field (SLF int; xcresult `type`: `error`, `warning`, `notice`, `analyzer warning`), never from `categoryIdent`/`issueType` strings, which change across versions (Xcode 27 moved Swift warnings to group tags such as `[#ImplicitStrongCapture]` [RL]; [TM] XLP#212). The category string is kept as a display field and mapped to a `group` where known.
2. **Location** from `DVTTextDocumentLocation` (file URL, start/end line and column; the xcresult `sourceURL` fragment `#StartingLineNumber=..&StartingColumnNumber=..`). Lines are converted to 1-based on output. `DVTDocumentLocation` with no line info gives file-level location.
3. **Multi-line assembly**: a message's full text is title + sub-messages (notes, fix-its) in order; continuation lines in emitted output (indented caret lines, `note:` lines that follow) attach to the preceding diagnostic of the same task ([TM] xcbeautify#105).
4. **Dedupe** by `(severity, file, line, column, normalized message)`; the same diagnostic emitted by several tasks (headers compiled per TU, batch sub-jobs) is counted once with an occurrence count and the list of tasks.
5. **Linkage**: each diagnostic carries its task, target and kind; timing diagnostics (`took Nms to type-check`) feed hotspots (§6.5); `agent`, `github` and `sarif` formats print errors first, then warnings, capped and deduped.

### 5.11 Build description, task DAG and modules reports

The build service writes the build description to `<DerivedData>/Build/Intermediates.noindex/XCBuildData/<signature>.xcbuilddata/` [OBS-12]:

| File | Content (AcmeApp 26 clean) | Use |
|---|---|---|
| `manifest.json` | llbuild manifest: `client`, `targets`, `nodes`, `commands`; 747 commands with `tool`, `inputs`, `outputs` (tools: phony 522, auxiliary-file 85, file-copy 44, shell 26, swift-driver-compilation 9, swift-driver-compilation-requirement 9, ...) | Task DAG edges (§6.2) |
| `target-graph.txt` | "Target dependency graph (13 targets)" with explicit dependencies | Target graph without parsing the project |
| `build-request.json` | action, configuration, run destination, `enableIndexBuildArena`, `generatePrecompiledModulesReport`, command-line overrides table | Build kind (§6.7), provenance of command-line settings |
| `description.msgpack`, `task-store.msgpack` | binary | not read in v1 |

Siblings: `XCBuildData/clangmodulesreport/` and `swiftmodulesreport/` (one CSV per module plus `Summary.csv` `Name,Variants`; a module CSV lists variants and a ✅/❌ matrix of the flags that differ, e.g. `-fapinotes-swift-version=6` vs `=5`, `-Xcc -D SWIFT_PACKAGE`, `__swift__=60200` vs `51000` for `Darwin`), `build.db` (llbuild state), `PIFCache/`.

**Matching a log to its description**: a build that creates the description logs "Build description signature: 6f0b463d…" and "Build description path: …" in the `CreateBuildDescription` task text [OBS-12]. A build that reuses a cached description (the r26 incremental log has no such line) is matched to the newest description whose command keys cover ≥ 95 % of the log's keyed tasks. If none matches, the DAG is unavailable and §6.2 falls back to inference.

**Snapshot**: the next build that re-plans writes a new description, and the modules reports are regenerated per build. `xcblame build` therefore copies `manifest.json`, `target-graph.txt`, `build-request.json` and both report directories, gzipped, to `.xcblame/snapshots/<log-uuid>/` right after xcodebuild exits (AcmeApp: 1.6 MB manifest before compression). `analyze` of a log uses its snapshot if present, else the live description if the signature matches, else inference. Retention follows history retention.

**v0.2 decision (2026-11-01).** The snapshot gzips only `manifest.json` (as `manifest.json.gz`); `target-graph.txt`, `build-request.json` and the `clangmodulesreport/` / `swiftmodulesreport/` CSV folders are copied plain, and a `SIGNATURE` file holds the `<signature>.xcbuilddata` folder name. History pruning also deletes a snapshot when no kept history entry names its log (entry `input.path` basename = snapshot uuid) and it is older than 90 days or beyond the newest 200 by mtime; an unloadable snapshot passed to the locator falls through to `snapshots/<uuid>/` and the live description with a `graph.notes` line.

---

## 6. Analysis engines

All analyzers are pure functions of `BuildModel` (+ `TaskDAG`, `ProjectModel`, `EnvSnapshot`, history). Each returns values plus `AnalyzerNote`s. Times are seconds as `Double`, clamped and validated (§6.11).

### 6.1 Timeline normalization

1. Session window = [manifest `timeStartedRecording`, `timeStoppedRecording`] (or the top section's start/stop).
2. A task whose start is earlier than the window start by more than 0.5 s is **reused**: Xcode copied it from a previous build. In the AcmeApp 26 incremental log, 39 of 59 sections are reused with timestamps from the clean build; naive span 20.0 s against a real 1.6 s [OBS-2]. Reused tasks and tasks with `wasFetchedFromCache` (SLF-only) are excluded from timing, counted as "up to date", and listed in `why` ([TM] XLP PR#249).
3. Clamp every interval to the window; zero-length tasks stay in counts but not in interval math.
4. Precise times: TaskMetrics `wcStartTime`/`wcDuration` when present and not placeholder; else section doubles.

### 6.2 Critical path

**Primary method: the build system's DAG** (when §5.11 provides a matching description).

1. Nodes: manifest commands. Edge A → B when an output node of A (file or virtual `<...>` gate node) is an input node of B. Built by indexing each node's producer, O(V + E).
2. Executed planned tasks map to commands by task key (§5.6). Non-executed commands (up to date, phony gates) get weight 0.
3. Dynamic tasks (Swift planning, frontend jobs, emit-module, PCM, interface compiles) are not commands. They attach to the planned command that requests them: Swift jobs of target T to T's `swift-driver-compilation` / `swift-driver-compilation-requirement` command (by target and rule); inside that group the order is planning → emit-module and compiles, from `dynamicTaskRequest` backtrace frames when present. PCM and interface tasks attach to the target whose planning they follow and whose first compile they precede (attribution `byTiming`, labelled), because the manifest does not name them.
4. Weights = measured durations of executed tasks. Longest path by topological order, O(V + E), with per-task slack (latest start − earliest start).
5. Consistency check: every DAG edge A → B between executed tasks must satisfy end(A) ≤ start(B) + 50 ms. More than 1 % violations means the description does not belong to this build: drop it and fall back.
6. **What-if** for a target X: recompute the longest path with every task of X set to duration 0; saving = current path − new path. This is a lower-is-better bound on the wall saving (it assumes unlimited cores), printed as "up to N s if X took no time"; "if X were twice as fast" uses duration/2.

**Fallback: timing inference** (no description, Xcode versions that do not write one, or the consistency check failed), labelled `basis: inferred`:

```
tasks sorted by end; endIndex = array of ends
cur = task with max end; path = [cur]
while cur.start > window.start + eps:
    i = upperBound(endIndex, cur.start + eps)          // O(log n)
    window = tasks[max(0, i-K) ..< i]                    // K = 64 latest finishers before cur
    pick, in order: constraint predecessor of cur in window (same target earlier phase, a
    dependency target's emit-module/link, from ProjectModel or target-graph.txt), else the
    latest-ending task in window; if cur.start - pick.end > eps, record a wait segment
    path.append(pick); cur = pick
```

Cost O(n log n + p·K) for path length p. `eps` = 50 ms. What-if is not computed under inference (slack is not observable from timing alone); the report shows only "path share (upper bound)" for each target.

Correctness rules for both: segments ordered and disjoint; sum(segments) + sum(waits) = path span ≤ window span; the last segment ends at the latest task end; every segment carries `basis: dag|byTiming|inferred`. The text report groups consecutive segments by target (§3.3).

**v0.2 decision (2026-11-01).** `whatIf` is filled when the path comes from the DAG, i.e. basis `dag` **or `mixed`** (explicit-module tasks and build-system steps outside the manifest attach `byTiming`, so every AcmeApp DAG path is `mixed`); it stays null under `inferred`. The DAG puts LocalizeCore's emit-module, not its compiles, on the path, because AcmeApp's planning waits for the LocalizeCore swiftmodule. The §3.3 mock row "LocalizeCore compile (on path: Models.swift 3.0 s)" is therefore the inference result, and the DAG row is the correct one; spans and the ends of shared tasks agree exactly (fixtures 20E8B73D, 5E3BDB3A, 71374EE4).

### 6.3 Parallelism and utilization

Sweep line over task intervals: concurrency histogram, peak lanes, busy time (union), task-time sum, CPU sum (TaskMetrics utime+stime of tasks with real metrics, with the task count), average parallelism (task time / busy), idle gaps (no task running, > 100 ms), and **serial stretches**: windows ≥ 1 s where lanes ≤ max(1, floor(0.10 × physical cores)). On AcmeApp (28 cores, threshold 2): 7.5 s of 18.1 s [OBS-6]. Log span, busy, task time and CPU are always printed as separate numbers ([TM] R5, XLP#44).

Process wall vs log span (`build` mode): 26 s process vs 18.1 s log on the AcmeApp clean build, 3 s vs 1.6 s incremental [RL]; the difference is "outside the build log", split using the `Logs/Package` resolve log when present.

**v0.2 decision (2026-11-01).** Without a physical core count (`--no-env`, Intel) the serial threshold is max(1, floor(10 % of peak lanes)), with a note in `timing.notes`, instead of null.

### 6.4 Rollups and batch-aware attribution

Rollups by phase, kind, target, owner (app, local package, remote package, Pods, macro plugin, system modules) and file, each with task time, busy time within the group and critical-path seconds; text ranks by critical-path seconds then task time.

| Granularity | When | How time is assigned |
|---|---|---|
| `exact` | compile task with one primary file (all 26 AcmeApp user files: 18 LocalizeCore + 8 AcmeApp frontends [OBS-14]) or `--deep --exact-files` | task time |
| `batch` | a batch of N files | one row "N files, D s"; members listed; no split |
| `estimated` | batch plus type-check text | D split by each file's share of type-check ms, labelled, never summed with exact rows |
| `wmo` | whole-module compile | module only |

Never copy a batch duration onto each file ([TM] R6). **v0.2 decision (2026-11-01):** only source compiles (Swift, C-family, Metal) are file rows, and `estimated` rows are not produced yet: no fixture has a batch with per-file type-check text; they come with `--deep`. V9 compares exact rows with the target's compile time. `--deep --exact-files` rebuilds only the top-K batches' targets with `SWIFT_ENABLE_BATCH_MODE=NO` in the deep DerivedData and states that the build shape changed.

### 6.5 Hotspot ranking

Sources: debug-time text, warn-long diagnostics (§5.10), stats-dir timers, ftime-trace. Filter to user code (repo root and local packages; >99 % of AcmeApp's 23,983 lines were swift-syntax [RL]), dedupe by `file:line:col`, aggregate per file and declaration kind, rank by `ms × w` with w = 1 if the file's compile task is on the critical path else 0.25. Each hotspot links to a SRC rule with a pattern match and a before/after template; never an automatic edit. Type-check ms is shown next to the file's total frontend time ([TM] BTA#43; Apple forum 816605).

### 6.6 Incremental-rebuild cause attribution

Goal: every executed task in a non-clean build gets exactly one primary cause; causes are ranked; totals partition executed time.

**State needed**: history stores a compact **task index** per build (§8.3): task key, rule, target, kind, signature digest (hash of commandDetails), duration, on-path flag, and for Swift module outputs the size + hash of the emitted `.swiftmodule`/`.abi.json` when `why` captured them. `analyze` of a log with no previous index in history compares nothing and reports causes from the current log only (backtraces, static script I/O); everything else is `unknown (no previous build recorded)`.

**Evidence, in precedence order** (the first that applies is the primary cause; later matches are kept as secondary evidence, never counted):

1. Backtrace frames: `ruleNeverBuilt`, `ruleSignatureChanged` (diff signature digest vs the index), `ruleInputRebuilt` (follow to the upstream task; that task's cause becomes the root), `ruleForced`, `ruleHadInvalidValue`.
2. Script phase with no declared outputs, `alwaysOutOfDate = 1`, or no inputs (ProjectModel) ([BP] §7.1, [OC] D1).
3. Signature digest differs from the previous build's (settings or command line changed).
4. Upstream module interface changed: the dependency's emit-module ran and its output hash changed (needs the `why` capture); known false trigger Xcode 27.0 swift-driver#2214 matched by inferred Xcode version (DYN-005).
5. Input timestamp churn: input mtime newer than the previous build start but content hash equal to the hash recorded by the previous `why` run (hashing only inputs of executed tasks).
6. Planning re-run without compiles; 2+ macro plugins per module on Xcode 26.x ([OC] F8).
7. `-driver-show-incremental` remarks.
8. `unknown`, with the suggestion `why --backtraces` [MV-2].

**Ranking**: a cause's cost = Σ task time of tasks it is the primary cause of (directly or as root of an `ruleInputRebuilt` chain), and separately Σ critical-path seconds of those tasks. Two rankings are printed (by task time, by path seconds); they are not added. **Partition invariant (V15)**: Σ over causes of task time = executed task time of the build, including `unknown`.

**`why` procedure**: settle build, zero-change build (or `--touch <file>` then build), snapshot description and outputs hashes, analyze the last build against the settle build's index. Two consecutive zero-change builds that both execute compile or plan tasks raise DYN-002 ([PP] A1). `--backtraces` creates a temporary copy of the scheme (`xcshareddata/xcschemes/.xcblame-<name>.xcscheme`, deleted afterwards) with Task Backtraces enabled and builds with `-scheme .xcblame-<name>`; it never edits the user's scheme. Whether the option is a scheme attribute, and whether the IDE notices the temporary file, is MV-2.

**v0.5 decisions (2026-11-02), cause attribution (probes-v0.5 MV-2).** `--backtraces` sets `EnableBuildBacktraceRecording=YES`
in the environment of every xcodebuild of the procedure (`XcodebuildRunner.run(environment:)`), settle build included,
since switching mechanisms changes task signatures: it works on 26.0.1 and 27.1 and writes no file. The temporary scheme
copy above is not used; its `.xcblame-<name>` naming is obsolete (a scheme file starting with `.` is not listed, and the
`enableTaskBacktraces` attribute exists only on 27.1, where a copy would have to be named `xcblame-<name>`). The root
cause of a chain is its **last** frame (`ruleHadInvalidValue` on a file or directory, `ruleSignatureChanged`,
`ruleNeverBuilt`); the first frame is the task itself, and frames are read by `category`/`frameKind`, never by their
text (it differs between 26 and 27). Per-file Swift compiles and emit-module tasks of a non-clean build say only "had
never run" (dynamic tasks are not in `build.db`): they inherit the cause of their module's `SwiftDriver Compilation`
task. The previous task index holds only the tasks the previous build ran, Swift driver jobs can carry per-build keys,
and scripts are left out of the signature signal; `incremental.notes` names each limit when it applies.

**v0.5 note (2026-11-03), what `--touch` simulates.** `--touch <file>` sets only the file's modification time. Swift decides by content hash, so the measured build recompiles just that file and its dependents are not rebuilt: it is not a one-line edit. The output says so, in `incremental.notes`, the text WHY section and the HTML Start-here box ("--touch changes only the file's timestamp, so Swift recompiled just this file. To see what one real edit rebuilds, add a line to the file and run: xcblame why --backtraces -- <args>"), next to the unchanged "Expected after your edits" line. `build --kind incremental|zero-change` and `build --touch` record Task Backtraces the way `why --backtraces` does (`EnableBuildBacktraceRecording=YES` in the environment of every build of the run, preparation included) so their causes are not `unknown`; `build --no-backtraces` opts out.

### 6.7 Build-kind classification

Signals, structural first: `build-request.json` (`action`, `enableIndexBuildArena` = index build, `buildCommand.style`), executed-task counts by kind, reused-task count, `BuildOperationMetrics` counters, DerivedData sub-paths. Kinds: `clean` (build description created, no reused tasks), `incremental` (reused tasks present), `zero-change` (no compile, plan or link task executed), `cached` (build-level cache hits > 0 in BuildOperationMetrics or CAS remarks; there is no per-task replay flag, so per-task "replayed" is reported only as a labelled heuristic: a compile task with cache-hit remarks, or duration < 5 % of its previous duration in the index with an unchanged signature), `index` (index build arena), `previews` (DerivedData Previews arena path or a previews-specific build request; exact signal [MV-17]), `analyze`, `archive`, `test` (from `action`). Never from titles. Previews/index/analyze are excluded from trends and baselines by default ([TM] XLP#224, XCM#72/#103, XcodeBenchmark#20). **v0.2 decision (2026-11-01):** `clean-action` is a kind too: a log of only planning, clean and gate tasks with no build-description task (the Product > Clean logs). v0.2 never produces `cached` or `previews`: their signals (build-level cache counters, the Previews arena) are not read yet and land with v0.5 (MV-17); until then such builds classify by their counts. Index builds may not produce activity logs at all [MV-17]; xcblame does not try to measure indexing (out of scope, [PP] A14).

**v0.5 decision (2026-11-02), `cached` and per-task replay:** MV-12 showed that replay is a per-task fact, so the duration heuristic above is no longer the primary signal. `CacheMetrics` reads `BuildOperationMetrics` in both shapes: Xcode 26.0.1 writes the legacy flat keys with zeros present, 27.1 writes `{"counters": {…}, "taskCounters": {"<RuleName>": {"cacheHits"|"cacheMisses": n}}}` with zero keys omitted (versions between were not tested). `build.cache` = {hits, misses} from the counters (`source: buildOperationMetrics`), else from the task output lines alone (`casRemarks`). Every cacheable task's emitted output is exactly `Cache hit` (replayed) or `Cache miss` (executed and stored); that exact count is `build.cache.replayedTasks` (v0.5 integration; the `cache: 112 task(s) replayed …` build note keeps the per-rule breakdown), and `replayedTasksHeuristic` stays null whenever the exact count exists (the heuristic needs the history task index and is not produced in v0.5). Kind `cached` = Σ hits > 0, checked after `index`/action and before the count rules, so a cache-hit clean build is `cached`, a miss-only build stays `clean`; V11 accepts `cached` on counter or `Cache hit` evidence. Fixtures: 26.0.1 hit build 112 hits (13 clang + 99 swift) and 112 `Cache hit` lines; 27.1 hit build 113 hits in the counters but 112 `Cache hit` lines (one SwiftCompile counted without the line): `hits` 113, `replayedTasks` 112, and the kind evidence names the unmatched hit. `previews` reads the expected Previews-arena signals (`buildCommand.command = preview`, an `arenaInfo` path or the description folder under `Intermediates.noindex/Previews/`); MV-17 is still open, so no previews log has confirmed them.

### 6.8 Fixed-cost detection

A fixed cost is a task that runs on (nearly) every build regardless of edits: (a) every executed task in a zero-change build; (b) tasks present in > 80 % of incremental builds of a scheme in history; (c) statically, scripts without outputs, upload scripts, linters, build-tool plugins. Classes: scripts, codesign, validate, embed/copy, Info.plist, app-intents metadata, execution-policy registration, planning, SDK stat cache (first build in a DerivedData only), package resolution, Swift planning, macro/swift-syntax builds, out-of-log time. AcmeApp clean: planning 1.8 s and SDK stat cache 1.8 s, serial at the start [OBS-14]. Per-day estimate = seconds × builds/day from history, or `buildsPerDay` from config (default 50, labelled assumption, [PP] §C).

### 6.9 Module graph metrics

Graph from `target-graph.txt` (when a description is available), ProjectModel and `swift package show-dependencies --format json`. Metrics: depth, longest chain weighted by critical-path seconds, fan-in/fan-out, umbrella candidates (fan-in > 50 % of modules), cycles, blockers (targets whose emit-module end gates the most dependent task-seconds), macro plugins per module, and **variants** from the modules reports (variant count per module and the differing flags; AcmeApp 26: 64 modules, 17 with 3 variants, 45 with 2, 2 with 1; 143 PCM tasks of which 79 are redundant variants, 7.6 s task time [OBS-4]). Variant causes are classified from the differing flags: language mode (`-fapinotes-swift-version`, `__swift__`), `SWIFT_PACKAGE` (package vs project target, inherent), preprocessor macros, other.

### 6.10 Regression vs baseline

Inputs: current report(s) and a baseline (committed `.xcblame/baseline.json` or a history query: same scheme, configuration, destination, kind, inferred Xcode version). Noise model: with ≥ 3 runs per side, compare medians with a MAD band (`|Δ| > 3 × pooled MAD` and `> 2 %`); otherwise the verdict is `indicative` and `--fail-if-slower` only fails when Δ exceeds the threshold plus a 5 % allowance (configurable). Delta attribution: environment first (inferred Xcode version, machine model, flags, thermal), then phases, targets, critical-path composition, new/removed tasks (from task indexes), settings ([PP] A5).

**v0.4 decision (2026-11-02).** The constants are 3 × pooled MAD, 2 % and a 5 % allowance (`docs/SCHEMA-v0.4.md` "Noise model"); a report or baseline with fewer than 3 runs on a side is worded `indicative` ("too few runs to tell it from noise"), never `slower` or `faster`, though the sign of the delta is still printed. `wallBasis` is `processWall` only when every run on both sides has it, else the log span; a baseline made from process wall against a log analyzed afterwards leaves the wall delta unknown and the verdict `indicative` (busy and critical path stay comparable), and a baseline that cannot be evaluated exits 1 (`Regression.NotEvaluable`), not 3.

### 6.11 Self-validation

The `Validator` runs on every report; each check passes, warns, or fails (the number is withheld and printed as "unavailable because ..."). A failure, timing drift (V14) or a reader degradation (truncated input) marks the report `degraded`; a plain warn is listed with the checks but does not (v0.2 decision, 2026-11-01: text, JSON and the html badge agree, `degraded` ⇔ `degradations` non-empty).

| # | Invariant |
|---|---|
| V1 | No NaN, infinity, or negative duration. |
| V2 | Every interval lies within the session window after clamping; clamped count reported. |
| V3 | Critical path span ≤ log span; segments disjoint; path ends at the last task end; DAG edges consistent with timing (§6.2 step 5). |
| V4 | Busy ≤ log span; task time ≥ busy; avg parallelism ≤ peak lanes. |
| V5 | Per rule-name row present in Xcode's timing aggregate (its rows are rule names, not kinds): |Δ seconds| ≤ max(0.25 s, 2 %) passes; above that warns; a task-count difference warns with both counts (r26: WriteAuxiliaryFile 85 vs 84 tasks, 0.47 vs 0.28 s: warn on count) [OBS-10]. |
| V6 | Every rollup is a partition (rows sum to the total, "other/unclassified" row present). |
| V7 | Unclassified task time ≤ 5 % of task time. |
| V8 | Target count ≤ distinct target names in signatures/keys; no target named after a build-system step. |
| V9 | `exact` file rows sum to ≤ the module's compile task time; `estimated` rows never mixed into exact totals. |
| V10 | A failed task is not `cancelled`; status matches manifest `highLevelStatus` and error count. |
| V11 | Build kind consistent with counts. |
| V12 | Each finding's estimated saving ≤ the measured cost it is based on, ≤ the what-if saving for "shortens this build" claims, and counts only avoidable parts (e.g. redundant variants, not the first variant). |
| V13 | Report size ≤ budget; truncation noted. |
| V14 | Schema-drift warnings on timing fields flip V2-V5 to warn. |
| V15 | Incremental causes partition executed task time (§6.6). |

---

## 7. Rule engine and fix application model

### 7.1 Rule schema and confidence

Rules are values compiled from `Rules/catalog.json`, generated from [RULES.md](RULES.md).

```json
{
  "id": "PHASE-001",
  "name": "run-script-inputs-outputs",
  "category": "scripts-and-phases",
  "catalogRef": ["D1"],
  "detect": {
    "static":  { "source": "project", "predicate": "shellScriptPhase.outputs.isEmpty || shellScriptPhase.alwaysOutOfDate" },
    "dynamic": { "source": "analysis", "predicate": "task.kind == .script && build.kind in [.zeroChange, .incremental]" }
  },
  "signal": "PBXShellScriptBuildPhase with empty outputPaths and outputFileListPaths",
  "signalKey": "script-phase:<phase-id>",
  "appliesTo": { "configurations": ["Debug", "Release"], "xcode": ">=10" },
  "impact": { "band": "M", "basis": "catalog", "evidence": ["S4: Helm zero-change 70 s -> 9 s", "S5: Sentry 6.3 s"] },
  "evidenceTag": "P",
  "risk": "medium: wrong declarations skip a needed script",
  "fix": { "kind": "recommend", "template": "phase-io-scaffold" },
  "conflicts": ["SET-030 depends on this"],
  "verifyGate": false
}
```

**Confidence** (computed; mocks in §3 follow it):

| Confidence | Condition |
|---|---|
| high | evidence tag `[P]` for the mechanism AND the cost was measured on this build (dynamic detection) |
| medium | `[S]` with a measured cost; or `[P]`/`[S]` static-only (no build data) |
| low | any `[K]` part, including mixed tags such as `[S/K]`; shown as "needs measurement", never in the default top 3, applied only through `verify` |

**Impact bands**: `XS` < 1 s per build or < 2 %, `S` 1-5 s or 2-10 %, `M` 5-30 s or 10-30 %, `L` > 30 s or > 30 %, `?` unmeasured. A measured band comes from this build's what-if (DAG) or path-share bound (inference), counting only the avoidable part (V12). Static-only findings show `?` unless the catalog has a number, which is shown as context.

**Signal dedupe**: every finding has a `signalKey` (e.g. `task:CompileAssetCatalogVariant:AcmeApp`, `module-variants`, `critical-path:target:LocalizeCore`). When several rules fire on the same key, the engine keeps the most specific rule (the one with a fix kind other than `rec`, else the one with the higher-priority category order SET > PHASE > DEP > GRAPH > SRC > ENV > DYN) and lists the others as "see also" ([RULES.md](RULES.md) §10).

**v0.3 decision (2026-11-01).** `RuleSpec` gained `severity` (RULES.md has no column; `--fail-on` needs one): the catalog default, at most `low` for a [K]-gated rule, raised by a measured band, overridden per signal by a predicate. The catalog is Swift literals next to their predicates, one file per category (`Rules/Catalog+SET.swift` …), not `catalog.json`; `RulesCatalogTests` compares the columns with RULES.md.

### 7.2 Finding

`{ruleId, title, severity, confidence, impact{band, seconds?, basis}, scope{targets, configurations}, evidence[{kind: setting|task|file|log|report, ref, value, provenance}], fix{kind, overlayLines?, projectEdit?, snippet?, commands?}, risk, xcode, sources[], seeAlso[]}`. Provenance says which level set a setting (SDK default, project xcconfig, project pbxproj, target xcconfig, target pbxproj, command line).

### 7.3 Fix kinds and the flag that allows each write

| Kind | Writes | Allowed by | Safety |
|---|---|---|---|
| `overlay` | `.xcblame/overlay-<Configuration>.xcconfig` | `fix --apply` | Text, commented with rule IDs, revertable; effective only through a hook or the command-line wrapper (§7.5). |
| `cli` | nothing; prints or injects xcodebuild args / CI YAML | `build --overlay`, or copy-paste | Zero project change. |
| `defaults` | `defaults write com.apple.dt.Xcode ...` (v0.6: only `IDEBuildOperationMaxNumberOfConcurrentCompileTasks`, ENV-002) | `fix --apply-defaults` | Prior value saved to `.xcblame/backup/defaults.json`; `--revert` restores. |
| `hook` | one `#include?` line in an existing xcconfig, or project-level `baseConfigurationReference` | `fix --install-hook` (+ `--edit-project` for the pbxproj variant) | §7.5. |
| `scheme` | `.xcscheme` attribute | `fix --edit-project` | Attribute edit, backup, XML re-parse. |
| `project` | pbxproj/xcproj | `fix --edit-project` | §7.6. |
| `manifest` | Package.swift / Podfile | `fix --edit-project` | Diff shown first. |
| `recommend` | nothing | - | file:line, snippet, steps. |

`--apply` alone never writes anything but overlay lines.

**v0.6 decision (2026-11-05).** The `defaults` kind covers one key in v0.6, `IDEBuildOperationMaxNumberOfConcurrentCompileTasks` (ENV-002; the key exists in 26.0.1 and 27.1, its effect was not probed, probes-v0.6 Q8; CI uses `-jobs N`). ENV-001 (`ShowBuildOperationDuration`) is display-only and a `recommend` step, as is DEP-008's `IDEPackageEnablePrebuilts`. The `hook` kind is the xcconfig append only; the pbxproj `baseConfigurationReference` variant, `scheme`, `project` and `manifest` writes wait for v0.7 (`--edit-project`).

### 7.4 Effective value and provenance

`SettingsOracle` runs `xcodebuild -showBuildSettings -json -scheme S -configuration C` once per configuration (cached by project file mtimes) for effective values per target, including package targets. Provenance comes from our reader: pbxproj/xcproj `buildSettings` at project and target level, `baseConfigurationReference` xcconfigs with `#include` chains, conditional keys, `$(inherited)`, and command-line overrides (also visible in `build-request.json` [OBS-15]). Inheritance low to high: platform defaults < project xcconfig < project settings < target xcconfig < target settings < `KEY=VALUE` < `-xcconfig` < `XCODE_XCCONFIG_FILE` ([DS] §6.1; the oracle's effective value stays ground truth). `--offline` uses only our resolver and lowers every finding's confidence one step.

**v0.6 decision (2026-11-05).** The command line is three ordered levels, not one: `KEY=VALUE` < `-xcconfig` < `XCODE_XCCONFIG_FILE`, all above every project level (probes-v0.6 Q1 on 26.0.1 and 27.1 beta, `-showBuildSettings` and the real compile line agree; Q4: shared keys take the env file's value, keys only in the `-xcconfig` file still apply). The project xcconfig vs project settings order is no longer disputed (Q1). MV-3 is resolved.

**v0.3 decision (2026-11-01).** Any xcodebuild that opens a project writes into it (`-list` included: `project.xcworkspace/xcshareddata/swiftpm/configuration/`, `Package.resolved`, `.swiftpm/` in local packages), so the oracle never opens the container: it runs `-showBuildSettings -json` on a scratch workspace whose generated scheme lists every project target, under `sandbox-exec` for projects without packages (SwiftPM refuses nested sandboxes, so package projects run unsandboxed with a guard that removes the empty `.swiftpm/` trees). Configurations run concurrently with a 20 s bound each, then the offline resolver with a note; package projects reuse `<DerivedData>/SourcePackages` checkouts when the container's DerivedData has them, and a cold cache resolves one configuration first. That generated scheme makes xcodebuild report `ONLY_ACTIVE_ARCH = NO` and may specialize dependency targets to the host platform, so SET-005 judges the value the project files resolve to. MV-3 result on Xcode 26.0.1: `-xcconfig` beat a target-level value without `$(inherited)` (`-showBuildSettings`).

**v0.3 decision (2026-11-02), oracle cache and writes.** The scratch workspace, the per-configuration DerivedData and any package clones live outside the repository in `~/Library/Caches/xcblame/oracle/<sha16(container path)>/` (`$TMPDIR/xcblame/…` when that is not writable, `XCBLAME_CACHE_DIR` overrides; §5.8 pattern); only the settings JSON stays in `<xcblame-dir>/cache/settings`, and every `doctor`/`analyze` run that creates `<xcblame-dir>` writes its `.gitignore` (with `cache/`). Entries unused for 30 days are pruned by `doctor` and `history prune`; `history prune --oracle-cache` removes them all; `doctor --verbose` prints the size. The write guard snapshots every folder under the container root and every local package root (nested packages included; `.git`, `.build`, `DerivedData`, `node_modules`, `Pods`, `.xcblame` skipped; 200k entries at most) and removes the new folders that hold only empty folders, restoring parents' mtimes and naming them in `project.notes`. Package checkouts are reused from the project's own DerivedData (Xcode's roots matched by `WorkspacePath` with or without build logs, or a project-local `-derivedDataPath`/Flutter `build/ios` folder whose `info.plist` names the container or whose checkouts hold every pin) only when their `workspace-state.json` revisions equal `Package.resolved` (no `Package.resolved`: not used), and never in place, since xcodebuild rewrites `workspace-state.json` in whatever folder it is given: they are APFS-cloned (`cp -c`, plain copy up to 2 GB) into the oracle entry, refreshed when the source revisions change, and every call passes `-skipPackageUpdates`; a Flutter app's `<app>/build/ios` next to the `ios/` folder is searched too. A cold resolve that times out for the first configuration skips the others, a destination that failed once is not retried by other configurations, `doctor` caps the whole oracle run at 30 s, and the oracle home is capped at 5 GB (least recently used entries pruned, marker-checked). **`analyze` never resolves packages**: 5 s per configuration, existing checkouts only (the project's or the oracle cache's), else the offline resolver at once with a note. Each configuration has its own deadline. **Per-platform destinations (v0.3 decision, 2026-11-02):** targets are grouped by their written `SDKROOT` (else the first `SUPPORTED_PLATFORMS` word, project level included) and each group runs with `-destination generic/platform=<iOS|macOS|tvOS|watchOS|visionOS>` and its own generated scheme (one call per configuration when the project is uniform), so an iOS dependency target is no longer evaluated as macOS / Mac Catalyst and its `[sdk=iphoneos*]` values apply; a group whose destination fails runs without one, with a note naming its targets. Shadowing counts a conditional assignment for any SDK the target supports (device and simulator). A shadowed `+V` rule plans `xcblame verify --mechanism cli` before `--edit-project`; a value from a CocoaPods-generated xcconfig (`Pods/Target Support Files/**`, `Pods-*.xcconfig`) is `recommend` with a Podfile `post_install` snippet; a flag-removal fix whose key comes from an xcconfig recommends editing that file. **v0.3 decision (2026-11-01):** ENV findings count in `doctor --fail-on`: the state of the machine running `doctor` is in scope for doctor (under `analyze` they are labelled "this machine" instead).

### 7.5 The xcconfig overlay and the `baseConfigurationReference` problem

The constraint:

1. Xcode reads an xcconfig only when a configuration points at it through `baseConfigurationReference` (one per configuration per level) or through an `#include` from such a file. An IDE build has no other hook.
2. An xcconfig at a level loses to explicit values in the project file at that level and to every higher level. Many catalog fixes exist precisely because someone set the value explicitly in the pbxproj.
3. Command-line settings (`KEY=VALUE`, `-xcconfig <file>`, the `XCODE_XCCONFIG_FILE` environment variable) are documented to sit above project settings, but research reports that "an -xcconfig flag gets overridden by target-level settings that lack $(inherited)" ([DS] §6.3). Their real precedence is MV-3. They exist only for xcodebuild, not the IDE, and they reach SPM package targets, which project-level xcconfigs do not ([PP] A16).
4. Generated projects (XcodeGen, Tuist) and CocoaPods-managed xcconfigs are regenerated, so edits to them are lost.

Chosen approach:

- **Command-line delivery (CI, `build --overlay`, `verify --mechanism cli`)**: the Runner writes `.xcblame/tmp/wrapper-<Config>.xcconfig` and passes it with `-xcconfig`. The wrapper `#include`s, in order, the user's own `-xcconfig` file if one was on the command line (removed from the args), the file named by `XCODE_XCCONFIG_FILE` if set (the variable is then unset for the child), the overlay, and, for `--deep`, the injected flag lines, so nothing the user passed is lost and `--deep` flags are not overridden by an `-xcconfig`. Before building, the oracle is run with the same wrapper and every overlay key is checked per target: a key whose effective value did not change is reported as `shadowed (command line did not win, MV-3)` and is not counted as applied. **v0.6 fix round 1 (2026-11-06):** `build --overlay [<plan-id>]` delivers the plan's kept overlay lines (with `--overlay-unverified` also unverified non-+V ones) this way and refuses to build when any overlay key did not win (docs/SCHEMA-v0.6.md Decision 29).
- **IDE delivery (one-time hook)**: `fix --install-hook` makes each configuration include the overlay with an optional include, so deleting `.xcblame/` never breaks a build:
  - If the project-level configuration already has a `baseConfigurationReference` to a repository xcconfig, append `#include? "<relative>/.xcblame/overlay-Debug.xcconfig"` at its end. Text edit of a team-owned file; no pbxproj change.
  - Otherwise the hook sets project-level `baseConfigurationReference` to `.xcblame/hook-<Config>.xcconfig` (which includes the overlay). That is a pbxproj edit under §7.6 and requires `--edit-project` in addition.
  - XcodeGen/Tuist: the hook is printed as the source change (`configFiles:` in `project.yml`, Tuist settings); CocoaPods-managed xcconfigs: a printed Podfile `post_install` snippet. Not applied.
- **Shadowing**: per overlay line the planner compares provenance (§7.4). If a higher level sets the key explicitly, the fix is not applied through the overlay. The finding offers, in order: `cli` delivery for CI (conditional on MV-3 and on the oracle check above), `--edit-project` (remove the shadowing value so the overlay wins), or recommend. Nothing is ever edited in the pbxproj automatically.
- **v0.6 decision (2026-11-05).** **Shadowing is a hook-only concept** (probes-v0.6 Q1, Q3, Q9): a target-level pbxproj value, with or without `$(inherited)`, does not shadow `-xcconfig` or `KEY=VALUE`, so command-line delivery reaches every key on every project and package target. Point 3 of the constraint is answered: the command line sits above every project level. A fully hook-shadowed overlay finding keeps its overlay lines and offers, in order: `cli` (always reaches; the oracle run with the wrapper confirms, it does not gate: `verify --mechanism cli`, CI), then recommend for Xcode builds (remove the shadowing value by hand); the plan step is `mechanism: cli` with `shadowing: full`. `--edit-project` is not offered in v0.6. A mismatch in the wrapper oracle check is reported as an unexpected precedence (a bug or an unprobed Xcode), not as `shadowed`.
- **Scope**: the hook reaches project targets only; command-line delivery reaches project and package targets. The plan prints, per rule, the targets each mechanism would change (from the oracle), and `verify` measures through the mechanism the fix will be delivered with (§7.8).
- **Content**: one file per configuration; `KEY = VALUE // xcblame SET-016 (plan 7f3a)`; list-typed keys start with `$(inherited)`; no `[config=...]` conditions [MV-9].
- **v0.6 decision (2026-11-05).** **Hook and content** (probes-v0.6 Q2, Q5, Q6, Q7; MV-9 resolved): the hook is `#include? "<path relative to the including file's folder>/.xcblame/overlay-<Configuration>.xcconfig"` appended as the **last** line of the project-level base xcconfig (last assignment wins and an include acts where it sits), never a plain `#include` (a missing plain include fails the build with exit 65 while `-showBuildSettings` exits 0), so the installer lints the include target itself and confirms with one `-showBuildSettings`; `fix --apply` warns when lines follow the hook. A base xcconfig shared by several configurations gets no hook. `[sdk=…]` conditions are allowed on overlay lines (honoured, stacked in either order, in a base xcconfig and in `-xcconfig`); `[config=…]` is unnecessary (one file per configuration). Overlay blocks are `// xcblame plan <id> rule <RULE>` … `// end xcblame plan <id> rule <RULE>`, removed byte-exactly by `--revert`.
- **Revert**: `fix --revert <plan>` removes that plan's lines; `fix --uninstall-hook` restores backed-up bytes.

### 7.6 Project editing protocol (`--edit-project`)

Only with `--edit-project` and only for non-generated projects ([TM] R11; XcodeProj history).

1. Refuse if git reports uncommitted changes to the file (`--allow-dirty` overrides).
2. Back up exact bytes to `.xcblame/backup/<timestamp>/`.
3. Edit textually and minimally: locate the object by its 24-hex ID, change or insert one `KEY = VALUE;` line in its `buildSettings` with the file's indentation; never re-serialize; new IDs only for the one `PBXFileReference` of the hook case (random 24-hex, collision-checked). For `project.xcproj` edit one key path, preserving order and formatting [MV-4].
4. Verify: re-parse (`PropertyListSerialization` / JSON), compare the object graph to the original with only intended keys different, run `xcodebuild -list` and `-showBuildSettings -json` and confirm the effective value changed; the diff must touch only intended lines. Any failure restores the backup.
5. Handle objectVersion 46-90, `shellScript` string or array, synchronized root groups (read-only), `project.xcproj` (edit only after MV-4).

### 7.7 Code-level findings

SRC rules never edit source. They print file:line, measured ms, matched pattern and a before/after template, for example SRC-001:

```
Sources/AcmeApp/StudioView.swift:394  expression took 62 ms to type-check
  before:  let w = a * 2 + b ?? 0 + (c > 0 ? c : d) * scale
  after:   let base: Double = a * 2 + (b ?? 0)
           let extra: Double = (c > 0 ? c : d) * scale
           let w = base + extra
```

SRC-011 (`final`) is the one code rule with an optional `--apply-code` later (v1.x).

### 7.8 Verify (A/B harness)

1. **Preconditions**: clean git tree for files the plan touches; AC power; thermal nominal (else warn); no other xcodebuild running.
2. **Mechanism**: the arm under test delivers the change exactly as the final fix will: `hook` (the hook must be installed; verify writes the overlay lines, builds without `-xcconfig`, and restores the overlay afterwards, also on signals) or `cli` (wrapper `-xcconfig`). A verdict records its mechanism; `fix --apply` refuses to deliver a rule through a mechanism other than the one it was verified with unless the oracle shows identical per-target effective values for both.
3. **DerivedData per arm**: for `incremental` and `zero-change` kinds each arm uses its own DerivedData (`~/Library/Caches/xcblame/verify/<plan>/<arm>/`), prepared by one unmeasured settle build, because toggling settings changes task signatures and would turn the next run into a rebuild. Interleaving (ABAB) is allowed only for `clean` (each run cleans anyway).
4. **Runs**: default 5 per arm; the first run of non-clean kinds is the settle build and is not measured, so ≥ 4 samples remain and the §6.10 noise model applies. With `--runs` < 4 the verdict is `indicative` and nothing is auto-kept.
5. **Validity checks per run**: exit code 0 on every run of both arms; the set of targets built and the multiset of executed task kinds per target must match between arms (for clean kinds) or be explained by the rule's declared effect (e.g. SET-004 removes `GenerateDSYMFile`); thermal warning excludes the run and replaces it once. A failed check reverts the rule with reason `broke build` or `task set changed`.
6. **Verdict** per rule (`--one-by-one`) or per batch: keep if after-p50 is lower beyond the noise band; revert if slower, within noise (unless `--keep-on-tie`), or invalid. The plan file records verdict, mechanism and per-target scope.

**v0.6 decision (2026-11-05).** Verdicts are `kept`, `kept (tie)`, `reverted (slower | within noise | broke build | task set changed | no effect)`, `indicative` (fewer than 4 runs or 3 samples per arm: never kept, never written by `fix --apply`) and `unverified` (not measured, e.g. after an abort). `reverted (no effect)`: the oracle check shows no reached target, so the unit is not built. Aborts (exit 6): dirty tree, battery, another xcodebuild, thermal, `--max-minutes`, a broken baseline build, an interrupt, a missing hook under `--mechanism hook`. On SIGINT/SIGTERM verify stops the running xcodebuild, then restores the overlay bytes. Under `hook` arm B's temporary block gets one fixed modification time per arm, so a series of incremental or zero-change builds does not re-plan for a new xcconfig mtime. `verify` without a stored plan builds one as `fix` does (docs/SCHEMA-v0.6.md).

---

## 8. Output formats and schema sketch

### 8.1 JSON report (`schemaVersion: "xcblame.report/1"`)

Values below are the r26 numbers of §3.3.

```json
{
  "schemaVersion": "xcblame.report/1",
  "tool": {"name": "xcblame", "version": "0.4.0", "kindTable": "2026.10.2", "ruleCatalog": "2026.10.1"},
  "input": {"kind": "xcactivitylog", "path": "<dd>/Logs/Build/20E8B73D.xcactivitylog", "reader": "slf",
            "logFormatVersion": 11, "bytesInflated": 12497589, "decodeWarnings": 0,
            "buildDescription": {"signature": "6f0b463d2f2edd5a58b553713dc8313d", "source": "snapshot",
                                 "commands": 747, "keyedTasks": 212, "unkeyedTasks": 365}},
  "env": {"xcode": {"value": "26.0", "source": "inferred", "evidence": ["MacOSX26.0.sdk", "25A352"]},
          "xcodeSelected": "26.0.1 (17A400)", "macOS": "27.0", "model": "Mac15,14", "cores": 28, "memGB": 96,
          "thermal": null, "rosetta": false,
          "derivedData": {"bytes": 411041792, "freeBytes": null, "internalSSD": true, "timeMachineExcluded": false},
          "notes": ["thermal: not recorded for builds analyzed after the fact", "freeBytes: probe timed out"]},
  "build": {"kind": "clean", "scheme": "AcmeApp", "configuration": "Debug", "destination": "macOS arm64",
            "status": "succeeded", "errors": 0, "warnings": 1, "logSpan": 18.14, "processWall": null,
            "outsideLog": null, "notes": ["processWall: only measured by `xcblame build`"]},
  "timing": {"busy": 18.07, "idle": 0.07, "taskTime": 139.84, "tasks": 577,
             "cpu": 123.32, "cpuTasks": 278, "metricsPlaceholdersIgnored": 188,
             "avgParallelism": 7.7, "peakLanes": 29,
             "serialStretches": {"thresholdLanes": 2, "seconds": 7.51, "total": 3, "shown": [ ]}},
  "criticalPath": {"basis": "dag+byTiming", "span": 18.14, "segments": [
      {"start": 0.0, "end": 1.83, "target": null, "kind": "planning", "task": "CreateBuildDescription", "basis": "dag"}],
      "segmentsTotal": 63, "segmentsShownShare": 1.0},
  "rollups": {"byPhase": [], "byKind": [], "byTarget": [], "byOwner": []},
  "files": [{"file": "Sources/AcmeApp/StudioView.swift", "target": "AcmeApp", "seconds": 2.39,
             "granularity": "exact", "onCriticalPath": true}],
  "filesTotal": 26, "filesShownShare": 0.04,
  "hotspots": [{"file": "Sources/AcmeApp/StudioView.swift", "line": 399, "col": 25, "ms": 425.05,
                "kind": "functionBody", "decl": "StringsView.body", "source": "debug-time-function-bodies"}],
  "hotspotsTotal": 4, "hotspotsShownShare": 0.25,
  "incremental": null,
  "fixedCosts": [{"class": "planning", "seconds": 1.83, "perDay": null, "perDayAssumedBuilds": 50}],
  "moduleGraph": {"targets": 13, "variants": {"modules": 64, "pcmTasks": 143, "redundantTasks": 79,
                  "redundantSeconds": 7.59, "causes": ["language-mode", "SWIFT_PACKAGE"]}},
  "findings": [{"ruleId": "SET-024", "impact": {"band": "S", "seconds": 4.0, "basis": "pathShare"},
                "confidence": "high", "evidence": [], "fix": {"kind": "recommend"}, "seeAlso": []}],
  "findingsTotal": 4,
  "regression": null,
  "validation": {"checks": [{"id": "V5", "status": "warn",
                 "detail": "WriteAuxiliaryFile: 85 tasks / 0.470 s vs summary 84 / 0.278 s"}],
                 "degraded": false, "notes": []},
  "truncation": {"applied": false},
  "notes": ["incremental: null because build kind is clean"]
}
```

Rules: every capped array has `<name>Total` and `<name>ShownShare`; unknown values are `null` with a reason in the nearest `notes[]`, never `0`; a section that does not apply to this build kind is `null` with a note; times in seconds; schema published by `xcblame schema` and tested in CI; additive changes keep version 1.

### 8.2 HTML report (`--format html`)

The HTML report is the main human-facing deliverable: the page a developer opens after a build, and the file a CI job attaches as an artifact. Draft v2 left HTML out because XCLogParser's HTML reports grew to 1.3-1.4 GB in 19,741-44,712 files, a `build.js` of 3-4 GB crashed Chrome, and pages went blank when the CDN was blocked ([TM] XLP#108/#202/#130/#220, R9). The user decided on 2026-10-31 that HTML is required (Appendix B row 39). The lesson stays as hard rules: one file, a hard size cap, ordered and visible truncation, and no network.

#### 8.2.1 Principles

1. **One self-contained file.** CSS, JS and icons are inline (icons as inline SVG). There are no sibling files, shards or per-target pages.
2. **Zero network.** No `<script src>`, `<link href>`, `@import`, remote `url(...)`, web fonts, `fetch` or `XMLHttpRequest`; the page uses the system font stack. A CSP meta tag (`default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:`) makes any accidental load fail visibly. The page works offline, from `file://`, and as an unzipped CI artifact. Source links inside rule explanations are ordinary links the user clicks (`rel="noreferrer"`). Nothing loads when the page opens.
3. **Data is one JSON blob.** It sits in `<script type="application/json" id="xcblame-data" data-encoding="json">`. The blob is the `xcblame.report/1` document (§8.1) that the same command prints with `--format json` and the same options. HTML defaults to `--top all`, so the JSON to compare against is `--format json --top all`. The blob adds one member, `taskIndex` (§8.2.2), which JSON leaves out because history already stores it (§8.3). Counts in the page therefore equal the JSON `*Total` values by construction. **Encoding: plain minified JSON, not gzip+base64.** Reasons:
   - (a) Parity and debuggability: the blob is the same bytes as the JSON output, and `sed`/`jq` can pull it out.
   - (b) `JSON.parse` is synchronous and fast (about 40 ms for 4 MB). Gzip needs an async `DecompressionStream` (Safari 16.4+) plus a base64 decode, and both sit on the first-paint path.
   - (c) Base64 adds 33 % and makes the file opaque.
   - (d) CI artifact stores (GitHub Actions zips artifacts) and mail already compress, so in-file compression saves little in transit.
   - (e) The §8.2.3 budget keeps the plain file small.

   Cost accepted: a task-heavy report is 3-5x larger on disk than a gzip blob would be. Revisit this only if real projects under 50k tasks hit the cap. `data-encoding` keeps a later `gzip+base64` mode an additive change.
4. **Vanilla JS, one template file.** `Sources/Reporters/Resources/report.html` holds the HTML, one `<style>` and one `<script>`. There is no framework, package manager, bundler or TypeScript, and the web part has no build step. The code is ES2020, so Safari 16+ and Chrome 110+ run it. Template budget: 150 KB, raised to 240 KB on 2026-11-02, to 280 KB on 2026-11-03 (§8.2.5 clarity decisions) and to 300 KB on 2026-11-05 (§8.2.5 v0.6 verify and fix-plan views), then lowered to **200 KB** on 2026-11-08 (§8.2.5 cockpit decision).
5. **Theme.** Light only (cockpit decision, 2026-11-08): one set of CSS custom properties on `:root`, `<meta name="color-scheme" content="light">`, no `prefers-color-scheme` block and no toggle. Every text token meets WCAG AA (4.5:1) on the grounds it sits on: `--ink` `#111`, `--ink-2` `#52525b` and `--muted` `#63636b` on `--bg` `#fff` and `--panel` `#f7f7f8`; `--accent-ink` `#c2410c` for orange text and numbers; `--good` `#067647`, `--warn` `#92400e`, `--bad` `#b42318` on `--bg`. The accent `#F97316` is a fill only (bars, ribbon, badges with `#111` text), never text. Color never carries meaning alone: the critical path is shown by color, hatching and a label.
6. **Print.** `@media print` expands collapsed sections, hides controls and prints every embedded row. On `beforeprint` the timeline canvas is copied into an `<img>`.
7. **Keyboard and accessibility.**
   - Tables are real `<table>` elements with `<th scope>` and `aria-sort`. Enter or Space on a header sorts.
   - Rows use a roving tabindex: ↑/↓ move between rows, Enter opens the drill-down, and `/` focuses the filter box.
   - Every canvas has a table equivalent.
   - Hash anchors (`#files`, `#target=LocalizeCore`) make a view linkable.
8. **Same truncation and unknown rules as JSON** ([TM] R3, BTA#10).
   - Every table header shows "shown N of Total (S % of seconds)", taken from `*Total`/`*ShownShare`.
   - `null` renders as "unknown (reason)", using the reason from the nearest `notes[]`; it never renders as `0`.
   - A section whose JSON value is `null` renders one line, "not applicable: <note>". It never disappears.
   - A number the Validator withheld renders as "unavailable because ...".
   - A banner lists every truncation step (§8.2.3).
9. **Deterministic.** The same input and options give a byte-identical file (NFR-12). The only date shown is the report's own.
10. **Text, never markup.** Every log-derived string goes into the page with `textContent` or `createTextNode`, never `innerHTML`, and no JS is built from strings. The template contains no user data outside the blob ([TM] XLP#142).

#### 8.2.2 Members added to the report document

These members are additive to schema v1 and published by `xcblame schema`. All except `taskIndex` also appear in `--format json`.

| Member | Content | Size control |
|---|---|---|
| `timing.utilization` | `{bucketSeconds, lanes[]}`: average running tasks per bucket. Bucket = max(0.1 s, span / 4,000). Computed from all tasks before truncation. | ≤ 4,000 numbers |
| `rollups.byTarget[].kinds` | Task time per kind for each target (kind mix). | per row |
| `moduleGraph.nodes`, `.edges`, `.criticalChain` | Graph for the SVG view: per node owner, depth, variant count, macro plugins, on-path seconds. | `nodesTotal` / `nodesShownShare` |
| `ruleDocs` | For each `ruleId` in `findings`: title, summary, fix text and sources (the `rules explain` text), so the explanation is inline. | only rules present |
| `taskIndex` (HTML only) | Columnar task table for the timeline. Arrays `start`, `dur` (integer ms from the window start), `lane` (greedy packing done in Swift), `target`, `kind`, `label` (indexes into interned `targets`, `kinds` and `labels` string tables), and `onPath` (0/1). Also `dropped` per target and lane, after truncation. No keys, signature digests, command lines or compiler output. | `taskIndexTotal` / `taskIndexShownShare` |

`compare --format html`, `trend --format html` and `verify --format html` embed the document that the same command prints with `--format json`. Compare embeds both reports, each held to half the data budget, plus `regression`. Trend embeds history summaries only, with no task indexes. Verify embeds the per-rule run table.

#### 8.2.3 Size budget and truncation

- **Cap.** The whole file is at most 8 MB, template included. The cap is `--max-report-bytes`, whose html default is 8 MB. Data budget = cap − template bytes (≤ 200 KB since 2026-11-08, §8.2.5). The cap is hard: the file never exceeds it, and size never fails the command (it exits 0 and prints a warning on stderr).
- **Totals first.** Truncation runs on the document before serialization. Every `*Total`, sum, rollup partition (with its "other" row), utilization series and critical-path segment is computed from the full model first. Truncation removes rows and never changes a headline number (V6, V13).
- **Order.** Each step runs only until the blob fits, and each has a floor it never goes below:
  1. **Hotspots tail.** Drop rows < 10 ms, then keep the top 500. Floor: top 25, the JSON default. `-debug-time-function-bodies` on a large app yields tens of thousands of rows.
  2. **Files tail.** Drop rows < 0.1 % of compile task time, then keep the top 1,000. Floor: top 25.
  3. **Task-index detail.** Drop off-path tasks < 50 ms, then < 250 ms, then < 1 s. Floor: every on-path task plus each target's longest task. Dropped tasks are counted per target and lane in `taskIndex.dropped`, and the timeline draws them as a hatched "N tasks, D s not shown" band. The utilization strip still uses all tasks.
  4. **Module graph.** Collapse nodes outside the critical chain and its direct neighbours into "N more modules (owner)". Floor: the critical chain.
  5. **Targets and other rollups tail.** Floor: top 25 plus the "other" row, so the partition stays (V6).
  6. **Findings evidence.** Floor: 3 evidence items per finding. Findings are never dropped.
  7. **Diagnostics.** Drop notes and duplicate occurrences first (counts stay). Errors are never dropped.
  8. **Last resort.** If the floors still do not fit, drop `taskIndex` entirely; the timeline then shows path segments and the utilization strip. If that still does not fit, keep only the header, the findings and validation, plus the banner.
- **Recorded.** Each step appends `{"step": "hotspots", "kept": 500, "total": 18402, "shownShare": 0.93}` to `truncation.steps`. The banner at the top of the page prints these entries.
- **Escape hatch.** The banner and the timeline footer give the exact command for full detail: `xcblame analyze <same input> --format chrome-trace -o build.trace.json`, to open in the Perfetto UI or speedscope. The command is plain text, not a link. `--format json --top all` gives the untruncated tables.
- **AcmeApp r26 estimate** (§3.3, §8.1 numbers):
  - Report document with all rows: about 35 KB minified (63 path segments × ~110 B, 12 target rows with kind mix, 26 files, 4 hotspots, 4 findings with `ruleDocs` ~4 KB, 15 checks, 13-target / 64-module graph with variants ~10 KB, 182 utilization buckets).
  - `taskIndex`: 577 rows × ~25 B plus ~450 interned labels × ~35 B, about 30 KB.
  - Template: 120-150 KB.
  - **Total: about 0.2 MB (≤ 0.25 MB), no truncation, about 60 KB gzip-compressed as a CI artifact.** The v0.2 exit criterion of ≤ 1 MB leaves 4x headroom.
  - A 50k-task synthetic: `taskIndex` ≈ 50k × 25 B + ~20k labels × 40 B ≈ 2.1 MB; with 5k files and 20k hotspots the total is about 4-5 MB, still under the cap. The first truncation to trigger beyond that is the hotspot tail.

**v0.2 decision (2026-11-01).** The budget trims `topTasks` first, before the hotspot tail: html uses `--top all` and embeds every task in `taskIndex`, so `topTasks` only repeats them. Step 5 also records `serialStretches`, `idleGaps`, `tasksWithoutTiming` and `decodeWarnings` (floor 25 each).

#### 8.2.4 Sections

UX sources ([ET] §3):
- The timeline follows Xcode Build Timeline and cargo `--timings` (empty space = blocked; concurrency under the bars).
- The owner and kind columns follow Android Build Analyzer (time per owner).
- Compare follows Gradle Build Scan (build-vs-build diff as the explanation).
- Hotspots grouped by file with totals follow ClangBuildAnalyzer (aggregate, then rank).

Each section carries `data-total` / `data-shown` attributes for the tests in §8.2.5. Since the cockpit decision (2026-11-08, §8.2.5) there is no sticky index; hash anchors still work and open the collapsed block that holds their target.

**First screen (cockpit, 2026-11-08).** Every page kind opens with the same slots, filled per document kind:
- `header#top`: the scheme and one chip per fact (`ul#meta > li[data-chip=kind|xcode|time|host|quality|degraded|redacted|doctor]`); the quality chip reads `N pass · N warn[ · N fail]`, the red `degraded` chip links to #10.
- `#start-here`: `p#headline` ("18.1 s clean build · 12 % slower than the previous clean build (16.2 s, 3 days ago)"; the delta clause comes from `previous` (docs/SCHEMA-v0.6.md "report: previous"), else from `regression` "than baseline", else it is left out), `p#floor` (the critical path: the build cannot be faster than this without changing the graph) and `p#waste` (span minus the floor), one line each; the truncation banner `#truncation` when anything was cut.
- "Do this first" (`ol#start-actions`): at most 3 `li.act`, each with what to change, the saving (seconds, %, or the catalog band marked "estimated"), the confidence, exactly one command or Xcode click path with a Copy button, and how to undo it. Ranked by measured seconds, then band (measured, estimated, unmeasured last), plus the longest path step of the user's own targets; Xcode's own work and bucket targets are never an action. With nothing to do, `#nothing-to-fix` names the floor, its target and step.
- The board: `#where` (critical-path seconds by target, Xcode work folded) and `table#hot5` (the slowest type-checks).
- `#summary`: five KPI tiles (`.kpi[data-kpi=span|task|tasks|par|cp]`) and `#cp-ribbon`, the critical path as one bar.

**Below the first screen.** Every section is a `details.sec-d` with an `h2` and a subtitle of at most eight words, closed by default, except Findings (#6), Why (#7) on incremental and why pages, and the page's own section on compare, trend, verify and fix-plan pages. Xcode's own work (build system, explicit modules, PCM, SDK stat cache) folds into one row in #2, #3 and `#where`, with a "Show Xcode work (N)" toggle. Tables show their top rows with a "Show all N rows" button: files 10, hotspots 15 (on-path or at least 100 ms first), targets 15, compare tasks 25, why cause tasks 10. Findings are one table row each with an expandable detail row; findings without a band sit under one "N unmeasured" housekeeping row. Notes, checks, degradations, environment and diagnostics live in one closed Details group (`details#details-group`: #14, #10 and the notes). Definitions are not on the page: they live in [REPORT.md](REPORT.md), [RULES.md](RULES.md) and `xcblame rules explain`.

| # | Section | What it shows | Fed by | Lands |
|---|---|---|---|---|
| 1 | Header | <ul><li>Build kind badge, scheme, configuration, destination, status.</li><li>Errors/warnings count, which expands to the deduped diagnostics.</li><li>Xcode version with an `inferred` badge and its evidence; `xcode-select` version.</li><li>Host: model, cores, RAM. Host name only without `--redact`.</li><li>Separate tiles for log span, process wall, busy, task time and CPU (with `cpuTasks`).</li><li>Validation badge ("13 pass · 1 warn"; `degraded` in red) linking to section 10.</li><li>Truncation banner.</li></ul> | `tool`, `input`, `env`, `build`, `timing`, `validation`, `truncation`, `notes` | v0.2 |
| 2 | Critical path timeline | <ul><li>Gantt over [0, span]: path segments grouped by target as in §3.3. Each bar shows seconds, share and a basis badge (`dag`/`byTiming`/`inferred`); waits are hatched.</li><li>What-if in a target's tooltip, DAG basis only: "up to N s if X took no time".</li><li>Below the Gantt, a utilization strip: lanes over time with the serial threshold line. Serial stretches and idle gaps are shaded.</li><li>Optional "all tasks" view: lanes × time from `taskIndex`, with on-path tasks outlined.</li><li>Drawing: one `<canvas>` that draws only the visible window and bins tasks into pixel columns when there is more than one task per pixel. Wheel/pinch zoom, drag to pan, hover lookup by binary search on sorted starts.</li><li>A segment table is the accessible equivalent.</li></ul> | `criticalPath.*`, `timing.utilization`, `timing.serialStretches`, `timing.peakLanes`, `taskIndex` | v0.2 |
| 3 | Targets | <ul><li>Sortable columns: target, owner, task time, on-path s, what-if (DAG), tasks, kind-mix stacked bar, busy. Includes the "other" row.</li><li>Click or Enter opens a drawer with that target's tasks from `taskIndex` ("shown N of M") and highlights them in the timeline.</li></ul> | `rollups.byTarget[]` (+ `kinds`), `rollups` Totals/ShownShare, `taskIndex` | v0.2 |
| 4 | Files | <ul><li>Sortable columns: file, target, seconds, granularity badge (`exact` / `batch N files` / `estimated` / `wmo`), on-path, type-check ms.</li><li>Batch rows expand to their members.</li><li>The footer shows totals per granularity; `estimated` is never summed with `exact` (V9).</li></ul> | `files[]`, `filesTotal`, `filesShownShare` | v0.2 |
| 5 | Hotspots | <ul><li>Grouped by file: file total ms next to the file's compile seconds.</li><li>Rows: `line:col`, declaration, kind, ms, source flag, on-path weight; labelled "type-check only".</li><li>Copy button copies `path:line:col` (Clipboard API, falling back to text selection).</li></ul> | `hotspots[]`, `hotspotsTotal`, `hotspotsShownShare`, `files[]` | v0.2 |
| 6 | Findings & fix plan | <ul><li>In fix-plan order: rule id, title, impact band with seconds and basis, confidence, evidence, fix kind, risk, mechanism.</li><li>"Copy xcblame command" copies the commands the text plan prints (`xcblame verify --rules SET-016 --kind clean --mechanism hook`, then `xcblame fix --rules SET-016 --apply`).</li><li>The rule explanation expands inline from `ruleDocs`, with sources.</li></ul> | `findings[]`, `findingsTotal`, `ruleDocs` | v0.2 (populated from v0.3) |
| 7 | Incremental why | <ul><li>Non-clean builds only.</li><li>Cause tree: cause class → causes → tasks, with task seconds and path seconds.</li><li>Two rankings as tabs, never summed.</li><li>The `unknown` row is always visible with its share and the `why --backtraces` hint; V15 status shown.</li></ul> | `incremental` | v0.5 |
| 8 | Fixed costs | Seconds per build and per day for each class. Per-day values based on `buildsPerDay` carry an "assumption" label. | `fixedCosts[]` | v0.5 |
| 9 | Module graph | <ul><li>Layered SVG (depth = longest path) inside `<g transform="translate() scale()">`, with zoom buttons, ⌘/Ctrl + wheel zoom (a plain wheel scrolls the page), drag to pan and 1:1 reset (the xcpurge pattern).</li><li>Critical-chain edges highlighted; node badges for variant count and macro plugins.</li><li>More than 300 nodes collapse by owner.</li><li>Clicking a node opens its target row.</li></ul> | `moduleGraph.*` | v0.5 |
| 10 | Environment & validation | <ul><li>Env table with `source` and probe notes.</li><li>Every check V1-V15 with status and detail; a failed check names the number it withheld.</li><li>Reader, decode warnings, build-description basis.</li></ul> | `env`, `input`, `validation.checks[]` | v0.2 |
| 11 | Compare | <ul><li>Headline delta with noise band and verdict (`indicative` below 3 runs per side).</li><li>Environment differences first, then diverging bars per phase, target, path composition, new/removed tasks and settings.</li><li>Both timelines on one time axis.</li></ul> | compare document: `a`, `b`, `regression` | v0.4 |
| 12 | Trend | <ul><li>p50/p95 sparklines per kind (SVG small multiples), grouped by `--by`.</li><li>Markers where the inferred Xcode version changes.</li><li>Each point shows its history entry id.</li></ul> | trend document | v0.4 |
| 13 | Verify | Per rule: arms, runs ok/total, one dot per run, p50 ± MAD, noise band, verdict, mechanism, per-target scope. | verify document | v0.6 |
| 14 | Diagnostics | Errors and warnings deduped, with counts (`#dg-mini`) and the table (`#dg-table`); inside the Details group. | `diagnosticsSummary`, `diagnostics[]`, `diagnosticsTotal` | cockpit (2026-11-08) |

Sections per command:
- `analyze` and `build --html`: 1-6 and 8-10, plus 7 for non-clean builds.
- `why`: 1, 7, 2, 3, 10.
- `doctor`: a project variant of 1 (generator, no build), then 6, 10, and the PASS/N/A lists. Build-only sections show "doctor runs no build" (v0.3).
- `compare`: 11, with a header for each side.
- `trend`: 12.
- `verify`: 13 and 6.

**v0.5 decision (2026-11-02), module graph zoom.** #9 keeps the xcpurge behaviour: ⌘/Ctrl + wheel (and pinch, which browsers deliver as a ctrl-wheel) zooms at the cursor, a plain wheel scrolls the page, the buttons zoom by 1.25 / 0.8 around the centre and 1:1 resets; a graph in the middle of a long page must not capture scrolling. The timeline (#2) is unchanged. The template stays within its 150 KB budget (148.9 KB with #7-#9), and ids stay unique across the whole report page.

**v0.4 decision (2026-11-02).** The compare (#11) and trend (#12) regions share the page's table helpers: `PAGE`, `tables` and `makeTable` are declared above the `schemaVersion` dispatch (`cls` may be a function of the row; `onShown(n)` and `rowAttrs(row)` are optional), so the compare tables and the trend points tables page, sort and print like the report's; DOM ids and `data-total` contracts are unchanged except that the compare headline's critical-path cell is `#cmp-path-span` (`#cmp-path` is only the composition block), and ids are unique per page.

**Render performance (NFR-15).**
- Order: parse the blob, then the header, the critical path, and the sections in view. Off-screen sections render when an `IntersectionObserver` reaches them.
- Tables render 200 rows at a time behind a "show 200 more" button, so no table holds thousands of DOM rows.
- Rows are built in a `DocumentFragment`.
- A timeline redraw takes ≤ 16 ms.
- The template sets `performance.mark('xcblame:first-paint')` once sections 1 and 2 are painted.

#### 8.2.5 Generation and tests

- **Embedding (the xcpurge approach).** `make template` runs `Scripts/embed-report-template.sh`. The script writes `Sources/Reporters/ReportTemplate.swift` (`enum ReportTemplate { static let html = #"""…"""# }`), choosing a raw-string delimiter that the HTML never contains. The binary therefore needs no resource bundle, and copied-out binaries and Homebrew bottles render HTML. A test fails when `report.html` and `ReportTemplate.swift` drift apart.
- **Rendering.** `HTMLReporter`:
  1. Builds the report document through the same code path as `--format json`.
  2. Runs the Redactor when `--redact` is set (the default for html).
  3. Runs the budget pass (§8.2.3) and adds `taskIndex`.
  4. Serializes minified JSON with sorted keys, then escapes it for script data: `</` → `<\/`, `<!--` → `<!--`, U+2028/2029 → ` `/` `. The result is still valid JSON.
  5. Fills the HTML-escaped placeholders (title, tool version), then substitutes the blob into `{{DATA}}` last, so text in the data that looks like a placeholder is never replaced.

  `analyze <report.json> --format html` re-renders a saved JSON report without re-parsing the log. This lets CI render from an artifact.
- **Page.** The page runs `JSON.parse(document.getElementById('xcblame-data').textContent)` and checks that the `schemaVersion` major is 1. Otherwise it renders the header with "made by a newer xcblame". Unknown members are ignored. `window.onerror` writes into a `#js-errors` element, which stays hidden while empty.
- **Writing and opening.**
  - The file goes to `-o` or `.xcblame/reports/<yyyyMMdd-HHmmss>-<kind>.html`, written atomically (temp file + rename). Stdout gets the summary line and the path.
  - `--open` runs `/usr/bin/open [-a <browser>] <file>` via `ReportOpener` and falls back to the default browser with a warning.
  - Without `--open`, xcblame prints an `open "<path>"` hint. With `CI=true`, `--open` is ignored with a note.
- **Tests, tier 1: `swift test`, every run, no browser.**
  - (a) Parity: the blob, extracted by its `id`, parses. With `taskIndex` removed it is byte-equal to `--format json --top all` for the same fixture.
  - (b) Escaping: the blob contains no `</script` or `<!--`. Hostile fixture strings (`</script><img onerror=…>`, an apostrophe in the host name, U+2028) round-trip unchanged.
  - (c) No unfilled `{{…}}` placeholders.
  - (d) No network references in the template: no `src=`/`href=` with a scheme, no `@import`, no `url(` other than `data:`, no `fetch(` or `XMLHttpRequest`.
  - (e) Size: the AcmeApp r26 fixture renders to ≤ 1 MB. The 50k-task synthetic renders to ≤ 8 MB with `truncation.steps` recorded and every `*Total` equal to the untruncated document's.
  - (f) Redaction: with `--redact`, no `$HOME`, user or host string appears anywhere in the file.
  - (g) Template drift.
  - (h) Determinism: two renders are byte-identical.
- **Tests, tier 2: headless DOM, CI on macOS runners (which ship Google Chrome); `XCTSkip` locally when Chrome is absent.**
  - Reuses xcpurge's helper: `Google Chrome --headless=new --dump-dom --virtual-time-budget=3000 --host-resolver-rules="MAP * ~NOTFOUND"` on the generated file. The resolver rule blocks the network, which proves the page works offline.
  - Asserts that `#js-errors` is empty, that each section's `data-total` equals the JSON `*Total`, and that rendered row counts equal the embedded rows (or 200 where a table pages).
  - `HTMLCockpitTests` (2026-11-08, replacing `HTMLClarityTests`) checks the first screen and the collapsed layout on every page kind (report, doctor, compare, trend, why, incremental, verify, fix plan): `#headline` (with the delta clause from `previous` or `regression`), `#floor`, `#waste`, at most 3 complete actions or `#nothing-to-fix`, the Xcode fold and toggle, the top-N counts, the closed Details group, which sections start open, and on the AcmeApp clean fixture at most 400 visible words (`body[data-visible-words]`) and 150 visible rows (`body[data-visible-rows]`).
  - `HTMLTemplateTests.testProseBudget` (tier 1, no browser): at most 200 static words in the markup, at most 3,000 words in multi-word JS string literals (ratcheted down as the template shrinks), every tooltip at most 12 words, and none of "What this shows", "What to do:", "glossary", `what-this-shows`, `col-defs`, `prefers-color-scheme`. `testTextTokensMeetAAInTheLightThemeAndKindColoursAreCached` checks the light tokens of §8.2.1 #5.
- **Tests, tier 3: WebKit smoke, nightly CI.**
  - `safaridriver` ships with macOS and needs no Node; the runner enables it with `sudo safaridriver --enable`.
  - Loads the AcmeApp fixture and the 50k-task synthetic, repeats the count check, and asserts that `xcblame:first-paint` is < 1 s.
  - Playwright-WebKit would also work but would add Node to CI, so it is not used.

**v0.2 decision (2026-11-01).** The blob is the pretty-printed `--format json` output plus one compact `taskIndex` line at its sorted position, not minified JSON (step 4): byte parity with `--format json --top all` wins over minification. `<!--` is escaped as `\u003c!--` (`\!` is not a JSON escape).

**Clarity decision (2026-11-02).** The pages are written for a junior iOS developer with no build-system background (audit: [reviews/html-clarity-audit.md](reviews/html-clarity-audit.md)). Every page kind opens with a "Start here" section (`#start-here`: what was measured, the key number, the top three actions as links); every section carries a `.what-this-shows` line and, where actionable, a `.what-to-do` line; every column header has a `title` definition repeated in a visible `.col-defs` line; unknown cells carry their reason as a tooltip and a numbered `.unk-notes` footnote; every table with a JSON Total shows a visible `.shown-of-total` line with the command for every row; nothing that holds a table starts collapsed; a `#glossary` section (at least 25 terms, `dt id="g-…"`) is the target of every dotted `a.term`. Charts are vanilla SVG next to their tables (summary: wall time by path kind and task time by kind; targets on-path vs task time; hotspots per file; why by cause class; fixed costs per class; compare headline with the noise band; trend min/max and Xcode markers; module graph arrows and the longest-chain label), each a `figure.chart` with `data-total`, a caption, a legend and axis labels, and never drawn without data. DOM ids and the `data-total` / `data-shown` contracts above are unchanged. The template budget rises from 150 KB to **240 KB** (the template is 223 KB); the 8 MB file cap is unchanged, so the data budget shrinks by the same 90 KB. `HTMLClarityTests` checks all five page kinds in headless Chrome.

**Clarity decision, round 2 (2026-11-03).** Review: [reviews/html-junior-reader-review.md](reviews/html-junior-reader-review.md). "Start here" lists actions only: each says what to change (the Xcode label, file, key and value, or the command) and how to check it worked (`xcblame compare`); actions rank by measured seconds, then band, then confidence. Before a build measures a finding, the catalog band ranks it (`findings[].estimatedBand`, shown as "estimated impact"); findings with no band at all are a separate **Housekeeping** list (confidence is shown on each action, "how sure: low — settings read offline", and never demotes a finding with a band) (`RulePlan.isHousekeeping`), ordered by severity, project-specific evidence and the plan's guards. Xcode's own work on the path (`explicit modules`, `build system`) is explained under "Xcode's own work", never offered as something to shorten. Finding cards carry no citation codes, vendor names or internal shorthands (the JSON and `xcblame rules explain` keep them); the mechanism reads as a sentence; `findings[].inXcode` gives the Build Settings label (`XcodeSettingLabels`). The fix plan starts with "commit your changes first", puts guards before the edits that need them and measures every project edit first (docs/SCHEMA-v0.5.md "Clarity additions"). Long tables render every row but show the top rows (files 25, compare task lists 25, why cause tasks 10, variants 10) with a visible "Show all N rows" button; consecutive steps of Xcode's own work on the critical path fold into one row. An unknown cell shows a short reason and a "why? N" link to the numbered reason under its table. Times are local, with the zone named. The template budget rises to **280 KB** (the template is 265 KB).

**v0.6 verify and fix-plan views (2026-11-05).** #13 (`#verify`: Start-here sentence per unit, abort banner, A vs B dot chart with the noise band, results table with one mark per run, "why? N" verdict reasons) and the fix-plan page (`#fixplan`: steps with mechanism, verify state and scope, guards, hook per configuration, copyable commands) follow the clarity standard above, with glossary entries for arm, baseline arm, mechanism, revert, settle build and task set (docs/SCHEMA-v0.6.md "HTML"). `xcblame verify` and `xcblame fix` are ordinary, copyable commands on every page; only `--edit-project` keeps a "not available yet" label. The template budget rises to **300 KB** (the template is 292 KB); the 8 MB file cap is unchanged.

**Cockpit decision (2026-11-08).** Supersedes the two Clarity decisions above and the glossary part of the v0.6 views. The clarity pages answered every question but buried the three that matter (how long, how much of it is waste, what to do first) under about 1,000 static words and 10,000 words of tooltips and what-lines. The first screen now answers those three with numbers (§8.2.4 "First screen"), and everything else is one click away:
- No glossary, no `.what-this-shows` / `.what-to-do` lines, no `.col-defs` lines, no `.unk-notes` footnotes, no `.shown-of-total` paragraphs and no dotted `a.term` links. Definitions moved to [REPORT.md](REPORT.md) (the glossary condensed), [RULES.md](RULES.md) and `xcblame rules explain`; the footer names `docs/REPORT.md` as plain text. An unknown cell shows "unknown" with its reason as the tooltip.
- Collapsed sections are allowed ("nothing that holds a table starts collapsed" is withdrawn); the open defaults are in §8.2.4. Print and hash anchors open every collapsed block.
- At most 200 static words in the template, tooltips of at most 12 words, section subtitles of at most 8 words; the cause label "What to do:" becomes "Fix:". The word tables (band, confidence, fix, cause, source, mechanism, abort, hook, check and step words) hold at most 8 words per entry.
- Light theme only (§8.2.1 #5).
- Charts kept: `#chart-kinds` (now in Targets), `#chart-why`, `#chart-fixedcosts`, `#verify-chart`, the `#cmp-band` svg, `.trend-svg` and `#mg-svg`; `#chart-wall`, `#chart-targets` and `#chart-hotspots` are replaced by `#cp-ribbon`, `#where` and the inline bars of their tables.
- The DOM ids and `data-total` / `data-shown` contracts of docs/SCHEMA-v0.4.md, v0.5 and v0.6 ("HTML views") are unchanged; the new slots are listed in §8.2.4. The report document gains one additive member, `previous` (docs/SCHEMA-v0.6.md "report: previous"), for the headline's delta clause.
- The template budget is lowered to **200 KB** (target about 150 KB); the 8 MB file cap is unchanged, so the data budget grows by 100 KB. Tests: `HTMLCockpitTests` and `HTMLTemplateTests.testProseBudget` (tier 2 and tier 1 above).

#### 8.2.6 What the HTML must not do (from XCLogParser)

- Render every task as a DOM row, or create one node per task. The timeline is one canvas and tables page at 200 rows ([TM] XLP#108: a 3-4 GB `build.js` crashed Chrome).
- Write more than one file, or split into shards or per-target pages (XLP#202/#220: 19,741-44,712 files).
- Inline per-file source, emitted compiler output, full command lines or raw note text. Diagnostics are deduped first lines with occurrence counts (XLP#117).
- Load from a CDN or the network (XLP#130: blank page without jQuery/Bootstrap). No web fonts, no analytics.
- Contain user names, absolute home paths, host names or the DerivedData hash when `--redact` is set. The Redactor runs on the document before embedding, and the template holds no environment data of its own.
- Insert log strings with `innerHTML` or build JS from them (XLP#142: an apostrophe in a computer name blanked the page).
- Show build-system steps as targets (XLP#220: 22,355 fake targets), or start every target at 0 (XLP#148). The page inherits §5.5 attribution and the clamped, reused-excluded intervals of §6.1.
- Print `0` for an unknown value, show a number the Validator withheld, or exceed the cap.

### 8.3 Other formats and history

- `markdown` / `github`: PR comment ≤ 64 KB with headline delta vs baseline, critical-path table, top 3 findings, collapsed details; `github` adds annotations for hotspots and errors/warnings (§5.10) and a step summary. Examples ship for GitHub Actions and Danger.
- `junit`: one testcase per budget (wall, incremental, per-target budgets in config); optional.
- `sarif`: code-level findings and compiler diagnostics.
- `chrome-trace`: Trace Event JSON for Perfetto/speedscope. It is the full-detail drill-down: the HTML report points to it when it truncates (§8.2.3). There are no HTML shards ([ET] §2, [TM] R9).
- `agent`: errors and warnings first (deduped, assembled), then ≤ 1,500 tokens: wall, kind, top 3 path segments, top 3 findings with IDs.
- **History entry** (`.xcblame/history/<time>-<kind>.json`): the report minus files/hotspots beyond the top 25, plus the **task index**: one compact row per executed task `[key, rule, target, kind, sigDigest, durationMs, onPath]` and, from `why` runs, module output hashes and input content hashes of executed tasks. AcmeApp clean: 577 rows, about 60 KB gzip-compressed (estimate). Retention: last 200 builds or 90 days (config). HTML reports written without `-o` go to `.xcblame/reports/` (git-ignored) and follow the same retention.

**v0.4 decision (2026-11-02).** Retention is the constants above (200 entries or 90 days, by file time) applied to `results/`, `logs/` and `reports/` (entries xcblame names itself, never a file someone put there) by `history prune`, `trend`, `build` and `analyze --format html`; `history prune --keep` and `--older-than` change `history/` only. History holds one entry per log (`input.path` basename): `History.save` returns the existing entry when the newest one is the same log, and `history prune` removes later duplicates, keeping the oldest. `.xcblame/.gitignore` ignores `history/ snapshots/ reports/ results/ logs/ cache/` and leaves `baseline.json` and `config.json` committable.

### 8.4 Exit codes

| Code | Meaning |
|---|---|
| 0 | Success (for `build`: xcodebuild's code is passed through by default) |
| 1 | xcblame internal error (analysis unavailable) |
| 2 | Usage error |
| 3 | `--fail-if-slower` threshold exceeded |
| 4 | `--fail-on <severity>` finding present |
| 5 | Log not found / not readable (candidates and hint listed) |
| 6 | `verify` aborted (dirty tree, thermal, timeout, broken baseline build) |

---

## 9. Differentiation

| Capability | xcblame | XCLogParser | Tuist Insights | BuildTimeAnalyzer | AvdLee skill | RocketSim Insights | Bazel (+rules_xcodeproj) |
|---|---|---|---|---|---|---|---|
| Works on current Xcode logs | Tolerant schema-table decoder, corpus 10-27, xcresult path | Breaks each minor; Swift classified "other" ([TM] R1/R2) | Yes (own pipeline, not verified) | Flag-dependent, "No valid logs" | Timing summary + flags | Durations only | n/a |
| Critical path | On the build system's own DAG (manifest), what-if by zeroing a target; inference fallback | No ([ET] §1.1) | No | No | No | No | Yes (build profile) |
| Honest per-file attribution | Granularity on every row; `--deep --exact-files` | Copies batch time to each file | Per-file (granularity not stated) | Function times only | Heuristic | No | Per action |
| Why it rebuilt | One primary cause per task, partitioned; backtraces, script I/O, signatures, module hashes, mtime churn | No | No | No | Zero-change check, point in time | No | Action cache keys |
| Fixes | ~100 catalogued rules, overlay, A/B verify through the delivery mechanism, auto-revert on slower/broken | No | No | No | LLM plan + apply after approval | No | n/a |
| Static audit without building | `doctor`, seconds | No | No | No | Yes (prompted) | No | n/a |
| CI gate + PR comment, no backend | Yes | Library only | Account/server | No | No | Team dashboard | Yes (heavy infra) |
| History / trend | Local files with task index | No | Hosted | No | Point in time | Hosted | Remote |
| Install / infra | One signed binary | Homebrew, lagging releases | CLI + server | macOS app | Python + LLM agent | Commercial app | Full migration |
| Determinism | Same input, same output | Yes | n/a | Yes | No (LLM) | n/a | Yes |

Sources: [ET] §3, §4; [TM] §1, §3.

---

## 10. Risks and open questions

### 10.1 Must-verify list

| ID | Question | Why it matters | How to verify | Blocks |
|---|---|---|---|---|
| MV-1 | Do IDE builds leave a result bundle readable with `xcresulttool get log --type build`? [OBS-1] | If yes, an Apple-supported reader for IDE builds too. | Build AcmeApp in Xcode.app 26.0.1 and 27.1; `find DerivedData -name '*.xcresult'`. | v0.1 reader priority |
| MV-2 | How to enable Task Backtraces without the GUI (scheme attribute? user default?), whether a temporary scheme copy works, and whether frames appear in SLF and xcresult. None in any AcmeApp log [OBS-3]. | Core evidence for `why`. | Toggle the option in a scheme, diff `.xcscheme` and `defaults`; build with a copied scheme; grep attachments. | v0.5 |
| MV-3 | Precedence of `-xcconfig`, `XCODE_XCCONFIG_FILE`, `KEY=VALUE` vs target-level pbxproj values with and without `$(inherited)`; does a command-line `$(inherited)` keep project `OTHER_SWIFT_FLAGS`? | CLI delivery and `--deep` correctness. | Precedence fixture; compare `-showBuildSettings -json`. | v0.5/v0.6. **Resolved (2026-11-05)** by [research/probes-v0.6.md](research/probes-v0.6.md) Q1-Q4, Q9 (26.0.1 and 27.1 beta): `KEY=VALUE` < `-xcconfig` < `XCODE_XCCONFIG_FILE`, all above target settings with or without `$(inherited)`; a command-line `$(inherited)` keeps the lower chain; command-line settings reach package targets. |
| MV-4 | Xcode 27.2 `project.xcproj` schema, conditional keys, xcodebuild support, Apple's package. | ProjectModel backend. | Create/convert in 27.2; Apple docs. | v0.3 read, v0.7 edit |
| MV-5 | SLF v12 and pre-11 layouts; string-length unit with non-ASCII paths; meaning of the v13 ints. | Corpus breadth (R1). | Fixtures on Xcode 10-27 via `xcodes`, unicode paths, a failing task. | v0.1, v0.8 |
| MV-6 | `-stats-output-dir` key format on 26/27. | `--deep` timers. | Inspect a real file. | v0.5 |
| MV-7 | `-ftime-trace` with explicit modules and caching. | Clang hotspots. | Mixed fixture. | v0.5 |
| MV-8 | `-driver-show-incremental` remarks visible in 26/27 logs? | `why` evidence. | Fixture. | v0.5 |
| MV-9 | `[config=...]` conditions and `#include?` in classic xcconfigs per version. | Overlay syntax. | Fixture. | v0.6. **Resolved (2026-11-05)** by probes-v0.6.md Q5-Q7: `#include?` is silent when missing and resolves against the including file's folder first, then the project folder (`PROJECT_DIR` vs `SRCROOT` not separated: same folder in the fixture); `[sdk=…]` conditions honoured and stackable; last assignment wins. Still open: the effect of the `defaults` keys (Q8, not probed). |
| MV-10 | Timing-aggregate sections in IDE-produced logs? | V5 availability. | IDE build. | v0.1 |
| MV-11 | Xcode Cloud log locations and post-action environment ([TM] TU#7543). | FR-48. | Workflow with `ci_scripts`. | v0.8 |
| MV-12 | `BuildOperationMetrics` 26.4+ key names for cache hits. | Cached kind. | Caching on. | v0.5 |
| MV-13 | ld_prime `-print_statistics`, `-why_load`, `-map`. | Link depth. | Probe. | later |
| MV-14 | `-onlyUsePackageVersionsFromResolvedFile` spelling and effect ([OC] E2). The `-clonedSourcePackagesDirPath` half is closed: the [RL] runs used it on 26.0.1 and 27.1. | DEP-002/CI-002 text. | `xcodebuild -help`. | v0.4 |
| MV-15 | IDE-produced log layout: manifest `className`, top-level class, presence of the command-line-only trailing int, task depth. Our corpus is xcodebuild-only [RL]. | Selection (§5.2) and decoding (§5.4) of the most common input. | **Task: build AcmeApp in Xcode.app 26.0.1 and 27.1 (clean, incremental, zero-change) and add the logs to the corpus.** | v0.1 exit |
| MV-16 | Does plain `xcodebuild build` without `-resultBundlePath` write an `.xcactivitylog`? README vs forum conflict ([DS] §1.1). | CI `analyze` without the wrapper. | Run both on 26 and 27. | v0.1 |
| MV-17 | Previews and index builds: DerivedData arena paths, build-request fields, whether they write activity logs at all. | §6.7 kinds. | Open a preview; watch DerivedData. | v0.5 |
| MV-18 | Build description reuse: does every build that re-plans write a new `<sig>.xcbuilddata`, and do old ones stay? Do 27.x and older Xcodes (≤ 15) write `manifest.json` in the same shape? | §5.11 matching and DAG availability. | Sequence of builds with setting changes on 15, 16, 26, 27. | v0.2 |

### 10.2 Evidence conflicts and the conservative behavior chosen

| Topic | Conflict | Rule behavior |
|---|---|---|
| Explicit modules | Xcode 16 betas: clean builds 1.7-43 % slower (Bitrise); Apple: default since 26, required for caching ([OC] A13; [BP] §2.6) | Never recommend disabling on 26+; 16-25 recommend-only with verify gate. |
| `DEAD_CODE_STRIPPING` in Debug | zld README vs WWDC22 ([OC] A25) | Recommend-only, verify-gated. |
| Compilation caching gains | -40 % to +77 %; SPM deps not cacheable in 26 beta ([OC] A16; [BP] §5.1) | Band `?` until measured, verify-gated, scope note for packages. |
| WMO in Debug | Conflicting guides ([PP] E9) | Debug WMO flagged; never recommended. |
| SLF string length | UTF-16 (old doc) vs UTF-8 bytes (2026 code) | Bytes; corpus test with non-ASCII. |
| `SWIFT_USE_INTEGRATED_DRIVER=NO` | AutoScout24 Xcode 14 gain vs required YES for caching, reportedly gone in 26.5 | Never recommend `NO`. |
| Strict concurrency cost | No measurement ([BP] §2.8) | Measure-only. |
| `-xcconfig` precedence | Documented top precedence vs [DS] §6.3 caveat | Oracle check on every CLI delivery (§7.5). |

### 10.3 Product risks

- Apple ships a first-party "why" (backtraces UI, SwiftPM trace events, [ET] §1.9). Mitigation: ingest them; our value is the joined analysis plus fixes plus CI.
- Format drift on every Xcode minor, now for the log and the build-description files. Mitigation: R18 process, table-driven decoders, inference fallback, 72 h drift-fix SLA.
- Wrong advice erodes trust. Mitigation: computed confidence, [K] rules "needs measurement", verify with validity checks and auto-revert, sources in `rules explain`.
- The DAG ignores resource limits (unlimited cores), so what-if savings are optimistic for CPU-bound stretches. Mitigation: label "if X took no time", show utilization next to it.

---

## 11. Roadmap (v0.1 → v1.0)

Scope boundary for v1: no remote cache, no IDE plugin, no hosted dashboard, no project generation, no source auto-edits (except optional `final` in v1.x), no indexing analysis, no hosted or server-rendered report (the HTML report is one static, size-capped file, §8.2; full detail via chrome-trace), no machine-benchmark reference database (env + trend by machine instead; benchmark numbers are not comparable across Xcode versions, [PP] §C).

| Milestone | Scope | Exit criteria | Closes |
|---|---|---|---|
| v0.1 Read | Gzip + SLF tokenizer/decoder (v11, v13, command-line and IDE layouts), XCResultReader, BuildModel common subset, KindTable v1, Diagnostics, Locator (class/domain/content selection, integrity), Xcode version inference, Validator V1, V2, V5-V8, V10, V13, V14; `analyze` text/json (timing, rollups), `selftest`. | Corpus: AcmeApp 26.0.1/27.1 xcodebuild logs **and IDE-produced logs (MV-15 task)** decode with 0 errors; per-rule sums pass V5 (counts may warn); 0 NaN/negatives; 12 MB log < 1 s, RSS < 100 MB; readers agree on the common subset (§5.7). | R1 (partial), R2, R3, R4, R8 (partial), R14, R15, R17 |
| v0.2 Explain | Timeline normalization (reused tasks), build-description snapshot + TaskDAG, critical path (DAG + inference), what-if, utilization, batch-aware attribution, hotspots from existing text, build kinds, Env, `build` wrapper, history with task index; V3, V4, V9, V11, V12. Redactor and the report budget/truncation pass (later shared by markdown/agent). **First HTML report** (§8.2; `--format html`, `build --html`, `--open`, `-o`): header, critical path timeline with utilization strip, targets, files, hotspots, findings & fix plan (populated from v0.3), environment & validation; `make template` embedding; tier 1 + 2 tests of §8.2.5, tier 3 nightly. | AcmeApp incremental: 39 reused tasks excluded, span 1.6 s; DAG path on AcmeApp clean reproduces the §3.3 path within 0.2 s per segment; DAG/inference agree on 3 fixtures or the difference is explained; `build` never changes xcodebuild's exit code. HTML for AcmeApp clean ≤ 1 MB, opens offline (headless Chrome with network blocked, no JS errors), and every section's `data-total` equals the JSON `*Total`. 50k-task synthetic: ≤ 8 MB with the truncation banner and unchanged Totals; first paint < 1 s in Chrome and Safari. | R3, R4, R5, R6 (partial), R7, R9, R12 (partial), R13 (partial), R17; [PP] W1, W3 |
| v0.3 Doctor | ProjectModel, SettingsOracle, schemes, SPM/Pods/Carthage, generator detection, xcproj read (after MV-4); static rules with concrete predicates (Tier-1 SET, PHASE-001-005, DEP-001-003/008/012, ENV-*). `doctor`, `rules explain`; `doctor --format html` (project header, findings & fix plan with `ruleDocs`, PASS/N/A, environment). | `doctor` < 5 s on a 200-target fixture; zero writes; on 5 OSS projects, a written audit checklist (every predicate in RULES.md evaluated by hand from `-showBuildSettings` and the project file, recorded as expected.json) matches `doctor` output exactly; provenance correct on the precedence fixture. | R11 (read); [PP] A6, A12, W4 |
| v0.4 CI | JSON schema v1, `markdown`/`github`/`junit`/`agent`, `--redact` defaults and budgets for those formats (Redactor and budget pass from v0.2), `baseline`, `compare`, `--fail-if-slower`, `trend` (incl. `--by commit`), HTML compare and trend views (§8.2.4 #11, #12), retention, `.xcblame/.gitignore`, GitHub Action + Danger examples, Homebrew tap, signed/notarized binary from CI. | Example workflow green on GitHub-hosted macOS (uploads the HTML report as an artifact); PR comment ≤ 64 KB on a 500-target synthetic log; compare HTML of two AcmeApp builds shows environment differences first and the noise band; automated release. | R9, R10, R12, R13; [PP] A9, W8, W9 |
| v0.5 Deep and Why | `--deep` (probe, deep DerivedData in cache dir, wrapper xcconfig), `--exact-files`, `why` (settle/zero-change/touch, temporary-scheme backtraces if MV-2 allows, hashes), cause attribution with V15, fixed costs, module graph + variants from reports, cached kind; HTML why, fixed-cost and module-graph views (§8.2.4 #7-#9). | On fixtures with planted causes (script without outputs, touched file, macro plugins, flag change), the planted cause is the primary cause of ≥ 90 % of executed task time and V15 holds; unknown share always reported (also in the HTML why view). | R6, R16; [PP] A1-A4, A16 |
| v0.6 Fix (integrated 2026-11-05; e2e verify and review pending) | Rule engine with signal dedupe; `fix` plan; overlay writer; hook installer (xcconfig append); CLI wrapper delivery with oracle check; `--apply-defaults`; `verify` (mechanism, per-arm DerivedData, validity checks, 5 runs, auto-revert); HTML verify view (§8.2.4 #13). | On 3 fixtures with planted bad settings, `verify` + `fix --apply` keep the planted fixes, revert a planted no-op and a planted build breaker; revert restores byte-identical files. | [PP] W4, W7, W11; [ET] gap 7 |
| v0.7 Edit | `--edit-project` for pbxproj (then xcproj), scheme edits, Package.swift URL fix, pbxproj hook, all RULES.md rows wired. | Round-trip no-op diff empty on 50 OSS projects; every edit verified by the oracle; zero-diff revert. | R11 (write) |
| v0.8 Breadth | Corpus Xcode 10-27 + current beta, fuzzing, 10 GB log performance, unicode paths, Xcode Cloud (MV-11), `swift build --build-system swiftbuild` output, SARIF, chrome-trace. | ≥ 60 logs across 12+ Xcode versions pass; 1 GB inflated log < 30 s and < 300 MB RSS; 24 h fuzzing without crash. | R1, R8, R16, R18 (process) |
| v1.0 | Schema freeze, docs, beta-day-1 corpus job, 72 h drift SLA, `mint`/SPM plugin, deprecation policy. | Two consecutive Xcode betas handled within SLA; no open P0; every rule documented with sources. | R18 |

**v0.5 decision (2026-11-03), the "≥ 90 % of executed task time" criterion.** On the AcmeWhy fixture Xcode's own per-build work outweighs the planted work: planning (build description, dependency graph, SDK stat cache: about 0.3 s, tasks of target `build system` or kind `planning`), the Info.plist and Swift-library copies (`ProcessInfoPlistFile`, `CopySwiftLibs`, `RegisterExecutionPolicyException`) every build repeats, and, in the other scenarios, the always-running script planted for the zero-change one. A planted cause therefore holds only 2-40 % of the whole build's executed task time. The criterion is measured on the executed task time **without** that per-build work: there the planted cause must hold ≥ 90 % (`WhyE2ETests`). That work runs on every build and is reported under its own causes (and in fixed costs), so leaving it out of the ratio hides no unexplained second.

**v0.2 decisions (2026-11-01)**, recorded in place: §3.2 (`XCBLAME_XCODEBUILD` test hook; `build --format json` needs `-o`), §5.11 (snapshot layout, snapshot pruning, locator fallback), §6.2 (`whatIf` for `dag` and `mixed`; DAG vs mock LocalizeCore row), §6.3 (serial threshold without a core count), §8.2.3 (`topTasks` trimmed first; extra step-5 lists), §8.2.5 (pretty JSON blob plus a compact `taskIndex` line; `<!--` escape). The schema contract is `docs/SCHEMA-v0.2.md`.

**v0.3 decisions (2026-11-01)**, recorded in place: §3.4 (pbxproj values shadow the overlay → `--edit-project`), §7.1 (`RuleSpec.severity`; catalog as Swift literals), §7.4 (scratch workspace + `sandbox-exec`, 20 s per configuration, DerivedData checkouts, SET-005 on resolved values, MV-3 result). The schema contract is `docs/SCHEMA-v0.3.md`.

**v0.4 decisions (2026-11-01)**, recorded in `docs/SCHEMA-v0.4.md`: noise model constants (§6.10), `diagnostics` and build context members in the report (§8.1), `github` annotations on stderr and the step summary (§8.3), `junit` budgets from `.xcblame/config.json`, exit code 3 precedence (§8.4), HTML compare and trend DOM contracts (§8.2.4 #11, #12). Integration decisions (2026-11-02) are recorded in place: §3.2 (`build` syntax, `compare` formats), §6.10 (indicative wording, `wallBasis`), §8.2.4 (shared table helpers, `#cmp-path-span`), §8.3 (retention, dedupe); the list is in `docs/SCHEMA-v0.4.md` "Integration notes".

**v0.5 decisions (2026-11-02)**, recorded in `docs/SCHEMA-v0.5.md` "Decisions taken in phase 1": the `incremental`, `fixedCosts`, `moduleGraph`, `deep` and `build.cache` members (§8.1), the deep DerivedData at `<cache>/deep/<sha16(container)>/` instead of `dd-deep/` (§5.8), `tmp/` for the wrapper xcconfig (§7.5), history rows with optional output and input hashes (§8.3), `why` exit codes (§8.4), and the #7-#9 DOM contracts (§8.2.4).

---

## 12. Test strategy

1. **Golden corpus** (`Tests/Corpus/<xcode>/<fixture>/<kind>/`): `build.xcactivitylog`, `manifest.plist`, optional `xcresult-log.json` (+ `--schema`), `stdout.txt`, the build-description snapshot (§5.11), `expected.json`, `meta.json` (machine, Xcode build, command, **producer: xcodebuild or IDE**). Seeds: AcmeApp 26.0.1/27.1 [RL] plus the IDE builds of MV-15. New Xcode releases and betas get fixtures on day 1 from a scheduled job (`xcodes`); donated logs redacted and checked in. Every parser change runs the whole corpus forward and backward ([TM] XLP#209/#211).
2. **Fixture projects** (generated in-repo, [TM] XcodeBenchmark#521): tiny SwiftUI app; 30-module SPM graph with an umbrella module; ObjC+Swift with bridging and prefix headers; CocoaPods project; script phases with and without outputs, an upload script; macro package (2 plugins on one module); synchronized folders (objectVersion 77) and objectVersion 90 shellScript arrays; Xcode 27.2 `project.xcproj`; settings at every precedence level; paths with spaces, apostrophes, unicode and `:`; a failing task (v13 int semantics); a 10k-file synthetic generator.
3. **Parser property tests**: generated token streams round-trip; truncation at every byte offset never crashes and yields `degraded: truncated`; inserted unknown classes/attachments give the same model plus warnings; field-drift mutations are detected or flagged by invariants; JSON attachment fields removed or retyped.
4. **Validator tests**: each invariant V1-V15 has a failing synthetic case.
5. **Analyzer tests**: hand-computed critical paths, what-if and utilization on small synthetic DAGs; DAG vs inference on the corpus; the AcmeApp stale-section case; cause partition (V15) on planted fixtures; batch vs exact attribution.
6. **Project model tests**: round-trip no-op on 50 OSS projects; oracle agreement on the precedence fixture; generator detection; the audit checklist of v0.3.
7. **Fix and verify tests**: deterministic fake `Runner` (scripted durations, noise, failures, task-set changes) to test verdicts and auto-revert; nightly end-to-end on fixtures; revert byte-identical.
8. **Performance gates**: 12 MB log < 1 s; 1 GB inflated synthetic < 30 s, < 300 MB RSS; scaling ≤ 2.3x per input doubling ([TM] PR#263).
9. **Output tests**: JSON validated against `xcblame schema`; every capped array has Total/ShownShare; no `0` where a `null` + note is required; markdown budget; redaction removes every home/user/host string; HTML tiers 1-3 of §8.2.5 (parity with JSON, escaping, no network, size cap, headless DOM counts, WebKit first paint).

---

## Appendix A. Observations from the [RL] artifacts (2026-10-30)

Read-only analysis of `build26*.log`, `slf26/27`, `r26-xcresult-buildlog.json`, `dd26/`.

| ID | Observation | Consequence |
|---|---|---|
| OBS-1 | `dd26/Logs/Build/` contains three `.xcactivitylog` files and `LogStoreManifest.plist`; no `.xcresult`. The bundle exists only at the `-resultBundlePath` given. | SLF parser required for DerivedData-based `analyze`; MV-1. |
| OBS-2 | Xcode 26 incremental log `D822889B`: 59 build-log sections, 39 start before `timeStartedRecording` (reused from the clean build, e.g. "Compile FilePreview.swift (arm64)" 3.64 s); naive span 20.0 s vs recorded 1.6 s. The 20 fresh sections match the stdout timing summary. | §6.1. |
| OBS-3 | Attachment identifiers in all 10 SLF files: only `TaskMetrics`; no `TaskBacktrace`, no `BuildOperationMetrics`. | §5.1, MV-2, MV-12. |
| OBS-4 | xcresult JSON (26): explicit-module tasks (`SwiftExplicitDependencyGeneratePcm`, `PrecompileModule`, `ScanDependencies`) carry no `(in target ...)` suffix. 143 PCM tasks cover 64 modules: 17 built 3 times, 45 twice, 2 once; 79 tasks are redundant variants (7.59 s task time). `swiftmodulesreport/Summary.csv` gives the same counts. | §5.5, §6.9, SET-024. |
| OBS-5 | Target suffix forms: `(in target 'SwiftSyntax' from project 'swift-syntax')` and `(in target 'LocalizeCore' from project 'AcmeApp' at path '/…/Package.swift')`. | §5.5. |
| OBS-6 | Concurrency (577 tasks, clean): peak 29 lanes; ≤ 2 lanes for 7.51 s, ≤ 3 lanes for 9.47 s of 18.14 s; idle 0.07 s; busy 18.07 s; task time 139.84 s. Task time by bucket: LocalizeCore 54.67, SwiftSyntax 39.82, AcmeApp 13.87, explicit modules 13.22, SwiftParser 10.46, build system (planning + ClangStatCache) 3.69, 6 version-marker/shim targets 4.11 s. | §3.3, §6.3. |
| OBS-7 | Planning tasks: `CreateBuildDescription` 0.43-1.83 s, `SendProjectDescription` 0.29 s, `ComputeTargetDependencyGraph` 0.07 s. | Fixed cost "planning". |
| OBS-8 | Class references 1-based; int/length payloads decimal, doubles hex (`tools/slftok.py`, 0 errors). | §5.3. |
| OBS-9 | Host: `Mac15,14`, 28 logical CPUs, 96 GB. | Mock env line. |
| OBS-10 | 579 depth-2 sections; 2 have no `commandDetails` (`Prepare packages`, `Build Timing Summary`), leaving 577 tasks. All 466 TaskMetrics sit on depth-2 sections; none of the 153 depth-3 per-file children has one. SwiftCompile structural sum 109.28 s vs summary 109.343 s; WriteAuxiliaryFile 85 tasks/0.470 s vs summary 84/0.278 s. | §5.5, V5 tolerance. |
| OBS-11 | AcmeApp project: XcodeGen (`project.yml`), objectVersion 77, no `.xcconfig`, Debug `dwarf`/`-Onone`/`ONLY_ACTIVE_ARCH=YES`, Release `wholemodule`/`-O`/`dwarf-with-dsym`, `SWIFT_VERSION = 5.0`, scheme `parallelizeBuildables="YES"`; `LocalizeCore` depends on `SwiftSyntax` and `SwiftParser` (library use). | §3.4, DEP-012. |
| OBS-12 | `dd26/Build/Intermediates.noindex/XCBuildData/6f0b463d2f2edd5a58b553713dc8313d.xcbuilddata/` with `manifest.json` (keys `client, targets, nodes, commands`; 747 commands), `target-graph.txt` (13 targets), `build-request.json`, `description.msgpack`, `task-store.msgpack`, `attachments/`; siblings `build.db`, `PIFCache/`, `clangmodulesreport/`, `swiftmodulesreport/`. The clean log's CreateBuildDescription text contains "Build description signature: 6f0b463d…" and the path; the incremental log does not. The task `xcbuildSignature` slots decode (hex → UTF-8) to `\x00P0:…`/`\x00P2:…` keys (471) and other prefixes; 212 equal manifest command keys after stripping the prefix byte; unmatched: SwiftCompile 87, PCM 143, PrecompileModule 12, SwiftDriver 9, SwiftEmitModule 9 (dynamic tasks). | §5.6, §5.11, §6.2. |
| OBS-13 | TaskMetrics: 466 records; 188 have `maxRSS = 0` and `utime = stime = wcDuration` (placeholders, e.g. `CreateBuildDirectory`); 278 real records sum to 123.32 s CPU; 111 executed tasks have no TaskMetrics (2.12 s; planning, `SwiftDriverJobDiscovery`). | §5.5, §5.6, §6.3. |
| OBS-14 | Timing-fallback critical path of the clean build: planning 0-1.83, `ClangStatCache` 1.88-3.68, swift-syntax markers + early PCMs 3.68-4.81, SwiftSyntax emit-module 4.81-7.52, SwiftParser 7.53-8.34, LocalizeCore planning 8.32-8.85, 26 PCM tasks 8.88-11.18 (Darwin … AppKit), LocalizeCore `Models.swift` 11.18-14.23, PCMs 14.20-15.25 (Foundation … SwiftUI), AcmeApp `StudioView.swift` 15.25-17.64, link/register/module reports 17.64-18.14. The 6.65 s SwiftSyntax batch (4.82-11.46) is off the path. LocalizeCore ran 18 single-file frontends, AcmeApp 8. | §3.3; corrects v1 of this doc, which put swift-syntax at 9.3 s on the path and explicit modules at 0 s. |
| OBS-15 | `build-request.json`: `action: build`, `configurationName: Debug`, `enableIndexBuildArena: false`, `generatePrecompiledModulesReport: true`, run destination (`macosx26.0`, arm64), and `overrides.commandLine.table` with the command-line settings (`CODE_SIGNING_ALLOWED`, `OTHER_SWIFT_FLAGS`). Module report `Darwin.csv` variants differ in `-fapinotes-swift-version=6` vs `=5`, `-Xcc -D SWIFT_PACKAGE`, `__swift__=60200` vs `51000`. The `Cleaning project …` log has the same `className` (`IDECommandLineBuildLog`) and domain as build logs and contains only planning tasks. | §5.2, §5.11, §6.7, §6.9, SET-024. |
| OBS-16 | The clean log names `MacOSX26.0.sdk` in commands and `macosx26.0-25A352` in the SDK stat-cache path; tool paths are `/Applications/Xcode.app/...`; no swift version text was found in task output. | §5.9: Xcode inferred as 26.0, not 26.0.1. |

---

## Appendix B. Review resolution ([REVIEW-2026-10-30.md](REVIEW-2026-10-30.md))

| # | Resolution |
|---|---|
| 1 | Selection by manifest className/domainType plus a content check (first executed non-planning, non-clean task); titles never used (§5.2). IDE layout added as `ide` row family (§5.3, §5.4) and MV-15 with the task "build AcmeApp in Xcode.app 26.0.1/27.1"; IDE fixtures are a v0.1 exit criterion (§11, §12.1). |
| 2 | RULES §0 legend rewritten: shadowed keys go to cli / `--edit-project` / recommend, never an automatic pbxproj edit (RULES §0, DESIGN §7.5). |
| 3 | Executed task defined structurally (task-depth section with a rule name; TaskMetrics only enrich) (§5.5); mock numbers recomputed from r26 under that definition: 577 tasks, 139.84 s, busy 18.07, CPU 123.3 s (§3.3, OBS-10, OBS-13). |
| 4 | The structural rule works without attachments, covering SLF < 11 / Xcode ≤ 15.2 (§5.5). |
| 5 | Common BuildModel subset table; SLF-only fields optional; `xcbuildSignature` described as a string slot, not an attachment; reader agreement defined on the subset; cross-build identity from the SLF key or manifest key (§5.6, §5.7, §11 v0.1, REQUIREMENTS FR-11). |
| 6 | Critical path rewritten around the manifest DAG with dynamic-task attachment and a consistency check; inference is the labelled fallback; `xcblame build` snapshots manifest, target graph, build request and the modules-report CSVs into `.xcblame/snapshots/` (§5.11, §6.2, OBS-12, MV-18, REQUIREMENTS FR-23/FR-49). |
| 7 | What-if = DAG longest path with the target's durations set to 0; under inference only the path-share bound is shown (§6.2). |
| 8 | V5 tolerance max(0.25 s, 2 %); count mismatches warn; the mock shows "13 pass, 1 warn" (§6.11, §3.3). |
| 9 | CI fallback for shadowed keys is conditional on MV-3 and checked by running the oracle with the actual wrapper xcconfig (§7.5; RULES §10). |
| 10 | Verify measures through the delivery mechanism of the final fix (`--mechanism hook|cli`); the plan shows per-target scope per mechanism; `fix --apply` refuses a different mechanism unless the oracle shows identical scope (§7.5, §7.8). |
| 11 | DEP-012 remedy reordered (leaf isolation, binary target; caching only for project targets, SPM caching unverified); SET-016 scope note; doctor mock rewritten (RULES DEP-012/SET-016, §3.3, §3.4). |
| 12 | Verify requires exit 0 on all runs and matching target set and task-kind multiset; otherwise "broke build"/"task set changed" revert (§7.8 step 5). |
| 13 | Separate DerivedData per arm with a settle build for non-clean kinds; ABAB only for clean (§7.8 step 3). |
| 14 | History stores a compact per-build task index (key, rule, target, kind, signature digest, duration, on-path) plus hashes from `why` runs; without a previous index, comparison-based causes are `unknown` (§6.6, §8.3). |
| 15 | Exactly one primary cause per task (precedence list), two separate rankings (task time, path seconds), partition invariant V15 (§6.6, §6.11). |
| 16 | Titles only annotate `other` rows and never change numbers (§4.3 rule 7, §5.5); previews/index from build request and DerivedData arena paths, MV-17 (§6.7). |
| 17 | JSON example fixed: `incremental: null` with note for a clean build, `cpu: 123.32` with `cpuTasks`, Totals/ShownShare on capped arrays, nulls with notes; the text mock prints span, busy, task time and CPU (§8.1, §3.3). |
| 18 | Xcode version inferred from SDK/stat-cache names and tool output, marked `inferred`, never taken from current `xcode-select`; trend/regression group by it (§5.9, §3.3, §6.10, OBS-16). |
| 19 | Cached builds detected from build-level counters only; per-task replay is a labelled heuristic (§5.6, §6.7, REQUIREMENTS FR-32). |
| 20 | New §5.10 diagnostics decoding (severity field, location, multi-line assembly, dedupe, linkage); FR-19 now maps to it. |
| 21 | Threshold defined as lanes ≤ max(1, floor(10 % of cores)) = 2 on 28 cores → 7.5 s, used consistently (§6.3, §3.3, §8.1, RULES DYN-001, OBS-6). |
| 22 | Variant numbers corrected (143 PCM tasks, 64 modules, 17×3 / 45×2 / 2×1, 79 redundant, 7.6 s); impact counts only the avoidable part and the variant causes (language mode, `SWIFT_PACKAGE`); LocalizeCore 18 frontends (OBS-4, OBS-14, §3.3, RULES SET-024). |
| 23 | Confidence table made unambiguous (§7.1, RULES §0); doctor shows no `high`; SET-024 measured + [P] shows `high` (§3.3, §3.4). |
| 24 | Doctor PLAN now runs `verify` first; `fix --apply` writes only kept rules (§3.4). |
| 25 | Any [K] part (incl. `[S/K]`) gates as [K]: low confidence, `+V` only; SET-011 and SET-029 now `+V` (RULES §0, rows). |
| 26 | Concrete predicates added for SET-017, SET-020, SET-025, DEP-009, DEP-010, ENV-004, GRAPH-010; rules without a detectable signal moved to category `info` (docs-only) (RULES). |
| 27 | Engine dedupe by `signalKey` (§7.1, RULES §10); legend amended: new rules about a catalog category extend it above the catalog's highest number (DEP-012), measurement-only rules use DYN (RULES §0). |
| 28 | Complexity stated correctly: DAG O(V + E); inference O(n log n + p·K) with a bounded candidate window (§6.2). |
| 29 | Default `--runs 5`; settle run excluded for non-clean kinds leaves ≥ 4 samples; < 4 samples is `indicative` and never auto-kept (§3.2, §7.8). |
| 30 | `why --backtraces` uses a temporary scheme copy that is deleted afterwards; the user's scheme is never edited; feasibility in MV-2 (§6.6, §3.2). |
| 31 | Command-line delivery writes a wrapper xcconfig that includes the user's `-xcconfig` and `XCODE_XCCONFIG_FILE` file, then the overlay, then `--deep` lines (§7.5, §5.8). |
| 32 | Deep DerivedData moved to `~/Library/Caches/xcblame/dd-deep/` (or `$TMPDIR`); `.xcblame/.gitignore` written on first run with the committed/local split (§5.8, §4.3 rule 2). |
| 33 | `defaults` writes gated by `fix --apply-defaults`; `--apply` writes overlay lines only (§7.3, REQUIREMENTS FR-35). |
| 34 | `-clonedSourcePackagesDirPath` marked confirmed (used in the [RL] runs); MV-14 narrowed to `-onlyUsePackageVersionsFromResolvedFile` (§10.1, RULES CI-002/DEP-002). |
| 35 | MV-16 added for plain `xcodebuild build` without `-resultBundlePath`; error hint points to `xcblame build` (§5.2, §10.1). |
| 36 | TaskMetrics placeholder records (maxRSS 0, utime = stime = wcDuration) treated as "no CPU data" (§5.6, §6.3, OBS-13). |
| 37 | W5: benchmark reference database declared out of scope with reason (§11), env + `trend --by machine` kept; W6: `--explain` and `glossary` added (§3.1, §3.2); W8: `trend --by commit` (§3.2); A10: previews classified, deeper Previews analysis out of scope (§6.7, §11); A14: indexing analysis out of scope (§6.7, §11); A15: free disk space captured (§5.9); R9: size budgets with Totals, chrome-trace is the full-detail drill-down, HTML shards out of scope (§8.3); the earlier "no HTML report" scope line is superseded by row 39; FR-48 mapped to v0.8 + MV-11 (REQUIREMENTS). |
| 38 | V3, V4 (and V9, V11, V12) moved to v0.2; v0.3 "hand audit" replaced by a written predicate checklist with expected.json (§11, §12.6). |
| 39 | User decision 2026-10-31 (not a review finding; recorded here because it reverses part of row 37): HTML report in, with size discipline. Details: one self-contained file; zero network; plain embedded JSON equal to `--format json` plus `taskIndex`; 8 MB cap with ordered truncation and floors; Totals computed before truncation; a banner listing every step; chrome-trace as the full-detail escape hatch; first version in v0.2, other views with their engines (§3.1, §3.2, §8.2, §11; REQUIREMENTS FR-53-FR-59, NFR-15, NFR-16). |

All 38 review findings resolved; none rejected. Row 39 records a later user decision.
