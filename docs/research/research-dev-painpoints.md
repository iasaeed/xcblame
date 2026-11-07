# How iOS developers experience and fight slow Xcode builds (2023 to Oct 2026)

Research date: 2026-10-30. Feeds UX/product design for a build-time analysis CLI.

## Method and coverage caveats (read first)

- About 45 distinct pages read (Swift Forums, Apple Developer Forums, Hacker News, GitHub issues, company engineering blogs, vendor docs).
- **Reddit (r/iOSProgramming, r/swift, r/Xcode) and Stack Overflow were NOT reachable.** The search tool blocks both domains and WebFetch refuses them. So there are no direct Reddit or SO quotes or vote counts. Substitutes: Swift Forums, Apple Developer Forums and HN. Treat "what got upvoted" as unanswered. HN is the closest proxy.
- **Medium and several vendor blogs returned HTTP 403.** Airbnb, Pinterest, Gojek, Qonto, Trendyol, Delivery Hero, Back Market and Dimillian's xcodebuild post are affected. Numbers for those come from search-engine snippets of the page and are marked `[snippet]`. Verify before quoting externally.
- Direct quotes are kept to 15 words or fewer. Paraphrases are marked "paraphrase".
- No company posts were found for: Shopify, Wise, Revolut (only an unverified listing line), Headspace, Reddit, SoundCloud, Slack, Dropbox, Bumble, Zalando, N26, Tokopedia, Kakao, Cookpad, Robinhood, Instacart, DoorDash, Tinder, Skyscanner, Babylon, Just Eat. Monzo has only a vendor headline.
- Xcode 27 appears to have shipped around 2026-09-14 (single secondary source: https://blakecrosley.com/blog/xcode-27-release `[snippet]`). Xcode 26.x and 27.x data below are very recent and thin.

---

## (A) Ranked pain points, with evidence

Ranking is my judgement of frequency and intensity across the sources read. It is not a measured vote count.

### 1. "Incremental" builds that do far more work than the edit justifies
- Swift Forums, Xcode 26: no-change builds taking 5-6 minutes. One user said "A single newline can cause a rebuild of virtually our entire app." One 375-module project saw a no-change build take 127s instead of 15s while re-planning 108 modules. https://forums.swift.org/t/slow-incremental-builds-because-of-planning-swift-module/84803 (2026)
- Apple's Owen Voorhees in that thread: replanning every module with no compiles usually means inputs are being changed unexpectedly, for example a linter touching timestamps. That is a cause the developer cannot see from inside Xcode.
- Apple Dev Forums, Xcode 14.2: incremental builds got slower after each rebuild, over 1 minute for a dozen-file project. Zero replies. The author downgraded to Xcode 13.4.1. https://developer.apple.com/forums/thread/723238 (Jan 2023)
- Apple Dev Forums: files rebuilt on the second build and settled only on the third. Zero replies. https://developer.apple.com/forums/thread/693285 (2021)
- Apple Dev Forums, Dec 2025: Xcode 26 CI Mac mini does a full rebuild every time, about 6 minutes slower than local. Zero replies. https://developer.apple.com/forums/thread/810306
- Toss (about 1,000 modules): before the compiler does real work, Xcode spends long computing the graph and planning. Trimming scripts and settings "helped only slightly" because cost scales with module count. https://tuist.dev/customers/toss

### 2. "I cannot tell WHY it rebuilt or WHAT is slow" (diagnostics gap)
- Swift Forums: a developer with about 350 files and no dependencies could not find per-file timings. The `-warn-long-function-bodies` flags produced nothing. https://forums.swift.org/t/investigating-slow-builds/71142 (paraphrase)
- Jon Shier in the same thread: type-check flags do not reach Swift packages. He also found an 8s Info.plist step and a 5s blocking script, which the type-check flags cannot reveal.
- fastred's widely linked guide: Xcode has no UI to rank files by compile time, so you run the CLI with flags and sort with awk. https://github.com/fastred/Optimizing-Swift-Build-Times (paraphrase)
- Asana: the team could not get reliable data from Xcode build logs on how module type affected build duration. https://asana.com/inside-asana/scaling-a-mature-ios-codebase-with-tuist (paraphrase)
- "Task Backtraces" (a Build Debugging setting) is the official "why did this task run" answer. Two posters in the 84803 thread did not find the backtraces in their logs (Xcode 26.4 beta).
- Actondon (Jun 2025): tracing over-rebuilds means reading `swiftdeps` YAML. SPM has no timing summary. https://actondon.com/blog/swift-build-time-improvement-research (paraphrase)
- Summed task times mislead. One article showed 281s of Swift compile inside a 37.3s clean build because tasks run in parallel. https://www.avanderlee.com/optimization/analysing-build-performance-xcode/

### 3. Swift macros and swift-syntax
- Swift Forums: first build went from about 30s to 5+ minutes. Another report: a no-op macro doubled Release CI from about 15 to about 30 minutes. https://forums.swift.org/t/compilation-extremely-slow-since-macros-adoption/67921
- Macros are re-expanded in the emit-module step. One user reported a "33.4s emit module cost for every incremental build." As of 2026 a poster said "No progress." https://forums.swift.org/t/swift-macros-build-time-overhead-concerns/70443
- In the Xcode 16.1 thread, Slava Pestov found that two thirds of `-emit-module` time was macro expansion. https://forums.swift.org/t/swift-6-xcode-16-1-slower-build-times/75707
- Prebuilt swift-syntax (Xcode 26) fixed much of the clean-build cost, but it is fragile. Xcode 27 built swift-syntax 603.0.2 from source, about 25s slower. The reporter later said it no longer occurred. https://github.com/swiftlang/swift-syntax/issues/3440 (Sep 2026)
- A macro-plugin input-order bug forces re-planning when a module loads 2+ macro plugins. The fix ships in Xcode 27 (84803 thread).

### 4. Swift type checker and SwiftUI view bodies
- HN, 2024-2026: "SwiftUI leans heavily on the compiler" (wrasee, paraphrase). Others: the error "makes type mistakes hard to locate" (Hamuko, paraphrase). Split views is the top mitigation. https://news.ycombinator.com/item?id=42135492 and https://news.ycombinator.com/item?id=40757411
- A 5-term arithmetic expression took 6-11s in a one-line example (lovasoa, ks2048). The same HN thread found the real-project hit rate is low: one commenter's slowest expression in a 1,014-line project took 3 ms. Consensus is that pathological cases are rare but brutal.
- Apple Dev Forums (Xcode 13 thread, still active to 2025): a clean build dropped from 35 minutes to 206s after fixing slow expressions. This was the largest documented single gain in that thread. https://developer.apple.com/forums/thread/690573
- Apple DTS says the root cause is flexible inference plus untyped literals plus operator overloading. Typical fix: annotate or split the expression. Sources: https://developer.apple.com/forums/thread/766252, https://developer.apple.com/forums/thread/793866 `[snippet]`

### 5. Every Xcode release brings a regression (trust problem)
- "Another year, another swift release, another huge regression" (DeskA, Xcode 16.1). Jon Shier: "impossible to tell if they're Swift or Xcode regressions." https://forums.swift.org/t/swift-6-xcode-16-1-slower-build-times/75707
- Apple Dev Forums on Xcode 13: reports of 10-20x slower builds, no official fix. https://developer.apple.com/forums/thread/690573
- Azure CI: 14m14s on Xcode 16.1 vs 40m55s on Xcode 26.0 (package resolution 2m52s vs 7m31s). Workaround was pinning Xcode 16.4. Maintainers said it is "external to us." https://github.com/actions/runner-images/issues/13096
- Xcode 16 workarounds were trial and error: delete the "Predictive Code Completion Model", or set `CLANG_ENABLE_EXPLICIT_MODULES=NO`. https://developer.apple.com/forums/thread/766471
- Not all regressions are real or permanent. `xcodebuild` incremental builds were slow because of network provisioning calls (7s vs 1s on an empty project). Xcode 26.0 fixed it. https://www.developer.apple.com/forums/thread/756120

### 6. Fixed-cost phases nobody notices (scripts, lint, dSYM, assets, signing, plugins)
- AutoScout24: moving SwiftLint to a pre-commit hook saved about 19s per build. Disabling the integrated Swift driver (`SWIFT_USE_INTEGRATED_DRIVER=NO`) cut incremental builds from 103s to 18s. Apple's own incremental-build advice "gave little benefit." https://tech.autoscout24.com/blog/posts/xcode-build-time-optimization/ (Xcode 14 era)
- SwiftLee: a Sentry dSYM upload script ran on every Debug build (6.3s). A newly added script cost about 6s "without anyone noticing." SwiftLint ran about 10s per incremental build. A prebuilt package plugin invalidated the cache. https://www.avanderlee.com/optimization/analysing-build-performance-xcode/
- Asset catalogs: splitting assets into bundles cut asset compile from one minute to 8s. Multiple catalogs in one target still compile serially. (84803 thread)
- Swift Forums: Thread Sanitizer "saved us a huge amount of time" when turned off. Module Verifier and explicit modules were also toggled. (75707 thread)

### 7. Modularization and big package graphs: not a free lunch
- Wealthfront (M2 Max, 64GB, macOS 26.2, about 2,000 Swift files): fresh build 2m39s, incremental 39s. The biggest incremental cost is "Emitting Module" at 14.6s. CI runs fresh builds because CocoaPods and SPM side by side corrupt artifacts. https://eng.wealthfront.com/2026/03/02/xcodegen-and-the-quest-to-modularize-the-wealthfront-ios-app/
- andrevini: a mostly linear dependency chain gains little. Over-modularizing "can eat into" the gains. Heavy-generics files will not be fixed by modules. https://andrevini.dev/blog/modularization-at-scale
- Explicit modules: synthetic benchmark 149s without vs 2,595s with (Xcode 16.1). Apple's engineer said it is synthetic and suggested overriding `COMPILER_WORKING_DIRECTORY`, claiming over 3x improvement. https://forums.swift.org/t/build-times-regression-with-explicitly-built-modules/77073
- Xcode 27.2: resolving a 524-package workspace took 280s. Xcode reportedly deadlocks near 500 git repos with Source Control on. https://github.com/swift-institute/Issues/issues/200 (27 Oct 2026, an unusual extreme workspace)
- HN: Xcode and SPM have "such a rough time with multiple targets" (JackYoustra, paraphrase). https://news.ycombinator.com/item?id=46841752 (2026)

### 8. Clean builds dominated by dependencies and branch churn
- Allegro: developers averaged 8 clean builds per day, about 40 minutes of lost work per day. https://blog.allegro.tech/2020/12/speeding-up-ios-builds-with-bazel.html (2020, old)
- LINE: Carthage deps built locally "typically 15-20 minutes". Developers often cleaned to fix problems, discarding artifacts. https://engineering.linecorp.com/en/blog/improving-build-performance-line-ios-bazel/ (2019-20, old)
- Lyft: commit churn means developers often face near-clean builds after pulling main. https://semaphore.io/blog/keith-smiley-bazel
- Expo: precompiled React Native cuts clean RNTester builds from about 120s to about 10s on an M4 Max. https://expo.dev/blog/precompiled-react-native-for-ios (2025)

### 9. CI minutes and cost as the forcing function
- GitHub macOS runner pricing was cut to $0.062/min in Jan 2026 (from $0.08) per vendor aggregators `[snippet]`: https://www.warpbuild.com/guides/github-actions-macos-runner-cost
- One indie team estimated $4,167/month on GitHub-hosted runners (28,723 minutes in 17 days). They moved to self-hosted Mac minis (about $64/month). They said the incentive had become "backwards": more tests meant higher cost. https://jeffverkoeyen.com/blog/2025/10/17/SelfHostingMacMinis/
- Spotify: PR feedback dropped from 80 to 20 minutes. Lyft: about 100 Mac minis, which cannot autoscale, so a handful of concurrent PRs saturates CI.
- Bitrise suggests a build-time objective with alerts. Its example is "no build over 10 minutes." Vendor claim. https://bitrise.io/blog/post/expert-tips-to-speed-up-your-ios-builds

### 10. SwiftUI Previews rebuild too much
- Apple developer-tools engineer's answer: split into smaller modules and put UI at a leaf of the dependency graph (WWDC23 session 10252). Poster: Firebase-type deps slowed previews. https://developer.apple.com/forums/thread/740200
- monday.com gives every module its own preview app. https://tuist.dev/customers/monday
- Cross-file previews recompile the whole module, per Blueprint docs `[snippet]`.

### 11. "Apple will not look at this" (feedback black hole)
- Jon Shier: he cannot share his codebase, so bug reports "go no where." (84803 thread)
- The three Apple forum threads in #1 each have zero replies.
- Fixes found by a community member (Steffen, 375 modules) were two upstream bugs in swift-build and swift-driver, discovered by profiling. Apple's fixes ship in Xcode 27.

### 12. Hidden defaults and conflicting advice
- fastred: "Assuming defaults are right" is a listed mistake. Check architecture and optimization settings yourself. (paraphrase)
- Actondon: guidance on WMO in Debug conflicts, and the mechanism of the trick is inferred. (paraphrase)
- SwiftLee: Xcode 26 compilation caching is opt-in, so easy to miss. Enabling it makes the first clean build slower (the Helm app went 86s to 91s clean, but incremental 70s to 9s). https://www.avanderlee.com/xcode/xcode-build-optimization-using-6-agent-skills/

### 13. Migrating to Bazel or Tuist: IDE and tool friction
- Mercari: "Xcode is notoriously hard to integrate with an external build system." They support Bazel only. https://engineering.mercari.com/en/blog/entry/20221215-16cdd59909/
- Grab: iOS remote builds abandoned because iOS builds only run on Apple hardware. Bazel added IDE gaps (indexing, jump to definition). https://engineering.grab.com/how-grab-is-blazing-through-the-super-app-bazel-migration
- Asana: Tuist is complex and only a minority of engineers are comfortable. `git checkout` became 5-15s slower. monday.com: "Restructuring the project often felt like fighting the tool."
- Lyft: Bazel needs at least one dedicated maintainer.
- Qonto rejected Bazel on setup complexity and learning curve `[snippet]`: https://medium.com/qonto-way/choosing-the-right-tool-to-modularize-our-ios-codebase-869a8ef568b8

### 14. Editor responsiveness mistaken for build speed (low confidence)
- Reports of SourceKitService at 100-200% CPU, typing lag, and endless indexing, with `IDEIndexDisable` and DerivedData deletion as folk cures. Sources are old Apple forum threads, Xcode 7 to 16.3 `[snippet]`: https://developer.apple.com/forums/thread/691427. I found no authoritative explainer separating indexing from building.

### 15. Hardware and environment gotchas
- Rosetta: one Xcode 13 build took 15,800s with Rosetta enabled vs 505s disabled. https://developer.apple.com/forums/thread/690573
- Network-mounted DerivedData and low free SSD space reduce cache hit rates (Bitrise tips).
- Laptops about 50% slower than CI minis (Allegro).

### 16. Per-expression timing flags have their own cost and caveats
- The flags add overhead and do not reach SPM packages. Use `-Xswiftc` for packages. Total build time does not reveal which expressions are slow (Actondon, 71142 thread).

Notes: not enough evidence for a separate ranked "SPM resolution" item beyond #7. I saw a swift-protobuf issue (1s to 18s resolve) only as a snippet. I saw no top-voted Stack Overflow answers on "Xcode slow build".

---

## (B) Case-study table

Times are as reported in the cited post. "Snippet" means I could not open the primary page.

| Company | Scale | Clean (before to after) | Incremental / CI (before to after) | Interventions that mattered most | Tooling | Source |
|---|---|---|---|---|---|---|
| Spotify (2022-23) | 200+ eng, multimillion LOC, 800+ test targets, about 3M LOC in biggest CI config | Not given | CI feedback 80 to 20 min; largest CI config 45+ to under 10 min; local p75 about 30s | (1) Bazel with BUILD files generated from existing YAML (2) remote cache + RBE (3) affected-test selection | Bazel, BuildBuddy, rules_xcodeproj, bazel-diff | https://engineering.atspotify.com/2023/10/switching-build-systems-seamlessly |
| Mercari | about 2.17M LOC Swift, close to 1,000 modules | Debug full 247-256s; remote cache about 75s; RBE + cache about 37-46s (M1 Pro) | No Xcode baseline; Xcode may be as fast locally | Remote cache, RBE on a few hundred Apple silicon machines, Bazel-only | Bazel, rules_xcodeproj, BuildBuddy | https://engineering.mercari.com/en/blog/entry/20221215-16cdd59909/ |
| Lyft | 15-20 to 60 iOS eng, 10 apps in monorepo | Rider app about 15 to about 2 min (remote cache) | CI on about 100 Mac minis | Monorepo, remote cache, query-based test selection | Bazel | https://semaphore.io/blog/keith-smiley-bazel |
| Uber (2017-19) | 500K-1M LOC shipping, about 350 modules | 30-45 to 5-10 min over a couple of years | Batch mode 25% slower than WMO at about 300 modules | Build config, compiler upgrades, hardware, Buck | Buck, Uber Poet | https://www.uber.com/us/en/blog/uber-poet/ (about 8+ years old) |
| LINE (2019-20) | 1.4M+ LOC, hundreds of modules | Beta build avg 30.96 to 14.53 (units not stated, probably min) | No incremental figures | Replace local Carthage builds with Bazel static frameworks + remote cache | Bazel, XcodeGen | https://engineering.linecorp.com/en/blog/improving-build-performance-line-ios-bazel/ |
| Allegro (2020) | 300K LOC ObjC+Swift, 25 devs | 260s to 85s | 8 clean builds/day per dev | Bazel, remote cache, workspace generator excludes modules | Bazel | https://blog.allegro.tech/2020/12/speeding-up-ios-builds-with-bazel.html |
| Grab | 700+ iOS targets, 30K+ unit tests | "dozens of minutes" clean | Xcode incremental under a couple of min | Critical-path reduction (7-10%), test impact analysis (-90% tests, -30% pipeline), Bazel | Bazel | https://engineering.grab.com/how-grab-is-blazing-through-the-super-app-bazel-migration |
| Asana (2023) | 300K LOC Swift, about 10 eng | Not given | Incremental median 45 to 15s (feature); Inbox 30-50 to 4s | (1) Move deps off CocoaPods (2) Tuist-generated modules (3) interface/impl split to break cycles | Tuist, SPM, Carthage | https://asana.com/inside-asana/scaling-a-mature-ios-codebase-with-tuist |
| monday.com | about 200 modules, about 20 eng | Not given | CI merge workflow 20+ to about 9 min (2022 to now) | Tuist, module cache, per-module preview apps | Tuist | https://tuist.dev/customers/monday (vendor-published) |
| Toss | about 1,000 modules | Not given | Local builds under 1 min more than tripled as a share | Binary XCFrameworks for untouched modules, remote cache, CI guard on cacheable share, remove unused imports | Tuist, self-hosted cache | https://tuist.dev/customers/toss (vendor-published, no absolute times) |
| AutoScout24 (Xcode 14) | Large mixed ObjC/Swift | 185s to 91s | One-line change 103s to 18s | (1) `SWIFT_USE_INTEGRATED_DRIVER=NO` (2) SwiftLint to pre-commit hook | Build Timeline | https://tech.autoscout24.com/blog/posts/xcode-build-time-optimization/ |
| Wealthfront (2026, baseline only) | about 2,000 Swift files, 15 eng | 2m39s (M2 Max) | Incremental 39s; tests 8-9s | Planned modularization | XcodeGen | https://eng.wealthfront.com/2026/03/02/xcodegen-and-the-quest-to-modularize-the-wealthfront-ios-app/ |
| Expo / RN (2025) | n/a | RNTester about 120 to about 10s; Expo Go 146 to 91s | n/a | Precompiled React Native | XCFrameworks | https://expo.dev/blog/precompiled-react-native-for-ios |
| HN commenter "shepting" (anonymous) | 1M-line Swift | CI clean 22 to 4.5 min | n/a | Buck or Bazel + HTTP remote cache | Buck, Bazel | https://news.ycombinator.com/item?id=21165154 (2019) |
| Delivery Hero `[snippet]` | about 115 modules | 2.5 to 0.5 min | Incremental 30s to 10-15s; CI 2.5x | Tuist | Tuist | https://deliveryhero.jobs/blog/scaling-ios-application-development-with-tuist/ |
| Trendyol `[snippet]` | n/a | n/a | CI 30 to 10 min (65%) | Tuist binary cache + selective testing | Tuist | https://tuist.dev/blog/2024/12/16/trendyol |
| Pinterest `[snippet]` | n/a | Clean 4m38s to 3m38s; remote cache under 1 min | "No clean build on CI in over a year" | Bazel + remote cache | Bazel | https://medium.com/pinterest-engineering/developing-fast-reliable-ios-builds-at-pinterest-part-one-cb1810407b92 |
| Gojek `[snippet]` | n/a | n/a | CI p50 about 30 to about 10 min | Bazel with Xcode fallback | Bazel | https://medium.com/gojekengineering/gojeks-journey-to-3x-faster-ios-builds-with-bazel-90fbe3f22f81 |
| Qonto `[snippet]` | n/a | "about 50%" after about 6 months; snippets conflict on absolute minutes | n/a | Module extraction; rejected Bazel | Tuist-style tooling | https://medium.com/qonto-way/modularization-72f2838d2ee7 |
| GitHub (iOS tests) `[snippet]` | n/a | n/a | Test time 38 to 15 min | Apple silicon runners + split by module | Actions | https://github.blog/engineering/infrastructure/how-github-reduced-testing-time-for-ios-apps-with-new-runner-features/ |
| Airbnb | n/a | **No minute numbers verified** | "notable improvements, especially incremental" `[snippet]` | Buck to Bazel, shared remote cache | Bazel | https://medium.com/airbnb-engineering/migrating-our-ios-build-system-from-buck-to-bazel-ddd6f3f25aa3 |
| Monzo / Chanel / Back Market (vendor pages) `[snippet]` | about 200 modules (Monzo) | Back Market: 35-40% faster with 3rd-party dep cache, up to 90% with full cache | Monzo: CI -70% (headline only) | Tuist caching | Tuist | https://tuist.dev/customers |

### Patterns across the table
- Two families of winner. **Big orgs** use Bazel or Buck with a remote cache and affected-test selection. **Mid-size teams** use Tuist or generated projects with binary or module caching. Both lean heavily on caching and on not building what was not touched.
- Interventions that recur most: (1) cache or reuse artifacts, (2) build or test only what changed, (3) cleaner dependency graph (interfaces, no cycles). Compiler-level tuning (type-check fixes) shows up in individual case studies (35 min to 206s), not in the company posts.
- Almost none report incremental numbers in a comparable way. Asana and Spotify gave the most direct figures. Asana reported the lack of reliable data from logs.
- Most posts are 2019-2023. The 2025-2026 evidence is mainly Swift Forums threads, SwiftLee's agent skill, Tuist and Wealthfront.

---

## (C) Thresholds and benchmarks

### What developers call slow (anecdotal; no survey data found)
- andrevini heuristic: clean builds over "2-3 minutes" plus slow incrementals suggest modularizing. Under "a minute" it probably is not needed. https://andrevini.dev/blog/modularization-at-scale
- Toss target: a change shows its result in under a minute.
- SwiftLee: a 3.9s incremental build is "acceptable"; 6s x 100 builds x 10 devs is about 1h40m waiting per day. His rule of thumb: 1s per build adds up to a minute every 60 builds. https://www.avanderlee.com/optimization/analysing-build-performance-xcode/
- SwiftLee agent skill author: 1 second saved on a 30s incremental at 50 builds/day is about 3.5 hours per developer per year (his estimate).
- Spotify local goal: p75 about 30 seconds. Asana: median 15s for a feature change.
- CI: Bitrise suggests under 5 to 10 minutes per build and "10 minutes or less" for PR pipelines (vendor claim). Many hosted-CI reports in the tens of minutes.
- Type-check warning thresholds in guides: 100 ms per function or expression (fastred, SwiftLee). `danger-xcprofiler` defaults are 50 ms warn and 100 ms fail `[snippet]`.
- Frequency of clean builds: Allegro measured 8 per day per developer (2020). No other measured figure found. fastred says developers clean "more than expected," e.g. after switching branches.

### XcodeBenchmark (clean Release build of a large project, wall-clock seconds, lower is better)
Source: https://github.com/devMEremenko/XcodeBenchmark (read 2026-10-30). Benchmark project: framework with 76 CocoaPods libraries, about 975K LOC per the page. Each Xcode version has its own table. **Results are only comparable within the same Xcode version.** I transcribed one table by hand, so verify exact pairings before quoting.

Xcode 16.1-16.2:
| Machine | Seconds |
|---|---|
| M3 Ultra 32c (Mac Studio) | 66 |
| M4 Max 16c | 77-81 |
| M2 Ultra 24c | 87 |
| M3 Max 16c | 90 |
| M4 Pro 14c | 92-97 |
| M4 Pro 12c | 103-109 |
| M1 Ultra 20c | 106 |
| M2 Max 12c | 110-126 |
| M3 Pro 11-12c | 127-147 |
| M4 base 10c | 140-141 |
| M2 Pro 10c | 141 |
| M1 Max 10c | 148 |
| M1 Pro 10c | 152 |
| M2/M3 Air 8c | 184 |
| M1 Air | 202 |
| M1 MBP 13" | 242 |
| Intel i7 iMac 2019 | 349 |
| Intel i7 Mac mini 2018 | 490 |
| Intel i7 MBP 2014 | 1,003 |

Xcode 26.x:
| Machine | Seconds |
|---|---|
| M5 Max 18c | 84 |
| M5 Pro 18c | 89 |
| M4 Max 16c | 89 |
| M2 Ultra | 93 |
| M5 Pro 15c | 101 |
| M4 Pro 14c | 104-108 |
| M1 Ultra | 112 |
| M5 base | 146 |
| M4 Pro Mac mini 14c, 64GB | 146 |
| M4 Pro 12c | 164 |
| M5 Air | 173 |
| M4 Air | 188 |
| M1 Max | 188 |
| M1 Pro | 194 |
| M3 Air 8GB | 506 (outlier, probably memory-starved) |

Xcode 27.0:
| Machine | Seconds |
|---|---|
| M5 Pro 18c Mac mini | 90 |
| M4 Max 14c | 139 |
| M4 base Mac mini | 185 |

Calibration takeaways
- Same-tier Macs score slower on newer Xcode in this benchmark. Examples: M4 Pro 14c 92-97s on Xcode 16 vs 104-108s on 26.x. M4 Max 14c 92s (Xcode 16.1) vs 139s (Xcode 27.0). M1 Pro 152s vs 194s. These are different machines and runs, so this is suggestive, not proof of regression. A tool should always record the Xcode version alongside any "is my machine slow" verdict.
- M1 Pro to M4 Pro 14c is about 1.6x. Pro-to-Max and Max-to-Ultra gains are small (about 77 vs 66s). The step from an Intel i7 to Apple silicon is the big one.
- A base M-series Air is about 2x slower than a Pro/Max. 8GB configs can be catastrophic.
- Other 2025 data: Bitrise measured M4 Pro as "35% faster" than M2 Pro on this benchmark (Xcode 16.2). Vendor claim: https://bitrise.io/blog/post/expert-tips-to-speed-up-your-ios-builds
- Interactive chart (Xcode 26, fastest community run per chip, checked 2026-09-21): https://gauravsharma.com/coding/apple/xcode-benchmark/ (no numeric values extractable).

### Xcode compilation caching (Xcode 26, opt-in)
- Bitrise: up to 30% in its experience. SwiftLee's agent-skill table shows wide variance: Helm incremental 70s to 9s, Wikipedia 5%, Kickstarter and Dash within noise. https://github.com/AvdLee/Xcode-Build-Optimization-Agent-Skill
- Third-party figures (snippets): 24% Wikipedia, 36% Pocket Casts, up to 77% for a modular Tuist project. Not independently verified.
- A first cold build populates the cache and can be slightly slower.

---

## (D) Wish-list and implied product requirements

**Caveat:** I found no direct quotes using phrasing like "one command", "auto-fix" or "PR comment". The items below are inferred from (a) explicit complaints, (b) what adjacent tools chose to build, and (c) behaviour of the developers. Where a quote exists it is shown.

| What developers show they want | Evidence | Implied requirement for the CLI |
|---|---|---|
| "Show me which file or function" | fastred: no Xcode UI to rank files. Forum poster could not find per-file timings (71142). Type-check flags do not reach SPM packages. | Rank files, functions, expressions and targets by cost. Work without requiring manual flag edits. Handle SPM packages. |
| "Why did this rebuild?" | 84803 thread: Task Backtraces not visible in logs. Apple 693285 and 810306 threads have zero replies. Apple's answer was timestamps and changing inputs. | Report the cause chain for each re-run task: which input changed. Detect timestamp churn, scripts without outputs, macro-plugin ordering, module variants. Offer a "no-change build" mode that lists every task that ran. |
| "Don't make me parse logs" | `xclogparser` needs `-resultBundlePath`, extra flags for type-check data, and still reports alpha status. Tuist post-action needs PATH and `runPostActionsOnFailure` tweaks. | One command that finds the latest `.xcactivitylog` or runs the build itself with the right flags. Zero project edits by default. |
| "What should I change?" | AvdLee's skill is popular because it proposes a plan (40+ checks) and applies it after approval. AutoScout24's biggest wins (driver flag, SwiftLint) were not source changes. | Ranked recommendations with estimated seconds saved, confidence, and the exact setting or line. Separate "safe settings" from "needs code changes". |
| "Is it me, my machine, or Xcode?" | Version regressions (#5). Benchmark table shows the Xcode version dominates. | Record machine, Xcode, macOS and compare against XcodeBenchmark-like reference. Flag known-bad Xcode and swift-syntax combos. |
| "Explain in plain language" | Summed compile 281s inside 37s wall clock confuses (SwiftLee). Timeline needs zooming into serial blocks. | Show critical path and wall-clock share, not summed task time. Label parallel vs serial. Define terms inline (planning, emit module, explicit modules). |
| "Compare before/after" | Case studies rely on A/B tables. SwiftLee's skill runs 3 clean and 3 incremental builds and stores JSON. Clean-build noise (+5s "within noise") needs handling. | Repeat runs, median, noise band, and a diff report. Baseline file that is diffable in PRs. Distinguish cold-cache from warm-cache. |
| "Track over time / catch regressions" | RocketSim (P75, P95, per Xcode version) and Tuist build insights exist for this. AutoScout24: a 6s script added unnoticed. | History store, trend by commit and Xcode version, p75/p95. Alerting with noise filters (Airflow lesson). |
| "PR comment in CI" | CI cost pressure (#9). Danger plugins existed for per-function time. Tuist and RocketSim sources I read did not mention PR comments. | CI mode that posts a summary delta vs main, with a budget threshold. Works from `xcodebuild -resultBundlePath` output. |
| "Do not make me adopt Bazel/Tuist" | Mercari, Grab, Asana, monday.com friction. Qonto rejected Bazel on complexity. | Position as a lightweight analyzer that works on existing Xcode projects. |
| Safe, reviewable fixes | AvdLee: "nothing changes until approval". | Dry-run by default. Emit a patch or plan file. |

Other product signals
- Keep it local-first. Many developers cannot share codebases (84803 thread, Jon Shier).
- Output should be usable by AI agents too: Toss feeds the cache context to coding assistants. SwiftLee ships the analysis as an agent skill.
- Fixed-cost inventory for the zero-change build is its own report: signing, validation, scripts, linting, plugin planning.
- Expect the analysis to go stale each Xcode release. Version-aware rules (for example "this is fixed in Xcode 26.0") are valuable.

---

## (E) Misconceptions a tool should correct

1. **"Summed task time equals build time."** Parallelism makes summed Swift compile time exceed wall clock (281s vs 37.3s). Show the critical path. (SwiftLee)
2. **"Swift is slow" when the cause is a script, lint step, dSYM upload, asset catalog, signing, or network call.** Evidence: AutoScout24, SwiftLee, 84803 asset catalogs, 756120 provisioning network calls.
3. **"Modularize and builds get faster."** Only if the graph is layered and not too linear, and only to a point. Graph planning cost scales with module count (Toss). Explicit modules can regress badly. Heavy-generics files are not helped.
4. **"Clean build time is the metric."** Developers feel zero-change and one-line incremental builds hundreds of times a day. Clean time matters for CI and branch switches. With caching the first clean build may get slower.
5. **"Xcode N+1 made my build slower, so downgrade."** Sometimes true (CI 14m to 40m, macros), sometimes fixed in a point release (xcodebuild provisioning in 26.0, prebuilt swift-syntax). Sometimes your inputs are changing (timestamps touched by a linter, per Apple).
6. **"Buy a faster Mac."** Benchmarks show diminishing returns above Pro-class chips. Rosetta Xcode or 8GB RAM are bigger levers. Newer Xcode can erase a hardware gain.
7. **"Delete DerivedData / Clean Build Folder fixes it."** It discards the incremental state you want to keep. This is a folk remedy and sources on its efficacy are weak (vendor cleanup pages only). Low confidence.
8. **"The type-check warning flags will find it."** They do not reach SPM packages. They need low thresholds. They add overhead. They do not cover non-compile phases.
9. **"Use WMO in Debug."** Advice conflicts. Mechanism is inferred, not documented (Actondon).
10. **"Macros are free."** Macros are re-expanded for emit-module, can double Release CI time, and the swift-syntax prebuilt depends on exact version and Xcode. Keep macro plugins only on modules that need them.
11. **"Indexing and building are the same thing."** Typing lag and endless "Indexing" are separate from build time. I found no authoritative source, so any claim here needs verification.
12. **"xcodebuild equals Xcode."** They diverged (provisioning network calls in 15.4-16.2). Also Xcode GUI settings and CI environments differ. Measure the one the developer cares about.
13. **"The error points at the problem."** "Unable to type-check this expression" often hides a different error or points to the wrong location (HN, Apple threads).

---

## Source index (additional pages read, not cited above)

- https://news.ycombinator.com/item?id=36124025, 40661001 (HN type-inference threads, search results only)
- https://developer.apple.com/forums/thread/62737 (Xcode 8 recompiles every file, snippet, old)
- https://www.warpbuild.com/guides/github-actions-macos-runner-cost (pricing, snippet)
- https://github.com/MobileNativeFoundation/XCLogParser (alpha, 32 open issues, requires Xcode 16.4 and Swift 6.0)
- https://tuist.dev/en/docs/guides/features/build-insights/xcode (post-action based; no PR comment mention found)
- https://www.rocketsim.app/features/build-insights/ (P75/P95, per-scheme, Xcode-version breakdown)

## Unverified or open items
- Whether Xcode 27 changes the build-insights, Task Backtraces or compilation-cache defaults. I could not reach Apple's release notes or WWDC26 pages.
- Reddit and SO top-voted answers (blocked).
- Any hard data on how often developers clean-build, or what pain threshold the median developer reports.
- Airbnb, Pinterest, Gojek, Qonto, Trendyol, Delivery Hero numbers are from snippets only.
