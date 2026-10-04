#!/bin/bash
set -euo pipefail
if [ "$#" -ne 1 ]; then echo "Usage: $0 <isolated-simulator-UDID> (RUN_UI_TESTS=1 includes UI)" >&2; exit 2; fi
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p "$repo_root/.build/validation"
result_dir="$(mktemp -d "$repo_root/.build/validation/core.XXXXXX")"
selection=(-only-testing:PhoneAgentTests)
if [ "${RUN_UI_TESTS:-0}" = 1 ]; then selection+=(-only-testing:PhoneAgentUITests); fi
xcodebuild -project "$repo_root/ios-app/PhoneAgent.xcodeproj" -scheme PhoneAgent \
  -destination "platform=iOS Simulator,id=$1" -derivedDataPath "$repo_root/.build/DerivedData" \
  -clonedSourcePackagesDirPath "$repo_root/.build/SourcePackages" \
  -disableAutomaticPackageResolution -skipPackageUpdates -parallel-testing-enabled NO \
  -resultBundlePath "$result_dir/Tests.xcresult" "${selection[@]}" \
  CODE_SIGNING_ALLOWED=NO test > "$result_dir/test.log" 2>&1 || { tail -50 "$result_dir/test.log"; exit 1; }
tail -12 "$result_dir/test.log"
echo "Evidence: $result_dir"
