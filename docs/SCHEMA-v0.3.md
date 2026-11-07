# xcblame schema and contract: v0.3 "Doctor"

The contract between the three v0.3 lanes. It lists every report member added in v0.3 (type, when it is `null`,
meaning, lane, invariant), the public XcblameKit types the lanes fill, the frozen CLI wiring, file ownership, and the
fixture projects with what each is meant to trigger. Report types live in
`Sources/XcblameKit/Reporters/ReportDocument.swift`; project, settings and rule types in
`Sources/XcblameKit/{Project,Settings,Rules}/`. `Tests/XcblameKitTests/Reporters/SchemaContractTests.swift` pins every
member name. Renaming, removing or retyping a member breaks the contract; a lane that needs a change stops and asks.

Lanes (disjoint files, see "File ownership"):
- **A** `Sources/XcblameKit/Project/`: pbxproj, xcconfig, scheme and manifest readers, generator detection
  (`ProjectModel.load`, `XCConfigFile.load`).
- **B** `Sources/XcblameKit/Settings/`: `SettingsOracle` over `xcodebuild -showBuildSettings -json`, provenance, the
  offline resolver.
- **C** `Sources/XcblameKit/Rules/`: the rule catalog and engine, the `doctor` text and HTML views, `rules`, findings in
  `analyze`.

## General rules (v0.2 rules unchanged)

- `schemaVersion` stays `"xcblame.report/1"`. Every v0.3 member is additive.
- A `T?` member always serializes, as `null` when unknown; it is never omitted. Unknown is never `0`, `""` or `[]`. A
  `null` member has a reason in the nearest `notes`.
- New top-level members use `@Added` (`Reporters/Nullable.swift`): they serialize like `@Null`, and a saved report
  written before v0.3 (no `project`, `doctor`, `fixPlan` keys) decodes with `nil` / `[]`, so `analyze old.json --format
  html` keeps working. New members inside `Finding` and `RuleDoc` are plain (v0.2 never emitted either).
- Keys sort, two runs over the same input are byte-equal, times are seconds rounded to 6 decimals (`round6`).

## Top level (added members)

| Member | Type | Null when | Meaning | Lane | Invariant |
|---|---|---|---|---|---|
| `project` | `ProjectSection?` | no project was read (`analyze` without a project, `--no-rules`, a v0.2 report) | The container `doctor` (or `analyze` with rules) read. | filled by `makeDoctor` / `merge(rules:)` from A + B output | |
| `doctor` | `DoctorSection?` | no rule ran (`analyze` with an empty rule run, `--no-rules`) | PASS / N/A / suppressed lists and doctor bookkeeping. | C (via `RuleResult`) | see Invariants |
| `fixPlan` | `[FixPlanStep]` | never (`[]` when no finding has a command) | Printed fix plan, in order. | `ReportDocument.fixPlan(_:)` from `findings[].fixCommands` | `order` = 1…n; ruleIds ⊆ `findings[].ruleId` |
| `findings` (v0.2) | `[Finding]` | never | Now filled: rule findings in fix-plan order. | C | unique `signalKey`; never dropped by truncation |
| `findingsTotal` (v0.2) | `Int` | never | `findings.count` (findings are never capped in v0.3). | C | |
| `ruleDocs` (v0.2) | `[String: RuleDoc]` | never | `rules explain` text for each rule in `findings`. | C | keys == set of `findings[].ruleId` |

A `doctor` document has every build member empty: `input.reader = "none"`, `input.layout = "project"`, `input.path` =
container path, `build`/`metrics` zeros and nulls, `targets`/`kinds`/`phases`/`topTasks`/`files`/`hotspots`/
`criticalPath` null, `graph.basis = "none"`, `validation.checks = []`, each with the note `doctor runs no build`, plus
a top-level note `doctor runs no build: …`. `topN` is `Int.max`. `xcode.value` is the selected Xcode
(`xcodebuild -version`, source `xcodebuild -version`), not an inferred one.

### ProjectSection (`project`)

