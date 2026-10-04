# Bounded RSD discovery and service connections

`bridge_rsd` implements a real synchronous Remote Service Discovery protocol
flow over a supplied TCP dialer and the existing HTTP/2/RemoteXPC session.
It does not provide pairing, a tunnel, DDI mounting, HID authorization, or evidence
that any operation works on a physical iPhone.

## Source and wire behavior

The reference is pymobiledevice3 commit
[`cd895d17ce8a97d883c10f87b26c7356d5e0ccb1`](https://github.com/doronz88/pymobiledevice3/tree/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1):

- [`remote/remotexpc.py`](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/remote/remotexpc.py):
  `_do_handshake`, `send_device_handshake`, `receive_response`
- [`remote/remote_service_discovery.py`](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/remote/remote_service_discovery.py):
  `connect`, `get_service_port`, `require_feature`, `start_remote_service`
- [`remote/core_device`](https://github.com/doronz88/pymobiledevice3/tree/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/remote/core_device):
  `screen_capture_service.py`, `display_service.py`, `hid_service.py`

Connect performs these steps with one caller-supplied absolute deadline:

1. Dial the negotiated tunnel server's IPv6 address and RSD port
2. Run the RemoteXPC HTTP/2 handshake, retaining bounded receive windows
3. Send the modern device handshake on the root stream, application ID 1,
   `ALWAYS_SET | DATA_PRESENT`, **without** `WANTING_REPLY`:
   - `MessageType`: string `Handshake`
   - `MessagingProtocolVersion`: XPC UInt64 `7`
   - `UUID`: XPC UUID using the caller's 16 RFC 4122-order bytes
   - `Properties.RemoteXPCVersionFlags`: XPC UInt64 `0x0100000000000006`
   - `Properties.SensitivePropertiesVisible`: XPC bool `true`
   - `Services`: empty XPC dictionary
4. Receive unsolicited `peer_info` on **either root or reply** stream. No request
   ID equality is assumed. No-payload controls and empty dictionaries are skipped.
   Root peer-info advances the root send sequence to its message ID + 1, matching
   the upstream receive behavior; reply peer-info leaves the root sequence alone
5. Validate the complete bounded XPC wrapper and retain only four service entries
6. Keep the RSD control connection open for the lifetime of service use

There is no system UUID lookup or UUID generation. The caller must use the
appropriate stable peer identity consistently across connections to its tunnel.
No actual identity, pairing material, screenshot, or phone is used by the tests.

## Discovery table and gates

The retained table contains only port, feature mask, feature-advertisement state,
and optional RemoteXPC transport state for:

- `com.apple.coredevice.screencaptureservice`
- `com.apple.coredevice.displayservice`
- `com.apple.coredevice.hid.universalhidservice`
- `com.apple.coredevice.hid.indigo`

Missing services remain absent. No fallback port or DDI availability is invented.
Ports accept XPC UInt64, positive Int64, or 1–5 ASCII decimal digits, restricted
to 1–65535. Python's `int()` also accepts whitespace, signs, and other coercions;
this narrow C profile intentionally rejects them and bool values.

The screenshot feature is `com.apple.coredevice.feature.capturescreenshot`.
The display feature enum covers `getmediasupportinfo`, `getmediastreamserverstatus`,
`startmediastream`, and `stopmediastream` under `com.apple.coredevice.feature.`.
A nonempty advertised feature list must contain the requested feature. Missing,
NULL, or empty lists produce explicit `BRIDGE_RSD_UNKNOWN` plus `BRIDGE_OK`, as
upstream `require_feature` skips capability denial in those cases. UNKNOWN does
not mean supported: the device remains the final authority. Non-array lists or
non-string feature values are rejected as malformed, even when Python might
coerce/ignore them. Call `require_feature` again before a later operation that
uses a different feature on an already open connection.

`UsesRemoteXPC`, if present, must be a bool. An explicit false prevents
`open_service` from speaking RemoteXPC to that service. Missing is UNKNOWN and
is allowed for these four known RemoteXPC wrappers. This explicit-false guard
is deliberately stricter than upstream's direct `start_remote_service`, which
ignores the flag, and consistent with the transport distinction in its generic
`start_service` dispatcher.

Only CoreDevice RemoteXPC service discovery/opening is implemented. Remote
lockdown trusted/untrusted fallback, `RSDCheckin`, escrow-bag handling, and
`all_values` are deliberately omitted. None is required to resolve/open these
four named RemoteXPC service ports; this implementation cannot provide general
lockdown APIs.

## Integration and lifetime

Header: `firmware/components/bridge_core/include/bridge_rsd.h`

- Initialize fresh `bridge_rsd` with `bridge_rsd_init`, a dialer, and the binary
  `server_address` / `server_rsd_port` from a successful CDTunnel negotiation
- The dialer must connect through the already-authorized tunnel, not through an
  arbitrary system route. Its `(IPv6 bytes, port, deadline, out bridge_io)`
  callback returns an independent byte stream. No OS network configuration is
  performed by this module
- For the lwIP adapter, verify the supplied address equals the negotiated peer
  before calling its peer-port-only connect routine. Each RSD/service connection
  needs a distinct retained TCP handle and independent `bridge_io.context`
- Call `bridge_rsd_connect` with caller-owned bounded scratch and UUID
- Call `bridge_rsd_require_feature` if the caller needs the ALLOWED/UNKNOWN/DENIED
  distinction; `bridge_rsd_open_service` repeats the gate before dialing
- Pass a zero-initialized `bridge_rsd_connection` to `open_service`. On success its
  `.session` is a fully initialized service RemoteXPC transport. The modern device
  handshake is sent only to RSD, **never** to an individual service
- Use the existing request builder, RemoteXPC send/response, and streamed PNG
  extractor APIs on that session. Opening a service does not send an operation
- Keep control alive; serialize `bridge_rsd_pump` with other RSD operations under
  the application's scheduler when control work is available. It processes one
  step, including HTTP/2 PING/SETTINGS/WINDOW_UPDATE. This module has no background
  thread and no nonblocking readiness detector. Pumping an idle socket to a timed
  out deadline is terminal under the existing RemoteXPC I/O contract
- Close service connections before closing RSD. The close callback must release
  resources boundedly, without a graceful-close wait. The wrapper cannot own or
  close arbitrary other service objects

A one-way HID send only means bytes were accepted by the transport. To avoid
reset/close discarding queued bytes, the optional dialer `drain` callback must
wait for actual TCP peer acknowledgements of all previously written bytes.
`bridge_rsd_drain_service` returns UNSUPPORTED if absent; it never substitutes
an empty local queue or a delay as success. TCP acknowledgement still does not
prove the iPhone accepted/applied the HID action. A drain failure poisons that
service session; close it. Source/destination and authorization policy remain
the caller's responsibility.

Discovery/dial/protocol/parser errors after connect begins are sticky FAILED,
close the control stream exactly once, and publish no partial service table.
A service-specific dial/handshake failure closes only that service; the RSD
control connection remains available. A new post-discovery payload is explicitly
UNSUPPORTED and terminal: dynamic service table updates/reconnect recovery are
not implemented and cannot silently mutate the current table.

## Bounds and data minimization

No heap allocation occurs. The caller supplies scratch for one complete XPC
wrapper, hard-capped at 65,536 bytes (including its 24-byte header), also subject
to the XPC parser's configured limit. A larger peer-info fails LIMIT on its wrapper
header before allocating or accepting a prefix as valid. Smaller scratch is
legal but correspondingly limits discovery; there is no automatic growth.

The hello uses a separate 512-byte stack buffer so receiving peer-info while a
flow-controlled send is waiting cannot corrupt outbound bytes. Parser depth,
object count, UTF-8, and all nested lengths are checked by `bridge_xpc_parse`.
Unknown service metadata is validated structurally but never retained in the
four-entry table. All peer-info scratch bytes written and RemoteXPC's completed
scratch bytes are wiped before returning. The supplied socket/tunnel may have
its own receive buffers outside this module's ownership. No UDID/product/user
metadata is logged or stored by the RSD module.

All calls and callbacks are single-owner and non-reentrant. Context, scratch,
UUID, and output structures must not overlap. An open context must not be
reinitialized or moved. The callback must honor its timeout/deadline; a bounded
C callback cannot be forcibly preempted by this module.

## Verification

Run `XPC_PYTHON=/path/to/python tools/test_rsd.sh` with `construct==2.10.70` and
`hyperframe==6.1.0`. The fixture script verifies SHA-256 hashes of the pinned
source, executes extracted source method ASTs, and compares wire bytes generated
independently of the C builder. The current script also needs the pinned
`research/pymobiledevice3` checkout for `remote_service_discovery.py`.

ASan/UBSan tests cover:

- Exact transport/device handshake output across 1–31-byte I/O fragmentation
- Root/reply unsolicited peer-info with nonmatching ID, no-payload controls,
  empty dictionaries, and HTTP/2 DATA fragmentation
- Four service-port representations, known/unknown/missing capabilities,
  unavailable services, explicit wrong transport, and correct typed values
- Real connection lifecycle: discovery → service dial → service handshake →
  correlated application request/reply → TCP-drain adapter → service close
- Persistent RSD PING response while services are open
- A >60 KiB valid peer-info and explicit 64 KiB/smaller-scratch limit failures
- Invalid types/ports, interleaved unexpected payloads, timeout, I/O/EOF,
  failed dial/handshake, sticky errors, scratch wiping, and idempotent closes

These are synthetic peer and adapter tests. Physical iPhone discovery, actual
Developer Mode/DDI state, HTTP/2 behavior of a particular iOS release, multi-
connection fairness inside the tunnel, HID effects, and end-to-end screenshots
remain unverified until separately tested on authorized hardware.
