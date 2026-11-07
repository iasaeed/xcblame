# Real xcactivitylog inventory (AcmeApp, macOS app, Debug, arm64)

Project: /Users/<you>/Projects/acmeapp (AcmeApp.xcodeproj; scheme `AcmeApp`; links local SwiftPM package `LocalizeCore` at repo root + remote swift-syntax 602.0.0, which adds 5 SwiftSyntaxNNN version-marker targets, ~240 SwiftCompile tasks total). It is a **macOS** app (no iOS target), so destination = `platform=macOS` (arm64 Mac Studio), not an iPhone simulator. Project files verified unchanged afterwards (sorted sha diff empty, `git status` clean); only `touch` on `Sources/LocalizeCore/ImportPlanner.swift` between builds.
Scratch: `<L>` = /private/tmp/claude-501/-Users-you--claude-spares-spare-TFCZwc/af624146-a990-430f-a625-aea8fae4b5e2/scratchpad/logs
Command (both versions, via `<L>/run.sh <ver> <DEVELOPER_DIR>`):
`xcodebuild -project AcmeApp.xcodeproj -scheme AcmeApp -configuration Debug -destination platform=macOS -clonedSourcePackagesDirPath <L>/spm$V -derivedDataPath <L>/dd$V -showBuildTimingSummary -resultBundlePath <L>/r$V.xcresult OTHER_SWIFT_FLAGS='-Xfrontend -debug-time-function-bodies -Xfrontend -warn-long-expression-type-checking=50' CODE_SIGNING_ALLOWED=NO clean build`
(clean+build in ONE invocation => 2 xcactivitylogs: "Cleaning project..." and "Building project..."; incremental run = separate invocation, `build` only, different resultBundlePath r$V-incr.xcresult.)

## 0. Summary table

| | Xcode 26.0.1 | Xcode 27.1 beta |
|---|---|---|
| Result | BUILD SUCCEEDED (clean + incr) | BUILD SUCCEEDED (clean + incr) |
| Clean build wall (process, incl. package resolve) | 26 s (log recorded 18.1 s) | 45 s (log recorded 28.5 s) |
| Incremental wall (touch ImportPlanner.swift) | 3 s (log 1.6 s) | 4 s (log 1.7 s) |
| SLF header | `SLF0` + `11#` (version 11) | `SLF0` + `13#` (version 13) |
| LogStoreManifest `logFormatVersion` | 11 | 13 |
| .xcactivitylog gz size (clean build / incr / clean-action) | 468,866 / 16,368 / 715 B | 562,385 / 12,830 / 708 B |
| Unzipped .slf size (clean build) | 12,497,589 B | 13,428,173 B |
| SLF tokens (clean build) | 18,735 | 20,564 |
| Function-body timing lines (`NNN.NNms\t/path:l:c\tdecl`) | 23,983 in stdout AND in SLF AND in xcresult log | 23,726 in stdout AND SLF AND xcresult |
| `warn-long-expression` warning | 1 (StudioView.swift:394, 62ms) in stdout, SLF, xcresult | 0 expression warnings (the 1 warning is a different one: `ImplicitStrongCapture` StudioModel.swift:112) |
| Build Timing Summary in stdout | yes | yes |
| Build Timing Summary in SLF | yes (`com.apple.dt.IDE.timing.aggregate` sections, 22) | yes (22) |

## Xcode 26: Xcode 26.0.1

### Files produced (dd26/Logs)
```
468866 B gz  12497589 B raw  dd26/Logs/Build/20E8B73D-96FE-4232-8A33-311BFD02F961.xcactivitylog
715 B gz  1427 B raw  dd26/Logs/Build/F49B68E8-5662-416D-A441-2F16BAF5D402.xcactivitylog
16368 B gz  175285 B raw  dd26/Logs/Build/D822889B-3D9A-478F-BB03-AB98C3967FD1.xcactivitylog
266 B gz  458 B raw  dd26/Logs/Package/70C9A68D-DD85-4024-8DC5-1D11054D07EE.xcactivitylog
536 B gz  1309 B raw  dd26/Logs/Package/B0761B97-5CC6-4A31-B8FC-F1E6E96D8878.xcactivitylog
```

### SLF header (xxd | head -4), clean-build log
```
00000000: 534c 4630 3131 2332 3225 4944 4543 6f6d  SLF011#22%IDECom
00000010: 6d61 6e64 4c69 6e65 4275 696c 644c 6f67  mandLineBuildLog
00000020: 3140 3023 3339 2258 636f 6465 2e49 4445  1@0#39"Xcode.IDE
00000030: 4163 7469 7669 7479 4c6f 6744 6f6d 6169  ActivityLogDomai
```
Decoded: magic `SLF0`, then token stream. Tokens are `<hexOrDecimal><typeChar>`: `#` int (decimal), `"` string (len bytes follow), `%` class-name definition (len bytes follow), `@` class-instance reference (index into class table; defines order of first appearance), `(` array (count), `^` double (16 hex chars = little-endian IEEE754 bits), `-` null (no number prefix), `*` **JSON string** (len bytes follow; used by TaskMetrics attachments). Version int is the first token (`11#` / `13#`), then `22%IDECommandLineBuildLog` then `1@` (instance of class 1).

