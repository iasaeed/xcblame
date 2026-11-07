# v0.6 "Fix" probes (MV-3 precedence, MV-9 xcconfig syntax, defaults keys, package reach)

Date: 2026-11-04. Host: macOS 27.0, 28 cores. Xcodes: 26.0.1 (17A400, default) and 27.1 beta (27A9269, `DEVELOPER_DIR=/Applications/Xcode-27.1-beta.app/Contents/Developer`).
Subjects: scratch copies of `fixtures/projects/Precedence` (iOS app target `Probe`) and `fixtures/projects/AcmeWhy` (macOS app + local package `WhyUtils`), extended with probe keys. The repository fixtures were not modified; no project under `~/Projects` was built.

Harnesses (scratchpad `probes-v0.6/sb.sh`, `build.sh`):

```
# settings (one target, selected keys)
cd ${CWD:-<scratch>/P}; xcodebuild -showBuildSettings -json -project <scratch>/P/Precedence.xcodeproj -scheme Probe \
  -configuration <Debug|Release> -sdk <iphonesimulator|iphoneos> -derivedDataPath <scratch>/dd/sb<26|27> [args]
# real build
cd /; xcodebuild -project <scratch>/P/Precedence.xcodeproj -scheme Probe -configuration Debug \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath <scratch>/dd/b<V>-<name> CODE_SIGNING_ALLOWED=NO [args] build
```

Raw logs, JSON and the extended fixtures are in the session scratchpad `probes-v0.6/`; they are not part of the repository.

## Summary

| # | Verdict (identical on 26.0.1 and 27.1 unless noted) |
|---|---|
| 1 | Low to high: project xcconfig < project settings < target xcconfig < target settings < `KEY=VALUE` < `-xcconfig` < `XCODE_XCCONFIG_FILE`. `KEY=VALUE` is **not** the top; both xcconfig mechanisms beat it. |
| 2 | `-xcconfig` with `$(inherited)` keeps the whole lower chain (project `OTHER_SWIFT_FLAGS` included, via the target level). Without `$(inherited)` it replaces everything. |
| 3 | No shadowing: `-xcconfig` beats a target-level pbxproj value without `$(inherited)` (showBuildSettings and the real compile line). `KEY=VALUE` beats it too, but loses to `-xcconfig`/env file. |
| 4 | `XCODE_XCCONFIG_FILE` wins over `-xcconfig`; keys only in the `-xcconfig` file still apply; `$(inherited)` in the env file chains onto the `-xcconfig` value. |
| 5 | `#include?` of a missing file: silent, build succeeds. Present file: included. Path resolved relative to the including file's directory first, then the project directory (SRCROOT); not cwd. Plain `#include` of a missing file fails the build (exit 65) while `-showBuildSettings` exits 0. |
| 6 | `[config=Debug]`, `[sdk=iphonesimulator*]`, and both stacked (either order) honoured, in a base xcconfig and in a `-xcconfig` file. |
| 7 | Last assignment wins; position is what counts (an `#include` acts as if its lines were pasted there). `$(inherited)` in a later line of the same level resolves to the earlier line's value. |
| 8 | Both keys are unset on this Mac; both strings still exist in 26.0.1 and 27.1 binaries. Effect **not probed** (needs `defaults write`; xcodebuild rejects them as `-Key value` args). |
| 9 | `-xcconfig`, `XCODE_XCCONFIG_FILE` and `KEY=VALUE` all reach the SwiftPM package target; the project-level base xcconfig does not. |

## Q1. Precedence ladder (MV-3)

**Method.** The Precedence copy sets a family of user keys at every level plus two real keys:

