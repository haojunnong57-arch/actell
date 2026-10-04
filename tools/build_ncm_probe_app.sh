#!/usr/bin/env bash
# Unsigned build only; no installation or device operations.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
case "${1:-device}" in
 device) destination='generic/platform=iOS' ;;
 simulator) destination='generic/platform=iOS Simulator' ;;
 *) echo 'usage: build_ncm_probe_app.sh [device|simulator]' >&2; exit 2 ;;
esac
exec xcodebuild -project "$root/ncm-dev/ProbeApp/NCMProbe.xcodeproj" -scheme NCMProbe \
 -configuration Debug -destination "$destination" -derivedDataPath "$root/.build/ncm-probe-app" CODE_SIGNING_ALLOWED=NO build