### Class table + token stats (my tokenizer: <L>/tools/slftok.py, slfinv.py; 0 parse errors)
```
size 12497589 header b'SLF0' b'11#2' tokens 18735 errors 0
class table (index name instance_refs):
  1 IDECommandLineBuildLog 1
  2 IDEActivityLogCommandInvocationSection 761
  3 IDEActivityLogSection 2
  4 IDEDiagnosticActivityLogMessage 54
  5 IDEFoundation.IDEActivityLogSectionAttachment 466
  6 DVTDocumentLocation 198
  7 DVTTextDocumentLocation 2
token kinds {'int': 4219, 'cls': 7, 'inst': 1484, 'str': 5489, 'dbl': 1728, 'arr': 930, 'null': 4412, 'json': 466}
task-title first words (from title strings containing "(in target" or setup steps):
    386 SwiftCompile
    192 SwiftDriverJobDiscovery
    159 Compile
     88 WriteAuxiliaryFile
     85 Write
```

(Function-body timing text: 85 string tokens (one emittedOutput per frontend job), 23,983 (26) / 23,726 (27) CR-separated lines in total.)

(`strings | grep '^(IDE|DVT)...$'` as requested only yields ~9 hits because SLF strings are length-prefixed with no terminators; the class table above from the tokenizer is the reliable source.)

### Task/step-title inventory (first word of title strings; each task appears 2-3x: title, signature, sub-section)
```
task-title first words (from title strings containing "(in target" or setup steps):
    386 SwiftCompile
    192 SwiftDriverJobDiscovery
    159 Compile
     88 WriteAuxiliaryFile
     85 Write
     48 Copy
     27 SwiftDriver
     19 Create
     18 SwiftEmitModule
     12 Ld
     10 CreateBuildDirectory
     10 RegisterExecutionPolicyException
      9 Planning
      9 ExtractAppIntentsMetadata
      8 EmitSwiftModule
      6 MkDir
      4 Build
      4 CompileAssetCatalogVariant
      4 CopySwiftLibs
      3 Building
      3 Compute
      3 CompileC
      2 Send
      2 ComputeTargetDependencyGraph
      2 CreateBuildDescription
      1 ComputePackagePrebuildTargetDependencyGraph
      1 Prepare
      1 CreateBuildRequest
      1 SendProjectDescription
      1 CreateBuildOperation
      1 GenerateAssetSymbols
      1 LinkAssetCatalog
      1 ConstructStubExecutorLinkFileList
      1 Validate
      1 Touch
      1 RegisterWithLaunchServices

```

### Timing / wall
clean rc=0 wall=26s
incr rc=0 wall=3s

### Build Timing Summary (verbatim from build26.log)
```
Build Timing Summary
SwiftCompile (87 tasks) | 109.343 seconds
SwiftEmitModule (9 tasks) | 4.015 seconds
CompileAssetCatalogVariant (1 task) | 3.445 seconds
SwiftDriver (9 tasks) | 2.320 seconds
ExtractAppIntentsMetadata (9 tasks) | 1.192 seconds
Ld (12 tasks) | 1.103 seconds
WriteAuxiliaryFile (84 tasks) | 0.278 seconds
ScanDependencies (1 task) | 0.274 seconds
RegisterExecutionPolicyException (10 tasks) | 0.213 seconds
Copy (44 tasks) | 0.088 seconds
RegisterWithLaunchServices (1 task) | 0.049 seconds
GenerateAssetSymbols (1 task) | 0.031 seconds
CompileC (1 task) | 0.030 seconds
CopySwiftLibs (1 task) | 0.027 seconds
ConstructStubExecutorLinkFileList (1 task) | 0.009 seconds
ProcessInfoPlistFile (1 task) | 0.007 seconds
SwiftMergeGeneratedHeaders (9 tasks) | 0.003 seconds
Touch (1 task) | 0.002 seconds
SwiftDriver Compilation (9 tasks) | 0.002 seconds
LinkAssetCatalog (1 task) | 0.002 seconds
SwiftDriver Compilation Requirements (9 tasks) | 0.002 seconds
Validate (1 task) | 0.000 seconds
note: Disabling hardened runtime with ad-hoc codesigning. (in target 'AcmeApp' from project 'AcmeApp' at path '/Users/<you>/Projects/acmeapp/AcmeApp.xcodeproj')
```

