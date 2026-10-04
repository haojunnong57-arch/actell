#!/usr/bin/env bash
# Build only. Never flashes or opens serial/USB.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
exec "$root/tools/with_device_idf.sh" idf.py -C "$root/ncm-dev/firmware" \
  -B "$root/.build/ncm-developer" -D "SDKCONFIG=$root/.build/ncm-developer/sdkconfig" build
