/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bridge_cdtunnel.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    const uint8_t *wire;
    size_t size;
    bridge_status expected;
    uint16_t requested, mtu, port;
    bool mask;
    uint8_t prefix, client[16], server[16];
} fixture;
#include "cdtunnel_fixtures.h"

typedef struct {
    const uint8_t *input;
    size_t size, pos, chunk, written, calls, read_calls, write_calls;
    uint8_t output[BRIDGE_CDTUNNEL_MAX_MTU * 2u + 256u];
    uint64_t now, advance, clock_step;
    uint32_t last_timeout;
    ptrdiff_t forced_read, forced_write;
    bool force_read, force_write, overread, overwrite;
} memory_io;
static ptrdiff_t read_memory(void *context, uint8_t *out, size_t size, uint32_t timeout) {
    memory_io *m = context;
    assert(size && timeout);
    ++m->calls; ++m->read_calls; m->last_timeout = timeout; m->now += m->advance;
    if (m->force_read) return m->forced_read;
    if (m->overread) return (ptrdiff_t)size + 1;
    size_t count = m->size - m->pos;
    if (count > size) count = size;
    if (m->chunk && count > m->chunk) count = m->chunk;
    if (count) memcpy(out, m->input + m->pos, count);
    m->pos += count;
    return (ptrdiff_t)count;
}
static ptrdiff_t write_memory(void *context, const uint8_t *data, size_t size, uint32_t timeout) {
    memory_io *m = context;
    assert(size && timeout);
    ++m->calls; ++m->write_calls; m->last_timeout = timeout; m->now += m->advance;
    if (m->force_write) return m->forced_write;
    if (m->overwrite) return (ptrdiff_t)size + 1;
    size_t count = size;
    if (m->chunk && count > m->chunk) count = m->chunk;
    assert(count <= sizeof m->output - m->written);
    memcpy(m->output + m->written, data, count); m->written += count;
    return (ptrdiff_t)count;
}
static uint64_t clock_memory(void *context) {
    memory_io *m = context;
    uint64_t now = m->now; m->now += m->clock_step; return now;
}
static void initialize(bridge_cdtunnel *t, memory_io *m, const uint8_t *wire, size_t size, uint16_t requested) {
    memset(m, 0, sizeof *m);
    m->input = wire; m->size = size;
    bridge_io io = {.context = m, .read = read_memory, .write = write_memory, .clock_ms = clock_memory};
    assert(bridge_cdtunnel_init(t, &io, requested) == BRIDGE_OK);
    assert(t->state == BRIDGE_CDTUNNEL_NEW && t->error == BRIDGE_OK);
}
static void zero_parameters(const bridge_cdtunnel *t) {
    bridge_cdtunnel_parameters zero = {0};
    assert(!memcmp(&t->parameters, &zero, sizeof zero));
}
static void failed_sticky(bridge_cdtunnel *t, memory_io *m, bridge_status expected) {
    assert(expected != BRIDGE_OK && t->state == BRIDGE_CDTUNNEL_FAILED && t->error == expected);
    zero_parameters(t);
    size_t calls = m->calls, size = 99;
    uint8_t buffer[BRIDGE_CDTUNNEL_MAX_JSON];
    assert(bridge_cdtunnel_handshake(t, buffer, sizeof buffer, UINT64_MAX) == expected);
    assert(bridge_cdtunnel_send_ipv6(t, buffer, sizeof buffer, UINT64_MAX) == expected);
    assert(bridge_cdtunnel_recv_ipv6(t, buffer, sizeof buffer, &size, UINT64_MAX) == expected);
    assert(size == 0 && m->calls == calls);
}
static void test_fixtures(void) {
    for (size_t i = 0; i < sizeof fixtures / sizeof fixtures[0]; ++i) {
        const fixture *f = &fixtures[i];
        for (size_t chunk = 0; chunk <= 3; ++chunk) {
            memory_io m; bridge_cdtunnel t; uint8_t scratch[BRIDGE_CDTUNNEL_MAX_JSON];
            initialize(&t, &m, f->wire, f->size, f->requested); m.chunk = chunk;
            bridge_status status = bridge_cdtunnel_handshake(&t, scratch, sizeof scratch, 100000);
            if (status != f->expected) {
                fprintf(stderr, "fixture %zu chunk %zu: expected %s, got %s\n", i, chunk,
                    bridge_status_name(f->expected), bridge_status_name(status)); abort();
            }
            const uint8_t *expected = f->requested == 1280 ? expected_request_1280 : expected_request_16000;
            size_t expected_size = f->requested == 1280 ? sizeof expected_request_1280 : sizeof expected_request_16000;
            assert(m.written == expected_size && !memcmp(m.output, expected, expected_size));
            if (status != BRIDGE_OK) failed_sticky(&t, &m, status);
            else {
                assert(t.state == BRIDGE_CDTUNNEL_READY && t.error == BRIDGE_OK && m.pos == f->size);
                assert(t.parameters.mtu == f->mtu && t.parameters.server_rsd_port == f->port);
                assert(t.parameters.has_netmask == f->mask && t.parameters.prefix_length == f->prefix);
                assert(!memcmp(t.parameters.client_address, f->client, 16));
                assert(!memcmp(t.parameters.server_address, f->server, 16));
                size_t calls = m.calls;
                assert(bridge_cdtunnel_handshake(&t, scratch, sizeof scratch, 100000) == BRIDGE_E_ARGUMENT);
                assert(t.state == BRIDGE_CDTUNNEL_READY && m.calls == calls);
            }
        }
    }
}
static void test_response_framing(void) {
    const fixture *f = &fixtures[0];
    uint8_t scratch[BRIDGE_CDTUNNEL_MAX_JSON], wire[BRIDGE_CDTUNNEL_MAX_JSON + 10u];
    memory_io m; bridge_cdtunnel t;
    /* Every truncation of the real frame is EOF, including partial magic/length. */
    for (size_t n = 0; n < f->size; ++n) {
        initialize(&t, &m, f->wire, n, 16000); m.chunk = 3;
        assert(bridge_cdtunnel_handshake(&t, scratch, sizeof scratch, 100000) == BRIDGE_E_EOF);
        failed_sticky(&t, &m, BRIDGE_E_EOF);
    }
    /* Every truncated JSON document, despite internally consistent frame length. */
    for (size_t n = 0; n < f->size - 10u; ++n) {
        memcpy(wire, f->wire, f->size); wire[8] = (uint8_t)(n >> 8); wire[9] = (uint8_t)n;
        initialize(&t, &m, wire, n + 10u, 16000);
        bridge_status status = bridge_cdtunnel_handshake(&t, scratch, sizeof scratch, 100000);
        assert(status != BRIDGE_OK); failed_sticky(&t, &m, status);
    }
    memcpy(wire, f->wire, f->size); wire[0] ^= 1u;
    initialize(&t, &m, wire, f->size, 16000);
    assert(bridge_cdtunnel_handshake(&t, scratch, sizeof scratch, 100000) == BRIDGE_E_FORMAT);
    assert(m.pos == 10); failed_sticky(&t, &m, BRIDGE_E_FORMAT);
    for (size_t size = BRIDGE_CDTUNNEL_MAX_JSON + 1u; size <= UINT16_MAX; size = UINT16_MAX) {
        memcpy(wire, f->wire, 10); wire[8] = (uint8_t)(size >> 8); wire[9] = (uint8_t)size;
        initialize(&t, &m, wire, 10, 16000);
        assert(bridge_cdtunnel_handshake(&t, scratch, sizeof scratch, 100000) == BRIDGE_E_LIMIT);
        assert(m.pos == 10); failed_sticky(&t, &m, BRIDGE_E_LIMIT);
        if (size == UINT16_MAX) break;
    }
    initialize(&t, &m, f->wire, f->size, 16000);
    assert(bridge_cdtunnel_handshake(&t, scratch, f->size - 11u, 100000) == BRIDGE_E_LIMIT);
    assert(m.pos == 10); failed_sticky(&t, &m, BRIDGE_E_LIMIT);
    /* Exact 1024-byte profile boundary, with legitimate trailing whitespace. */
    memcpy(wire, f->wire, f->size); memset(wire + f->size, ' ', sizeof wire - f->size);
    wire[8] = 4; wire[9] = 0;
    initialize(&t, &m, wire, sizeof wire, 16000);
    assert(bridge_cdtunnel_handshake(&t, scratch, sizeof scratch, 100000) == BRIDGE_OK);
    assert(m.pos == sizeof wire);
}
static void test_io_failures_and_deadlines(void) {
    const fixture *f = &fixtures[0];
    uint8_t scratch[BRIDGE_CDTUNNEL_MAX_JSON]; memory_io m; bridge_cdtunnel t;
    for (size_t stage = 0; stage < 2; ++stage) {
        const ptrdiff_t results[] = {0, -BRIDGE_E_TIMEOUT, -BRIDGE_E_IO, -BRIDGE_E_FORMAT};
        for (size_t i = 0; i < sizeof results / sizeof results[0]; ++i) {
            initialize(&t, &m, f->wire, f->size, 16000);
            m.force_read = stage == 0; m.force_write = stage == 1;
            m.forced_read = results[i]; m.forced_write = results[i];
            bridge_status expected = i == 0 ? BRIDGE_E_EOF : (i == 1 ? BRIDGE_E_TIMEOUT : BRIDGE_E_IO);
            assert(bridge_cdtunnel_handshake(&t, scratch, sizeof scratch, 100000) == expected);
            failed_sticky(&t, &m, expected);
        }
        initialize(&t, &m, f->wire, f->size, 16000);
        m.overread = stage == 0; m.overwrite = stage == 1;
        assert(bridge_cdtunnel_handshake(&t, scratch, sizeof scratch, 100000) == BRIDGE_E_IO);
        failed_sticky(&t, &m, BRIDGE_E_IO);
    }
    initialize(&t, &m, f->wire, f->size, 16000);
    assert(bridge_cdtunnel_handshake(&t, scratch, sizeof scratch, 0) == BRIDGE_E_TIMEOUT);
    assert(m.calls == 0); failed_sticky(&t, &m, BRIDGE_E_TIMEOUT);
    initialize(&t, &m, f->wire, f->size, 16000); m.chunk = 1; m.advance = 1;
    assert(bridge_cdtunnel_handshake(&t, scratch, sizeof scratch, 70) == BRIDGE_E_TIMEOUT);
    assert(m.now == 70 && m.last_timeout == 1 && m.written == sizeof expected_request_16000);
    assert(m.pos > 0 && m.pos < f->size); failed_sticky(&t, &m, BRIDGE_E_TIMEOUT);
    initialize(&t, &m, f->wire, f->size, 16000); m.advance = 500;
    assert(bridge_cdtunnel_handshake(&t, scratch, sizeof scratch, 100) == BRIDGE_E_TIMEOUT);
    assert(m.calls == 1); failed_sticky(&t, &m, BRIDGE_E_TIMEOUT);
    /* Parsing/final validation itself remains within the original deadline. */
    initialize(&t, &m, f->wire, f->size, 16000); m.clock_step = 1;
    assert(bridge_cdtunnel_handshake(&t, scratch, sizeof scratch, 6) == BRIDGE_E_TIMEOUT);
    assert(m.pos == f->size); failed_sticky(&t, &m, BRIDGE_E_TIMEOUT);
    initialize(&t, &m, f->wire, f->size, 16000);
    assert(bridge_cdtunnel_handshake(&t, scratch, sizeof scratch, UINT64_MAX) == BRIDGE_OK);
    assert(m.last_timeout == UINT32_MAX);
}
static void open_tunnel(bridge_cdtunnel *t, memory_io *m, uint16_t mtu) {
    const fixture *f = mtu == 16000 ? &fixtures[3] : &fixtures[0];
    uint8_t scratch[BRIDGE_CDTUNNEL_MAX_JSON];
    initialize(t, m, f->wire, f->size, 16000);
    assert(bridge_cdtunnel_handshake(t, scratch, sizeof scratch, 100000) == BRIDGE_OK);
    assert(t->parameters.mtu == mtu);
    m->input = NULL; m->size = m->pos = m->written = m->calls = m->read_calls = m->write_calls = 0;
}
static void ipv6_packet(uint8_t *packet, size_t size) {
    assert(size >= 40 && size <= 65575u);
    memset(packet, 0x5a, size); packet[0] = 0x60;
    packet[4] = (uint8_t)((size - 40u) >> 8); packet[5] = (uint8_t)(size - 40u);
    packet[6] = size == 40 ? 59 : 17; packet[7] = 64;
}
static void test_packet_success(void) {
    uint8_t packet[BRIDGE_CDTUNNEL_MAX_MTU], output[BRIDGE_CDTUNNEL_MAX_MTU];
    memory_io m; bridge_cdtunnel t;
    const size_t sizes[] = {40, 41, 1280, 16000};
    for (size_t i = 0; i < sizeof sizes / sizeof sizes[0]; ++i) {
        ipv6_packet(packet, sizes[i]);
        for (size_t chunk = 0; chunk < 4; ++chunk) {
            open_tunnel(&t, &m, 16000); m.chunk = chunk;
            assert(bridge_cdtunnel_send_ipv6(&t, packet, sizes[i], 100000) == BRIDGE_OK);
            assert(m.written == sizes[i] && !memcmp(m.output, packet, sizes[i]));
            m.input = packet; m.size = sizes[i]; size_t received = 999;
            assert(bridge_cdtunnel_recv_ipv6(&t, output, sizeof output, &received, 100000) == BRIDGE_OK);
            assert(received == sizes[i] && m.pos == sizes[i] && !memcmp(output, packet, received));
        }
    }
    /* Coalesced packets remain separately readable; handshake does not eat IP. */
    uint8_t stream[1024]; const fixture *f = &fixtures[0];
    memcpy(stream, f->wire, f->size); ipv6_packet(stream + f->size, 48); ipv6_packet(stream + f->size + 48, 40);
    initialize(&t, &m, stream, f->size + 88u, 16000);
    assert(bridge_cdtunnel_handshake(&t, output, sizeof output, 100000) == BRIDGE_OK);
    assert(m.pos == f->size);
    size_t received;
    assert(bridge_cdtunnel_recv_ipv6(&t, output, sizeof output, &received, 100000) == BRIDGE_OK);
    assert(received == 48 && m.pos == f->size + 48u);
    assert(bridge_cdtunnel_recv_ipv6(&t, output, sizeof output, &received, 100000) == BRIDGE_OK);
    assert(received == 40 && m.pos == f->size + 88u);
}
static void test_packet_failures(void) {
    uint8_t packet[BRIDGE_CDTUNNEL_MAX_MTU + 1u], output[BRIDGE_CDTUNNEL_MAX_MTU];
    memory_io m; bridge_cdtunnel t; size_t size;
    /* Full MTU capacity is a local precondition and never consumes wire bytes. */
    open_tunnel(&t, &m, 1280); ipv6_packet(packet, 80); m.input = packet; m.size = 80;
    assert(bridge_cdtunnel_recv_ipv6(&t, output, 1279, &size, 100000) == BRIDGE_E_LIMIT);
    assert(size == 0 && m.pos == 0 && m.calls == 0 && t.state == BRIDGE_CDTUNNEL_READY);
    for (size_t n = 0; n < 80; ++n) {
        open_tunnel(&t, &m, 1280); m.input = packet; m.size = n; m.chunk = 3;
        assert(bridge_cdtunnel_recv_ipv6(&t, output, sizeof output, &size, 100000) == BRIDGE_E_EOF);
        assert(size == 0); failed_sticky(&t, &m, BRIDGE_E_EOF);
    }
    for (unsigned variant = 0; variant < 4; ++variant) {
        ipv6_packet(packet, 80);
        bridge_status expected;
        if (variant == 0) { packet[0] = 0x45; expected = BRIDGE_E_FORMAT; }
        else if (variant == 1) { packet[4] = 0xff; packet[5] = 0xff; expected = BRIDGE_E_LIMIT; }
        else if (variant == 2) { packet[4] = 0; packet[5] = 0; packet[6] = 0; expected = BRIDGE_E_UNSUPPORTED; }
        else { ipv6_packet(packet, 1281); expected = BRIDGE_E_LIMIT; }
        open_tunnel(&t, &m, 1280);
        assert(bridge_cdtunnel_send_ipv6(&t, packet, 80, 100000) == expected);
        assert(m.calls == 0 && t.state == BRIDGE_CDTUNNEL_READY);
        m.input = packet; m.size = 80;
        assert(bridge_cdtunnel_recv_ipv6(&t, output, sizeof output, &size, 100000) == expected);
        assert(size == 0 && m.pos == 40); failed_sticky(&t, &m, expected);
    }
    open_tunnel(&t, &m, 16000); ipv6_packet(packet, 80);
    assert(bridge_cdtunnel_send_ipv6(&t, packet, 79, 100000) == BRIDGE_E_FORMAT);
    assert(bridge_cdtunnel_send_ipv6(&t, packet, 81, 100000) == BRIDGE_E_FORMAT);
    assert(bridge_cdtunnel_send_ipv6(&t, packet, 39, 100000) == BRIDGE_E_ARGUMENT);
    assert(m.calls == 0 && t.state == BRIDGE_CDTUNNEL_READY);
    ipv6_packet(packet, sizeof packet);
    assert(bridge_cdtunnel_send_ipv6(&t, packet, sizeof packet, 100000) == BRIDGE_E_LIMIT);
    /* Timeout spans the header AND body; neither short I/O nor packet phase resets it. */
    open_tunnel(&t, &m, 1280); ipv6_packet(packet, 80);
    m.input = packet; m.size = 80; m.chunk = 1; m.advance = 1;
    assert(bridge_cdtunnel_recv_ipv6(&t, output, sizeof output, &size, 60) == BRIDGE_E_TIMEOUT);
    assert(size == 0 && m.pos == 60 && m.last_timeout == 1); failed_sticky(&t, &m, BRIDGE_E_TIMEOUT);
    open_tunnel(&t, &m, 1280); m.chunk = 1; m.advance = 1;
    assert(bridge_cdtunnel_send_ipv6(&t, packet, 80, 60) == BRIDGE_E_TIMEOUT);
    assert(m.written == 60 && m.last_timeout == 1); failed_sticky(&t, &m, BRIDGE_E_TIMEOUT);
    open_tunnel(&t, &m, 1280); m.force_write = true; m.forced_write = -BRIDGE_E_IO;
    assert(bridge_cdtunnel_send_ipv6(&t, packet, 80, 100000) == BRIDGE_E_IO);
    failed_sticky(&t, &m, BRIDGE_E_IO);
    open_tunnel(&t, &m, 1280); m.input = packet; m.size = 80; m.clock_step = 1;
    assert(bridge_cdtunnel_recv_ipv6(&t, output, sizeof output, &size, 4) == BRIDGE_E_TIMEOUT);
    assert(size == 0 && m.pos == 80); failed_sticky(&t, &m, BRIDGE_E_TIMEOUT);
}
static void test_arguments(void) {
    memory_io m; bridge_cdtunnel t; uint8_t scratch[1024]; size_t size = 1;
    bridge_io io = {.context = &m, .read = read_memory, .write = write_memory, .clock_ms = clock_memory};
    assert(bridge_cdtunnel_init(NULL, &io, 16000) == BRIDGE_E_ARGUMENT);
    assert(bridge_cdtunnel_init(&t, NULL, 16000) == BRIDGE_E_ARGUMENT);
    assert(bridge_cdtunnel_init(&t, &io, 1279) == BRIDGE_E_ARGUMENT);
    assert(bridge_cdtunnel_init(&t, &io, 16001) == BRIDGE_E_ARGUMENT);
    io.read = NULL; assert(bridge_cdtunnel_init(&t, &io, 16000) == BRIDGE_E_ARGUMENT); io.read = read_memory;
    io.write = NULL; assert(bridge_cdtunnel_init(&t, &io, 16000) == BRIDGE_E_ARGUMENT); io.write = write_memory;
    io.clock_ms = NULL; assert(bridge_cdtunnel_init(&t, &io, 16000) == BRIDGE_E_ARGUMENT);
    initialize(&t, &m, fixtures[0].wire, fixtures[0].size, 16000);
    assert(bridge_cdtunnel_handshake(&t, NULL, 1024, 100000) == BRIDGE_E_ARGUMENT);
    assert(bridge_cdtunnel_handshake(&t, scratch, 0, 100000) == BRIDGE_E_ARGUMENT);
    assert(bridge_cdtunnel_handshake(NULL, scratch, 1024, 100000) == BRIDGE_E_ARGUMENT);
    assert(bridge_cdtunnel_send_ipv6(&t, scratch, 1024, 100000) == BRIDGE_E_ARGUMENT);
    assert(bridge_cdtunnel_recv_ipv6(&t, scratch, 1024, &size, 100000) == BRIDGE_E_ARGUMENT && size == 0);
    assert(m.calls == 0 && t.state == BRIDGE_CDTUNNEL_NEW);
    open_tunnel(&t, &m, 1280);
    assert(bridge_cdtunnel_send_ipv6(NULL, scratch, 1024, 100000) == BRIDGE_E_ARGUMENT);
    assert(bridge_cdtunnel_send_ipv6(&t, NULL, 1024, 100000) == BRIDGE_E_ARGUMENT);
    assert(bridge_cdtunnel_recv_ipv6(NULL, scratch, 1024, &size, 100000) == BRIDGE_E_ARGUMENT && size == 0);
    assert(bridge_cdtunnel_recv_ipv6(&t, NULL, 1024, &size, 100000) == BRIDGE_E_ARGUMENT && size == 0);
    assert(bridge_cdtunnel_recv_ipv6(&t, scratch, 1024, NULL, 100000) == BRIDGE_E_ARGUMENT);
    assert(m.calls == 0 && t.state == BRIDGE_CDTUNNEL_READY);
}
static void test_mutations(void) {
    const fixture *f = &fixtures[0];
    uint8_t wire[1024], scratch[1024]; memory_io m; bridge_cdtunnel t;
    for (size_t pos = 0; pos < f->size; ++pos) {
        for (unsigned bit = 0; bit < 8; ++bit) {
            memcpy(wire, f->wire, f->size); wire[pos] ^= (uint8_t)(1u << bit);
            initialize(&t, &m, wire, f->size, 16000); m.chunk = 3;
            bridge_status status = bridge_cdtunnel_handshake(&t, scratch, sizeof scratch, 100000);
            if (status != BRIDGE_OK) failed_sticky(&t, &m, status);
            else assert(t.state == BRIDGE_CDTUNNEL_READY && t.parameters.mtu >= 1280 &&
                t.parameters.mtu <= 16000 && t.parameters.server_rsd_port);
        }
    }
    /* Deterministic multiple mutations, random lengths, binary JSON and headers. */
    uint32_t random = UINT32_C(0x4150504c);
    for (unsigned run = 0; run < 6000; ++run) {
        memcpy(wire, f->wire, f->size);
        for (unsigned mutation = 0; mutation < 5; ++mutation) {
            random = random * UINT32_C(1664525) + UINT32_C(1013904223);
            wire[random % f->size] = (uint8_t)(random >> 16);
        }
        random = random * UINT32_C(1664525) + UINT32_C(1013904223);
        size_t length = (run & 1u) ? f->size : random % (f->size + 1u);
        initialize(&t, &m, wire, length, 16000);
        bridge_status status = bridge_cdtunnel_handshake(&t, scratch, sizeof scratch, 100000);
        if (status != BRIDGE_OK) failed_sticky(&t, &m, status);
        else assert(t.state == BRIDGE_CDTUNNEL_READY && t.parameters.mtu >= 1280 &&
            t.parameters.mtu <= 16000 && t.parameters.server_rsd_port);
    }
}
int main(void) {
    test_fixtures(); test_response_framing(); test_io_failures_and_deadlines();
    test_arguments(); test_packet_success(); test_packet_failures(); test_mutations();
    printf("PASS: %zu CDTunnel schema fixtures, exact Python request bytes, short I/O, framing/IPv6 boundaries, deadlines, sticky failure and mutations (synthetic/public only)\n",
        sizeof fixtures / sizeof fixtures[0]);
    return 0;
}
