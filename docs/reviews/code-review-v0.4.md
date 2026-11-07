# Code review: xcblame v0.4 "CI" (`1c19bec..77c34ba`)

Fresh-eyes review of the skeleton (3d62628), lanes A (formats, schema), B (compare, baseline, regression) and C (trend,
git, retention, CI), plus the integration commits. Checked against DESIGN §3.1–3.2, §6.10, §8.1, §8.3, §8.4, §11 (v0.4
row) and docs/SCHEMA-v0.4.md. This covers correctness, security, data loss and requirement gaps only. Every finding below
was traced through the code; the ones I could not confirm end to end are marked PLAUSIBLE.

**Verdict: FIX-FIRST.** No blockers. There are five majors: two break the main CI flows (baseline key mismatch between
`build` and `analyze`/log operands, and task digests that only match on the same machine), one loses data (`history
prune` dedupe by basename), one lets the regression gate pass silently, and one exposes the release secrets.

## Regression, baseline, build context

- `Sources/XcblameKit/Env/BuildContext.swift:36-37, 55-58`: major: `destination` comes from two different vocabularies.
  `build` takes it from `-destination` (`iOS Simulator iPhone 17`, `macOS` for `platform=macOS`). `analyze`, compare
  log operands (`CompareOperands.swift:60`) and `baseline save --from <log>` take it from the build request
  (`iOS Simulator arm64`, `macOS arm64`). `Regression.requireSameBuild` (`Compare/Regression.swift:252`) refuses two
  known values that differ, and `Baseline.selectHistory` requires keys to be exactly equal. Scenario:
  `baseline save --from <DerivedData log>`, then `xcblame build --baseline .xcblame/baseline.json --fail-if-slower 10 --
  -scheme App -destination 'platform=macOS' build` gives "regression: destination differs: baseline macOS arm64, current
  macOS", which is exit 2 on every run. Comparing a `build` history id with a log also exits 2, and `baseline save
  --last N` treats `build` and `analyze` entries of the same build as different keys. Fix: derive the destination one
  way (platform plus arch from the build request when there is one, for both commands), or normalize both to
  `platform[ arch]` and keep the device name out of the key. Add a test that mixes `build` and log operands.
- `Sources/XcblameKit/Compare/BaselineBuild.swift:60-62` (with `History/History.swift:180`): major: the `--with-tasks`
  digests and the compare task multiset hash `sigDigest = SHA256(commandDetails)`. The command line contains absolute
  source paths, the DerivedData hash and the home folder. So a baseline committed from a developer Mac and evaluated
  on CI (different home, checkout and DerivedData) matches no digest. Every task then shows as "new", and attribution
  adds "N tasks of the baseline did not run". `compare` of two checkouts gets the same spurious `tasks.added` and
  `tasks.removed`. A committed baseline is the documented use. Fix: digest a path-normalized command (strip home, repo
  root and DerivedData roots with the Redactor rules), or use rule + target + repo-relative primary file.
- `Sources/xcblame/BuildCommand.swift:55-60, 74-75`: major: under the default `--exit-code xcodebuild`, an analysis that
  throws (no log, decode failure) leaves `regressionFailed == false` and `baselineFailure == nil`. With `--baseline
  --fail-if-slower` the command then exits 0, so the CI gate passes silently. An unreadable baseline, by contrast, fails
  closed (1/2/5). Fix: when `regression.baseline != nil` and analysis failed, set `baselineFailure = 1` (and say so in
  SCHEMA "Exit codes").
- `Sources/XcblameKit/Compare/Regression.swift:61-69`: minor: a baseline with `wallBasis: processWall` (made from `build`)
  checked by `analyze --fail-if-slower` (no process wall) gives `wall` null and `failed` false: exit 0 with only a note.
  This matches the spec, but the gate can never fire. Fix: print a stderr warning when `thresholdPct` is set and wall is
  not comparable, or store span stats in the baseline too.
- `Sources/XcblameKit/Compare/Regression.swift:252-261`: minor: a key field that is null on one side is skipped
  silently. `analyze` of a log without a build description has `configuration` and `destination` null, so a Release log
  is compared with a Debug baseline and no note says so. Fix: add a `regression.notes` line naming the key fields that
  were not compared.

## History, retention

- `Sources/XcblameKit/History/Retention.swift:48-58`: major (data loss): `dedupeHistory` keys on the log basename
  without its extension (`History.logName`). Distinct builds whose logs reuse a name (`build.log`, `App.xcresult`,
  fixed fastlane names) are deleted on `history prune`, and only the oldest is kept. Scenario: entries `build`
  (Mon), `other` (Tue), `build` (Wed, a different build): prune deletes Wed's entry. `History.save:118` has the same
  flaw today for consecutive runs. Fix: key on the identity of the log content (a digest or size+mtime of the input,
  or the build start time stored in the entry), never on the basename.
- `Sources/XcblameKit/Trend/Trend.swift:73`: minor: an entry with no time passes any `--since`. Fix: exclude it and add
  it to the note count.
- Retention itself is fine: it touches only stamp names in `results`, `logs` and `reports`, examines entries with
  `lstat`, skips a folder that is a symbolic link, never follows a link, and a failure on one entry does not stop the
  others.

## GitHub format, markdown, agent, junit

- Annotation escaping is correct (`GitHubReporter.swift:91-99`). Data escaping covers `%`, CR and LF; properties also
  get `:` and `,`; messages go through `oneLine` first. A `::set-env` or `::add-mask` inside a message stays message
  data, because the first `::` after the command is the escaped property separator. File paths are repo-relative or
  dropped; `..`, `~`, `$` and absolute paths are rejected (`FormatSupport.swift:184-195`).
- `Sources/xcblame/TextFormats.swift:15-21` / `FormatSupport.swift:74-76`: minor, PLAUSIBLE: with `--format github` and
  no `-o`, the markdown body goes to stdout. The runner's legacy parser accepts `##[command]` anywhere in a line, and
  `FormatText.markdown` leaves `##[` alone. A diagnostic text like `##[add-mask]…` or `##[stop-commands]…` in a log
  analyzed after the fact would act as a command. Fix: escape `[` as `\[` in `markdown()` (it renders the same).
