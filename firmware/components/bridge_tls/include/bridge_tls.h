/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_TLS_H
#define BRIDGE_TLS_H
#include "bridge_core.h"

#define BRIDGE_TLS_MAX_CERTIFICATE_BYTES 8192u
#define BRIDGE_TLS_MAX_PRIVATE_KEY_BYTES 8192u
#define BRIDGE_TLS_MAX_RECORD_BYTES 16384u

typedef struct bridge_tls bridge_tls;
typedef struct {
    /* Caller-provided existing pair identity only. No filesystem, provisioning,
     * generation, persistence or ambient credential lookup is performed.
     * A PEM length may include its trailing NUL; DER lengths must be exact.
     * Exactly one certificate per field; encrypted private keys unsupported.
     * Inputs are parsed/copied during open and may be released afterwards. */
    const uint8_t *host_certificate;
    size_t host_certificate_len;
    const uint8_t *host_private_key;
    size_t host_private_key_len;
    const uint8_t *expected_device_certificate;
    size_t expected_device_certificate_len;
} bridge_tls_config;

/* Uses the application's existing mbedTLS allocator; NEVER changes global hooks.
 * Input/record sizes are bounded, but this is NOT a strict total heap budget.
 * Peer handshake parsing and crypto also allocate. Two live channels need two
 * contexts; measure total ESP-IDF high-water on real hardware before sizing RAM.
 * Only one task may operate on a particular context at a time.
 * raw must remain alive until destroy. Caller owns/always closes raw transport.
 * open performs local parsing and RNG initialization, never transport I/O.
 * No input/key/certificate material is logged. */
bridge_status bridge_tls_open(const bridge_tls_config *, bridge_io *raw,
                              bridge_tls **out);
/* TLS 1.2 only, authenticated RSA/ECDSA AES-GCM suites. Exact DER leaf pin is
 * REQUIRED. It intentionally replaces CA/hostname/time identity checks for a
 * locally authorized pair certificate; possession is proved by TLS Finished
 * and the certificate's private key. This is stricter than upstream CERT_NONE.
 * Real Apple device leaf presentation and cipher support remain unverified.
 * Absolute deadline uses raw->clock_ms; callbacks must honor remaining timeout.
 * CPU crypto and an overlong raw callback cannot be preempted; checked after.
 * Any handshake/record failure is terminal, including timeout; no downgrade. */
bridge_status bridge_tls_handshake(bridge_tls *, uint64_t deadline_ms);
/* Returns usable bridge_io ONLY after a successful, pinned handshake.
 * Its callbacks preserve an overall absolute deadline across all internal
 * TLS short reads/writes, derived from the caller's remaining timeout. */
bridge_status bridge_tls_get_io(bridge_tls *, bridge_io *out);
/* Nonblocking, no transport I/O, no crypto or state advancement. Reports only
 * already-decrypted buffered plaintext, NOT bytes buffered in the raw stream.
 * READY only; on an invalid/terminal session writes zero when out is non-NULL.
 * Same single-owner and context-lifetime requirements as the other operations. */
bridge_status bridge_tls_pending(bridge_tls *, size_t *decrypted_bytes);
/* Sends close_notify if still live; does not close or free the raw transport.
 * Best effort under the absolute deadline. Destroy never performs network I/O. */
bridge_status bridge_tls_close(bridge_tls *, uint64_t deadline_ms);
void bridge_tls_destroy(bridge_tls *);
/* Diagnostic numeric mbedTLS error only; never contains identity material.
 * Certificate/pin rejection is BRIDGE_E_TYPE; other TLS errors BRIDGE_E_IO. */
int bridge_tls_last_error(const bridge_tls *);
#endif
