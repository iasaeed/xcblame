#!/bin/sh
# Generates fixtures/projects/AcmeWhy (docs/SCHEMA-v0.5.md "Planted-cause fixture"): a macOS app, two frameworks and a
# local package, with the planted causes of `xcblame why`. Idempotent, no network, no signing; the generated tree is
# committed so tests need no run of this script.
#
#   Scripts/make-why-fixture.sh          (re)write the fixture
#   Scripts/make-why-fixture.sh --flip   toggle WHY_FLAG in Config/Why.xcconfig (planted cause 3, settingsChanged)
#
# Planted causes: 1. Run Script "Stamp" in AcmeWhyApp has an input and no outputs (every build, PHASE-001);
# 2. `--touch WhyCore/Core.swift` (inputChanged, dependents join it); 3. the WHY_FLAG flip read by WhyCore's
# OTHER_SWIFT_FLAGS (settingsChanged); 4. two macro plugins: static only, Packages/WhyMacros is never built (it needs
# swift-syntax from the network) and is not referenced by the project.
set -eu
cd "$(dirname "$0")/.."
root=fixtures/projects/AcmeWhy

if [ "${1:-}" = "--flip" ]; then
    config="$root/Config/Why.xcconfig"
    if grep -q '^WHY_FLAG = WHY_A$' "$config"; then
        sed -i '' 's/^WHY_FLAG = WHY_A$/WHY_FLAG = WHY_B/' "$config"
    else
        sed -i '' 's/^WHY_FLAG = WHY_B$/WHY_FLAG = WHY_A/' "$config"
    fi
    grep '^WHY_FLAG' "$config"
    exit 0
fi

mkdir -p "$root/AcmeWhy.xcodeproj/xcshareddata/xcschemes" "$root/AcmeWhyApp" "$root/WhyKit" "$root/WhyCore" "$root/Config" \
    "$root/Packages/WhyUtils/Sources/WhyUtils" "$root/Packages/WhyMacros/Sources/WhyMacros" \
    "$root/Packages/WhyMacros/Sources/WhyMacrosA" "$root/Packages/WhyMacros/Sources/WhyMacrosB"

cat > "$root/Config/Why.xcconfig" <<'EOF'
// Planted cause 3 (settingsChanged): `Scripts/make-why-fixture.sh --flip` toggles this value; WhyCore reads it through
// OTHER_SWIFT_FLAGS = $(inherited) -D$(WHY_FLAG).
WHY_FLAG = WHY_A
EOF

cat > "$root/WhyCore/Core.swift" <<'EOF'
public enum Core {
    public static func value() -> Int {
        #if WHY_A
        return 1
        #else
        return 2
        #endif
    }
}
EOF

cat > "$root/WhyKit/Kit.swift" <<'EOF'
import WhyCore
import WhyUtils

public enum Kit {
    public static func describe() -> String { Utils.label(Core.value()) }
}
EOF

cat > "$root/AcmeWhyApp/main.swift" <<'EOF'
import WhyKit

print(Kit.describe())
EOF

cat > "$root/Packages/WhyUtils/Package.swift" <<'EOF'
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WhyUtils",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WhyUtils", targets: ["WhyUtils"])],
    targets: [.target(name: "WhyUtils")]
)
EOF

cat > "$root/Packages/WhyUtils/Sources/WhyUtils/Utils.swift" <<'EOF'
public enum Utils {
    public static func label(_ value: Int) -> String { "value \(value)" }
}
EOF