- `Sources/XcblameKit/Reporters/Formats/FormatSupport.swift:85-107`: minor: `mentionSafe` counts a backslash-escaped
  backtick as a code-span delimiter. In ``foo \`@octocat` `` the mention is left unwrapped, but GitHub renders it live,
  so the PR comment notifies @octocat. Fix: treat `` \` `` as a literal before splitting on backticks.
- `Sources/xcblame/TextFormats.swift:42-54`: minor: there is no 1 MiB check on `$GITHUB_STEP_SUMMARY`. With
  `--max-report-bytes` over 1 MiB, or several appends in one step, the runner drops the whole summary. Fix: skip the
  append (warn on stderr) when existing size + body > 1,048,576.
- `Sources/XcblameKit/Reporters/Formats/AgentReporter.swift:42-47`: minor: at the 20-error floor, `hardTruncate` cuts
  from the end, which drops BUILD, CRITICAL PATH and FINDINGS. The spec says the summary is never dropped. Fix: clip the
  diagnostics block, not the tail.
- `Sources/XcblameKit/Reporters/Formats/JUnitReporter.swift:48`: minor: target budgets are looked up in
  `document.targets`, which is capped at `--top` (default 15). A budgeted target below the top N is `skipped` ("not in
  the report") instead of evaluated, so a small target that blows its budget never fails. Fix: read the full target
  rollup, or render junit with `--top all` for the lookup.
- The markdown 64 KB cap and the agent 8 KB cap are enforced in UTF-8 bytes (`Fit.fit` and `clamp`). JUnit XML
  escaping and `time` with 3 decimals are correct.

## Compare, trend, HTML, schema

- History-id operands are matched against `History.list` ids and never joined into a path, so `../` cannot escape. Both
  compare sides are redacted, including `remoteHost` (`$REMOTE`). Folding of capped target rows is noted in the compare
  notes.
- Trend percentiles are R-7 and correct for n = 1 and 2. `--since` accepts `Nd` and `YYYY-MM-DD` and validates them; an
  empty history exits 0 with a note.
- HTML compare and trend views put every data string in through `textContent`, `createTextNode` or `setAttribute`; there
  is no `innerHTML` or `href` built from data and no network. The data blob uses `escapeScriptData`.
- The JSON Schema uses the draft 2020-12 URI and `additionalProperties: true`, lists nullable members as `[T, "null"]`,
  and has tests that encode real pipeline, fixture and sample documents and validate them strictly. Drift risk is low.

## GitInfo

- `--no-optional-locks` is passed on every call (tested), git runs from `/usr/bin/git` with a 2 s kill, `dirty` uses
  `--untracked-files=no`, and `remoteHost` takes the host only, so a credential cannot leak. Note: git runs in the
  current directory, not the `-project`/`-workspace` folder. This matches the spec, but `xcblame build` run from outside
  the repository records no git.

## CI, release, examples

- `.github/workflows/release.yml:21-25`: major (security): the Apple signing secrets (`APPLE_CERT_P12`, its password,
  the Apple ID app password) are in job-level `env`. Every step can read them, including the third-party
  `maxim-lobanov/setup-xcode@v1` (a mutable tag, line 30) and `swift test`. Fix: move them into step-level `env` on the
  Codesign and Notarize steps only, and pin third-party actions by commit SHA.
- `examples/danger/Dangerfile:5-10`: minor: the comment promises exit 3, but the sample command has no `--fail-if-slower`.
  JSON `diagnostics[].file` is absolute (json is not redacted by default), so Danger's inline `file:` comments do not
  attach. Messages are posted raw, `@mentions` included. Fix: add the flag, make the paths repo-relative, and wrap
  mentions.
- `ci.yml` pins first-party actions by major; secrets are never echoed; the tag-vs-version check is correct. Examples use
  only Acme* names.

## Tests deleted, weakened or skipped

- No test file was deleted.
- `Tests/xcblameTests/CLITests.swift:390-399`: the `analyze --project` test now forces `--offline` and expects
  confidence `low`. The xcodebuild-resolver path (`medium`) is no longer covered at CLI level. This is acceptable as a
  flake fix (the 5 s cap on a cold oracle), but the resolver path needs coverage somewhere else.
- `CLITests.swift:132`: the "unknown format exits 2" test moved from `markdown` to `sarif`. Correct.
- `SchemaContractTests` gains the four new keys and `ReportersTextTests` bumps the version. Correct.
- New `XCTSkip`s only cover a missing Chrome or git. Acceptable.
- Missing tests for risky logic: mixed `build`/log destination keys, task digests across two checkout paths, dedupe of
  distinct same-named logs, and `build --fail-if-slower` when analysis fails.

## Private-name grep

Private-name grep over tracked files (the private corpus project names and the restricted work-project patterns, excluding docs/research): only the reference app name "AcmeApp"
occurs. It is new in four tracked files from this diff:
- `Sources/XcblameKit/Reporters/ReportDocument.swift:537` (doc comment example `AcmeApp: SwiftCompile`; replace it with
  `AcmeApp: SwiftCompile`)
- `Tests/XcblameKitTests/CompareTestSupport.swift:6`
- `Tests/xcblameTests/CompareCLITests.swift:45, 58, 71, 77`
- `Tests/xcblameTests/CompareFlowCLITests.swift:61`

The test hits assert the scheme name of the existing fixture logs (`fixtures/logs/cli-xcode26*`, which were already
tracked with that name), so they inherit the fixture debt. Already tracked before this diff: PROGRESS.md, docs/*,
fixtures/*, Graph/Rules sources and the older tests.

## Re-check (fix commits `77c34ba..88457f8`)

Commits: 2de0370 (M5), 296aec7 (M1), 3b3333c (M2, M3), 4d4b99a (M4 and the verifier findings), 88457f8 (minors). Read
only. I did not re-run the suite for this pass. No test file was deleted.

**Verdict: FIX-FIRST.** M2 is only partly fixed: task digests still differ between a developer Mac and a GitHub runner.
Everything else is fixed, or reduced to a minor.

### Majors

- M1 (destination vocabulary): **fixed.** `-destination` and the build request both give `platform [arch]`; device
  names, ids, `OS=` and `generic/` are dropped; `destinationsAgree` lets a side without an arch match any arch. This is
  used in `requireSameBuild`, `key(of:)` and `selectHistory`. Residual minors are listed below.
- M2 (portable task digests): **reopened, major (partial).** `History.portable` covers the project root (from `cd`),
  the DerivedData hash and home user names. It does not cover the Xcode developer dir. Every compile command carries
  `/Applications/Xcode.app/Contents/Developer/...` (64 times in `fixtures/logs/build26.log`) for the toolchain and the
  SDK, while a GitHub runner under `setup-xcode` builds from `/Applications/Xcode_26.0.app`. So a baseline committed
  from a dev Mac still matches no digest on CI, and every task shows as "new". The test
  (`HistoryTests.swift:259`) varies only the root, home and hash.
- M3 (dedupe by basename): **fixed.** `logId` is `uuid:` for Xcode's UUID-named logs (which is what `build` analyzes),
  otherwise sha256 of the first 1 MiB plus the size. An old entry without `logId` and without a UUID name gets no
  identity and is never deduped, which is safe. Reading 1 MiB per save is cheap.
- M4 (build gate passes when analysis fails): **fixed.** `baselineFailure` is reset at the top of `run()`. The catch
  sets exit 1 when `--baseline` is given, xcodebuild's non-zero code still wins, and SCHEMA documents it.
- M5 (release secrets): **fixed.** The secrets are step-level `env` on Codesign and Notarize only, both actions are
  pinned by SHA, and a test enforces both. (`ci.yml` and the example still pin by major, which is acceptable for
  workflows without secrets.)

### Minors

| Minor | Status |
|---|---|
| processWall gate | fixed: `regression.notes` line plus a stderr warning |
| unknown key fields | fixed: `requireSameBuild` returns a note naming them |
| `##[` | partial: escaped in the github body and annotations only; see new findings |
| `mentionSafe` | partial: `\`` outside a span is fixed, a new bypass inside a span; see new findings |
| step summary 1 MiB | fixed |
| agent floor | fixed: the diagnostics block is clipped and the summary is kept |
| junit target budgets | fixed: junit defaults to `--top all`; an explicit `--top N` gives an explicit skip reason |
| trend `--since` | fixed |
| Dangerfile | fixed (it shares the `mention_safe` span flaw) |
| resolver path coverage | fixed: `AnalyzeResolverPathTests` |
| private name in `ReportDocument.swift:537` | fixed (the remaining test hits come from the fixtures) |

