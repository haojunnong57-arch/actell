/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bridge_zlib.h"
#include "esp_heap_caps.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static size_t attempts, allocations, frees, fail_at;
void *heap_caps_malloc(size_t bytes, uint32_t capabilities) {
    assert(capabilities == (MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT));
    if (attempts++ == fail_at) return NULL;
    void *result = malloc(bytes); assert(result); ++allocations;
    memset(result, 0xa5, bytes); return result;
}
void heap_caps_free(void *pointer) { assert(pointer); ++frees; free(pointer); }
int main(void) {
    uint8_t input[384], output[512]; size_t input_size, output_size;
    assert(bridge_media_video_protobuf(123, input, sizeof input, &input_size) == BRIDGE_OK);
    for (fail_at = 0; fail_at <= 5; ++fail_at) {
        attempts = allocations = frees = 0;
        bridge_zlib_stats stats; bridge_zlib_config config = BRIDGE_ZLIB_CONFIG_DEFAULT;
        config.stats = &stats; output_size = 999;
        bridge_status status = bridge_zlib_compress(&config, input, input_size, output, sizeof output, &output_size);
        assert(status == (fail_at < 5 ? BRIDGE_E_LIMIT : BRIDGE_OK));
        assert(fail_at < 5 ? output_size == 0 : output_size > 0);
        assert(stats.live_bytes == 0 && allocations == frees);
        assert(stats.allocations == allocations && stats.frees == frees);
        if (fail_at == 0) assert(allocations == 0); /* No PSRAM: no fallback. */
    }
    puts("ESP allocator branch: exact PSRAM/8BIT capabilities, absent PSRAM and each allocation failure passed (host shim only)");
    return 0;
}
