# xcblame: requirements

Status: draft v2.1, 2026-10-31 (review fixes per [DESIGN.md](DESIGN.md) Appendix B; v2.1 adds the HTML report, FR-53-FR-59, NFR-15, NFR-16, per the user decision of 2026-10-31, DESIGN Appendix B row 39). Each requirement has a source (research file and, where useful, the primary URL) and the DESIGN section that satisfies it. "MUST" requirements gate v1.0; "SHOULD" may slip to v1.x; "OUT" marks an explicit v1 scope exclusion. Citation keys as in DESIGN: [BP] build-pipeline, [ET] existing-tools, [OC] optimizations-catalog, [DS] data-sources, [PP] dev-painpoints (A1-A16 ranked pain points, W1-W11 wish-list rows in order, E1-E13 misconceptions), [TM] tool-mistakes (R1-R18), [RL] real-log-inventory, [OBS-n] DESIGN Appendix A, [REV-n] review finding n.

## 1. Functional requirements

### 1.1 Measure

| ID | Requirement | Source | Design |
|---|---|---|---|
| FR-01 | MUST wrap `xcodebuild` (`xcblame build -- <args>`), stream its output unchanged, inject `-resultBundlePath` and `-showBuildTimingSummary` when absent, and measure process wall time. | [TM] XLP#139/#146, XCM#45, R7 | §3.2, §4.1 Runner |
| FR-02 | MUST return xcodebuild's exit code by default and never fail or block the build because of analysis; analysis failure yields a warning and a `degraded` partial report. | [TM] R17, TU#11168, XCM#37 | §4.3 rule 1, §8.4 |
| FR-03 | MUST analyze an existing build from an `.xcactivitylog`, an `.xcresult`, a DerivedData folder, or the latest build of the project in the current directory; when no log exists after a plain `xcodebuild build`, MUST point to `xcblame build`. | [PP] W3; [TM] XCP#22; [DS] §1.1 conflict; [REV-35] | §3.2, §5.2, MV-16 |
| FR-04 | MUST locate logs via explicit path, `-derivedDataPath`, per-workspace settings, `IDECustomDerivedDataLocation`, default, matching by `info.plist` `WorkspacePath`; on failure list every directory searched and every candidate. | [TM] XLP#214, BTA#30, R7; [DS] §1.1 | §5.2 |
| FR-05 | MUST wait for log completeness (size stable, gzip CRC/ISIZE valid) with a timeout, and salvage truncated logs as partial, flagged builds. | [TM] XLP#139, XCP#34/#29, TU#11168 | §5.2 |
| FR-06 | MUST select logs by manifest `domainType` and `className` plus a content check (contains an executed non-planning, non-clean task), never by title; ordered by manifest start time; `--list`/`--index` with scheme, status, kind. | [DS] §1.2; [OBS-15]; [TM] XCP#22; [REV-1] | §5.2 |
| FR-07 | MUST capture environment: Xcode version (from the invocation in `build` mode; inferred from SDK/tool evidence in the log for `analyze`, marked `inferred`), macOS, model, cores (P/E), RAM, Rosetta, thermal before/after (wrapped builds), DerivedData location/size/volume/free space/symlink/Time Machine/`.noindex`, Xcode defaults, CI provider; git branch/sha/commit time opt-in. | [PP] A5, A15, W5; [OC] F1-F6; [DS] §1.4, §8; [REV-18], [REV-37] | §5.9 |
| FR-08 | MUST provide `--deep`: inject `-debug-time-function-bodies`, `-debug-time-expression-type-checking`, `-stats-output-dir`, clang `-ftime-trace` through the command-line wrapper xcconfig (never by editing the project), probe the toolchain, verify no target loses a pre-existing flag, and build in a DerivedData outside the repository (`~/Library/Caches/xcblame/` or `$TMPDIR`). | [TM] BTA#109/#106/#61, R6; [DS] §3-4; [PP] A16; [REV-31], [REV-32] | §5.8, §7.5 |
| FR-09 | SHOULD offer `--deep --exact-files`: rebuild only the top-K batched targets with batch mode disabled, stating that the build shape changed. | [TM] R6; [ET] gap 4 | §6.4 |
| FR-10 | MUST support repeated runs (`--runs`) and build kinds `clean`, `incremental` (`--touch`), `zero-change`. | [PP] W7 | §3.2, §7.8 |
| FR-49 | MUST, in `build` mode, snapshot the build description (`manifest.json`, `target-graph.txt`, `build-request.json`) and the Clang/Swift modules-report CSVs into `.xcblame/snapshots/<log-uuid>/` right after xcodebuild exits, because the next build overwrites them. | [OBS-12]; [BP] §1.1 (llbuild manifest); [REV-6] | §5.11 |