### Sample task-header lines (stdout, first <=3 per task kind)
```
CreateBuildDirectory <L>/dd26/Build/Products
CreateBuildDirectory <L>/dd26/Build/Intermediates.noindex
CreateBuildDirectory <L>/dd26/Build/Intermediates.noindex/SwiftExplicitPrecompiledModules
WriteAuxiliaryFile <L>/dd26/Build/Intermediates.noindex/AcmeApp.build/Debug/AcmeApp-cd74b7ba211e7a8f77a1e7546f3a3e88-VFS/al
WriteAuxiliaryFile <L>/dd26/Build/Intermediates.noindex/swift-syntax.build/Debug/SwiftSyntax601.build/SwiftSyntax601.Depend
WriteAuxiliaryFile <L>/dd26/Build/Intermediates.noindex/swift-syntax.build/Debug/SwiftSyntax600.build/SwiftSyntax600.Depend
Copy <L>/dd26/Build/Intermediates.noindex/GeneratedModuleMaps/SwiftSyntax601.modulemap /tmp/claude-501/-Users-you--claud
Copy <L>/dd26/Build/Intermediates.noindex/GeneratedModuleMaps/SwiftSyntax602.modulemap /tmp/claude-501/-Users-you--claud
Copy <L>/dd26/Build/Intermediates.noindex/GeneratedModuleMaps/SwiftSyntax600.modulemap /tmp/claude-501/-Users-you--claud
ScanDependencies <L>/dd26/Build/Intermediates.noindex/swift-syntax.build/Debug/_SwiftSyntaxCShims.build/Objects-normal/arm6
SwiftDriver SwiftSyntax602 normal arm64 com.apple.xcode.tools.swift.compiler (in target 'SwiftSyntax602' from project 'swift-syntax')
SwiftDriver SwiftSyntax601 normal arm64 com.apple.xcode.tools.swift.compiler (in target 'SwiftSyntax601' from project 'swift-syntax')
SwiftDriver SwiftSyntax600 normal arm64 com.apple.xcode.tools.swift.compiler (in target 'SwiftSyntax600' from project 'swift-syntax')
SwiftExplicitDependencyGeneratePcm arm64 <L>/dd26/ModuleCache.noindex/SwiftShims-16F5T8JICRIPYV1U945N1WZ8D.pcm
SwiftExplicitDependencyGeneratePcm arm64 <L>/dd26/ModuleCache.noindex/_SwiftConcurrencyShims-62ZT5SQ3336EHLZWLB384WEWI.pcm
SwiftEmitModule normal arm64 Emitting\ module\ for\ SwiftSyntax602 (in target 'SwiftSyntax602' from project 'swift-syntax')
SwiftCompile normal arm64 <L>/spm26/checkouts/swift-syntax/Sources/VersionMarkerModules/SwiftSyntax602/Empty.swift (in targ
SwiftCompile normal arm64 Compiling\ Empty.swift <L>/spm26/checkouts/swift-syntax/Sources/VersionMarkerModules/SwiftSyntax6
SwiftCompile normal arm64 <L>/spm26/checkouts/swift-syntax/Sources/VersionMarkerModules/SwiftSyntax602/Empty.swift (in targ
SwiftEmitModule normal arm64 Emitting\ module\ for\ SwiftSyntax600 (in target 'SwiftSyntax600' from project 'swift-syntax')
SwiftEmitModule normal arm64 Emitting\ module\ for\ SwiftSyntax509 (in target 'SwiftSyntax509' from project 'swift-syntax')
SwiftDriverJobDiscovery normal arm64 Emitting module for SwiftSyntax601 (in target 'SwiftSyntax601' from project 'swift-syntax')
```

### Function-body timings (-debug-time-function-bodies) and long-expression warnings
stdout lines: 23983; stdout 'expression took': 1
Top 3 slowest bodies (stdout):
```
425.05ms<TAB>/Users/<you>/Projects/acmeapp/Sources/AcmeApp/StudioView.swift:399:25<TAB>getter AcmeApp.(file).StringsView._@/Users/<you>/Projects/acmeapp/Sources/AcmeApp/StudioView.swift:399:25
250.49ms<TAB>/Users/<you>/Projects/acmeapp/Sources/AcmeApp/StudioView.swift:8:25<TAB>getter AcmeApp.(file).StudioView._@/Users/<you>/Projects/acmeapp/Sources/AcmeApp/StudioView.swift:8:25
188.16ms<TAB>/Users/<you>/Projects/acmeapp/Sources/AcmeApp/WorkflowViews.swift:7:25<TAB>getter AcmeApp.(file).TranslationsView._@/Users/<you>/Projects/acmeapp/Sources/AcmeApp/WorkflowViews.swift:7:25
```
Format sample (stdout; in SLF/xcresult the same text lives in the emittedOutput string of each SwiftCompile command-invocation section, lines separated by CR/LF; 85 sections carry them):
```
0.01ms<TAB>/Users/<you>/Projects/acmeapp/Sources/LocalizeCore/Discovery.swift:6:23<TAB>getter LocalizeCore.(file).Discovery._@/Users/<you>/Projects/acmeapp/Sources/LocalizeCore/Discovery.swift:6:23
0.01ms<TAB>/Users/<you>/Projects/acmeapp/Sources/LocalizeCore/ImportPlanner.swift:10:16<TAB>getter LocalizeCore.(file).ImportOptions._@/Users/<you>/Projects/acmeapp/Sources/LocalizeCore/ImportPlanner.swift:
0.01ms<TAB>/Users/<you>/Projects/acmeapp/Sources/LocalizeCore/ImportPlanner.swift:10:16<TAB>setter LocalizeCore.(file).ImportOptions._@/Users/<you>/Projects/acmeapp/Sources/LocalizeCore/ImportPlanner.swift:
0.01ms<TAB>/Users/<you>/Projects/acmeapp/Sources/LocalizeCore/ImportPlanner.swift:10:16<TAB>_modify accessor LocalizeCore.(file).ImportOptions._@/Users/<you>/Projects/acmeapp/Sources/LocalizeCore/ImportPlan
```
long-expression warning, stdout:
```
26506:/Users/<you>/Projects/acmeapp/Sources/AcmeApp/StudioView.swift:394:9: warning: expression took 62ms to type-check (limit: 50ms)
```

