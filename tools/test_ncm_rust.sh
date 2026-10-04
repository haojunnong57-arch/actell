#!/usr/bin/env bash
# In-memory and loopback peers only. No device access, key reads or persistent keys.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
bash tools/with_ncm_rust.sh cargo test --offline --locked --manifest-path ncm-dev/rust/Cargo.toml -p phoneagent-ncm-backend
bash tools/with_ncm_rust.sh cargo test --offline --locked --manifest-path ncm-dev/rust/Cargo.toml -p idevice --lib --features ring,remote_pairing,tunnel_tcp_stack,display_stream,mobile_image_mounter
