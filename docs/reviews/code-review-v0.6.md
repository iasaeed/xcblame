# xcblame v0.6 "Fix": fresh-eyes code review

Scope: `git diff c554ca2..cbf8d90` (Fix/Verify kits, Reporters, FixCommand/VerifyCommand/PlanLoading/FixVerifyOutput, FindingBuilder,
History+Verify, Cancel). Contract: docs/SCHEMA-v0.6.md, DESIGN §7.3-7.5, §7.8, §8.4. Reviewed by reading plus focused repros under
`/private/tmp/claude-501/-Users-you-Projects/af624146-a990-430f-a625-aea8fae4b5e2/scratchpad/review-v0.6/` (fixture copies only; no xcodebuild,
no `defaults write`). Existing suites for Fix*/Verify*/SchemaV06 pass (53 tests).

Counts: 2 major, 12 minor, 3 requirement gaps.

## Majors

### M1. Symlinked base xcconfig: `--install-hook` replaces the symlink with a regular file; `--uninstall-hook` then fails and leaves the hook
- `Sources/XcblameKit/Fix/HookInstaller.swift:166` (`hooked.write(to: site.xcconfig, options: .atomic)`), `:147`/`:172` (record path), `:233-243`, `Fix/Backups.swift:112-124` (`FixPaths.canonical`).
- What breaks: an atomic write to a symlink path swaps the link for a regular file (verified with Foundation: `symlink survives atomic write: false`), so the hook lands in a
  copy and the real target is untouched. The user-visible name and the hook record come from `FixPaths.display`, which resolves symlinks, so `hooks.json` stores the
  *target* path (`shared/Debug.real.xcconfig`). Uninstall then reads the untouched target: sha differs from `hookedSHA256`, the textual fallback finds no hook lines,
  and it reports "edited by hand ... remove them yourself". The symlink is already gone (git shows typechange `T`) and the hook stays.
- Repro (done): copy `fixtures/projects/AcmeFixWin`, move `Config/Debug.xcconfig` to `shared/Debug.real.xcconfig`, `ln -s ../shared/Debug.real.xcconfig Config/Debug.xcconfig`,
  commit, `xcblame fix --offline --rules SET-004 --configuration Debug --install-hook` (prints "hook appended to shared/Debug.real.xcconfig"), `ls -la Config`
  (regular file, 556 bytes), `xcblame fix --offline --configuration Debug --uninstall-hook` -> exit 1, hook still present.
- Fix: resolve the xcconfig with `resolvingSymlinksInPath()` before read/backup/write (write to the real file, record that path), or classify a symlinked xcconfig as
  `unavailable` ("is a symlink"). Verify the written file with `lstat` after install.

### M2. Hook-mechanism verify leaves a live temporary block in the committed overlay on SIGHUP, SIGQUIT, SIGKILL or a crash; nothing can find it afterwards
- `Sources/XcblameKit/Verify/VerifyOverlay.swift:87-99` (in-place `Data.write`, original bytes only in memory), `:139-161` (`VerifySignals` handles only SIGINT and SIGTERM).
- What breaks: closing the terminal tab during a long verify delivers SIGHUP, whose default action terminates xcblame before any restore. Arm B's
  `// xcblame verify <plan> rule R (temporary)` block stays in `.xcblame/overlay-<C>.xcconfig`, and because the hook includes that file, every later Xcode/xcodebuild build
  silently uses the unverified change. `OverlayFile.blocks` skips verify blocks on purpose, so `fix --revert`, `--apply` conflict detection (`owners`) and auto-revert never
  see it. In a git tree the next verify aborts `dirtyTree` (recoverable with `git checkout`); outside git (precondition is only `warn`) the original bytes are lost.
- Repro: run a `--mechanism hook` verify on a fixture with a fake slow `XCBLAME_XCODEBUILD`, `kill -HUP <xcblame pid>` while arm B builds, `cat .xcblame/overlay-Debug.xcconfig`.
- Fix: add SIGHUP (and SIGQUIT) to `VerifySignals`; persist the pre-write bytes (e.g. `tmp/verify-restore-<C>.json`) and have verify/fix start by restoring or at least refusing
  with a clear message when a `(temporary)` block exists; make `blocks` report leftover verify blocks as hand-edit errors instead of skipping them.

## Minors

1. `Sources/XcblameKit/Fix/FixApply.swift:189-194` + `Verify/ABHarness.swift:621`: auto-revert of ONE applied rule appends a `revert` event to the plan, so `newestApplied` (what
   `fix --revert` without an id uses) treats the whole plan as reverted. Scenario: apply rules A and B, `verify --rules A` reverts A, `fix --revert` prints "nothing to revert" while
   B's block is still in the overlay (works only with an explicit plan id). Fix: record per-rule state (derive "applied" from steps with `state == .applied`) rather than the last event.