# Planted cause 4 (static): two macro plugins for one module. Never built: a `.macro` target needs swift-syntax.
cat > "$root/Packages/WhyMacros/Package.swift" <<'EOF'
// swift-tools-version: 5.9
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "WhyMacros",
    platforms: [.macOS(.v14)],
    products: [.library(name: "WhyMacros", targets: ["WhyMacros"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-syntax", from: "600.0.0")],
    targets: [
        .macro(name: "WhyMacrosA", dependencies: [.product(name: "SwiftCompilerPlugin", package: "swift-syntax")]),
        .macro(name: "WhyMacrosB", dependencies: [.product(name: "SwiftCompilerPlugin", package: "swift-syntax")]),
        .target(name: "WhyMacros", dependencies: ["WhyMacrosA", "WhyMacrosB"]),
    ]
)
EOF
echo '@freestanding(expression) public macro stampA() -> Int = #externalMacro(module: "WhyMacrosA", type: "StampA")' \
    > "$root/Packages/WhyMacros/Sources/WhyMacros/WhyMacros.swift"
echo '// Plugin A (never built).' > "$root/Packages/WhyMacros/Sources/WhyMacrosA/PluginA.swift"
echo '// Plugin B (never built).' > "$root/Packages/WhyMacros/Sources/WhyMacrosB/PluginB.swift"

# `primaryCause.subject` matches as a suffix (paths are absolute in the report); `minShare` is the share of the task time
# of the scenario's `tasks` (target, optional rule) held by the primary cause; `backtraces` says whether the scenario
# records Task Backtraces (EnableBuildBacktraceRecording=YES, MV-2). Without backtraces a flip is visible only on keyed
# tasks the previous build also executed, so it is measured with them (the per-file compiles have per-build keys).
cat > "$root/expected.json" <<'EOF'
[
  {"scenario": "zeroChange", "backtraces": false, "tasks": {"target": "AcmeWhyApp", "rule": "PhaseScriptExecution"},
   "primaryCause": {"class": "scriptPhase", "source": "script", "subject": "AcmeWhyApp/Stamp", "ruleId": "PHASE-001"}, "minShare": 0.9},
  {"scenario": "touch", "touch": "WhyCore/Core.swift", "backtraces": true, "tasks": {"target": "WhyCore"},
   "primaryCause": {"class": "inputChanged", "source": "backtrace", "subject": "WhyCore/Core.swift", "ruleId": null}, "minShare": 0.9},
  {"scenario": "flip", "backtraces": true, "tasks": {"target": "WhyCore"},
   "primaryCause": {"class": "settingsChanged", "source": "backtrace", "subject": "WhyCore", "ruleId": null}, "minShare": 0.9},
  {"scenario": "macroPlugins", "static": true, "module": "WhyKit", "plugins": 2, "package": "Packages/WhyMacros"}
]
EOF

cat > "$root/AcmeWhy.xcodeproj/xcshareddata/xcschemes/AcmeWhyApp.xcscheme" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "A70000000000000000000030"
               BuildableName = "AcmeWhyApp.app"
               BlueprintName = "AcmeWhyApp"
               ReferencedContainer = "container:AcmeWhy.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <LaunchAction
      buildConfiguration = "Debug"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "A70000000000000000000030"
            BuildableName = "AcmeWhyApp.app"
            BlueprintName = "AcmeWhyApp"
            ReferencedContainer = "container:AcmeWhy.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
</Scheme>
EOF

cat > "$root/AcmeWhy.xcodeproj/project.pbxproj" <<'EOF'
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {

/* Begin PBXBuildFile section */
		A70000000000000000000060 /* WhyKit.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = A70000000000000000000011 /* WhyKit.framework */; };
		A70000000000000000000061 /* WhyCore.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = A70000000000000000000012 /* WhyCore.framework */; };
		A70000000000000000000063 /* WhyUtils in Frameworks */ = {isa = PBXBuildFile; productRef = A70000000000000000000082 /* WhyUtils */; };
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
		A70000000000000000000071 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = A70000000000000000000001 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = A70000000000000000000031;
			remoteInfo = WhyKit;
		};
		A70000000000000000000073 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = A70000000000000000000001 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = A70000000000000000000032;
			remoteInfo = WhyCore;
		};
/* End PBXContainerItemProxy section */

