# CDTunnel service byte-stream transport

This module implements the actual CDTunnel handshake and subsequent raw IPv6
packet boundaries over an already-open CoreDeviceProxy service. It has no heap,
OS socket, TUN device, network-stack, or pairing dependency. Passing its host tests
does **not** demonstrate a working iPhone tunnel or a trusted RSD connection.

## Protocol evidence

The implementation follows pymobiledevice3 commit
`cd895d17ce8a97d883c10f87b26c7356d5e0ccb1`:

- [`remote/tunnel_service.py:172–186`](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/remote/tunnel_service.py#L172-L186):
  eight-byte `CDTunnel` magic, big-endian unsigned 16-bit body length, JSON body
- [`remote/tunnel_service.py:443–518`](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/remote/tunnel_service.py#L443-L518):
  TCP/service variant requests MTU 16000; sends raw packets; receives a 40-byte
  IPv6 header followed by its big-endian 16-bit payload length
- [`remote/tunnel_service.py:1364–1407`](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/pymobiledevice3/remote/tunnel_service.py#L1364-L1407):
  service name `com.apple.internal.devicecompute.CoreDeviceProxy`, client network
  parameters, server IPv6 address, and server RSD port
- [`misc/RemoteXPC.md`](https://github.com/doronz88/pymobiledevice3/blob/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1/misc/RemoteXPC.md):
  public response schema including optional client `netmask`

The older documentation example uses MTU 1280 and discusses QUIC. That example
provides a response-schema fixture only; it does not change the pinned TCP
implementation's 16000-byte request. A returned MTU may be smaller than requested.

Source-file SHA-256 for `tunnel_service.py`:
`ae788ece14718a59af73300578159d6642f15b24f75851d90c5c456d33000263`.

## Integration and ownership

1. Open the actual CoreDeviceProxy service through the authorized lockdown
   session. Honor service TLS when required. Supply its application byte stream
   as a `bridge_io`; USB or usbmux packet framing must already be removed.
2. Call `bridge_cdtunnel_init(&tunnel, &service_io, 16000)`. The interface is copied,
   but the caller retains ownership of the underlying service and callback
   context. Keep them alive until the final operation returns.
3. Call `bridge_cdtunnel_handshake(&tunnel, scratch, capacity, deadline_ms)` with
   one absolute monotonic deadline. A 1024-byte scratch area covers the complete
   implemented JSON bound; larger caller workspaces are also accepted.
4. Only after `BRIDGE_OK`/`BRIDGE_CDTUNNEL_READY`, consume
   `tunnel.parameters.client_address`, `.server_address`, `.mtu`, and
   `.server_rsd_port`. Binary addresses are 16 bytes in network order; textual
   spellings are also available. Optional `.netmask` and `.prefix_length` are
   valid only when `.has_netmask` is true.
5. Connect a real IPv6/TCP stack to `bridge_cdtunnel_send_ipv6` and
   `bridge_cdtunnel_recv_ipv6`. Receive storage must hold the negotiated MTU.
   Forward a received packet only after success and a nonzero returned size.
6. On a terminal failure, close the underlying service and discard partial
   bytes. Reinitialization requires a freshly opened service stream.

Calls are serialized on one task. Callbacks must honor their remaining timeout,
never retain temporary buffers, and never reenter the context. A synchronous
callback cannot be forcibly preempted; deadline overrun is detected on return.
The same deadline covers request write, response framing, JSON body and parsing,
or an entire raw packet. Short transfers do not reset it.

## Bounded, fail-closed profile

- MTU request: 1280–16000 inclusive; 16000 is the default upstream-derived choice
- Negotiated MTU: at least IPv6's 1280 minimum and no larger than the request
- Handshake JSON body: 1–1024 bytes, also limited by the supplied scratch capacity
- Root object: exactly `clientParameters`, `serverAddress`, `serverRSDPort`, `type`
- Client object: required `address` and `mtu`, optional `netmask`
- `type`: exactly `serverHandshakeResponse`; RSD port: integer 1–65535
- Strict integer syntax, complete JSON consumption, no arbitrary nesting or
  unknown values, no dynamic token array, and no heap allocation
- Duplicate keys, including escaped spellings, are rejected; unknown keys return
  `BRIDGE_E_UNSUPPORTED` rather than silently accepting an unreviewed schema
- IPv6 literals support compressed/full forms and final dotted-quad tails;
  brackets, zone IDs, DNS names, unspecified/multicast/loopback/IPv4-mapped
  endpoints, and equal client/server addresses are rejected
- Optional netmask must be a contiguous IPv6 mask; absence does not invent a
  prefix length, and a prefix is not silently inferred from endpoint addresses

A successful response commits all parameters atomically. Any failure once a wire
operation is attempted sets sticky `BRIDGE_CDTUNNEL_FAILED`, clears negotiated
parameters, and suppresses further I/O. There is no byte-scanning recovery.
Pure local argument, state, undersized receive-buffer, or invalid transmit-packet
errors before I/O leave a ready connection usable.

The raw packet layer validates IPv6 version, header/payload byte count and MTU.
It adds **no** length prefix or CDTunnel header to IP packets. A receive call
consumes exactly one complete packet even if later packets are already buffered
below it. The returned size remains zero until success. The caller buffer can
contain partial bytes after failure and is invalid then; there are no packet
consumer callbacks that can observe a provisional packet.

Zero-payload packets are supported only with No Next Header (59). Jumbograms are
unsupported. Extension-header-chain consistency, TCP/UDP/ICMPv6 checksums, source
and destination policy, routing, retransmission, and RSD/HTTP2/RemoteXPC belong to
the later real IP stack and application layers. A ready CDTunnel is not evidence
that any of those layers is ready or that screenshot/input operations succeeded.

## Validation

Run `tools/test_cdtunnel.sh` with a C11 GCC-compatible compiler and Python 3.
The script uses only standard-library Python and the two project C sources,
plus AddressSanitizer and UndefinedBehaviorSanitizer. It needs no device, keys,
certificates, personal identifiers, Python package install, or network access.

Coverage includes:

- 105 valid/invalid schema fixtures from synthetic addresses and one public
  documentation response; Python `ipaddress` checks expected binary addresses
- Exact request bytes against the pinned `json.dumps` request expression and
  `CDTunnel` + BE16 framing at requested MTU 1280 and 16000
- If the research checkout is present, its source hash and AST request/framing
  expressions are also verified; an exported archive remains runnable offline
  using the documented source expression without that checkout
- 1-, 2-, and 3-byte reads/writes; every frame truncation and every truncated JSON
  body; zero/oversized framing and the exact 1024-byte JSON boundary
- Duplicate/escaped keys, missing/unknown fields, integer overflow, wrong types,
  endpoint and mask validation, small/large MTU, and RSD-port limits
- EOF, callback errors/over-reporting, no-progress, and absolute deadlines across
  handshake phases, packet phases, and final validation
- Raw IPv6 40-, 41-, 1280-, and 16000-byte packets; invalid version/length/MTU,
  every 80-byte packet truncation, coalesced handshake/IP and consecutive packets
- More than 7,000 single-bit and seeded multiple-mutation cases under sanitizers,
  including sticky terminal state and no further I/O after failures

These are offline wire/parser/stream tests, not physical-iPhone validation.