### LogStoreManifest.plist (dd26/Logs/Build, plutil -p; abbreviated to 1 build log)
```
  "logFormatVersion" => 11
  "logs" => {
      "schemeIdentifier-schemeName" => "AcmeApp"
      "schemeIdentifier-sharedScheme" => 1
      "signature" => "Building project AcmeApp with scheme AcmeApp and configuration Debug"
      "timeStartedRecording" => 815073642.753639
      "timeStoppedRecording" => 815073660.895242
      "title" => "Building project AcmeApp with scheme AcmeApp and configuration Debug"
      "uniqueIdentifier" => "20E8B73D-96FE-4232-8A33-311BFD02F961"
    }
    "D822889B-3D9A-478F-BB03-AB98C3967FD1" => {
      "className" => "IDECommandLineBuildLog"
      "documentTypeString" => "<nil>"
      "domainType" => "Xcode.IDEActivityLogDomainType.BuildLog"
      "fileName" => "D822889B-3D9A-478F-BB03-AB98C3967FD1.xcactivitylog"
      "hasPrimaryLog" => true
      "primaryObservable" => {
        "highLevelStatus" => "S"
        "totalNumberOfAnalyzerIssues" => 0
        "totalNumberOfErrors" => 0
        "totalNumberOfTestFailures" => 0
        "totalNumberOfWarnings" => 0
      }
      "schemeIdentifier-containerName" => "AcmeApp project"
      "schemeIdentifier-schemeName" => "AcmeApp"
      "schemeIdentifier-sharedScheme" => 1
      "signature" => "Building project AcmeApp with scheme AcmeApp and configuration Debug"
      "timeStartedRecording" => 815073663.111902
      "timeStoppedRecording" => 815073664.668171
      "title" => "Building project AcmeApp with scheme AcmeApp and configuration Debug"
      "uniqueIdentifier" => "D822889B-3D9A-478F-BB03-AB98C3967FD1"
    }
```
All 3 manifest entries per version: 'Cleaning project ...' (clean action, own log), 'Building project ...' (clean-build), second 'Building project ...' (incremental, only recorded if same DerivedData). Linking fields: uniqueIdentifier == fileName stem; schemeIdentifier-schemeName / -containerName ('AcmeApp project') / -sharedScheme; timeStartedRecording/timeStoppedRecording (Apple-epoch seconds, i.e. since 2001-01-01); primaryObservable.{highLevelStatus S|W|E, totalNumberOf{Errors,Warnings,AnalyzerIssues,TestFailures}}; signature/title; domainType; className=IDECommandLineBuildLog. Package resolve logs live in Logs/Package with their own manifest (title 'Resolve Packages', no scheme fields). Launch/Localization/Test manifests are empty.
## Xcode 27: Xcode 27.1 beta

### Files produced (dd27/Logs)
```
708 B gz  1447 B raw  dd27/Logs/Build/C272AB0A-5EFB-4584-BE0C-F4B16803F890.xcactivitylog
562385 B gz  13428173 B raw  dd27/Logs/Build/21F7B51C-4B90-49D4-B328-EDA168F7A9A5.xcactivitylog
12830 B gz  121063 B raw  dd27/Logs/Build/9DF7B31E-1F20-4F5F-B0EB-71E206ED3070.xcactivitylog
267 B gz  466 B raw  dd27/Logs/Package/CF1BC62B-7842-4899-9EF3-D096FD9F45DD.xcactivitylog
660 B gz  1762 B raw  dd27/Logs/Package/AA349786-0D0B-4299-8267-AD977CEA50CB.xcactivitylog
```

### SLF header (xxd | head -4), clean-build log
```
00000000: 534c 4630 3133 2332 3225 4944 4543 6f6d  SLF013#22%IDECom
00000010: 6d61 6e64 4c69 6e65 4275 696c 644c 6f67  mandLineBuildLog
00000020: 3140 3023 3339 2258 636f 6465 2e49 4445  1@0#39"Xcode.IDE
00000030: 4163 7469 7669 7479 4c6f 6744 6f6d 6169  ActivityLogDomai
```
Decoded: magic `SLF0`, then token stream. Tokens are `<hexOrDecimal><typeChar>`: `#` int (decimal), `"` string (len bytes follow), `%` class-name definition (len bytes follow), `@` class-instance reference (index into class table; defines order of first appearance), `(` array (count), `^` double (16 hex chars = little-endian IEEE754 bits), `-` null (no number prefix), `*` **JSON string** (len bytes follow; used by TaskMetrics attachments). Version int is the first token (`11#` / `13#`), then `22%IDECommandLineBuildLog` then `1@` (instance of class 1).

### Class table + token stats (my tokenizer: <L>/tools/slftok.py, slfinv.py; 0 parse errors)
```
size 13428173 header b'SLF0' b'13#2' tokens 20564 errors 0
class table (index name instance_refs):
  1 IDECommandLineBuildLog 1
  2 IDEActivityLogCommandInvocationSection 771
  3 IDEActivityLogSection 2
  4 IDEDiagnosticActivityLogMessage 57
  5 IDEFoundation.IDEActivityLogSectionAttachment 473
  6 DVTDocumentLocation 193
  7 DVTTextDocumentLocation 4
token kinds {'int': 5847, 'cls': 7, 'inst': 1501, 'str': 5562, 'dbl': 1745, 'arr': 944, 'null': 4485, 'json': 473}
task-title first words (from title strings containing "(in target" or setup steps):
    381 SwiftCompile
    192 SwiftDriverJobDiscovery
    168 Compile
     88 WriteAuxiliaryFile
     85 Write
```

(`strings | grep '^(IDE|DVT)...$'` as requested only yields ~9 hits because SLF strings are length-prefixed with no terminators; the class table above from the tokenizer is the reliable source.)

