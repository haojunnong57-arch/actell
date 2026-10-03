/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bridge_zlib.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h> /* Independent host zlib oracle; not the vendored headers. */

typedef struct {
    void *pointers[BRIDGE_ZLIB_MAX_ALLOCATIONS];
    size_t sizes[BRIDGE_ZLIB_MAX_ALLOCATIONS];
    size_t attempts, count, frees, live, peak, fail_at;
} heap_tracker;
/* Linker wrappers make any accidental process-global allocator fallback fatal
 * during custom-allocator calls. Test backing blocks use __real_malloc/free. */
void *__real_malloc(size_t);
void *__real_calloc(size_t, size_t);
void *__real_realloc(void *, size_t);
void __real_free(void *);
static bool forbid_global;
void *__wrap_malloc(size_t n) { assert(!forbid_global); return __real_malloc(n); }
void *__wrap_calloc(size_t n, size_t s) { assert(!forbid_global); return __real_calloc(n, s); }
void *__wrap_realloc(void *p, size_t n) { assert(!forbid_global); return __real_realloc(p, n); }
void __wrap_free(void *p) { assert(!forbid_global); __real_free(p); }

static void *tracked_allocate(void *opaque, size_t bytes) {
    heap_tracker *heap = opaque;
    size_t attempt = heap->attempts++;
    if (attempt == heap->fail_at) return NULL;
    assert(bytes <= BRIDGE_ZLIB_MEMORY_BUDGET - heap->live);
    for (size_t i = 0; i < BRIDGE_ZLIB_MAX_ALLOCATIONS; ++i) {
        if (heap->pointers[i]) continue;
        void *p = __real_malloc(bytes); assert(p);
        memset(p, 0xa5, bytes); /* Adapter must handle nonzero memory. */
        heap->pointers[i] = p; heap->sizes[i] = bytes;
        heap->live += bytes; ++heap->count;
        if (heap->live > heap->peak) heap->peak = heap->live;
        return p;
    }
    assert(false); return NULL;
}
static void tracked_release(void *opaque, void *p) {
    heap_tracker *heap = opaque;
    for (size_t i = 0; i < BRIDGE_ZLIB_MAX_ALLOCATIONS; ++i) {
        if (heap->pointers[i] != p) continue;
        memset(p, 0x5a, heap->sizes[i]);
        __real_free(p); heap->pointers[i] = NULL;
        heap->live -= heap->sizes[i]; ++heap->frees; return;
    }
    assert(false); /* Includes double free and wrong allocator context. */
}
static bridge_zlib_config config_for(heap_tracker *heap, bridge_zlib_stats *stats) {
    return (bridge_zlib_config){BRIDGE_ZLIB_MEMORY_BUDGET,
        tracked_allocate, tracked_release, heap, stats};
}
static void reclaimed(const heap_tracker *heap, const bridge_zlib_stats *stats) {
    assert(heap->live == 0 && stats->live_bytes == 0);
    assert(heap->count == heap->frees && stats->allocations == stats->frees);
    assert(stats->allocations == heap->count && stats->peak_bytes == heap->peak);
    assert(stats->peak_bytes <= BRIDGE_ZLIB_MEMORY_BUDGET);
    for (size_t i = 0; i < BRIDGE_ZLIB_MAX_ALLOCATIONS; ++i) assert(!heap->pointers[i]);
}
static uint32_t random32(uint32_t *state) {
    *state = *state * UINT32_C(1664525) + UINT32_C(1013904223);
    return *state;
}
static void compare(const uint8_t *source, size_t n, const uint8_t *out, size_t len) {
    uint8_t expected[BRIDGE_MEDIA_COMPRESSED_MAX], decoded[BRIDGE_MEDIA_VIDEO_PROTO_MAX];
    uLongf expected_size = sizeof expected, decoded_size = sizeof decoded;
    assert(compress2(expected, &expected_size, source, (uLong)n, 9) == Z_OK);
    assert(expected_size == len && !memcmp(expected, out, len));
    assert(uncompress(decoded, &decoded_size, out, (uLong)len) == Z_OK);
    assert(decoded_size == n && !memcmp(decoded, source, n));
}
static size_t baseline(uint8_t *source, size_t n) {
    uint8_t out[BRIDGE_MEDIA_COMPRESSED_MAX]; size_t size = 999;
    heap_tracker heap = {.fail_at = SIZE_MAX}; bridge_zlib_stats stats;
    bridge_zlib_config config = config_for(&heap, &stats);
    forbid_global = true;
    assert(bridge_zlib_compress(&config, source, n, out, sizeof out, &size) == BRIDGE_OK);
    forbid_global = false;
    reclaimed(&heap, &stats); compare(source, n, out, size);
    assert(stats.allocations == 5 && stats.zlib_status == Z_STREAM_END);
    printf("zlib host peak: %zu bytes in %zu allocations (budget %u)\n",
        stats.peak_bytes, stats.allocations, BRIDGE_ZLIB_MEMORY_BUDGET);
    return stats.peak_bytes;
}
static void failure_tests(uint8_t *source, size_t n, size_t peak) {
    uint8_t out[BRIDGE_MEDIA_COMPRESSED_MAX]; size_t size;
    for (size_t fail = 0; fail < 5; ++fail) {
        heap_tracker heap = {.fail_at = fail}; bridge_zlib_stats stats;
        bridge_zlib_config config = config_for(&heap, &stats); size = 999;
        forbid_global = true;
        assert(bridge_zlib_compress(&config, source, n, out, sizeof out, &size) == BRIDGE_E_LIMIT);
        forbid_global = false;
        assert(size == 0 && stats.allocation_failures > 0); reclaimed(&heap, &stats);
    }
    const size_t budgets[] = {0, 1, 1024, 65535, 65536, 131072, 262144, peak - 1, peak,
                             BRIDGE_ZLIB_MEMORY_BUDGET, BRIDGE_ZLIB_MEMORY_BUDGET + 1u, SIZE_MAX};
    for (size_t i = 0; i < sizeof budgets / sizeof budgets[0]; ++i) {
        heap_tracker heap = {.fail_at = SIZE_MAX}; bridge_zlib_stats stats;
        bridge_zlib_config config = config_for(&heap, &stats); config.memory_budget = budgets[i];
        size = 999; forbid_global = true;
        bridge_status status = bridge_zlib_compress(&config, source, n, out, sizeof out, &size);
        forbid_global = false;
        bool success = budgets[i] >= peak && budgets[i] <= BRIDGE_ZLIB_MEMORY_BUDGET;
        assert(status == (success ? BRIDGE_OK : BRIDGE_E_LIMIT));
        assert(success ? size > 0 : size == 0); reclaimed(&heap, &stats);
        if (budgets[i] > BRIDGE_ZLIB_MEMORY_BUDGET) assert(heap.attempts == 0);
        if (success) compare(source, n, out, size);
    }
}
static void argument_tests(void) {
    uint8_t bytes[600] = {0}, out[600]; size_t size = 999;
    heap_tracker heap = {.fail_at = SIZE_MAX}; bridge_zlib_stats stats;
    bridge_zlib_config config = config_for(&heap, &stats);
    assert(bridge_zlib_compress(&config, NULL, 0, out, sizeof out, &size) == BRIDGE_E_ARGUMENT && size == 0);
    size = 999;
    assert(bridge_zlib_compress(&config, bytes, 1, NULL, 0, &size) == BRIDGE_E_ARGUMENT && size == 0);
    assert(bridge_zlib_compress(&config, bytes, 1, out, sizeof out, NULL) == BRIDGE_E_ARGUMENT);
    for (size_t n = 385; n <= 600; ++n) {
        size = 999;
        assert(bridge_zlib_compress(&config, bytes, n, out, sizeof out, &size) == BRIDGE_E_LIMIT && size == 0);
    }
    size = 999;
    assert(bridge_zlib_compress(&config, bytes, SIZE_MAX, out, sizeof out, &size) == BRIDGE_E_LIMIT && size == 0);
    assert(bridge_zlib_compress(&config, bytes, 5, bytes, 500, &size) == BRIDGE_E_ARGUMENT && size == 0);
    assert(bridge_zlib_compress(&config, bytes, 5, bytes + 4, 500, &size) == BRIDGE_E_ARGUMENT && size == 0);
    assert(bridge_zlib_compress(&config, bytes + 4, 5, bytes, 500, &size) == BRIDGE_E_ARGUMENT && size == 0);
    config.release = NULL;
    assert(bridge_zlib_compress(&config, bytes, 1, out, sizeof out, &size) == BRIDGE_E_ARGUMENT && size == 0);
    config.allocate = NULL; config.release = tracked_release;
    assert(bridge_zlib_compress(&config, bytes, 1, out, sizeof out, &size) == BRIDGE_E_ARGUMENT && size == 0);
    assert(heap.attempts == 0);
    assert(bridge_zlib_compress(NULL, bytes, 0, out, SIZE_MAX, &size) == BRIDGE_OK);
    compare(bytes, 0, out, size);
}
static void fuzz_calls(void) {
    uint32_t random = UINT32_C(0x13579bdf);
    for (size_t i = 0; i < 5000; ++i) {
        uint8_t input[384], out[600]; size_t size = 999;
        size_t n = random32(&random) % 385u;
        for (size_t k = 0; k < n; ++k) input[k] = (uint8_t)(random32(&random) >> 24);
        if (i % 3 == 0) memset(input, (int)(i & 255u), n);
        size_t cap = random32(&random) % 601u;
        heap_tracker heap = {.fail_at = i % 7 == 0 ? (i % 5) : SIZE_MAX};
        bridge_zlib_stats stats; bridge_zlib_config config = config_for(&heap, &stats);
        if (i % 11 == 0) config.memory_budget = random32(&random) % BRIDGE_ZLIB_MEMORY_BUDGET;
        memset(out, 0xa5, sizeof out); forbid_global = true;
        bridge_status status = bridge_zlib_compress(&config, input, n, out, cap, &size);
        forbid_global = false;
        reclaimed(&heap, &stats); assert(stats.peak_bytes <= config.memory_budget);
        assert(status == BRIDGE_OK || status == BRIDGE_E_LIMIT);
        if (status == BRIDGE_OK) { assert(size <= cap && size <= 512); compare(input, n, out, size); }
        else assert(size == 0);
        for (size_t k = cap < 512 ? cap : 512; k < sizeof out; ++k) assert(out[k] == 0xa5);
    }
}
static void *thread_offers(void *arg) {
    uint32_t seed = (uint32_t)(uintptr_t)arg;
    for (size_t i = 0; i < 400; ++i) {
        uint8_t uuid[16] = {0}, out[1024], raw[384]; size_t size, raw_size;
        uint32_t session = random32(&seed);
        heap_tracker heap = {.fail_at = SIZE_MAX}; bridge_zlib_stats stats;
        bridge_zlib_config config = config_for(&heap, &stats);
        assert(bridge_media_video_offer(session, uuid, bridge_zlib_compress, &config,
            out, sizeof out, &size) == BRIDGE_OK);
        assert(size <= sizeof out); reclaimed(&heap, &stats);
        assert(bridge_media_video_protobuf(session, raw, sizeof raw, &raw_size) == BRIDGE_OK);
        heap = (heap_tracker){.fail_at = SIZE_MAX};
        assert(bridge_zlib_compress(&config, raw, raw_size, out, sizeof out, &size) == BRIDGE_OK);
        reclaimed(&heap, &stats); compare(raw, raw_size, out, size);
    }
    return NULL;
}
int main(void) {
    uint8_t raw[BRIDGE_MEDIA_VIDEO_PROTO_MAX], output[600]; size_t n = 0, size = 0;
    assert(bridge_media_video_protobuf(UINT32_MAX, raw, sizeof raw, &n) == BRIDGE_OK);
    size_t peak = baseline(raw, n);
    failure_tests(raw, n, peak); argument_tests();
    uint8_t expected[512]; size_t expected_size;
    assert(bridge_zlib_compress(NULL, raw, n, expected, sizeof expected, &expected_size) == BRIDGE_OK);
    for (size_t cap = 0; cap <= sizeof output; ++cap) {
        memset(output, 0xa5, sizeof output); size = 999;
        heap_tracker heap = {.fail_at = SIZE_MAX}; bridge_zlib_stats stats;
        bridge_zlib_config config = config_for(&heap, &stats);
        bridge_status status = bridge_zlib_compress(&config, raw, n, output, cap, &size);
        assert(status == (cap < expected_size ? BRIDGE_E_LIMIT : BRIDGE_OK));
        assert(size == (cap < expected_size ? 0 : expected_size));
        if (status == BRIDGE_OK) assert(!memcmp(expected, output, size));
        reclaimed(&heap, &stats);
        for (size_t k = cap < 512 ? cap : 512; k < sizeof output; ++k) assert(output[k] == 0xa5);
    }
    fuzz_calls();
    pthread_t threads[4];
    for (uintptr_t i = 0; i < 4; ++i) assert(pthread_create(&threads[i], NULL, thread_offers, (void *)(i + 1u)) == 0);
    for (size_t i = 0; i < 4; ++i) assert(pthread_join(threads[i], NULL) == 0);
    puts("Vendored zlib: allocator faults, exact budgets, all capacities, 5000 bounded fuzz calls and 4 concurrent callers passed");
    return 0;
}
