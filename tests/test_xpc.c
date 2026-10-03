/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bridge_xpc.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    const bridge_xpc_object *root;
    uint32_t flags;
    uint64_t message_id;
    const uint8_t *wire;
    size_t size;
} fixture;
#include "xpc_fixtures.h"

static void semantic_equal(const bridge_xpc_object *obj, const bridge_xpc_view *view) {
    assert(obj->type == view->type);
    switch (obj->type) {
        case BRIDGE_XPC_NULL: assert(view->size == 0); break;
        case BRIDGE_XPC_BOOL: {
            bool value = false;
            assert(bridge_xpc_bool(view, &value) == BRIDGE_OK);
            assert(value == obj->value.boolean);
            break;
        }
        case BRIDGE_XPC_INT64: {
            int64_t value = 0;
            assert(bridge_xpc_int64(view, &value) == BRIDGE_OK);
            assert(value == obj->value.int64);
            break;
        }
        case BRIDGE_XPC_UINT64: {
            uint64_t value = 0;
            assert(bridge_xpc_uint64(view, &value) == BRIDGE_OK);
            assert(value == obj->value.uint64);
            break;
        }
        case BRIDGE_XPC_STRING:
            assert(view->size == strlen(obj->value.string));
            assert(memcmp(view->payload, obj->value.string, view->size) == 0);
            break;
        case BRIDGE_XPC_DATA:
            assert(view->size == obj->value.bytes.size);
            if (view->size) assert(memcmp(view->payload, obj->value.bytes.data, view->size) == 0);
            break;
        case BRIDGE_XPC_UUID:
            assert(view->size == 16);
            assert(memcmp(view->payload, obj->value.uuid, 16) == 0);
            break;
        case BRIDGE_XPC_ARRAY:
            assert(view->count == obj->value.array.count);
            for (size_t i = 0; i < obj->value.array.count; ++i) {
                bridge_xpc_view child;
                assert(bridge_xpc_array_at(view, i, &child) == BRIDGE_OK);
                semantic_equal(&obj->value.array.values[i], &child);
            }
            break;
        case BRIDGE_XPC_DICTIONARY:
            assert(view->count == obj->value.dictionary.count);
            for (size_t i = 0; i < obj->value.dictionary.count; ++i) {
                bridge_xpc_view child;
                const bridge_xpc_entry *entry = &obj->value.dictionary.entries[i];
                assert(bridge_xpc_dict_find(view, entry->key, &child) == BRIDGE_OK);
                semantic_equal(entry->value, &child);
            }
            break;
        default: assert(false);
    }
}

static uint8_t buffer[BRIDGE_XPC_MAX_MESSAGE_SIZE + 1u];
static void put32(uint8_t *p, uint32_t n) {
    for (unsigned i = 0; i < 4u; ++i) p[i] = (uint8_t)(n >> (i * 8u));
}
static void set_wrapper_size(size_t n) {
    assert(n >= 24u);
    put32(buffer + 8, (uint32_t)(n - 24u));
    put32(buffer + 12, 0);
}

static void test_differential(void) {
    init_fixtures();
    for (size_t i = 0; i < sizeof(fixtures) / sizeof(fixtures[0]); ++i) {
        const fixture *f = &fixtures[i];
        size_t needed = 0, size = 0;
        assert(bridge_xpc_encode(f->root, f->flags, f->message_id, NULL, 0, &needed) == BRIDGE_OK);
        assert(needed == f->size);
        memset(buffer, 0xaa, sizeof(buffer));
        assert(bridge_xpc_encode(f->root, f->flags, f->message_id, buffer, f->size-1u, &size) == BRIDGE_E_LIMIT);
        assert(size == 0);
        for (size_t j = 0; j < sizeof(buffer); ++j) assert(buffer[j] == 0xaa);
        assert(bridge_xpc_encode(f->root, f->flags, f->message_id, buffer, sizeof(buffer), &size) == BRIDGE_OK);
        assert(size == f->size);
        assert(memcmp(buffer, f->wire, size) == 0);
        assert(buffer[size] == 0xaa);
        bridge_xpc_message message;
        assert(bridge_xpc_parse(f->wire, f->size, &message) == BRIDGE_OK);
        assert(message.flags == f->flags && message.message_id == f->message_id);
        assert(message.has_payload == (f->root != NULL));
        if (f->root) semantic_equal(f->root, &message.root);
        /* Every truncation and unexpected trailing byte fails closed. */
        for (size_t j = 0; j < f->size; ++j) {
            assert(bridge_xpc_parse(f->wire, j, &message) != BRIDGE_OK);
            assert(message.root.payload == NULL && !message.has_payload);
        }
        assert(bridge_xpc_parse(buffer, size + 1u, &message) == BRIDGE_E_FORMAT);
    }
}

