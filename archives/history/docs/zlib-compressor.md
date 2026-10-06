# Bounded level-9 zlib media-offer compressor

`firmware/components/bridge_zlib` is an actual ESP-IDF component backed by
unmodified upstream zlib 1.3.2 source. It implements the existing
`bridge_media_compress_fn` callback. This resolves the missing compression
implementation for local offer serialization; it does **not** establish a live
media session or prove that any iPhone accepts an offer.

## Usage

Add `bridge_zlib` to the calling ESP-IDF component's `REQUIRES`, include
`bridge_zlib.h`, then pass `bridge_zlib_compress` and `NULL` as the compressor
and compressor context to `bridge_media_video_offer`.

```c
#include "bridge_zlib.h"

size_t offer_size = 0;
bridge_status status = bridge_media_video_offer(
    session_id, call_uuid, bridge_zlib_compress, NULL,
    offer, sizeof offer, &offer_size);
if (status != BRIDGE_OK) {
    /* Discard all partial output; offer_size is zero. */
}
```

The calling component must provide the fresh session/call identifiers and own
session authorization. No randomness, device access, network I/O, logging of
identities, or global allocator changes occur here.

Optional per-call settings use `bridge_zlib_config` initialized with
`BRIDGE_ZLIB_CONFIG_DEFAULT`. The configuration can lower the allocation budget,
provide a paired allocator/release callback and opaque context, and collect
`bridge_zlib_stats`. A zero budget deliberately refuses allocations; a budget
greater than the fixed maximum is rejected. Caller callbacks must obey
malloc/free alignment, ownership, and lifetime semantics. All zlib allocations
are zeroed by the adapter, even when the backing allocator returns dirty memory.

## Wire format and bounds

The exact invocation is `deflateInit2(..., 9, Z_DEFLATED, 15, 8,
Z_DEFAULT_STRATEGY)` followed by `deflate(..., Z_FINISH)`. The result is a zlib
wrapper with header `78 da` and Adler-32 checksum. There is no preset dictionary,
raw/gzip mode, retry at a lower compression level, or hand-written stored-block
replacement. Upstream zlib may itself select any valid DEFLATE block type under
its ordinary level-9 algorithm.

- Input is limited to 384 bytes, including the default-video protobuf
- Output is limited to `min(caller_capacity, 512)` bytes, even if the caller
  advertises a larger buffer
- Source/destination overlap is rejected; configuration, stats and size storage
  must also be separate from those buffers
- Empty input is valid with a non-NULL input pointer
- All failures leave output size zero; any partially written bytes are invalid
- Memory exhaustion, budget refusal and output exhaustion return `BRIDGE_E_LIMIT`
- Invalid pointers/callback pairs and detected overlap return `BRIDGE_E_ARGUMENT`
- Unexpected upstream compressor/cleanup errors return `BRIDGE_E_IO`

Each invocation owns a local `z_stream`, configuration copy, statistics, and
fixed eight-entry allocation tracker. There are no global allocator hooks,
retained workspaces, dynamic pools, or fallback algorithms. `deflateEnd` is
called whenever state remains; a final tracked-block sweep defensively releases
any allocation left by an unexpected upstream cleanup path. An unexpected
cleanup path fails rather than returning apparently valid output.

## Memory on ESP32-S3

The default ESP-IDF backing allocator is exclusively
`heap_caps_malloc(bytes, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT)` with
`heap_caps_free`. Missing/unavailable PSRAM returns a limit failure. It does not
fall back to internal RAM and this component does not enable PSRAM in board
configuration. Hardware initialization belongs to the application.

A hard per-invocation limit of 393,216 bytes (384 KiB) covers the total live
allocation sizes requested by zlib. Host x86-64 tests measured 268,112 bytes
across five allocations at the fixed parameters. Target structure sizes can
differ, so this is a host measurement, not an on-board RAM claim. Allocator
bookkeeping, stack frames, and the caller's input/output buffers are additional
to this payload budget. The maximum number of simultaneously tracked heap blocks
is eight; the current zlib configuration uses five.