### 1.2 Read

| ID | Requirement | Source | Design |
|---|---|---|---|
| FR-11 | MUST read `xcresulttool get log --type build` JSON when a result bundle exists and SLF `.xcactivitylog` otherwise, into one BuildModel; both readers MUST agree on the common subset (task set, durations within 2 ms, targets, kinds, diagnostics); SLF-only fields (wasCancelled, isQuiet, wasFetchedFromCache, uniqueIdentifier, task key) are optional. | [RL]; [OBS-1], [OBS-12]; [DS] §2; [REV-5] | §5.1, §5.7 |
| FR-12 | MUST tokenize SLF at byte level (UTF-8 byte lengths, embedded NUL/CR/LF, 1-based class refs, decimal ints, hex little-endian doubles, `*` JSON tokens). | [RL]; [OBS-8]; [TM] PR#254, R14 | §5.3 |
| FR-13 | MUST decode sections with a versioned schema table (command-line and IDE layouts) plus type-sequence sniffing; unknown classes, attachments and fields skipped with a warning. v0.1 MUST parse IDE-produced fixtures (AcmeApp built in Xcode.app 26.0.1 and 27.1). | [TM] R1, XLP#9/#169/#242/#261/#262; [DS] §1.4; [REV-1] | §5.3, §5.4, MV-15, §11 |
| FR-14 | MUST decode `TaskMetrics`, `TaskBacktrace`, `BuildOperationMetrics` (both shapes, build-level) with all fields optional; treat TaskMetrics placeholder records (maxRSS 0, utime = stime = wcDuration) as "no CPU data"; keep unknown attachment IDs raw and ignore them. | [DS] §1.4; [TM] PR#235/#237, XLP#245/#251; [OBS-13]; [REV-36] | §5.4, §5.6 |
| FR-15 | MUST classify tasks by rule name (first token of commandDetails, unescaped), structure and command line from a versioned KindTable; titles may only annotate `other` rows and never change kind, target or numbers; unclassified time MUST be reported. | [TM] R2, XLP#190/#201/#167/#136; [REV-16] | §4.3 rule 7, §5.5 |
| FR-16 | MUST attribute tasks to real targets only (signature suffix incl. optional ` at path`, `.build`/`-t.build` segments, manifest key prefix); explicit-module and planning tasks go to named buckets. | [TM] R4, XLP#220/#148/#51/#258; [OBS-4], [OBS-5] | §5.5 |
| FR-17 | MUST define the executed task structurally (task-depth section with a rule name, not an aggregate/log section) and count it once, with nested sections as sub-spans; MUST work for logs without attachments (SLF < 11); TaskMetrics only enrich. | [RL] 264.2 s naive vs 109.3 s; [OBS-10], [OBS-13]; [TM] XLP#203; [REV-3], [REV-4] | §5.5 |
| FR-18 | MUST read Xcode's timing aggregate sections and validate per-rule-name sums (the aggregate's row unit) against them with tolerance max(0.25 s, 2 %), reporting count mismatches as warnings. | [RL] 22 aggregate sections; [OBS-10]; [REV-8] | §6.11 V5 |
| FR-19 | MUST decode diagnostics by severity field (not category strings), assemble multi-line diagnostics, dedupe repeats with occurrence counts, and link each to task and target. | [TM] R15, XLP#212, xcbeautify#105; [RL] `[#ImplicitStrongCapture]`; [REV-20] | §5.10 |
| FR-20 | MUST read the project model read-only: pbxproj (objectVersion 46-90, synchronized folders, shellScript string or array), Xcode 27.2 `project.xcproj` JSON, xcconfig chains, `-showBuildSettings -json`, `build-request.json` command-line overrides, schemes, workspace, SPM, Podfile.lock, Cartfile.resolved, generator detection (XcodeGen, Tuist, CocoaPods). | [TM] R11, XPJ#837/#880/#921/#987; [DS] §6; [OBS-11], [OBS-15] | §4.1, §7.4 |