2. `Fix/OverlayFile.swift:84,126`: a block's range starts at the newline before its begin line; when a hand edit removes the blank line between two blocks of the same plan the ranges overlap by
   one character and the reversed `removeSubrange` deletes one extra character after the second block (repro in `scratchpad/review-v0.6/ov/main.swift`: the blank line before a trailing user
   comment disappears). Same code in `VerifyOverlay.removingPlanBlocks`. Fix: clamp `start` to the previous block's end, or merge overlapping ranges before removing.
3. `Fix/HookInstaller.swift:141,167,161`: hook records are saved once at the end, and the installer only rolls back on `check` failure. Ctrl-C (or a crash) during the online
   `-showBuildSettings` verifier of configuration N leaves hooked files without a `hooks.json` row; `--uninstall-hook` then says "no xcblame hook recorded" and `--install-hook` says
   `alreadyInstalled`, so the tool cannot remove its own lines. `try? Backups.saveHooks` also swallows a write failure. Fix: save the record before `check` (drop it on rollback), save per file, surface errors.
4. `Fix/HookInstaller.swift:214-261` + `Build/StateFiles.swift` (`backup/` is git-ignored, the hook lines are committed): in a teammate's clone or a fresh checkout
   `plan.hook` reports `installed` but `--uninstall-hook` reports "no xcblame hook recorded". Fix: when no record exists, scan `sites` for the marker and use the textual removal.
5. `Verify/ABHarness.swift:117,123,420`: when the user passes xcodebuild args after `--` without `-configuration`, verify derives the configuration from the overlay lines (e.g. Debug) but
   builds without `-configuration`, which xcodebuild resolves to the project default (normally Release). Hook arm: the Debug overlay is never read, both arms are identical, verdict `reverted (within noise)` and
   auto-revert removes a good applied block. PLAUSIBLE (xcodebuild default-configuration behaviour not run here). Fix: append `-configuration <c>` or exit 2 when it is missing.
