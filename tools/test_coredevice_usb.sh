#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/host_test_platform.sh
mkdir -p .build
${CC:-gcc} -std=c11 -g -O1 -Wall -Wextra -Werror -Wconversion -Wshadow \
 -fsanitize=address,undefined -fno-omit-frame-pointer "${host_no_pie[@]}" \
 -I tests/usb_host_sim/include -I firmware/components/bridge_core/include \
 -I firmware/components/bridge_usb_host/include -I firmware/components/bridge_tls/include \
 -I firmware/components/bridge_coredevice_usb/include \
 tests/test_coredevice_usb.c firmware/components/bridge_coredevice_usb/bridge_coredevice_usb.c \
 firmware/components/bridge_core/{bridge_io,bridge_bplist,bridge_lockdown_probe,bridge_lockdown_session,bridge_cdtunnel}.c \
 -o .build/test_coredevice_usb
ASAN_OPTIONS=detect_leaks=0 .build/test_coredevice_usb
