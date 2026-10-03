#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
"${XPC_PYTHON:-python3}" tests/test_rsd_reference.py
"${CC:-gcc}" -std=c11 -O1 -g -Wall -Wextra -Werror -Wconversion -Wshadow \
    -fsanitize=address,undefined -fno-omit-frame-pointer \
    -I firmware/components/bridge_core/include -I .build/rsd-fixtures \
    firmware/components/bridge_core/bridge_io.c firmware/components/bridge_core/bridge_xpc.c \
    firmware/components/bridge_core/bridge_remotexpc.c firmware/components/bridge_core/bridge_rsd.c \
    tests/test_rsd.c -o .build/test_rsd
ASAN_OPTIONS=detect_leaks=0 .build/test_rsd