### Task/step-title inventory (first word of title strings; each task appears 2-3x: title, signature, sub-section)
```
task-title first words (from title strings containing "(in target" or setup steps):
    381 SwiftCompile
    192 SwiftDriverJobDiscovery
    168 Compile
     88 WriteAuxiliaryFile
     85 Write
     48 Copy
     27 SwiftDriver
     23 Create
     18 SwiftEmitModule
     16 CreateBuildDirectory
     12 Ld
      9 Planning
      9 ExtractAppIntentsMetadata
      6 MkDir
      4 Build
      4 CompileAssetCatalogVariant
      4 CopySwiftLibs
      3 Building
      3 Compute
      3 CompileC
      2 Send
      2 ComputeTargetDependencyGraph
      2 CreateBuildDescription
      1 ComputePackagePrebuildTargetDependencyGraph
      1 Prepare
      1 CreateBuildRequest
      1 SendProjectDescription
      1 CreateBuildOperation
      1 GenerateAssetSymbols
      1 LinkAssetCatalog
      1 ConstructStubExecutorLinkFileList
      1 RegisterExecutionPolicyException
      1 Validate
      1 Touch
      1 RegisterWithLaunchServices

```

### Timing / wall
clean rc=0 wall=45s
incr rc=0 wall=4s

### Build Timing Summary (verbatim from build27.log)
```
Build Timing Summary
SwiftCompile (87 tasks) | 116.663 seconds
SwiftEmitModule (9 tasks) | 5.318 seconds
SwiftDriver (9 tasks) | 3.770 seconds
CompileAssetCatalogVariant (1 task) | 3.407 seconds
Ld (12 tasks) | 1.232 seconds
ExtractAppIntentsMetadata (9 tasks) | 0.820 seconds
WriteAuxiliaryFile (84 tasks) | 0.385 seconds
ScanDependencies (1 task) | 0.327 seconds
Copy (44 tasks) | 0.176 seconds
RegisterWithLaunchServices (1 task) | 0.049 seconds
CompileC (1 task) | 0.038 seconds
CopySwiftLibs (1 task) | 0.031 seconds
GenerateAssetSymbols (1 task) | 0.025 seconds
SwiftMergeGeneratedHeaders (9 tasks) | 0.016 seconds
RegisterExecutionPolicyException (1 task) | 0.013 seconds
ConstructStubExecutorLinkFileList (1 task) | 0.008 seconds
ProcessInfoPlistFile (1 task) | 0.007 seconds
Touch (1 task) | 0.002 seconds
SwiftDriver Compilation (9 tasks) | 0.002 seconds
SwiftDriver Compilation Requirements (9 tasks) | 0.002 seconds
LinkAssetCatalog (1 task) | 0.001 seconds
Validate (1 task) | 0.000 seconds
note: Disabling hardened runtime with ad-hoc codesigning. (in target 'AcmeApp' from project 'AcmeApp' at path '/Users/<you>/Projects/acmeapp/AcmeApp.xcodeproj')
```

### Sample task-header lines (stdout, first <=3 per task kind)
```
CreateBuildDirectory <L>/dd27/SDKExplicitPrecompiledModules
CreateBuildDirectory <L>/dd27/ModuleCache.noindex
CreateBuildDirectory <L>/dd27/CompilationCache.noindex
WriteAuxiliaryFile <L>/dd27/Build/Intermediates.noindex/AcmeApp.build/Debug/AcmeApp-cd74b7ba211e7a8f77a1e7546f3a3e88-VFS/al
WriteAuxiliaryFile <L>/dd27/Build/Intermediates.noindex/swift-syntax.build/Debug/SwiftSyntax602-t.build/SwiftSyntax602.modu
WriteAuxiliaryFile <L>/dd27/Build/Intermediates.noindex/swift-syntax.build/Debug/SwiftSyntax601-t.build/SwiftSyntax601.modu
Copy <L>/dd27/Build/Intermediates.noindex/GeneratedModuleMaps/SwiftSyntax601.modulemap /tmp/claude-501/-Users-you--claud
Copy <L>/dd27/Build/Intermediates.noindex/GeneratedModuleMaps/SwiftSyntax602.modulemap /tmp/claude-501/-Users-you--claud
Copy <L>/dd27/Build/Intermediates.noindex/GeneratedModuleMaps/SwiftSyntax600.modulemap /tmp/claude-501/-Users-you--claud
ScanDependencies <L>/dd27/Build/Intermediates.noindex/swift-syntax.build/Debug/_SwiftSyntaxCShims-t.build/Objects-normal/ar
SwiftDriver SwiftSyntax602 normal arm64 com.apple.xcode.tools.swift.compiler (in target 'SwiftSyntax602' from project 'swift-syntax')
SwiftDriver SwiftSyntax600 normal arm64 com.apple.xcode.tools.swift.compiler (in target 'SwiftSyntax600' from project 'swift-syntax')
SwiftDriver SwiftSyntax509 normal arm64 com.apple.xcode.tools.swift.compiler (in target 'SwiftSyntax509' from project 'swift-syntax')
PrecompileModule <L>/dd27/Build/Intermediates.noindex/ExplicitPrecompiledModules/ptrcheck-3CDURAZPR42H2XNX4H48ISBNT.scan
PrecompileModule <L>/dd27/Build/Intermediates.noindex/ExplicitPrecompiledModules/_AvailabilityInternal-B19ULBLXJT3KLVCCQ4EJ
PrecompileModule <L>/dd27/Build/Intermediates.noindex/ExplicitPrecompiledModules/_Builtin_stdbool-32TEXO7QVOFWFLAEL13QVTBT7
SwiftExplicitDependencyGeneratePcm arm64 <L>/dd27/SDKExplicitPrecompiledModules/SwiftShims-DQWOESZ3NITESHUV8LO6HTQZY.pcm
SwiftExplicitDependencyGeneratePcm arm64 <L>/dd27/SDKExplicitPrecompiledModules/_SwiftConcurrencyShims-5MQRJXO4BFDM5QV2XBW2
SwiftEmitModule normal arm64 Emitting\ module\ for\ SwiftSyntax602 (in target 'SwiftSyntax602' from project 'swift-syntax')
SwiftCompile normal arm64 (in target 'SwiftSyntax602' from project 'swift-syntax')
SwiftEmitModule normal arm64 Emitting\ module\ for\ SwiftSyntax510 (in target 'SwiftSyntax510' from project 'swift-syntax')
SwiftCompile normal arm64 (in target 'SwiftSyntax510' from project 'swift-syntax')
```

