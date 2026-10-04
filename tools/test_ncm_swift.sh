#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$root/.build/ncm-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.build/ncm-module-cache"
exec swift test --disable-sandbox --package-path "$root/ncm-dev/PhoneAgentNCM" \
 --scratch-path "$root/.build/ncm-swift" --cache-path "$root/.build/swift-cache"
