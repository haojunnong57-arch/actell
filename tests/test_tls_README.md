# Actual TLS adapter validation

Run `tools/test_tls.sh` after sourcing **ESP-IDF v5.5.5** (`IDF_PATH`), or set
`MBEDTLS_SOURCE_DIR` to its complete mbedTLS source directory. CMake, a host C11
compiler and Python 3 with OpenSSL-backed `ssl` are required. `CMAKE`, `CC`,
`PYTHON` and `BUILD_JOBS` can override tools. The script compiles the **real**
mbedTLS library and the same `bridge_tls.c` used by firmware; it does not replace
cryptography or TLS APIs with stubs. All connections are loopback-only.

## Reference and test identity provenance

- pymobiledevice3 commit
  [`cd895d17ce8a97d883c10f87b26c7356d5e0ccb1`](https://github.com/doronz88/pymobiledevice3/tree/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1):
  `service_connection.py:444–477` configures client TLS 1.2–1.3, no hostname and
  `CERT_NONE`; `lockdown.py:907–928` uses HostCertificate + HostPrivateKey.
- ESP-IDF v5.5.5 pins Espressif mbedTLS
  [`9d669eadb1955d348986b9280156710aaaadf79f`](https://github.com/espressif/mbedtls/tree/9d669eadb1955d348986b9280156710aaaadf79f),
  reporting mbedTLS 3.6.6. Tests read `framework/data_files/cli-rsa-sha256.crt`,
  `cli-rsa.key`, `server2-sha256.crt`, `server2.key`, `server1.crt`, `server1.key`
  and `test-ca-sha256.crt`, plus `server2-sha256.crt.der`, `cli-rsa-sha256.crt.der` and `cli-rsa-sha256.key.der`, **from that upstream checkout**. The framework's
  `LICENSE` permits Apache-2.0 OR GPL-2.0-or-later.
- These are already-public, deliberately insecure **test identities**. They are
  not copied into this repository, provisioned into a device, persisted as pair
  identities, embedded or linked into any firmware target. No credential
  generation or user/device credential access is part of this suite.

## Authentication policy

The adapter intentionally strengthens upstream's `CERT_NONE`: it requires the
caller-provided expected DeviceCertificate, uses `VERIFY_REQUIRED`, compares the
presented leaf's full DER bytes, then verifies TLS Finished/key possession.
Additional chain certificates cannot provide an alternate identity. Pair-pinned
certificate CA/hostname/date metadata is not used as the trust decision; ordinary
TLS key-usage/cipher checks still apply. Host cert/private key must match.

There is no unauthenticated compatibility flag, fallback, session resumption or
renegotiation. TLS **1.2 only**, with RSA/ECDSA-authenticated AES-GCM suites; RSA
keys are limited to 2048–4096 bits and EC keys to 256–521 bits. Device pin changes,
unsupported ciphers or protocol versions fail closed. The fact that Apple
actually presents the same leaf as a saved DeviceCertificate has **not** been
verified on physical hardware. This policy is not a claim of parity with every
pymobiledevice3-supported device.

## Tested behavior

- Independent OpenSSL TLS server requires and verifies the exact public test
  client certificate; raw reads are capped at 5 bytes and writes at 3 bytes
- 10,000-byte encrypted round trip and close-notify; no-I/O pending-plaintext
  inspection in open, live, buffered, drained and terminal states
- Required identity, 8 KiB input caps, malformed input, cert/key mismatch and
  multiple/trailing/hidden certificates and keys, complete DER/PEM consumption
  (including extra DER bytes hidden inside a single base64 PEM block);
  injected failure at every open-time calloc cleans up
- Peer pin mismatch, expired deadline, overlong/overreporting raw callback,
  handshake/read/write timeouts, positive-byte slow-drip deadline, handshake OOM
- EOF, fatal TLS alert, plaintext instead of TLS, oversized TLS record,
  TLS 1.1 downgrade and TLS 1.3-only incompatibility, corrupted authenticated
  application record, no I/O exposure or handshake reuse after terminal failure
- Real core lockdown state machine + independent `plistlib` peer:
  plaintext StartSession → pinned TLS → encrypted StartService → a second
  service stream → encrypted StopSession, with XML and binary replies
- Both plaintext service and **two simultaneously live TLS contexts**; a
  mismatched second-channel certificate closes both streams without reuse
- Teardown is idempotent, frees tracked allocations, and clears session ID and
  workspace; the standalone TLS component never closes the caller-owned raw fd

The host library and adapter are compiled with ASan/UBSan and strict warnings.
LeakSanitizer is disabled because the execution harness uses ptrace; a
host-only linker wrapper separately checks tracked calloc allocations return to
zero, including fault paths. It does **not** change production allocator hooks.

## Memory and timing limits

The adapter limits each caller identity blob to 8 KiB and accepts only builds
with TLS input/output record limits at most 16 KiB. It never stores whole
application messages. Its own temporary private-key copy is explicitly erased;
mbedTLS frees its parsed key and DRBG state. Caller-owned input buffers remain
the caller's responsibility.

There is **no strict total mbedTLS heap ceiling**. TLS certificate parsing and
crypto allocate internally, and a peer certificate chain may consume additional
bounded-record-dependent allocations. The existing application's allocator is
left unchanged. CPU crypto and a misbehaving raw callback cannot be preempted;
deadlines are checked before and after calls. The raw stream must honor each
remaining timeout, and its clock must be monotonic.

Observed Linux x86-64 default-library calloc **payload** peaks: 60,356 bytes for
one successful fixture and 110,996 bytes while two TLS fixture contexts are live.
These are measurements for one test handshake, not upper bounds. They exclude
allocator metadata, other allocations, stack, USB buffers and application state.
The host defaults used 16 KiB input + 16 KiB output buffers; ESP-IDF's reviewed
firmware config uses 16 KiB input + 4 KiB output and its own allocator. Host
numbers do not establish ESP32 RAM usage or prove the overall 8 MB target.

Still unverified: physical iPhone handshake/pin compatibility, real pair-identity
provisioning, USB transport + TLS on hardware, CoreDevice tunnel readiness,
end-to-end image transfer and firmware heap/stack high-water under real traffic.
