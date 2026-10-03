/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Protocol reference: pymobiledevice3 cd895d17ce8a97d883c10f87b26c7356d5e0ccb1,
 * service_connection.py:444-477 and lockdown.py:907-928. Upstream uses
 * HostCertificate+HostPrivateKey, TLS >=1.2, no hostname and CERT_NONE.
 * This implementation intentionally fails closed on a mandatory pair leaf pin
 * instead of copying CERT_NONE. No actual Apple handshake has been observed. */
#include "bridge_tls.h"
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include "mbedtls/ctr_drbg.h"
#include "mbedtls/entropy.h"
#include "mbedtls/platform_util.h"
#include "mbedtls/pem.h"
#include "mbedtls/ssl.h"
#include "mbedtls/x509_crt.h"

#if !defined(MBEDTLS_SSL_PROTO_TLS1_2) || !defined(MBEDTLS_SSL_CLI_C)
#error "bridge_tls requires the real mbedTLS TLS 1.2 client"
#endif
#if MBEDTLS_SSL_IN_CONTENT_LEN > BRIDGE_TLS_MAX_RECORD_BYTES || \
    MBEDTLS_SSL_OUT_CONTENT_LEN > BRIDGE_TLS_MAX_RECORD_BYTES
#error "bridge_tls record size exceeds reviewed 16 KiB bound"
#endif

typedef enum { TLS_OPEN, TLS_READY, TLS_FAILED, TLS_CLOSED } tls_state;
struct bridge_tls {
    bridge_io raw;
    mbedtls_ssl_context ssl;
    mbedtls_ssl_config conf;
    mbedtls_x509_crt host, expected;
    mbedtls_pk_context key;
    mbedtls_ctr_drbg_context rng;
    mbedtls_entropy_context entropy;
    uint64_t deadline;
    tls_state state;
    bridge_status transport_error;
    int last_error;
    bool pin_seen, pin_rejected;
};

/* All suites authenticate the peer; no PSK, anonymous, NULL or static DH.
 * TLS 1.3 is deliberately outside this bounded first implementation. */
