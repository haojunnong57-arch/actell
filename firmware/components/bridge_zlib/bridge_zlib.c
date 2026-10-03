/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bridge_zlib.h"
#include "zlib.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#ifdef ESP_PLATFORM
#include "esp_heap_caps.h"
#endif

#if !defined(Z_SOLO) || !defined(Z_PREFIX) || !defined(NO_GZIP)
#error "bridge_zlib requires the isolated vendored Z_SOLO/Z_PREFIX/NO_GZIP build"
#endif
#if defined(FASTEST) || defined(FORCE_STORED) || defined(FORCE_STATIC) || defined(LIT_MEM)
#error "Non-default zlib compression or memory tuning is unsupported"
#endif
_Static_assert(BRIDGE_MEDIA_VIDEO_PROTO_MAX <= UINT_MAX, "zlib input width");
_Static_assert(BRIDGE_MEDIA_COMPRESSED_MAX <= UINT_MAX, "zlib output width");

typedef struct { void *pointer; size_t bytes; } allocation;
typedef struct {
    bridge_zlib_config config;
    bridge_zlib_stats stats;
    allocation blocks[BRIDGE_ZLIB_MAX_ALLOCATIONS];
    bool bad_free;
} invocation;

static void *default_allocate(void *context, size_t bytes) {
    (void)context;
#ifdef ESP_PLATFORM
    return heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
#else
    return malloc(bytes);
#endif
}
static void default_release(void *context, void *pointer) {
    (void)context;
#ifdef ESP_PLATFORM
    heap_caps_free(pointer);
#else
    free(pointer);
#endif
}

static voidpf bounded_allocate(voidpf opaque, uInt items, uInt size) {
    invocation *call = opaque;
    if (items == 0 || size == 0 || (size_t)items > SIZE_MAX / (size_t)size)
        goto refused;
    size_t bytes = (size_t)items * (size_t)size;
    if (bytes > call->config.memory_budget - call->stats.live_bytes)
        goto refused;
    for (size_t i = 0; i < BRIDGE_ZLIB_MAX_ALLOCATIONS; ++i) {
        if (call->blocks[i].pointer) continue;
        void *pointer = call->config.allocate(call->config.allocator_context, bytes);
        if (!pointer) goto refused;
        memset(pointer, 0, bytes);
        call->blocks[i] = (allocation){pointer, bytes};
        call->stats.live_bytes += bytes;
        if (call->stats.live_bytes > call->stats.peak_bytes)
            call->stats.peak_bytes = call->stats.live_bytes;
        ++call->stats.allocations;
        return pointer;
    }
refused:
    ++call->stats.allocation_failures;
    return Z_NULL;
}
static void bounded_release(voidpf opaque, voidpf pointer) {
    invocation *call = opaque;
    if (!pointer) return;
    for (size_t i = 0; i < BRIDGE_ZLIB_MAX_ALLOCATIONS; ++i) {
        if (call->blocks[i].pointer != pointer) continue;
        call->config.release(call->config.allocator_context, pointer);
        call->stats.live_bytes -= call->blocks[i].bytes;
        call->blocks[i] = (allocation){0};
        ++call->stats.frees;
        return;
    }
    call->bad_free = true;
}
/* Difference-based ranges avoid overflowing pointer + size. Caller still
 * supplies valid readable/writable buffers of the stated lengths. */
static bool overlapping(const uint8_t *source, size_t n, const uint8_t *out, size_t cap) {
    if (n == 0 || cap == 0) return false;
    uintptr_t a = (uintptr_t)source, b = (uintptr_t)out;
    return a <= b ? b - a < n : a - b < cap;
}
bridge_status bridge_zlib_compress(void *context, const uint8_t *source,
    size_t source_size, uint8_t *destination, size_t destination_capacity,
    size_t *destination_size) {
    if (destination_size) *destination_size = 0;
    invocation call = {.config = BRIDGE_ZLIB_CONFIG_DEFAULT};
    if (context) call.config = *(const bridge_zlib_config *)context;
    if (call.config.stats) *call.config.stats = (bridge_zlib_stats){0};
    if (!source || !destination || !destination_size) return BRIDGE_E_ARGUMENT;
    if ((call.config.allocate == NULL) != (call.config.release == NULL))
        return BRIDGE_E_ARGUMENT;
    if (source_size > BRIDGE_MEDIA_VIDEO_PROTO_MAX ||
        call.config.memory_budget > BRIDGE_ZLIB_MEMORY_BUDGET)
        return BRIDGE_E_LIMIT;
    size_t capacity = destination_capacity < BRIDGE_MEDIA_COMPRESSED_MAX ?
        destination_capacity : BRIDGE_MEDIA_COMPRESSED_MAX;
    if (overlapping(source, source_size, destination, capacity)) return BRIDGE_E_ARGUMENT;
    if (capacity == 0) return BRIDGE_E_LIMIT;
    if (!call.config.allocate) {
        call.config.allocate = default_allocate;
        call.config.release = default_release;
    }
    z_stream stream = {0};
    stream.zalloc = bounded_allocate;
    stream.zfree = bounded_release;
    stream.opaque = &call;
    int result = deflateInit2(&stream, 9, Z_DEFLATED, 15, 8, Z_DEFAULT_STRATEGY);
    bridge_status status = BRIDGE_E_IO;
    if (result == Z_OK) {
        /* Upstream's non-const next_in API does not modify input. */
        stream.next_in = (Bytef *)(uintptr_t)source;
        stream.avail_in = (uInt)source_size;
        stream.next_out = destination;
        stream.avail_out = (uInt)capacity;
        result = deflate(&stream, Z_FINISH);
        if (result == Z_STREAM_END && stream.avail_in == 0 &&
            stream.total_out <= capacity && stream.total_out >= 6 &&
            destination[0] == 0x78 && destination[1] == 0xda) {
            status = BRIDGE_OK;
        } else if (result == Z_OK || result == Z_BUF_ERROR || result == Z_MEM_ERROR) {
            status = BRIDGE_E_LIMIT;
        }
    } else if (result == Z_MEM_ERROR) {
        status = BRIDGE_E_LIMIT;
    }
    call.stats.zlib_status = result;
    size_t produced = (size_t)stream.total_out;
    if (stream.state != Z_NULL) {
        int ended = deflateEnd(&stream);
        /* An unfinished stream may return Z_DATA_ERROR after releasing its
         * state. Preserve the original output-limit failure in that case. */
        if (status == BRIDGE_OK && ended != Z_OK) status = BRIDGE_E_IO;
    }
    /* Defense in depth for future upstream changes: reclaim any tracked
     * allocation even if an unexpected initialization/end path left it live. */
    if (call.stats.live_bytes != 0 || call.bad_free) status = BRIDGE_E_IO;
    for (size_t i = 0; i < BRIDGE_ZLIB_MAX_ALLOCATIONS; ++i)
        if (call.blocks[i].pointer) bounded_release(&call, call.blocks[i].pointer);
    if (call.config.stats) *call.config.stats = call.stats;
    if (status == BRIDGE_OK) *destination_size = produced;
    return status;
}
