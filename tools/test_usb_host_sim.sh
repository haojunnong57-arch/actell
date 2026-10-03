#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
${CC:-gcc} -std=c11 -g -O1 -Wall -Wextra -Werror -Wconversion -Wshadow \
 -fsanitize=address,undefined -fno-omit-frame-pointer -fno-pie -no-pie \
 -I tests/usb_host_sim/include -I firmware/components/bridge_core/include \
 -I firmware/components/bridge_usb_host/include \
 tests/usb_host_sim/test_lifecycle.c firmware/components/bridge_core/bridge_usb_descriptors.c \
 -o .build/test_usb_host_sim
ASAN_OPTIONS=detect_leaks=0 .build/test_usb_host_sim
${CC:-gcc} -std=c11 -g -O1 -Wall -Wextra -Werror -Wconversion -Wshadow \
 -fsanitize=address,undefined -fno-omit-frame-pointer -fno-pie -no-pie \
 -I tests/usb_host_sim/include -I firmware/components/bridge_core/include \
 -I firmware/components/bridge_usb_host/include \
 tests/usb_host_sim/test_protocol_integration.c \
 firmware/components/bridge_core/{bridge_usb_descriptors,bridge_usbmux,bridge_lockdown_probe,bridge_io,bridge_bplist}.c \
 -o .build/test_usb_host_protocol_sim
ASAN_OPTIONS=detect_leaks=0 .build/test_usb_host_protocol_sim