/* Begin PBXFileReference section */
		A70000000000000000000010 /* AcmeWhyApp.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = AcmeWhyApp.app; sourceTree = BUILT_PRODUCTS_DIR; };
		A70000000000000000000011 /* WhyKit.framework */ = {isa = PBXFileReference; explicitFileType = wrapper.framework; includeInIndex = 0; path = WhyKit.framework; sourceTree = BUILT_PRODUCTS_DIR; };
		A70000000000000000000012 /* WhyCore.framework */ = {isa = PBXFileReference; explicitFileType = wrapper.framework; includeInIndex = 0; path = WhyCore.framework; sourceTree = BUILT_PRODUCTS_DIR; };
		A70000000000000000000014 /* Why.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Why.xcconfig; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		A70000000000000000000020 /* AcmeWhyApp */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = AcmeWhyApp;
			sourceTree = "<group>";
		};
		A70000000000000000000021 /* WhyKit */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = WhyKit;
			sourceTree = "<group>";
		};
		A70000000000000000000022 /* WhyCore */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = WhyCore;
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		A70000000000000000000041 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				A70000000000000000000060 /* WhyKit.framework in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		A70000000000000000000051 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				A70000000000000000000061 /* WhyCore.framework in Frameworks */,
				A70000000000000000000063 /* WhyUtils in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		A70000000000000000000056 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		A70000000000000000000002 = {
			isa = PBXGroup;
			children = (
				A70000000000000000000020 /* AcmeWhyApp */,
				A70000000000000000000021 /* WhyKit */,
				A70000000000000000000022 /* WhyCore */,
				A70000000000000000000004 /* Config */,
				A70000000000000000000003 /* Products */,
			);
			sourceTree = "<group>";
		};
		A70000000000000000000003 /* Products */ = {
			isa = PBXGroup;
			children = (
				A70000000000000000000010 /* AcmeWhyApp.app */,
				A70000000000000000000011 /* WhyKit.framework */,
				A70000000000000000000012 /* WhyCore.framework */,
			);
			name = Products;
			sourceTree = "<group>";
		};
		A70000000000000000000004 /* Config */ = {
			isa = PBXGroup;
			children = (
				A70000000000000000000014 /* Why.xcconfig */,
			);
			path = Config;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		A70000000000000000000030 /* AcmeWhyApp */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = A700000000000000000000A5 /* Build configuration list for PBXNativeTarget "AcmeWhyApp" */;
			buildPhases = (
				A70000000000000000000040 /* Sources */,
				A70000000000000000000041 /* Frameworks */,
				A70000000000000000000043 /* Stamp */,
			);
			buildRules = (
			);
			dependencies = (
				A70000000000000000000070 /* PBXTargetDependency */,
			);
			fileSystemSynchronizedGroups = (
				A70000000000000000000020 /* AcmeWhyApp */,
			);
			name = AcmeWhyApp;
			productName = AcmeWhyApp;
			productReference = A70000000000000000000010 /* AcmeWhyApp.app */;
			productType = "com.apple.product-type.application";
		};
		A70000000000000000000031 /* WhyKit */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = A700000000000000000000A8 /* Build configuration list for PBXNativeTarget "WhyKit" */;
			buildPhases = (
				A70000000000000000000050 /* Sources */,
				A70000000000000000000051 /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
				A70000000000000000000072 /* PBXTargetDependency */,
			);
			fileSystemSynchronizedGroups = (
				A70000000000000000000021 /* WhyKit */,
			);
			name = WhyKit;
			packageProductDependencies = (
				A70000000000000000000082 /* WhyUtils */,
			);
			productName = WhyKit;
			productReference = A70000000000000000000011 /* WhyKit.framework */;
			productType = "com.apple.product-type.framework";
		};
		A70000000000000000000032 /* WhyCore */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = A700000000000000000000AB /* Build configuration list for PBXNativeTarget "WhyCore" */;
			buildPhases = (
				A70000000000000000000055 /* Sources */,
				A70000000000000000000056 /* Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				A70000000000000000000022 /* WhyCore */,
			);
			name = WhyCore;
			productName = WhyCore;
			productReference = A70000000000000000000012 /* WhyCore.framework */;
			productType = "com.apple.product-type.framework";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		A70000000000000000000001 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2600;
				LastUpgradeCheck = 2600;
				TargetAttributes = {
					A70000000000000000000030 = {
						CreatedOnToolsVersion = 26.0;
					};
					A70000000000000000000031 = {
						CreatedOnToolsVersion = 26.0;
					};
					A70000000000000000000032 = {
						CreatedOnToolsVersion = 26.0;
					};
				};
			};
			buildConfigurationList = A700000000000000000000A2 /* Build configuration list for PBXProject "AcmeWhy" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = A70000000000000000000002;
			minimizedProjectReferenceProxies = 1;
			packageReferences = (
				A70000000000000000000092 /* XCLocalSwiftPackageReference "Packages/WhyUtils" */,
			);
			preferredProjectObjectVersion = 77;
			productRefGroup = A70000000000000000000003 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				A70000000000000000000030 /* AcmeWhyApp */,
				A70000000000000000000031 /* WhyKit */,
				A70000000000000000000032 /* WhyCore */,
			);
		};
/* End PBXProject section */

