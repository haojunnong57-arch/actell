#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."
source tools/host_test_platform.sh
mkdir -p .build/media_offer
cc=${CC:-gcc}
common=(-std=c11 -O1 -g -Wall -Wextra -Werror -Wconversion -Wshadow -I firmware/components/bridge_core/include)
source=firmware/components/bridge_core/bridge_media_offer.c
"$cc" "${common[@]}" -fPIC -shared "$source" -o .build/media_offer/libmedia_offer.so
python3 tests/test_media_offer.py
# The zlib adapter below is host-test code only. It is not a production firmware
# callback: compress2 may allocate. No firmware zlib integration is implied.
cat > .build/media_offer/sanitizer.c <<'C'
#include "bridge_media_offer.h"
#include <assert.h>
#include <string.h>
#include <zlib.h>
static bridge_status host_zlib9(void *ctx, const uint8_t *src, size_t n,
        uint8_t *dst, size_t cap, size_t *size) {
    (void)ctx; uLongf result = (uLongf)cap;
    int s = compress2(dst, &result, src, (uLong)n, 9);
    *size = 0;
    if (s != Z_OK) return BRIDGE_E_IO;
    *size = (size_t)result; return BRIDGE_OK;
}
int main(void) {
    uint8_t uuid[16] = {0}, out[BRIDGE_MEDIA_VIDEO_OFFER_MAX + 1];
    size_t needed = 0, size = 0;
    assert(bridge_media_video_offer(UINT32_MAX, uuid, host_zlib9, 0,
        out, sizeof out - 1, &needed) == BRIDGE_OK);
    for (size_t cap = 0; cap <= sizeof out - 1; ++cap) {
        memset(out, 0xa5, sizeof out); size = 999;
        bridge_status s = bridge_media_video_offer(UINT32_MAX, uuid,
            host_zlib9, 0, out, cap, &size);
        assert(s == (cap < needed ? BRIDGE_E_LIMIT : BRIDGE_OK));
        assert(size == (cap < needed ? 0 : needed));
        for (size_t j = cap; j < sizeof out; ++j) assert(out[j] == 0xa5);
    }
    uint32_t sid = 1;
    for (unsigned i = 0; i < 2000; ++i) {
        sid = sid * UINT32_C(1664525) + UINT32_C(1013904223);
        assert(bridge_media_video_offer(sid, uuid, host_zlib9, 0,
            out, sizeof out - 1, &size) == BRIDGE_OK);
        assert(size <= BRIDGE_MEDIA_VIDEO_OFFER_MAX);
    }
    return 0;
}
C
"$cc" "${common[@]}" -fsanitize=address,undefined -fno-omit-frame-pointer "${host_no_pie[@]}" \
  "$source" .build/media_offer/sanitizer.c -lz -o .build/media_offer/test_sanitized
ASAN_OPTIONS=detect_leaks=0 .build/media_offer/test_sanitized
printf 'Media offer: pinned byte equivalence, bounds, ASan and UBSan passed; device acceptance untested\n'