| Key | project xcconfig | project settings | target xcconfig | target settings |
|---|---|---|---|---|
| `XP_ALL` | px | ps | tx | ts |
| `XP_UPTO_TX` | px | ps | tx | – |
| `XP_UPTO_PS` | px | ps | – | – |
| `XP_PX` | px | – | – | – |
| `XP_TS_INH` | px | – | – | `$(inherited) ts` |
| `GCC_OPTIMIZATION_LEVEL` | s | – | – | 1 (Debug and Release) |
| `SWIFT_COMPILATION_MODE` | – | – | wholemodule | – |
| `OTHER_SWIFT_FLAGS` | `$(inherited) -DPROJECT_XCCONFIG` (+ hook file below) | `$(inherited) -DPROJECT_SETTINGS` | `$(inherited) -DTARGET_XCCONFIG` | Debug only: `-DTARGET_SETTINGS_ONLY` (no `$(inherited)`) |

Command-line inputs: `cli.xcconfig` (`-xcconfig`) sets every `XP_*` to `cli-x`, `GCC_OPTIMIZATION_LEVEL = 3`, `SWIFT_COMPILATION_MODE = singlefile`, `OTHER_SWIFT_FLAGS = $(inherited) -DCLI_X`, plus `XP_BOTH`/`XP_ONLY_X`. `env.xcconfig` (`XCODE_XCCONFIG_FILE`) sets them to `env`, `GCC_OPTIMIZATION_LEVEL = 2`, `OTHER_SWIFT_FLAGS = $(inherited) -DENV`, `XP_BOTH`/`XP_ONLY_ENV`, no `SWIFT_COMPILATION_MODE`. KV: `XP_ALL=kv XP_BOTH=kv GCC_OPTIMIZATION_LEVEL=0 'OTHER_SWIFT_FLAGS=$(inherited) -DKV'`.

**Observation, Debug, iphonesimulator** (Release identical except `OTHER_SWIFT_FLAGS` base, see Q2; 26.0.1 and 27.1 byte-identical):

```
baseline     XP_ALL=ts    XP_UPTO_TX=tx    XP_UPTO_PS=ps    XP_PX=px    XP_TS_INH='px ts'  GCC_OPT=1  SCM=wholemodule  OSF='-DTARGET_SETTINGS_ONLY'
-xcconfig    XP_ALL=cli-x XP_UPTO_TX=cli-x XP_UPTO_PS=cli-x XP_PX=cli-x XP_TS_INH=cli-x  GCC_OPT=3  SCM=singlefile   OSF='-DTARGET_SETTINGS_ONLY -DCLI_X'
env file     XP_ALL=env   (all XP_* env)                                                GCC_OPT=2  SCM=wholemodule  OSF='-DTARGET_SETTINGS_ONLY -DENV'
KV           XP_ALL=kv    XP_UPTO_TX=tx    XP_UPTO_PS=ps    XP_PX=px    XP_TS_INH='px ts'  GCC_OPT=0  SCM=wholemodule  OSF='-DTARGET_SETTINGS_ONLY -DKV'
-x + env     XP_ALL=env   XP_BOTH=env  XP_ONLY_X=cli-x  XP_ONLY_ENV=env                 GCC_OPT=2  SCM=singlefile   OSF='-DTARGET_SETTINGS_ONLY -DCLI_X -DENV'
-x + KV      XP_ALL=cli-x XP_BOTH=cli-x                                                 GCC_OPT=3  SCM=singlefile   OSF='-DTARGET_SETTINGS_ONLY -DKV -DCLI_X'
env + KV     XP_ALL=env   XP_BOTH=env                                                   GCC_OPT=2  SCM=wholemodule  OSF='-DTARGET_SETTINGS_ONLY -DKV -DENV'
all three    XP_ALL=env   XP_BOTH=env  XP_ONLY_X=cli-x  XP_ONLY_ENV=env                 GCC_OPT=2  SCM=singlefile   OSF='-DTARGET_SETTINGS_ONLY -DKV -DCLI_X -DENV'
```

The `$(inherited)` chain in the last row (`TARGET_SETTINGS_ONLY` < `KV` < `CLI_X` < `ENV`) shows the stacking order directly. This matches `xcodebuild -help`'s wording ("apply the build settings defined in the file at PATH as overrides") and the man page claim that `-xcconfig` overrides settings passed individually on the command line.