static const int ciphers[] = {
    MBEDTLS_TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,
    MBEDTLS_TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384,
    MBEDTLS_TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256,
    MBEDTLS_TLS_ECDHE_ECDSA_WITH_AES_256_GCM_SHA384,
    MBEDTLS_TLS_RSA_WITH_AES_128_GCM_SHA256,
    MBEDTLS_TLS_RSA_WITH_AES_256_GCM_SHA384,
    0
};
static bridge_status remaining(bridge_tls *t, uint32_t *ms) {
    uint64_t now = t->raw.clock_ms(t->raw.context);
    if (now >= t->deadline) {
        t->transport_error = BRIDGE_E_TIMEOUT;
        return BRIDGE_E_TIMEOUT;
    }
    uint64_t d = t->deadline - now;
    *ms = d > UINT32_MAX ? UINT32_MAX : (uint32_t)d;
    return BRIDGE_OK;
}
static int raw_result(bridge_tls *t, ptrdiff_t n, size_t len) {
    uint32_t ignored;
    if (remaining(t, &ignored) != BRIDGE_OK) return MBEDTLS_ERR_SSL_TIMEOUT;
    if (n == -(ptrdiff_t)BRIDGE_E_TIMEOUT) {
        t->transport_error = BRIDGE_E_TIMEOUT;
        return MBEDTLS_ERR_SSL_TIMEOUT;
    }
    if (n == 0) {
        t->transport_error = BRIDGE_E_EOF;
        return MBEDTLS_ERR_SSL_CONN_EOF;
    }
    if (n < 0 || (size_t)n > len || n > INT_MAX) {
        t->transport_error = BRIDGE_E_IO;
        return MBEDTLS_ERR_SSL_INTERNAL_ERROR;
    }
    return (int)n;
}
static int raw_recv(void *ctx, unsigned char *buf, size_t len) {
    bridge_tls *t = ctx;
    uint32_t ms;
    if (remaining(t, &ms) != BRIDGE_OK) return MBEDTLS_ERR_SSL_TIMEOUT;
    if (len > INT_MAX) len = INT_MAX;
    return raw_result(t, t->raw.read(t->raw.context, buf, len, ms), len);
}
static int raw_send(void *ctx, const unsigned char *buf, size_t len) {
    bridge_tls *t = ctx;
    uint32_t ms;
    if (remaining(t, &ms) != BRIDGE_OK) return MBEDTLS_ERR_SSL_TIMEOUT;
    if (len > INT_MAX) len = INT_MAX;
    return raw_result(t, t->raw.write(t->raw.context, buf, len, ms), len);
}
static int verify_pin(void *ctx, mbedtls_x509_crt *crt, int depth, uint32_t *flags) {
    bridge_tls *t = ctx;
    /* Additional chain certificates convey no trust. Only the leaf at depth 0
     * can authenticate this connection. Returning a fatal callback error on a
     * mismatch avoids VERIFY_OPTIONAL/VERIFY_NONE-style acceptance. */
    if (depth == 0) {
        if (crt->raw.len != t->expected.raw.len ||
            memcmp(crt->raw.p, t->expected.raw.p, crt->raw.len) != 0) {
            t->pin_rejected = true;
            *flags |= MBEDTLS_X509_BADCERT_OTHER;
            return MBEDTLS_ERR_X509_CERT_VERIFY_FAILED;
        }
        t->pin_seen = true;
    }
    *flags = 0; /* Exact pair pin replaces CA, hostname and validity metadata. */
    return 0;
}
static bool retry(int e) {
    return e == MBEDTLS_ERR_SSL_WANT_READ || e == MBEDTLS_ERR_SSL_WANT_WRITE ||
           e == MBEDTLS_ERR_SSL_CRYPTO_IN_PROGRESS;
}
static bridge_status tls_error(bridge_tls *t, int e) {
    t->last_error = e;
    t->state = TLS_FAILED;
    if (t->transport_error != BRIDGE_OK) return t->transport_error;
    if (e == MBEDTLS_ERR_SSL_TIMEOUT) return BRIDGE_E_TIMEOUT;
    if (e == MBEDTLS_ERR_SSL_PEER_CLOSE_NOTIFY || e == MBEDTLS_ERR_SSL_CONN_EOF)
        return BRIDGE_E_EOF;
    if (t->pin_rejected || e == MBEDTLS_ERR_X509_CERT_VERIFY_FAILED ||
        e == MBEDTLS_ERR_SSL_BAD_CERTIFICATE ||
        e == MBEDTLS_ERR_SSL_NO_CLIENT_CERTIFICATE)
        return BRIDGE_E_TYPE;
    if (e == MBEDTLS_ERR_SSL_ALLOC_FAILED || e == MBEDTLS_ERR_X509_ALLOC_FAILED ||
        e == MBEDTLS_ERR_PK_ALLOC_FAILED || e == MBEDTLS_ERR_PEM_ALLOC_FAILED) return BRIDGE_E_LIMIT;
    return BRIDGE_E_IO;
}
static bool pem(const uint8_t *p, size_t n) {
    return n >= 11 && memcmp(p, "-----BEGIN ", 11) == 0;
}
/* mbedTLS parsers accept trailing data. Enforce complete single-object input
 * before using them, including a PEM's caller-counted optional final NUL. */
