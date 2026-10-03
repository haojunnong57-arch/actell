/* SPDX-License-Identifier: GPL-3.0-or-later
 * Protocol serializer derived from:
 * https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/remote/core_device/media_stream_offer.py
 * Fixed protocol defaults are kept verbatim; dynamic IDs are serialized.
 */
#include "bridge_media_offer.h"
#include <string.h>

typedef struct { uint8_t *data; size_t size, capacity; bool failed; } writer;
static void bytes(writer *w, const void *p, size_t n) {
    if (w->failed) return;
    if (n > w->capacity - w->size) { w->failed = true; return; }
    if (n) memcpy(w->data + w->size, p, n);
    w->size += n;
}
static void byte(writer *w, uint8_t v) { bytes(w, &v, 1); }
static void varint(writer *w, uint64_t v) {
    do { uint8_t b = (uint8_t)(v & 127u); v >>= 7;
        if (v) b |= 128u;
        byte(w, b);
    } while (v);
}
static void field_int(writer *w, unsigned field, uint64_t v) {
    varint(w, (uint64_t)field << 3); varint(w, v);
}
static void field_bytes(writer *w, unsigned field, const void *p, size_t n) {
    varint(w, ((uint64_t)field << 3) | 2u); varint(w, n); bytes(w, p, n);
}
static void field_string(writer *w, unsigned field, const char *s) {
    field_bytes(w, field, s, strlen(s));
}
static void be(writer *w, uint64_t v, unsigned n) {
    while (n) { --n; byte(w, (uint8_t)(v >> (8u * n))); }
}
static bridge_status finish(writer *w, size_t *out_size) {
    if (w->failed) return BRIDGE_E_LIMIT;
    *out_size = w->size; return BRIDGE_OK;
}
static void codec_bank(writer *out, unsigned pt, unsigned f4, unsigned pairs) {
    uint8_t bank[96]; writer w = {bank, 0, sizeof bank, false};
    field_int(&w, 1, pt);
    for (unsigned i = 0; i < pairs; ++i) {
        uint8_t entry[16]; writer e = {entry, 0, sizeof entry, false};
        field_int(&e, 1, 1); field_int(&e, 2, 1u + i % 2u);
        field_int(&e, 3, 50115); field_int(&e, 4, 0);
        if (e.failed) { out->failed = true; return; }
        field_bytes(&w, 2, entry, e.size);
    }
    field_string(&w, 3, "FLS;SW:1;"); field_int(&w, 4, f4);
    if (w.failed) { out->failed = true; return; }
    field_bytes(out, 3, bank, w.size);
}
bridge_status bridge_media_video_protobuf(uint32_t session_id,
    uint8_t *out, size_t capacity, size_t *out_size) {
    if (out_size) *out_size = 0;
    if (!out || !out_size) return BRIDGE_E_ARGUMENT;
    uint8_t settings[160]; writer s = {settings, 0, sizeof settings, false};
    byte(&s, 8); /* f1, five-byte padded uint32 varint, including zero. */
    for (unsigned i = 0; i < 5; ++i) {
        uint8_t v = (uint8_t)((session_id >> (7u * i)) & 127u);
        if (i != 4) v |= 128u;
        byte(&s, v);
    }
    field_int(&s, 2, 0); codec_bank(&s, 123, 1, 4); codec_bank(&s, 100, 14, 2);
    field_int(&s, 7, 0); field_int(&s, 8, 63); field_int(&s, 10, 1); field_int(&s, 12, 1);
    if (s.failed) return BRIDGE_E_LIMIT;
    writer w = {out, 0, capacity, false};
    field_int(&w, 1, 1); field_int(&w, 2, 1); field_bytes(&w, 5, settings, s.size);
    field_string(&w, 6, "Viceroy 1.7.0"); field_int(&w, 8, 0);
    static const uint32_t tiers[10][3] = {
        {4074, 0, 16384}, {0, 75000000, 524288}, {0, 40000000, 12288},
        {16, 4100, 0}, {0, 20000000, 98304}, {4, 6500, 0},
        {0, 6000000, 131072}, {0, 100000000, 1048576},
        {0, 60000000, 262144}, {1, 299, 0}
    };
    for (unsigned i = 0; i < 10; ++i) {
        uint8_t tier[24]; writer t = {tier, 0, sizeof tier, false};
        field_int(&t, 1, tiers[i][0]); field_int(&t, 2, tiers[i][1]);
        if (tiers[i][2]) field_int(&t, 3, tiers[i][2]);
        if (t.failed) return BRIDGE_E_LIMIT;
        field_bytes(&w, 9, tier, t.size);
    }
    field_int(&w, 13, UINT64_C(17137042128614416384));
    field_int(&w, 14, 2); field_int(&w, 16, 0); field_int(&w, 18, 1);
    return finish(&w, out_size);
}
static void plist_blob(writer *w, unsigned type, const void *p, size_t n) {
    if (n < 15) byte(w, (uint8_t)((type << 4) | n));
    else {
        byte(w, (uint8_t)((type << 4) | 15u));
        if (n <= 255) { byte(w, 0x10); byte(w, (uint8_t)n); }
        else if (n <= 65535) { byte(w, 0x11); be(w, n, 2); }
        else { w->failed = true; return; }
    }
    bytes(w, p, n);
}
bridge_status bridge_media_video_offer(uint32_t session_id,
    const uint8_t call_uuid[16], bridge_media_compress_fn compressor,
    void *compressor_context, uint8_t *out, size_t capacity, size_t *out_size) {
    if (out_size) *out_size = 0;
    if (!call_uuid || !out || !out_size || !compressor) return BRIDGE_E_ARGUMENT;
    uint8_t raw[BRIDGE_MEDIA_VIDEO_PROTO_MAX], compressed[BRIDGE_MEDIA_COMPRESSED_MAX] = {0};
    size_t raw_size = 0, compressed_size = 0;
    bridge_status status = bridge_media_video_protobuf(session_id, raw, sizeof raw, &raw_size);
    if (status != BRIDGE_OK) return status;
    status = compressor(compressor_context, raw, raw_size, compressed, sizeof compressed, &compressed_size);
    if (status != BRIDGE_OK) return status;
    if (compressed_size > sizeof compressed) return BRIDGE_E_LIMIT;
    if (compressed_size < 6) return BRIDGE_E_FORMAT;
    /* Require a zlib-wrapped DEFLATE stream, no preset dictionary, FLEVEL=3.
     * This is structural screening, not a decoder or acceptance validation. */
    if (compressed[0] != 0x78 || compressed[1] != 0xda) return BRIDGE_E_FORMAT;
    uint8_t endpoint[64]; writer e = {endpoint, 0, sizeof endpoint, false};
    field_int(&e, 1, 0); field_int(&e, 2, 1); field_string(&e, 3, "Mac15,9");
    field_string(&e, 4, "2205.3.1"); field_string(&e, 5, "25F80");
    if (e.failed) return BRIDGE_E_LIMIT;
    char uuid[36]; static const char hex[] = "0123456789ABCDEF";
    size_t u = 0;
    for (size_t i = 0; i < 16; ++i) {
        if (i == 4 || i == 6 || i == 8 || i == 10) uuid[u++] = '-';
        uuid[u++] = hex[call_uuid[i] >> 4]; uuid[u++] = hex[call_uuid[i] & 15u];
    }
    static const char *const keys[4] = {
        "avcMediaStreamNegotiatorMediaBlob", "avcMediaStreamNegotiatorMode",
        "avcMediaStreamOptionCallID", "avcMediaStreamOptionRemoteEndpointInfo"
    };
    size_t offsets[9]; writer w = {out, 0, capacity, false};
    bytes(&w, "bplist00", 8); offsets[0] = w.size;
    static const uint8_t dictionary[] = {0xd4, 1, 2, 3, 4, 5, 6, 7, 8};
    bytes(&w, dictionary, sizeof dictionary);
    for (size_t i = 0; i < 4; ++i) {
        offsets[i + 1] = w.size; plist_blob(&w, 5, keys[i], strlen(keys[i]));
    }
    offsets[5] = w.size; plist_blob(&w, 4, compressed, compressed_size);
    offsets[6] = w.size; byte(&w, 0x10); byte(&w, 5);
    offsets[7] = w.size; plist_blob(&w, 5, uuid, sizeof uuid);
    offsets[8] = w.size; plist_blob(&w, 4, endpoint, e.size);
    size_t table = w.size;
    for (size_t i = 0; i < 9; ++i) be(&w, offsets[i], 2);
    be(&w, 0, 6); byte(&w, 2); byte(&w, 1);
    be(&w, 9, 8); be(&w, 0, 8); be(&w, table, 8);
    return finish(&w, out_size);
}
