#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
pin=fd432e4ee2cfb7f7f1c7eb7227e0173412e7b84e
if [[ -n ${LWIP_SOURCE_DIR:-} ]]; then
  lwip=$LWIP_SOURCE_DIR
elif [[ -n ${IDF_PATH:-} ]]; then
  lwip=$IDF_PATH/components/lwip/lwip
else
  echo 'Source ESP-IDF v5.5.5 export.sh or set LWIP_SOURCE_DIR before testing' >&2
  exit 1
fi
if [[ ! -f "$lwip/src/core/tcp.c" ]]; then
  echo 'Pinned lwIP source unavailable: set LWIP_SOURCE_DIR to ESP-IDF v5.5.5 components/lwip/lwip' >&2
  exit 1
fi
actual=$(git -C "$lwip" rev-parse HEAD)
[[ "$actual" == "$pin" ]] || { echo "lwIP pin mismatch: $actual (expected $pin)" >&2; exit 1; }
[[ -z $(git -C "$lwip" status --porcelain --untracked-files=no) ]] || { echo 'lwIP tracked sources have local changes' >&2; exit 1; }
cc=${CC:-gcc}
port="$lwip/contrib/ports/unix/port"
flags=(-std=c11 -D_POSIX_C_SOURCE=200809L -D_DEFAULT_SOURCE -g -O1 -Wall -Wextra -Werror -pthread -fno-omit-frame-pointer)
# Darwin hides the upstream port's relative pthread wait under strict POSIX.
if [[ "$(uname -s)" == Darwin ]]; then flags+=(-D_DARWIN_C_SOURCE); fi
case ${SANITIZE:-1} in
  1|address) mode=address; flags+=(-fsanitize=address,undefined) ;;
  thread) mode=thread; flags+=(-fsanitize=thread) ;;
  0) mode=plain ;;
  *) echo "Unsupported SANITIZE mode" >&2; exit 1 ;;
esac
build=".build/lwip/$mode"
mkdir -p "$build"
printf "Testing real lwIP %s with %s sanitizers\n" "$pin" "$mode"
incs=(-I tests/test_lwip -I "$port/include" -I "$lwip/src/include" -I firmware/components/bridge_core/include -I firmware/components/bridge_lwip/include)
sources=("$lwip"/src/core/*.c "$lwip"/src/core/ipv4/*.c "$lwip"/src/core/ipv6/*.c "$lwip/src/api/tcpip.c" "$lwip/src/api/netifapi.c" tests/test_lwip/host_protect.c "$build/sys_arch.o")
"$cc" "${flags[@]}" "${incs[@]}" \
  -Dsys_arch_protect=bridge_upstream_protect_unused \
  -Dsys_arch_unprotect=bridge_upstream_unprotect_unused \
  -c "$port/sys_arch.c" -o "$build/sys_arch.o"
"$cc" "${flags[@]}" "${incs[@]}" "${sources[@]}" tests/test_lwip/port_smoke.c -o "$build/port_smoke"
ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0} "$build/port_smoke"

"$cc" "${flags[@]}" "${incs[@]}" "${sources[@]}" \
  firmware/components/bridge_core/bridge_io.c \
  firmware/components/bridge_core/bridge_cdtunnel.c \
  firmware/components/bridge_lwip/bridge_lwip.c \
  tests/test_lwip/test_lwip.c -o "$build/test_lwip"
ASAN_OPTIONS=${ASAN_OPTIONS:-detect_leaks=0} "$build/test_lwip"