static void test_screenshot_view(void) {
    const fixture *f = &fixtures[3];
    bridge_xpc_message message;
    bridge_xpc_view output, image;
    assert(bridge_xpc_parse(f->wire, f->size, &message) == BRIDGE_OK);
    assert(bridge_xpc_dict_find(&message.root, "CoreDevice.output", &output) == BRIDGE_OK);
    assert(bridge_xpc_dict_find(&output, "image", &image) == BRIDGE_OK);
    assert(image.type == BRIDGE_XPC_DATA);
    assert(image.payload >= f->wire && image.payload + image.size <= f->wire + f->size);
    assert(image.size == sizeof("\x89PNG\r\n\x1a\nsynthetic-only") - 1u);
    assert(memcmp(image.payload, "\x89PNG\r\n\x1a\nsynthetic-only", image.size) == 0);
    assert(bridge_xpc_dict_find(&output, "missing", &image) == BRIDGE_E_NOT_FOUND);
    assert(bridge_xpc_array_at(&output, 0, &image) == BRIDGE_E_TYPE);
}

static void test_malformed(void) {
    bridge_xpc_message message;
    size_t n = 0;
    const bridge_xpc_object string = { .type = BRIDGE_XPC_STRING, .value.string = "ab" };
    assert(bridge_xpc_encode(&string, 0x101, 0, buffer, sizeof(buffer), &n) == BRIDGE_OK);
    buffer[0] ^= 1u;
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_E_FORMAT);
    buffer[0] ^= 1u;
    buffer[24] ^= 1u;
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_E_FORMAT);
    buffer[24] ^= 1u;
    buffer[28] = 6;
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_E_FORMAT);
    buffer[28] = 5;
    put32(buffer + 36, 0); /* zero-byte STRING */
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_E_FORMAT);
    put32(buffer + 36, 3);
    buffer[42] = 'x'; /* missing NUL */
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_E_FORMAT);
    buffer[42] = 0;
    buffer[40] = 0; /* embedded NUL */
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_E_FORMAT);
    buffer[40] = 0xc0; buffer[41] = 0x80; /* overlong UTF-8 */
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_E_FORMAT);
    put32(buffer + 36, UINT32_MAX);
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_E_LIMIT);
    put32(buffer + 32, 0x5000); /* DOUBLE is intentionally outside supported subset */
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_E_UNSUPPORTED);
    put32(buffer + 32, 0x1a000); /* FILE_TRANSFER is not inline DATA */
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_E_UNSUPPORTED);
    assert(bridge_xpc_parse(buffer, sizeof(buffer), &message) == BRIDGE_E_LIMIT);

    const bridge_xpc_object empty = { .type = BRIDGE_XPC_DICTIONARY };
    assert(bridge_xpc_encode(&empty, 1, 0, buffer, sizeof(buffer), &n) == BRIDGE_OK);
    put32(buffer + 40, 1); /* count without entries */
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_E_FORMAT);
    put32(buffer + 40, BRIDGE_XPC_MAX_OBJECTS + 1u);
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_E_LIMIT);
    put32(buffer + 40, 0);
    put32(buffer + 36, 3); /* prefixed container length less than count word */
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_E_FORMAT);
    put32(buffer + 36, 8); /* trailing bytes inside empty dict */
    memset(buffer + n, 0, 4); n += 4; set_wrapper_size(n);
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_E_FORMAT);

    const bridge_xpc_object nil = { .type = BRIDGE_XPC_NULL };
    const bridge_xpc_entry entry = { "ab", &nil };
    const bridge_xpc_object dict = { .type = BRIDGE_XPC_DICTIONARY, .value.dictionary = { &entry, 1 } };
    assert(bridge_xpc_encode(&dict, 1, 0, buffer, sizeof(buffer), &n) == BRIDGE_OK);
    buffer[44] = 0xc0; buffer[45] = 0x80;
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_E_FORMAT);
    memset(buffer + 44, 'x', n - 44u); /* unterminated dictionary key */
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_E_FORMAT);
}

