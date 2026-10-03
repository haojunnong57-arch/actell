# Bounded RemoteXPC session

`bridge_remotexpc.c` is an operational synchronous HTTP/2 transport state machine
for the two RemoteXPC messaging channels. It operates over a caller-supplied
`bridge_io`; it does not open a socket, establish a tunnel, authenticate a device,
perform pairing, discover services, or claim successful iPhone interoperability.
Tests use a synthetic HTTP/2 peer and the pinned pymobiledevice3 wire schema.

## Supported wire subset

Source: pymobiledevice3 commit
`cd895d17ce8a97d883c10f87b26c7356d5e0ccb1`, `remote/remotexpc.py` and
`remote/xpc_message.py`.

The opening sequence preserves upstream ordering and XPC bytes:

1. HTTP/2 connection preface and SETTINGS
2. Empty HEADERS on root stream 1
3. Empty-dictionary XPC on stream 1, message ID 0
4. Empty HEADERS on reply stream 3
5. No-payload root terminator, flags `0x0201`
6. No-payload reply-channel initialization, flags `0x400001`
7. Read peer SETTINGS (processing preceding window updates), then ACK

One intentional resource-policy difference: receive stream windows are 16 KiB,
not upstream's 16 MiB. The connection retains its HTTP/2 default 65,535-byte
window, so no initial connection WINDOW_UPDATE is sent. Both connection and
stream windows are replenished after at least 8 KiB has been consumed by the
parser and accepted by its callback. Credits are never returned for rejected
chunks. The transport adapter remains responsible for bounded TCP/socket queues
and actual receive backpressure; these advertised credits are in-flight network
limits, not resident allocations in this module.

Root/reply DATA is reassembled independently. A wrapper can cross any number of
DATA frames; a DATA frame can contain multiple wrappers. Network reads/writes
may split at every byte, including the HTTP/2 and XPC headers. Control frames and
other-stream wrappers can interleave without overwriting a single shared XPC
accumulator. SETTINGS changes retroactively adjust open send windows; outbound
DATA respects both connection and stream windows, including zero/negative
windows and 16 KiB frame-size limits.

SETTINGS ACK, PING/ACK, WINDOW_UPDATE, GOAWAY, RST_STREAM and stream END_STREAM are
handled. GOAWAY/RST_STREAM are terminal; `peer_error` preserves the received HTTP/2
error code. Oversized or malformed frames, zero/overflowing window increments,
invalid SETTINGS and partial-wrapper stream endings fail closed. Unknown HTTP/2
extension types are drained in bounded chunks, as required by HTTP/2. Unknown
messaging stream IDs and file-transfer streams are rejected explicitly.

Only empty header blocks are supported; an empty HEADERS/CONTINUATION sequence
is supported and enforces exclusive continuation ordering. Nonempty HPACK,
padding, priorities and server push fail with `BRIDGE_E_UNSUPPORTED`. This is not
a general-purpose HTTP/2 implementation. A peer MAX_CONCURRENT_STREAMS below 2
is conservatively rejected even on updates, rather than retaining existing
streams as a full HTTP/2 client could. XPC object payload validity remains the
responsibility of `bridge_xpc_parse`, `bridge_xpc_extract_png`, or a suitable
caller parser; the session validates wrapper framing, size and supported flags.

## Caller integration

- Initialize caller-owned session storage with a connected `bridge_io`, maximum
  inbound wrapper size, and a consumer for unsolicited/interleaved messages
- Run `bridge_remotexpc_handshake` with an absolute monotonic deadline
- Encode/send requests using `bridge_remotexpc_send`, or prepare a wrapper with
  the public `session.next_message_id` and call `bridge_remotexpc_send_encoded`
- Outbound request IDs begin at 1 and increase after each successfully sent
  wrapper; they never wrap. A caller-prepared mismatched ID is rejected before
  any bytes are written
- Consumers receive BEGIN, CHUNK and END with stream, flags, message ID and total
  wrapper length. CHUNK includes the original 24-byte wrapper. Per-stream events
  are ordered; events from streams 1 and 3 may interleave. Every callback buffer
  is borrowed only until the callback returns
