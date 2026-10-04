#!/usr/bin/env bash
# Build only. This script deliberately has no flash/monitor/install operation.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mode="${1:-ncm}"
case "$mode" in
  ncm) defaults='sdkconfig.defaults' ;;
  hid) defaults='sdkconfig.defaults;sdkconfig.hid' ;;
  *) echo 'Usage: build_usb_device.sh [ncm|hid]' >&2; exit 2 ;;
esac
exec "$root/tools/with_device_idf.sh" idf.py -C "$root/firmware-device" \
  -B "$root/.build/device-$mode" -D "SDKCONFIG=$root/.build/device-$mode/sdkconfig" \
  -D "SDKCONFIG_DEFAULTS=$defaults" build