static void test_limits(void) {
    bridge_xpc_object chain[BRIDGE_XPC_MAX_DEPTH + 1u];
    size_t n = 0;
    for (size_t i = 0; i < BRIDGE_XPC_MAX_DEPTH; ++i) {
        chain[i] = (bridge_xpc_object){ .type = BRIDGE_XPC_ARRAY, .value.array = { &chain[i+1u], 1 } };
    }
    chain[BRIDGE_XPC_MAX_DEPTH] = (bridge_xpc_object){ .type = BRIDGE_XPC_NULL };
    assert(bridge_xpc_encode(chain, 1, 0, buffer, sizeof(buffer), &n) == BRIDGE_E_LIMIT);
    assert(n == 0);
    assert(bridge_xpc_encode(chain + 1, 1, 0, buffer, sizeof(buffer), &n) == BRIDGE_OK);
    bridge_xpc_message message;
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_OK);
    /* Add one more array wrapper directly on wire to test parser depth bound. */
    memmove(buffer + 44, buffer + 32, n - 32u);
    put32(buffer + 32, BRIDGE_XPC_ARRAY);
    put32(buffer + 36, (uint32_t)(n - 28u));
    put32(buffer + 40, 1); n += 12u; set_wrapper_size(n);
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_E_LIMIT);
    chain[0].value.array.values = chain; /* cyclic input cannot recurse forever */
    assert(bridge_xpc_encode(chain, 1, 0, buffer, sizeof(buffer), &n) == BRIDGE_E_LIMIT);

    static bridge_xpc_object many[BRIDGE_XPC_MAX_OBJECTS];
    for (size_t i = 0; i < BRIDGE_XPC_MAX_OBJECTS; ++i) many[i].type = BRIDGE_XPC_NULL;
    bridge_xpc_object array = { .type = BRIDGE_XPC_ARRAY, .value.array = { many, BRIDGE_XPC_MAX_OBJECTS } };
    assert(bridge_xpc_encode(&array, 1, 0, buffer, sizeof(buffer), &n) == BRIDGE_E_LIMIT);
    array.value.array.count--;
    assert(bridge_xpc_encode(&array, 1, 0, buffer, sizeof(buffer), &n) == BRIDGE_OK);
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_OK);
    put32(buffer + 40, BRIDGE_XPC_MAX_OBJECTS);
    put32(buffer + 36, (uint32_t)(n - 36u)); /* plus new NULL */
    put32(buffer + n, BRIDGE_XPC_NULL); n += 4; set_wrapper_size(n);
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_E_LIMIT);

    static uint8_t data[BRIDGE_XPC_MAX_MESSAGE_SIZE];
    bridge_xpc_object blob = { .type = BRIDGE_XPC_DATA,
        .value.bytes = { data, BRIDGE_XPC_MAX_MESSAGE_SIZE - 40u } };
    assert(bridge_xpc_encode(&blob, 1, 0, buffer, sizeof(buffer), &n) == BRIDGE_OK);
    assert(n == BRIDGE_XPC_MAX_MESSAGE_SIZE);
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_OK);
    blob.value.bytes.size++;
    assert(bridge_xpc_encode(&blob, 1, 0, buffer, sizeof(buffer), &n) == BRIDGE_E_LIMIT);
    assert(n == 0);
}