### New findings

- `Sources/XcblameKit/History/History.swift:194`: major (this is M2 reopened): `portable` leaves the developer dir
  (`/Applications/<any>.app/Contents/Developer`) and a repo-local `-derivedDataPath` as they are, so digests differ
  between `Xcode.app` and `Xcode_26.0.app`. Fix: map `/Applications/[^/]+\.app/Contents/Developer` (and the
  `DEVELOPER_DIR` of the log) to `$DEVELOPER_DIR`, and normalize `-derivedDataPath` roots. Add a test with two Xcode
  app names.
- `Sources/XcblameKit/History/History.swift:207`: minor: `projectRoot` keeps only the most common `cd`. In a workspace
  whose projects or local packages sit in sibling folders (monorepo, `ios/` subfolder), the tasks of the other roots
  keep their checkout paths, so their digests still differ between machines. Fix: normalize every `cd` root seen, or
  use the git root of the most common one.
- `Sources/XcblameKit/Reporters/Formats/FormatSupport.swift:85-110`: minor: the `\`` rewrite also applies inside code
  spans. In CommonMark, a backslash does not escape inside a span, so in ``a `b \` @octocat c` d`` the span closes at
  `` \` `` and `@octocat` is a live mention. `mentionSafe` leaves it unwrapped, and
  `FormatsGitHubTests.swift:103` asserts that wrong behavior. The Dangerfile's `mention_safe` has the same flaw. Fix:
  scan left to right, honour `\`` only outside a span, and close a span at any backtick run of the same length.
