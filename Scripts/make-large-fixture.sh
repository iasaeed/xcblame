#!/bin/bash
# Synthesizes a large Xcode project for the `doctor` performance gate (DESIGN §11 v0.3: < 5 s on 200 targets).
# Usage: Scripts/make-large-fixture.sh <out-dir> [targets (default 200)]
# Writes <out-dir>/Large.xcodeproj (objectVersion 77, one synchronized folder per target) and <out-dir>/ModuleN/*.swift:
# one app target plus N-1 static library targets; each library depends on the two before it, every 10th has a
# script phase without outputs. Nothing is built. Open it with: xcodebuild -list -project <out-dir>/Large.xcodeproj
set -euo pipefail

out=${1:?usage: make-large-fixture.sh <out-dir> [targets]}
count=${2:-200}
(( count >= 2 )) || { echo "targets must be at least 2" >&2; exit 2; }
proj="$out/Large.xcodeproj"
mkdir -p "$proj"

id() { printf 'AA%022X' "$1"; }              # 24 hex digits
# Per target t (1-based) the ids are t*16 + k: k=0 target, 1 product, 2 group, 3 sources, 4 frameworks, 5 script,
# 6 config list, 7 Debug, 8 Release, 9 dependency, 10 proxy, 11 second dependency, 12 second proxy.
oid() { id $(( $1 * 16 + $2 )); }
name() { if (( $1 == 1 )); then echo LargeApp; else printf 'Module%03d' "$1"; fi; }

for (( t = 1; t <= count; t++ )); do
  n=$(name "$t")
  mkdir -p "$out/$n"
  printf 'public enum %s { public static let value = %d }\n' "$n" "$t" > "$out/$n/$n.swift"
done
cat > "$out/LargeApp/LargeAppMain.swift" <<'SWIFT'
@main
struct LargeAppMain { static func main() {} }
SWIFT

deps_of() {  # dependency target numbers of target t
  local t=$1
  if (( t == 1 )); then (( count >= 2 )) && echo 2; (( count >= 3 )) && echo 3; return; fi
  (( t + 1 <= count )) && echo $(( t + 1 ))
  (( t + 2 <= count )) && echo $(( t + 2 ))
  return 0
}

