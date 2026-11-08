# Reading the xcblame HTML report

The page answers three questions on its first screen: how long the build took, how much of it is the floor and how
much is waste, and what to do first. Everything else is collapsed below it. This file holds the definitions the page
leaves out (the in-page glossary was removed on 2026-11-08, DESIGN §8.2.5 "Cockpit decision"). Rules have their own
text: [RULES.md](RULES.md) and `xcblame rules explain <id>`.

## The first screen

- **Headline**: the log span and build kind ("18.1 s clean build"), then how it compares with the previous build of the
  same kind and scheme in your history (`previous`), or with `--baseline` ("than baseline").
- **Floor**: the critical path. The build cannot finish sooner without changing what waits on what.
- **Waste**: log span minus the floor: time the build spent off the critical path (idle gaps, scheduling).
- **Do this first**: at most three actions, each with the saving, how sure xcblame is, one command or Xcode click path
  to copy, and how to undo it. "Nothing to fix at this build" names the floor's target and step instead.
- **Chips**: build kind, Xcode version, time, host, checks (`N pass · N warn`), and `degraded` or `redacted` when they apply.
- **Show Xcode work (N)**: unfolds the rows of Xcode's own work, which are folded by default.
- **Details**: diagnostics, environment, checks and notes, closed by default.

## Time

- **Log span (wall time)**: seconds from the first task to the last task in the build log: how long you waited.
- **Process wall**: seconds the whole xcodebuild process ran, including work before and after the log. Only
  `xcblame build` measures it.
- **Busy time**: seconds of the log span in which at least one task was running. Log span minus busy time is idle time.
- **Idle gap**: time in which no task was running at all: nothing was being built.
- **Task time**: every task's seconds added up. Tasks run in parallel, so it shows how much work there was, not how
  long you waited.
- **CPU time**: processor seconds of the tasks that report it (compilers do, most other tasks do not); never estimated.
- **Parallelism**: task time divided by busy time: tasks running at once on average. "Peak" is the most at one moment.

## Critical path and timeline

- **Critical path**: the longest chain of tasks in which each waited for the one before. The build cannot finish
  sooner than this chain, however many cores the Mac has.
- **Path step**: one task (or a few joined tasks) on the critical path, with its start, end and seconds.
- **Wait (on the path)**: time between two path steps in which no path task ran, for example while Xcode scheduled work.
- **How the path was found**: `dag` from the build plan (most reliable), `byTiming` from one task starting as another
  ended, `mixed` both, `inferred` timing only.
- **Build description**: the plan Xcode writes before it builds: the tasks and what each depends on (`--build-description`).
- **On path**: seconds of a target, file or task on the critical path. Only these seconds delayed the end of the build.
- **What-if (path saving if free)**: how much shorter the path gets if this target took no time: an upper bound. Needs
  the build plan.
- **Blockers**: for a target, the task time of every task that had to wait for it to finish.
- **Slack**: how long a task could have started later without making the build longer. Zero slack means on the path.
- **eps (timing tolerance)**: under inference, a task follows another one if it started within this many ms of its end.
- **Lane**: one row of the all-tasks timeline, in which tasks run one after another.
- **Utilization strip**: how many tasks were running at each moment, in lanes.
- **Serial threshold**: a low number of running tasks; below it the Mac mostly waits on one or two tasks.
- **Serial stretch**: at least one second at or below the serial threshold: the build was almost single-threaded.

## Targets and tasks

- **Task**: one step of the build: compiling a file, linking, copying a resource, running a script phase, signing.
- **Task kind**: the type of a task, for example `swiftCompile`, `link`, `copy` or `script`. Chart colors are kinds.
- **Target**: an Xcode target or a Swift package target.
- **Owner**: where a target comes from: `app`, `localPackage`, `remotePackage`, `systemModules` (Apple SDK modules
  built for this build) or `buildSystem` (Xcode itself).
- **Xcode's own work**: rows such as "build system" and "explicit modules": planning and precompiling system modules.
  You cannot shorten them by editing a target, so they are folded and never an action.
- **Planning**: work before compiling: reading the project, creating the build description, planning Swift jobs.
- **Explicit modules**: Xcode builds every module dependency as its own task first, instead of on demand.
- **PCM (precompiled module)**: a Clang or Swift module compiled ahead of time so imports are fast (`modulePrecompile`).
- **Emit module (`swiftEmitModule`)**: writing a module's `.swiftmodule` so importing targets can start; often on the path.
- **`swiftCompile`**: compiling Swift source files into object files.
- **Module variant**: the same module built more than once with different flags; each extra variant is repeated work.
- **Macro plugin**: a Swift macro implementation the compiler loads; it and its swift-syntax add build time.

## Files and hotspots

- **Exact**: a file row measured on its own.
- **Batch**: several Swift files compiled by one compiler job; the time is for the whole batch. **Members** are its files.
- **Estimated**: a file's share of its batch, split by type-check time; never added to exact rows.
- **WMO (whole module)**: one job compiles the whole module, so there is no time per file.
- **Type-check time**: time the compiler spent working out the types of a function or expression.
- **Hotspot**: a function or expression slow to type-check (`-debug-time-function-bodies`, `-warn-long-expression-type-checking`
  or `xcblame build --deep`). The page shows on-path ones and those of 100 ms or more first.