### 1.3 Explain

| ID | Requirement | Source | Design |
|---|---|---|---|
| FR-21 | MUST detect reused sections (start before the session window or `wasFetchedFromCache`) and exclude them from timing; clamp intervals to the session window. | [TM] PR#249; [OBS-2] | §6.1 |
| FR-22 | MUST report log span, process wall (when wrapped), time outside the log, busy time, task-time sum, CPU (with the number of tasks that had real metrics), average and peak parallelism, idle gaps and serial stretches (lanes ≤ max(1, floor(10 % of physical cores))), as separate numbers. | [TM] R5, XLP#44/#148; [PP] A2, E1; [OBS-6]; [REV-17], [REV-21] | §6.3 |
| FR-23 | MUST compute the critical path on the build system's DAG (manifest commands, dynamic tasks attached to their requesting command) when a matching description or snapshot exists, with a timing-consistency check; otherwise on labelled timing inference. What-if = DAG longest path with the target's durations set to 0; under inference only a path-share bound. | [ET] gap 2; [BP] §1.5; [OBS-12]; [REV-6], [REV-7], [REV-28] | §6.2 |
| FR-24 | MUST roll up by phase, kind, target, owner (app, local package, remote package, Pods, macro plugin, system modules) and file, ranking by critical-path seconds then task time. | [TM] BTA#99/#24/#49, XLP#221; [ET] gap 3 | §6.4 |
| FR-25 | MUST label per-file granularity (`exact`, `batch`, `estimated`, `wmo`) on every row and never copy a batch duration onto each file. | [TM] R6, BTA#92, XLP#47; [DS] §1.5 | §6.4 |
| FR-26 | MUST rank function/expression hotspots filtered to user code, deduped by file:line:col, weighted by critical-path membership, labelled "type-check only", with a linked code rule and snippet. | [PP] A4, W1; [TM] BTA#43/#26, XLP#100; [RL] | §6.5 |
| FR-27 | MUST give every executed task in a non-clean build exactly one primary cause (precedence: backtrace, script I/O, signature change, upstream module change, timestamp churn, planning pattern, driver remarks, `unknown`), rank causes by task time and by path seconds separately, and enforce that causes partition executed task time. | [PP] A1, A2, W2; [ET] gap 1, 5; [REV-15] | §6.6, V15 |
| FR-28 | MUST classify build kind (clean, incremental, zero-change, cached, previews, index, analyze, archive, test) from build-request fields, task counts, reused tasks, cache counters and DerivedData arena paths, never titles; exclude previews/index/analyze from baselines by default. | [TM] XLP#224, XCM#72/#103, XcodeBenchmark#20, XRC#140; [OBS-15]; [REV-16] | §6.7, MV-17 |
| FR-29 | MUST report fixed costs per class (scripts, codesign, validate, embed, Info.plist, app-intents, planning, SDK stat cache, package resolution, Swift planning, macro/swift-syntax, out-of-log time) with per-build and per-day estimates. | [PP] A6; [OC] D8; [BP] §1.2; [OBS-14] | §6.8 |
| FR-30 | MUST compute module-graph metrics (depth, longest weighted chain, fan-in/out, umbrella candidates, cycles, blockers, macro plugins per module) and module variants with their differing flags from the modules reports. | [OC] C4-C6, A24, F8; [OBS-4], [OBS-15] | §6.9 |
| FR-31 | MUST compare a build against a baseline with a noise model and attribute the delta (environment incl. inferred Xcode first, then phases, targets, critical path, new/removed tasks, settings). | [PP] A5, W7, W8; [ET] gap 9 | §6.10 |
| FR-32 | MUST model compilation caching at build level (cache counters, cached kind); cache hits are not compile time; per-task replay only as a labelled heuristic; missing CAS never fatal. | [TM] R16, TU#11782/#12245; [DS] §1.4; [REV-19] | §5.6, §6.7 |

### 1.4 Fix

