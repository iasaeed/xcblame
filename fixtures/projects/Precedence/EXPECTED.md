# Precedence fixture: expected effective values and winning level

One app target, `Probe`, with a setting family written at every level (DESIGN §7.4, low to high):
platform default < project xcconfig (`Config/project.xcconfig`, which `#include`s `Config/base.xcconfig` and
`#include?`s the missing `Config/missing.xcconfig`) < project `buildSettings` < target xcconfig
(`Config/target.xcconfig`) < target `buildSettings` < command line.

Verified with Xcode 26.0.1 (17A400):
`xcodebuild -showBuildSettings -json -project Precedence.xcodeproj -scheme Probe -configuration <C> [-sdk <sdk>]`.
Values are exactly as xcodebuild prints them (a leading space where `$(inherited)` expanded to nothing).
"Level" is the `Provenance.Level` the oracle must report; "file" is `Provenance.file` (relative to this folder).

## Debug (sdk iphoneos unless noted)

| Key | Effective value | Level | File | `$(inherited)` at the winner |
|---|---|---|---|---|
| `ACME_PROBE_BASE` | `base` | projectXCConfig | `Config/base.xcconfig` (via `#include`) | no |
| `ACME_PROBE_PROJECT_XCCONFIG` | `project-xcconfig` | projectXCConfig | `Config/project.xcconfig` | no |
| `ACME_PROBE_INCLUDE_ORDER` | `project-xcconfig` | projectXCConfig | `Config/project.xcconfig` (assigned after the include, so it beats `base.xcconfig`) | no |
| `ACME_PROBE_PROJECT_SETTINGS` | `project-settings` | projectSettings | `Precedence.xcodeproj/project.pbxproj` | no |
| `ACME_PROBE_TARGET_XCCONFIG` | `target-xcconfig` | targetXCConfig | `Config/target.xcconfig` | no |
| `ACME_PROBE_TARGET_SETTINGS` | `target-settings` | targetSettings | `Precedence.xcodeproj/project.pbxproj` | no |
| `ACME_PROBE_LAYER` | `target-settings` | targetSettings | `Precedence.xcodeproj/project.pbxproj` | no |
| `ACME_PROBE_SDK` (iphoneos) | `any` | projectXCConfig | `Config/project.xcconfig` | no |
| `ACME_PROBE_SDK` (`-sdk iphonesimulator`) | `simulator` | projectXCConfig | `Config/project.xcconfig` (conditional `[sdk=iphonesimulator*]`) | no |
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | ` FROM_PROJECT_XCCONFIG DEBUG FROM_PROJECT_SETTINGS FROM_TARGET_XCCONFIG FROM_TARGET_SETTINGS` | targetSettings | `Precedence.xcodeproj/project.pbxproj` | yes (every level contributes) |
| `OTHER_SWIFT_FLAGS` | `-DTARGET_SETTINGS_ONLY` | targetSettings | `Precedence.xcodeproj/project.pbxproj` | no (drops every lower level) |
| `GCC_PREPROCESSOR_DEFINITIONS` | `TARGET_XCCONFIG=1` | targetXCConfig | `Config/target.xcconfig` | no (drops the project levels) |
| `PRODUCT_NAME` | `ProbeFromTargetXCConfig` | targetXCConfig | `Config/target.xcconfig` | no |

## Release (differences from Debug)

| Key | Effective value | Level | File | `$(inherited)` |
|---|---|---|---|---|
| `ACME_PROBE_LAYER` | `target-xcconfig` | targetXCConfig | `Config/target.xcconfig` (Release sets no target-level value) | no |
| `SWIFT_ACTIVE_COMPILATION_CONDITIONS` | ` FROM_PROJECT_XCCONFIG FROM_PROJECT_SETTINGS FROM_TARGET_XCCONFIG FROM_TARGET_SETTINGS` | targetSettings | `Precedence.xcodeproj/project.pbxproj` | yes |
| `OTHER_SWIFT_FLAGS` | ` -DPROJECT_XCCONFIG -DPROJECT_SETTINGS -DTARGET_XCCONFIG` | targetXCConfig | `Config/target.xcconfig` | yes |

All other rows are as in Debug (`ACME_PROBE_SDK` likewise `any` / `simulator`).

## Observations (settle DESIGN §7.4 questions for Xcode 26.0.1)

- Project xcconfig < project settings: the project-level `buildSettings` value wins over the project-level
  `baseConfigurationReference`, and its `$(inherited)` pulls the xcconfig value in (`FROM_PROJECT_XCCONFIG` precedes
  `FROM_PROJECT_SETTINGS`). The same holds one level up for the target.
- `#include?` of a missing file is silent; `XCConfigFile.missingIncludes` must still list `Config/missing.xcconfig`.
- Command line (Debug): `ACME_PROBE_LAYER=command-line OTHER_SWIFT_FLAGS=-DCLI` → `command-line` and `-DCLI`
  (level `commandLine`).
- `-xcconfig <file>` with `ACME_PROBE_LAYER = xcconfig-flag` and `OTHER_SWIFT_FLAGS = -DXCCONFIG_FLAG` → both win
  over the target-level values, including `OTHER_SWIFT_FLAGS`, which the target sets without `$(inherited)`. On this
  Xcode the "an -xcconfig flag loses to target settings without `$(inherited)`" report of DESIGN §7.5 (MV-3) does
  not reproduce for `-showBuildSettings`; the oracle check stays mandatory.
