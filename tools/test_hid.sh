#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
${CC:-gcc} -std=c11 -Wall -Wextra -Werror -Wconversion -Wshadow -fPIC -shared \
 -I firmware/components/bridge_core/include firmware/components/bridge_core/bridge_hid.c -o .build/libbridge_hid.so
python3 tests/test_hid.py "$PWD/.build/libbridge_hid.so"
