# xcblame schema and contract: v0.6 "Fix"

The contract between the three v0.6 lanes. It freezes the two new documents (`xcblame.fixplan/1`, `xcblame.verify/1`),
their storage, the overlay file, the hook, the `defaults` backup, the `fix` and `verify` CLI, the HTML verify view
(§8.2.4 #13) and the fix-plan view, and the file ownership. Types live in
`Sources/XcblameKit/Model/FixPlanDocument.swift` (`FixPlanDocument`, `FixPlanning`, `FixPlanRequest`),
`Sources/XcblameKit/Model/VerifyDocument.swift` (`VerifyDocument`, `Verifying`, `VerifyRequest`) and
`Sources/XcblameKit/Model/FixPlanStore.swift`. `Tests/XcblameKitTests/Reporters/SchemaV06ContractTests.swift` pins every
member name and closed vocabulary (`V06Samples` there holds one populated sample of each document). Renaming, removing
or retyping a member breaks the contract; a lane that needs a change stops and asks the integrator.

Lanes (disjoint files, see "Lane ownership"):
- **A Fix** (`fix`: planner, overlay writer, hook installer, defaults applier, revert, backups, fixtures).
- **B Verify** (`verify`: A/B harness, per-arm DerivedData, validity checks, verdicts, auto-revert, aborts, history
  verify entries, scripted fake runner).
- **C Report** (text, markdown, agent, json and HTML for both documents; HTML section 13; fix-plan view; glossary;
  JSON Schema; `xcblame schema --document fixplan|verify`).

The probe lane answered MV-3 (remaining v0.6 part) and MV-9 in [research/probes-v0.6.md](research/probes-v0.6.md)
(Xcode 26.0.1 and 27.1 beta agree on every point). Its results are folded into the contracts below and listed under
"Decisions"; DESIGN text they change is listed under "DESIGN amendments for the integration agent".

## General rules (v0.2-v0.5 rules unchanged)

- Both documents are new top-level documents next to `xcblame.report/1`, `xcblame.compare/1`, `xcblame.trend/1` and
  `xcblame.baseline/1`; the report schema is unchanged (one additive member since 2026-11-08: `previous`, see
  "report: previous"). `tool` is the report's `Tool`; `tool.version` becomes `0.6.0` at
  integration (phase 1 leaves `XcblameVersion.current` at `0.5.0`).
- §8.1 null+note: a nil member serializes as an explicit `null` (`@Null`); the reason sits in the nearest `notes`.
- Times are seconds rounded to 6 decimals (`ReportDocument.round6`); ratios are fractions (`deltaPct` −0.124 = 12.4 %
  faster). Paths stay absolute in the document and are redacted by the Redactor (lane C extends the walk to both
  documents; `redacted` is set once it ran).
- JSON is `JSONReporter.encoder()` (sorted keys, ISO-8601 dates), `JSONReporter.render(_ plan:)` /
  `render(_ verify:)` (`Reporters/JSONReporter+FixVerify.swift`, done in phase 1).
- Nothing in the project is written by `fix` without a write flag, and nothing at all by `verify` except the overlay
  file under `--mechanism hook`, restored byte-identical after each B run (also on SIGINT/SIGTERM/SIGHUP/SIGQUIT, and
  by the next `fix`/`verify`/`build` after a SIGKILL or crash: Decision 31).

## Storage (`<xcblame-dir>`, default `.xcblame`)

| Path | What | Git |
|---|---|---|
| `plans/<id>.json` | `FixPlanDocument`, pretty JSON (`FixPlanStore.save/load/list`) | ignored |
| `overlay-<Configuration>.xcconfig` | the overlay (below) | committed (the team gets the fix) |
| `backup/<sha16>.orig` | exact bytes of an xcconfig before the hook was appended | ignored |
| `backup/hooks.json` | `[{path, link?, configuration, originalSHA256, hookedSHA256, backup}]` | ignored |
| `tmp/verify-inflight.json` | journal of a running `--mechanism hook` verify: overlay paths, original bytes (base64), mtime, plan, rules, pid | ignored |
| `tmp/build-overlay-<Config>.xcconfig` | the lines `build --overlay` delivers through the wrapper | ignored |
| `backup/defaults.json` | `[{planId, domain, key, prior: {exists, type, value}}]` | ignored |
| `history/verify/<id>.json.gz` | `VerifyDocument` (gzip, like history entries) | ignored (under `history/`) |
| `tmp/verify-overlay-<Config>.xcconfig`, `tmp/wrapper-<Config>.xcconfig` | `--mechanism cli` scratch | ignored |
| `<OracleCache.home()>/verify/<plan>/A/`, `…/B-<RULE or batch>/` | per-arm DerivedData (§7.8 step 3) | outside the repo |

`.xcblame/.gitignore` gains `plans/` and `backup/` (phase 1, `StateFiles.swift`; the v0.5 text is upgraded in place).
History verify entries sit in a subfolder so `History.list` (and everything built on it: `previousIndex`, trend,
baseline, retention, `compare <id>`) never sees them; `history prune` prunes the subfolder too (lane B, marked block in
`HistoryCommand.swift`). Per-arm DerivedData follows the deep cache rules (30 days unused, `history prune` removes;
lane B adds `VerifyDerivedData.prune` next to `DeepDerivedData.prune`).

## Fix plan document (`xcblame.fixplan/1`)

Top level: `schemaVersion`, `tool`, `generatedAt`, `id`, `generatedFrom`, `project`, `steps`, `guards`, `hook`,
`commands`, `events`, `notes`, `redacted`.

| Member | Type | Meaning |
|---|---|---|
| `id` | 8 lowercase hex | First 8 hex of SHA-256 over: `generatedFrom.analysisId` (or `analysisPath`), `project.container`, and per step in order `ruleId`, overlay `line`s, defaults `key=value`. Deterministic: the same inputs give the same id, and `fix`/`verify` then reuse the stored plan (its `verify` states and `events` survive). Verify states and events are not hashed. |
| `generatedFrom` | `Source` | `analysisId` (history entry id) or `analysisPath` (`fix --from <file>`), `analysisKind`, `doctorConfigurations`, `settingsSource` (`xcodebuild` / `offline` / `mixed`), `rulesFilter`. |
| `project` | `Project` | `container`, `generator` (nil when hand-made), `configurations`, `scheme`. |
| `steps` | `[Step]` | Plan order: `RulePlan.ordered` (prerequisites first); every finding with a fix kind other than `measure`. |
| `guards` | `[Guard]` | `id` closed: `commitFirst`, `hookInstalled`, `prerequisite`, `verifyFirst`, `cleanTree`; `text`, `ruleIds`, `satisfied` (nil = not checked). |
| `hook` | `[HookState]` | Per configuration: `status` closed `installed` / `notInstalled` / `unavailable` / `generated`, `baseXCConfig` (repo-relative), `reason`. |
| `commands` | `[String]` | The commands to run, in order (`xcblame fix --install-hook`, `xcblame verify …`, `xcblame fix --apply`). |
| `events` | `[Event]` | Writes made with this plan, oldest first: `at`, `action` closed `apply` / `applyDefaults` / `revert` / `installHook` / `uninstallHook`, `ruleIds`, `files` (repo-relative), `defaultsKeys`. |

**Step**: `order` (1-based), `ruleId`, `title`, `fixKind` (closed: the finding's `fixKind` verbatim, `overlay`, `cli`,
`defaults`, `scheme`, `project`, `manifest`, `recommend`, `measure`), `mechanism` (closed: `hook`, `cli`, `defaults`,
`recommend`), `mechanismDetail` (the finding's `mechanism` text), `impactBand`, `impactSeconds`, `estimatedBand`,
`confidence`, `verifyOnly` (`+V`), `verifyKind` (`clean` / `incremental` / `zero-change`, from the finding's
`xcblame verify … --kind`, else `clean`), `scope`, `overlay`, `defaults`, `shadowing` (closed `none` / `partial` /
`full`), `shadowedBy` (level labels), `verify`, `state` (closed `planned` / `applied` / `applied-cli` / `reverted` /
`skipped`),
`stateReason`, `commands`, `inXcode`, `risk`.

**Mechanism per fix kind**: `overlay` → `hook` (default) or `cli` (when every hook pair is shadowed, or on CI, or when
the hook is `unavailable`); `cli` → `cli`; `defaults` → `defaults`; everything else → `recommend` (v0.6 writes no
pbxproj, scheme or manifest: those steps print the `inXcode` lines; see Decisions).

**ScopeRow** (`scope[]`, Appendix B item 10): `target`, `configuration`, `key`, `before`, `after`, `provenance`,
`mechanism`, `reached`, `note`. A step lists rows for **both** `hook` and `cli` when it has overlay lines, so the plan
shows the targets each mechanism changes. `hook` rows: project targets only (package targets get no hook row, probes
Q9); `reached` false when a level above the project xcconfig sets the key (project settings, target xcconfig, target
settings; `SettingsOracle.isShadowed`). `cli` rows: project and package targets, `reached` always true by construction
(probes Q1/Q3: `-xcconfig` sits above every project level, `$(inherited)` or not); the oracle run with the wrapper
(`SettingsOracle.effective(withXCConfig:)`) fills `after` as a confirmation, and a mismatch sets `reached` false with
a `note` (a bug or an unprobed Xcode, never an expected outcome).

**OverlayLine**: `configuration`, `key`, `condition` (nil, or an `[sdk=…]` condition, probes Q6), `value`, `line` (the
exact text written). **DefaultsChange**: `domain` (`com.apple.dt.Xcode`), `key`, `value` (nil = `defaults delete`),
`type` (`bool` / `int` / `string`, nil with a nil value).

**VerifyState** (`steps[].verify`, written by lane B): `status` (closed `unverified` / `kept` / `reverted` /
`indicative`), `reason` (closed `slower` / `withinNoise` / `brokeBuild` / `taskSetChanged` / `noEffect`, set only for
`reverted`), `mechanism`, `kind`, `verifyId`, `verifiedAt`, `deltaSeconds`, `deltaPct`, `tie`, `basis` (16 hex,
`VerifyBasis.value`, Decision 30; nil in plans written before fix round 1). Text spelling:
`kept`, `kept (tie)`, `reverted (slower)`, `reverted (within noise)`, `reverted (broke build)`, `reverted (task set
changed)`, `reverted (no effect)`, `indicative`, `unverified`.

### `fix --apply` rules

1. Writes overlay lines only (§7.3), for steps with `fixKind == overlay`.
2. A step is written when `verify.status == kept`. With `--force-unverified` also when `unverified` and not
   `verifyOnly`. Never when `reverted` or `indicative`. Skipped steps get `state: skipped` and a `stateReason`.
3. Mechanism (Appendix B item 10): `--apply` delivers through the hook. A step planned `mechanism: cli`, or kept with
   `mechanism: cli` while its `hook` and `cli` scope rows differ (the reached `(target, configuration, key, after)`
   sets), is recorded `state: applied-cli` and nothing is written; the `stateReason` and the message give the exact
   `xcblame build --overlay <plan-id> [--overlay-unverified] -- -scheme <S> -configuration <C> build` that delivers it
   (fix round 1, Decision 29).
4. A key already set in another plan's block of the same overlay file: the step is skipped ("key X is set by plan Y:
   xcblame fix --revert Y first"). One key appears at most once per overlay file. A temporary verify block a killed
   verify left counts as well ("… an interrupted verify of plan Y left …: xcblame fix --revert Y removes it").
5. Nothing written is exit 0 with a note: "every overlay step was skipped (reasons above)" and the verify commands of
   the unverified or indicative ones only. A reverted step says so: "SET-004 was reverted (within noise) on
   <date>: not applied; re-verify with xcblame verify …". A written step whose configuration has no installed hook
   gets a warning (nothing reads the overlay until `--install-hook`).

`--apply-defaults` writes the `defaults` steps (the flag is the consent, §7.3; `+V` ones need `kept`, which v0.6 verify
never produces for defaults, so in practice: non-`+V` only), saving prior values first.

## Overlay file (`overlay-<Configuration>.xcconfig`)

```
// xcblame overlay for configuration Debug. Written by xcblame fix --apply; each block belongs to one plan step and
// xcblame fix --revert <plan-id> removes it. Read through the #include? hook or the xcblame -xcconfig wrapper.

// xcblame plan 7f3a91c2 rule SET-004
DEBUG_INFORMATION_FORMAT = dwarf // xcblame SET-004 (plan 7f3a91c2)
// end xcblame plan 7f3a91c2 rule SET-004

// xcblame plan 7f3a91c2 rule SET-016
OTHER_SWIFT_FLAGS = $(inherited) -Xfrontend -foo // xcblame SET-016 (plan 7f3a91c2)
// end xcblame plan 7f3a91c2 rule SET-016
```

- One file per configuration, header first (the three comment lines above, then one blank line). One block per
  (plan, rule): a begin line `// xcblame plan <id> rule <RULE>`, the step's lines for that configuration, an end line
  `// end xcblame plan <id> rule <RULE>`, and one blank line before the block. Blocks never nest; a block whose end line
  is missing makes `--apply` and `--revert` refuse the file (exit 1, "the overlay was edited by hand").
- Line text: `KEY = VALUE // xcblame <RULE> (plan <id>)`, or `KEY[sdk=<pattern>] = VALUE …` for an `[sdk=…]` condition
  (probes Q6: honoured, stacked in either order, in a base xcconfig and in `-xcconfig`). `[config=…]` is never written
  (the file is already per configuration).
- List-typed keys (`OTHER_SWIFT_FLAGS`, `OTHER_LDFLAGS`, `OTHER_CFLAGS`, `*_SEARCH_PATHS`, `GCC_PREPROCESSOR_DEFINITIONS`,
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS`, any key whose current value has several words) start with `$(inherited)`
  (probes Q2/Q7: without it the value replaces the whole lower chain).
- **Revert is byte-exact**: removing a block removes exactly the bytes apply inserted (blank line + block). When the
  overlay file did not exist before the first apply and its last block goes, the file is deleted. After apply then
  revert every file is byte-identical to before (§11 exit criterion).

## Hook (`fix --install-hook`, `--uninstall-hook`)

- Target: the project-level `baseConfigurationReference` xcconfig of each configuration (§7.5), when it is a repository
  file, not CocoaPods-generated, not shared with another configuration of the project (one `#include?` path per
  configuration; see Decisions), and the project is not generated. Otherwise `hook[].status` is `unavailable` (with
  `reason`) or `generated` (XcodeGen/Tuist: the `configFiles:` / settings change is printed, nothing written).
- Text appended (always the **last** two lines of the file, probes Q7: last assignment wins and an include acts where
  it sits): a newline if the file does not end with one, then exactly these two lines (fix round 1, Decision 27; no
  blank line before them, so a clone without the backup can remove exactly what was appended):

  ```
  // xcblame hook (fix --install-hook); remove with: xcblame fix --uninstall-hook
  #include? "<path from this xcconfig's folder to <repo>/.xcblame>/overlay-<Configuration>.xcconfig"
  ```

  `#include?` only, never plain `#include` (probes Q5: a missing plain include fails the build with exit 65 while
  `-showBuildSettings` exits 0). The path is relative to the including file's folder (the first lookup, probes Q5).
  A `//` comment line before the `#include?` is harmless (probe 2026-11-06, Xcode 26.0.1: the overlay value wins).
- A symlinked base xcconfig (Decision 28): the bytes are read, backed up and written at the link's **target** (the link
  stays a link, checked with `lstat` after writing); the include path is relative to the **link's** folder, where
  Xcode resolves includes (probe 2026-11-06: an `#include?` in the target resolved against the link's folder).
  `hooks.json` rows gain `link` (the path the project names; `path` is the target). A target outside the project
  folder is `unavailable`.
- Install checks: (1) the file has no uncommitted git changes (else that configuration is refused, exit 1, "commit
  first"); (2) bytes backed up to `backup/<sha16>.orig` and the row saved in `backup/hooks.json` **before** the file is
  written (a save failure writes nothing; an interrupted check can still be undone), dropped again on rollback;
  (3) after writing, the installer resolves the include path itself and checks the overlay file exists or will be
  created by the same run (the oracle cannot see a broken include), and, when the overlay has lines, runs
  `-showBuildSettings` for one project target through the scratch-workspace oracle (`-derivedDataPath` in the oracle
  cache, nothing under `~/Library/Developer`) and checks an overlay key's value appears; a failure restores the backup.
- A later `fix --apply` re-checks that the hook lines are still last; if not, it warns ("lines after the xcblame hook
  in <file> win over the overlay").
- `--uninstall-hook`: when the file's SHA-256 equals `hookedSHA256`, the backup bytes are written back (byte-identical);
  otherwise the hook lines are removed textually and a note says the rest of the file was kept as edited. Without a
  `hooks.json` row (a teammate's clone: `backup/` is git-ignored, the hook lines are committed) the two hook lines are
  removed when they are the file's last two lines byte for byte; anything else exits 1 with the remove-by-hand
  message. The `pbxproj` variant (setting `baseConfigurationReference` when there is none) is **out of scope for
  v0.6**.

## Defaults (`fix --apply-defaults`, `--revert`)

- v0.6 writes one key: `IDEBuildOperationMaxNumberOfConcurrentCompileTasks` (ENV-002) in `com.apple.dt.Xcode`, as
  `defaults delete` (default = cores) or `defaults write -int`. Probes Q8: the key exists in 26.0.1 and 27.1; its effect
  was not probed, so ENV-002's confidence stays as the catalog says and its text names `-jobs N` for xcodebuild/CI.
- ENV-001 (`ShowBuildOperationDuration`) is display-only (IDEKit, probes Q8): the planner makes it a `recommend` step
  (the `defaults write` line in `inXcode`), never a `defaults` step. DEP-008's `IDEPackageEnablePrebuilts` (Xcode 16.4)
  is `recommend` too.
- Before writing, the prior state (`exists`, `type`, `value`) goes to `backup/defaults.json` keyed by plan id;
  `--revert <plan>` restores it exactly (deletes the key when it did not exist).

## `xcblame fix` (CLI, frozen in phase 1)

`xcblame fix [--rules <ids>] [--apply] [--apply-defaults] [--force-unverified] [--install-hook] [--uninstall-hook]
[--revert [<plan-id>]] [--edit-project] [--plan-out <file>] [--from <history-id|report.json>] [--project <p> |
--workspace <w>] [--configuration <c>]… [--offline] [--xcblame-dir <d>] [--format text|json|html|markdown|agent]
[-o <file>] [--open]`

- Plan inputs: a doctor pass (as `doctor`, same oracle) plus the analysis `--from` names, else the newest history entry
  that is not a `build --deep` entry; no analysis is fine (static findings only, `analysisId` nil, note).
- Without a write flag: prints the plan, stores it in `plans/` (xcblame state, not the project). `--plan-out` also
  writes the JSON there.
- Validation (exit 2): `--edit-project` (not in 0.6, message points to the manual steps and `verify --mechanism cli`);
  `--project` with `--workspace`; `<plan-id>` without `--revert`; `--revert`/`--uninstall-hook` with `--apply`,
  `--apply-defaults` or `--install-hook`; `--force-unverified` without `--apply`/`--apply-defaults`; unknown `--rules`;
  a format outside text/json/html/markdown/agent. Combinable: `--install-hook --apply --apply-defaults`;
  `--revert --uninstall-hook`.
- `--revert` without an id: the newest plan with an `apply` or `applyDefaults` event not yet reverted.
- Exit: 0 done (skipped steps are notes), 1 a write failed and was rolled back, or an overlay/hooked file was edited
  by hand so that the exact bytes cannot be found, 2 usage, 5 project not found.
- Phase 1: `run` prints `error: xcblame fix: not implemented in this build` and exits 2 inside the `// v0.6 lane A`
  block.

## Verify document (`xcblame.verify/1`)

Top level: `schemaVersion`, `tool`, `generatedAt`, `id` (`<yyyyMMdd-HHmmss>-verify`), `planId`, `kind` (`clean` /
`incremental` / `zero-change`), `mechanism` (`--mechanism`, nil = per step), `runsPerArm`, `oneByOne`, `keepOnTie`,
`maxMinutes`, `touch`, `scheme`, `configuration`, `xcodebuildArguments`, `wallBasis` (`processWall`), `noiseModel`,
`preconditions`, `results`, `abort`, `elapsedSeconds`, `xcode`, `machine`, `notes`, `redacted`.

- **results[]** (`UnitResult`, one per rule with `--one-by-one`, else one batch): `ruleIds`, `titles`, `mechanism`,
  `scope` (the unit's scope rows under `mechanism`), `arms` (`A` then `B`), `deltaSeconds` (B.p50 − A.p50),
  `deltaPct`, `noiseBand`, `verdict` (`status`, `reason`, `tie`), `checks`, `notes`, `basis` (the unit's steps'
  `VerifyBasis` values combined, Decision 30).
- **arms[]** (`ArmResult`): `arm`, `derivedData`, `runs`, `runsTotal`, `runsOk`, `samples`, `p50`, `mad` (median and
  median absolute deviation of the samples' `wall`). With `--one-by-one` arm A is measured once and repeated in every
  unit (same runs).
- **runs[]** (`Run`): `arm`, `index` (1-based, settle included), `settle`, `ok`, `exitCode`, `wall`, `criticalPath`,
  `taskKindsHash` (16 hex of SHA-256 over sorted `target\tkind\tcount` lines of executed tasks), `targetSetHash` (16 hex
  over sorted built target names), `thermal`, `excluded` (nil for a sample; `settle build`, `failed`, `thermal: replaced
  by run N`).
- **checks[]**: `name` closed `exitCode`, `targetSet`, `taskKinds`, `thermal`, `oracle`; `status` `pass` / `fail` /
  `warn` / `skipped`; `detail`.
- **preconditions[]**: `name` closed `cleanTree`, `power`, `thermal`, `otherBuild`, `hook`; `status` `pass` / `warn` /
  `fail`; `detail`.
- **noiseModel**: `madMultiplier` 3, `minPct` 0.02, `minSamples` 3, `minRuns` 4 (`NoiseModel.v06`).
- **abort**: `reason` closed `dirtyTree`, `onBattery`, `xcodebuildRunning`, `thermal`, `timeout`, `baselineBroken`,
  `interrupted`, `hookMissing`; `detail`. Non-nil → exit 6; finished units keep their verdicts, the rest are
  `unverified`.

### Verdict (DESIGN §7.8, v0.4 noise model §6.10)

- Samples: runs with `ok` and not `excluded`. Non-clean kinds: the first run of each arm is the unmeasured settle build.
- `indicative` when `--runs` < 4 or either arm has < 3 samples: never kept, never written into `fix --apply`.
- Band = max(3 × pooled MAD, 2 % × A.p50), pooled MAD = √((madA² + madB²)/2) (`Stats.pooled`).
- `kept` when B.p50 < A.p50 and |Δ| > band; `reverted (slower)` when B.p50 > A.p50 and |Δ| > band; otherwise
  `reverted (within noise)`, or `kept` with `tie: true` under `--keep-on-tie`.
- Validity first (any failure wins over timing): a B run exit ≠ 0 → `reverted (broke build)`; target set differs, or
  (clean kind) the per-target task-kind multiset differs beyond the rule's declared effect (lane B's table, e.g.
  SET-004 removes `GenerateDSYMFile`) → `reverted (task set changed)`; the oracle check shows no reached target →
  `reverted (no effect)`, not built. An A run exit ≠ 0 → abort `baselineBroken`.
- Thermal: a run whose thermal state is above nominal is excluded and replaced once; a replacement also throttled
  aborts `thermal`. Start-of-run thermal above nominal is a `warn` precondition.
- Preconditions that abort: files the plan touches (overlay files, hooked xcconfigs) dirty in git (`dirtyTree`), on
  battery (`onBattery`), another `xcodebuild` process (`xcodebuildRunning`), `--mechanism hook` without the hook for
  the configuration (`hookMissing`).

### Mechanisms in verify

- `hook`: the hook must be installed; arm B writes the unit's lines into the overlay file as a block
  `// xcblame verify <plan> rule <RULE> (temporary)` … `// end xcblame verify <plan> rule <RULE>`, builds without
  `-xcconfig`, and restores the overlay file's exact bytes after each B run and on SIGINT/SIGTERM/SIGHUP/SIGQUIT.
  Before the first temporary write the original bytes go to `tmp/verify-inflight.json` (removed once they are back);
  `fix`, `verify` and `build` start by restoring the bytes of a journal whose pid is dead (one warning line), so a
  SIGKILL or crash cannot leave the change live (Decision 31). Arm A builds with the overlay as it is, without the
  selected steps' blocks and without another plan's block that sets one of the measured keys (noted).
- Without `-configuration` in the arguments verify adds the one the selected overlay lines are for (noted): xcodebuild
  would otherwise build the project's default configuration and both arms would be identical.
- `--max-minutes` also stops a build still running when the budget runs out (`XcodebuildRunner.Cancel` on a timer),
  abort `timeout`. A build ended by a signal (exit 129-131, 137, 143) waits up to 1 s for the interrupt flag, so a
  Ctrl-C is `interrupted`, not `reverted (broke build)`. A failing auto-revert is a note on the unit; the verdicts are
  still written and the history entry saved.
- `cli`: both arms pass a wrapper `-xcconfig` (`WrapperXCConfig.plan` with `overlay:` =
  `tmp/verify-overlay-<Config>.xcconfig`): arm A's holds the current overlay, arm B's the current overlay plus the
  unit's lines, so the wrapper itself is not what is measured. The wrapper includes the user's `-xcconfig` first, then
  the `XCODE_XCCONFIG_FILE` file (removed from the child's environment), then the overlay, with absolute paths (probes
  Q4, Q5).
- Per-arm DerivedData for `incremental` and `zero-change` (`<cache>/verify/<plan>/A/`, `B-<RULE>`, `B-batch`), each
  prepared by its settle build; `clean` may interleave A/B (ABAB) and passes `-derivedDataPath` per arm too.
- `incremental`: before each measured run of both arms, the `--touch` file's timestamp is touched (`why --touch`
  semantics); without `--touch`, verify picks the first `.swift` source of the first built project target
  (alphabetical) and names it in `notes`.
- Without `--` arguments the xcodebuild arguments come from the plan's analysis: `-workspace|-project <container>
  -scheme <build.scheme> -configuration <build.configuration> -destination <build.destination> build`; a missing part
  is exit 2 naming it.

After the run, verify writes each unit's verdict into the plan's `steps[].verify` (`FixPlanStore.save`) and saves the
document as a history verify entry.

## `xcblame verify` (CLI, frozen in phase 1)

`xcblame verify [--runs n (5)] [--kind clean|incremental|zero-change] [--touch <file>] [--rules <ids>] [--one-by-one]
[--keep-on-tie] [--max-minutes n] [--mechanism hook|cli] [--plan <id>] [--xcblame-dir <d>] [--format
text|json|html|markdown|agent] [-o <file>] [--open] [-- <xcodebuild args>]`

- `--kind` default: each step's `verifyKind`; a batch whose steps differ is exit 2 ("give --kind or --one-by-one").
- `--mechanism` default: each step's planned `mechanism` (`defaults`/`recommend` steps are not verified in v0.6).
- `--plan` default: the newest stored plan containing every `--rules` id, else a fresh plan made through
  `FixPlanning` (as `fix` would, stored).
- Validation (exit 2): `--runs` < 1, `--max-minutes` ≤ 0, `--touch` without `--kind incremental`, unknown `--rules`,
  a format outside the five. The command the doctor plan prints (`xcblame verify --rules SET-016 --kind clean
  --mechanism hook`) parses (`VerifyCLITests`).
- Exit: 0 finished (any verdicts), 6 aborted, 1 internal error, 2 usage.
- Phase 1: `run` prints `error: xcblame verify: not implemented in this build` and exits 2 inside the `// v0.6 lane B`
  block.

## Text, formats, JSON Schema (lane C)

- Text (§3.5): `verify` prints a table per unit: arm, runs ok/total, p50 ± MAD, delta (s and %), noise band, verdict,
  mechanism, per-target scope (targets reached, shadowed ones named). `fix` prints the steps in order (rule, title,
  band, confidence, fix kind, mechanism, verify state, scope summary per mechanism, overlay lines), then the guards,
  then the commands, then "nothing in the project changed" unless a write flag ran.
- Entry points, phase-1 stubs in lane C's files: `TextReporter.renderFixPlan(_:colors:)`,
  `TextReporter.renderVerify(_:colors:)` (stub: one line), `MarkdownReporter.render(_ plan:options:)` /
  `render(_ verify:options:)`, `AgentReporter.render(_ plan:options:)` / `render(_ verify:options:)` (stubs throw
  `notImplemented("… (v0.6 lane C)")`); budgets as the report's markdown (64 KB) and agent (8 KB) formats.
- `JSONSchema.Document` gains `fixplan` and `verify` (draft 2020-12, closed vocabularies as `enum`s), and
  `SchemaCommand.SchemaDocument` gains `fixplan`, `verify` (`all` includes them). `V06Samples` validate in strict mode.

## HTML (lane C; DESIGN §8.2.4 #13 and #6)

- `HTMLReporter.renderVerify(_:options:)` and `HTMLReporter.renderFixPlan(_:options:)` (phase-1 stubs throw): the
  template with the document's pretty JSON as `#xcblame-data`, byte-equal to `--format json` apart from script escapes
  (the `renderTrend` pattern; no budget pass needed: a verify document is a few KB). The page dispatches on
  `KIND === 'xcblame.verify'` and `'xcblame.fixplan'` like compare/trend.
- DOM contract, verify (`#verify`): `<section id="verify" data-total="<results count>">`; in the cockpit (amended
  2026-11-08: `#headline` "Kept N, reverted M." and the next command in `#start-actions`) the block `#verify-start`
  with one plain sentence per unit ("Turning on SET-004 made clean builds 2.0 s faster (12 %), more than the noise
  band: kept."); `#verify-abort` banner when `abort` is set (reason in plain words and what to do); table
  `#verify-results`, one `tr[data-rule="<ids joined by +>"][data-verdict="kept|reverted|indicative|unverified"]`
  `[data-reason]` per unit with arm rows: runs ok/total, one dot per run `span.verify-run[data-arm][data-ok][data-settle]`
  (title: wall seconds), p50 ± MAD, noise band, verdict, mechanism, scope. (The "what this shows" paragraph above the
  table was removed on 2026-11-08.)
- Fix plan view: section 6's renderer over `steps[]` (`#fixplan`, `tr[data-rule][data-state][data-verify]`), the
  guards, the hook state per configuration, and copy buttons for `commands`.
- ~~Junior-reader standard of v0.5: Start-here box, plain sentences, "what this shows" per section, glossary entries
  for `arm`, `p50`, `MAD`, `noise band`, `mechanism`, `overlay`, `hook`, `revert`, `settle build`, `indicative`;
  checked by `HTMLClarityTests` additions.~~ **Amended 2026-11-08 (cockpit, DESIGN §8.2.5 "Cockpit decision"):** every
  page opens with `#headline` and at most three `#start-actions` (`li.act` with what, saving, confidence, one copyable
  command and how to undo it); the page's own section starts open, the rest is collapsed; no "what this shows" lines and
  no glossary on the page: those entries moved to [REPORT.md](REPORT.md). Checked by `HTMLCockpitTests` and
  `HTMLTemplateTests.testProseBudget`.
- Template budget 280 KB (269 KB now): lane C has about 11 KB; `make template` after editing `report.html`. (Raised to
  300 KB on 2026-11-05, lowered to 200 KB on 2026-11-08, DESIGN §8.2.1 #4.)

## report: previous (D1, 2026-11-08)

One additive member of `xcblame.report/1`, for the HTML headline's delta clause ("12 % slower than the previous clean
build (16.2 s, 3 days ago)"). It always serializes; `null` when there is no previous build, with no note (the
`regression` precedent).

```json
"previous": { "span": 16.2, "kind": "clean", "generatedAt": "2026-11-05T10:15:00Z", "id": "20261105-101500-clean" }
```

| Member | Type | Meaning |
|---|---|---|
| `previous` | object or null | The previous comparable build in the local history. |
| `previous.span` | number | That entry's `build.span` (log span, seconds). |
| `previous.kind` | string | That entry's `build.kind`, equal to this report's. |
| `previous.generatedAt` | date-time | That entry's own `generatedAt`. |
| `previous.id` | string | The history entry id (`history show` and `analyze <id>` take it). |

- Filled by `analyze` (on a log) and `build` from `<xcblame-dir>/history` before the new entry is written
  (`ReportDocument.Previous.lookup`): the newest entry that started strictly earlier than this build (history entries
  carry `buildStart`, the log's start time, since 2026-11-09; older entries fall back to `generatedAt`), with the same
  `build.kind` and the same `build.scheme` (both null counts as the same), that is not a `build --deep` run
  (`deep.enabled`), has a span, and is not the entry of the same log (re-analyzing a log never compares it with
  itself). A deep build itself gets `null` (its task times are not comparable).
- `null` when the report's kind is unknown, when no entry qualifies, with `--no-history`, for `--model-json` input and
  for doctor documents. A saved report or history entry re-rendered with `analyze <file|id>` keeps the value it was
  written with; one written before the member existed decodes with `null`.
- `xcblame schema --document report` lists it (`$defs/Previous`, nullable, required like every always-serialized
  member). The HTML page uses it before `regression` (DESIGN §8.2.4 "First screen").

## Lane ownership

**Shared files nobody edits after phase 1** (a change goes to the integrator): `Model/FixPlanDocument.swift`,
`Model/VerifyDocument.swift`, `Model/FixPlanStore.swift`, `Build/StateFiles.swift`, `Reporters/ReportDocument.swift`,
`Reporters/Nullable.swift`, `History/History.swift`, `Sources/xcblame/{Xcblame,ExitCode,GlobalOptions}.swift`,
`docs/SCHEMA-v0.6.md`, `Tests/XcblameKitTests/Reporters/SchemaV06ContractTests.swift`,
`Tests/xcblameTests/CLIRunner.swift`. Lanes may add extensions to the frozen types in their own files.

| Lane | Owns |
|---|---|
| A Fix | `Sources/XcblameKit/Fix/*` (`FixPlanner` conforming to `FixPlanning`, `OverlayFile`, `HookInstaller`, `DefaultsApplier`, `Revert`, `Backups`), the `// v0.6 lane A` block of `Sources/xcblame/FixCommand.swift` (and new private helpers in that file), tests `Tests/XcblameKitTests/Fix*Tests.swift`, `Tests/xcblameTests/FixCLITests.swift` (replaces the stub tests), fixtures `fixtures/projects/AcmeFix*` (synthetic). |
| B Verify | `Sources/XcblameKit/Verify/*` (`ABRun` conforming to `Verifying`, arms, `VerifyDerivedData`, settle, validity checks, declared-effect table, verdicts, aborts, preconditions, the scripted fake runner protocol for tests, §12 item 7), `History/History+Verify.swift` (save/list/show of `history/verify/`), the `// v0.6 lane B` blocks of `Sources/xcblame/VerifyCommand.swift` and `HistoryCommand.swift` (prune), tests `Tests/XcblameKitTests/Verify*Tests.swift`, `Tests/xcblameTests/VerifyCLITests.swift` (replaces the stub tests). |
| C Report | `Reporters/TextReporter+Fix.swift`, `Reporters/TextReporter+Verify.swift`, `Reporters/JSONReporter+FixVerify.swift`, `Reporters/Formats/MarkdownReporter+FixVerify.swift`, `Reporters/Formats/AgentReporter+FixVerify.swift`, `Reporters/HTML/HTMLReporter+Verify.swift`, `Resources/report.html` (verify and fixplan regions, glossary), `Reporters/HTML/ReportTemplate.swift` (regenerated), `Reporters/Schema/JSONSchema.swift`, `Sources/xcblame/SchemaCommand.swift`, the Redactor extension for both documents (`Reporters/HTML/Redactor+FixVerify.swift`), `Reporters/ReportDocument+Doctor.swift` (`isFutureCommand` / `futureNote` only, see Integration notes), tests `Tests/XcblameKitTests/{FixVerifyText*,FixVerifyFormats*,HTMLVerify*,FixVerifySchema*}Tests.swift`, `HTMLClarityTests` additions. |

Lane notes:
- **A** Suggested fixtures (each a tiny synthetic project, settings in a project-level `Config/<Config>.xcconfig`):
  `AcmeFixWin` (Debug `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym` → SET-004, a real clean-build win, kept;
  `GenerateDSYMFile` is its declared effect), `AcmeFixNoop` (a planted setting whose fix changes nothing measurable on
  a tiny target → reverted within noise), `AcmeFixBreaker` (a script phase with declared outputs that reads an
  undeclared input, so SET-030's `ENABLE_USER_SCRIPT_SANDBOXING = YES` breaks the build → reverted broke build).
  Unit tests never run xcodebuild; the opt-in e2e (`XCBLAME_E2E=1`) builds copies of the fixtures.
- **A** The planner is a pure function of `FixPlanRequest` plus the oracle-with-wrapper call for `cli` rows; inject the
  oracle call for tests. Plan id per "Fix plan document".
- **B** `ABRun` takes the runner through a protocol (`VerifyBuildRunning`, lane B's own) so tests script durations,
  noise, failures, thermal states and task-set changes; the real one wraps `XcodebuildRunner.run` and the report
  pipeline (critical path, task kinds).
- **B** Verdict writing uses `FixPlanStore.save`; a stored plan whose id differs from `VerifyDocument.planId` is never
  touched.
- **C** Renders only from the documents; no engine calls. The text and HTML wording follows the "verdict" spelling
  above.

## Decisions

Taken in phase 1 (2026-11-04), with the probe results (probes-v0.6.md, 26.0.1 and 27.1 beta agree):

1. **Precedence** (probes Q1), low to high: project xcconfig < project settings < target xcconfig < target settings <
   `KEY=VALUE` < `-xcconfig` < `XCODE_XCCONFIG_FILE`. Three ordered command-line levels, not one.
2. **Shadowing is a hook-only concept** (probes Q3, Q9): a target-level pbxproj value without `$(inherited)` does not
   shadow `-xcconfig` or `KEY=VALUE`, so `cli` delivery reaches every key on every project and package target.
   `scope[]` `cli` rows are `reached` by construction; the oracle check confirms, it does not gate. `shadowing` /
   `shadowedBy` describe the `hook` mechanism only. A fully hook-shadowed overlay step plans `mechanism: cli`
   (CI, `build --overlay`, `verify --mechanism cli`) or `recommend` for IDE builds.
3. **`XCODE_XCCONFIG_FILE` beats `-xcconfig`** (probes Q4): the wrapper includes the user's `-xcconfig`, then the env
   file, then the overlay, and unsets the variable for the child (v0.5 behaviour kept).
4. **`#include?` only** (probes Q5): silent when missing, resolved against the including file's folder first, then
   SRCROOT. A plain `#include` of a missing file fails the build while `-showBuildSettings` exits 0, so the hook
   installer checks the include target exists itself and confirms with a real `-showBuildSettings`.
5. **Conditions** (probes Q6): `[sdk=…]` allowed on overlay lines (`OverlayLine.condition`); `[config=…]` never written
   (one file per configuration). The offline resolver must evaluate stacked conditions in either order (noted for the
   integrator; `Settings/` is not a lane file).
6. **Hook is the last line** (probes Q7): appended at the end; `fix --apply` warns when lines follow it.
7. **List keys start with `$(inherited)`** (probes Q2, Q7).
8. **Defaults** (probes Q8): `--apply-defaults` covers only `IDEBuildOperationMaxNumberOfConcurrentCompileTasks`;
   `ShowBuildOperationDuration` (ENV-001) is display-only and never a `defaults` step; CI uses `-jobs N`.
9. **Package targets** (probes Q9): hook scope = project targets only; `cli` scope = project + package targets.
10. `fixKind` keeps the finding's vocabulary (`recommend`, not `rec`; `cli` and `measure` included); `hook` is a
    mechanism, not a fix kind; `defaults` is both a fix kind and a mechanism.
11. `VerifyStatus` adds `indicative` (§7.8 step 4) to the brief's `unverified | kept | reverted`; `RevertReason` adds
    `noEffect` (oracle check shows no reached target: not built).
12. `fix --apply` writes only `kept` steps (Appendix B item 24); `--force-unverified` also writes `unverified` steps
    that are not `+V`; `reverted` and `indicative` never.
13. `--edit-project` is parsed and rejected (exit 2) in v0.6: §7.6 project editing waits for MV-4 (v0.7). The hook's
    pbxproj `baseConfigurationReference` variant is out of scope; a project without a project-level base xcconfig gets
    `hook.status: unavailable` with the manual step (create `Config/<C>.xcconfig` holding the `#include?` line and set
    it in Project › Info › Configurations) and `cli` for xcodebuild.
14. A base xcconfig shared by several configurations gets no hook for any of them (an `#include?` path cannot name the
    configuration; `$(CONFIGURATION)` expansion in include paths was not probed); `unavailable` with that reason.
15. `fix` without write flags stores the plan in `plans/` (xcblame state, git-ignored), so `verify` and `--apply` find
    it; the project is untouched.
16. Plans and backups are git-ignored; overlay files are committed. `--revert <id>` needs only the overlay blocks
    (and, for defaults, the local backup), so it works in a teammate's checkout.
17. Verify history entries live in `history/verify/` (a subfolder `History.list` never reads), so `previousIndex`,
    trend, baseline and retention exclude them without touching their code. Individual verify builds are not saved as
    history entries.
18. `verify --kind incremental` takes `--touch`, else touches a file it picks; xcodebuild arguments are optional
    (derived from the plan's analysis).
19. Overlay block end line is `// end xcblame plan <id> rule <RULE>` (matched pair) rather than a bare `// end`, so a
    hand edit cannot make revert remove the wrong lines.
20. Phase-1 CLI stubs exit 2 (usage) with "not implemented in this build", so nothing fake succeeds (the v0.5 stubs
    used exit 1). Tests for the stubs are replaced by the lanes.
21. JSON Schema validation of `V06Samples` is lane C's (the schema does not exist yet); phase 1 pins member names and a
    JSON round trip instead.

Taken at integration (2026-11-05):

22. **Fixed mtime per arm** (lane B): under `--mechanism hook` arm B writes its temporary block in place (same inode)
    and sets one fixed modification time per arm (`OverlayGuard.write(_:to:modificationDate:)`), so a series of
    incremental or zero-change builds sees the same xcconfig and does not re-plan; the original bytes and mtime come
    back after each B run. The block format (header, begin/end lines, parsing, byte-exact removal) is lane A's
    `OverlayFile`; `VerifyOverlay` only adds the temporary blocks and `OverlayGuard`.
23. **Shadowed overlay findings plan `cli`** (Decision 2 applied to `FindingBuilder`): a fully hook-shadowed finding
    keeps `fixKind: overlay` and its `overlayLines`; its mechanism text is "shadowed by <levels>: cli (an -xcconfig on
    the xcodebuild command line reaches every target; xcblame verify --mechanism cli measures it), or for Xcode
    builds recommend …" and its only command `xcblame verify --rules X --kind K --mechanism cli` (no `xcodebuild …
    KEY=VALUE`, no `--edit-project`). The planner marks the step `mechanism: cli`, `shadowing: full`; the report's
    fix plan adds the `inXcode` lines as manual steps for Xcode builds.
24. **`verify` builds its own plan**: no stored plan with the selected rules → a fresh plan through `FixPlanner` (doctor
    pass plus the newest non-deep history entry, `PlanLoading` shared with `fix`), stored in `plans/`; the container
    is the `-project`/`-workspace` after `--`, else the current folder. Exit 1 only when there is no analysis at all.
25. **`ReportDocument.FixPlanStep.verifyStatus`** (optional, additive, `xcblame.report/1` unchanged): the rule's verify
    state from the newest stored plan that measured it, in the text spelling (`FixPlanner.verifyLabels`), set on the
    `verify` and `fix` steps by `analyze` and `doctor`; the HTML fix plan shows it as a small "verify: kept" note.
26. **Signals**: SIGINT/SIGTERM during a verify build stop the running xcodebuild tree first (`XcodebuildRunner.Cancel`,
    SIGTERM then SIGKILL after 5 s, wired through `VerifyInterrupt.onRaise`), then restore the overlay; exit 6
    `interrupted`.

Taken in fix round 1 (2026-11-06, docs/reviews/code-review-v0.6.md "Fix round 1"):

27. **Hook text is two lines** (review gap 3, minor 4): `// xcblame hook (fix --install-hook); remove with: xcblame
    fix --uninstall-hook` then the `#include?`, appended with no blank line before them. Probe (AcmeFixWin copy,
    Xcode 26.0.1, `-showBuildSettings -json` with `-derivedDataPath` in the scratchpad): the comment line is harmless,
    the overlay's `DEBUG_INFORMATION_FORMAT = dwarf` wins. Uninstall without a backup (a teammate's clone) removes
    exactly those two trailing lines when they match byte for byte, else exit 1 with the remove-by-hand message.
28. **Symlinked base xcconfig** (review M1): edit the link's target in place, keep the link (`lstat` after writing),
    include path relative to the link's folder. Probe (same setup, `Config/Debug.xcconfig` a symlink to
    `../shared/Debug.real.xcconfig`, `inc-a.xcconfig` with different values in both folders): includes in the target
    resolve against the **link's** folder (`XP_DIR = link`, `XP_SHARED = link`). `hooks.json` records `path` (target)
    and `link`; uninstall follows the link again and restores the target byte-identical.
29. **`xcblame build --overlay [<plan-id>] [--overlay-unverified]`** (review gap 1; DESIGN §3.2, §7.5): the newest
    stored plan with a deliverable step (or the given id); deliverable = an `overlay` step `kept` (with
    `--overlay-unverified` also `unverified` and not `+V`), never `reverted`/`indicative` or `fix --revert`ed. Its lines
    for `-configuration` (required after `--`, exit 2 without) go into `tmp/build-overlay-<C>.xcconfig`, included by the
    wrapper after the user's `-xcconfig` and `XCODE_XCCONFIG_FILE` (unset for the child), before `--deep` lines. The
    oracle (`-showBuildSettings` with the same wrapper and arguments) runs first: any overlay key that did not win on a
    target of the step's cli scope is an error naming it and **nothing is built** (exit 1; the DESIGN §7.5 text
    "reported and not counted as applied" becomes a refusal, since probes Q1/Q3 say this can only be a bug or an
    unprobed Xcode). The report's `build.notes` gets `overlay: <plan-id> (<rules> for <C> …; oracle check: …)`, so
    `compare` and `trend` see it. A `KEY=VALUE` argument naming an overlay key gets a warning (it loses, probes Q1).
    `fix --apply` records such cli steps `applied-cli` (a new `StepState`) and prints the exact command.
30. **Verdict basis** (review gap 2): `VerifyState.basis` / `UnitResult.basis` = 16 hex over rule id, overlay
    assignments, container, the step's planned verify kind and mechanism, its scope rows (target, configuration, key,
    mechanism, reached) and the project files' content digest (`SettingsCache.inputs`: pbxproj, xcconfigs and their
    includes, schemes, manifests, lockfiles; files inside the xcblame dir and the two hook lines left out). `carryOver`
    reuses a verdict (same plan, another plan's identical step, a history entry) only when the new step's basis is
    equal; otherwise the step is `unverified` with the note "<RULE>: project changed since verify (<verify id>)". A
    verdict without a basis (older plans) is never reused.
31. **Verify journal** (review M2): `tmp/verify-inflight.json` (`{planId, rules, pid, startedAt, entries: [{path,
    original (base64, nil = absent), modificationDate}]}`), written before arm B's first temporary write, removed after
    the restore. `fix`, `verify` and `build` call `VerifyJournal.recover` first: a journal whose pid is not alive and
    whose file still holds a `(temporary)` block gets the original bytes and mtime back, one `warning:` line. The
    overlay parser reads temporary blocks (`Block.temporary`): `fix --revert <id>` removes them, `--apply` treats their
    keys as owned, auto-revert and arm A see them. SIGHUP and SIGQUIT are handled like SIGINT/SIGTERM.
32. **No oracle DerivedData under `~/Library/Developer`** (verifier finding C): the hook installer's verifier and the
    planner's cli oracle use `SettingsOracle.effectiveInScratch` (the v0.3 scratch workspace and generated scheme in
    `OracleCache.directory`, `-derivedDataPath` there, sandboxed without packages) instead of `-project -target` /
    `-alltargets`, which cannot take `-derivedDataPath`.
33. **Incremental verify commands name a file to touch** (verifier finding D): the plan's `xcblame verify … --kind
    incremental` command ends with `--touch <the largest .swift file of the step's target folder>`.

Taken in fix round 2 (2026-11-06, docs/reviews/code-review-v0.6.md "Re-check 1", "Fix round 2"):

34. **Journal recovery restores any arm's write** (amends 31): when the verify is dead, every journaled file whose
    bytes differ from the journaled original gets the original back (an arm A write strips applied blocks). The journal
    also stores `processStart` (seconds since 1970, `sysctl kern.proc.pid`); a live pid that started at another time
    is a reused pid, so the verify counts as dead.
35. **Ignored signals stay ignored**: `VerifySignals` catches only those of SIGINT/SIGTERM/SIGHUP/SIGQUIT whose
    disposition is not `SIG_IGN` (`nohup xcblame verify …` survives closing the terminal).
36. **`build --overlay` is per container** (amends 29): without a plan id only plans whose `project.container` is the
    build's container are considered; none deliverable is exit 2 "no plan for <container>; run xcblame fix" and
    xcodebuild never runs. A step kept through `hook` is delivered only when its hook and cli scope rows agree
    (`sameScope`, rule 3 the other way round); otherwise it is left out with a note.
37. **`applied-cli` reverts**: `fix --revert` (and `newestApplied`, which now counts `applied-cli`) and a reverted
    verify move `applied-cli` steps to `reverted`, so `build --overlay` stops delivering them.
38. **Hook upgrade and digest**: `--install-hook` replaces a pre-fix-round hook (blank line, `// xcblame hook: xcblame
    fix --uninstall-hook removes these lines`, `#include?`) in place with the two-line hook, backing up the file without
    it. `VerifyBasis.projectDigest` drops both hook formats and trailing empty lines, so hooking an unterminated file
    does not change it.
39. **Task-set check honours declared effects by kind and count** (verifier round 2: SET-004 on AcmeFixWin was
    `reverted (task set changed)`): `VerifyVerdict.declaredEffects` (kinds a fix adds or removes: may appear, disappear
    or change count) now covers every catalog SET rule whose fix changes a task kind by definition (SET-001/009/015
    Swift job shapes, SET-004 `GenerateDSYMFile`, SET-005 `CreateUniversalBinary` and header merging, SET-011
    validation, SET-013/014/016 module builds, SET-021 PCH, SET-022 header-map auxiliary files, SET-023 TAPI/link,
    SET-029 strip, SET-032 module-interface emission/verification, names for SET-032 not yet confirmed from a log);
    `declaredCounts` lists kinds whose presence must match but whose count may change (SET-005: one architecture in
    arm B halves every per-arch task). `cacheDependentKinds` (explicit/implicit module PCM builds and the modules
    report) are never compared: they run only on the first clean build of a fresh per-arm module cache, whatever the
    change, which is what made SET-004's B arm differ. Undeclared differences still give `reverted (task set changed)`.
    SET-028 (LTO happens inside `Ld`) and the `rec`-only PHASE rules declare nothing; SET-012 is not in the catalog.
    **Amended in fix round 3 (2026-11-06; main @ 3dae7b6 gave SET-005 `reverted (task set changed)` on `SwiftDriver
    Compilation`, `SwiftDriver Compilation Requirements`, `ConstructStubExecutorLinkFileList`):** the per-kind
    `declaredCounts` list is replaced by an *architecture-count effect* (`architectureCountRules`: SET-005, SET-006,
    the `ONLY_ACTIVE_ARCH`/`ARCHS`/`VALID_ARCHS`/`EXCLUDED_ARCHS` rules of docs/RULES.md). For those rules every kind is
    compared by presence, not count: the compile and link work (`SwiftCompile`, `CompileC`, `Ld`) and every other kind of
    arm A must still be in B, B may add none, and only the declared multi-arch-only kinds (`CreateUniversalBinary`,
    `SwiftMergeGeneratedHeaders`, `GenerateTAPI`) may disappear. A `taskKinds` failure is at most two lines: up to three
    kinds with their counts (`2 → 1`, `only in B`, `missing in B`), then the effect the rule would need (an
    architecture-count effect when only counts changed, else the kinds in its declared effect).
40. **Oracle-blind keys** (fix round 3): `-showBuildSettings` over the generated all-targets scheme reports
    `ONLY_ACTIVE_ARCH = NO` whatever the project says (no destination). So (a) the hook installer's check reads such
    keys (`HookInstaller.oracleBlindKeys`) from the project files with the offline resolver; (b) Decision 36's
    kept-through-hook comparison for `build --overlay` compares the reached `(target, configuration, key)` rows of
    both mechanisms, not the plan's cli `after` values, and `build --overlay`'s own oracle (the build's arguments,
    destination included) still checks every value before building. The "nothing to deliver" error names why each
    step of the container's newest plan is left out.

## DESIGN amendments for the integration agent

- §7.4: the inheritance line ends "… < target settings < command line"; replace with the three ordered command-line
  levels `KEY=VALUE` < `-xcconfig` < `XCODE_XCCONFIG_FILE` and drop "disputed"/MV-3 wording for the order (probes Q1).
- §7.5 point 3 and "Shadowing": shadowing applies to the hook only; command-line delivery is not shadowed by
  target-level values (`$(inherited)` or not). The finding's offer order becomes: `cli` (always reaches, oracle
  confirms), then recommend. "Content": `[sdk=…]` conditions allowed; `[config=…]` unnecessary (MV-9 answered).
- §7.5 hook bullet: `#include?` appended as the last line, path relative to the including file; installer lints the
  include target.
- §7.3 `defaults` row: limited to `IDEBuildOperationMaxNumberOfConcurrentCompileTasks` in v0.6; ENV-001 is
  `recommend`.
- §7.8 step 6 / §3.5: add `indicative` and `reverted (no effect)` to the verdict list.
- §10.1: MV-3 and MV-9 resolved by probes-v0.6.md (keep the `PROJECT_DIR` vs `SRCROOT` caveat and the unprobed
  `defaults` effect).
- §3.2 `fix` row: `--edit-project` not in v0.6; add `--force-unverified`, `--from`; `verify` row: add `--touch`,
  `--plan`, optional `-- <xcodebuild args>`.
- RULES.md / `FindingBuilder`: the shadowed-overlay mechanism text ("cli on CI (only if the oracle confirms …)") and
  the `xcodebuild … KEY=VALUE` command should become the wrapper delivery (`xcblame build --overlay` /
  `verify --mechanism cli`), since `-xcconfig` beats `KEY=VALUE` and both beat target settings.

## Integration notes

- Merge order A, B, C. Expected conflicts: `ReportTemplate.swift` (regenerate with `make template` after C), the stub
  tests in `FixCLITests.swift` / `VerifyCLITests.swift` (the lane versions win), `HistoryCommand.swift` (B's block
  only).
- Bump `XcblameVersion.current` to `0.6.0` (and the tests that pin it).
- Until C merges, A and B emit text through the phase-1 stubs (one line) and json through `JSONReporter`; their CLI
  tests use `--format json`.
- `ReportDocument.isFutureCommand` / `futureNote` (lane C): `xcblame verify` and `xcblame fix` steps stop being
  labelled "available in xcblame 0.6"; only `--edit-project` commands keep a label ("not available yet: make the change
  by hand"), in text, markdown and HTML (`FUTURE` in `report.html`).
- Doctor/analyze fix-plan steps (`ReportDocument.fixPlan`) keep printing `xcblame fix --rules X --apply`; after the
  merge `fix --rules X --apply` must accept them unchanged.
- The offline resolver's stacked-condition evaluation (Decision 5) and the `FindingBuilder` shadowing text
  (amendments) are integrator changes outside every lane.