### Function-body timings (-debug-time-function-bodies) and long-expression warnings
stdout lines: 23726; stdout 'expression took': 0
Top 3 slowest bodies (stdout):
```
206.48ms<TAB>/Users/<you>/Projects/acmeapp/Sources/AcmeApp/StudioView.swift:8:25<TAB>getter AcmeApp.(file).StudioView.body.getter@/Users/<you>/Projects/acmeapp/Sources/AcmeApp/StudioView.swift:8:25
191.44ms<TAB>/Users/<you>/Projects/acmeapp/Sources/AcmeApp/StudioView.swift:399:25<TAB>getter AcmeApp.(file).StringsView.body.getter@/Users/<you>/Projects/acmeapp/Sources/AcmeApp/StudioView.swift:399:25
134.74ms<TAB>/Users/<you>/Projects/acmeapp/Sources/AcmeApp/WorkflowViews.swift:7:25<TAB>getter AcmeApp.(file).TranslationsView.body.getter@/Users/<you>/Projects/acmeapp/Sources/AcmeApp/WorkflowViews.swift:7:25
```
Format sample (stdout; in SLF/xcresult the same text lives in the emittedOutput string of each SwiftCompile command-invocation section, lines separated by CR/LF; 85 sections carry them):
```
0.01ms<TAB>/Users/<you>/Projects/acmeapp/Sources/LocalizeCore/Discovery.swift:6:23<TAB>getter LocalizeCore.(file).Discovery.defaultExclusions.getter@/Users/<you>/Projects/acmeapp/Sources/LocalizeCore/Discov
0.01ms<TAB>/Users/<you>/Projects/acmeapp/Sources/LocalizeCore/ImportPlanner.swift:10:16<TAB>getter LocalizeCore.(file).ImportOptions.sourceLocale.getter@/Users/<you>/Projects/acmeapp/Sources/LocalizeCore/Im
0.01ms<TAB>/Users/<you>/Projects/acmeapp/Sources/LocalizeCore/ImportPlanner.swift:10:16<TAB>setter LocalizeCore.(file).ImportOptions.sourceLocale.setter@/Users/<you>/Projects/acmeapp/Sources/LocalizeCore/Im
0.01ms<TAB>/Users/<you>/Projects/acmeapp/Sources/LocalizeCore/ImportPlanner.swift:10:16<TAB>_modify accessor LocalizeCore.(file).ImportOptions.sourceLocale._modify accessor@/Users/<you>/Projects/acmeapp/Sou
```

### LogStoreManifest.plist (dd27/Logs/Build, plutil -p; abbreviated to 1 build log)
```
  "logFormatVersion" => 13
  "logs" => {
      "schemeIdentifier-schemeName" => "AcmeApp"
      "schemeIdentifier-sharedScheme" => 1
      "signature" => "Building project AcmeApp with scheme AcmeApp and configuration Debug"
      "timeStartedRecording" => 815073721.64457
      "timeStoppedRecording" => 815073723.328132
      "title" => "Building project AcmeApp with scheme AcmeApp and configuration Debug"
      "uniqueIdentifier" => "9DF7B31E-1F20-4F5F-B0EB-71E206ED3070"
    }
    "21F7B51C-4B90-49D4-B328-EDA168F7A9A5" => {
      "className" => "IDECommandLineBuildLog"
      "documentTypeString" => "<nil>"
      "domainType" => "Xcode.IDEActivityLogDomainType.BuildLog"
      "fileName" => "21F7B51C-4B90-49D4-B328-EDA168F7A9A5.xcactivitylog"
      "hasPrimaryLog" => true
      "primaryObservable" => {
        "highLevelStatus" => "W"
        "totalNumberOfAnalyzerIssues" => 0
        "totalNumberOfErrors" => 0
        "totalNumberOfTestFailures" => 0
        "totalNumberOfWarnings" => 1
      }
      "schemeIdentifier-containerName" => "AcmeApp project"
      "schemeIdentifier-schemeName" => "AcmeApp"
      "schemeIdentifier-sharedScheme" => 1
      "signature" => "Building project AcmeApp with scheme AcmeApp and configuration Debug"
      "timeStartedRecording" => 815073690.982541
      "timeStoppedRecording" => 815073719.473833
      "title" => "Building project AcmeApp with scheme AcmeApp and configuration Debug"
      "uniqueIdentifier" => "21F7B51C-4B90-49D4-B328-EDA168F7A9A5"
    }
```
All 3 manifest entries per version: 'Cleaning project ...' (clean action, own log), 'Building project ...' (clean-build), second 'Building project ...' (incremental, only recorded if same DerivedData). Linking fields: uniqueIdentifier == fileName stem; schemeIdentifier-schemeName / -containerName ('AcmeApp project') / -sharedScheme; timeStartedRecording/timeStoppedRecording (Apple-epoch seconds, i.e. since 2001-01-01); primaryObservable.{highLevelStatus S|W|E, totalNumberOf{Errors,Warnings,AnalyzerIssues,TestFailures}}; signature/title; domainType; className=IDECommandLineBuildLog. Package resolve logs live in Logs/Package with their own manifest (title 'Resolve Packages', no scheme fields). Launch/Localization/Test manifests are empty.

