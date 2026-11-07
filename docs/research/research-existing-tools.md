# Competitive landscape: Xcode build-time analysis / visualization / optimization tools

Research date: 2026-10-30. Star counts and "last push" dates were read from the GitHub REST API (api.github.com/repos/...) and repo pages on 2026-10-30. "pushed_at" is the last push to any branch, which can overstate code activity (docs/CI commits count).

## 0. Executive summary

- The OSS field is thin and mostly stale. The only actively maintained OSS parser is XCLogParser (1.85k stars, v0.2.50 on 2026-10-27), and its signature per-file/per-function Swift timing features are broken on modern Xcode. The only well-starred "analyzer" app (BuildTimeAnalyzer, 4.3k) depends on the `-debug-time-function-bodies` flag and a 2016-era approach.
- The commercial/hosted layer (Tuist Build Insights, RocketSim for Teams, Bitrise Insights/Build Cache) does trending and dashboards, not diagnosis. None of them explains WHY a given build was slow or what to change.
- The newest and fastest-growing "tool" is an AI-agent skill (AvdLee/Xcode-Build-Optimization-Agent-Skill, 1.27k stars in about 7 months). It validates demand for "actionable fixes", but it is prompt-driven and doesn't ship a deterministic parser. Its README does not name the raw artifacts it parses.
- The platform is moving: Swift 6.x compiler/SwiftPM are adding trace-event output and "task backtraces" (why a task ran). Xcode 27 claims big SwiftUI type-check wins via ContentBuilder. A new CLI should plan to ingest these formats, not only xcactivitylog.
- Biggest gap: nobody joins (a) module/target-level critical-path attribution, (b) per-file/function culprit ranking that survives batch-mode compilation, (c) incremental-build "why did this rebuild", and (d) a concrete, ranked, auto-applicable fix list, in one offline CLI that works both locally and in CI.

---

## 1. Tool-by-tool findings

