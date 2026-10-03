#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
# Real ESP-IDF 5.5.5 mbedTLS source; fixture certificates/keys stay OUTSIDE
# firmware and are public upstream tests, NOT usable production credentials.
mbedtls=${MBEDTLS_SOURCE_DIR:-${IDF_PATH:+${IDF_PATH}/components/mbedtls/mbedtls}}
cmake=${CMAKE:-cmake}
if ! command -v "$cmake" >/dev/null; then
  echo "CMake unavailable; source ESP-IDF export.sh or set CMAKE" >&2; exit 1
fi
[[ -f "$mbedtls/include/mbedtls/ssl.h" && -f "$mbedtls/framework/data_files/server2-sha256.crt" ]] || {
  echo 'Set MBEDTLS_SOURCE_DIR to the ESP-IDF 5.5.5 mbedTLS checkout with framework submodule' >&2; exit 1;
}
mkdir -p .build/tls-mbedtls
"$cmake" -S "$mbedtls" -B .build/tls-mbedtls -DENABLE_TESTING=OFF -DENABLE_PROGRAMS=OFF \
  -DCMAKE_BUILD_TYPE=Debug -DCMAKE_C_FLAGS='-fsanitize=address,undefined -fno-omit-frame-pointer' \
  > .build/tls-mbedtls/configure.log 2>&1
"$cmake" --build .build/tls-mbedtls -j "${BUILD_JOBS:-4}" > .build/tls-mbedtls/build.log 2>&1
"${CC:-gcc}" -std=c11 -O1 -g -Wall -Wextra -Werror -Wconversion -Wshadow \
  -fsanitize=address,undefined -fno-omit-frame-pointer -no-pie \
  -I "$mbedtls/include" -I firmware/components/bridge_core/include \
  -I firmware/components/bridge_tls/include \
  firmware/components/bridge_core/bridge_io.c firmware/components/bridge_tls/bridge_tls.c \
  tests/test_tls_client.c .build/tls-mbedtls/library/libmbedtls.a \
  .build/tls-mbedtls/library/libmbedx509.a .build/tls-mbedtls/library/libmbedcrypto.a \
  -Wl,--wrap=calloc -Wl,--wrap=free -o .build/test_tls_client
"${PYTHON:-python3}" tests/test_tls_peer.py .build/test_tls_client "$mbedtls/framework/data_files"
"${CC:-gcc}" -std=c11 -O1 -g -Wall -Wextra -Werror -Wconversion -Wshadow \
  -fsanitize=address,undefined -fno-omit-frame-pointer -no-pie \
  -I "$mbedtls/include" -I firmware/components/bridge_core/include \
  -I firmware/components/bridge_tls/include \
  firmware/components/bridge_core/bridge_io.c firmware/components/bridge_core/bridge_bplist.c \
  firmware/components/bridge_core/bridge_lockdown_session.c firmware/components/bridge_tls/bridge_tls.c \
  tests/test_tls_lockdown.c .build/tls-mbedtls/library/libmbedtls.a \
  .build/tls-mbedtls/library/libmbedx509.a .build/tls-mbedtls/library/libmbedcrypto.a \
  -Wl,--wrap=calloc -Wl,--wrap=free -o .build/test_tls_lockdown
"${PYTHON:-python3}" tests/test_tls_lockdown_peer.py .build/test_tls_lockdown "$mbedtls/framework/data_files"