/* Begin PBXShellScriptBuildPhase section */
		A70000000000000000000043 /* Stamp */ = {
			isa = PBXShellScriptBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			inputFileListPaths = (
			);
			inputPaths = (
				"$(SRCROOT)/AcmeWhyApp/main.swift",
			);
			name = Stamp;
			outputFileListPaths = (
			);
			outputPaths = (
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = "# Planted cause 1: an input and no outputs, so it runs on every build (PHASE-001).\necho \"stamp $(date +%s)\"\n";
		};
/* End PBXShellScriptBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		A70000000000000000000040 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		A70000000000000000000050 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		A70000000000000000000055 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
		A70000000000000000000070 /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = A70000000000000000000031 /* WhyKit */;
			targetProxy = A70000000000000000000071 /* PBXContainerItemProxy */;
		};
		A70000000000000000000072 /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = A70000000000000000000032 /* WhyCore */;
			targetProxy = A70000000000000000000073 /* PBXContainerItemProxy */;
		};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
		A700000000000000000000A0 /* Debug */ = {
			isa = XCBuildConfiguration;
			baseConfigurationReference = A70000000000000000000014 /* Why.xcconfig */;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = NO;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		A700000000000000000000A1 /* Release */ = {
			isa = XCBuildConfiguration;
			baseConfigurationReference = A70000000000000000000014 /* Why.xcconfig */;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				ENABLE_USER_SCRIPT_SANDBOXING = NO;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				SDKROOT = macosx;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
		A700000000000000000000A3 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				GENERATE_INFOPLIST_FILE = YES;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				PRODUCT_BUNDLE_IDENTIFIER = com.example.acmewhy;
				PRODUCT_NAME = "$(TARGET_NAME)";
			};
			name = Debug;
		};
		A700000000000000000000A4 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				GENERATE_INFOPLIST_FILE = YES;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				PRODUCT_BUNDLE_IDENTIFIER = com.example.acmewhy;
				PRODUCT_NAME = "$(TARGET_NAME)";
			};
			name = Release;
		};
		A700000000000000000000A6 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				DEFINES_MODULE = YES;
				DYLIB_INSTALL_NAME_BASE = "@rpath";
				GENERATE_INFOPLIST_FILE = YES;
				INSTALL_PATH = "$(LOCAL_LIBRARY_DIR)/Frameworks";
				PRODUCT_BUNDLE_IDENTIFIER = com.example.acmewhy.kit;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SKIP_INSTALL = YES;
			};
			name = Debug;
		};
		A700000000000000000000A7 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				DEFINES_MODULE = YES;
				DYLIB_INSTALL_NAME_BASE = "@rpath";
				GENERATE_INFOPLIST_FILE = YES;
				INSTALL_PATH = "$(LOCAL_LIBRARY_DIR)/Frameworks";
				PRODUCT_BUNDLE_IDENTIFIER = com.example.acmewhy.kit;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SKIP_INSTALL = YES;
			};
			name = Release;
		};
		A700000000000000000000A9 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				DEFINES_MODULE = YES;
				DYLIB_INSTALL_NAME_BASE = "@rpath";
				GENERATE_INFOPLIST_FILE = YES;
				INSTALL_PATH = "$(LOCAL_LIBRARY_DIR)/Frameworks";
				OTHER_SWIFT_FLAGS = "$(inherited) -D$(WHY_FLAG)";
				PRODUCT_BUNDLE_IDENTIFIER = com.example.acmewhy.core;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SKIP_INSTALL = YES;
			};
			name = Debug;
		};
		A700000000000000000000AA /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				DEFINES_MODULE = YES;
				DYLIB_INSTALL_NAME_BASE = "@rpath";
				GENERATE_INFOPLIST_FILE = YES;
				INSTALL_PATH = "$(LOCAL_LIBRARY_DIR)/Frameworks";
				OTHER_SWIFT_FLAGS = "$(inherited) -D$(WHY_FLAG)";
				PRODUCT_BUNDLE_IDENTIFIER = com.example.acmewhy.core;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SKIP_INSTALL = YES;
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		A700000000000000000000A2 /* Build configuration list for PBXProject "AcmeWhy" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				A700000000000000000000A0 /* Debug */,
				A700000000000000000000A1 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
		};
		A700000000000000000000A5 /* Build configuration list for PBXNativeTarget "AcmeWhyApp" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				A700000000000000000000A3 /* Debug */,
				A700000000000000000000A4 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
		};
		A700000000000000000000A8 /* Build configuration list for PBXNativeTarget "WhyKit" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				A700000000000000000000A6 /* Debug */,
				A700000000000000000000A7 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
		};
		A700000000000000000000AB /* Build configuration list for PBXNativeTarget "WhyCore" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				A700000000000000000000A9 /* Debug */,
				A700000000000000000000AA /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
		};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		A70000000000000000000092 /* XCLocalSwiftPackageReference "Packages/WhyUtils" */ = {
			isa = XCLocalSwiftPackageReference;
			relativePath = Packages/WhyUtils;
		};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		A70000000000000000000082 /* WhyUtils */ = {
			isa = XCSwiftPackageProductDependency;
			productName = WhyUtils;
		};
/* End XCSwiftPackageProductDependency section */
	};
	rootObject = A70000000000000000000001 /* Project object */;
}
EOF

echo "wrote $root"