| ID | Requirement | Source | Design |
|---|---|---|---|
| FR-33 | MUST run static rules without building (`doctor`) in seconds. | [PP] W4; [ET] §1.8 | §3.4, §7 |
| FR-34 | MUST express every rule as data with a concrete detection predicate (or mark it docs-only `info`), exact signal, signal key, fix kind, impact band with basis, evidence tag, computed confidence, risk, applicability, conflicts. Any [K] part gates the rule as "needs measurement" (low confidence, `+V` only). | [OC] tag legend, conflicts; [REV-25], [REV-26], [REV-27] | §7.1, RULES.md |
| FR-35 | MUST print a fix plan by default; `--apply` writes only `.xcblame/overlay-<Config>.xcconfig` lines; `defaults` changes need `--apply-defaults`; hook installation needs `--install-hook`; project, scheme and manifest edits need `--edit-project`. Shadowed keys are never fixed by an automatic project edit. | [PP] W11; [TM] R11; [REV-2], [REV-33] | §7.3, §7.5 |
| FR-36 | MUST compute setting provenance, refuse to claim an overlay fix that a higher level shadows, and for every delivery (hook or command line) confirm with `-showBuildSettings -json` that the effective value changed per target. | [DS] §6.1, §6.3; [REV-9] | §7.4, §7.5 |
| FR-37 | MUST, for `--edit-project`, back up bytes, edit textually and minimally, re-parse, compare object graphs, confirm via `xcodebuild -list`/`-showBuildSettings`, restore on any mismatch; refuse generated projects. | [TM] XPJ#56/#666/#683/#934/#1004/#1055; [OBS-11] | §7.6 |
| FR-38 | MUST give code-level findings as file:line + before/after snippet and never auto-edit source in v1. | [OC] B intro; [PP] E13 | §7.7 |
| FR-39 | MUST provide `verify`: deliver through the same mechanism as the final fix, separate DerivedData per arm for non-clean kinds, default 5 runs per arm, require exit 0 and a matching target/task-kind set on every run, noise band, auto-revert when slower, within noise, broken, or changed. | [PP] W7; [OC] Tier 2; [REV-10], [REV-12], [REV-13], [REV-29] | §7.8 |
| FR-40 | MUST support `fix --revert` and hook uninstall restoring byte-identical files. | [TM] R11 | §7.5 |
| FR-41 | MUST deliver command-line overlays through a generated wrapper xcconfig that includes the user's own `-xcconfig` and `XCODE_XCCONFIG_FILE` file before the overlay. | [REV-31] | §7.5 |

### 1.5 CI, history and output

| ID | Requirement | Source | Design |
|---|---|---|---|
| FR-42 | MUST emit a versioned JSON report with a published JSON Schema; unknown values are `null` with a reason; sections that do not apply to the build kind are `null` with a note. | [TM] R12, XCM#29, TU#8729; [REV-17] | §8.1 |
| FR-43 | MUST emit `markdown`/`github` PR comments and annotations, `junit`, `sarif`, `chrome-trace` (the drill-down view), and an `agent` mode (errors first, token-budgeted). | [TM] R12, XLP#188/#166, XCP#13, xcbeautify#508; [PP] W9 | §8.3 |
| FR-44 | MUST support `--baseline <file>`, `--fail-if-slower <pct>` and documented exit codes. | [PP] A9, W9; [OC] G6, G8 | §3.2, §8.4 |
| FR-45 | MUST keep local history in `.xcblame/history/` with a summary and a compact per-build task index (key, rule, target, kind, signature digest, duration, on-path; hashes from `why` runs), retention, `trend` (p50/p75/p95 by kind, scheme, inferred Xcode, branch, commit, machine) and `compare`. | [PP] W8; [ET] gap 11; [TM] XCM#58/#114; [REV-14], [REV-37] | §3.2, §6.6, §8.3 |
| FR-46 | MUST provide `--redact`, on by default for shareable formats (markdown, github, agent, html), and escape all user strings. | [TM] R13, XLP#142 | §3.1, §8.2, §8.3 |
| FR-47 | MUST cap ranked tables and report sizes, always stating total rows and shown share (`<name>Total`, `<name>ShownShare`). | [TM] R9, BTA#10, XLP#108/#202; [REV-17] | §3.1, §8.1, §8.2.3 |
| FR-48 | SHOULD support Xcode Cloud (explicit log/bundle paths in `ci_scripts`, environment detection), after MV-11. | [TM] TU#7543; [REV-37] | §11 v0.8, MV-11 |
| FR-50 | SHOULD parse `swift build --build-system swiftbuild` output and SwiftPM trace events when available. | [TM] R16, xcbeautify#509; [ET] §1.9 | §11 v0.8 |
| FR-51 | MUST offer `--explain` glossary lines and `xcblame glossary` defining every reported term. | [PP] W6; [REV-37] | §3.1, §3.2 |
| FR-52 | MUST write `.xcblame/.gitignore` on first run, ignoring history, snapshots, reports, tmp and backups while keeping config, baseline, overlays and hooks tracked. | [REV-32] | §4.3 rule 2 |

