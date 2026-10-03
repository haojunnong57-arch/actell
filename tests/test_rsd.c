/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bridge_rsd.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "rsd_fixtures.h"
#define CAPACITY (96u * 1024u)
#define DEADLINE UINT64_C(1000000)
typedef struct {
    uint8_t input[CAPACITY], output[CAPACITY];
    size_t input_size, input_pos, output_size, fragment;
    uint64_t now, tick;
    bool fail_read, fail_write, closed;
} peer;
typedef struct {
    peer peers[2];
    unsigned dials, closes, drains;
    uint16_t ports[8];
    bridge_status dial_error, drain_error;
    bool bad_io;
} network;
static network net;
static bridge_rsd rsd;
static bridge_rsd_connection service;
static uint8_t scratch[BRIDGE_RSD_MAX_PEER_INFO];
static const uint8_t address[16] = {0xfd, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2};
static const uint8_t identity[16] = {0, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
    0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff};
static ptrdiff_t rd(void *context, uint8_t *data, size_t size, uint32_t timeout) {
    peer *p = context; assert(timeout && !p->closed); p->now += p->tick;
    if (p->fail_read) return -(ptrdiff_t)BRIDGE_E_TIMEOUT;
    if (size > p->fragment) size = p->fragment;
    if (size > p->input_size - p->input_pos) size = p->input_size - p->input_pos;
    if (size) memcpy(data, p->input + p->input_pos, size);
    p->input_pos += size; return (ptrdiff_t)size;
}
static ptrdiff_t wr(void *context, const uint8_t *data, size_t size, uint32_t timeout) {
    peer *p = context; assert(timeout && !p->closed); p->now += p->tick;
    if (p->fail_write) return -(ptrdiff_t)BRIDGE_E_IO;
    if (size > p->fragment) size = p->fragment;
    assert(size <= sizeof p->output - p->output_size);
    memcpy(p->output + p->output_size, data, size); p->output_size += size;
    return (ptrdiff_t)size;
}
static uint64_t clk(void *context) { return ((peer *)context)->now; }
static bridge_status dial(void *context, const uint8_t server[16], uint16_t port,
    uint64_t deadline, bridge_io *out) {
    network *n = context; assert(!memcmp(server, address, 16) && deadline);
    assert(n->dials < 8); n->ports[n->dials++] = port;
    if (n->dial_error != BRIDGE_OK) return n->dial_error;
    peer *p = &n->peers[port == 58783 ? 0 : 1]; assert(!p->closed);
    *out = (bridge_io){p, rd, n->bad_io ? NULL : wr, clk}; return BRIDGE_OK;
}
static void close_io(void *context, bridge_io *io) {
    network *n = context; peer *p = io->context; assert(p && !p->closed);
    p->closed = true; ++n->closes;
}
static bridge_status drain_io(void *context, bridge_io *io, uint64_t deadline) {
    network *n = context; assert(io->context && deadline); ++n->drains; return n->drain_error;
}
static void frame(peer *p, uint8_t type, uint8_t flags, uint32_t stream, const uint8_t *data, size_t size) {
    assert(size < 0x1000000 && size + 9 <= sizeof p->input - p->input_size);
    uint8_t *b = p->input + p->input_size;
    b[0] = (uint8_t)(size >> 16); b[1] = (uint8_t)(size >> 8); b[2] = (uint8_t)size;
    b[3] = type; b[4] = flags; b[5] = (uint8_t)(stream >> 24);
    b[6] = (uint8_t)(stream >> 16); b[7] = (uint8_t)(stream >> 8); b[8] = (uint8_t)stream;
    if (size) memcpy(b + 9, data, size);
    p->input_size += size + 9;
}
static void data_frames(peer *p, uint32_t stream, const uint8_t *data, size_t size, size_t step) {
    for (size_t pos = 0; pos < size;) {
        size_t n = size - pos; if (n > step) n = step;
        frame(p, 0, 0, stream, data + pos, n); pos += n;
    }
}
static void reset(size_t fragment) {
    memset(&net, 0, sizeof net); memset(&service, 0, sizeof service);
    for (size_t i = 0; i < 2; ++i) net.peers[i].fragment = fragment;
    memset(scratch, 0xa5, sizeof scratch);
    bridge_rsd_dialer d = {&net, dial, close_io, drain_io};
    assert(bridge_rsd_init(&rsd, &d, address, 58783) == BRIDGE_OK);
}
static void settings(peer *p) { frame(p, 4, 0, 0, NULL, 0); }
static bridge_status connect_fixture(const uint8_t *data, size_t size, uint32_t stream, size_t step) {
    settings(&net.peers[0]); data_frames(&net.peers[0], stream, data, size, step);
    return bridge_rsd_connect(&rsd, identity, scratch, sizeof scratch, DEADLINE);
}
static void scratch_clean(size_t size) {
    for (size_t i = 0; i < size; ++i) assert(scratch[i] == 0);
    assert(!rsd.peer_scratch && !rsd.peer_capacity && !rsd.peer_used);
}
static void wire_and_ports(void) {
    for (size_t fragment = 1; fragment <= 31; ++fragment) {
        reset(fragment); uint32_t stream = fragment & 1u ? 1u : 3u;
        peer *control = &net.peers[0]; settings(control);
        data_frames(control, 3, fixture_no_payload, sizeof fixture_no_payload, 1);
        data_frames(control, 1, fixture_empty, sizeof fixture_empty, 3);
        data_frames(control, stream, fixture_peer_info, sizeof fixture_peer_info, 7);
        assert(bridge_rsd_connect(&rsd, identity, scratch, sizeof scratch, DEADLINE) == BRIDGE_OK);
        assert(rsd.state == BRIDGE_RSD_READY && rsd.control_open && !control->closed && !net.closes);
        scratch_clean(sizeof fixture_peer_info);
        assert(control->output_size == sizeof fixture_transport_handshake + sizeof fixture_device_handshake);
        assert(!memcmp(control->output, fixture_transport_handshake, sizeof fixture_transport_handshake));
        assert(!memcmp(control->output + sizeof fixture_transport_handshake,
            fixture_device_handshake, sizeof fixture_device_handshake));
        assert(rsd.control.next_message_id == (stream == BRIDGE_RXPC_ROOT ? 100u : 2u));
        for (unsigned i = 0; i < BRIDGE_RSD_SERVICE_COUNT; ++i) {
            uint16_t port = 0;
            assert(bridge_rsd_get_port(&rsd, (bridge_rsd_service)i, &port) == BRIDGE_OK);
            assert(port == 61001 + i);
        }
        bridge_rsd_availability result;
        assert(bridge_rsd_require_feature(&rsd, BRIDGE_RSD_SCREENSHOT, BRIDGE_RSD_CAPTURE_SCREENSHOT, &result) == BRIDGE_OK && result == BRIDGE_RSD_ALLOWED);
        assert(bridge_rsd_require_feature(&rsd, BRIDGE_RSD_DISPLAY, BRIDGE_RSD_MEDIA_START, &result) == BRIDGE_OK && result == BRIDGE_RSD_ALLOWED);
        assert(bridge_rsd_require_feature(&rsd, BRIDGE_RSD_DISPLAY, BRIDGE_RSD_MEDIA_STOP, &result) == BRIDGE_E_UNSUPPORTED && result == BRIDGE_RSD_DENIED);
        assert(bridge_rsd_open_service(&rsd, BRIDGE_RSD_DISPLAY, BRIDGE_RSD_MEDIA_STOP,
            &service, 4096, NULL, NULL, DEADLINE) == BRIDGE_E_UNSUPPORTED && net.dials == 1);
        assert(bridge_rsd_require_feature(&rsd, BRIDGE_RSD_SCREENSHOT, BRIDGE_RSD_MEDIA_START, &result) == BRIDGE_E_ARGUMENT);
        assert(bridge_rsd_require_feature(&rsd, BRIDGE_RSD_INDIGO, BRIDGE_RSD_FEATURE_NONE, &result) == BRIDGE_OK && result == BRIDGE_RSD_UNKNOWN);
        settings(&net.peers[1]);
        assert(bridge_rsd_open_service(&rsd, BRIDGE_RSD_SCREENSHOT, BRIDGE_RSD_CAPTURE_SCREENSHOT,
            &service, 4096, NULL, NULL, DEADLINE) == BRIDGE_OK);
        assert(service.open && service.session.ready && service.session.next_message_id == 1 && net.ports[1] == 61001);
        assert(net.peers[1].output_size == sizeof fixture_transport_handshake);
        assert(!memcmp(net.peers[1].output, fixture_transport_handshake, sizeof fixture_transport_handshake));
        assert(bridge_rsd_open_service(&rsd, BRIDGE_RSD_SCREENSHOT, BRIDGE_RSD_CAPTURE_SCREENSHOT,
            &service, 4096, NULL, NULL, DEADLINE) == BRIDGE_E_ARGUMENT);
        /* Real request/response on the discovered TCP service, no device handshake. */
        bridge_xpc_object value = {.type = BRIDGE_XPC_BOOL, .value.boolean = true};
        bridge_xpc_entry pair = {"question", &value};
        bridge_xpc_object request = {.type = BRIDGE_XPC_DICTIONARY, .value.dictionary = {&pair, 1}};
        uint8_t encoded[128]; uint64_t mid = 0;
        assert(bridge_remotexpc_send(&service.session, &request, true, encoded, sizeof encoded, DEADLINE, &mid) == BRIDGE_OK && mid == 1);
        data_frames(&net.peers[1], 3, fixture_answer, sizeof fixture_answer, 3);
        bridge_remotexpc_response response;
        assert(bridge_remotexpc_response_open(&service.session, &response, 3, true, mid) == BRIDGE_OK);
        assert(bridge_read_exact(&response.io, encoded, sizeof fixture_answer, DEADLINE) == BRIDGE_OK);
        assert(bridge_remotexpc_response_finish(&response, BRIDGE_OK) == BRIDGE_OK);
        assert(!memcmp(encoded, fixture_answer, sizeof fixture_answer));
        assert(bridge_rsd_drain_service(&service, DEADLINE) == BRIDGE_OK && net.drains == 1);
        const uint8_t ping[8] = {'k','e','e','p','a','l','i','v'};
        frame(control, 6, 0, 0, ping, 8);
        size_t before = control->output_size;
        assert(bridge_rsd_pump(&rsd, DEADLINE) == BRIDGE_OK && control->output_size == before + 17);
        assert(control->output[before + 3] == 6 && control->output[before + 4] == 1);
        assert(!net.closes);
        bridge_rsd_close_service(&service); bridge_rsd_close_service(&service);
        assert(net.closes == 1 && rsd.control_open);
        bridge_rsd_close(&rsd); bridge_rsd_close(&rsd);
        assert(net.closes == 2 && rsd.state == BRIDGE_RSD_CLOSED);
        uint16_t port;
        assert(bridge_rsd_get_port(&rsd, BRIDGE_RSD_SCREENSHOT, &port) == BRIDGE_E_ARGUMENT);
    }
}
static void fixture_error(const uint8_t *bytes, size_t size, bridge_status expected) {
    reset(3); assert(connect_fixture(bytes, size, 1, 11) == expected);
    assert(rsd.state == BRIDGE_RSD_FAILED && rsd.failure == expected && net.closes == 1 && net.peers[0].closed);
    scratch_clean(size);
    for (unsigned i = 0; i < BRIDGE_RSD_SERVICE_COUNT; ++i) assert(!rsd.services[i].port);
    size_t writes = net.peers[0].output_size;
    assert(bridge_rsd_connect(&rsd, identity, scratch, sizeof scratch, DEADLINE) == expected);
    assert(bridge_rsd_pump(&rsd, DEADLINE) == expected && net.peers[0].output_size == writes);
}
#define ERROR(name, expected) fixture_error(fixture_##name, sizeof fixture_##name, expected)
static void parse_errors(void) {
    ERROR(no_services, BRIDGE_E_NOT_FOUND); ERROR(bad_services, BRIDGE_E_TYPE);
    ERROR(bad_entry, BRIDGE_E_TYPE); ERROR(missing_port, BRIDGE_E_NOT_FOUND);
    ERROR(bad_properties, BRIDGE_E_TYPE); ERROR(bad_transport_type, BRIDGE_E_TYPE);
    ERROR(bad_features_type, BRIDGE_E_TYPE); ERROR(bad_feature_entry, BRIDGE_E_TYPE);
    ERROR(zero, BRIDGE_E_FORMAT); ERROR(high, BRIDGE_E_FORMAT); ERROR(space, BRIDGE_E_FORMAT);
    ERROR(sign, BRIDGE_E_FORMAT); ERROR(empty_port, BRIDGE_E_FORMAT); ERROR(long_port, BRIDGE_E_FORMAT);
    ERROR(hex, BRIDGE_E_FORMAT); ERROR(negative, BRIDGE_E_FORMAT); ERROR(highint, BRIDGE_E_FORMAT);
    ERROR(boolport, BRIDGE_E_TYPE); ERROR(nullport, BRIDGE_E_TYPE);
    ERROR(max_id, BRIDGE_E_LIMIT);
    reset(7); assert(connect_fixture(fixture_over_limit, sizeof fixture_over_limit, 1, 24) == BRIDGE_E_LIMIT);
    assert(net.closes == 1 && rsd.failure == BRIDGE_E_LIMIT);
    reset(7); settings(&net.peers[0]); data_frames(&net.peers[0], 3, fixture_peer_info, sizeof fixture_peer_info, 11);
    assert(bridge_rsd_connect(&rsd, identity, scratch, 64, DEADLINE) == BRIDGE_E_LIMIT && net.closes == 1);
    reset(7); settings(&net.peers[0]);
    data_frames(&net.peers[0], 1, fixture_peer_info, 80, 80);
    data_frames(&net.peers[0], 3, fixture_peer_info, 80, 80);
    assert(bridge_rsd_connect(&rsd, identity, scratch, sizeof scratch, DEADLINE) == BRIDGE_E_UNSUPPORTED && net.closes == 1);
    scratch_clean(80);
}
static void unknown_features(const uint8_t *data, size_t size) {
    reset(11); assert(connect_fixture(data, size, 3, 9) == BRIDGE_OK);
    bridge_rsd_availability result;
    assert(bridge_rsd_require_feature(&rsd, BRIDGE_RSD_SCREENSHOT, BRIDGE_RSD_CAPTURE_SCREENSHOT, &result) == BRIDGE_OK && result == BRIDGE_RSD_UNKNOWN);
    settings(&net.peers[1]);
    assert(bridge_rsd_open_service(&rsd, BRIDGE_RSD_SCREENSHOT, BRIDGE_RSD_CAPTURE_SCREENSHOT,
        &service, 4096, NULL, NULL, DEADLINE) == BRIDGE_OK);
    bridge_rsd_close_service(&service); bridge_rsd_close(&rsd);
}
static void availability(void) {
    unknown_features(fixture_unknown_features, sizeof fixture_unknown_features);
    unknown_features(fixture_null_features, sizeof fixture_null_features);
    unknown_features(fixture_empty_features, sizeof fixture_empty_features);
    reset(19); assert(connect_fixture(fixture_missing, sizeof fixture_missing, 3, 19) == BRIDGE_OK);
    uint16_t port = 9;
    assert(bridge_rsd_get_port(&rsd, BRIDGE_RSD_SCREENSHOT, &port) == BRIDGE_E_NOT_FOUND && !port);
    assert(bridge_rsd_open_service(&rsd, BRIDGE_RSD_SCREENSHOT, BRIDGE_RSD_CAPTURE_SCREENSHOT,
        &service, 4096, NULL, NULL, DEADLINE) == BRIDGE_E_NOT_FOUND && net.dials == 1);
    bridge_rsd_close(&rsd);
    reset(19); assert(connect_fixture(fixture_wrong_transport, sizeof fixture_wrong_transport, 1, 19) == BRIDGE_OK);
    assert(bridge_rsd_open_service(&rsd, BRIDGE_RSD_SCREENSHOT, BRIDGE_RSD_CAPTURE_SCREENSHOT,
        &service, 4096, NULL, NULL, DEADLINE) == BRIDGE_E_UNSUPPORTED && net.dials == 1);
    bridge_rsd_close(&rsd);
}
static void large_info(const char *name) {
    static uint8_t large[CAPACITY];
    FILE *f = fopen(name, "rb"); assert(f);
    size_t size = fread(large, 1, sizeof large, f); assert(size > 60000 && size <= sizeof scratch); assert(!fclose(f));
    reset(7); assert(connect_fixture(large, size, 3, 8192) == BRIDGE_OK);
    scratch_clean(size);
    assert(rsd.services[BRIDGE_RSD_SCREENSHOT].port == 61001 && rsd.control_open);
    bridge_rsd_close(&rsd);
}
static void io_errors(void) {
    reset(7); net.dial_error = BRIDGE_E_IO;
    assert(bridge_rsd_connect(&rsd, identity, scratch, sizeof scratch, DEADLINE) == BRIDGE_E_IO && !net.closes);
    reset(7); net.bad_io = true;
    assert(bridge_rsd_connect(&rsd, identity, scratch, sizeof scratch, DEADLINE) == BRIDGE_E_ARGUMENT && net.closes == 1);
    reset(7); net.peers[0].fail_write = true;
    assert(connect_fixture(fixture_peer_info, sizeof fixture_peer_info, 1, 19) == BRIDGE_E_IO && net.closes == 1);
    reset(7); net.peers[0].fail_read = true;
    assert(connect_fixture(fixture_peer_info, sizeof fixture_peer_info, 1, 19) == BRIDGE_E_TIMEOUT && net.closes == 1);
    reset(7); settings(&net.peers[0]);
    assert(bridge_rsd_connect(&rsd, identity, scratch, sizeof scratch, DEADLINE) == BRIDGE_E_EOF && net.closes == 1);
    reset(7); net.peers[0].now = DEADLINE;
    assert(connect_fixture(fixture_peer_info, sizeof fixture_peer_info, 1, 19) == BRIDGE_E_TIMEOUT && net.closes == 1);
    reset(7); assert(connect_fixture(fixture_peer_info, sizeof fixture_peer_info, 1, 19) == BRIDGE_OK);
    net.dial_error = BRIDGE_E_IO;
    assert(bridge_rsd_open_service(&rsd, BRIDGE_RSD_INDIGO, BRIDGE_RSD_FEATURE_NONE, &service, 4096, NULL, NULL, DEADLINE) == BRIDGE_E_IO);
    assert(rsd.state == BRIDGE_RSD_READY && rsd.control_open && !net.closes);
    net.dial_error = BRIDGE_OK; net.peers[1].fail_read = true;
    assert(bridge_rsd_open_service(&rsd, BRIDGE_RSD_INDIGO, BRIDGE_RSD_FEATURE_NONE, &service, 4096, NULL, NULL, DEADLINE) == BRIDGE_E_TIMEOUT);
    assert(!service.open && net.closes == 1 && rsd.control_open);
    bridge_rsd_close(&rsd);
    reset(7); assert(connect_fixture(fixture_peer_info, sizeof fixture_peer_info, 1, 19) == BRIDGE_OK);
    data_frames(&net.peers[0], 1, fixture_peer_info, sizeof fixture_peer_info, 19);
    bridge_status e;
    do { e = bridge_rsd_pump(&rsd, DEADLINE); } while (e == BRIDGE_OK);
    assert(e == BRIDGE_E_UNSUPPORTED && net.closes == 1);
    reset(7); assert(connect_fixture(fixture_peer_info, sizeof fixture_peer_info, 1, 19) == BRIDGE_OK);
    settings(&net.peers[1]);
    assert(bridge_rsd_open_service(&rsd, BRIDGE_RSD_INDIGO, BRIDGE_RSD_FEATURE_NONE, &service, 4096, NULL, NULL, DEADLINE) == BRIDGE_OK);
    service.dialer.drain = NULL;
    assert(bridge_rsd_drain_service(&service, DEADLINE) == BRIDGE_E_UNSUPPORTED && !net.drains);
    service.dialer.drain = drain_io; net.drain_error = BRIDGE_E_TIMEOUT;
    assert(bridge_rsd_drain_service(&service, DEADLINE) == BRIDGE_E_TIMEOUT && net.drains == 1);
    assert(bridge_rsd_drain_service(&service, DEADLINE) == BRIDGE_E_TIMEOUT && net.drains == 1);
    bridge_rsd_close_service(&service); bridge_rsd_close(&rsd);
}
static void arguments(void) {
    reset(7); uint16_t port;
    assert(bridge_rsd_connect(&rsd, NULL, scratch, sizeof scratch, DEADLINE) == BRIDGE_E_ARGUMENT && !net.dials);
    assert(bridge_rsd_connect(&rsd, identity, scratch, 23, DEADLINE) == BRIDGE_E_ARGUMENT && !net.dials);
    assert(bridge_rsd_connect(&rsd, identity, scratch, sizeof scratch + 1, DEADLINE) == BRIDGE_E_ARGUMENT && !net.dials);
    assert(bridge_rsd_get_port(NULL, BRIDGE_RSD_SCREENSHOT, &port) == BRIDGE_E_ARGUMENT);
    assert(bridge_rsd_get_port(&rsd, (bridge_rsd_service)-1, &port) == BRIDGE_E_ARGUMENT);
    assert(!bridge_rsd_service_name((bridge_rsd_service)-1));
    assert(!bridge_rsd_feature_name((bridge_rsd_feature)-1));
    assert(bridge_rsd_drain_service(&service, DEADLINE) == BRIDGE_E_ARGUMENT);
    bridge_rsd_close(NULL); bridge_rsd_close_service(NULL);
}
static void bounded_mutations(void) {
    uint8_t mutated[sizeof fixture_peer_info];
    for (size_t i = 0; i < sizeof mutated; ++i) {
        memcpy(mutated, fixture_peer_info, sizeof mutated);
        mutated[i] ^= (uint8_t)(1u << (i % 8));
        reset(13);
        bridge_status e = connect_fixture(mutated, sizeof mutated, 1, 41);
        assert(!rsd.peer_scratch && !rsd.peer_capacity && !rsd.peer_used);
        if (e == BRIDGE_OK) {
            assert(rsd.state == BRIDGE_RSD_READY && rsd.control_open);
            bridge_rsd_close(&rsd);
        } else {
            assert(rsd.state == BRIDGE_RSD_FAILED && rsd.failure == e && !rsd.control_open);
            assert(bridge_rsd_pump(&rsd, DEADLINE) == e);
        }
        assert(net.closes == 1);
    }
}
int main(void) {
    arguments(); wire_and_ports(); parse_errors(); availability();
    large_info(".build/rsd-fixtures/large_info.bin");
    large_info(".build/rsd-fixtures/limit_info.bin"); io_errors(); bounded_mutations();
    puts("RSD ASan/UBSan: handshake wire, root/reply unsolicited discovery, features, live control/service exchange, bounds, cleanup and errors passed");
    return 0;
}
