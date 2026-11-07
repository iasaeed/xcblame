# Xcode IDE (GUI) .xcactivitylog inventory - BLOCKED, no IDE log produced

Status (2026-10-30): no GUI-written log was obtained. Findings so far:

1. `open -a /Applications/Xcode.app <proj>` fails on this host (macOS 27.0 / 26A428) with
   `_LSOpenURLsWithCompletionHandler() failed ... error -10664` (Xcode 26.0.1 build 17A400,
   LSMinimumSystemVersion 15.6, so the cause is not the plist minimum; LaunchServices refuses it).
   Xcode-27.1-beta.app (min 26.6) was not tried.
2. Launching the binary directly (`Contents/MacOS/Xcode`) works; project open via AppleScript
   (`tell application "Xcode" to open ...`) started indexing (Index.noindex/SymbolCache created in
   DerivedData/AcmeApp-fhhfterbyoixxmbvtvqjulxjpqpq) but the Apple event then timed out (-1712) and
   Xcode stopped answering AppleScript. `System Events` also timed out (-1712) for every query, so
   the Product > Build menu fallback is unavailable. `screencapture` fails ("could not create image
   from display") and the user denied computer-use access to Xcode, so a possible modal
   (macro/package trust dialog) could not be inspected. Main thread sampled idle in the event loop.
3. Resulting DerivedData Logs/Build/LogStoreManifest.plist is empty (`logFormatVersion 11`, `logs {}`);
   no .xcactivitylog and no .xcresult exist. Xcode was killed afterwards (SIGTERM, process I launched).
4. AcmeApp git status was clean before and after (0 lines).

Next step options: run the build from a session that has Automation + Accessibility + Screen Recording
granted (or let the user click Product > Build once, then re-run steps 3-5 of the plan).

## Partial result: IDE-written Package logs (Logs/Package), Xcode 26.0.1 GUI process

Five "Resolve Packages" logs were written by the IDE (fixtures: fixtures/logs/ide-xcode26/*.xcactivitylog + LogStoreManifest.plist
from Logs/Package). SLF header bytes: `53 4c 46 30 31 31 23 32 31 25 49 44 45 41 63 74` = "SLF011#21%IDEAct" (SLF version 011, same as CLI).

slftok.py on 8DDE6B16-...slf (IDE):   classes = IDEActivityLogSection (3 refs), DVTDocumentLocation (2); no errors; 67 tokens.
slftok.py on CLI Package-70C9A68D-... : classes = IDECommandLineBuildLog (1), IDEActivityLogSection (1); 43 tokens.
=> IDE root class is IDEActivityLogSection (confirmed); CLI root is IDECommandLineBuildLog. Root title "Resolve Packages",
   domainType Xcode.IDEActivityLogDomainType.PackageLog, manifest className IDEActivityLogSection, signature "Resolve Packages",
   no Resolve Package Graph child section in IDE log. Manifest logFormatVersion 11, primaryObservable highLevelStatus "S".
Build-log (Logs/Build) comparison remains outstanding.