**Real build check** (both Xcodes, `XCODE_XCCONFIG_FILE=env.xcconfig … -xcconfig cli.xcconfig 'OTHER_SWIFT_FLAGS=$(inherited) -DKV' SWIFT_COMPILATION_MODE=wholemodule build`, BUILD SUCCEEDED). The `builtin-SwiftDriver` line of `Probe`:

```
-Onone -DFROM_PROJECT_XCCONFIG -DDEBUG -DFROM_PROJECT_SETTINGS -DFROM_TARGET_XCCONFIG -DFROM_TARGET_SETTINGS
-DTARGET_SETTINGS_ONLY -DKV -DCLI_X -DENV -enable-batch-mode -incremental
```

No `-whole-module-optimization`/`-wmo`: the KV `SWIFT_COMPILATION_MODE=wholemodule` lost to `-xcconfig`'s `singlefile` in the real compile too. The oracle (`-showBuildSettings`) agrees with the build for every key checked.

**Verdict.** Ladder, low to high: platform < project xcconfig < project settings < target xcconfig < target settings < `KEY=VALUE` < `-xcconfig` < `XCODE_XCCONFIG_FILE`. Same on 26.0.1 and 27.1.

**Implication for v0.6.** DESIGN §7.4 must split "command-line" into three ordered levels (`commandLineSetting` < `commandLineXCConfig` < `environmentXCConfig`) in `Provenance.Level`. The §7.5 wrapper is correct only because it removes the user's `-xcconfig` and unsets `XCODE_XCCONFIG_FILE` and `#include`s them before the overlay: if the variable were left set, the user's env file would beat the overlay. A user's `KEY=VALUE` on the command line loses to the overlay (and already lost to their own `-xcconfig`); `build --overlay` should warn when a passed `KEY=VALUE` names an overlay key. Never deliver `--deep` flags as `KEY=VALUE` when any xcconfig mechanism is in play.

## Q2. `$(inherited)` in a command-line xcconfig

**Observation** (both Xcodes):

```
                                   Debug                                Release
-xcconfig OSF=$(inherited) -DCLI_X '-DTARGET_SETTINGS_ONLY -DCLI_X'      ' -DPROJECT_XCCONFIG -DHOOK_OVERLAY -DPROJECT_SETTINGS -DTARGET_XCCONFIG -DCLI_X'
-xcconfig OSF=-DCLI_NOINH          '-DCLI_NOINH'                        '-DCLI_NOINH'
-xcconfig (inh) + KV OSF=-DKV_NOINH '-DKV_NOINH -DCLI_X'                 '-DKV_NOINH -DCLI_X'
```

**Verdict.** `$(inherited)` in `-xcconfig` inherits from the effective target-level value (or from `KEY=VALUE` when one is given), so project `OTHER_SWIFT_FLAGS` survive exactly when every level in between also used `$(inherited)` (Release); a target value without `$(inherited)` already cut them off (Debug), and that is the pbxproj's doing, not the command line's. Without `$(inherited)` the `-xcconfig` value replaces everything.

**Implication for v0.6.** Keep "list-typed keys start with `$(inherited)`" (§7.5 Content). The overlay can never restore a project-level flag that a target dropped; the planner must report that from provenance, not from the overlay.

## Q3. Does a target pbxproj value without `$(inherited)` shadow `-xcconfig` / `KEY=VALUE`?

**Observation.** `OTHER_SWIFT_FLAGS` (target Debug, no `$(inherited)`), `GCC_OPTIMIZATION_LEVEL = 1` and `XP_ALL = ts` (target settings) all lose to `-xcconfig` (Q1 rows) and to `KEY=VALUE`; confirmed in the real compile line (Q1).

**Verdict.** No shadowing on either Xcode, for `-showBuildSettings` and for the build. The "-xcconfig loses to target settings without `$(inherited)`" report ([DS] §6.3) does not reproduce; the likely source is an `-xcconfig` value without `$(inherited)` being mistaken for "lost", or `KEY=VALUE` vs `-xcconfig` confusion.

