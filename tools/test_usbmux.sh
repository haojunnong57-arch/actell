#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/host_test_platform.sh
mkdir -p .build
cc=${CC:-gcc}
"$cc" -std=c11 -O1 -g -Wall -Wextra -Werror -Wconversion -Wshadow \
  -fsanitize=address,undefined -fno-omit-frame-pointer "${host_no_pie[@]}" \
  -I firmware/components/bridge_core/include \
  firmware/components/bridge_core/bridge_usbmux.c tests/test_usbmux.c \
  -o .build/test_usbmux
ASAN_OPTIONS=detect_leaks=0 .build/test_usbmux
