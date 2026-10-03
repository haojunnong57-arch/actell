/* SPDX-License-Identifier: GPL-3.0-or-later
 * Real lockdown state machine + real mbedTLS; loopback test transport only. */
#include "test_tls_support.h"
#include "bridge_lockdown_session.h"
typedef struct {
    transport raw[2];
    bridge_tls *tls[2];
    unsigned opened, upgrades, closed[2];
} harness;
static bridge_status connect_raw(transport *t, uint16_t port, bridge_io *out) {
    t->fd = socket(AF_INET, SOCK_STREAM, 0);
    if (t->fd < 0) return BRIDGE_E_IO;
    struct sockaddr_in addr = {.sin_family = AF_INET, .sin_port = htons(port)};
    assert(inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr) == 1);
    if (connect(t->fd, (struct sockaddr *)&addr, sizeof addr) != 0) return BRIDGE_E_IO;
    assert(fcntl(t->fd, F_SETFL, O_NONBLOCK) == 0);
    t->read_cap = 5; t->write_cap = 3;
    *out = (bridge_io){t, read_cb, write_cb, clock_ms};
    return BRIDGE_OK;
}
static bridge_status service_open(void *ctx, uint16_t port, bridge_io *out, uint64_t deadline) {
    harness *h = ctx;
    assert(clock_ms(&h->raw[0]) < deadline);
    ++h->opened;
    return connect_raw(&h->raw[1], port, out);
}
static bridge_status tls_start(void *ctx, bridge_lockdown_channel channel,
    bridge_io *io, const void *opaque, uint64_t deadline) {
    harness *h = ctx;
    assert(channel == BRIDGE_LOCKDOWN_CHANNEL_SESSION || channel == BRIDGE_LOCKDOWN_CHANNEL_SERVICE);
    ++h->upgrades;
    bridge_status s = bridge_tls_open(opaque, io, &h->tls[channel]);
    if (s == BRIDGE_OK) s = bridge_tls_handshake(h->tls[channel], deadline);
    if (s == BRIDGE_OK) s = bridge_tls_get_io(h->tls[channel], io);
    return s;
}
static void channel_close(void *ctx, bridge_lockdown_channel channel, bridge_io *io) {
    harness *h = ctx;
    (void)io;
    ++h->closed[channel];
    bridge_tls_destroy(h->tls[channel]); h->tls[channel] = NULL;
    if (h->raw[channel].fd >= 0) { close(h->raw[channel].fd); h->raw[channel].fd = -1; }
}
int main(int argc, char **argv) {
    assert(argc == 4);
    signal(SIGPIPE, SIG_IGN);
    bool encrypted_service = strcmp(argv[2], "lockdown_plain_service") != 0;
    bool service_mismatch = strcmp(argv[2], "lockdown_service_mismatch") == 0;
    harness h = {.raw = {{.fd = -1}, {.fd = -1}}};
    bridge_tls_config cfg = {0};
    cfg.host_certificate = read_file(argv[1], "cli-rsa-sha256.crt", &cfg.host_certificate_len);
    cfg.host_private_key = read_file(argv[1], "cli-rsa.key", &cfg.host_private_key_len);
    cfg.expected_device_certificate = read_file(argv[1], "server2-sha256.crt", &cfg.expected_device_certificate_len);
    bridge_lockdown_pair_identity identity = {"SYNTHETIC-HOST", "SYNTHETIC-BUID", &cfg};
    bridge_lockdown_session_ops ops = {&h, service_open, tls_start, channel_close};
    bridge_io raw = {0};
    assert(connect_raw(&h.raw[0], (uint16_t)strtoul(argv[3], NULL, 10), &raw) == BRIDGE_OK);
    uint8_t workspace[BRIDGE_LOCKDOWN_SESSION_MAX_WORKSPACE];
    bridge_lockdown_session session;
    assert(bridge_lockdown_session_init(&session, &raw, &ops, &identity,
                                        workspace, sizeof workspace) == BRIDGE_OK);
    uint64_t deadline = clock_ms(&h.raw[0]) + 10000;
    bridge_status s = bridge_lockdown_session_start(&session, deadline);
    if (s != BRIDGE_OK) fprintf(stderr, "start=%s failure=%d\n", bridge_status_name(s), session.failure);
    assert(s == BRIDGE_OK && session.session_ssl && h.upgrades == 1);
    s = bridge_lockdown_session_start_coredevice_proxy(&session, deadline);
    if (service_mismatch) {
        assert(s == BRIDGE_E_TYPE);
        assert(session.state == BRIDGE_LOCKDOWN_FAILED);
        assert(!bridge_lockdown_session_service_io(&session));
    } else {
        if (s != BRIDGE_OK) fprintf(stderr, "service=%s failure=%d\n", bridge_status_name(s), session.failure);
        assert(s == BRIDGE_OK && session.service_ssl == encrypted_service);
        bridge_io *service = bridge_lockdown_session_service_io(&session); assert(service);
        assert(bridge_write_exact(service, (const uint8_t *)"ping", 4, deadline) == BRIDGE_OK);
        uint8_t reply[4];
        assert(bridge_read_exact(service, reply, sizeof reply, deadline) == BRIDGE_OK);
        assert(memcmp(reply, "pong", 4) == 0);
        assert(h.tls[0] && (h.tls[1] != NULL) == encrypted_service);
        assert(bridge_lockdown_session_stop(&session, deadline) == BRIDGE_OK);
        assert(session.state == BRIDGE_LOCKDOWN_CLOSED);
    }
    assert(h.opened == 1 && h.upgrades == (encrypted_service ? 2u : 1u));
    assert(h.closed[0] == 1 && h.closed[1] == 1);
    assert(!h.tls[0] && !h.tls[1] && h.raw[0].fd == -1 && h.raw[1].fd == -1);
    assert(session.session_id[0] == '\0');
    for (size_t i = 0; i < sizeof workspace; ++i) assert(workspace[i] == 0);
    bridge_lockdown_session_close(&session);
    assert(h.closed[0] == 1 && h.closed[1] == 1);
    free((void *)cfg.host_certificate); free((void *)cfg.host_private_key);
    free((void *)cfg.expected_device_certificate);
    assert(heap_live == 0);
    printf("PASS: %s actual StartSession→TLS→StartService→%s; host calloc payload peak=%zu bytes\n",
           argv[2], service_mismatch ? "pin rejection/terminal teardown" : "service IO→encrypted StopSession", heap_peak);
    return 0;
}
