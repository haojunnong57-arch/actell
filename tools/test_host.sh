#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/fixtures
python3 tests/generate_fixtures.py .build/fixtures
cc=${CC:-gcc}
"$cc" -std=c11 -O1 -g -Wall -Wextra -Werror -Wconversion -Wshadow \
  -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I firmware/components/bridge_core/include -I .build/fixtures \
  firmware/components/bridge_core/bridge_io.c firmware/components/bridge_core/bridge_bplist.c \
  tests/test_core.c -o .build/test_core
ASAN_OPTIONS=detect_leaks=0 .build/test_core