**Implication for v0.6.** `cli` delivery is reliable for project targets. Keep the oracle check of §7.5 (cheap, and catches env/KV surprises) but expect `shadowed (command line did not win)` to fire only when the user's `XCODE_XCCONFIG_FILE` was not unset.

## Q4. `-xcconfig` together with `XCODE_XCCONFIG_FILE`

**Observation.** Rows `-x + env` and `all three` in Q1: shared keys take the env value (`XP_BOTH=env`, `GCC_OPTIMIZATION_LEVEL=2`), keys only in the `-xcconfig` file still apply (`XP_ONLY_X=cli-x`, `SWIFT_COMPILATION_MODE=singlefile`), and the env file's `$(inherited)` sees the `-xcconfig` value (`-DCLI_X -DENV`). Same in the real build.

**Verdict.** `XCODE_XCCONFIG_FILE` is the topmost layer, above `-xcconfig`. Both Xcodes.

**Implication for v0.6.** The wrapper order "user `-xcconfig`, then the env file, then the overlay" reproduces the user's own relative order and puts the overlay on top. The child process must have `XCODE_XCCONFIG_FILE` removed from its environment (not set to the wrapper; either works, but removal keeps one mechanism).

## Q5. `#include?` (MV-9)

**Method.** Added to the project-level `Config/project.xcconfig`: `#include? "sub/opt-rel.xcconfig"` (exists at `Config/sub/`), `#include? "Config/sub/opt-src.xcconfig"` (SRCROOT form; exists at `<SRCROOT>/Config/sub/`, not at `Config/Config/sub/`), `#include? "missing/none.xcconfig"` (absent). In `cli.xcconfig`: `#include? "nope/missing.xcconfig"` (absent), `#include? "clisub/inc.xcconfig"`. Then the same `cli.xcconfig` copied to `<scratch>/elsewhere/` (outside the project) with its own `clisub/inc.xcconfig` and an extra `#include? "clisub/inc2.xcconfig"` that exists only under SRCROOT; run with `cwd=/`.

**Observation** (both Xcodes, all configs/SDKs):

```
XP_OPT_REL='present'  XP_OPT_SRC='present-srcroot-form'             # cwd=SRCROOT and cwd=/
-xcconfig elsewhere/cli.xcconfig, cwd=/:  XP_XINC='elsewhere-dir'  XP_XINC2='srcroot'
with Config/Config/sub/opt-src.xcconfig also present:  XP_OPT_SRC='includer-dir-form'
```

Missing optional includes print nothing in `-showBuildSettings` stderr or in the build log, and the real build with three missing `#include?` targets (Q1 build) **succeeded** on both Xcodes. For contrast, a plain `#include "nope/hard-missing.xcconfig"` in a `-xcconfig` file:

```
-showBuildSettings: exit 0, values from the file still reported (XP_HARD='set'), stderr:
  Ignoring configuration file '<scratch>/hard.xcconfig' because it could not be loaded.
  Reason: … hard.xcconfig line 1: Unable to find included file "nope/hard-missing.xcconfig"
build: <scratch>/hard.xcconfig:1:1: error: could not find included file 'nope/hard-missing.xcconfig' in search paths
       ** BUILD FAILED **  (exit 65, both Xcodes)
```

**Verdict.** `#include?` works on 26.0.1 and 27.1, missing or present. Relative paths resolve against the including file's directory first, then the project directory (SRCROOT; `PROJECT_DIR` is the same folder in this fixture, so the two were not separated); the working directory plays no role. This applies to a `-xcconfig` file outside the project as well.

**Implication for v0.6.** Hook line: `#include? "<path relative to the including xcconfig>/.xcblame/overlay-<C>.xcconfig"` (includer-relative is the first lookup, so it cannot be captured by a same-named file under SRCROOT). The wrapper should `#include` absolute paths (no search ambiguity). Never emit a plain `#include` for anything xcblame owns. The oracle cannot detect a broken plain `#include`: `-showBuildSettings` exits 0 and even reports the file's values, so `doctor`/`fix` should lint include targets themselves.

