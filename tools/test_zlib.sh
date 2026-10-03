#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/zlib/plain .build/zlib/sanitized
cc=${CC:-gcc}
component=firmware/components/bridge_zlib
common=(-std=c11 -O1 -g -Wall -Wextra -Werror)
project=(-Wconversion -Wshadow -I firmware/components/bridge_core/include -I "$component/include")
zlib=(-DZ_SOLO -DZ_PREFIX -DNO_GZIP -I "$component/vendor/zlib")
san=(-fsanitize=address,undefined -fno-omit-frame-pointer)
for mode in plain sanitized; do
  flags=(-fPIC)
  if [[ "$mode" == sanitized ]]; then flags+=("${san[@]}"); fi
  for source in adler32 deflate trees zutil; do
    "$cc" "${common[@]}" "${flags[@]}" "${zlib[@]}" -c "$component/vendor/zlib/$source.c" -o ".build/zlib/$mode/$source.o"
  done
  "$cc" "${common[@]}" "${flags[@]}" "${project[@]}" "${zlib[@]}" -c "$component/bridge_zlib.c" -o ".build/zlib/$mode/bridge_zlib.o"
  "$cc" "${common[@]}" "${flags[@]}" "${project[@]}" -c firmware/components/bridge_core/bridge_media_offer.c -o ".build/zlib/$mode/bridge_media_offer.o"
done
"$cc" -shared .build/zlib/plain/*.o -o .build/zlib/libbridge_zlib.so
python3 tests/test_zlib.py
"$cc" "${common[@]}" "${project[@]}" "${san[@]}" -no-pie -pthread \
  tests/test_zlib.c .build/zlib/sanitized/*.o -lz \
  -Wl,--wrap=malloc -Wl,--wrap=calloc -Wl,--wrap=realloc -Wl,--wrap=free \
  -o .build/zlib/test_zlib_sanitized
ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:halt_on_error=1}" \
UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1:print_stacktrace=1}" \
  .build/zlib/test_zlib_sanitized
# The managed executor uses ptrace, which is incompatible with LeakSanitizer.
# Every tracked allocation is nevertheless checked for balanced release above.
"$cc" "${common[@]}" "${project[@]}" "${zlib[@]}" "${san[@]}" \
  -DESP_PLATFORM -I tests/test_zlib_esp -c "$component/bridge_zlib.c" -o .build/zlib/esp_wrapper.o
"$cc" "${common[@]}" "${project[@]}" "${san[@]}" -no-pie -I tests/test_zlib_esp \
  tests/test_zlib_esp.c .build/zlib/esp_wrapper.o .build/zlib/sanitized/bridge_media_offer.o \
  .build/zlib/sanitized/{adler32,deflate,trees,zutil}.o -o .build/zlib/test_zlib_esp
ASAN_OPTIONS="${ASAN_OPTIONS:-detect_leaks=0:halt_on_error=1}" \
UBSAN_OPTIONS="${UBSAN_OPTIONS:-halt_on_error=1:print_stacktrace=1}" .build/zlib/test_zlib_esp
printf '%s\n' 'Bounded zlib: source hashes, exact Python level-9 bytes, full offers, allocation balance, ASan/UBSan and ESP allocator shim passed; LSan disabled by default; real PSRAM/device runtime untested' 