static bool exact_der_sequence(const uint8_t *p, size_t n) {
    if (n < 2 || p[0] != 0x30) return false;
    size_t bytes = p[1], header = 2, length = 0;
    if ((bytes & 0x80u) == 0) return bytes == n - header;
    bytes &= 0x7fu;
    if (!bytes || bytes > sizeof(size_t) || bytes > n - header || !p[2]) return false;
    for (size_t i = 0; i < bytes; ++i) {
        if (length > (SIZE_MAX >> 8)) return false;
        length = (length << 8) | p[header + i];
    }
    header += bytes;
    return length >= 128 && length == n - header;
}
static bool whitespace(uint8_t c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}
static bool exact_pem(const uint8_t *p, size_t n, const char *begin, const char *end) {
    if (n && p[n - 1] == 0) --n;
    if (memchr(p, 0, n)) return false;
    size_t b = strlen(begin), e = strlen(end);
    if (n < b + e || memcmp(p, begin, b) != 0) return false;
    for (size_t i = b; i <= n - e; ++i) {
        if (memcmp(p + i, end, e) == 0) {
            for (size_t j = i + e; j < n; ++j) if (!whitespace(p[j])) return false;
            return true;
        }
    }
    return false;
}
static int decode_pem(mbedtls_pem_context *decoded, const uint8_t *p, size_t n,
                      const char *begin, const char *end) {
    if (!exact_pem(p, n, begin, end)) return MBEDTLS_ERR_PEM_INVALID_DATA;
    uint8_t *copy = calloc(1, n + 1);
    if (!copy) return MBEDTLS_ERR_PEM_ALLOC_FAILED;
    memcpy(copy, p, n);
    size_t used = 0;
    int e = mbedtls_pem_read_buffer(decoded, begin, end, copy, NULL, 0, &used);
    /* This helper also handles private-key PEM. The decoded buffer is erased
     * by mbedtls_pem_free after the caller parses or rejects its exact DER. */
    mbedtls_platform_zeroize(copy, n + 1);
    free(copy);
    return e;
}
static int parse_cert(mbedtls_x509_crt *crt, const uint8_t *p, size_t n) {
    if (!pem(p, n)) {
        if (!exact_der_sequence(p, n)) return MBEDTLS_ERR_X509_INVALID_FORMAT;
        return mbedtls_x509_crt_parse_der(crt, p, n);
    }
    mbedtls_pem_context decoded;
    mbedtls_pem_init(&decoded);
    int e = decode_pem(&decoded, p, n, "-----BEGIN CERTIFICATE-----", "-----END CERTIFICATE-----");
    if (!e) {
        size_t len;
        const uint8_t *der = mbedtls_pem_get_buffer(&decoded, &len);
        /* A single visible PEM block may still encode DER || hidden bytes. */
        if (!exact_der_sequence(der, len)) e = MBEDTLS_ERR_X509_INVALID_FORMAT;
        else e = mbedtls_x509_crt_parse_der(crt, der, len);
    }
    mbedtls_pem_free(&decoded);
    return e;
}
static int parse_key(bridge_tls *t, const uint8_t *p, size_t n) {
    if (!pem(p, n)) {
        if (!exact_der_sequence(p, n)) return MBEDTLS_ERR_PK_KEY_INVALID_FORMAT;
        return mbedtls_pk_parse_key(&t->key, p, n, NULL, 0,
                                    mbedtls_ctr_drbg_random, &t->rng);
    }
    static const char *const headers[][2] = {
        {"-----BEGIN PRIVATE KEY-----", "-----END PRIVATE KEY-----"},
        {"-----BEGIN RSA PRIVATE KEY-----", "-----END RSA PRIVATE KEY-----"},
        {"-----BEGIN EC PRIVATE KEY-----", "-----END EC PRIVATE KEY-----"}
    };
    const char *begin = NULL, *end = NULL;
    for (size_t i = 0; i < sizeof headers / sizeof headers[0]; ++i) {
        if (exact_pem(p, n, headers[i][0], headers[i][1])) {
            begin = headers[i][0]; end = headers[i][1]; break;
        }
    }
    if (!begin) return MBEDTLS_ERR_PK_KEY_INVALID_FORMAT;
    mbedtls_pem_context decoded;
    mbedtls_pem_init(&decoded);
    int e = decode_pem(&decoded, p, n, begin, end);
    if (!e) {
        size_t len;
        const uint8_t *der = mbedtls_pem_get_buffer(&decoded, &len);
        if (!exact_der_sequence(der, len)) e = MBEDTLS_ERR_PK_KEY_INVALID_FORMAT;
        else e = mbedtls_pk_parse_key(&t->key, der, len, NULL, 0,
                                      mbedtls_ctr_drbg_random, &t->rng);
    }
    mbedtls_pem_free(&decoded);
    return e;
}
static bool supported_key(const mbedtls_pk_context *pk) {
    size_t bits = mbedtls_pk_get_bitlen(pk);
    return (mbedtls_pk_can_do(pk, MBEDTLS_PK_RSA) && bits >= 2048 && bits <= 4096) ||
           (mbedtls_pk_can_do(pk, MBEDTLS_PK_ECDSA) && bits >= 256 && bits <= 521);
}
bridge_status bridge_tls_open(const bridge_tls_config *cfg, bridge_io *raw,
                              bridge_tls **out) {
    if (!out) return BRIDGE_E_ARGUMENT;
    *out = NULL;
    if (!cfg || !raw || !raw->read || !raw->write || !raw->clock_ms ||
        !cfg->host_certificate || !cfg->host_certificate_len ||
        !cfg->host_private_key || !cfg->host_private_key_len ||
        !cfg->expected_device_certificate || !cfg->expected_device_certificate_len)
        return BRIDGE_E_ARGUMENT;
    if (cfg->host_certificate_len > BRIDGE_TLS_MAX_CERTIFICATE_BYTES ||
        cfg->expected_device_certificate_len > BRIDGE_TLS_MAX_CERTIFICATE_BYTES ||
        cfg->host_private_key_len > BRIDGE_TLS_MAX_PRIVATE_KEY_BYTES)
        return BRIDGE_E_LIMIT;
    bridge_tls *t = calloc(1, sizeof *t);
    if (!t) return BRIDGE_E_LIMIT;
    t->raw = *raw;
    t->state = TLS_OPEN;
    mbedtls_ssl_init(&t->ssl);
    mbedtls_ssl_config_init(&t->conf);
    mbedtls_x509_crt_init(&t->host);
    mbedtls_x509_crt_init(&t->expected);
    mbedtls_pk_init(&t->key);
    mbedtls_ctr_drbg_init(&t->rng);
    mbedtls_entropy_init(&t->entropy);
    static const unsigned char personalization[] = "bridge_tls_pair_client_v1";
    int e = mbedtls_ctr_drbg_seed(&t->rng, mbedtls_entropy_func, &t->entropy,
                                personalization, sizeof personalization - 1);
    if (!e) e = parse_cert(&t->host, cfg->host_certificate, cfg->host_certificate_len);
    if (!e) e = parse_cert(&t->expected, cfg->expected_device_certificate,
                           cfg->expected_device_certificate_len);
    if (!e && (t->host.next || t->expected.next || !supported_key(&t->host.pk) ||
               !supported_key(&t->expected.pk))) e = MBEDTLS_ERR_SSL_BAD_CERTIFICATE;
    if (!e) e = parse_key(t, cfg->host_private_key, cfg->host_private_key_len);
    if (!e) e = mbedtls_pk_check_pair(&t->host.pk, &t->key,
                                     mbedtls_ctr_drbg_random, &t->rng);
    if (!e) e = mbedtls_ssl_config_defaults(&t->conf, MBEDTLS_SSL_IS_CLIENT,
                  MBEDTLS_SSL_TRANSPORT_STREAM, MBEDTLS_SSL_PRESET_DEFAULT);
    if (!e) {
        mbedtls_ssl_conf_min_tls_version(&t->conf, MBEDTLS_SSL_VERSION_TLS1_2);
        mbedtls_ssl_conf_max_tls_version(&t->conf, MBEDTLS_SSL_VERSION_TLS1_2);
        mbedtls_ssl_conf_authmode(&t->conf, MBEDTLS_SSL_VERIFY_REQUIRED);
        /* A non-NULL trust anchor is required by mbedTLS VERIFY_REQUIRED.
         * Even an otherwise valid certificate cannot bypass verify_pin(). */
        mbedtls_ssl_conf_ca_chain(&t->conf, &t->expected, NULL);
        mbedtls_ssl_conf_verify(&t->conf, verify_pin, t);
        mbedtls_ssl_conf_rng(&t->conf, mbedtls_ctr_drbg_random, &t->rng);
        mbedtls_ssl_conf_ciphersuites(&t->conf, ciphers);
#if defined(MBEDTLS_SSL_RENEGOTIATION)
        mbedtls_ssl_conf_renegotiation(&t->conf, MBEDTLS_SSL_RENEGOTIATION_DISABLED);
#endif
#if defined(MBEDTLS_SSL_SESSION_TICKETS)
        mbedtls_ssl_conf_session_tickets(&t->conf, MBEDTLS_SSL_SESSION_TICKETS_DISABLED);
#endif
        e = mbedtls_ssl_conf_own_cert(&t->conf, &t->host, &t->key);
    }
    if (!e) e = mbedtls_ssl_setup(&t->ssl, &t->conf);
    /* Explicit NULL disables DNS/SNI identity. DeviceCertificate pin is the
     * only peer identity; no implicit hostname downgrade is performed. */
    if (!e) e = mbedtls_ssl_set_hostname(&t->ssl, NULL);
    if (e) {
        bridge_status s = tls_error(t, e);
        bridge_tls_destroy(t);
        return s;
    }
    mbedtls_ssl_set_bio(&t->ssl, t, raw_send, raw_recv, NULL);
    *out = t;
    return BRIDGE_OK;
}
bridge_status bridge_tls_handshake(bridge_tls *t, uint64_t deadline) {
    if (!t || t->state != TLS_OPEN) return BRIDGE_E_ARGUMENT;
    t->deadline = deadline;
    t->transport_error = BRIDGE_OK;
    int e;
    do {
        uint32_t ms;
        if (remaining(t, &ms) != BRIDGE_OK) return tls_error(t, MBEDTLS_ERR_SSL_TIMEOUT);
        e = mbedtls_ssl_handshake(&t->ssl);
    } while (retry(e));
    uint32_t ms;
    if (remaining(t, &ms) != BRIDGE_OK) return tls_error(t, MBEDTLS_ERR_SSL_TIMEOUT);
    if (e) return tls_error(t, e);
    if (!t->pin_seen || mbedtls_ssl_get_verify_result(&t->ssl) != 0)
        return tls_error(t, MBEDTLS_ERR_X509_CERT_VERIFY_FAILED);
    t->state = TLS_READY;
    return BRIDGE_OK;
}
static uint64_t io_clock(void *ctx) {
    bridge_tls *t = ctx;
    return t->raw.clock_ms(t->raw.context);
}
static ptrdiff_t io_transfer(bridge_tls *t, uint8_t *read_buf,
                            const uint8_t *write_buf, size_t n, uint32_t ms) {
    if (!t || (!read_buf && !write_buf) || !n || t->state != TLS_READY)
        return -(ptrdiff_t)BRIDGE_E_ARGUMENT;
    uint64_t now = io_clock(t);
    t->deadline = UINT64_MAX - now < ms ? UINT64_MAX : now + ms;
    t->transport_error = BRIDGE_OK;
    if (n > BRIDGE_TLS_MAX_RECORD_BYTES) n = BRIDGE_TLS_MAX_RECORD_BYTES;
    int e;
    do {
        uint32_t rem;
        if (remaining(t, &rem) != BRIDGE_OK)
            return -(ptrdiff_t)tls_error(t, MBEDTLS_ERR_SSL_TIMEOUT);
        e = read_buf ? mbedtls_ssl_read(&t->ssl, read_buf, n) :
                       mbedtls_ssl_write(&t->ssl, write_buf, n);
    } while (retry(e));
    uint32_t rem;
    if (remaining(t, &rem) != BRIDGE_OK)
        return -(ptrdiff_t)tls_error(t, MBEDTLS_ERR_SSL_TIMEOUT);
    if (e <= 0) {
        bridge_status s = tls_error(t, e ? e : MBEDTLS_ERR_SSL_CONN_EOF);
        return s == BRIDGE_E_EOF ? 0 : -(ptrdiff_t)s;
    }
    return e;
}
static ptrdiff_t io_read(void *ctx, uint8_t *buf, size_t n, uint32_t ms) {
    return io_transfer(ctx, buf, NULL, n, ms);
}
static ptrdiff_t io_write(void *ctx, const uint8_t *buf, size_t n, uint32_t ms) {
    return io_transfer(ctx, NULL, buf, n, ms);
}
bridge_status bridge_tls_get_io(bridge_tls *t, bridge_io *out) {
    if (!t || !out || t->state != TLS_READY) return BRIDGE_E_ARGUMENT;
    *out = (bridge_io){t, io_read, io_write, io_clock};
    return BRIDGE_OK;
}
bridge_status bridge_tls_pending(bridge_tls *t, size_t *out) {
    if (!out) return BRIDGE_E_ARGUMENT;
    *out = 0;
    if (!t || t->state != TLS_READY) return BRIDGE_E_ARGUMENT;
    *out = mbedtls_ssl_get_bytes_avail(&t->ssl);
    return BRIDGE_OK;
}
bridge_status bridge_tls_close(bridge_tls *t, uint64_t deadline) {
    if (!t) return BRIDGE_E_ARGUMENT;
    if (t->state != TLS_READY) { t->state = TLS_CLOSED; return BRIDGE_OK; }
    t->deadline = deadline;
    t->transport_error = BRIDGE_OK;
    int e;
    do {
        uint32_t ms;
        if (remaining(t, &ms) != BRIDGE_OK) return tls_error(t, MBEDTLS_ERR_SSL_TIMEOUT);
        e = mbedtls_ssl_close_notify(&t->ssl);
    } while (retry(e));
    uint32_t ms;
    if (remaining(t, &ms) != BRIDGE_OK) return tls_error(t, MBEDTLS_ERR_SSL_TIMEOUT);
    if (e) return tls_error(t, e);
    t->state = TLS_CLOSED;
    return BRIDGE_OK;
}
void bridge_tls_destroy(bridge_tls *t) {
    if (!t) return;
    mbedtls_ssl_free(&t->ssl);
    mbedtls_ssl_config_free(&t->conf);
    mbedtls_x509_crt_free(&t->host);
    mbedtls_x509_crt_free(&t->expected);
    mbedtls_pk_free(&t->key);
    mbedtls_ctr_drbg_free(&t->rng);
    mbedtls_entropy_free(&t->entropy);
    mbedtls_platform_zeroize(t, sizeof *t);
    free(t);
}
int bridge_tls_last_error(const bridge_tls *t) { return t ? t->last_error : 0; }
