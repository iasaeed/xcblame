# AcmeFixBreaker: a fix that breaks the build (SET-030)

Same layout as AcmeFixWin (macOS SwiftUI app `AcmeFixBreaker`, settings only in `Config/<Configuration>.xcconfig`),
plus a `Read Inputs` script phase that declares `Scripts/declared.txt` as input and
`$(DERIVED_FILE_DIR)/acme-inputs.txt` as output (so PHASE-001 is quiet and SET-030 is not deferred), but also reads the
undeclared `Scripts/undeclared.txt`.

- Planted: `ENABLE_USER_SCRIPT_SANDBOXING = NO` (with `FUSE_BUILD_SCRIPT_PHASES = YES`, so SET-030 has one key).
- `xcblame fix --rules SET-030` plans one `overlay` step through the `hook` for Debug and Release
  (`ENABLE_USER_SCRIPT_SANDBOXING = YES`), `verifyKind` `incremental`.
- Expected verify verdict: `reverted (broke build)`: with sandboxing on, the sandbox denies the undeclared read and the
  build fails (`** BUILD FAILED **`, Xcode 26.0.1).

Caveat: Xcode's script sandbox profile denies reads under `SRCROOT` by path, and xcodebuild reports a copy under
`/tmp` or `/var/folders` by its symlinked path (`/tmp/…`), which the sandbox does not match: there the build
succeeds. Build a copy whose path has no symlink (resolve with `realpath`, e.g. `/private/var/folders/…`, or a folder
under the home directory).
