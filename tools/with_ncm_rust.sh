#!/usr/bin/env bash
# Use an existing Rust compiler; writes/cache/outputs stay in this worktree.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
toolchain="${NCM_RUST_TOOLCHAIN:-$root/../app-only/build/toolchains/rustup/toolchains/1.95.0-aarch64-apple-darwin}"
export PATH="$toolchain/bin:$PATH"
export RUSTC="$toolchain/bin/rustc"
export RUSTDOC="$toolchain/bin/rustdoc"
export CARGO_HOME="$root/.build/ncm-cargo"
export CARGO_TARGET_DIR="$root/.build/ncm-rust"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
exec "$@"
