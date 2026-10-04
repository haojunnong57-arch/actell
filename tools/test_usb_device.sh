#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$root/.build/usb-device-tests"
${CC:-clang} -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined -g \
  -I"$root/firmware-device/main" "$root/tests/usb_device/test_protocol.c" \
  "$root/firmware-device/main/protocol.c" "$root/firmware-device/main/hid_motion.c" \
  -o "$root/.build/usb-device-tests/protocol"
"$root/.build/usb-device-tests/protocol"
${CC:-clang} -std=c11 -Wall -Wextra -Werror -Wno-deprecated-declarations -fsanitize=address,undefined -g \
  -I"$root/tests/usb_device/host_stubs" -I"$root/firmware-device/main" \
  "$root/tests/usb_device/host_server.c" "$root/firmware-device/main/main.c" \
  "$root/firmware-device/main/protocol.c" "$root/firmware-device/main/hid_motion.c" \
  -o "$root/.build/usb-device-tests/server"
python3 "$root/tests/usb_device/test_tcp.py"
