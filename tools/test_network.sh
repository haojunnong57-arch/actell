#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/host_test_platform.sh
mkdir -p .build
${CC:-gcc} -std=c11 -O1 -g -Wall -Wextra -Werror -Wconversion -Wshadow \
 -fsanitize=address,undefined -fno-omit-frame-pointer "${host_no_pie[@]}" \
 -I firmware/components/bridge_core/include -I firmware/components/bridge_lwip/include \
 -I firmware/components/bridge_network/include -I tests/network_sim_include \
 firmware/components/bridge_network/bridge_network.c tests/test_network.c -o .build/test_network
ASAN_OPTIONS=detect_leaks=0 .build/test_network