### 1.6 HTML report

Added by the user decision of 2026-10-31 (DESIGN Appendix B row 39). This reverses the earlier v1 scope exclusion of HTML but keeps the XCLogParser lesson ([TM] R8, R9: 1.3-1.4 GB reports, a 3-4 GB `build.js`, CDN blank pages) as hard limits.

| ID | Requirement | Source | Design |
|---|---|---|---|
| FR-53 | MUST emit an HTML report: `--format html` for `analyze`, `compare`, `why`, `doctor`, `verify` and `trend`, and `build --html`. The report MUST be one self-contained file: inline CSS/JS, no sibling files, shards or per-target pages. It MUST make no network request on load (no CDN, web fonts, `fetch`), so it opens offline, from `file://`, and as a CI artifact. It MUST also follow dark/light via `prefers-color-scheme`, print cleanly, and have keyboard-navigable tables. | [TM] R9, XLP#108/#202/#130/#220; [ET] §6 (single-file HTML), §3 (Android Build Analyzer, Gradle Build Scan, cargo `--timings`, Xcode Build Timeline); [PP] W3 | §3.1, §3.2, §8.2.1, §8.2.6 |
| FR-54 | MUST embed the data as one plain JSON blob in `<script type="application/json" id="xcblame-data">`. The blob MUST equal the `--format json` document for the same command and options, plus `taskIndex`, so every count in the page equals the JSON `*Total`. A test MUST verify byte parity, and that each section's rendered counts match the blob. | [TM] R3, R12 | §8.2.1, §8.2.2, §8.2.5 |
| FR-55 | MUST cap the HTML file at 8 MB by default, template included (`--max-report-bytes`). It MUST truncate in the fixed order of §8.2.3 (hotspots → files → task-index detail → module graph → targets → evidence → diagnostics) down to fixed floors, after computing every Total, partition, utilization series and critical path from the full model. It MUST never exceed the cap and never fail the command because of size. | [TM] R8, R9, XLP#108/#117/#150/#202 | §8.2.3 |
| FR-56 | MUST make truncation and unknowns visible in the page. Every table states shown/total and seconds share from `*Total`/`*ShownShare`, and a banner lists every truncation step (`truncation.steps`). `null` renders as "unknown (reason)" and an inapplicable section as "not applicable: <note>", never as `0` or a missing section. The banner MUST give the `--format chrome-trace` command for full detail. | [TM] R3, R9, BTA#10, R17 | §8.2.1, §8.2.3 |
| FR-57 | MUST apply `--redact` (on by default for html) to the document before embedding, so no user name, absolute home path, host name or DerivedData hash reaches the file. Every log-derived string MUST be inserted as text, never as markup or generated JS. | [TM] R13, XLP#142 | §3.1, §8.2.5, §8.2.6 |
| FR-58 | MUST write HTML to `-o <path>` or to `.xcblame/reports/<time>-<kind>.html` (atomically) and print the path. `--open [--browser <app>]` MUST open it in the default browser, or in `<app>` with fallback to the default browser. It MUST never open a browser when `CI=true`. `analyze <report.json> --format html` MUST re-render a saved JSON report. | [PP] W3 ("don't make me parse logs"); [ET] §6 | §3.1, §3.2, §8.2.5 |
| FR-59 | MUST provide these HTML sections: header, critical-path timeline with utilization strip, targets (owner, kind mix, drill-down to tasks), files with granularity badges, hotspots with `file:line` grouped by file, findings & fix plan with copyable `xcblame` commands and inline rule explanations, and environment & validation, all in v0.2. The views for doctor (v0.3), compare and trend (v0.4), incremental why, fixed costs and module graph (v0.5) and verify (v0.6) MUST land with their engines. | [PP] W1 ("show me which file or function"), W2, W4, W7, W8; [ET] §3; [TM] R5, R6 | §8.2.4, §11 |