### 1.1 XCLogParser (MobileNativeFoundation, originally Spotify) - the incumbent
- URL: https://github.com/MobileNativeFoundation/XCLogParser
- Stars 1,852; forks 140; open issues 43 (API; the page says 32 issues + 11 PRs); created 2019-05-22; last push 2026-10-27; Swift; Apache-2.0; not archived. (https://api.github.com/repos/MobileNativeFoundation/XCLogParser)
- Releases: v0.2.50 (2026-10-27), v0.2.49 (2026-07-07), v0.2.48 (2026-06-09), v0.2.47 (2026-04-24), v0.2.46 (2026-03-03). v0.2.41 shipped 2025-03-21. (https://api.github.com/repos/MobileNativeFoundation/XCLogParser/releases)
- v0.2.50 is a perf fix: quadratic diagnostic accumulation in large logs (e.g., 40,000 notices/warnings 30.5 s -> 2.5 s; 40,000 distinct locations 53 s -> 0.15 s). So big-log memory/CPU blowups are a known recurring weakness. (https://api.github.com/repos/MobileNativeFoundation/XCLogParser/releases/latest)
- Status: maintained but community-driven, README still says "alpha". Maintenance lull in 2025: issue #226 (Feb-Mar 2025) shows a merged Xcode 16 fix sat unreleased for ~6 weeks and Homebrew lagged further. (https://github.com/MobileNativeFoundation/XCLogParser/issues/226)
- Input: `.xcactivitylog` files in `DerivedData/<proj>-<hash>/Logs/Build` (gzip-compressed, SLF serialization), located via `LogStoreManifest.plist`. For `xcodebuild` on Xcode 11+, logs are only produced with `-resultBundlePath` (or for `test`). Requires Xcode 16.4 / Swift 6.0 per README. (https://github.com/MobileNativeFoundation/XCLogParser README)
- SLF format: tokenized binary-ish text stream after gunzip (README links a separate format doc; I could not fetch the format doc, it 404'd at the path I guessed). Parse errors on new Xcode versions are a recurring failure class: "The line doesn't seem like a valid SLF line" on Xcode 15.3 (#207) and Xcode 16.x (XCMetrics #118). (https://github.com/MobileNativeFoundation/XCLogParser/issues/207, https://github.com/spotify/XCMetrics/issues/118)
- Commands: `dump` (full JSON), `parse --reporter ...`, `manifest`.
- Reporters: `json` (nested step tree), `flatJson` (array, subSteps always empty, "intended for loading into a database"), `summaryJson` (one object, no nested steps), `chromeTracer` (chrome://tracing events), `issues` (errors/warnings only), `html` (static report: per-module and per-file times, warnings, errors).
- Notable flags: `--omit_warnings`, `--omit_notes`, `--trunc_large_issues` (cap 100 per task; "reduces memory use"), `--redacted`, `--without_build_specific_info`, `--derived_data`, `--rootOutput`, `--machine_name`.
- Swift function timing extraction: opt-in. Build with `-Xfrontend -debug-time-function-bodies` and `-Xfrontend -debug-time-expression-type-checking`; parser attaches `swiftFunctionTimes` / `swiftTypeCheckTimes` (durationMS, occurrences, file, startingLine/Column, signature) to the Swift compile step. Also optional ld64 stats (`-Xlinker -print_statistics`) and clang `-ftime-trace` ingestion.
- Limitations / complaints (primary evidence):
  - Swift type-check/function times no longer produced on modern Xcode (#190, open since 2023-10, 12 comments). A contributor (Iron-Ham, Mar 2025) found modern logs name steps "SwiftCompile" not "CompileSwift ", so the parser "will never" recognize them; also Xcode batches files, making "slowest Swift files" misleading. Fix exists only in a fork (Iron-Ham/XCLogParser, 2 stars, last push 2025-09-11). (https://github.com/MobileNativeFoundation/XCLogParser/issues/190)
  - Swift compile steps categorized "other" on Xcode 15.0.1 (#201); non-target steps like "Create build description" appear under "Slowest targets" on Xcode 16.0 (#220).
  - New build system timeline is misleading: #148 (2021) "Each target is now starting with a `Create directory Target.framework`... step" so all targets appear to start together; #175 (2022): "many target seems build take a long time... but they not, just wait for dependency build". One commenter with 100+ pods: a clean build "produced nearly 15K targets, making the timeline unreadable". No maintainer reply on either. (https://github.com/MobileNativeFoundation/XCLogParser/issues/148, /175)
  - Memory: "Memory usage explosion in parse command in 0.2.37" (#196); leak after parseActivityLogInURL (#215, ~500 MB for 6.6 MB of logs); HTML report of 19,741 files / 1.3 GB (#202); Iron-Ham reports ~80 GB in `writeTargetFiles`.
  - Test stats gone when Xcode produces xcresult instead of xcactivitylog (#127, #174).
  - Wanted but not built: OpenTelemetry reporter (#188, open), SonarQube (#166), documentURL for storyboard/XIB steps (#65).
  - No critical-path computation, no cross-build diff, no "why", no fixes.
- Use: local (post-action script) and CI (xcodebuild + resultBundlePath), mostly as a library under other tools (XCMetrics, Tuist's `inspect build` is likely similar in spirit but I did not verify Tuist's parser internals).

### 1.2 XCMetrics (Spotify)
- URL: https://github.com/spotify/XCMetrics
- Stars 1,161; forks 82; open issues 20; last push 2024-04-26; latest releases v0.0.13 (2023-01-23); Swift; Apache-2.0; not archived but effectively dormant. (https://api.github.com/repos/spotify/XCMetrics, /releases)
- Architecture: Swift backend (Vapor/SwiftNIO + Postgres + Redis, Docker/Docker Compose, protobuf definitions; deployment examples folder), a CLI client that you add as a scheme post-action; client uploads `.xcactivitylog` (+ metadata via plugins) to the backend, backend parses with XCLogParser and stores builds/targets/steps in Postgres; visualize via Grafana on the DB. README claims ~1M builds / 10B steps collected at Spotify. (README: https://github.com/spotify/XCMetrics; Postgres/Redis/Grafana details from issues #20, #29, #48, #58.)
- Why less used (evidence from issues):
  - Self-host burden: crash on latest docker image (#20, 8 comments, still open), Docker Compose failures (#48 open), only `latest` tag published (#43), "Looking forward to the Web Interface" (#52) / "Web interface" (#23) - the demo UI was never open-sourced, users need to build Grafana dashboards on an undocumented schema (#29).
  - Scale: bind-count limit crash on a 29 MB log (#30), slow queries as data grows (#58), no retention (#41, #114).
  - Xcode drift: broken on Xcode 15.3 (#115, open), 16.1 parse error (#118, open, 2025-01).
  - Data-model gaps users asked about: git branch (#9, solved via plugins), extension vs main target builds skewing medians (#72), confusing "for Previews" build rows (#103).
- Does NOT: give per-build explanation or fixes; no hosted option; no built-in UI.
- Use: team-wide trend collection, local + CI, large orgs only.

### 1.3 BuildTimeAnalyzer-for-Xcode (Robert Gummesson)
- URL: https://github.com/RobertGummesson/BuildTimeAnalyzer-for-Xcode
- Stars 4,342 (most-starred in category); forks 263; open issues 19; created 2016-05-04; last push 2026-03-08 (small modernization: removed ObjC gzip dependency; commits show an AI co-author trailer); Swift macOS app; last tagged release per a search summary was v1.0.12 (June 2019) - I could not confirm this from GitHub. Effectively maintenance-mode. (API pages above)
- How: macOS app; reads the latest Xcode build log from DerivedData and parses the `-Xfrontend -debug-time-function-bodies` output lines (needs the flag in "Other Swift Flags"). Originally an Xcode plugin (Alcatraz) until Xcode 8 killed plugins.
- Output: sortable GUI table of function/expression times per file; click to open file in Xcode.
- Issues: "No Valid Logs Found" (#30, 27 comments, still open), "not seeing all the build timings" (#10), "Build times should be cumulative" (#26: files appear multiple times because of target dependencies), request for `-debug-time-expression-type-checking` (#61), plugin install failures (#1, #20).
- Does NOT: CLI/CI, JSON, targets/modules, parallelism/critical path, incremental analysis, history, fixes. Per-file attribution is dead in batch mode (see section 3).

### 1.4 xcode-build-times-rendering (Paul Taykalo)
- URL: https://github.com/PaulTaykalo/xcode-build-times-rendering
- Stars 334; forks 22; Ruby gem `xcode-build-times` 0.1.1 / JS (d3); last push 2021-04-28; ARCHIVED 2025-03-25 (read-only). (https://github.com/PaulTaykalo/xcode-build-times-rendering)
- How: `install` injects "Timing START"/"Timing END" run-script build phases into every target; events appended to `~/.timings.xcode`; `generate` emits `gantt.html` (d3 Gantt per target). Does not parse xcactivitylog at all.
- Gives: per-target Gantt (the "build timeline" idea, pre-Xcode 14).
- Does NOT: survive new build system (script phases may not bracket actual compile work), no files/functions, mutates the project file, abandoned/archived.
- Related Taykalo repos: xcode-time-tracker (142 stars, last push 2023-09-23), swift-scripts (950 stars, dead-code scripts), objc-dependency-visualizer (1,868 stars, 2020). (https://api.github.com/users/PaulTaykalo/repos)

### 1.5 xcprofiler (giginet)
- URL: https://github.com/giginet/xcprofiler
- Stars 343; forks 11; open issues 6; Ruby gem; last push 2019-10-11 (abandoned). (https://api.github.com/repos/giginet/xcprofiler)
- How: add `-Xfrontend -debug-time-function-bodies` to Other Swift Flags, build, run `xcprofiler MyApp` (or pass an .xcactivitylog path); parses the log's compiler output.
- Output: CLI table (File, Line, Method, ms), `--limit/--threshold/--order/--no-unique`, JSON reporter, Ruby API.
- Does NOT: targets, parallelism, current Xcode behaviors; README says tested only on Ruby 2.3/2.4; sample uses old Swift.

### 1.6 XcodeBenchmark (devMEremenko) - hardware benchmark, not an analyzer
- URL: https://github.com/devMEremenko/XcodeBenchmark
- Stars 3,683; forks 414; open issues 345; created 2020-08-18; last push 2026-10-16; the repo language is Python per API (the benchmarked code is a big C/C++/Swift/ObjC mix); actively maintained. (https://api.github.com/repos/devMEremenko/XcodeBenchmark)
- How: `sh benchmark.sh` compiles a fixed large framework (76 CocoaPods libs, ~2.5 GB build dir) and reports seconds; community submits results; tables by Xcode version and chip. Latest: M5 Max 16" ~84 s (Xcode 26), M5 Pro Mac mini 90 s (Xcode 27). Results across Xcode versions not comparable. (README: https://github.com/devMEremenko/XcodeBenchmark)
- Does NOT: say anything about YOUR project. Useful only for "what machine should I buy" and as a reproducible-methodology reference (pause background apps, plug in power; README notes an AI agent running on the same Mac slowed results ~10%).

### 1.7 Small/new local trackers (2025-2026)
- **XCBuildStats** (filipvlasic): macOS menu bar app + `swift run XCBuildStats --report`. 0 stars, created 2026-07-06, pushed 2026-10-27. Reads `LogStoreManifest.plist` only (does not decompress logs), copies into SQLite `~/.xcbuildstats/db.sqlite`; also watches `xcodebuild` processes (since CLI builds only log for `test` or `-resultBundlePath`). Notes Xcode purges logs and that cancellations are not marked (counted as short success). Total-time tracking only; no attribution. (https://github.com/filipvlasic/XCBuildStats)
- **maj07k1/build-time**: menu bar app; Xcode (manifests + xcactivitylog per-target times), SwiftPM `build.db`, npm logs; ranks slowest targets/modules; 0 stars, created 2026-10-21. (https://github.com/maj07k1/build-time)
- **matopeto/xcode-build-times**: SwiftBar/xbar plugin (PHP), 167 stars, last push 2026-08-08, "time you spend waiting for Xcode". (https://api.github.com/repos/matopeto/xcode-build-times)
- Older trackers, all dead (2016-2020): edwardaux/BuildMeUp (64), dbgrandi/GoOutside (61), marcinreliga/BuildTimeLogger (45), timroesner/BuildTimes (44), cats-oss/xcbt (14), irskep/swift_compile_times_parser (21, archived). (https://api.github.com/search/repositories?q=xcode+build+time)
- Pattern: every new entrant is "how long did I wait" tracking. Diagnosis is not attempted.

### 1.8 AI-agent skills (the new 2026 wave)
- **AvdLee/Xcode-Build-Optimization-Agent-Skill**: 1,266 stars, 52 forks, created 2026-03-13, last push 2026-09-14, Python, MIT. Six skills (orchestrator, benchmark, compilation-analyzer, project-analyzer, spm-build-analysis, fixer); 40+ checks (build settings, script phases, long type-checks, SPM graph, macros, SwiftUI decomposition, `final`); two-phase flow: writes `.build-benchmark/optimization-plan.md`, user ticks boxes, fixer applies approved items and re-benchmarks. README promotes RocketSim for long-term tracking, says results are point-in-time, self-reported, no trend tracking, README does not name which raw artifacts it parses. (https://github.com/AvdLee/Xcode-Build-Optimization-Agent-Skill)
- Other skills: InvokeDev/xcode-dx-skills (1 star; user pastes `xcodebuild -showBuildTimingSummary` output) (https://github.com/InvokeDev/xcode-dx-skills); attentiondotnet/Xcode-Build-Optimization-Agent-Skill (0 stars; looks like a copy/fork of the above).
- Takeaway: demand for "tell me what to fix and apply it" is real (1.2k stars in 7 months), but these are LLM-prompt workflows with weak determinism and no attribution engine underneath.

### 1.9 Xcode built-ins
- **Build Timeline** (Xcode 14+): Report navigator > build log > assistant editor. Rows = parallelism, width = duration, empty space = tasks blocked on upstream outputs, color = target; selection synced with the log. Apple's WWDC22 session defines critical path (shortest possible build with unlimited resources) but gives no tool to compute it; it is "post-build analysis". (https://developer.apple.com/videos/play/wwdc2022/110364/)
- **Build Timing Summary**: Product > Perform Action > Build With Timing Summary, or `xcodebuild -showBuildTimingSummary`; per-task-category totals. SwiftLee notes summed Swift compile times can exceed wall time because of parallelism. (https://www.avanderlee.com/optimization/analysing-build-performance-xcode/, updated 2026-03-30)
- **Compiler flags**: `-warn-long-function-bodies=N` and `-warn-long-expression-type-checking=N` (emit warnings above threshold), `-debug-time-function-bodies`, `-debug-time-expression-type-checking`, `-stats-output-dir`, incremental debugging via `-driver-show-incremental` / `-driver-show-job-lifecycle` (Swift forums; Xcode may filter the remarks). (https://forums.swift.org/t/optimizing-and-debugging-incremental-build-time-in-swift-5-5/49379, https://forums.swift.org/t/tools-for-profiling-long-compile-times/65350)
- **Recent build durations**: shown in the Report navigator, but Xcode keeps few logs and DerivedData cleaning wipes them (per XCBuildStats README), so no long-term history.
- **Xcode 26/27**: Compilation Caching (LLVM CAS, needs explicit modules + integrated driver), described in Bitrise's write-up (2025-11-11); third-party reports disagree on gains (clean builds slower with cache on in one December 2025 test). Xcode 27: Apple's SwiftUI guide says "Build times in Xcode 27 improve significantly through changes to ViewBuilder, now exposed as ContentBuilder" (no numbers). The WWDC26 "What's new in Xcode 27" transcript has no build-analysis feature. (https://developer.apple.com/wwdc26/guides/swiftui/, https://developer.apple.com/videos/play/wwdc2026/258/, https://bitrise.io/blog/post/lifting-the-hood-on-build-cache-for-xcode)
- **Incoming from the Swift toolchain**: SwiftPM pitch (2026-06-13, Owen Voorhees) to stabilize `--trace-events-file` (Trace Event Format JSON for Perfetto/speedscope) and `--enable-task-backtraces` (records why each task ran). Forum replies mention `-trace-stats-events` CSV, and open PR swiftlang/swift#88251 (`-emit-time-trace-path`, frontend time-trace, not merged as of my fetch, last update 2026-05-19). The thread mentions an "Accepted SE-0545" link but I could not verify the proposal text. (https://forums.swift.org/t/pitch-swiftpm-build-performance-debugging-options/87369, https://github.com/swiftlang/swift/pull/88251)

### 1.10 Tuist (Build Insights + cache)
- URL: https://github.com/tuist/tuist; stars 5,852; forks 781; open issues 600; Elixir (server) + Swift CLI per repo; last push 2026-10-30 (active). (https://api.github.com/repos/tuist/tuist)
- Build Insights (launched 2025-06-05): `tuist inspect build` as scheme post-action; CI via `tuist xcodebuild` with `-resultBundlePath` (else "activity logs and result bundles are not generated"); uploads to Tuist dashboard; per-module and per-file durations; filter by scheme, clean vs incremental, local vs CI; tags/values via env vars; optional machine metrics daemon (CPU/mem/network/disk) via `tuist setup insights`. Needs account/server (self-host possible). Gotchas: post-action not run on failed builds unless `runPostActionsOnFailure`, post-action doesn't inherit shell PATH (Mise/Homebrew), Xcode Cloud log discovery issue (#7543), API doesn't expose build runs (#8729 open). (https://tuist.dev/en/docs/guides/features/build-insights/xcode, https://github.com/tuist/tuist/issues/7543, /8729)
- Cache: "Module cache" (binary modules; needs Tuist-generated projects) and "Xcode cache" (shares Xcode compilation artifacts; works with any Xcode project). (https://tuist.dev/en/docs/guides/features/cache)
- Does NOT (per docs I read): explain why a build was slow, rank fixes, compute critical path, or run offline without a backend.

### 1.11 RocketSim for Teams / Build Insights (commercial)
- https://rocketsim.app/features/build-insights/: auto-collects build durations in the background, splits clean vs incremental, P75/P95/7-day average, filter by scheme, compares Xcode versions/machines, team dashboard. Page doesn't say how builds are captured. Duration-trend product, not diagnostics; SwiftLee's article recommends it for regression alerts ("Ideally, you would be notified automatically when a build becomes slower").

### 1.12 Bitrise (Insights + Build Cache for Xcode)
- Build Cache for Xcode (post dated 2025-11-11): local proxy implementing LLVM CAS gRPC; wrapper around `xcodebuild`; requires explicit modules + integrated driver; Xcode UI not covered by wrapper; 0% hit rate if DerivedData already has outputs; invocation compare with AI summaries in Bitrise Insights. (https://bitrise.io/blog/post/lifting-the-hood-on-build-cache-for-xcode)
- Insights: workflow-level p50/p90 build times and "Bottlenecks" page (workflows slower over 7 days vs prior 7); Q3 2026 update: Build Cache connects Xcode so local build times and cache hit rates appear in Insights, plus an Insights API in open beta. Workflow-level, not task-level. (https://bitrise.io/blog/post/q3-2026-product-update, https://docs.bitrise.io/en/insights/getting-started-with-insights.html)

### 1.13 Remote caching / "big company" answer
- **Bazel + rules_xcodeproj**: Bazel 26,017 stars (Java, active); rules_xcodeproj 628 stars, 168 open issues, last push 2026-10-27. Spotify reported CI build+test p75 from ~80 to ~20 minutes after moving to Bazel (InfoQ, 2023-10); Allegro/LINE report mixed Swift/ObjC rule gaps and cache misses from local paths. Cost: full build-system migration. (https://api.github.com/repos/bazelbuild/bazel, https://api.github.com/repos/MobileNativeFoundation/rules_xcodeproj, https://www.infoq.com/news/2023/10/spotify-bazel-ios-transition/, https://blog.allegro.tech/2020/12/speeding-up-ios-builds-with-bazel.html)
- **Buck2**: 4,506 stars, Rust, active (https://api.github.com/repos/facebook/buck2). I did not verify iOS maturity.
- **XCRemoteCache (Spotify)**: 872 stars, last push 2024-07-10, 37 open issues. Wraps CC/swiftc/libtool, fingerprints inputs, serves target artifacts over REST; does not support SPM deps, and requires disabling the new Swift driver (default since Xcode 14), i.e., dated vs Xcode 26 compilation caching. (https://github.com/spotify/XCRemoteCache)
- **Tart (Cirrus Labs)**: 7,722 stars, active; macOS VM runner tech, not a build analyzer. "Cirrus"/"Rugged": nothing relevant to build-time analysis found (unverified/not pursued).
- **Emerge Tools**: products found are Size Analysis, Snapshots, Performance Analysis, Launch Booster, Reaper (runtime dead-code), Build Distribution; no build-time analysis product found. (https://docs.emergetools.com/docs/quickstart)

### 1.14 Adjacent: xcbeautify, xcpretty, Periphery, SwiftLint
- **xcbeautify** (cpisciotta): 1,553 stars, Swift, last push 2026-08-10. Parses `xcodebuild`/`swift test` stdout; JUnit reports; GitHub/TeamCity/Azure renderers. README gives no build-time/durations feature. (https://raw.githubusercontent.com/cpisciotta/xcbeautify/main/README.md)
- **xcpretty**: 4,032 stars, Ruby, last push 2025-03-26. I did not verify timing features; widely understood as a formatter only (unverified for this report). (https://api.github.com/repos/xcpretty/xcpretty)
- **Periphery**: 6,180 stars, Swift; ARCHIVED 2026-08-12 as it "transitioned from an open-source project to a commercial product" (periphery.pro). Relevance: unused code removal reduces compile work, but it does no timing. (https://github.com/peripheryapp/periphery)
- **SwiftLint**: 19,779 stars. No build-time rule found. `explicit_type_interface` is a style rule (opt-in, no autocorrect). Whether explicit types help compile time is disputed on Swift Forums (one measured inferred 451.9 ms vs explicit 623.7 ms). SwiftLint itself costs build time (SwiftLee suggests `--quiet` and linting only changed files). (https://realm.github.io/SwiftLint/explicit_type_interface.html, https://forums.swift.org/t/compilation-time-with-and-without-type-inference/56545)

---

## 2. Other ecosystems - ideas to copy

| Tool | Input | Output / UX | Transferable idea |
|---|---|---|---|
| Android Studio Build Analyzer (https://developer.android.com/build/build-analyzer) | Gradle build data from the last build | In-IDE tabs: Overview, Plugins (time grouped by plugin), Tasks, Warnings, Downloads; warning types: always-run tasks, tasks sharing an output dir, non-incremental annotation processors, config cache off, Jetifier | Attribute time to the *owner* (plugin) not only the task; first-class "warnings" that are structural causes with a stated fix; compare several builds |
| Gradle Build Scan / Develocity (https://develocity.ai/develocity/product/performance-insights/) | Instrumented build + server | Timeline with critical path/concurrency; build comparison "what changed" (inputs, deps, environment); trends; avoidance savings; AI agent via MCP | Build-vs-build diff as the explanation primitive; link every trend point to its builds |
| gradle-profiler (1,534 stars) | Runs scenarios | Benchmarks clean/incremental with HTML | Scenario-driven benchmarks (clean, incremental ABI change, incremental body change) |
| ClangBuildAnalyzer (https://github.com/aras-p/ClangBuildAnalyzer, 1,263 stars, last push 2025-03-21) | Aggregates `-ftime-trace` JSON across files | Plain text ranked lists: slowest files, templates, functions, headers + include chains | Aggregate across many compile units, then rank by *total* cost and by inclusion count, not single-file |
| ninjatracing (531 stars) | `.ninja_log` | Chrome trace JSON for Perfetto/speedscope | Convert to the Trace Event format; reuse existing viewers instead of building a UI |
| cargo --timings (https://doc.rust-lang.org/cargo/reference/timings.html) | Cargo scheduler data | HTML: unit graph with dependency edges, concurrency graph (waiting / inactive / active), per-unit table, timestamped copies for comparing runs | Concurrency graph that separates "waiting for CPU" vs "blocked on deps" vs "running"; highlight a crate on which many others block; duplicate-version detection |
| Xcode Build Timeline (WWDC22) | Build graph | Parallelism rows, empty space = blocked | Same idea, but no automated critical path or recommendations |

(Note: some "UX ideas" in the cargo page summary were my fetch tool's synthesis, not documented features; the table lists only what the page documents.)

---

## 3. Comparison table

| Tool | Stars (2026-10-30) | Last push / status | Lang | Input | Output | Granularity | Works on Xcode 16/26? | CI / local | Explains why? | Suggests/applies fixes? |
|---|---|---|---|---|---|---|---|---|---|---|
| XCLogParser | 1,852 | 2026-10-27, active (v0.2.50) | Swift | xcactivitylog (SLF) | JSON, flatJson, summaryJson, HTML, chromeTracer, issues | step/target/file; Swift fn times only via flags and currently broken (#190) | Parses; Swift timing broken | Both | No | No |
| XCMetrics | 1,161 | 2024-04-26, dormant | Swift | xcactivitylog via XCLogParser | Postgres + (Grafana you build) | target/step history | Broken on 15.3/16.1 (open issues) | Both, needs backend | No | No |
| BuildTimeAnalyzer | 4,342 | 2026-03-08, maintenance | Swift | `-debug-time-function-bodies` log lines | macOS GUI table | function/expr per file | Unreliable ("No Valid Logs Found") | Local only | No | No |
| xcode-build-times-rendering | 334 | archived 2025-03 | Ruby/JS | injected start/end script phases | Gantt HTML | target | Dead | Local | No | No |
| xcprofiler | 343 | 2019-10-11, abandoned | Ruby | xcactivitylog + `-debug-time-function-bodies` | CLI table, JSON | function | Stale | Both | No | No |
| XcodeBenchmark | 3,683 | 2026-10-16, active | Python/sh | fixed corpus build | leaderboard tables | whole-machine | Yes | Local | n/a | n/a |
| XCBuildStats | 0 | 2026-10-27 (new) | Swift | LogStoreManifest.plist + process watch | menu bar, SQLite, CSV, `--report` | whole-build totals | Yes | Local | No | No |
| maj07k1/build-time | 0 | 2026-10-21 (new) | Swift | manifests/xcactivitylog, SwiftPM build.db, npm logs | menu bar, ranked targets | target/module | Yes | Local | No | No |
| Xcode Build Timeline / Timing Summary | built-in | n/a | n/a | in-memory build graph | GUI timeline, text summary | task | Yes | Local (GUI) | Partial (visual only) | No |
| Tuist Build Insights | 5,852 (repo) | 2026-10-30, active | Elixir/Swift | xcactivitylog + xcresult via post-action | hosted dashboard | module, file | Yes | Both, needs account/server | No | No |
| RocketSim Build Insights | closed source | commercial | Swift | not disclosed | app + team dashboard | whole-build P75/P95 | Yes | Both | No | No |
| Bitrise Insights/Build Cache | closed | commercial | n/a | CI metadata, Xcode wrapper | dashboards, invocation compare, AI summary | workflow/invocation | Xcode 26 caching | CI (+ local wrapper) | AI summary (claimed) | Not shown |
| AvdLee build skill | 1,266 | 2026-09-14, active | Python/md | benchmarks + timing summary + project files | `optimization-plan.md` | project/build-setting/hotspot | Yes | Local | Heuristic | Yes, with approval |
| Bazel + rules_xcodeproj | 26,017 / 628 | active | Java/Swift | n/a (build system) | remote cache, BEP, profile | action | Yes | CI-first | n/a | n/a (replaces build system) |
| XCRemoteCache | 872 | 2024-07-10, stale | Swift | n/a | cache | target | New Swift driver unsupported | CI-first | n/a | n/a |
| xcbeautify / xcpretty | 1,553 / 4,032 | active / 2025-03 | Swift / Ruby | xcodebuild stdout | pretty logs, JUnit | none | Yes | CI | No | No |
| Periphery | 6,180 | archived 2026-08 (commercial) | Swift | index store | unused-code report | symbol | n/a | Both | n/a | n/a |

---

## 4. Gap analysis - what nobody does well

1. **Explaining WHY a build was slow (causal, not descriptive).** Every tool says "X took N seconds." None say "X was slow because it waited 40 s on target Y, whose Swift module emit blocked 12 dependents" or "this incremental build recompiled 212 files because header H changed." Apple's own tool is visual-only; the incremental "why" lives in obscure flags (`-driver-show-incremental`) that Xcode may filter, and in the new SwiftPM `--enable-task-backtraces`.
2. **Dependency-graph critical path and bottleneck targets.** Apple defines critical path but does not compute it. XCLogParser's HTML/timeline gets misleading under the new build system (#148, #175; 15K "targets" for a 100-pod project). Gradle/Bazel tools do this; no Xcode OSS tool does. Ranking "targets whose speedup would shorten the critical path" (and "what-if" estimates) is open.
3. **Module-level attribution.** Best available is per-target totals in XCLogParser/Tuist. No one attributes time to SwiftPM modules vs app target vs macro plugins vs script phases vs asset catalogs vs link, nor to the *owner* (as Android's Plugins view does).
4. **Per-file/function culprit ranking under batch mode.** Xcode batches Swift files, so per-file timings are not attributable ("The fact that the batch steps get nothing more than overall time makes it very hard to find slow building file" - Jon_Shier, Swift Forums, 2026). Existing tools either require flags that no longer work (#190) or require disabling batch mode, which slows the build and distorts results. A tool that does a targeted, cheap re-measurement (e.g., disable batch mode only for the top-K batches) or ingests the upcoming `-emit-time-trace-path` data would fill this.
5. **Incremental-build culprit ranking.** Most pain is the edit-build-run loop, but analyzers focus on clean builds. Nobody ranks "files/targets that most often trigger large rebuilds" (change-impact/fan-out) or detects zero-change-build overhead (script phases without inputs/outputs, plugins running every time). The AvdLee skill lists zero-change overhead as a check but only point-in-time.
6. **SwiftUI/type-check hotspots.** Only flags (`-warn-long-*`) and old function-body timing tools. No tool correlates hotspot -> concrete rewrite pattern, and none tracks the effect of Xcode 27's ContentBuilder changes across versions.
7. **Actionable, auto-applicable fixes with verification.** Only the AI skill does plan -> approve -> apply -> re-benchmark, and it is LLM-driven with no deterministic attribution engine and no history. Nothing offers deterministic fixes such as declaring script-phase inputs/outputs, enabling `FUSE_BUILD_SCRIPT_PHASES`, eager linking, splitting the one target that gates the critical path.
8. **CI vs local in one tool.** Trackers are local-only (XCBuildStats, build-time, RocketSim local); backends (XCMetrics, Tuist) require infrastructure/accounts and post-action plumbing that breaks on failed builds, shell PATH, Xcode Cloud (#7543). No simple "xcodebuild + resultBundlePath -> diff vs main-branch baseline -> PR comment" CLI with zero backend.
9. **Build-vs-build diff / regression attribution.** Gradle has it. Xcode OSS tools have none. Bitrise has an "invocation compare" (closed). Needed: diff two builds down to "which targets/files/phases changed time, which Xcode/SDK/flags changed."
10. **Robustness to Xcode/format drift.** XCLogParser's SLF parser breaks across Xcode releases (15.0.1, 15.3, 16.0/16.1) and bleeds memory; XCMetrics inherits this. A new tool needs a tolerant parser, a fixture corpus per Xcode version, and a fallback to other sources (timing summary, `build.db`, xcresult, SwiftPM trace events).
11. **History that survives DerivedData purges.** Only XCBuildStats/build-time store their own history, and only while their app is running.
12. **Standard export formats.** Perfetto/Trace Event JSON exists in XCLogParser (`chromeTracer`) but OpenTelemetry (#188) is unmet.

---

## 5. What developers say they wish existed (quotes, with sources)

- "many target seems build take a long time ... but they not, just wait for dependency build" - wudijimao, XCLogParser #175, 2022. https://github.com/MobileNativeFoundation/XCLogParser/issues/175
- "Each target is now starting with a `Create directory Target.framework` and `Create directory Headers` step." - Craig Siemens, XCLogParser #148, 2021 (timeline now misleading). Another commenter: "nearly 15K targets, making the timeline unreadable" (paraphrase of samuelsainz's report). https://github.com/MobileNativeFoundation/XCLogParser/issues/148
- "The fact that the batch steps get nothing more than overall time makes it very hard to find slow building file." - Jon_Shier, Swift Forums SwiftPM pitch, June 2026. https://forums.swift.org/t/pitch-swiftpm-build-performance-debugging-options/87369
- Batch mode "shares parsing and type-checking costs across files", so per-file attribution is "Not really" possible; the workaround `-Xswiftc --disable-batch-mode` "usually slows the build" (Owen Voorhees, same thread; quote shortened/paraphrased).
- "it emits many thousands of lines of output, which is hard to sift through" - on `-debug-time-function-bodies`, Swift Forums, June 2023. https://forums.swift.org/t/tools-for-profiling-long-compile-times/65350
- "Ideally, you would be notified automatically when a build becomes slower" - Antoine van der Lee, SwiftLee, 2025-10-27 (upd. 2026-03-30). https://www.avanderlee.com/optimization/analysing-build-performance-xcode/
- "I would love the ability to know if a build is associated with a specific git branch" - schlagelk, XCMetrics #9, 2021 (wants regression-per-PR). https://github.com/spotify/XCMetrics/issues/9
- Request for OpenTelemetry output: "there is everything to create traces in the [OTEL format]" and send "build profiling data to nearly any Observability tooling" - secustor, XCLogParser #188, 2023. https://github.com/MobileNativeFoundation/XCLogParser/issues/188
- "Build times should be cumulative" (files appear multiple times because of target dependencies) - BuildTimeAnalyzer #26, 2016. https://github.com/RobertGummesson/BuildTimeAnalyzer-for-Xcode/issues/26
- Merged-but-unreleased fix: "a new release incorporating the fix is not yet available" - XCLogParser #226, Feb 2025 (maintenance/distribution friction). https://github.com/MobileNativeFoundation/XCLogParser/issues/226
- Incremental-build "why" is hidden: Swift Forums thread (2021) where users add `-driver-show-incremental` but remarks do not appear in Xcode's log. https://forums.swift.org/t/optimizing-and-debugging-incremental-build-time-in-swift-5-5/49379
- Frustration with Xcode builds in HN comments (e.g., "Xcode Is the Worst Piece of Professional Software I Have Ever Used" thread, 2025-09; comments say Swift is "undermined by Xcode's slow builds"). These are sentiment only, not tool requests. https://news.ycombinator.com/item?id=45338087
- Reddit (r/iOSProgramming, r/swift): NOT accessible via the tools available (reddit.com blocked for fetch/search). No Reddit quotes in this report.

---

## 6. Design implications for a new CLI (inferences, not sourced facts)

- Inputs, in priority order: xcactivitylog (tolerant SLF parser), xcresult, `-showBuildTimingSummary` text, SwiftPM `--trace-events-file` JSON + task backtraces, Swift frontend time-trace (when it ships), `-stats-output-dir`, clang `-ftime-trace`, SwiftPM `build.db`.
- Outputs: terminal ranked tables + Perfetto trace JSON + stable JSON schema + single-file HTML + PR-comment markdown; optional OTel later.
- Differentiators to build first: (1) critical-path computation and "what-if", (2) incremental-build trigger/fan-out analysis, (3) build-vs-build diff, (4) batch-aware per-file attribution, (5) deterministic fix suggestions with a verify step (re-measure), (6) zero-backend CI mode with a baseline artifact.
- Risk: Apple is moving (SwiftPM trace events, task backtraces, compilation caching, ContentBuilder). Design a source-adapter layer so format changes do not break the core.

---

## 7. Conflicts, gaps, unverified

- "Last commit" dates are API `pushed_at`; I did not verify individual commit contents except for BuildTimeAnalyzer (last commits 2026-03-08) and XCLogParser (v0.2.50 notes).
- BuildTimeAnalyzer latest release (v1.0.12, June 2019) comes from a search summary, not the GitHub releases page.
- XCLogParser SLF byte-level format: README links a format doc I could not fetch (404 at guessed path). Details of the SLF grammar are therefore not in this report.
- XCLogParser README says Xcode 16.4 / Swift 6.0 required; Xcode 27 compatibility not verified.
- Tuist's internal parsing approach, pricing, and Xcode 26/27 coverage: not verified from docs.
- RocketSim's capture mechanism and pricing: not on the fetched page.
- Bitrise "AI summaries" in invocation compare: stated in Bitrise's blog; a separate search found no corroborating Insights UI evidence.
- Compilation caching performance: sources disagree (one guide claims 20-40% faster clean builds; another December 2025 test found clean builds slower with caching on). Treat as unsettled.
- Xcode "Recent" build duration behavior and log retention: from XCBuildStats README only.
- xcpretty timing support, Buck2 iOS maturity, Cirrus/Rugged: not verified or found.
- SE-0545: mentioned in the Swift forums thread; proposal text/status not verified. swiftlang/swift PR #88251 was open as of my fetch (last update 2026-05-19); may have merged since.
- Reddit and many large SEO sites were unreachable; HN search found no Show HN for an Xcode build-time analyzer (HN Algolia: top hits are old BuildTimeAnalyzer submissions with 1 point each).
- Emerge Tools: only product pages found; absence of a build-time product is based on search, not an exhaustive site review.

## Source index
- GitHub API repo/release pages (fetched 2026-10-30): https://api.github.com/repos/{MobileNativeFoundation/XCLogParser, spotify/XCMetrics, RobertGummesson/BuildTimeAnalyzer-for-Xcode, giginet/xcprofiler, devMEremenko/XcodeBenchmark, tuist/tuist, peripheryapp/periphery, cirruslabs/tart, spotify/XCRemoteCache, cpisciotta/xcbeautify, xcpretty/xcpretty, aras-p/ClangBuildAnalyzer, MobileNativeFoundation/rules_xcodeproj, facebook/buck2, gradle/gradle-profiler, bazelbuild/bazel, realm/SwiftLint, AvdLee/Xcode-Build-Optimization-Agent-Skill, filipvlasic/XCBuildStats, maj07k1/build-time, matopeto/xcode-build-times, Iron-Ham/XCLogParser}
- GitHub search API: https://api.github.com/search/repositories?q=xcode+build+time ; ?q=xcactivitylog
- https://github.com/PaulTaykalo/xcode-build-times-rendering
- https://developer.apple.com/videos/play/wwdc2022/110364/ ; https://developer.apple.com/wwdc26/guides/swiftui/ ; https://developer.apple.com/videos/play/wwdc2026/258/
- https://tuist.dev/en/docs/guides/features/build-insights/xcode ; https://tuist.dev/en/docs/guides/features/cache ; https://community.tuist.dev/t/tuist-build-insights/609
- https://bitrise.io/blog/post/lifting-the-hood-on-build-cache-for-xcode ; https://bitrise.io/blog/post/q3-2026-product-update
- https://rocketsim.app/features/build-insights/ ; https://www.avanderlee.com/optimization/analysing-build-performance-xcode/
- https://forums.swift.org/t/pitch-swiftpm-build-performance-debugging-options/87369 ; https://github.com/swiftlang/swift/pull/88251
- https://developer.android.com/build/build-analyzer ; https://develocity.ai/develocity/product/performance-insights/ ; https://doc.rust-lang.org/cargo/reference/timings.html ; https://github.com/aras-p/ClangBuildAnalyzer ; https://github.com/nico/ninjatracing
- https://www.infoq.com/news/2023/10/spotify-bazel-ios-transition/ ; https://blog.allegro.tech/2020/12/speeding-up-ios-builds-with-bazel.html
