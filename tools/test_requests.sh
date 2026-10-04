#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
flags=()
if [[ "${SANITIZE:-0}" == 1 ]]; then flags=(-fsanitize=address,undefined -fno-omit-frame-pointer); fi
${CC:-gcc} "${flags[@]}" -std=c11 -Wall -Wextra -Werror -Wconversion -Wshadow -fPIC -shared \
 -I firmware/components/bridge_core/include \
 firmware/components/bridge_core/bridge_io.c firmware/components/bridge_core/bridge_xpc.c \
 firmware/components/bridge_core/bridge_requests.c firmware/components/bridge_core/bridge_screenshot_stream.c \
 -o .build/libbridge_requests.so
if [[ "${SANITIZE:-0}" == 1 ]]; then
  export ASAN_OPTIONS=detect_leaks=0
  if [[ "$(uname -s)" == Darwin ]]; then
    export DYLD_INSERT_LIBRARIES="$(${CC:-gcc} -print-file-name=libclang_rt.asan_osx_dynamic.dylib)${DYLD_INSERT_LIBRARIES:+:$DYLD_INSERT_LIBRARIES}"
  else
    export LD_PRELOAD="$(${CC:-gcc} -print-file-name=libasan.so)${LD_PRELOAD:+:$LD_PRELOAD}"
  fi
fi
${PYTHON:-python3} tests/test_requests.py "$PWD/.build/libbridge_requests.so"
