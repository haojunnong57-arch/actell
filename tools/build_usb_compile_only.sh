#!/usr/bin/env bash
# Build a test profile ONLY. This does not confirm wiring, activate a USB port,
# or flash hardware. Its arbitrary config value 4 is a test, not a recommendation.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
command -v idf.py >/dev/null || { echo 'Source ESP-IDF v5.5.5 export.sh first.' >&2; exit 1; }
mkdir -p "$root/.build"
cat > "$root/.build/usb-compile-only.defaults" <<'CONFIG'
CONFIG_BRIDGE_USB_WIRING_CONFIRMED=y
CONFIG_BRIDGE_USB_HOST_ENABLE=y
CONFIG_BRIDGE_USB_CONFIGURATION_VALUE=4
CONFIG
printf '%s\n' 'COMPILATION ONLY. Do not flash this synthetic hardware-confirmation profile.'
cd "$root/firmware"
idf.py -B "$root/.build/firmware-usb-enabled" \
  -D "SDKCONFIG=$root/.build/sdkconfig-usb-enabled" \
  -D "SDKCONFIG_DEFAULTS=$root/firmware/sdkconfig.defaults;$root/.build/usb-compile-only.defaults" build size