- **On-path weight**: 1 when the file's compile task was on the critical path, lower when it was not.

## Findings and fixes

- **Rule id**: SET build settings, SRC Swift code, GRAPH project structure, PHASE build phases, DEP dependencies, ENV
  this Mac and Xcode, CI, DYN measured on your build.
- **Impact band**: cost per build: XS under 1 s (2 %), S 1-5 s (2-10 %), M 5-30 s (10-30 %), L over 30 s, ? unknown.
  "Estimated" means from the rule catalog, before a build measured it.
- **Confidence**: high (documented and measured here), medium (published data, estimated here), low (needs measuring;
  settings read with `--offline` drop one step).
- **Fix kind**: `overlay` (one line in `.xcblame/overlay-*.xcconfig`), `cli` (an xcodebuild argument), `defaults` (an
  Xcode preference), `project` (by hand), `recommend` (a manual change).
- **Housekeeping**: findings with no band at all, neither measured nor estimated; folded under one "N unmeasured" row.
- **Overlay**: an `.xcconfig` xcblame writes under `.xcblame/` and adds to the build; delete it to undo.
- **Hook**: one `#include?` line at the end of your base xcconfig that makes the overlay take effect
  (`fix --install-hook`, `--uninstall-hook`).
- **Shadowed**: the setting is also set at a level that wins over the overlay, so the overlay alone cannot change it.
- **Where this value is set**: the level that sets a build setting: target, project, an `.xcconfig` file or the default.
- **Oracle (exact settings)**: `xcodebuild -showBuildSettings` per target; `--offline` reads the project files instead.
- **singlefile (Incremental) and wholemodule**: the Swift Compilation Mode. Incremental suits Debug; Whole Module gives
  faster code for Release but slower iteration.
- **verify**: builds with and without a fix several times and keeps it only if it is measurably faster.

## Incremental builds

- **Clean build**: a build from nothing: every task runs.
- **Incremental build**: a build after an earlier one, in which only tasks whose inputs changed should run.
- **Zero-change build**: an incremental build with no edits. Every task it runs is overhead.
- **Cause class**: why a task ran again: `inputChanged`, `scriptPhase` (no declared outputs), `settingsChanged`,
  `upstreamInterface`, `timestampChurn`, `planning`, `firstBuild`, `forced`, `driverRemark`, `unknown`.
- **Fix:** the one line under a cause that says what to change, or "Nothing to change" when it is expected.
- **Unknown share**: executed time no evidence explains; `xcblame why --backtraces` gets Xcode's own reasons.
- **Signature**: a fingerprint of a build description or of a task's inputs; when it changes, the task runs again.
- **Task backtrace**: Xcode's own record of why a task ran; the strongest evidence.
- **Fixed cost**: work that runs on nearly every build regardless of edits. "Per day" may rest on an assumed builds per day.
- **History entry**: one build recorded under `.xcblame/history`; its id names it in trend, compare and the headline.

## Module graph

- **Module graph**: the targets and their dependencies; a target builds only after everything it depends on.
- **Longest chain**: the chain of dependent targets with the most on-path seconds: the floor even with unlimited cores.
- **Depth**: how many dependency levels lie below a target (0 = it depends on nothing).
- **Fan-in and fan-out**: how many targets depend on this one, and how many it depends on.

## Compare, trend and verify

- **Changed task (compare)**: a task in both builds with another key or command line, paired by rule, target and name.
- **Noise band**: how much the same build varies run to run; with 3 or more runs per side, differences inside it are noise.
- **MAD**: median absolute deviation: how much run times spread around their median.
- **Indicative**: a verdict from too few builds (under 3 per side; verify needs 4 per arm): a hint, never kept.
- **p50 / p75 / p95**: percentiles of build times; p50 is the median, p95 is close to the slowest builds.
- **Arm (A and B)**: one side of a verify measurement: A without the change, B with it, the same number of times.
- **Baseline arm**: arm A; the change is compared against its median.
- **Mechanism**: how a change reaches the build: `hook`, `cli`, `defaults` or `recommend`.
- **Revert**: undo a change. verify reverts every change after measuring it; `fix --revert` removes what `--apply` wrote.
- **Settle build**: the first, unmeasured build of each arm in incremental runs, to steady DerivedData.
- **Task set**: the targets and task kinds a build ran; if arm B runs others than the rule expects, the change is reverted.

## Report quality

- **Checks V1-V15**: self-checks on xcblame's own numbers; a failed check withholds the number it protects.
- **Degraded**: the input missed something, so some numbers are unknown or less precise; each says why.
- **Redacted**: user names, home paths and host names replaced (with `~` and `$USER`), so the file is safe to share.
- **Truncated**: a long list cut to keep the file under its size cap; totals still count every row, and
  `--format json --top all` prints them all.
- **unknown (reason)**: a value xcblame could not measure; the reason is the cell's tooltip. Never shown as 0.