static void test_arguments_and_types(void) {
    size_t n = 0;
    bridge_xpc_message message;
    bridge_xpc_view view;
    uint64_t u;
    int64_t i;
    bool b;
    assert(bridge_xpc_parse(NULL, 0, &message) == BRIDGE_E_ARGUMENT);
    assert(bridge_xpc_parse(buffer, 0, NULL) == BRIDGE_E_ARGUMENT);
    assert(bridge_xpc_encode(NULL, 0, 0, buffer, sizeof(buffer), NULL) == BRIDGE_E_ARGUMENT);
    assert(bridge_xpc_encode(NULL, 0, 0, NULL, 1, &n) == BRIDGE_E_ARGUMENT);
    bridge_xpc_object bad = { .type = BRIDGE_XPC_STRING, .value.string = NULL };
    assert(bridge_xpc_encode(&bad, 0, 0, buffer, sizeof(buffer), &n) == BRIDGE_E_ARGUMENT);
    bad.value.string = "\xed\xa0\x80"; /* surrogate */
    assert(bridge_xpc_encode(&bad, 0, 0, buffer, sizeof(buffer), &n) == BRIDGE_E_FORMAT);
    bad.value.string = "\xf4\x90\x80\x80"; /* beyond Unicode */
    assert(bridge_xpc_encode(&bad, 0, 0, buffer, sizeof(buffer), &n) == BRIDGE_E_FORMAT);
    bad.value.string = "\xe4\xb8"; /* incomplete */
    assert(bridge_xpc_encode(&bad, 0, 0, buffer, sizeof(buffer), &n) == BRIDGE_E_FORMAT);
    bad = (bridge_xpc_object){ .type = BRIDGE_XPC_DATA, .value.bytes = { NULL, 1 } };
    assert(bridge_xpc_encode(&bad, 0, 0, buffer, sizeof(buffer), &n) == BRIDGE_E_ARGUMENT);
    bad = (bridge_xpc_object){ .type = BRIDGE_XPC_ARRAY, .value.array = { NULL, 1 } };
    assert(bridge_xpc_encode(&bad, 0, 0, buffer, sizeof(buffer), &n) == BRIDGE_E_ARGUMENT);
    bad = (bridge_xpc_object){ .type = (bridge_xpc_type)0x5000 };
    assert(bridge_xpc_encode(&bad, 0, 0, buffer, sizeof(buffer), &n) == BRIDGE_E_UNSUPPORTED);
    bad = (bridge_xpc_object){ .type = BRIDGE_XPC_BOOL, .value.boolean = true };
    assert(bridge_xpc_encode(&bad, 0, 0, buffer, sizeof(buffer), &n) == BRIDGE_OK);
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_OK);
    assert(bridge_xpc_bool(&message.root, &b) == BRIDGE_OK && b);
    assert(bridge_xpc_uint64(&message.root, &u) == BRIDGE_E_TYPE);
    assert(bridge_xpc_int64(&message.root, &i) == BRIDGE_E_TYPE);
    assert(bridge_xpc_dict_find(&message.root, "x", &view) == BRIDGE_E_TYPE);
    put32(buffer + 36, 0xffffffffu); /* upstream interprets any nonzero as true */
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_OK);
    assert(bridge_xpc_bool(&message.root, &b) == BRIDGE_OK && b);

    const bridge_xpc_object first = { .type = BRIDGE_XPC_UINT64, .value.uint64 = 1 };
    const bridge_xpc_object last = { .type = BRIDGE_XPC_UINT64, .value.uint64 = 2 };
    const bridge_xpc_entry entries[] = { { "same", &first }, { "same", &last } };
    const bridge_xpc_object dict = { .type = BRIDGE_XPC_DICTIONARY, .value.dictionary = { entries, 2 } };
    assert(bridge_xpc_encode(&dict, 1, 0, buffer, sizeof(buffer), &n) == BRIDGE_OK);
    assert(bridge_xpc_parse(buffer, n, &message) == BRIDGE_OK);
    assert(bridge_xpc_dict_find(&message.root, "same", &view) == BRIDGE_OK);
    assert(bridge_xpc_uint64(&view, &u) == BRIDGE_OK && u == 2);
}

static void test_mutations(void) {
    /* Bounded deterministic malformed-input smoke fuzz under ASan/UBSan. */
    uint32_t state = 0x29b00b92u;
    bridge_xpc_message message;
    for (unsigned k = 0; k < 20000u; ++k) {
        const fixture *f = &fixtures[k % (sizeof(fixtures) / sizeof(fixtures[0]))];
        memcpy(buffer, f->wire, f->size);
        state = state * 1664525u + 1013904223u;
        size_t at = state % f->size;
        buffer[at] ^= (uint8_t)((state >> 24) | 1u);
        bridge_status status = bridge_xpc_parse(buffer, f->size, &message);
        if (status != BRIDGE_OK) assert(!message.has_payload && message.root.payload == NULL);
    }
}

int main(void) {
    test_differential();
    test_screenshot_view();
    test_malformed();
    test_limits();
    test_arguments_and_types();
    test_mutations();
    printf("XPC: %zu upstream differential fixtures; typed parse, limits, malformed, 20000 mutations PASS\n",
        sizeof(fixtures) / sizeof(fixtures[0]));
    return 0;
}