## Q6. Conditional assignments (MV-9)

**Method.** In `Config/project.xcconfig` (project base) and in `cli.xcconfig` (`-xcconfig`): `K = plain` then `K[config=Debug] = dbg`, `K[sdk=iphonesimulator*] = sim`, `K[config=Debug][sdk=iphonesimulator*] = dbgsim`, and the reversed stacking `[sdk=…][config=Debug] = simdbg`.

**Observation** (both Xcodes; base-xcconfig keys `XP_C1..4`, `-xcconfig` keys `XP_XC1..3` behave identically):

| | C1 `[config=Debug]` | C2 `[sdk=iphonesimulator*]` | C3 `[config][sdk]` | C4 `[sdk][config]` |
|---|---|---|---|---|
| Debug, iphonesimulator | dbg | sim | dbgsim | simdbg |
| Debug, iphoneos | dbg | plain | plain | plain |
| Release, iphonesimulator | plain | sim | plain | plain |
| Release, iphoneos | plain | plain | plain | plain |

**Verdict.** All three forms honoured, stacking in either order, at the project-base level and on the command line, on 26.0.1 and 27.1.

**Implication for v0.6.** The "no `[config=...]` conditions" rule in §7.5 Content is no longer needed for correctness; one file per configuration remains the simpler, more readable choice. `[sdk=…]` conditions are safe for platform-specific fixes inside one overlay file. The offline resolver must evaluate stacked conditions in any order.

## Q7. Ordering inside a file and around `#include`

**Method.** In `Config/project.xcconfig`: `XP_LW = first`, `XP_LW = second`; `XP_IO_A = before`, `XP_IO_B = before`, `XP_LIST = a`, then `#include "io.xcconfig"` (sets `XP_IO_A = included`, `XP_IO_B = included`), then `XP_IO_B = after`, and finally `#include? "hook-overlay.xcconfig"` as the last line (sets `XP_LW = overlay`, `XP_LIST = $(inherited) b`, `OTHER_SWIFT_FLAGS = $(inherited) -DHOOK_OVERLAY`).

**Observation** (both Xcodes, every config/SDK): `XP_LW='overlay'`, `XP_IO_A='included'`, `XP_IO_B='after'`, `XP_LIST='a b'`; Release `OTHER_SWIFT_FLAGS=' -DPROJECT_XCCONFIG -DHOOK_OVERLAY -DPROJECT_SETTINGS -DTARGET_XCCONFIG'`.

**Verdict.** Last assignment wins; an `#include` is textual (its lines take effect at the include position, so a later line beats it and it beats earlier lines). `$(inherited)` inside a later assignment at the same level expands to the previous assignment in that file chain, not to the next level down only.

**Implication for v0.6.** Appending `#include?` as the **last** line of the project base xcconfig makes overlay lines win over everything in that file, and `$(inherited)` list keys keep the file's own earlier values. `install-hook` must append at the end (and re-check it stays last); the overlay still loses to project/target pbxproj values (Q1 ladder), which is the shadowing case of §7.5.

## Q8. Xcode user defaults (read only; nothing written)

**Observation.**

```
defaults read com.apple.dt.Xcode IDEBuildOperationMaxNumberOfConcurrentCompileTasks
  Error: Could not find key 'IDEBuildOperationMaxNumberOfConcurrentCompileTasks' in domain 'com.apple.dt.Xcode'.
defaults read com.apple.dt.Xcode ShowBuildOperationDuration
  Error: Could not find key 'ShowBuildOperationDuration' in domain 'com.apple.dt.Xcode'.
```