Calls are reentrant with independent stats/allocator state. Shared custom
allocators must be thread safe. Call from normal task context, not an ISR. This
small, bounded media-offer encoder is not a video-frame codec, decompressor,
arbitrary-input service, or streaming compression API.

## Pinned upstream source and license

Verified on 2026-10-02 using the [official zlib homepage](https://zlib.net/) and
[canonical release page](https://github.com/madler/zlib/releases/tag/v1.3.2):

- Stable release: zlib 1.3.2, released 2026-02-17
- Upstream tag commit: `da607da739fa6047df13e66a2af6b8bec7c2a498`
- Archive: `https://zlib.net/zlib-1.3.2.tar.gz`
- Published and locally verified SHA-256:
  `bb329a0a2cd0274d05519d61c667c062e06990d72e125ee2dfa8de64f0119d16`

The archive was verified before extraction. Only `adler32.c`, `deflate.c`,
`deflate.h`, `trees.c`, `trees.h`, `zconf.h`, `zlib.h`, `zutil.c`, `zutil.h`,
`LICENSE`, and `README` are vendored. Every file is byte-for-byte upstream;
per-file SHA-256 and sizes are recorded in
`firmware/components/bridge_zlib/vendor/SOURCE_MANIFEST.json`. No upstream build,
install, configure, or helper scripts were executed.

The four upstream compilation units use `Z_SOLO`, `Z_PREFIX`, and `NO_GZIP`:
explicit allocators are mandatory, normal zlib entry points are prefixed, and
gzip/CRC/file-I/O dependencies are absent. No inflate, gz*, minizip, examples,
executables, or upstream build tools are included. Vendor headers are private to
the component. The upstream zlib license and source notices remain intact; the
adapter/tests/documentation are project code under GPL-3.0-or-later.

## Verification

Run `./tools/test_zlib.sh` from the repository root. It compiles the actual
vendored implementation, not a system-zlib substitute for the callback.
Independent host zlib and Python zlib are used only as test oracles.

Passed in the dot cloud environment on 2026-10-02:

1. Every vendored-file SHA-256 and byte size matches the provenance manifest
2. Byte-identical Python `zlib.compress(..., 9)` output for all 385 input
   lengths from 0 through 384, each with random, zero, and patterned input
3. All 265 default-video offers are byte-identical to pinned upstream
   pymobiledevice3, including compressed payload, complete bplist and UUID
4. Every output capacity from 0 through 600, with untouched guard bytes after
   the effective output limit
5. Allocation failure injected at each of the five upstream allocation sites,
   zero/small/exact/one-byte-short/excessive budgets, and all tracked blocks freed
6. 5,000 deterministic bounded fuzz calls combining input, capacity, budget and
   allocation failures, plus four concurrent callers doing 400 offer/direct
   compression pairs each
7. ASan and UBSan over the real adapter and vendored sources; linker-wrapped
   malloc/calloc/realloc/free reject accidental global allocation fallback during
   custom-allocator tests
8. The ESP allocator source branch under a host-only heap shim verifies exactly
   the PSRAM/8BIT capabilities, absent-PSRAM failure and each allocation failure
9. Actual ESP-IDF 5.5.5 / ESP32-S3 cross-compilation of the complete component to
   `firmware/build/esp-idf/bridge_zlib/libbridge_zlib.a`

LeakSanitizer was attempted but cannot operate under this executor's ptrace
restriction. It is disabled by default in the script; allocation/free accounting
assertions cover every exercised call. On a compatible host, set
`ASAN_OPTIONS=detect_leaks=1:halt_on_error=1` to also run LSan.

The focused cross-build used official ESP-IDF environment setup, `idf.py
reconfigure`, and `ninja -C firmware/build esp-idf/bridge_zlib/libbridge_zlib.a`.
It is a component compile check, not a claim about the aggregate firmware image.
No firmware was flashed, no device/USB port was activated, and real PSRAM
behavior, on-board latency/stack consumption, and live iPhone acceptance remain
unverified.
