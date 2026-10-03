/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "test_tls_support.h"
#include "mbedtls/pem.h"
static void local_tests(const bridge_tls_config *cfg, bridge_io *raw, const char *dir) {
    bridge_tls *t = NULL;
    bridge_tls_config c = *cfg;
    assert(bridge_tls_open(NULL, raw, &t) == BRIDGE_E_ARGUMENT && !t);
    c.expected_device_certificate = NULL;
    assert(bridge_tls_open(&c, raw, &t) == BRIDGE_E_ARGUMENT && !t);
    c = *cfg; c.host_private_key_len = BRIDGE_TLS_MAX_PRIVATE_KEY_BYTES + 1u;
    assert(bridge_tls_open(&c, raw, &t) == BRIDGE_E_LIMIT && !t);
    c = *cfg; c.host_certificate_len = BRIDGE_TLS_MAX_CERTIFICATE_BYTES + 1u;
    assert(bridge_tls_open(&c, raw, &t) == BRIDGE_E_LIMIT && !t);
    c = *cfg; c.expected_device_certificate_len = BRIDGE_TLS_MAX_CERTIFICATE_BYTES + 1u;
    assert(bridge_tls_open(&c, raw, &t) == BRIDGE_E_LIMIT && !t);
    c = *cfg; c.host_private_key = (const uint8_t *)"not a key"; c.host_private_key_len = 9;
    assert(bridge_tls_open(&c, raw, &t) != BRIDGE_OK && !t);
    c = *cfg; c.host_certificate = cfg->expected_device_certificate;
    c.host_certificate_len = cfg->expected_device_certificate_len;
    assert(bridge_tls_open(&c, raw, &t) != BRIDGE_OK && !t);
    assert(heap_live == 0);
    uint8_t *double_cert = malloc(cfg->expected_device_certificate_len * 2); assert(double_cert);
    memcpy(double_cert, cfg->expected_device_certificate, cfg->expected_device_certificate_len);
    memcpy(double_cert + cfg->expected_device_certificate_len,
           cfg->expected_device_certificate, cfg->expected_device_certificate_len);
    c = *cfg; c.expected_device_certificate = double_cert;
    c.expected_device_certificate_len *= 2;
    assert(bridge_tls_open(&c, raw, &t) != BRIDGE_OK && !t);
    free(double_cert);
    /* Full-consumption regressions: the underlying parsers tolerate trailing
     * DER/PEM bytes, so the adapter itself must reject them. */
    for (unsigned field = 0; field < 3; ++field) {
        const uint8_t *src = field == 0 ? cfg->expected_device_certificate :
                             field == 1 ? cfg->host_certificate : cfg->host_private_key;
        size_t n = field == 0 ? cfg->expected_device_certificate_len :
                   field == 1 ? cfg->host_certificate_len : cfg->host_private_key_len;
        uint8_t *altered = malloc(n * 2 + 8); assert(altered);
        for (unsigned variant = 0; variant < 3; ++variant) {
            memcpy(altered, src, n);
            size_t changed;
            if (variant == 0) { altered[n] = 0; changed = n + 1; }
            else if (variant == 1) { altered[n] = 'X'; changed = n + 1; }
            else { altered[n] = 0; memcpy(altered + n + 1, src, n); changed = n * 2 + 1; }
            c = *cfg;
            if (field == 0) { c.expected_device_certificate = altered; c.expected_device_certificate_len = changed; }
            else if (field == 1) { c.host_certificate = altered; c.host_certificate_len = changed; }
            else { c.host_private_key = altered; c.host_private_key_len = changed; }
            bridge_status result = bridge_tls_open(&c, raw, &t);
            if (variant == 0) { assert(result == BRIDGE_OK); bridge_tls_destroy(t); }
            else { assert(result != BRIDGE_OK && !t); }
            assert(heap_live == 0);
        }
        free(altered);
    }
    size_t der_len;
    uint8_t *der = read_file(dir, "server2-sha256.crt.der", &der_len);
    uint8_t *altered = malloc(der_len * 2 + 1); assert(altered);
    memcpy(altered, der, der_len); memcpy(altered + der_len, der, der_len);
    for (unsigned variant = 0; variant < 3; ++variant) {
        c = *cfg; c.expected_device_certificate = altered;
        c.expected_device_certificate_len = variant == 0 ? der_len : variant == 1 ? der_len + 1 : der_len * 2;
        bridge_status result = bridge_tls_open(&c, raw, &t);
        if (variant == 0) { assert(result == BRIDGE_OK); bridge_tls_destroy(t); }
        else assert(result != BRIDGE_OK && !t);
        assert(heap_live == 0);
    }
    free(altered); free(der);
    /* A single visible PEM can base64-encode DER||DER or DER||junk.
     * Encoding public upstream fixtures does not generate an identity/key. */
    static const char *const der_files[] = {"server2-sha256.crt.der", "cli-rsa-sha256.crt.der", "cli-rsa-sha256.key.der"};
    for (unsigned field = 0; field < 3; ++field) {
        der = read_file(dir, der_files[field], &der_len);
        altered = malloc(der_len * 2 + 1); assert(altered);
        memcpy(altered, der, der_len); memcpy(altered + der_len, der, der_len);
        for (unsigned variant = 0; variant < 3; ++variant) {
            uint8_t encoded[8192]; size_t encoded_len = 0;
            size_t len = variant == 0 ? der_len : variant == 1 ? der_len + 1 : der_len * 2;
            const char *begin = field == 2 ? "-----BEGIN PRIVATE KEY-----\n" : "-----BEGIN CERTIFICATE-----\n";
            const char *end = field == 2 ? "-----END PRIVATE KEY-----\n" : "-----END CERTIFICATE-----\n";
            assert(mbedtls_pem_write_buffer(begin, end, altered, len, encoded, sizeof encoded, &encoded_len) == 0);
            c = *cfg;
            if (field == 0) { c.expected_device_certificate = encoded; c.expected_device_certificate_len = encoded_len; }
            else if (field == 1) { c.host_certificate = encoded; c.host_certificate_len = encoded_len; }
            else { c.host_private_key = encoded; c.host_private_key_len = encoded_len; }
            bridge_status result = bridge_tls_open(&c, raw, &t);
            if (variant == 0) { assert(result == BRIDGE_OK); bridge_tls_destroy(t); }
            else assert(result != BRIDGE_OK && !t);
            assert(heap_live == 0);
        }
        free(altered); free(der);
    }
    /* Inject failure at each calloc in open; every partial context is freed. */
    bool reached_success = false;
    for (size_t i = 0; i < 256; ++i) {
        fail_after = i; heap_count = 0;
        bridge_status s = bridge_tls_open(cfg, raw, &t);
        if (s == BRIDGE_OK) { reached_success = true; bridge_tls_destroy(t); }
        else assert(!t);
        assert(heap_live == 0);
        if (reached_success) break;
    }
    fail_after = SIZE_MAX;
    assert(reached_success);
    puts("PASS: missing/oversize/malformed/mismatched/multiple/trailing/hidden identity rejection, PEM/DER and allocation failure cleanup");
}
int main(int argc, char **argv) {
    assert(argc == 4);
    signal(SIGPIPE, SIG_IGN);
    const char *mode = argv[2];
    transport tr = {.fd = -1, .read_cap = 5, .write_cap = 3};
    bridge_io raw = {&tr, read_cb, write_cb, clock_ms}, secure = {0};
    bridge_tls_config cfg = {0};
    cfg.host_certificate = read_file(argv[1], "cli-rsa-sha256.crt", &cfg.host_certificate_len);
    cfg.host_private_key = read_file(argv[1], "cli-rsa.key", &cfg.host_private_key_len);
    const char *pin = strcmp(mode, "pin_mismatch") == 0 ? "server1.crt" : "server2-sha256.crt";
    cfg.expected_device_certificate = read_file(argv[1], pin, &cfg.expected_device_certificate_len);
    if (strcmp(mode, "local") == 0) { local_tests(&cfg, &raw, argv[1]); goto finish; }
    bridge_tls *tls = NULL;
    assert(bridge_tls_open(&cfg, &raw, &tls) == BRIDGE_OK && tls);
    assert(bridge_tls_get_io(tls, &secure) == BRIDGE_E_ARGUMENT);
    size_t pending = 99;
    assert(bridge_tls_pending(tls, &pending) == BRIDGE_E_ARGUMENT && pending == 0);
    assert(bridge_tls_pending(tls, NULL) == BRIDGE_E_ARGUMENT);
    tr.fd = socket(AF_INET, SOCK_STREAM, 0); assert(tr.fd >= 0);
    struct sockaddr_in addr = {.sin_family = AF_INET,
        .sin_port = htons((uint16_t)strtoul(argv[3], NULL, 10))};
    assert(inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr) == 1);
    assert(connect(tr.fd, (struct sockaddr *)&addr, sizeof addr) == 0);
    assert(fcntl(tr.fd, F_SETFL, O_NONBLOCK) == 0);
    bool expired = strcmp(mode, "expired_deadline") == 0;
    tr.overrun = strcmp(mode, "callback_overrun") == 0;
    tr.overreport = strcmp(mode, "callback_overreport") == 0;
    uint64_t start = clock_ms(&tr);
    uint64_t deadline = start + ((strcmp(mode, "handshake_timeout") == 0 || strcmp(mode, "slow_drip") == 0) ? 120u : 5000u);
    if (strcmp(mode, "handshake_oom") == 0) fail_after = heap_count;
    bridge_status got = bridge_tls_handshake(tls, expired ? start : deadline);
    bool good = strcmp(mode, "happy") == 0 || strcmp(mode, "close_notify") == 0 ||
        strcmp(mode, "read_timeout") == 0 || strcmp(mode, "write_timeout") == 0 ||
        strcmp(mode, "record_corruption") == 0;
    if (!good) {
        bridge_status expected = BRIDGE_E_IO;
        if (strcmp(mode, "pin_mismatch") == 0) expected = BRIDGE_E_TYPE;
        if (expired || tr.overrun || strcmp(mode, "handshake_timeout") == 0 || strcmp(mode, "slow_drip") == 0)
            expected = BRIDGE_E_TIMEOUT;
        if (strcmp(mode, "eof") == 0) expected = BRIDGE_E_EOF;
        if (strcmp(mode, "handshake_oom") == 0) { assert(got != BRIDGE_OK); expected = got; }
        if (got != expected) fprintf(stderr, "mode=%s expected=%s got=%s tls=%d\n",
            mode, bridge_status_name(expected), bridge_status_name(got), bridge_tls_last_error(tls));
        assert(got == expected);
        if (strcmp(mode, "slow_drip") == 0) assert(clock_ms(&tr) - start < 300u);
        assert(bridge_tls_get_io(tls, &secure) == BRIDGE_E_ARGUMENT);
        assert(bridge_tls_handshake(tls, deadline) == BRIDGE_E_ARGUMENT);
        if (expired) assert(tr.reads == 0 && tr.writes == 0);
    } else {
        if (got) fprintf(stderr, "handshake failed %s: %s TLS=%d\n", mode,
                         bridge_status_name(got), bridge_tls_last_error(tls));
        assert(got == BRIDGE_OK);
        assert(bridge_tls_get_io(tls, &secure) == BRIDGE_OK);
        size_t calls = tr.reads + tr.writes;
        assert(bridge_tls_pending(tls, &pending) == BRIDGE_OK && pending == 0);
        assert(tr.reads + tr.writes == calls);
        uint8_t b[10000];
        if (strcmp(mode, "happy") == 0) {
            for (size_t i = 0; i < sizeof b; ++i) b[i] = (uint8_t)(i % 251u);
            assert(bridge_write_exact(&secure, b, sizeof b, clock_ms(&tr) + 5000) == BRIDGE_OK);
            memset(b, 0, sizeof b);
            assert(bridge_read_exact(&secure, b, 1, clock_ms(&tr) + 5000) == BRIDGE_OK);
            calls = tr.reads + tr.writes;
            assert(bridge_tls_pending(tls, &pending) == BRIDGE_OK && pending == 96);
            assert(tr.reads + tr.writes == calls);
            assert(bridge_read_exact(&secure, b + 1, sizeof b - 1, clock_ms(&tr) + 5000) == BRIDGE_OK);
            assert(bridge_tls_pending(tls, &pending) == BRIDGE_OK && pending == 0);
            for (size_t i = 0; i < sizeof b; ++i) assert(b[i] == (uint8_t)(i % 251u));
            assert(tr.reads > 100 && tr.writes > 100);
            assert(bridge_tls_close(tls, clock_ms(&tr) + 5000) == BRIDGE_OK);
        } else if (strcmp(mode, "close_notify") == 0) {
            assert(secure.read(secure.context, b, 1, 5000) == 0);
        } else if (strcmp(mode, "write_timeout") == 0) {
            tr.overrun = true;
            assert(secure.write(secure.context, (const uint8_t *)"x", 1, 100) == -(ptrdiff_t)BRIDGE_E_TIMEOUT);
        } else {
            ptrdiff_t n = secure.read(secure.context, b, 1, 120);
            assert(n == -(ptrdiff_t)(strcmp(mode, "read_timeout") == 0 ? BRIDGE_E_TIMEOUT : BRIDGE_E_IO));
        }
        assert(bridge_tls_get_io(tls, &secure) == BRIDGE_E_ARGUMENT);
    }
    pending = 99;
    assert(bridge_tls_pending(tls, &pending) == BRIDGE_E_ARGUMENT && pending == 0);
    bridge_tls_destroy(tls);
    assert(fcntl(tr.fd, F_GETFD) >= 0); /* TLS never takes ownership of raw fd. */
    close(tr.fd);
    assert(heap_live == 0);
    printf("PASS: %s; observed calloc payload peak=%zu bytes (host only)\n", mode, heap_peak);
finish:
    free((void *)cfg.host_certificate); free((void *)cfg.host_private_key);
    free((void *)cfg.expected_device_certificate);
    assert(heap_live == 0);
    return 0;
}
