# AcmeFixWin: planted real wins (SET-005, SET-004)

Synthetic macOS SwiftUI app, one target `AcmeFixWin`, scheme `AcmeFixWin`. Every setting lives in the project-level
base xcconfigs (`Config/Debug.xcconfig`, `Config/Release.xcconfig`, both `#include "Shared.xcconfig"`); the project
file sets none, so nothing shadows the overlay and `xcblame fix --install-hook` can hook each configuration. The 40
`AcmeFixWin/Synthetic*.swift` files (generic helpers and small SwiftUI views, compile-time weight only) make a clean
Debug build take about 10 s, so a planted setting's effect is far outside the noise band (fix round 1, 2026-11-06:
the original one-file app built in ~1.7 s and SET-004's ~0.1 s gain stayed within noise, `reverted (within noise)`).

- Planted (the verify fixture): Debug `ONLY_ACTIVE_ARCH = NO` → SET-005. On a macOS destination Debug compiles every
  source for arm64 and x86_64 and links a universal binary; the overlay's `ONLY_ACTIVE_ARCH = YES` halves the compile
  work. Declared effect: the Swift driver/compile, link and `CreateUniversalBinary` task kinds.
- Planted (smaller): Debug `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym` → SET-004 (`GenerateDSYMFile` on every build;
  about 0.1 s here, so a SET-004 verify is expected `reverted (within noise)`; the CLI and hook tests use SET-004 for
  its plan shape only).
- `xcblame fix --rules SET-005` plans one `overlay` step through the `hook`:
  `ONLY_ACTIVE_ARCH = YES // xcblame SET-005 (plan <id>)` in `.xcblame/overlay-Debug.xcconfig`.
- Also fires: SET-016 (compilation caching, `+V`) and machine ENV rules; use `--rules`.

Verify (on a scratch copy; `XCBLAME_CACHE_DIR` keeps the oracle and per-arm DerivedData out of `~/Library`):

```
xcblame fix --rules SET-005 --install-hook
xcblame verify --rules SET-005 --kind clean --runs 5 -- -project AcmeFixWin.xcodeproj -scheme AcmeFixWin \
  -configuration Debug -destination platform=macOS CODE_SIGNING_ALLOWED=NO
```

Expected verdict: `kept`. Measured 2026-11-06 (Mac, 28 cores, Xcode 26.0.1, hook mechanism, clean ABAB, 5 runs):
A p50 10.55 s (MAD 0.17), B p50 6.29 s (MAD 0.25), delta −4.26 s (−40.3 %), noise band 0.65 s; checks oracle, exit
code, target set and thermal pass, task kinds `warn` (arm A's first, cold run also built the explicit-module PCMs).
Then `xcblame fix --rules SET-005 --apply` writes the block, `xcblame fix --revert` removes it and
`xcblame fix --uninstall-hook` restores `Config/` byte-identical.

Build: `xcodebuild -project AcmeFixWin.xcodeproj -scheme AcmeFixWin -configuration Debug -destination platform=macOS
-derivedDataPath <tmp> CODE_SIGNING_ALLOWED=NO build`.