Binary strings, both 26.0.1 and 27.1: `IDEBuildOperationMaxNumberOfConcurrentCompileTasks` in `IDEFoundation`, `Xcode3Core`, and `SWBUtil` (in both `XCBuild.framework` and `SwiftBuild.framework` build-service bundles; 27.1 also in `IDEXCBuildSupportCore`). `IDEFoundation` holds the log strings `Build task concurrency set to %ld via user default IDEBuildOperationMaxNumberOfConcurrentCompileTasks` and `IDEBuildOperationMaxNumberOfConcurrentCompileTasks = %lu`. `ShowBuildOperationDuration` is in `IDEKit` and `Xcode3Core` only (GUI). An argument-domain attempt (`xcodebuild … -IDEBuildOperationMaxNumberOfConcurrentCompileTasks 3 build`) is rejected: `xcodebuild: error: invalid option '-IDEBuildOperationMaxNumberOfConcurrentCompileTasks'` (exit 64, both). `xcodebuild -help` lists `-jobs NUMBER` ("specify the maximum number of concurrent build operations"). `build-request.json` (27.1) has `useParallelTargets: true` and no job-count field.

**Verdict.** Both keys still exist on 26.0.1 and 27.1 and are unset on this Mac. Effect **not probed**: proving it needs `defaults write` (forbidden here) or a GUI build. `ShowBuildOperationDuration` is display-only (IDEKit) and cannot change build time.

**Implication for v0.6.** `defaults` fixes: keep `IDEBuildOperationMaxNumberOfConcurrentCompileTasks` (with backup/revert per §7.3) but at `medium` confidence until an effect probe runs under a throwaway user or with save/restore; for xcodebuild/CI emit `-jobs N` (`cli` kind) instead. Treat `ShowBuildOperationDuration` as a visibility helper, not a speed fix.

## Q9. Do command-line settings reach SwiftPM package targets?

**Method.** AcmeWhy copy (macOS app, framework targets `WhyKit`/`WhyCore`, local package `WhyUtils`); appended `OTHER_SWIFT_FLAGS = $(inherited) -DPROJ_XCCONFIG_PROBE` to the project-level base `Config/Why.xcconfig`. Built with `XCODE_XCCONFIG_FILE=pkg-env.xcconfig` (`-DENV_XCCONFIG_PROBE`), `-xcconfig pkg-cli.xcconfig` (`-DCLI_XCCONFIG_PROBE`), `'OTHER_SWIFT_FLAGS=$(inherited) -DKV_PROBE'`, `-destination platform=macOS,arch=arm64`, own `-clonedSourcePackagesDirPath`. BUILD SUCCEEDED on both.

**Observation** (`builtin-SwiftDriver` `-D` flags per module; 26.0.1 and 27.1 identical):

```
AcmeWhyApp :: -DDEBUG -DPROJ_XCCONFIG_PROBE -DKV_PROBE -DCLI_XCCONFIG_PROBE -DENV_XCCONFIG_PROBE
WhyCore    :: -DDEBUG -DPROJ_XCCONFIG_PROBE -DWHY_A -DKV_PROBE -DCLI_XCCONFIG_PROBE -DENV_XCCONFIG_PROBE
WhyUtils   :: -DSWIFT_PACKAGE -DDEBUG -DSWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE -DXcode -DKV_PROBE
              -DCLI_XCCONFIG_PROBE -DENV_XCCONFIG_PROBE -D_LIBCPP_HARDENING_MODE -DSWIFT_PACKAGE -DDEBUG
```

**Verdict.** All three command-line mechanisms reach the package target, stacked in the same order as for project targets; the project-level base xcconfig (`PROJ_XCCONFIG_PROBE`) does not. Both Xcodes.

**Implication for v0.6.** Confirms §7.5 Scope: hook = project targets only, `cli` = project + package targets. `fix --plan` should list package targets under "cli only". Flags such as `-warn-long-function-bodies` or `-D` injected by the wrapper will also hit third-party package code (and its warnings), so `--deep` must attribute them per module.

## Not done / caveats

- Q8 effect of the defaults keys: not probed (would need `defaults write`).
- `PROJECT_DIR` vs `SRCROOT` as the include fallback base: not separated (same folder in the fixture).
- Only Debug was real-built for Q1/Q5/Q9; Release precedence comes from `-showBuildSettings` (which matched the build in every Debug check).
- Workspaces (`-workspace`) and the IDE were not probed; IDE builds ignore all three command-line mechanisms by construction.