6. `Verify/ABHarness.swift:126-128`: arm A strips only blocks of `plan.id`. If the same rule/key was applied under another plan id (apply under P1, later `fix`/`verify` picks newer plan P2 with the same step),
   arm A still contains the lines, arm B adds the same key: no delta, spurious `reverted (within noise)`, and `autoRevert` (which only acts on P2's `.applied` steps) leaves P1's block. Fix: strip blocks of any plan
   that set a key the unit sets.
7. `Verify/ABHarness.swift:437-441,345-348,329`: a Ctrl-C reaches xcodebuild through the process group, but `isRaised` is set later by the dispatch-source handler. If the killed build is processed first, a B run is
   recorded `reverted (broke build)` (and auto-reverted) or an A run aborts `baselineBroken` instead of `interrupted`. PLAUSIBLE (race window is small). Fix: treat a signal-terminated xcodebuild (uncaught signal / 130 / 143)
   as interrupted, or re-check `isRaised` after a short settle when `ok` is false.
8. `Verify/ABHarness.swift:395`, `XcodebuildVerifyRunner.swift:70-74` (`timeout: nil`): `--max-minutes` is only tested before a build starts. A build starting at minute 29 of 30 (plus its `clean`) runs to completion, and a hung
   xcodebuild is never stopped. Fix: pass the remaining budget as the runner timeout, abort `timeout` when it fires.
9. `Verify/ABHarness.swift:561-587`: `autoRevert` can throw (`editedByHand` for another configuration's overlay file, a write error). `recordVerdicts` then throws before `FixPlanStore.save` and before
   `History.saveVerify`, so all verdicts of a long run are lost and the command exits 1. Fix: catch per rule, add a note, still save.
10. `Fix/FixApply.swift:119-121`: `--force-unverified` writes an `unverified` step whose planned mechanism is `cli` (fully shadowed): the lines go into the overlay but the hook cannot reach them. Also `--apply` with the hook not
    installed prints "wrote ..." with no warning that nothing takes effect (the `hookInstalled` guard exists only in the plan). Fix: skip or warn.
11. `xcblame/FixCommand.swift:138`: `--plan-out` writes `JSONReporter.render(plan)` unredacted, ignoring `--redact` (absolute container path, user, host in the file). The stdout/`-o` path is redacted via `prepareForOutput`; this one is not.
    Fix: render `ReportPipeline.prepareForOutput(plan, redact: global.resolvedRedact)`.
12. `Verify/VerifyVerdict.swift:69-84`: `declaredEffects` has no entry for SET-032 (`BUILD_LIBRARY_FOR_DISTRIBUTION = NO` removes the swiftinterface emission/verification tasks) or SET-028 (LTO). In a clean verify those kind differences
    would be judged undeclared: `reverted (task set changed)` for a real win. PLAUSIBLE (task rule names not confirmed from a log here). Fix: add entries or probe.

(Smaller notes, no separate number: `FixPlanner.commands` always lists `xcblame fix --apply` even when every overlay step is `cli` and `--apply` can only skip; defaults rows store non-integer prior types as `string` (arrays/dicts/dates would be
re-written as strings, harmless today because the only writable key is an integer); `--xcblame-dir` outside the project root puts a machine-specific `../..` include path into the committed xcconfig with no check; `Verify` DerivedData is never
removed after a run except by prune, by design.)

## Requirement gaps

1. **`xcblame build --overlay` is not implemented** (confirmed: `BuildCommand.swift:373,423` pass `overlay: nil`; no `--overlay` option in `build --help`), yet DESIGN §3.2/§7.3/§7.5 list it as the delivery for `cli` steps and
   it is referenced by `FixApply.swift:112` (skip reason), `TextReporter+Verify.swift:109`, SCHEMA-v0.6 rule 3 and Decision 2. Consequence: a step planned `cli` (every fully hook-shadowed finding, every plan made with `CI=true`) or kept through `cli` can be
   verified but never delivered by xcblame: `fix --apply` skips it with advice that names a nonexistent flag (`sameScope` is false whenever the hook rows are unreached). Either implement `build --overlay` (the wrapper with `overlay:` exists in `WrapperXCConfig`) or change
   the skip reason/notes to the manual `-xcconfig` recipe and record the deferral in DESIGN/PROGRESS.
2. DESIGN §7.5 "Before building, the oracle is run with the same wrapper": verify's `oracle` check (`ABHarness.oracleCheck`) only reads the scope rows stored in the plan, which can be days old; a changed xcconfig or pbxproj between `fix` and `verify` is not noticed
   (verdicts and plans are also carried across stale project states by `FixPlanner.carryOver`, which keys only on rule + assignments + container, not on project file state, mechanism or Xcode version; `kept (hook)` can survive until a target-level value makes the step fully shadowed, after which `--apply` still writes it).
3. SCHEMA "Hook"/Decision 16: `--revert` works in a teammate checkout, but `--uninstall-hook` does not (see Minor 4); the committed hook lines have no committed way to be removed by the tool.

## Checked and fine

- Overlay block grammar, append/remove byte-exactness for the normal flows: apply then revert restores byte-identical files and deletes a file apply created (repro on `AcmeFixWin`: apply, revert, file gone); two plans sharing a rule: second plan's step is skipped with the
  "key X is set by plan Y" message and revert of Y removes only Y's block; revert of an unknown plan id is "nothing to revert", exit 0, nothing written; hand-edited (unmatched begin/end) overlay makes apply and revert refuse before writing.
- Hook install/uninstall for ordinary files: backup bytes written before the edit, `#include?` path relative to the including file's folder, restored byte-identical when the file is unchanged (git clean after install+uninstall on AcmeFixWin); file without trailing newline gets one;
  CRLF files only gain an extra blank LF line (`"\r\n".hasSuffix("\n")` is false in Swift), harmless; read-only files are overwritten with permissions kept (Foundation behaviour), not refused; shared xcconfig, Pods xcconfig, generated projects and outside-folder files yield `unavailable`/`generated` with reasons; dirty/untracked files are refused.
  Backup name collisions (two files with identical bytes) are ref-counted on uninstall.
- Defaults: prior state saved to `backup/defaults.json` before the first write, re-apply keeps the first prior, revert restores or deletes, failure rolls back what the call wrote. Only the ENV-002 key is writable.
- `fix --apply` rules: kept-only; `--force-unverified` never applies `reverted`, `indicative` or `+V`; `cli`-kept steps skipped unless hook and cli reached `(target, configuration, key, after)` sets are identical (conservative when `after` is nil); fully shadowed findings plan `mechanism: cli` with only the verify command (no hook offered);
  plan id hashes source id, container, rule ids and `<Config>|KEY[cond] = VALUE` lines but not the line text (which embeds the id).
- Verdict logic matches the SCHEMA table: validity checks win over timing (`broke build`, `task set changed`, `no effect` not built), `indicative` for runs < 4 or < 3 samples, band = max(3 x pooled MAD, 2 % x A.p50), `kept (tie)` only for within-noise under `--keep-on-tie` (never for slower/indicative); non-clean kinds settle once per arm in per-arm DerivedData, clean interleaves ABAB with `clean` before each build; thermal run excluded and replaced once, second throttle aborts; A failure aborts `baselineBroken`; exit 6 for any abort with finished verdicts recorded, usage errors exit 2, other errors exit 1.
- Overlay restoration in the verify harness: restored after every run (`defer`), after the unit, in `run()`'s `defer` for thrown errors, and by the SIGINT/SIGTERM source after `Cancel.terminate()` kills the xcodebuild tree (sticky, so a later launch is stopped); inode and mtime preserved.
- `cli` mechanism: wrapper includes the user's `-xcconfig`, then `XCODE_XCCONFIG_FILE`, then the verify overlay with absolute paths; `unsetEnvironment` reaches both the `clean` and the build; both arms use the wrapper.
- Reporters: `Redactor.roundTrip` walks every string of both documents (fails closed); JSON Schema for `fixplan`/`verify` matches a real plan document produced by the CLI (required/optional and enums, checked with a script); `@Null` usage matches the schema's nullable fields; the HTML additions use `textContent`/`el()` only (no `innerHTML`); markdown and agent renderers are capped (`Fit`, `fitAgent`).
- Integration seams: `PlanLoading` with no history gives an analysis-less plan with a note (verify then exits 1 with a pointer); `verify` without a stored plan runs the doctor online and stores the plan; `CLIRunner` drains stderr concurrently; `FindingBuilder` shadowing change is consistent with the planner.

## Fix round 1 (2026-11-06)

Every finding below plus the verifier's findings A-D (real builds on main @ cbf8d90). Contract changes are recorded in
docs/SCHEMA-v0.6.md Decisions 27-33. Tests named `Suite.test…`.

Majors
- **M1 symlinked base xcconfig: fixed.** `HookInstaller.Site` keeps the path the project names and its resolved
  target; bytes are read, backed up and written at the target, the link is checked with `lstat` afterwards, the include
  path stays relative to the link's folder (probe on an AcmeFixWin copy: includes in a symlinked xcconfig resolve
  against the link's folder), `hooks.json` records `path` and `link`, uninstall follows the link and restores the
  target byte-identical. `FixHookTests.testSymlinkedBaseXCConfigIsEditedAtItsTarget`.
- **M2 verify crash safety: fixed.** `VerifyJournal` (`tmp/verify-inflight.json`: overlay path, original bytes
  base64, mtime, plan, rules, pid) is written by `OverlayGuard` before the first temporary write and removed after the
  restore; `fix`, `verify` and `build` call `VerifyJournal.recover` first (dead pid and a `(temporary)` block left: bytes
  and mtime back, one warning). SIGHUP and SIGQUIT are handled like SIGINT/SIGTERM. `OverlayFile.blocks` reads verify
  blocks (`Block.temporary`): `fix --revert <id>` removes them, `--apply` sees their keys as owned (never "already in
  the overlay"), arm A and auto-revert see them. `VerifyFixRoundTests.testHookVerifyJournalsTheOriginalBytesWhileArmBRuns`,
  `.testRecoverRestoresTheOverlayOfADeadVerify`, `.testSignalsCoverHangupAndQuit`,
  `FixOverlayTests.testTemporaryVerifyBlocksAreSeenByApplyAndRevert`.

Requirement gaps
- **1 `build --overlay`: implemented.** `xcblame build --overlay [<plan-id>] [--overlay-unverified]` (needs
  `-configuration`, exit 2 otherwise): `OverlayDelivery` picks the kept (optionally unverified non-+V) overlay lines,
  never reverted/indicative/`--revert`ed, writes `tmp/build-overlay-<C>.xcconfig`, the existing wrapper includes it
  after the user's `-xcconfig` and `XCODE_XCCONFIG_FILE` (unset for the child) and before `--deep` lines; the oracle
  with the same wrapper runs first and a key that did not win is an error naming it, nothing built (exit 1); the report
  notes `overlay: <plan-id> (…)` in `build.notes`; a `KEY=VALUE` naming an overlay key warns. `fix --apply` records cli
  steps `applied-cli` (new `StepState`) and prints the exact `xcblame build --overlay <id> -- -scheme <S>
  -configuration <C> build`. Every `--overlay` mention in Sources and docs is now true.
  `BuildOverlayCLITests` (help/usage, wrapper contents and call order, oracle refusal with the stubbed xcodebuild via
  `XCBLAME_XCODEBUILD` → `SettingsOracle.effective(withXCConfig:executable:)`, unverified/reverted selection),
  `FixOverlayTests.testKeptThroughCLIIsRecordedAppliedCLIUnlessScopesAgree`, `FixCLITests.testRefusals`.
- **2 stale verdicts carried over: fixed.** `VerifyBasis` (rule, overlay assignments, container, planned kind and
  mechanism, scope rows, content digest of the project's settings inputs without the xcblame dir and the hook lines)
  is recorded with each verdict (`VerifyState.basis`, `UnitResult.basis`, both `@Added`); `carryOver` reuses a verdict
  only on an equal basis, else the step is `unverified` with "project changed since verify (<id>)"; a verdict without
  a basis is never reused. (Verify's oracle check still reads the plan's scope rows; a plan made before a project change
  no longer carries its verdicts forward, which closes the stale-`kept` path the review describes.)
  `FixPlannerTests.testVerdictsOfAChangedProjectAreNotReused`, `.testVerifyStatesCarryOverFromStoredPlansAndHistory`,
  `VerifyFixRoundTests.testVerdictsCarryTheirBasis`.
- **3 uninstall in a teammate's clone: fixed** (with minor 4). The hook is two lines, `// xcblame hook (fix
  --install-hook); remove with: xcblame fix --uninstall-hook` and the `#include?` (probe: the comment line is harmless);
  without a `hooks.json` row uninstall removes exactly those two trailing lines when they match byte for byte, else
  exit 1 with the remove-by-hand message. `FixHookTests.testUninstallWithoutABackupRemovesTheTwoTrailingLines`,
  `.testInstallAppendsIncludeAsLastLineAndUninstallRestoresBytes`.

Minors
1. **Partial auto-revert: fixed.** `FixApply.newestApplied` is per step (`state == .applied`), so `fix --revert` without
   an id still finds a plan whose other steps are applied; auto-revert marks only the reverted steps.
   `FixOverlayTests.testPartialAutoRevertKeepsTheOtherAppliedStepRevertable`, `.testNewestAppliedSkipsRevertedPlans`.
2. **Overlapping block ranges: fixed.** A block's range starts no earlier than the previous block's end (both parsers
   share `OverlayFile.blocks`). `FixOverlayTests.testBlocksWithoutTheBlankLineBetweenThemDoNotOverlap`.
3. **Hook record saved late: fixed.** The row is saved per file before the file is written (a save failure writes
   nothing) and dropped on rollback; uninstall surfaces a `hooks.json` write failure.
   `FixHookTests.testHookRecordIsSavedBeforeTheCheck`, `.testVerifierFailureRestoresTheBackup`.
4. **No record in a clone: fixed** (gap 3 above).
5. **Missing `-configuration`: fixed.** Verify appends the configuration of the selected overlay lines and notes it.
   `VerifyFixRoundTests.testMissingConfigurationIsAddedToTheArguments`.
6. **Same key under another plan: fixed.** Arm A also leaves out other plans' blocks that set a measured key (noted);
   a reverted unit notes that block stays (`xcblame fix --revert <other>`); auto-revert does not touch another plan.
   `VerifyFixRoundTests.testArmAStripsAnotherPlansBlockOfTheSameKey`.
7. **Ctrl-C race: fixed.** A build ending with 129/130/131/137/143 waits up to 1 s for the interrupt flag before it
   is judged. `VerifyFixRoundTests.testASignalKilledBuildIsInterruptedNotBroken`.
8. **`--max-minutes` during a build: fixed.** `VerifyBuild.deadline`; `XcodebuildVerifyRunner` stops the running tree
   with `XcodebuildRunner.Cancel` on a timer and reports `timedOut`; the harness aborts `timeout`.
   `VerifyFixRoundTests.testMaxMinutesStopsARunningBuild`, `.testRunnerStopsTheBuildAtTheDeadline`.
9. **Auto-revert throwing loses verdicts: fixed.** Caught per unit (note), the plan and the history entry are still
   saved. `VerifyFixRoundTests.testFailingAutoRevertStillRecordsEveryVerdict`.
10. **`--force-unverified` on a cli step / no hook: fixed.** A cli-planned step is recorded `applied-cli` (with
    `--overlay-unverified` in its command), never written into the overlay; a written step whose configuration has no
    installed hook gets a warning. `FixOverlayTests.testKeptThroughCLIIsRecordedAppliedCLIUnlessScopesAgree`,
    `.testApplyWarnsWhenTheHookIsNotInstalled`.
11. **`--plan-out` unredacted: fixed.** Rendered through `ReportPipeline.prepareForOutput(plan, redact:)`.
    (Covered by the shared redaction path; no separate test.)
12. **`declaredEffects` SET-032/SET-028: declined.** docs/RULES.md defines no task-kind effect for either (SET-028
    "Debug NO; Release YES_THIN", SET-032 "NO for internal modules"; both `+V`, effect `?`), so adding task rule names
    would be a guess; a verify of either that changes the task set stays `reverted (task set changed)` until a log
    confirms the kinds.

Verifier findings (main @ cbf8d90)
- **A AcmeFixWin never kept: fixed.** 40 synthetic Swift sources (clean Debug ~10 s) and Debug `ONLY_ACTIVE_ARCH = NO`
  (SET-005, macOS: two architectures); EXPECTED.md has the commands. Scratch-copy run, `verify --rules SET-005 --kind
  clean --runs 5` (hook): `kept`, A p50 10.55 s (MAD 0.17), B p50 6.29 s (MAD 0.25), delta −4.26 s (−40.3 %), band
  0.65 s; apply, revert and uninstall left `Config/` byte-identical. SET-004 stays planted (its ~0.1 s is within noise).
- **B wording: fixed.** Reverted steps: "SET-004 was reverted (within noise) on <date>: not applied; re-verify with …";
  "nothing written: every overlay step was skipped (reasons above)"; the text output says "the project changed" only
  when a write event happened. `FixCLITests.testApplyNeedsVerifyOrForceAndRevertRoundTrips`, `.testRefusals`,
  `FixOverlayTests.testApplyRulesVerifyStatesAndForceUnverified`.
- **C DerivedData litter: fixed.** The hook verifier and the planner's cli oracle use
  `SettingsOracle.effectiveInScratch` (the v0.3 scratch workspace and generated scheme under `OracleCache.directory`,
  `-derivedDataPath` there). The doctor pass already did. The scratch-copy e2e left no new folder under
  `~/Library/Developer/Xcode/DerivedData`. `FixHookTests.testXcodebuildVerifierPassesADerivedDataPathInTheOracleCache`.
- **D incremental verify command: fixed.** The plan's `--kind incremental` verify command ends with `--touch <largest
  .swift file of the step's target folder>`. `FixPlannerTests.testIncrementalVerifyCommandSuggestsATouchFile`.

Smaller notes: `FixPlanner.commands` still lists `xcblame fix --apply` for cli-only plans, which is now right (it records
`applied-cli` and prints the build command); the `--xcblame-dir` outside-root include path and the defaults type notes
are unchanged.

## Re-check 1 (2026-11-06)

Against main @ cb368fe (`git diff cbf8d90..cb368fe`). Read-only review of the code paths; the named tests were not re-run by the reviewer (a focused run was
still building when this was written).

### Status of the original findings
- M1 symlinked xcconfig: **fixed** (`HookInstaller.Site` target/link split, `lstat` check after write, `link` in `hooks.json`; `FixHookTests.testSymlinkedBaseXCConfigIsEditedAtItsTarget`).
- M2 verify crash safety: **fixed for the temporary-block case** (journal, SIGHUP/SIGQUIT, `blocks` reads temporary blocks). Two residual holes in New 1 and New 2 below.
- Gap 1 `build --overlay`: **fixed** (BuildCommand/BuildOverlay/OverlayDelivery, oracle refusal exits 1 before building). Gap 2 stale verdicts: **fixed for carry-over** (`VerifyBasis`);
  verify's own oracle check still reads the stored plan's scope rows (documented, accepted). Gap 3: **fixed** (two-line hook, `unrecorded` uninstall).
- Minors 1-11: **fixed** (1 `newestApplied` per step; 2 `start` clamped to the previous block's end; 3 record saved before write; 4 as gap 3; 5 `-configuration` appended; 6 other plans' blocks stripped from arm A;
  7 signal-exit wait; 8 deadline timer + `Cancel`; 9 per-unit catch; 10 `applied-cli` and hook warning; 11 `--plan-out` redacted). Minor 12 (declaredEffects SET-032/028): **declined with reason, still open as PLAUSIBLE**.

### New findings
1. **minor** `Verify/VerifyOverlay.swift` (`VerifyJournal.recover`, the `temporary` guard): the journal also records the arm A write (`base`, i.e. the overlay with the selected steps' applied blocks stripped), but recovery
   restores a file only when it still holds a `(temporary)` block. A verify killed (SIGKILL/crash) during an arm A build leaves the overlay without its applied blocks, `recover` finds no temporary block, deletes the journal and returns
   nil: the applied steps silently disappear from the overlay while the plan still says `applied`. Fix: restore whenever the journal's pid is dead and the file differs from the journaled original, or journal only B writes plus an A marker.
2. **minor** `Verify/VerifyOverlay.swift` (`VerifySignals.init`): SIGHUP (and SIGINT) handlers are installed unconditionally, which replaces `SIG_IGN`. Under `nohup xcblame verify ...` (or a backgrounded non-interactive job) closing the
   terminal now aborts the verify with `interrupted`, the opposite of what nohup asks for. Fix: query the current disposition with `sigaction` and skip signals that are ignored.
3. **minor** `xcblame/BuildOverlay.swift:25-33` + `OverlayDelivery.plan`: with no plan id and no deliverable plan for this container the code falls back to the newest plan of ANY container in the shared `.xcblame`; its lines are written into
   the wrapper for a different project. `misses` skips targets the oracle does not list, so the oracle check will not catch it. Fix: drop the fallback (error naming the container).
4. **minor** `Fix/FixApply.swift` (`revert`) + `OverlayDelivery.leftOut`: a step recorded `applied-cli` has no overlay block, so `fix --revert <id>` finds nothing and never moves it to `reverted`; `build --overlay` keeps delivering it
   (`leftOut` only excludes `.reverted`). Fix: let revert flip `appliedCLI` steps of the plan to `reverted`.
5. **minor** `Fix/OverlayDelivery.swift:leftOut`: a step kept through `hook` is delivered through `cli` with no scope comparison (the reverse of SCHEMA rule 3 / DESIGN §7.8 step 2: refuse a mechanism other than the verified one
   unless the scopes agree). cli reaches package targets the hook scope never measured. Fix: apply `sameScope` for kept-through-hook steps too, or note it.
6. **minor** `Fix/VerifyBasis.swift:projectDigest`: hook-line stripping removes the two lines but not the newline `install` adds when the original lacks a trailing newline, so hooking such a file after a `cli` verify changes the digest
   and drops the verdict ("project changed since verify"). Safe direction (re-verify), low impact.
7. **nit/PLAUSIBLE** `VerifyJournal.recover` trusts `kill(pid, 0)`: a dead verify whose pid was reused by another live process is never recovered (the stale journal then also blocks nothing, but the temp block stays). Low likelihood.
8. **nit** Files hooked by the pre-fix format (`// xcblame hook: xcblame fix --uninstall-hook removes these lines`, blank line before) are not recognised by `isInstalled`; a re-install appends a second hook and its backup already contains
   the old hook. Only matters if cbf8d90 builds were used on a real project.

No new major. Timer `Cancel` (sticky shared instance, `fired` flag checked after both `clean` and build, restore before `stop(.timeout)`), journal write-before-touch ordering, `restoreAll` removing the journal after the restore, per-file hook record save and
rollback, the `unrecorded` byte-for-byte two-line removal, `VerifyBasis` single-step vs combined consistency between `recordVerdicts` and `carryOver`, and `effectiveInScratch` (guarded writes, `-u` env unset) read as correct.

**Verdict: SHIP** (no open major; the minors above can follow).

## Fix round 2 (2026-11-06)

All eight re-check findings fixed; SCHEMA-v0.6 Decisions 34-38.
1. **Arm A kill not recovered: fixed.** `VerifyJournal.recover` restores every journaled file whose bytes differ from the
   journaled original when the verify is dead, whichever arm wrote it (no `(temporary)` condition).
   `VerifyFixRoundTests.testRecoverRestoresAnArmAWrite`, `.testRecoverRestoresTheOverlayOfADeadVerify`.
2. **`nohup` overridden: fixed.** `VerifySignals` queries each disposition with `sigaction` and leaves `SIG_IGN` signals
   alone (`installed` lists the caught ones; `uninstall` resets only those). `VerifyFixRoundTests.testIgnoredSignalsStayIgnored`.
3. **Another container's plan delivered: fixed.** No fallback: without a deliverable plan for the build's container
   `--overlay` exits 2 "no plan for <container> …; run xcblame fix" before xcodebuild runs (a given plan id is still
   taken as is). Container paths compare symlink-resolved. `BuildOverlayCLITests.testAnotherContainersPlanIsNotDelivered`,
   `.testUnverifiedNeedsTheFlagAndRevertedIsNeverDelivered`.
4. **`applied-cli` never reverted: fixed.** `fix --revert <id>` (and `--revert` without an id, `newestApplied` now
   counts `applied-cli`) moves them to `reverted` with a revert event; a reverted verify does the same in auto-revert.
   `FixOverlayTests.testRevertMovesAppliedCLIStepsToReverted`, `VerifyFixRoundTests.testRevertedVerifyRevertsAnAppliedCLIStep`.
5. **Kept through hook delivered through cli unchecked: fixed.** `OverlayDelivery.leftOut` applies `FixApply.sameScope`
   to a step kept through `hook`; different reached rows leave it out with a note naming the mismatch and the
   `verify --mechanism cli` command. `FixOverlayTests.testKeptThroughHookIsDeliveredThroughCLIOnlyWhenScopesAgree`.
6. **Digest changed by the hook's newline: fixed.** `VerifyBasis.projectDigest` drops trailing empty lines after removing
   the hook lines (current and legacy marker). `FixHookTests.testProjectDigestIgnoresTheHookOnAnUnterminatedFile`.
7. **pid reuse: fixed.** The journal stores `processStart` (`sysctl kern.proc.pid`, `p_starttime`); a live pid with
   another start time is a dead verify. Journals without it fall back to `kill(pid, 0)`.
   `VerifyFixRoundTests.testReusedPidIsNotTakenForTheVerify`.
8. **Pre-fix hook format: fixed.** `--install-hook` finds the old blank line + `// xcblame hook: xcblame fix
   --uninstall-hook removes these lines` + `#include?` and replaces it in place with the two-line hook; the backup is
   the file without the old hook. `FixHookTests.testLegacyHookIsUpgradedInPlace`.

Verifier round 2 (`verify --rules SET-004 --runs 5` on AcmeFixWin: `reverted (task set changed)`): **fixed.** The
failing kinds were `SwiftExplicitDependencyGeneratePcm` and `GenerateSwiftModulesReport`: B's fresh per-arm module
cache built the explicit-module PCMs in its first clean run. Those cache-dependent kinds are never compared now. The
declared-effect table covers every catalog SET rule whose fix changes a task kind (SCHEMA Decision 39), and a new
`declaredCounts` ("count may change": presence compared, not count) holds SET-005's per-arch kinds. Undeclared
differences still revert. Original minor 12 (SET-028/032) is closed: SET-032 declares the interface tasks, SET-028
declares nothing (LTO runs inside `Ld`). `VerifyFixRoundTests.testSET004DeclaredEffectAndColdModuleBuildsAreNotATaskSetChange`,
`VerifyVerdictTests.testArchitectureCountComparesByPresenceAndCacheKindsAreIgnored` (tests renamed in fix round 3).

## Fix round 3 (2026-11-06)

Verifier on main @ 3dae7b6: `verify --rules SET-005 --kind clean --runs 5 --mechanism hook` on AcmeFixWin ended
`reverted (task set changed)` (delta −4.5 s, band 0.38 s) on `SwiftDriver Compilation`, `SwiftDriver Compilation
Requirements` and `ConstructStubExecutorLinkFileList`: per-arch planning kinds whose count halves with one
architecture. **Fixed** (SCHEMA Decision 39 amended, Decision 40):
- Architecture-count effect (`VerifyVerdict.architectureCountRules`: SET-005, SET-006): every kind compares by
  presence; compile/link work and every other A kind must stay, B may add none, only `CreateUniversalBinary`,
  `SwiftMergeGeneratedHeaders`, `GenerateTAPI` may disappear. Undeclared differences still revert.
  `VerifyFixRoundTests.testSET005ArchitectureCountWithTheLoggedTaskKinds` (the exact per-build kind sets of
  verify-v0.6-r3/v005.txt), `VerifyVerdictTests.testArchitectureCountComparesByPresenceAndCacheKindsAreIgnored`.
- The `taskKinds` failure is at most two lines and names the effect a rule would need.
  `VerifyVerdictTests.testTaskKindsFailureNamesTheNeededEffect`.
- Found by the proof run: an applied SET-005 overlay made `--install-hook` fail (the generated-scheme oracle reports
  `ONLY_ACTIVE_ARCH = NO`), and `build --overlay` left the kept-through-hook SET-005 out on the same oracle values. The
  hook check reads that key from the project files; the kept-through-hook comparison is by reached targets, values are
  checked by `build --overlay`'s own oracle. `FixHookTests.testOracleBlindKeyIsCheckedFromTheProjectFiles`.

Proof (scratch copy of AcmeFixWin, hook, clean, 5 runs): SET-005 `kept`, A p50 10.91 s (MAD 0.24), B p50 6.38 s (MAD
0.10), delta −4.54 s, band 0.55 s, taskKinds pass; SET-004 `reverted (within noise)`, A p50 10.84 s, B p50 10.73 s,
delta −0.11 s, band 0.30 s, taskKinds pass. Then `fix --rules SET-005 --install-hook --apply` wrote the block,
`build --overlay` built one architecture (no `normal x86_64` task; "oracle check: every key won on 1 target(s)"),
`fix --revert` and `--uninstall-hook` left `Config/` byte-identical and no overlay file.
