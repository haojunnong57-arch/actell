#!/usr/bin/env bash
# Static Rust backend only; no C ABI/Swift link or app signing/installation.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
case "${1:-device}" in
 device) target=aarch64-apple-ios ;;
 simulator) target=aarch64-apple-ios-sim ;;
 *) echo 'usage: build_ncm_rust.sh [device|simulator]' >&2; exit 2 ;;
esac
bash tools/with_ncm_rust.sh cargo build --offline --locked --manifest-path ncm-dev/rust/Cargo.toml --release --target "$target"