## 2. Non-functional requirements

| ID | Requirement | Source | Design |
|---|---|---|---|
| NFR-01 | MUST be a single signed, notarized universal Swift binary; only external package dependency swift-argument-parser; system `libz`; no Ruby, Node, Python, Docker or server. | [TM] R10, XBR#12, XCM#81/#48/#20 | §4.1 |
| NFR-02 | MUST be local-first: no network access except the user's own xcodebuild; no telemetry. | [TM] R13; [PP] other signals | §4.3 |
| NFR-03 | MUST stream: parse a 1 GB inflated log in < 30 s with < 300 MB RSS; a 12 MB log in < 1 s. | [TM] R8, XLP#150/#196/#215, XCM#20 | §4.3, §12.8 |
| NFR-04 | MUST use only O(n) / O(n log n) algorithms on log-sized inputs (DAG longest path O(V+E); inference O(n log n + p·K)) and no backtracking regex on untrusted text; CI gates on scaling tests. | [TM] PR#263, xcbeautify#138/#162; [REV-28] | §4.3, §6.2, §12.8 |
| NFR-05 | MUST contain no force unwrap, `try!` or `fatalError` in parse/analyze paths. | [TM] XCM#38, XPJ#1055 | §4.3 |
| NFR-06 | MUST self-validate every report (V1-V15) and withhold numbers that fail. | [TM] R3, XBR#17 | §6.11 |
| NFR-07 | MUST be read-only by default; writes only inside `.xcblame/` and `~/Library/Caches/xcblame/` without explicit flags. | [TM] R11; [REV-32] | §4.3 |
| NFR-08 | MUST keep version-dependent knowledge in data tables (KindTable, ClassSchemaTable, RuleSpec, known-issue table) with Xcode ranges. | [TM] R1, rules_xcodeproj#3160 | §4.3 |
| NFR-09 | MUST ship a golden corpus covering Xcode 10-27, xcodebuild- and IDE-produced logs, and every new beta on day 1, tested forward and backward. | [TM] R1, R18, XLP#209/#211; [REV-1] | §12.1 |
| NFR-10 | MUST automate releases (tag to signed binary, stable asset names, Homebrew tap update). | [TM] R10, XLP#226/#232/#239 | §11 v0.4 |
| NFR-11 | SHOULD meet a 72 h fix SLA for format drift on a new Xcode beta. | [TM] R18 | §10.3, §11 |
| NFR-12 | MUST produce deterministic output for the same input and options. | [ET] §1.8 | §9 |
| NFR-13 | MUST bound environment probes with timeouts (2 s each) and degrade to `unknown`. | [TM] XCM#37 | §5.9 |
| NFR-14 | MUST be scope-honest: state what was not measured (no backtraces, batch granularity, no result bundle, inferred Xcode, inferred critical path, no previous task index). | [TM] XLP#127/#114, R17 | §6.2, §6.6, §8.1 |
| NFR-15 | MUST render the HTML report's first paint in < 1 s on a 50k-task report in current Safari and Chrome on an Apple-silicon (M1-class) Mac. First paint = header, critical-path bars and the first rows of visible tables, measured by the `xcblame:first-paint` performance mark. Timeline zoom/pan MUST redraw in ≤ 16 ms. The page MUST create no DOM node per task: a canvas timeline, and tables paged at 200 rows. | [TM] R8, R9, XLP#108 (Chrome crash); [ET] §1.1 (XLP#148: 15K-target timeline unreadable) | §8.2.4, §8.2.5 tier 3 |
| NFR-16 | MUST keep the web part to one template file in vanilla JS/CSS, with no framework, package manager, bundler or build step. The template MUST be compiled into the binary at build time (`make template` → `ReportTemplate.swift`), with a drift test. | NFR-01; [TM] R10 | §8.2.1, §8.2.5 |

## 3. Traceability: R1-R18 (from [TM])

