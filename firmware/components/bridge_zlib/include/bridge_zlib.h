/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_ZLIB_H
#define BRIDGE_ZLIB_H
#include "bridge_media_offer.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Total requested zlib heap bytes per invocation, never a global pool.
 * Heap allocator bookkeeping and this function's bounded stack are additional.
 * A custom configuration may lower this limit, but cannot increase it. */
#define BRIDGE_ZLIB_MEMORY_BUDGET (384u * 1024u)
#define BRIDGE_ZLIB_MAX_ALLOCATIONS 8u

typedef void *(*bridge_zlib_alloc_fn)(void *context, size_t bytes);
typedef void (*bridge_zlib_free_fn)(void *context, void *pointer);

typedef struct {
    size_t peak_bytes;
    size_t live_bytes;       /* Zero after every return. */
    size_t allocations;
    size_t frees;
    size_t allocation_failures;
    int zlib_status;         /* Z_OK before zlib is called; last work status. */
} bridge_zlib_stats;

typedef struct {
    size_t memory_budget;    /* Zero deliberately disallows any allocation. */
    bridge_zlib_alloc_fn allocate;
    bridge_zlib_free_fn release;
    void *allocator_context;
    bridge_zlib_stats *stats;
} bridge_zlib_config;

#define BRIDGE_ZLIB_CONFIG_DEFAULT \
    { BRIDGE_ZLIB_MEMORY_BUDGET, NULL, NULL, NULL, NULL }

/* Matches bridge_media_compress_fn exactly. NULL context uses the defaults;
 * otherwise context points to a bridge_zlib_config valid for the entire call.
 * Both allocator callbacks must be supplied together or both must be NULL.
 * They must have malloc/free semantics, return suitably aligned distinct live
 * blocks, never retain input/output pointers, and be thread safe if shared.
 * Memory is zeroed by this adapter even when the allocator returns dirty bytes.
 *
 * Default ESP-IDF allocator: MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT, no internal
 * RAM fallback. No PSRAM or failed allocation returns BRIDGE_E_LIMIT.
 * Default host allocator: malloc/free, useful only for verification.
 *
 * Exactly zlib level=9, DEFLATED, windowBits=15, memLevel=8, default strategy;
 * no dictionary, raw DEFLATE, gzip, fallback level, or substitute encoder.
 * Input must be non-NULL and <= BRIDGE_MEDIA_VIDEO_PROTO_MAX (384) bytes.
 * At most min(destination_capacity, BRIDGE_MEDIA_COMPRESSED_MAX=512) bytes
 * are written; a larger destination capacity never raises this limit.
 * Input, output, out-size, configuration and stats storage must not overlap.
 * Input/output overlap is detected and rejected. Empty input is supported.
 * On every error, destination_size is zero and partial output is invalid.
 * No allocation survives the call, including initialization/output failures.
 *
 * Reentrant with independent stats/allocator state; call from task context,
 * not an ISR. This prepares a small local media offer, not a stream codec or
 * an untrusted-data decompressor, and never starts hardware or a session. */
bridge_status bridge_zlib_compress(void *context, const uint8_t *source,
    size_t source_size, uint8_t *destination, size_t destination_capacity,
    size_t *destination_size);

#ifdef __cplusplus
}
#endif
#endif
