#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
build="$root/.build/ncm-tests"
mkdir -p "$build"
idf="${IDF_PATH:-$root/../with-esp/.build/toolchains/esp-idf-v5.5.5}"
core="$root/firmware/components/bridge_core"
json="$idf/components/json/cJSON"
${CC:-clang} -std=c11 -g -O1 -Wno-deprecated-declarations -fsanitize=address,undefined -I "$json" -c "$json/cJSON.c" -o "$build/cJSON.o"
${CC:-clang} -std=c11 -g -O1 -Wall -Wextra -Werror -fsanitize=address,undefined \
 -I ncm-dev/core -I "$core/include" -I "$json" ncm-dev/tests/test_core.c ncm-dev/core/*.c \
 "$core"/{bridge_io,bridge_bplist,bridge_lockdown_probe,bridge_xpc,bridge_hid,bridge_requests,bridge_screenshot_stream,bridge_remotexpc,bridge_rsd,bridge_operations}.c \
 "$build/cJSON.o" -o "$build/core"
"$build/core"
${CC:-clang} -std=c11 -g -O1 -Wall -Wextra -Werror -fsanitize=address,undefined \
 -I ncm-dev/core -I "$core/include" -I "$json" ncm-dev/tests/test_socket.c \
 ncm-dev/core/{nd_discovery,nd_pairing,nd_socket,nd_server}.c \
 "$core"/{bridge_io,bridge_bplist,bridge_lockdown_probe}.c "$build/cJSON.o" \
 -pthread -o "$build/socket"
"$build/socket"
${CC:-clang} -std=c11 -g -O1 -Wall -Wextra -Werror -fsanitize=address,undefined \
 -I ncm-dev/core -I "$core/include" -I "$json" ncm-dev/tests/test_relay.c \
 ncm-dev/core/{nd_discovery,nd_socket,nd_relay}.c "$core/bridge_io.c" \
 -pthread -o "$build/relay"
"$build/relay"
