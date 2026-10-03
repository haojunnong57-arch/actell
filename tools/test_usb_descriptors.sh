#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
${CC:-gcc} -std=c11 -g -O1 -Wall -Wextra -Werror -Wconversion -Wshadow -fsanitize=address,undefined \
 -I firmware/components/bridge_core/include firmware/components/bridge_core/bridge_usb_descriptors.c \
 tests/test_usb_descriptors.c -o .build/test_usb_descriptors
ASAN_OPTIONS=detect_leaks=0 .build/test_usb_descriptors