- `Sources/xcblame/TextFormats.swift:39`: minor: `##[` is neutralized only in `GitHubReporter`. `compare --format
  github` (its body goes to stdout and to the step summary) does not neutralize, nor does `--format agent` (which
  prints raw diagnostic messages to stdout), nor `--format markdown` on stdout. Fix: neutralize in
  `FormatText.markdown` / `diagnosticLine` (so it happens before `Fit`), or in `renderTextFormat` /
  `renderCompareTextFormat` for every format.
- `Sources/XcblameKit/Reporters/Formats/GitHubReporter.swift:14-15`: minor: escaping after `Fit` and then calling
  `clamp` can cut a body that sits at its cap mid-line: a half `<sub>` footer or a dropped `</details>`. Fix: escape
  inside `markdown()` before fitting (as in the item above).
- `Sources/XcblameKit/Compare/Regression.swift:240` (and `BaselineBuild.swift` `selectHistory`): minor:
  `destinationsAgree` is not transitive, and each value is checked only against the first. Runs `macOS`, `macOS arm64`,
  `macOS x86_64` pass `key(of:)` and come out as `macOS arm64`, and `baseline save --last N` can mix architectures when
  the newest entry names none. Fix: check every value against the merged destination.
- `Sources/XcblameKit/Env/BuildContext.swift:109`: minor: `variant=` is dropped, so Mac Catalyst and native macOS (and
  "Designed for iPad") are both `macOS arm64`. The build request does the same (`sdkVariant` is ignored). Fix: keep the
  variant (`macOS (Catalyst) arm64`) in both sources. Also PLAUSIBLE: `platform=` is not case-folded (`platform=macos`
  gives `macos`, which disagrees with `macOS`); map it case-insensitively through the same table as the build request.
- `Sources/XcblameKit/History/History.swift:308`: minor, PLAUSIBLE: for non-UUID text logs over 1 MiB, two different
  logs with an identical first MiB and an identical size share an identity, and the later one is deduped. This is
  unlikely, because timing lines differ. Fix: also hash the last 64 KiB.

### Checked, no issue

- `analyze <history id|prefix>`: an existing path always wins, and an id is tried only when the path does not exist.
  An ambiguous prefix exits 2, and ids are matched against `History.list`, never joined into a path.
- Paths are made repo-relative before redaction (diagnostics, hotspots, files, and the workspace prefix in messages),
  and redaction runs afterwards. A file outside the workspace becomes a file-less annotation with the basename only, so
  no folder leaks.
- The junit `--top all` default only widens the document behind junit. V13 is off for junit, and history entries keep
  all target rows (larger, harmless).
- Test changes are assertion updates for the new vocabulary and behaviour plus new tests. None were weakened except
  the agent cap test, which went from `hasSuffix("[truncated]")` to `contains`; that is correct now that the marker
  sits before the summary.