- With no consumer, no-payload control wrappers may be ignored; payload-bearing
  messages fail explicitly rather than silently discarding responses

A pull consumer such as the streaming PNG extractor can use
`bridge_remotexpc_response_open`. Choose the expected stream and exact message
ID (`match_id=true`). It exposes a bounded `response.io` that stops at the chosen
wrapper's end, while routing other messages through the previous consumer.
`match_id=false` is available for an unsolicited RSD peer-info wrapper when its ID
is not known in advance; it skips no-payload control wrappers and is not
request-ID correlation. The source does not
prove every future service uses the same reply-channel/ID convention, so callers
must select the convention for the service they implement.

Always call `bridge_remotexpc_response_finish` with the parser's return value and
use finish's returned status. It detects early abandonment/unconsumed bytes and
preserves a lower-level terminal error even if `bridge_read_exact` translated a
negative adapter return into `BRIDGE_E_IO`. The PNG sink is provisional until the
extractor and finish both succeed; discard partial output on failure. No PNG CRC
validation or pixel decompression is added to the existing extractor.

A response adapter must be attached before pumping any fragment of the desired
wrapper. The APIs have one owner, are not thread safe, and do not support
reentrant calls from callbacks. Do not drive a second receive/send operation
while a pull response is being consumed. Public send/pump calls are rejected
while an adapter is attached; only its read callback advances the session.
Attach the adapter after the synchronous send completes. Sending may pump incoming traffic while
waiting for credit, so a consumer must already be installed for replies that can
arrive during that wait. There is deliberately no unbounded response queue.
Caller output scratch must not alias session/response storage.

To send the modern RSD device handshake, a subsequent layer can build the pinned
`MessageType=Handshake`, protocol version, UUID, Properties and Services
objects and send them as a normal request. UUID selection belongs to the caller;
this layer generates no identity and creates no persistent account access.

## Resource and failure contract

No heap allocation is used by the session or response adapter. On the tested
64-bit host their sizes are 1,296 and 1,144 bytes, respectively; exact target ABI
sizes can differ. Session chunk scratch and pull-adapter queue are each 1,024
bytes. The caller's encoding scratch, socket queues, XPC parser, sink and
screenshot scratch are additional. Inbound maximum wrapper size is supplied by
the caller and may exceed the resident encoder's 64 KiB limit. Outbound messages
remain bounded resident XPC wrappers.

Every I/O call receives the remaining absolute deadline. Callback deadlines are
checked after return, but cannot preempt a blocking callback. Callback consumers
must be bounded/nonblocking. All transport, protocol and callback failures poison
the session. Close the underlying transport; never try to resynchronize the
poisoned session. `bridge_remotexpc_abort` lets a subsequent semantic parser mark
a session terminal without closing a transport owned by its caller.
Argument/encoding errors detected before sending leave the
session usable.

## Verification

Run `XPC_PYTHON=/path/to/python tools/test_remotexpc.sh` with `construct==2.10.70`
and `hyperframe==6.1.0` installed. The test executes the pinned upstream
`_do_handshake` AST against a synthetic writer using hyperframe serialization,
normalizes only the documented receive-window policy, and compares all emitted
opening bytes. No device, credentials or network access is used by the test.

The C state machine runs under ASan/UBSan with strict compiler warnings. Tests
cover 1–37-byte transport fragmentation, independent/coalesced wrapper streams,
SETTINGS/PING/continuations, zero-window outbound recovery while receiving an
interleaved reply, ID mismatch and exact selection, EOF/error/timeout/limits,
callback rejection and poisoned-state behavior. A valid synthetic PNG with
CRC-correct chunks and zlib RGB data traverses an interleaved HTTP/2 fixture:
9,480,493 image bytes with a full-stream independently generated rolling-hash
check, a 127-byte screenshot scratch, over 2,000 receive-window
updates and repeated PING acknowledgements. It proves bounded source-matched
synthetic transport/parser behavior, not USB/NCM operation, pairing, on-device
RSD acceptance, service availability, actual screenshots, or touch injection.
