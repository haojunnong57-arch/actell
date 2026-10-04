#!/usr/bin/env bash
# Static backend with C ABI; no signing, installation or device actions.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
case "${1:-device}" in
 device) target=aarch64-apple-ios ;;
 simulator) target=aarch64-apple-ios-sim ;;
 host) target=aarch64-apple-darwin ;;
 *) echo 'usage: build_ncm_rust.sh [device|simulator|host]' >&2; exit 2 ;;
esac
bash tools/with_ncm_rust.sh cargo build --offline --locked --manifest-path ncm-dev/rust/Cargo.toml --release --target "$target"