## xcresult (both versions) and per-task timings
`xcrun xcresulttool get build-results --path r26.xcresult` returns only a summary: actionTitle, destination (arch/os/device), start/end time, status, error/warning counts + a `warnings[]` array (className DVTTextDocumentLocation, issueType, message, sourceURL with `#StartingLineNumber=..&Timestamp=..` fragment). No per-task timings. Xcode 26 sample (verbatim, trimmed):
```
{ "actionTitle":"Build \"AcmeApp\"", "destination":{"architecture":"arm64","deviceName":"My Mac","modelName":"Mac Studio","osVersion":"27.0","platform":"macOS"},
  "startTime":1793380842.103, "endTime":1793380860.897, "status":"succeeded", "errorCount":0, "warningCount":1,
  "warnings":[{"className":"DVTTextDocumentLocation","issueType":"Swift Compiler Warning","message":"Expression took 62ms to type-check (limit: 50ms)","sourceURL":"file:///.../StudioView.swift#EndingColumnNumber=8&EndingLineNumber=393&StartingColumnNumber=8&StartingLineNumber=393&Timestamp=815073642.754679"}] }
```
Xcode 27 equivalent: warning issueType `ImplicitStrongCapture`, message "'weak' ownership of capture 'self' differs from implicitly-captured strong reference in outer scope" (StudioModel.swift:111-112) (note: new in 27, [#ImplicitStrongCapture] diagnostic group tag appears in stdout).
`xcresulttool get object --legacy --format json` (deprecated): ActionsInvocationRecord -> actions[ActionRecord] -> buildResult with `logRef` (Reference id -> targetType ActivityLogSection), metrics (empty ResultMetrics for build), issues, runDestination, hardware record. Per-task data only reachable via the logRef: `get object --legacy --id <logRef>` returns just the top ActivityLogSection (5 KB; subsections one level).
**Best find: `xcrun xcresulttool get log --path r26.xcresult --type build` (Xcode 16+) dumps the entire build log as structured JSON (12.4 MB for 26, 13.4 MB for 27)** = the xcactivitylog tree already decoded. Saved at `<L>/r26-xcresult-buildlog.json`, `<L>/r27-xcresult-buildlog.json`. Schema (`--schema` available): section {title, domainType, duration (s, double), startTime (Unix epoch s), result, attachments[], messages[], subsections[], commandInvocationDetails{commandDetails(signature), emittedOutput, exitCode}, location}. So per-task timings DO exist in the xcresult (via `get log`), including emittedOutput (function-body timings, compiler diagnostics). Stats:
- 26: 770 sections; depth hist {0:1, 1:2, 2:583, 3:184}; domainTypes: BuildLogSection 742, timing.aggregate 22, BuildLogTimingSummarySection 2, LogSection 1, BuildLog 3; function-body lines in emittedOutput: 23,983 across 85 tasks.
- 27: 780 sections; same shape; 23,726 lines across 85 tasks.
- Note: the single r26.xcresult covers clean+build invocation (top log duration 18.79 s = 'Cleaning' 0.65 s + 'Building' ~18.1 s); incremental has its own r26-incr.xcresult.
Top task kinds by summed duration (xcresult JSON; SwiftCompile double counts: batch "Compiling a.swift, b.swift" parent + per-file children + the file-level 'SwiftCompile normal arm64 <file>'):
- 26: SwiftCompile n=240 264.2s; SwiftExplicitDependencyGeneratePcm n=143 12.5s; SwiftEmitModule 4.0s; EmitSwiftModule 3.5s; CompileAssetCatalogVariant 3.45s; SwiftDriver 2.35s; ClangStatCache 1.8s; Ld n=13 1.1s; PrecompileModule n=12 0.7s
- 27: SwiftCompile n=244 116.8s; SwiftExplicitDependencyGeneratePcm n=149 14.1s; **SwiftExplicitDependencyCompileModuleFromInterface n=5 7.1s (new in 27)**; SwiftEmitModule 5.3s; SwiftDriver 3.8s; ClangStatCache 3.6s; PrecompileModule n=13 2.0s; Ld 1.2s
(26's SwiftCompile sum is 2.3x larger than 27's in the same JSON because 26 nests extra per-file child sections; Build Timing Summary text says 109.3s vs 116.7s for 87 tasks, so use that aggregate, not a naive sum.)

## Format observations useful for the parser
1. Every IDEActivityLogCommandInvocationSection (class idx 2) record, leaf example, Xcode 26 (20 tokens) vs 27 (22 tokens) -- **v13 adds two Int fields** (one after the three Ints following the 3 nulls, one trailing after the empty subsection array):
```
26: inst:2 int:2 str:'com.apple.dt.IDE.BuildLogSection' str:title str:signature dbl:timeStarted dbl:timeStopped null null null int:0 int:0 int:0 null null str:commandDetails str:UUID null null arr:0
27: inst:2 int:2 str:'com.apple.dt.IDE.BuildLogSection' str:title str:signature dbl:timeStarted dbl:timeStopped null null null int:0 int:0 int:0 int:0 null null str:commandDetails str:UUID null null arr:0 int:0
```
(Both versions share class table order: 1 IDECommandLineBuildLog, 2 IDEActivityLogCommandInvocationSection, 3 IDEActivityLogSection, 4 IDEDiagnosticActivityLogMessage, 5 IDEFoundation.IDEActivityLogSectionAttachment, 6 DVTDocumentLocation, 7 DVTTextDocumentLocation. No new classes between 11 and 13 in this log. Note class 5 is namespaced `IDEFoundation.IDEActivityLogSectionAttachment`, a Swift class.)
2. Attachments: each compile-like section carries `IDEFoundation.IDEActivityLogSectionAttachment` with identifier `com.apple.dt.ActivityLogSectionAttachment.TaskMetrics` and a `*` JSON token: `{"wcStartTime":815073653931597,"utime":930677,"stime":1930138,"maxRSS":336084992,"wcDuration":2985189}` (wcStartTime/wcDuration in microseconds, Apple epoch; utime/stime microseconds CPU; maxRSS bytes). 466 (26) / 473 (27) such attachments. These give real per-task CPU/RSS, absent from stdout.
3. Another attachment string per task is a hex-encoded blob (`0050303A7461726765742D4C6F63616C697A65436F72652D5041434B4147452D...` = ASCII "P0:target-LocalizeCore-PACKAGE-TARGET:..." task identifier / XCBuild task id).
4. Section hierarchy (xcresult JSON depth): root BuildLog -> 'Cleaning/Building' children -> per-task command sections (e.g. SwiftCompile batch 'Compiling A.swift, B.swift...') -> per-file children ('Compile A.swift (arm64)', signature `SwiftCompile normal arm64 /abs/A.swift (in target 'X' from project 'Y')`). Parent batch signature: `SwiftCompile normal arm64 Compiling\ A.swift /abs/A.swift ... (in target ...)` (spaces backslash-escaped). Xcode 27 also emits parent `SwiftCompile normal arm64 (in target 'X' from project 'Y')` with no file list (new title shape).
5. Function-body timing text lives in the emittedOutput of the per-file leaf SwiftCompile section. In SLF: 85 string tokens (one per frontend job emittedOutput), lines CR-separated; in stdout they are interleaved after the task's command echo. Decl text embeds `@/path:line:col` suffix. Parent paths for SwiftPM checkouts are under the clonedSourcePackagesDirPath (spm$V/checkouts/swift-syntax/...), so >99% of the 23.9k lines belong to swift-syntax, not user code; user-code lines are filtered easily by path.
6. Other 27 differences visible in stdout/titles: `SDKExplicitPrecompiledModules` dir at DerivedData root (26 used Build/Intermediates.noindex/SwiftExplicitPrecompiledModules + ModuleCache.noindex); `PrecompileModule` tasks now `.../Intermediates.noindex/ExplicitPrecompiledModules/<name>-<hash>.scan`; SwiftPM dep target dirs `SwiftSyntax602-t.build` (vs `SwiftSyntax602.build`); `CompilationCache.noindex` CreateBuildDirectory step; `[#ImplicitStrongCapture]` group tag in diagnostics; `RegisterExecutionPolicyException` 1 task (vs 10).
7. Warning/error location: DVTTextDocumentLocation (class 7) only 2 (26) / 4 (27) instances for diagnostics; DVTDocumentLocation (class 6) 198/193 on per-file sections (file:// URL + 0.0 timestamp + signature).

## CompilationCache.noindex
- `~/Library/Developer/Xcode/DerivedData/CompilationCache.noindex` = **28 KB** (generic/{lock,v1.1/v3.actions,v8.index,v8.data,...}); created Oct 28 01:38, not grown by these runs (scratch DerivedData got its own 28 KB `dd26|dd27/CompilationCache.noindex`).
- It is only the CAS stub: `xcodebuild -showBuildSettings` (both Xcodes) gives `COMPILATION_CACHE_CAS_PATH = ~/Library/Developer/Xcode/DerivedData/CompilationCache.noindex` and `COMPILATION_CACHE_KEEP_CAS_DIRECTORY = YES` (project defaults) plus `SWIFT_ENABLE_EXPLICIT_MODULES = YES`. No `COMPILATION_CACHE_*`/`-cache-compile-job` string appears in any build log (stdout 0 hits, SLF 0 hits) and `SWIFT_ENABLE_COMPILE_CACHE` is not set => compilation caching is NOT enabled for this project; nothing from caching in logs. (Other projects with Xcode's "Enable Compilation Caching" would populate it.)

## Caveats / notes
- AcmeApp is macOS-only; task suggested iOS sim, so macOS destination used. 'My Mac' arm64+x86_64 ambiguity warning printed; xcodebuild picked arm64.
- swift-syntax is built from source in every clean build (dominates time: 87 SwiftCompile tasks, ~109-117 s CPU-summed in 26-27 s wall).
- Incremental builds only recompiled the package target LocalizeCore (swift-driver + emit-module + 1 SwiftCompile); app target not recompiled (no interface change). No `timeout` binary on macOS; used `perl alarm 600` guard; neither build came close.
- Full raw artifacts: dd26/, dd27/, slf26/, slf27/ (xcactivitylog + gunzipped .slf), build26.log, build26-incr.log, build27.log, build27-incr.log, r26/r27(-incr).xcresult, inv26.txt, inv27.txt, headers.txt, leaf-compare.txt, tools/ (slftok.py = working SLF tokenizer) under <L>.
