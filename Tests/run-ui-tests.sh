#!/bin/bash
set -euo pipefail

# Uses an isolated test project; the app's project and signing settings are untouched.
repo_dir=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
test_dir=$(mktemp -d /tmp/iroirokae-ui-tests.XXXXXX)
simulator_id="${1:-}"
if [ "$#" -gt 0 ]; then shift; fi
if [ -z "$simulator_id" ]; then
  simulator_id=$(/usr/bin/xcrun simctl list devices available -j | /usr/bin/python3 -c '
import json, sys
devices = [d for runtime in json.load(sys.stdin)["devices"].values() for d in runtime if "iPhone" in d["name"]]
if not devices:
    raise SystemExit("No available iPhone simulator. Pass its device identifier as the first argument.")
print(next((d for d in devices if d["state"] == "Booted"), devices[0])["udid"])
')
fi

/usr/bin/python3 - "$repo_dir" "$test_dir" <<'PY'
from pathlib import Path
import json
import re
import sys

repo = Path(sys.argv[1])
destination = Path(sys.argv[2]) / "CameraUITest.xcodeproj"
destination.mkdir()
source = (repo / "色々変え.xcodeproj/project.xcproj").read_text()
# The Xcode project format permits trailing commas.
project = json.loads(re.sub(r",\s*([}\]])", r"\1", source))
project["files"][0]["path"] = str(repo / "色々変え")
project["files"].append({
    "path": str(repo / "Tests/CameraUITests.swift"),
    "target-membership": ["CameraUITests/compile-sources"],
})
project["files"][1]["children"].append({
    "path": "<PRODUCTS>/CameraUITests.xctest",
    "id": "000000000000000000000121",
    "type": "wrapper.cfbundle",
    "index": False,
})
project["targets"].append({
    "name": "CameraUITests",
    "id": "000000000000000100000001",
    "product": "Products/CameraUITests.xctest",
    "product-type": "bundle.ui-testing",
    "dependencies": ["色々変え"],
    "build-phases": ["compile-sources", "frameworks", "resources"],
    "build-settings": {
        "GENERATE_INFOPLIST_FILE": "YES",
        "PRODUCT_BUNDLE_IDENTIFIER": "dev.somayumoto.IroIroKae.UITests",
        "PRODUCT_NAME": "$(TARGET_NAME)",
        "SDKROOT": "iphoneos",
        "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
        "SWIFT_VERSION": "5.0",
        "TEST_TARGET_NAME": "色々変え",
        "TARGETED_DEVICE_FAMILY": "1,2",
    },
})
(destination / "project.xcproj").write_text(json.dumps(project, ensure_ascii=False, indent=2))
schemes = destination / "xcshareddata/xcschemes"
schemes.mkdir(parents=True)
(schemes / "CameraUITests.xcscheme").write_text('''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2720" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="000000000000000100000001" BuildableName="CameraUITests.xctest" BlueprintName="CameraUITests" ReferencedContainer="container:CameraUITest.xcodeproj"/>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES">
    <Testables>
      <TestableReference skipped="NO" parallelizable="NO">
        <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="000000000000000100000001" BuildableName="CameraUITests.xctest" BlueprintName="CameraUITests" ReferencedContainer="container:CameraUITest.xcodeproj"/>
      </TestableReference>
    </Testables>
    <MacroExpansion>
      <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="000000000000000100000000" BuildableName="色々変え.app" BlueprintName="色々変え" ReferencedContainer="container:CameraUITest.xcodeproj"/>
    </MacroExpansion>
  </TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"/>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"/>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
PY

printf 'UI test artifacts: %s\n' "$test_dir"
/usr/bin/xcodebuild test \
  -project "$test_dir/CameraUITest.xcodeproj" \
  -scheme CameraUITests \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$test_dir/build" \
  -resultBundlePath "$test_dir/Results.xcresult" \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_DEBUG_DYLIB=NO \
  "$@" \
  2>&1 | tee "$test_dir/test.log"
printf 'UI test results: %s/Results.xcresult\n' "$test_dir"