| Member | Type | Null when | Meaning |
|---|---|---|---|
| `container` | `String` | – | `.xcodeproj` / `.xcworkspace` / `Package.swift` path (redactable). |
| `format` | `String` | – | `pbxproj` / `xcproj` / `package` (`ProjectModel.format`). |
| `objectVersion` | `Int?` | not `pbxproj` | pbxproj `objectVersion` (first project of a workspace). |
| `generator` | `String?` | not generated | `xcodegen` / `tuist` / another name (`ProjectModel.generator`). |
| `targets` | `Int` | – | Project targets across projects (`ProjectModel.allTargets.count`). |
| `packageTargets` | `Int?` | no effective settings were read | Targets the oracle lists that are not project targets (first evaluated configuration). |
| `localPackages`, `remotePackages` | `Int` | – | `packages` with `.local` / any other requirement. |
| `dependencyManagers` | `[String]` | – | `cocoapods` / `carthage` / `spm`, in `ProjectModel` order. |
| `schemes` | `Int` | – | `ProjectModel.schemes.count` (shared and user). |
| `settingsSource` | `String?` | no effective settings | `xcodebuild -showBuildSettings -json` or `offline resolver` (mixed sources: `offline resolver` plus a note). |
| `configurations` | `[String]` | – | Configurations evaluated (`doctor --configuration`, default all; `analyze`: the project's default). |
| `notes` | `[String]` | – | `ProjectModel.notes` plus reasons for the null members. |

### DoctorSection (`doctor`)

| Member | Type | Null when | Meaning |
|---|---|---|---|
| `passed` | `[RuleOutcome]` | – | Rules whose predicate held (`detail`: the evidence, e.g. `Debug: singlefile`). |
| `notApplicable` | `[RuleOutcome]` | – | Rules with nothing to check (`no script phases`, dynamic-only without a build, Xcode range). |
| `suppressed` | `[RuleOutcome]` | – | Lost a `signalKey` dedupe or a RULES.md §10 conflict; `detail` names the winner. |
| `rulesEvaluated` | `Int` | – | Distinct rule ids across `findings`, `passed`, `notApplicable`, `suppressed`. |
| `durationSeconds` | `Double?` | under `analyze` | Wall time of the doctor run (locate → render input). |
| `offline` | `Bool` | – | `--offline`. |
| `failOn` | `String?` | `--fail-on` absent or `none` | `low` / `medium` / `high`. |
| `failed` | `Bool` | – | A finding at or above `failOn` exists (`doctor` exits 4). Always false under `analyze`. |

**RuleOutcome**: `ruleId: String`, `title: String` (the rule name), `detail: String` (one line).

**FixPlanStep** (`fixPlan[]`): `order: Int` (1-based, consecutive), `ruleId: String`, `command: String`,
`note: String?` (null in v0.3; Lane C may annotate). One step per entry of `findings[i].fixCommands`, findings in
order.

### Finding (`findings[]`, v0.3 members added to the v0.2 ones)

| Member | Type | Null when | Meaning |
|---|---|---|---|
| `severity` (v0.2) | `String?` | rule has none | `info` / `low` / `medium` / `high` (`RuleSpec.Severity`); `--fail-on` compares it, null counts as `info`. |
| `confidence` (v0.2) | `String` | – | `high` / `medium` / `low` (DESIGN §7.1). `doctor` never emits `high`; `--offline` lowers one step. |
| `impactBand` (v0.2) | `String?` | – | `XS`/`S`/`M`/`L`/`?`; static-only findings `?` (catalog numbers go in evidence as context). |
| `signalKey` | `String` | – | Dedupe key from `RuleSpec.signalKeyTemplate`, e.g. `setting:SWIFT_COMPILATION_MODE:Acme:Debug`, `script-phase:AC0000000000000000000043`. Unique across `findings`. |
| `scopeTargets` | `[String]` | – | Targets covered (project and package target names); empty = project-wide. |
| `scopeConfigurations` | `[String]` | – | Configuration names covered; empty = not configuration-specific. |
| `evidenceDetails` | `[EvidenceItem]` | – | Structured `evidence`, same order and count as `evidence`. |
| `fixCommands` | `[String]` | – | What the plan prints (`xcblame verify --rules SET-016 --kind clean --mechanism hook`, `xcblame fix --rules SET-016 --apply`). |
| `overlayLines` | `[String]` | – | `KEY = VALUE // xcblame SET-001` lines for `overlay*` fixes; empty otherwise or when shadowed. |
| `seeAlso` | `[String]` | – | Rule ids folded into this finding by `signalKey` dedupe (they are in `doctor.suppressed`). |
| `xcode` | `String?` | rule applies to all versions | The rule's Xcode range (`26+`). |
| `sources` | `[String]` | – | Source URLs from the rule spec. |
| `needsMeasurement` | `Bool` | – | Static-only impact or [K]-gated rule: shown as "needs measurement", never in the default top 3. |

**EvidenceItem**: `kind: String` (`setting` / `phase` / `package` / `file` / `task` / `env` / `report`), `ref: String`
(`Acme:Debug:SWIFT_COMPILATION_MODE`, a phase id, a package URL, a path, a task id), `value: String?`,
`provenance: String?` (`Provenance.Level` raw value, `@ <file>` when known; null for non-settings).

**RuleDoc** (`ruleDocs[id]`, v0.3 members added): `id: String`, `category: String` (ID prefix `SET`, `PHASE`, …),
`applyKinds: [String]` (RULES.md notation `overlay(D)`, `overlay(R)`, `overlay`, `cli`, `defaults`, `scheme`,
`pbxproj`, `manifest`, `rec`, `measure`), `verifyOnly: Bool` (`+V`), `risk: String`, `evidenceTag: String` (`P`, `S`,
`K`, or mixed text such as `S/K`). `RuleSpec.ruleDoc` builds it; `title` is the rule name.

## Invariants (Lane C enforces, tests pin them)

1. `findings[].signalKey` is unique; folded rules appear in the winner's `seeAlso` and in `doctor.suppressed`.
2. Every evaluated rule id lands in exactly one of `findings[].ruleId`, `doctor.passed`, `doctor.notApplicable`,
   `doctor.suppressed`; `doctor.rulesEvaluated` is the size of their union (`RuleResult.rulesEvaluated`).
3. `ruleDocs` keys == set of `findings[].ruleId`.
4. `fixPlan` = `ReportDocument.fixPlan(findings)`: order 1…n, findings order, each finding's commands in order
   (v0.5 clarity: guards first, verify/check/manual steps inserted; docs/SCHEMA-v0.5.md "Clarity additions").
5. `findings` are in fix-plan order: measured before `needsMeasurement`, then impact, then category dedupe rank
   (`RuleSpec.Category.dedupeRank`: SET > PHASE > DEP > GRAPH > SRC > ENV > DYN > CI), then id.
6. `doctor` confidence is never `high`; `--offline` lowers every finding one step (`medium` → `low`).
7. `doctor.failed` == `ReportDocument.failOnHit(findings, threshold: failOn)`; exit 4 iff `failed`.
8. Rules never write: no rule, oracle or reader writes outside `<xcblame-dir>/cache` (see "Zero writes").

## Library types (public, `Codable`, `Sendable`, `Equatable`)

### Project (Lane A, `Sources/XcblameKit/Project/ProjectModel.swift`)

`ProjectModel { root: URL (container dir), container: Container, format: Format, projects: [Project], schemes:
[Scheme], packages: [PackageReference], dependencyManagers: [DependencyManager], generator: Generator?, notes:
[String] }` with helpers `allTargets`, `configurationNames`.

- `Container`: `.xcodeproj(URL)` / `.xcworkspace(URL)` / `.package(URL)` (the `Package.swift` file); `.url`.
- `Format`: `.pbxproj(objectVersion:)` / `.xcproj` / `.package`.
- `DependencyManager`: `.cocoapods(podfile:lockfile:podCount:)` / `.carthage(cartfile:)` / `.spm`; `.name`.
  `podCount` = pods in `Podfile.lock` `PODS:` (top-level entries), nil without a lockfile.
- `Generator`: `.xcodegen(spec:)` (`project.yml`/`project.json` next to the container) / `.tuist(manifest:)`
  (`Project.swift` or `Workspace.swift`, `Tuist/` or `Tuist.swift`) / `.other(name:)`; `.name`.
- Nested in `ProjectModel` (the bare names `Target` and `Project` collide with `BuildModel`):
  - `Project { path, name, objectVersion: Int?, configurations, defaultConfiguration: String?, projectSettings:
    [config: [key: SettingValue]], projectXCConfig: [config: URL], targets }`. A configuration without a
    `baseConfigurationReference` has no `projectXCConfig` key. `defaultConfiguration` is the project list's
    `defaultConfigurationName` (added beyond the brief: `analyze` needs a configuration and the log names none).
  - `Target { id (24-hex), name, productType (raw), hasSwiftSources, hasCSources, hasBridgingHeader, settings:
    [config: [key: SettingValue]], xcconfig: [config: URL], phases: [BuildPhase], dependencies: [target name],
    packageProducts: [product name], frameworkKind: .static/.dynamic/nil, isTest }`. Synchronized root groups count
    their files for `hasSwiftSources`/`hasCSources` and `.sources(count:)`.
  - `BuildPhase`: `.shellScript(ShellScriptPhase)` / `.sources(count:)` / `.resources(count:largeFileBytes:)` /
    `.other(name:)`.
  - `ShellScriptPhase { id, name, shellScript (unescaped; objectVersion 90 arrays joined by newlines), inputPaths,
    outputPaths, inputFileListPaths, outputFileListPaths, alwaysOutOfDate, runOnlyForDeploymentPostprocessing }`.
  - `PackageReference { url: String?, path: URL?, requirement, products, consumers, manifest: PackageManifest? }`,
    `Requirement`: `.exact(v)` / `.upToNextMajor(v)` / `.upToNextMinor(v)` / `.range(from:to:)` / `.branch(name)` /
    `.revision(sha)` / `.local`. `manifest` (added beyond the brief, DEP-012/PHASE-005 need it) only for local
    packages and the `.package` container: `PackageManifest { name?, dependencies: [PackageReference], targets:
    [PackageTarget { name, type (regular/executable/test/macro/plugin/binary/system), dependencies, plugins }] }`,
    parsed as text (never `swift package dump-package`, which may write `.build/`).
  - `Scheme { name, path, parallelizeBuildables: Bool?, buildImplicitDependencies: Bool?, isShared }`.
- Top level: `SettingValue { raw: String?, conditions: [String: String]? }`. `raw` is optional (a key set only
  conditionally, e.g. `EXCLUDED_ARCHS[sdk=iphonesimulator*]`, has no unconditional value); conditions map the bracket
  text (`sdk=iphonesimulator*`) to its value; pbxproj arrays are joined with single spaces.
  `XCConfigFile { url, settings: [key: SettingValue], includes, optionalIncludes, missingIncludes }`: one file, includes
  listed not merged; `missingIncludes` holds both forms (a missing `#include` breaks the build, `#include?` is silent).

### Settings (Lane B, `Sources/XcblameKit/Settings/SettingsOracle.swift`)

- `EffectiveSettings { configuration, targets: [target: [key: String]], source: .xcodebuild/.offlineResolver, notes }`
  (`Source.label` is the `project.settingsSource` text).
- `Provenance { level: Level, file: String?, rawValue: String?, inherited: Bool }`, `Level`: `platformDefault` <
  `projectXCConfig` < `projectSettings` < `targetXCConfig` < `targetSettings` < `commandLine`, plus `unknown`.
  Order verified on Xcode 26.0.1 by the Precedence fixture (`fixtures/projects/Precedence/EXPECTED.md`).
- `ConfigurationRole.role(name:effective:) -> .debugLike/.releaseLike/.unknown` (implemented): `-Onone` or `DEBUG` in
  `SWIFT_ACTIVE_COMPILATION_CONDITIONS` → debug-like (so a deliberately bad `-O` + `DEBUG` Debug stays debug-like);
  an optimizing level without `DEBUG` → release-like; else the name prefix `debug`/`release`; else unknown.

### Rules (Lane C, `Sources/XcblameKit/Rules/`)

- `RuleSpec { id, name, category: Category, detection: Detection, signal, fix, applyKinds: [ApplyKind], verifyOnly,
  impactContext, risk, configurations: Configurations, xcode, evidenceTag: EvidenceTag, sources, conflicts,
  signalKeyTemplate, summary, severity: Severity }` with `ruleDoc` and `explainText`.
  - `Category`: `set src graph phase dep env ci dyn` (`prefix`, `dedupeRank`). `Detection`: `static dynamic both info`.
    `ApplyKind`: `overlayDebug overlayRelease overlay cli defaults scheme pbxproj manifest recommend measure`
    (`label` = RULES.md notation). `Configurations`: `debug release both ci`. `EvidenceTag`: `primary secondary
    knowledge mixed(String)`, coded as the tag text; `isKnowledgeGated` = contains `K`.
  - `severity` (added beyond the brief): `--fail-on` needs one and RULES.md has no column; it is the rule's default,
    the engine may raise or lower it (Lane C policy, document it in the catalog file).
- `RuleCatalog.all: [RuleSpec]` (empty until Lane C; Swift literals, not `catalog.json`), `RuleCatalog.spec(_:)`
  (case-insensitive; Lane C adds alias resolution: PHASE-006 → PHASE-002, SRC-010 → SET-007, CI-005 → SET-008,
  CI-007 → SET-017).
- `RuleContext { project: ProjectModel?, settings: [config: EffectiveSettings], provenance: (target, key, config) ->
  Provenance, env: EnvSnapshot?, analysis: Analysis?, document: ReportDocument?, xcode: String?, isCI, offline }`;
  `RuleContext.oracleProvenance(project)` binds `SettingsOracle.provenance`.
- `RuleResult { findings, passed, notApplicable, suppressed, ruleDocs, notes }`, `rulesEvaluated`;
  `RuleOutcome` = `ReportDocument.RuleOutcome`.
- `RuleEngine.run(_ context:, rules: [String]?, categories: [Category]?) -> RuleResult`.

## Entry points and file ownership

| File | Symbol | Phase 1 behavior | Owner |
|---|---|---|---|
| `Project/ProjectModel.swift` | `ProjectModel.load(container:scheme:) throws -> ProjectModel` | throws `notImplemented` | A |
| `Project/ProjectModel.swift` | `XCConfigFile.load(url:) throws -> XCConfigFile` | throws `notImplemented` | A |
| `Project/ProjectLocator.swift` | `ProjectLocator.find(startingAt:) -> URL?` | implemented: container itself, else `.xcworkspace` > `.xcodeproj` > `Package.swift` in the folder | A |
| `Project/ProjectLocator.swift` | `ProjectLocator.find(forBuildLog:derivedData:) -> URL?` | implemented: `<dd>/info.plist` `WorkspacePath` (dd defaults to three levels above the log), nil when absent or gone | A |
| `Project/*` (new files) | readers (pbxproj OpenStep parser, xcconfig, xcscheme, Podfile/Cartfile/Package.swift, generator) | – | A |
| `Settings/SettingsOracle.swift` | `SettingsOracle.effective(project:configuration:scheme:offline:cacheDir:) throws -> EffectiveSettings` | throws `notImplemented` | B |
| `Settings/SettingsOracle.swift` | `SettingsOracle.provenance(project:target:key:configuration:) -> Provenance` | `.unknown` | B |
| `Settings/SettingsOracle.swift` | `ConfigurationRole.role(name:effective:)` | implemented | B |
| `Rules/RuleSpec.swift` | `RuleSpec`, `RuleCatalog.all` / `spec(_:)` | empty catalog | C |
| `Rules/RuleEngine.swift` | `RuleEngine.run(_:rules:categories:) -> RuleResult` | empty `RuleResult()` (so `analyze` output is unchanged) | C |
| `Reporters/ReportDocument+Doctor.swift` | `makeDoctor(...)`, `merge(rules:project:settings:configurations:offline:)`, `fixPlan(_:)`, `failOnHit(_:threshold:)`, `ProjectSection.make(...)` | implemented | C |
| `Reporters/TextReporter+Doctor.swift` | `TextReporter.renderDoctor(_:colors:) -> String` | placeholder (header, counts, findings, plan) | C |
| `Reporters/TextReporter.swift` | findings section in the `analyze` text report | unchanged (no findings section yet) | C |
| `Resources/report.html` (+ `make template`) | doctor variant (§8.2.4: project header, findings & fix plan, environment, PASS/N/A lists; build sections say "doctor runs no build") | unchanged; renders the doctor document without throwing | C |
| `Sources/xcblame/RulesCommand.swift` | `rules list` / `rules explain` | works over the empty catalog | C (output layout only) |

Frozen (no lane edits them; a needed change stops and asks): `ReportDocument.swift`, `Nullable.swift`,
`ReportDocument+Make.swift`, `ReportPipeline.swift`, `XcblameError.swift`, and in `Sources/xcblame/`:
`DoctorCommand.swift`, `AnalyzeCommand.swift`, `GlobalOptions.swift`, `ModelLoading.swift`, `Xcblame.swift`,
`ExitCode.swift`. Tests: each lane adds its own files (`Tests/XcblameKitTests/{Project,Settings,Rules}/`); shared
`SchemaContractTests` changes only with this document.

## Frozen wiring

**`xcblame doctor [<path>] [--project <p> | --workspace <w>] [--scheme S] [--configuration C …] [--offline] [--rules
ids] [--category cats] [--fail-on none|low|medium|high] [--format text|json|html] [-o f] [--open [--browser b]]
[--xcblame-dir d]`** (plus the global `--redact`, `--quiet`, `--no-color`; `--top` is accepted and ignored).

1. Container: `--project` / `--workspace` / `<path>` (default `.`; at most one) must exist; a container path is taken
   as is, a folder goes through `ProjectLocator.find(startingAt:)`. None → `projectNotFound` → exit 5.
2. `ProjectModel.load(container:scheme:)`.
3. Configurations: `--configuration` values in order, else `model.configurationNames`. For each,
   `SettingsOracle.effective(project:configuration:scheme:offline:cacheDir: <xcblame-dir>/cache/settings)`; any error
   propagates (exit 1). The oracle itself falls back to the offline resolver with a note when xcodebuild fails.
4. `EnvSnapshot.capture()`; `xcode` = first line of `xcodebuild -version` without `Xcode `.
5. `RuleEngine.run(RuleContext(project:settings:provenance: oracleProvenance, env:, xcode:, isCI:, offline:),
   rules: --rules, categories: --category)`.
6. `ReportDocument.makeDoctor(project:settings:result:configurations:environment:xcode:generatedAt:durationSeconds:
   offline:failOn:)`; `Redactor.redact` when `--redact` resolves true (default for html).
7. Render: text `TextReporter.renderDoctor`; json `JSONReporter.render`; html `HTMLReporter.renderReport(_, taskIndex:
   nil, options: title "xcblame doctor")` → `HTMLOutput.write(kind: "doctor")`, i.e.
   `<xcblame-dir>/reports/<time>-doctor.html` without `-o`. stdout summary: `wrote <path> (<fmt>, N bytes) · N
   finding(s), N rules evaluated`.
8. Exit: 0; 4 when `doctor.failed`; 1 internal (incl. `notImplemented`: today `doctor` prints `error: not implemented
   in this build: ProjectModel.load (…)` and exits 1); 2 usage (`--fail-on` value, unknown `--category`, two
   containers); 5 project not found.

**Zero writes.** `doctor` writes only `<xcblame-dir>/cache/…`, `<xcblame-dir>/reports/` (+ the `.xcblame/.gitignore`
that `HTMLOutput` keeps) and `-o`. `runProcess` uses temp files it deletes. Lane B owns the xcodebuild side: running
`-showBuildSettings` on a project with Swift packages resolves them, which writes
`<project>.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` when missing and creates an empty
`.swiftpm/` in local packages, plus checkouts in DerivedData. The oracle must pass
`-disableAutomaticPackageResolution` (never rewriting the project's `Package.resolved`) and fall back to the offline
resolver with a note when resolution would be needed; Xcode's own DerivedData is outside the rule.

**`xcblame rules list [--category cats] [--json]`**, **`rules explain <id> [--json]`**: over `RuleCatalog.all`. Empty
catalog: `list` prints `no rules in this build` (`--json`: `[]`), `explain` exits 2 with that text; unknown id exits 2.
`explain` prints `RuleSpec.explainText` (title line, summary, signal, fix, apply kinds with `+V`, risk, impact
context, evidence tag with "needs measurement" for [K], conflicts, sources); `--json` prints the `RuleSpec`.

**`analyze`** gains `--project <p>`, `--workspace <w>` (not both), `--no-rules`, `--offline`. After
`ReportPipeline.run` and before the history save (so history entries carry findings), for real logs and
`--model-json` (not saved reports), unless `--no-rules`:
1. Container: `--project`/`--workspace` (missing path → note), else `ProjectLocator.find(forBuildLog: logURL,
   derivedData: nil)`, else the first `.xcworkspace`/`.xcodeproj` directly in the analyzed folder (a project folder
   input); none → rules run on the build only.
2. `ProjectModel.load(container:scheme: nil)`; configuration = `projects.first.defaultConfiguration ??
   configurationNames.first`; `SettingsOracle.effective` for that one configuration (same cache dir).
3. `RuleEngine.run(RuleContext(project:settings:provenance:env: document.environment, analysis:, document:, xcode:
   document.xcode.value, isCI:, offline:))` → `document.merge(rules:project:settings:configurations:offline:)`.
4. `notImplemented` from steps 1–2 is silent; any other error adds `rules: project not read (…)` to `notes`. `analyze`
   never fails because of rules. V13 is measured again after the merge (`ReportDocument.remeasuringSize`, json and
   text; html measures the page). The text report prints one `rules: N evaluated, …` line, never the PASS/N/A lists.

**Exit codes** (`ExitCode.swift`): 4 = `failOnHit`; `XcblameError.projectNotFound` → 5.

## Fixture inventory (`fixtures/projects/`)

All synthetic, hand-written, no build products; each passes `xcodebuild -list -json` and `xcodebuild
-showBuildSettings -json -project … -scheme … -configuration Debug` (Xcode 26.0.1). `FixtureProjectTests` asserts the
target names (AcmeApp resolves its packages from the committed `Package.resolved` into `.build/fixture-packages` with
`-disableAutomaticPackageResolution`; skipped when offline on the first run).

| Fixture | Shape | Meant to trigger (expected outcome) |
|---|---|---|
| `AcmeApp/AcmeApp.xcodeproj` | objectVersion 77, synchronized root groups. Targets `Acme` (iOS app, Swift + `Legacy.m`, bridging header), `AcmeKit` (dynamic framework, `MACH_O_TYPE = mh_dylib`), `AcmeCore` (static lib), `AcmeTests`. Project Debug: `SWIFT_COMPILATION_MODE = wholemodule`, `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym`, `ONLY_ACTIVE_ARCH = NO`, `SWIFT_OPTIMIZATION_LEVEL = -O` (with `DEBUG` conditions), `GCC_OPTIMIZATION_LEVEL = s`, `ENABLE_BITCODE = YES`, `OTHER_LDFLAGS = -ld_classic`; Release good but `OTHER_SWIFT_FLAGS = $(inherited) -debug-time-function-bodies`; `AcmeKit` target `SWIFT_ENABLE_BATCH_MODE = NO` (both configs). Script phases on `Acme`: `Lint` (swiftlint, no I/O), `Generate Constants` (inputs + outputs declared), `Upload Symbols` (`sentry-cli upload-dif`, no `${CONFIGURATION}` guard, no outputs), `Stamp Build` (`alwaysOutOfDate = 1`). Packages: swift-argument-parser `kind = branch` (main) → `Acme`, swift-collections exact 1.1.4 → `AcmeKit`, local `Packages/AcmeShared` (target `AcmeShared` depends on `SwiftSyntax` from swift-syntax exact 602.0.0, applies build-tool plugin `AcmeGen`) → `Acme`. Shared scheme `Acme`: `parallelizeBuildables = "NO"`. | Findings: SET-001, SET-002, SET-003 (Acme has C sources), SET-004, SET-005, SET-009 (AcmeKit), SET-010, SET-020 (Release), SET-027, PHASE-001 (Lint, Upload Symbols, Stamp Build; not Generate Constants), PHASE-002 (Upload Symbols), PHASE-003 (Lint), PHASE-005 (AcmeGen), DEP-001 (swift-argument-parser), DEP-012 (static: SwiftSyntax in non-macro AcmeShared), GRAPH-007; SET-016 (Xcode 26, caching unset; `+V`, needs measurement). Pass: SET-007, SET-011, SET-014, DEP-002 (Package.resolved committed). N/A: DEP-008 (no macro target), SET-023 (one dynamic framework), PHASE-007, DEP-004/005/006. Suppressed/deferred: SET-030 (waits for PHASE-001). Maybe GRAPH-013 (local + branch-pinned remote). |
| `AcmeLegacy/AcmeLegacy.xcodeproj` | objectVersion 56, classic `PBXGroup`/`PBXBuildFile` lists. `AcmeLegacy` (app) embeds `AcmeLegacyKit` (dynamic framework, Swift + `LKHelper.m`, public header). Debug good (`-Onone`, `dwarf`, `ONLY_ACTIVE_ARCH = YES`, `GCC_OPTIMIZATION_LEVEL = 0`); Release `wholemodule`/`-O`. Script `Version Bump` (PlistBuddy on the built Info.plist, no I/O). Shared scheme, `parallelizeBuildables = "YES"`. | Reader path for classic groups (file refs → `hasSwiftSources`, `hasCSources`, `.sources(count: 1/2)`). Findings: PHASE-001 (Version Bump). Pass: SET-001…SET-005, SET-003 (C sources, level 0), GRAPH-007. N/A: packages, SET-023. |
| `Precedence/Precedence.xcodeproj` | One app target `Probe`; `Config/project.xcconfig` (`#include "base.xcconfig"`, `#include? "missing.xcconfig"`, `ACME_PROBE_SDK[sdk=iphonesimulator*]`) as project base configuration, project `buildSettings`, `Config/target.xcconfig` as target base configuration, target `buildSettings` with and without `$(inherited)`; keys `ACME_PROBE_*`, `SWIFT_ACTIVE_COMPILATION_CONDITIONS`, `OTHER_SWIFT_FLAGS`, `GCC_PREPROCESSOR_DEFINITIONS`, `PRODUCT_NAME`. | Provenance and offline-resolver ground truth: `EXPECTED.md` (value, level, file, inherited per key, Debug and Release, both SDKs, command line and `-xcconfig` observations). `XCConfigFile.missingIncludes` lists `missing.xcconfig`. |
| `PodsLike/PodsLike.xcodeproj` | App `PodsLike` with `[CP] Check Pods Manifest.lock` and `[CP] Embed Pods Frameworks` phases (no Pods xcconfig references, no `Pods/`, no workspace). `Podfile` (3 pods, `use_frameworks!`, `post_install` sets `EXCLUDED_ARCHS[sdk=iphonesimulator*] = arm64` and `ENABLE_BITCODE = YES`), `Podfile.lock` (3 pods, synthetic checksums), `Cartfile` (2 entries). | `dependencyManagers` = cocoapods (`podCount` 3) + carthage. Findings: DEP-005, DEP-006, PHASE-007, SET-006 (Podfile), SET-010 (Podfile). Pass/N/A: DEP-004 (3 ≤ 20 pods). |
| `GenXcodeGen/AcmeGen.xcodeproj` + `project.yml` | Tiny app generated-style project next to an XcodeGen spec. | `generator = xcodegen(spec: project.yml)`; `pbxproj`/`scheme` apply kinds downgrade to `rec` with the `project.yml` change (RULES.md §10). |
| `GenTuist/AcmeTuist.xcodeproj` + `Project.swift` + `Tuist/` | Tiny app next to a Tuist manifest (`Tuist/Config.swift`, `Tuist/ProjectDescriptionHelpers/`). | `generator = tuist(manifest: Project.swift)`; DEP-007; same downgrade as XcodeGen. |
| `Scripts/make-large-fixture.sh <dir> [n=200]` | Writes `<dir>/Large.xcodeproj`: `LargeApp` + 199 static libraries (macOS), each depending on the next two, a no-output script phase on every 10th target; one Swift file per target. | Performance gate: `doctor` < 5 s on 200 targets. Measured here: generation ~12 s, `xcodebuild -list` 0.8 s, `-showBuildSettings -json -alltargets` 2.3 s and 7.4 MB per configuration, so two configurations must run concurrently (Lane B). 20 × PHASE-001. |

## Notes for the lanes (observed while writing the fixtures, Xcode 26.0.1)

- `-showBuildSettings -scheme Acme` lists only the scheme's build-action targets (`Acme`), not its implicit
  dependencies; `-alltargets` lists the four project targets; neither listed the `AcmeShared` package target in a
  quick probe. Lane B decides how `EffectiveSettings.targets` gets package targets (DESIGN §7.4 claims it does) and
  records it in `notes`; `ProjectSection.packageTargets` reads whatever the oracle returns.
- Effective values keep xcodebuild's spacing (a leading space where `$(inherited)` was empty); rules should split on
  whitespace, never compare raw strings for list-typed keys.
- Precedence is project xcconfig < project settings < target xcconfig < target settings < command line; `-xcconfig`
  won over a target-level `OTHER_SWIFT_FLAGS` without `$(inherited)` (MV-3 report not reproduced for
  `-showBuildSettings`).
- The local-package product dependency has no `package =` key (`XCSwiftPackageProductDependency { productName }`);
  Lane A matches it to the `XCLocalSwiftPackageReference` by product name from the manifest.
- `ProcessRunner.runProcess` / `runProbe` (2 s default timeout) are the subprocess helpers; the oracle needs a longer
  timeout (package resolution) and must record a timeout as a note plus offline fallback.

## Lane A notes (`ProjectModel.load`, readers in `Sources/XcblameKit/Project/`)

- **Containers.** `.xcworkspace` (every `FileRef` resolved: `group:`, `container:`, `absolute:`, `self:`), `.xcodeproj`,
  `Package.swift` or its folder; any other folder goes through `ProjectLocator.find(startingAt:)`. A workspace member
  that fails to parse becomes a note (a `project.xcproj` member still throws `notImplemented`); a workspace with no
  readable project throws `readerFailure`. `Pods/Pods.xcodeproj` is **not** read (note + `cocoapods` manager when a
  `Podfile` sits next to the container), which differs from the `ProjectModel.projects` doc comment ("included when
  present"): its targets are regenerated and would only add noise.
- **`defaultConfiguration`** follows the brief, not the field's doc comment: the `LaunchAction` configuration of the
  `scheme` argument (else of the project's first shared, then user scheme), else `Debug` when present, else the list's
  `defaultConfigurationName`, else the first configuration. AcmeApp: `Debug` (its list default is `Release`).
- **pbxproj** via `PropertyListSerialization` (no hand parser was needed, objectVersion 46–90). `BuildPhase.other(name:)`
  carries the isa. `shellScript` arrays are joined with `\n`. `baseConfigurationReferenceAnchor` +
  `…RelativePath` (xcconfig inside a synchronized folder) resolve. A folder file reference
  (`lastKnownFileType = wrapper|folder`) holding a `Package.swift` is a local package (pre-Xcode 15 style). Unknown
  isa objects are ignored with one note per isa.
- **Synchronized folders** are listed on disk (read-only): `.swift` and C-family files are sources; headers,
  `.xcconfig`, `.entitlements` and `Info.plist` are skipped; bundle-like folders (`.xcassets`, `.bundle`, `.xcstrings`,
  …) count as one resource; everything else is a resource. `membershipExceptions` of an exception set naming the target
  are excluded. `largeFileBytes` sums files over 10 MB each (the type's doc comment); PHASE-010 compares that sum with
  50 MB. Nil only when no resource file resolved to a path.
- **Packages.** Remote requirement kinds map 1:1; local paths resolve against the project's `SRCROOT`; references are
  deduplicated by path or by URL (case, trailing `/` and `.git` ignored). A product dependency without `package =` binds
  to the local package whose manifest lists it as a product (or target); unbound products become notes.
- **Package.swift** (`// ponytail:` heuristic, no `dump-package`): the literal `Package(...)` call only, comments
  stripped, strings and brackets balanced. Targets/dependencies built in variables or appended later are not seen (a
  note says so). Manifest dependency `products`/`consumers` come from `.product(name:package:)` matched by package
  identity (last URL/path component without `.git`, or `name:`).
- **xcconfig.** A value ends at the first `//` (Xcode does the same, URLs included), a trailing `;` is dropped, the
  assignment `=` is the first outside `[...]`. `$(inherited)` and other references stay unexpanded. An unconditional
  assignment does not clear earlier conditional ones (both are kept in one `SettingValue`). Include paths starting with
  a build-setting reference (`$(SRCROOT)/…`) or `<…>` are not resolved and are listed in no `XCConfigFile` array; the
  loader notes them. Line continuations are unsupported (noted). `XCConfigFile.resolved(key:)` replays includes in
  place (depth first, later definitions win, cycles and depth > 32 stop), re-reading from disk.
- **Facts for Lane C** (internal, same module): `ManifestReaders.podfile(_:) -> PodfileFacts` (`pods`, `useFrameworks`,
  `postInstall` body text, `postInstallSettings` key → value), `ManifestReaders.cartfile(_:)`,
  `ManifestReaders.podCount(lockfile:)`, `XCConfigReader.flatten(url:)`. Notes carry absolute paths (redaction is the
  report layer's job). Synthesized `Codable` omits nil optionals in `ProjectModel` JSON.
- **Not Lane A, observed:** `XcblameError.readerFailure`'s description says "could not read the build log", which is
  misleading for a corrupt project file; a project-specific case or wording would read better.

## Lane B notes (SettingsOracle, Xcode 26.0.1)

- **Any xcodebuild that opens a project writes into it**, `-list` included: an empty
  `<project>.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/configuration/` when missing, `Package.resolved` there
  when packages resolve, `.swiftpm/xcode/` in local packages. `-derivedDataPath` requires `-scheme`, so `-alltargets`
  cannot be pointed at the cache. `FixtureProjectTests.testXcodebuildListsEveryFixture` (`-list -project`) leaves
  these empty folders in every fixture today (untracked, so git does not show them).
- The oracle never opens the container: it writes `<cache home>/oracle/<sha16(container)>/Settings.xcworkspace`
  (`OracleCache`: `~/Library/Caches/xcblame`, else `$TMPDIR/xcblame`, `XCBLAME_CACHE_DIR` overrides)
  (absolute `FileRef`s to every project, a copy of the container's `Package.resolved`, and a generated scheme
  `xcblame-settings` whose build action lists every project target by id and name) and runs
  `xcodebuild -showBuildSettings -json -workspace … -scheme xcblame-settings -configuration C -derivedDataPath
  …/DerivedData-<sha8(C)> -clonedSourcePackagesDirPath …/SourcePackages -disableAutomaticPackageResolution
  -skipPackagePluginValidation -skipMacroValidation -skipUnavailableActions [-skipPackageUpdates once checkouts are
  cached]`, with `GIT_OPTIONAL_LOCKS=0`. One call lists all targets of all projects: 200 targets 2.4 s/config
  (`-alltargets` 2.2 s; `-target` per target would be ~200 calls); Debug+Release concurrently 2.7–3.3 s cold.
  `cacheDir` holds only the settings JSON (the CLI passes `<xcblame-dir>/cache/settings`, git-ignored as `cache/`):
  entries are `cacheDir/<sha256>.json`, keyed also by the xcblame version and `XCODE_XCCONFIG_FILE`.
- Projects without packages run under `sandbox-exec` (writes denied below the root, each project folder and local
  package, allowed below the scratch folder, which may sit inside the project). SwiftPM sandboxes manifest evaluation
  and nested sandboxes are refused (`sandbox_apply: Operation not permitted`), so package projects run unsandboxed
  and `WriteGuard` removes the empty `.swiftpm/` trees xcodebuild creates in local packages, restoring the folder
  mtime to the nanosecond; anything else new is noted (`xcodebuild wrote … (left in place)`), never deleted.
- A wrong `BlueprintIdentifier` still lists the target (xcodebuild falls back to `BlueprintName`). No targets listed,
  a non-zero exit, a timeout or unreadable JSON → offline resolver with `xcodebuild failed (<first error line>);
  offline resolver` first in `notes`. Fallbacks and guard leftovers are never cached; a cache hit appends `cache hit`.
- Package targets: xcodebuild never lists them, not even with a package entry in the generated scheme.
  `EffectiveSettings.targets` gets local package targets (`regular`/`executable`/`test`/`macro`) from the offline
  resolver with only `SWIFT_VERSION` (`swiftLanguageModes`/`swiftLanguageVersions`, else tools version ≥ 6 → `6`,
  else `5`; read from the `Package.swift` text since `PackageManifest` has neither field) and the note `package
  targets: offline resolver only (SWIFT_VERSION from the manifest; other settings unknown)`. Remote package targets
  are absent.
- Package-using projects pay ~1.8 s to open the workspace (`-list` alone is as slow): AcmeApp Debug alone 2.7–2.9 s,
  Debug+Release batch 2.9–3.1 s (concurrent; serial would be ~5.5 s).
- `Provenance.file` is relative to `project.root` when inside it (else absolute). Conditions are matched against the
  effective `SDK_NAME` (else the SDKROOT path's SDK), `ARCHS` and the configuration when the caller passes the
  target's effective map (`provenance(…, commandLineOverrides:, effective:)`), else against the target's SDKROOT as
  written (`iphoneos` matches `sdk=iphoneos*`); arch conditions need the effective map. Within a level later lines
  win and `$(inherited)` chains to the previous assignment (includes flattened in place); pbxproj conditional values
  come after the unconditional one.
- Offline resolver: `$(inherited)` at the bottom of a chain is empty (matches xcodebuild for the Precedence keys);
  `$(KEY)`/`${KEY}` resolve late within the target (plus `TARGET_NAME`, `PROJECT_NAME`, `CONFIGURATION`, `SRCROOT`,
  `PROJECT_DIR`, `SOURCE_ROOT`); references to keys nothing sets stay unexpanded and are listed in one note. Only
  keys the project writes are emitted.
- New public API (extensions, no type change): `SettingsOracle.effectiveAll(project:configurations:scheme:offline:
  cacheDir:timeout:)` (the CLI loops `effective` per configuration today; switching `DoctorCommand` to `effectiveAll`
  is what makes configurations concurrent), `provenance(…, commandLineOverrides:, effective:)`,
  `provenanceChain(…) -> [Provenance]`, `isShadowed(…, byLevelAbove:, commandLineOverrides:) -> Provenance?` (the
  highest non-`$(inherited)` assignment above the level), `invalidateCache(cacheDir:)`.
- `DoctorContractTests.testStubsThrowNotImplemented` asserted the phase-1 stubs; replaced at integration by
  `testEntryPointsAreReal`.

## Lane C notes

- **Catalog**: 49 rules in `RuleCatalog.all` (SET 26, PHASE 6, DEP 10, ENV 7; SET-011, DEP-004 and ENV-008 added
  after the review, static parts), the RULES.md columns verbatim
  (`RulesCatalogTests` compares them), one file per category (`Rules/Catalog+SET.swift` …) holding the literals and
  the predicates. `sources` = `[OC] <record>`, then other keys (`[PP] A6`, `[BP] §4`, `[OBS-n]`), then the S-index
  resolved to URLs. Aliases (PHASE-006, SRC-010, CI-005, CI-007) resolve in `RuleCatalog.spec` and `--rules`.
  SET-007's `@testable` source scan, SET-017's history condition, SET-021's git-log part, DEP-002's resolve time and
  DEP-003's `binaryTarget` check are not part of v0.3 (stated in the finding or pass text).
- **Severity policy** (`Confidence.severity`): the catalog default; a [K]-gated rule is at most `low`; a measured
  `L` band raises to `high`, `M` to at least `medium`; predicates override per signal (SET-027 `high` on Xcode 27,
  SET-010 `low` from Xcode 14, ENV-005 `high` under Rosetta, SET-013 `info` as a 16-25 candidate).
- **needsMeasurement** = any [K] part, or a `+V` rule whose impact was not measured on this build (SET-016 in
  `doctor`). Static [P]/[S] findings keep `needsMeasurement = false` with band `?` and a `catalog` evidence item.
- **Bands**: from seconds and share; with both the larger band wins.
- **Granularity and signal keys**: settings rules emit one finding per rule (all targets and role-matched
  configurations in scope; key `setting:<KEY>:<targets joined by +>:<configs>`); script rules one per phase
  (`script-phase:<id>`, `script-guard:<id>`, `script-linter:<id>`, `script-codegen:<id>`), so a phase can carry
  PHASE-001 and PHASE-002; packages one per package (`package:<normalized url>`). `[CP] …` phases belong to
  PHASE-007 and are skipped by PHASE-001…004.
- **Shadowing** (§7.5): the hook includes the overlay from the project-level base xcconfig, so explicit values in
  the project file at project or target level, target xcconfigs and the command line all shadow it. AcmeApp's Debug
  values are written in the project-level `buildSettings`, so SET-001…005/010 are shadowed there and offer
  `--edit-project` (fix kind `project`; `cli` on CI with the MV-3 caveat; `recommend` for generated projects, with
  the generator-source change as evidence). Integration: `RuleScan` asks `SettingsOracle.provenance` (with the
  target's effective map) and `SettingsOracle.isShadowed(…, byLevelAbove: .projectXCConfig)` unless an injected
  `RuleContext.provenance` knows the level; only a run without a project model notes unknown provenance.
- **Provenance strings** in `evidenceDetails[].provenance`: `target settings (App.xcodeproj)`,
  `project xcconfig (Config/Debug.xcconfig)` (level label plus the file, a pbxproj shown as its `.xcodeproj`).
- **analyze**: dynamic parts that need no configuration run without a project (PHASE-001 script tasks in
  incremental/zero-change builds, DEP-012 remote-package share of a clean build); measured costs on settings rules
  attach only when the analyzed configuration is role-matched. Every analyze run with rules now carries a `doctor`
  section (mostly N/A without a project).
- **ENV probes**: `EnvSnapshot` has no Xcode-defaults fields, so ENV rules read `defaults read com.apple.dt.Xcode`,
  `diskutil`, `tmutil`, `pmset`, `sysctl` through `MachineProbe` (2 s each, read-only), only when the context has an
  environment snapshot.
- **Frozen-file touches**: one call line in `TextReporter.render`; `RulesCommand.List` prints
  `RuleCatalog.listTable` (C owns its layout); `DoctorContractTests` stub assertions on the empty catalog replaced.

## Integration notes (v0.3)

- `doctor` and `analyze` call `SettingsOracle.effectiveAll` (configurations concurrent, `defaultTimeout` 20 s each,
  then the offline resolver with a note); each configuration's oracle notes reach `project.notes` as
  `<configuration>: <note>`. The stdout summary ends with `· settings: <settingsSource>`.
- Package projects: `-clonedSourcePackagesDirPath` is the project's own `SourcePackages` (Xcode DerivedData matched by
  `WorkspacePath` with or without build logs, or a project-local DerivedData) when its `workspace-state.json` revisions
  equal `Package.resolved` (note `package checkouts from …`; first configuration alone, `-skipPackageUpdates` always;
  changed pins: not used, note), else the oracle cache's; a cold cache resolves the first configuration alone, and
  only `doctor` may resolve: `analyze` (`resolvePackages: false`, 5 s per configuration) goes offline at once when no
  checkouts exist.
- The generated multi-target scheme makes xcodebuild report `ONLY_ACTIVE_ARCH = NO` and can evaluate dependency targets
  for macOS (AcmeLegacyKit, AcmeKit). SET-005 reads the offline-resolved (written) value, else the effective one.
  Since the re-check, targets run per platform group with `-destination generic/platform=<P>` (DESIGN §7.4).
- Podfile `post_install` facts reach the rules through `RuleContext.podfileFacts` (Lane A's `ManifestReaders.podfile`):
  SET-006, SET-010, SET-027.
- `XcblameError.projectUnreadable` (exit 1, "could not read the project: …") for corrupt project files; a missing
  container stays `projectNotFound` (exit 5).
- Fixture inventory on the real reader and oracle (`RulesEngineTests`): every Xcode 26 fixture also gets SET-016 and
  SET-029 (no fixture writes Debug `COPY_PHASE_STRIP = NO`, AcmeApp aside); AcmeWorkspace = AcmeApp + DEP-002, DEP-005,
  PHASE-007; GRAPH-007 is not in the v0.3 catalog.