| R | Requirement summary | xcblame requirements | Design feature |
|---|---|---|---|
| R1 | Format-drift resilience, golden corpus 10-27, never hard-fail | FR-13, FR-14, NFR-08, NFR-09 | Schema table + sniffing with command-line and IDE layouts (§5.4), corpus (§12.1) |
| R2 | Classify by structure/command line, not title | FR-15, FR-17 | Rule-name KindTable, structural task unit (§5.5) |
| R3 | No silent zeros/NaN/negatives/caps | FR-42, FR-47, NFR-06 | Validator V1-V15 (§6.11), Total/ShownShare, null + notes (§8.1) |
| R4 | Correct target attribution | FR-16, FR-17, FR-21, FR-28 | Attribution chain, buckets, reused tasks (§5.5, §6.1) |
| R5 | Separate wall, busy, CPU, idle, critical path | FR-22, FR-23 | Utilization, DAG critical path (§6.2, §6.3) |
| R6 | Honest per-file timing, orchestrated profiling build | FR-08, FR-09, FR-25 | Granularity labels, `--deep --exact-files` (§6.4, §5.8) |
| R7 | Log discovery and integrity | FR-01, FR-03-FR-06, FR-48 | Locator, IntegrityProbe (§5.2) |
| R8 | Streaming, bounded memory, O(n) | NFR-03, NFR-04, FR-55, NFR-15 | Streaming tokenizer (§4.3); HTML size cap and render budget (§8.2.3, §8.2.4) |
| R9 | Reports that cannot explode | FR-47, FR-53-FR-56, NFR-15; chrome-trace drill-down (FR-43) | Size budgets, top-N with totals (§3.1, §8). Single-file HTML with an 8 MB cap, ordered truncation with floors and a banner (§8.2.3). Full detail via chrome-trace. Drill-down shards: OUT (one file only, §8.2.6). |
| R10 | Zero-setup distribution | NFR-01, NFR-10 | Single binary, release automation |
| R11 | Never edit project by default; xcconfig/CLI overrides; handle all formats | FR-20, FR-35-FR-37, FR-40, FR-41, FR-52, NFR-07 | Overlay, hook, wrapper, edit protocol (§7.3-§7.6) |
| R12 | Machine-readable, diff, build kind, rollups, fix ranking, trace/JUnit/SARIF, agent mode | FR-28, FR-31, FR-42-FR-44, FR-54 | JSON schema, reporters (§8). OTLP: OUT for v1 (chrome-trace covers trace viewers). |
| R13 | Privacy by default | FR-46, FR-57, NFR-02 | Redactor (also before HTML embedding, §8.2.5) |
| R14 | Byte-correct tokenization | FR-12 | §5.3 |
| R15 | Diagnostics by severity, multi-line assembly | FR-19 | §5.10 |
| R16 | Compilation caching and swift-build | FR-32, FR-50 | Build-level cache counters, cached kind (§6.7) |
| R17 | Never fail/slow the build; scope honesty | FR-02, NFR-13, NFR-14 | Exit-code pass-through, timeouts (§4.3) |
| R18 | Sustainable maintenance | NFR-09-NFR-11 | Beta-day-1 corpus, SLA (§11, §12) |

## 4. Traceability: pain points A1-A16 (from [PP] §A)