{
  printf '// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 77;\n\tobjects = {\n\n'

  echo '/* Begin PBXContainerItemProxy section */'
  for (( t = 1; t <= count; t++ )); do
    k=10
    for d in $(deps_of "$t"); do
      printf '\t\t%s /* PBXContainerItemProxy */ = {\n\t\t\tisa = PBXContainerItemProxy;\n\t\t\tcontainerPortal = %s /* Project object */;\n\t\t\tproxyType = 1;\n\t\t\tremoteGlobalIDString = %s;\n\t\t\tremoteInfo = %s;\n\t\t};\n' \
        "$(oid "$t" $k)" "$(id 1)" "$(oid "$d" 0)" "$(name "$d")"
      k=12
    done
  done
  echo '/* End PBXContainerItemProxy section */'
  echo

  echo '/* Begin PBXFileReference section */'
  for (( t = 1; t <= count; t++ )); do
    n=$(name "$t")
    if (( t == 1 )); then
      printf '\t\t%s /* %s.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = %s.app; sourceTree = BUILT_PRODUCTS_DIR; };\n' "$(oid "$t" 1)" "$n" "$n"
    else
      printf '\t\t%s /* lib%s.a */ = {isa = PBXFileReference; explicitFileType = archive.ar; includeInIndex = 0; path = lib%s.a; sourceTree = BUILT_PRODUCTS_DIR; };\n' "$(oid "$t" 1)" "$n" "$n"
    fi
  done
  echo '/* End PBXFileReference section */'
  echo

  echo '/* Begin PBXFileSystemSynchronizedRootGroup section */'
  for (( t = 1; t <= count; t++ )); do
    n=$(name "$t")
    printf '\t\t%s /* %s */ = {\n\t\t\tisa = PBXFileSystemSynchronizedRootGroup;\n\t\t\tpath = %s;\n\t\t\tsourceTree = "<group>";\n\t\t};\n' "$(oid "$t" 2)" "$n" "$n"
  done
  echo '/* End PBXFileSystemSynchronizedRootGroup section */'
  echo

  echo '/* Begin PBXFrameworksBuildPhase section */'
  for (( t = 1; t <= count; t++ )); do
    printf '\t\t%s /* Frameworks */ = {\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n' "$(oid "$t" 4)"
  done
  echo '/* End PBXFrameworksBuildPhase section */'
  echo

  echo '/* Begin PBXGroup section */'
  printf '\t\t%s = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' "$(id 2)"
  for (( t = 1; t <= count; t++ )); do printf '\t\t\t\t%s /* %s */,\n' "$(oid "$t" 2)" "$(name "$t")"; done
  printf '\t\t\t\t%s /* Products */,\n\t\t\t);\n\t\t\tsourceTree = "<group>";\n\t\t};\n' "$(id 3)"
  printf '\t\t%s /* Products */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n' "$(id 3)"
  for (( t = 1; t <= count; t++ )); do printf '\t\t\t\t%s,\n' "$(oid "$t" 1)"; done
  printf '\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = "<group>";\n\t\t};\n'
  echo '/* End PBXGroup section */'
  echo

  echo '/* Begin PBXNativeTarget section */'
  for (( t = 1; t <= count; t++ )); do
    n=$(name "$t")
    printf '\t\t%s /* %s */ = {\n\t\t\tisa = PBXNativeTarget;\n\t\t\tbuildConfigurationList = %s;\n\t\t\tbuildPhases = (\n' "$(oid "$t" 0)" "$n" "$(oid "$t" 6)"
    (( t % 10 == 0 )) && printf '\t\t\t\t%s /* Generate */,\n' "$(oid "$t" 5)"
    printf '\t\t\t\t%s /* Sources */,\n\t\t\t\t%s /* Frameworks */,\n\t\t\t);\n\t\t\tbuildRules = (\n\t\t\t);\n\t\t\tdependencies = (\n' "$(oid "$t" 3)" "$(oid "$t" 4)"
    k=9
    for d in $(deps_of "$t"); do printf '\t\t\t\t%s /* PBXTargetDependency */,\n' "$(oid "$t" $k)"; k=11; done
    printf '\t\t\t);\n\t\t\tfileSystemSynchronizedGroups = (\n\t\t\t\t%s /* %s */,\n\t\t\t);\n\t\t\tname = %s;\n\t\t\tproductName = %s;\n\t\t\tproductReference = %s;\n' \
      "$(oid "$t" 2)" "$n" "$n" "$n" "$(oid "$t" 1)"
    if (( t == 1 )); then type=com.apple.product-type.application; else type=com.apple.product-type.library.static; fi
    printf '\t\t\tproductType = "%s";\n\t\t};\n' "$type"
  done
  echo '/* End PBXNativeTarget section */'
  echo

  echo '/* Begin PBXProject section */'
  printf '\t\t%s /* Project object */ = {\n\t\t\tisa = PBXProject;\n\t\t\tattributes = {\n\t\t\t\tBuildIndependentTargetsInParallel = 1;\n\t\t\t\tLastUpgradeCheck = 2600;\n\t\t\t};\n' "$(id 1)"
  printf '\t\t\tbuildConfigurationList = %s;\n\t\t\tdevelopmentRegion = en;\n\t\t\thasScannedForEncodings = 0;\n\t\t\tknownRegions = (\n\t\t\t\ten,\n\t\t\t\tBase,\n\t\t\t);\n' "$(id 6)"
  printf '\t\t\tmainGroup = %s;\n\t\t\tminimizedProjectReferenceProxies = 1;\n\t\t\tpreferredProjectObjectVersion = 77;\n\t\t\tproductRefGroup = %s /* Products */;\n\t\t\tprojectDirPath = "";\n\t\t\tprojectRoot = "";\n\t\t\ttargets = (\n' "$(id 2)" "$(id 3)"
  for (( t = 1; t <= count; t++ )); do printf '\t\t\t\t%s /* %s */,\n' "$(oid "$t" 0)" "$(name "$t")"; done
  printf '\t\t\t);\n\t\t};\n'
  echo '/* End PBXProject section */'
  echo

  echo '/* Begin PBXShellScriptBuildPhase section */'
  for (( t = 10; t <= count; t += 10 )); do
    printf '\t\t%s /* Generate */ = {\n\t\t\tisa = PBXShellScriptBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\tinputPaths = (\n\t\t\t);\n\t\t\tname = Generate;\n\t\t\toutputPaths = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t\tshellPath = /bin/sh;\n\t\t\tshellScript = "echo generate %s\\n";\n\t\t};\n' "$(oid "$t" 5)" "$(name "$t")"
  done
  echo '/* End PBXShellScriptBuildPhase section */'
  echo

  echo '/* Begin PBXSourcesBuildPhase section */'
  for (( t = 1; t <= count; t++ )); do
    printf '\t\t%s /* Sources */ = {\n\t\t\tisa = PBXSourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n' "$(oid "$t" 3)"
  done
  echo '/* End PBXSourcesBuildPhase section */'
  echo

  echo '/* Begin PBXTargetDependency section */'
  for (( t = 1; t <= count; t++ )); do
    k=9
    for d in $(deps_of "$t"); do
      printf '\t\t%s /* PBXTargetDependency */ = {\n\t\t\tisa = PBXTargetDependency;\n\t\t\ttarget = %s /* %s */;\n\t\t\ttargetProxy = %s /* PBXContainerItemProxy */;\n\t\t};\n' \
        "$(oid "$t" $k)" "$(oid "$d" 0)" "$(name "$d")" "$(oid "$t" $(( k + 1 )))"
      k=11
    done
  done
  echo '/* End PBXTargetDependency section */'
  echo

  echo '/* Begin XCBuildConfiguration section */'
  printf '\t\t%s /* Debug */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;\n\t\t\t\tONLY_ACTIVE_ARCH = YES;\n\t\t\t\tSDKROOT = macosx;\n\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";\n\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";\n\t\t\t\tSWIFT_VERSION = 5.0;\n\t\t\t};\n\t\t\tname = Debug;\n\t\t};\n' "$(id 7)"
  printf '\t\t%s /* Release */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";\n\t\t\t\tSDKROOT = macosx;\n\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;\n\t\t\t\tSWIFT_VERSION = 5.0;\n\t\t\t};\n\t\t\tname = Release;\n\t\t};\n' "$(id 8)"
  for (( t = 1; t <= count; t++ )); do
    for c in 7:Debug 8:Release; do
      printf '\t\t%s /* %s */ = {\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {\n\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";\n\t\t\t};\n\t\t\tname = %s;\n\t\t};\n' "$(oid "$t" "${c%%:*}")" "${c#*:}" "${c#*:}"
    done
  done
  echo '/* End XCBuildConfiguration section */'
  echo

  echo '/* Begin XCConfigurationList section */'
  printf '\t\t%s = {\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t%s /* Debug */,\n\t\t\t\t%s /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t};\n' "$(id 6)" "$(id 7)" "$(id 8)"
  for (( t = 1; t <= count; t++ )); do
    printf '\t\t%s = {\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t%s /* Debug */,\n\t\t\t\t%s /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t};\n' "$(oid "$t" 6)" "$(oid "$t" 7)" "$(oid "$t" 8)"
  done
  echo '/* End XCConfigurationList section */'

  printf '\t};\n\trootObject = %s /* Project object */;\n}\n' "$(id 1)"
} > "$proj/project.pbxproj"

echo "wrote $proj ($count targets)"
