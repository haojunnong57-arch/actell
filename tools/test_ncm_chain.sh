#!/usr/bin/env bash
# Actual Swift -> C ABI -> Rust -> C relay -> synthetic peer. LOOPBACK ONLY.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
mkdir -p .build/ncm-tests
clang -std=c11 -g -O1 -Wall -Wextra -Werror -fsanitize=address,undefined \
 -I ncm-dev/core -I firmware/components/bridge_core/include \
 ncm-dev/tests/relay_fixture.c ncm-dev/core/{nd_discovery,nd_socket,nd_relay}.c \
 firmware/components/bridge_core/bridge_io.c -pthread -o .build/ncm-tests/relay_fixture
# Separate target directory ensures test-only exports cannot enter iOS artifacts.
NCM_RUST_TARGET_DIR="$root/.build/ncm-rust-fixtures" bash tools/with_ncm_rust.sh cargo build --offline --locked --manifest-path ncm-dev/rust/Cargo.toml --features offline-fixtures --release --target aarch64-apple-darwin
export NCM_OFFLINE_FIXTURES=1
export NCM_BACKEND_ARCHIVE_DIR="$root/.build/ncm-rust-fixtures/aarch64-apple-darwin/release"
export NCM_RELAY_FIXTURE="$root/.build/ncm-tests/relay_fixture"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="$root/.build/ncm-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$root/.build/ncm-module-cache"
swift test --disable-sandbox --package-path "$root/ncm-dev/PhoneAgentNCM" \
 --scratch-path "$root/.build/ncm-swift-chain" --cache-path "$root/.build/swift-cache"