| # | Pain point | Requirements | Design feature / scope |
|---|---|---|---|
| A1 | Incremental builds do far more work than the edit justifies | FR-21, FR-27, FR-29, FR-45 | `why` with task index and one-cause partition (§6.6) |
| A2 | Cannot tell why it rebuilt or what is slow | FR-22-FR-27 | DAG critical path, rollups, causes (§6) |
| A3 | Macros and swift-syntax cost | FR-29, FR-30 | Fixed-cost class, macro-plugin metric, DEP-012/DEP-008/SRC-009 |
| A4 | Type checker and SwiftUI bodies | FR-08, FR-26, FR-38 | Hotspots + SRC rules (§6.5, §7.7) |
| A5 | Every Xcode release regresses | FR-07, FR-31, FR-45 | Inferred Xcode version, env-first attribution, trend by Xcode (§5.9, §6.10) |
| A6 | Fixed-cost phases nobody notices | FR-29, FR-33 | Fixed-cost report, PHASE rules (§6.8) |
| A7 | Modularization is not a free lunch | FR-30 | Module graph metrics, GRAPH rules with planning-cost caveat |
| A8 | Clean builds dominated by dependencies, branch churn | FR-24, FR-28 | Owner rollup, cached kind, SET-016/DEP rules |
| A9 | CI minutes and cost | FR-42-FR-45 | CI mode, baseline, PR comment (§8) |
| A10 | SwiftUI Previews rebuild too much | FR-28; RULES GRAPH-010 | Previews builds classified and excluded from baselines; GRAPH-010 suggests preview apps. Previews-specific timing analysis: OUT for v1 (§11). |
| A11 | Apple will not look at this | FR-42, FR-46 | Redacted, shareable JSON; `selftest` corpus for bug reports |
| A12 | Hidden defaults and conflicting advice | FR-33, FR-34 | `doctor` with provenance; conflicts stated per rule (§10.2) |
| A13 | Bazel/Tuist migration friction | NFR-01, FR-20 | Works on existing Xcode projects |
| A14 | Editor responsiveness mistaken for build speed | FR-28 | Index builds classified when logged (MV-17); indexing analysis: OUT for v1 (§6.7, §11). |
| A15 | Hardware and environment gotchas | FR-07 | Env capture incl. Rosetta, RAM, thermal, free disk; ENV rules |
| A16 | Timing flags have cost, do not reach SPM | FR-08 | Command-line wrapper reaches packages; deep DerivedData outside the repo |

## 5. Traceability: wish-list W1-W11 (from [PP] §D, rows in order)

| W | Wish | Requirements / scope |
|---|---|---|
| W1 | Show me which file or function | FR-25, FR-26, FR-08, FR-59 (HTML files and hotspots) |
| W2 | Why did this rebuild? | FR-27, FR-45 |
| W3 | Don't make me parse logs | FR-01, FR-03, FR-53, FR-58 (`--format html --open`) |
| W4 | What should I change? | FR-33, FR-34, FR-35 |
| W5 | Is it me, my machine, or Xcode? | FR-07, FR-31, `trend --by machine|xcode`. A reference benchmark database is OUT (benchmark tables are not comparable across Xcode versions, [PP] §C). |
| W6 | Explain in plain language | FR-22, FR-23, FR-51 |
| W7 | Compare before/after | FR-10, FR-31, FR-39, FR-59 (HTML compare/verify) |
| W8 | Track over time | FR-45 (trend by commit with `--git`), FR-59 (HTML trend) |
| W9 | PR comment in CI | FR-43, FR-44 |
| W10 | Do not make me adopt Bazel/Tuist | NFR-01, FR-20 |
| W11 | Safe, reviewable fixes | FR-35-FR-37, FR-39, FR-40 |

## 6. Misconceptions the output must correct (from [PP] §E)

| E | Misconception | How the output corrects it |
|---|---|---|
| E1 | Summed task time = build time | Span, busy, task time and CPU printed separately; critical path first (FR-22, FR-23). |
| E2 | "Swift is slow" when a script/lint/dSYM/asset/sign/network step is | Fixed-cost and phase rollups ranked by critical path (FR-24, FR-29). |
| E3 | Modularize and it gets faster | Planning cost and depth shown with module count; GRAPH rules carry the caveat (FR-30). |
| E4 | Clean build time is the metric | Kind-separated history and baselines; zero-change report (FR-28, FR-45). |
| E5 | New Xcode is slower, so downgrade | Env-first regression attribution with inferred Xcode; version-aware rules (FR-07, FR-31). |
| E6 | Buy a faster Mac | Serial stretches show unused cores; ENV rules point to Rosetta/RAM first (FR-07, FR-22). |
| E7 | Delete DerivedData fixes it | `why` shows real causes; no rule recommends deleting DerivedData. |
| E8 | Type-check warning flags will find it | Hotspots labelled type-check only; non-compile phases ranked alongside (FR-26). |
| E9 | Use WMO in Debug | SET-001 flags Debug WMO; never recommended. |
| E10 | Macros are free | Macro-plugin and swift-syntax costs measured (FR-29, FR-30). |
| E11 | Indexing = building | Index builds classified separately when logged (FR-28). |
| E12 | xcodebuild = Xcode | Producer (xcodebuild or IDE) recorded; IDE logs analyzed directly (FR-03, FR-13). |
| E13 | The error points at the problem | Code findings show measured ms at the location, not only diagnostics (FR-26). |
