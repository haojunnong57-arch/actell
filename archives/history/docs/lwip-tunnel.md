# Embedded IPv6 TCP/UDP over CDTunnel

## Scope and dependency

`firmware/components/bridge_lwip/` adapts the real ESP-IDF 5.5.5 bundled
lwIP stack to the negotiated CDTunnel raw IPv6 byte stream. The pinned lwIP
checkout is `fd432e4ee2cfb7f7f1c7eb7227e0173412e7b84e`. TCP connection state,
checksums, receive windows, out-of-order handling, retransmission timers,
FIN/reset processing and UDP validation are performed by that stack, not by
bridge-specific transport implementations.

This implements an embedded point-to-point IPv6 netif. It does not create a
host TAP/TUN, add host routes, alter host network settings, enable Wi-Fi, perform
pairing, generate credentials, or authenticate to an iPhone. Existing caller
credentials and a successfully negotiated CDTunnel are prerequisites. The USB
same-controller active gate remains the application's responsibility; this
component does not enable it. Synthetic tests do not establish real-device
interoperability or the suitability of an ESP32 USB wiring arrangement.

## Initialization and address policy

Call `esp_netif_init()` once before creating a bridge on ESP-IDF. The component
never calls `tcpip_init()` or starts a second lwIP core thread. Host tests call
`tcpip_init()` once and run the same component in `NO_SYS=0` mode.

`bridge_lwip_create(link, &net, deadline)` uses the client address, peer address,
and MTU from the READY CDTunnel. The netif has no Ethernet/ARP/MLD flags and its
output callback copies complete raw IPv6 packets directly into a bounded queue.
There is no Ethernet header and no added per-packet CDTunnel prefix. It never
sets the global default netif. TCP and UDP PCBs are explicitly bound to this
netif and the negotiated client address; connect/send targets are only the
negotiated peer address. Both inbound and outbound raw IPv6 packets are checked
against those exact source/destination addresses. Packets with other addresses
are rejected before entering the embedded IP stack. All IPv6 fragment headers,
including atomic fragments and fragments following extension headers, are
rejected. Extension-chain inspection is bounded to eight headers. Pinned lwIP's
global fragment reassembly cache survives netif removal; avoiding reassembly
prevents old fragments from entering a recreated tunnel with the same addresses.
TCP uses normal transport segmentation and is unaffected by this restriction.
ICMPv6 neighbor/router-discovery types 133..137 are also rejected. They are not
needed on this raw point-to-point link, and otherwise a valid link-local peer
could alter lwIP-global router or neighbor-discovery state through an RA/Redirect
even without Ethernet flags. Normal transport-relevant ICMP errors remain
available to lwIP.

The netif address is marked preferred without DAD; it comes from the completed
point-to-point negotiation. The negotiated MTU is enforced again at the output
queue and by the existing CDTunnel framing implementation.

## Ownership, concurrency and bounded pumping

All public bridge calls, including `bridge_io` read/write/clock callbacks, belong
to one USB owner task. A second thread must not call them concurrently. Every
raw lwIP PCB/netif operation executes on the lwIP core thread through
`tcpip_try_callback()`. Core callbacks only process bounded memory or copy packet
and stream bytes; they never call a USB, TLS, transport-poll, transport-readable,
or borrowed clock callback.

The owner and core exchange one persistent command in the net object. The
command's release/acquire completion flag protects every command field and its
staging buffer. Fixed single-producer/single-consumer rings use release/acquire
indices; no pointer to a caller's read/write buffer is retained. Core-owned PCB
pointers never escape the component. TCP and UDP handles contain slot generation
tags, so an old copied handle is rejected after the slot is reused. Slots retire
when the generation reaches UINT32_MAX rather than wrapping. A handle's
storage must outlive every `bridge_io` referencing it, and no handle may be used
after the net itself is destroyed.

One `bridge_lwip_poll(net, absolute_deadline)` iteration:

1. Drains a snapshot of at most eight raw IPv6 output packets, using real
   `bridge_cdtunnel_send_ipv6()` calls on the owner task
2. Calls the borrowed link's USB poll once
3. Observes `readable`, without I/O, and reads at most one packet only when bytes
   are present
4. Uses real `bridge_cdtunnel_recv_ipv6()` to complete that packet with the same
   overall absolute deadline, then submits it for core-thread IPv6 input

No empty packet receive is used as a polling mechanism and no timeout-based
resynchronization is attempted. Once a partial CDTunnel packet begins, its
completion deadline is terminal on failure. The underlying stream's read
adapter must continue pumping usbmux control ACKs while completing reads. This
is a packet-link requirement, not something lwIP callbacks can do. When a core
command is pending, the owner may continue USB polling and queued transmission,
but cannot overwrite the ingress staging buffer or another command.

## TCP and UDP API

`bridge_lwip_tcp_connect(net, peer_port, deadline, &handle)` opens an actual IPv6
TCP connection to the negotiated peer and requested RSD/service port. On a
connection timeout after a PCB was created, the output handle remains valid for
cleanup. `bridge_lwip_tcp_io(&handle)` provides a bounded byte stream. Reads
consume at most the available caller capacity; writes copy at most 4096 bytes
per callback and may return a short write. Accepted bytes can still be in the
real lwIP send queue, so a successful write alone does not establish delivery.

`bridge_lwip_tcp_pending()` observes receive bytes without transport I/O, allowing
RSD/control servicing without probing an empty stream. `bridge_lwip_tcp_drain()`
waits for real peer acknowledgments of every byte accepted by write calls,
tracked by lwIP's `tcp_sent` callback. This proves TCP delivery only, not iPhone
application handling or a visible UI change. It must be used before closing a
one-way HID report stream if delivery is required. `bridge_lwip_tcp_close()` is
an explicit abort/release; it can emit RST and makes no graceful-FIN guarantee.
A read waiting for data can time out without poisoning the underlying tunnel.
If a posted core command misses its completion-acknowledgment deadline, the net
is stopped: its side effects could otherwise leave a channel without a returned
handle or race a later write. Zero-window/backpressure waits are bounded by the original operation deadline.

UDP receivers bind an explicit nonzero local port on the client address and may
optionally filter a peer source port. They only accept the negotiated peer's
address. Four datagrams of at most 2048 bytes are retained per receiver. Incoming
oversize/full-queue datagrams are dropped with a counter. Receive preserves a
datagram if the caller buffer is too small, and zero-length datagrams are valid. Outbound UDP payloads must also fit within
the negotiated MTU minus 48 bytes (IPv6 + UDP headers); larger sends return LIMIT
rather than emit fragments. At MTU 1280 the maximum outbound UDP payload is 1232.
The API is a bounded future-media transport primitive; it does not decode,
display or play media, or claim a media service has been negotiated.

## Teardown and failures

`bridge_lwip_shutdown(net)` immediately marks the bridge stopped. It and
`bridge_lwip_destroy(net)` never invoke the borrowed link or its clock, including
on retries. The caller may release the USB/TLS service immediately after
shutdown. The net allocation itself must be retained while asynchronous cleanup
is pending.

Shutdown posts a core callback. If a command is already pending or running,
its completion is atomically linearized against the stop request: it either
performs cleanup itself or finishes before shutdown schedules cleanup. A single
successful shutdown therefore cannot lose the stop request. A full core mailbox
returns LIMIT and can be retried. Cleanup aborts all TCP PCBs, removes UDP PCBs
and the netif, then acknowledges completion. `bridge_lwip_cleanup_complete()` is
true only after that callback's final release publication.

`bridge_lwip_destroy()` retries the shutdown post and returns TIMEOUT while the
core still owns the context; only OK frees it. Do not discard the pointer on
TIMEOUT/LIMIT or start a replacement session that forgets pending cleanup. If
create returns failure with a non-NULL output net, the same cleanup contract
applies. Transport read/write/poll failure initiates shutdown automatically.
There is no attempt to reuse a partially consumed CDTunnel service.

## Actual memory bounds

The bridge context is one explicit PSRAM allocation on ESP-IDF
(`MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT`); lack of suitable memory returns LIMIT,
without silently consuming a quarter-megabyte of internal SRAM. Host builds use
`calloc`. Because synchronization fields are in that PSRAM context, ESP32-S3
builds require IDF's `CONFIG_STDATOMIC_S32C1I_SPIRAM_WORKAROUND=y`: native S32C1I
cannot operate on external RAM. The checked IDF 5.5.5 GCC configurations enable
this automatically and add `-mdisable-hardware-atomics`, selecting IDF's
PSRAM-safe library implementations. Alternative toolchains must establish the
same atomic guarantees before using this component.
`bridge_lwip_get_stats().allocation_bytes` reports the exact
`sizeof(context)` for the compiled target; pointer sizes and lwIP netif settings
make this target-dependent. The verified 64-bit Unix test ABI reports 247336 bytes.

Fixed backing storage, regardless of negotiated MTU:

| Storage | Bound |
|---|---:|
| Raw output queue | 8 × 16000 = 128000 bytes, plus lengths |
| One ingress staging packet | 16000 bytes |
| Four TCP receive rings | 4 × 16384 = 65536 bytes |
| One command write staging buffer | 4096 bytes |
| Four UDP receivers, four datagrams each | 16 × 2048 = 32768 bytes, plus lengths/ports |
| PCBs, handles, state and netif | Fixed struct overhead or separately allocated lwIP objects |

lwIP also allocates packet buffers, TCP segment metadata, PCBs and global core
resources. ESP-IDF uses `MEMP_MEM_MALLOC=1`, so most `MEMP_NUM_*` constants must
not be represented as hard allocation limits. This component instead enforces
four live TCP and four live UDP slots and compile-time limits on the actual
lwIP retention mechanisms:

- `TCP_WND <= 16384`, `TCP_SND_BUF <= 32768`, `TCP_SND_QUEUELEN <= 128`
- Out-of-order queue disabled, or `TCP_OOSEQ_MAX_PBUFS` in 1..8 per PCB
- IPv6 reassembly disabled, or `IP_REASS_MAX_PBUFS` in 1..16 globally
- Only one ingress packet is submitted by this bridge at a time

A retained ingress pbuf can occupy the full negotiated 16000-byte allocation
even when TCP later trims its visible length. Conservative payload allocation
bounds therefore use full MTU times retained pbuf count, not just the advertised
TCP window. At the allowed maxima, four × eight out-of-order buffers can occupy
512000 bytes, up to four refused TCP inputs 64000 bytes, and TCP send payload at most 131072 bytes, in addition
to the fixed context, metadata and global stack resources. These are conservative
upper bounds, not measured steady-state usage or total firmware-RAM claims.
This bridge never contributes packets to global IPv6 fragment reassembly because
it rejects fragment headers before lwIP input; other interfaces, if added by an
application, own their separate global-stack resource use. The intended IDF configuration uses smaller default windows and four out-of-order
pbufs. `CONFIG_SPIRAM_TRY_ALLOCATE_WIFI_LWIP=y` makes IDF's lwIP allocator prefer
PSRAM; explicitly retain `CONFIG_LWIP_TCP_OOSEQ_MAX_PBUFS=4`, because the former
option otherwise changes IDF's default out-of-order limit to unbounded zero.

## Validation and remaining limits

Run `tools/test_lwip.sh`. It requires the exact pinned source tree, verifies the
commit and that tracked sources are unmodified, and compiles the real lwIP core
plus its upstream Unix pthread `sys_arch` port. It never creates a host interface
or uses root routing. A synthetic IPv6 peer independently forms and validates
transport pseudo-header checksums, performs real TCP handshakes, and exchanges
packets through the actual CDTunnel parser with short stream reads/writes.

The real packet suite covers SYN/ACK and bidirectional TCP, bad-checksum
rejection, out-of-order/duplicate/FIN handling, reset and operation deadlines,
actual timer-driven SYN/data retransmission, zero-window reopening, transport
ACK drain, pending-byte observation, TCP receive-window/credit/ring wrap, full
TX-ring backpressure, UDP checksum/source-port filtering and bounded receive
queues, stale handles, source-address rejection, partial-packet fail-closed
handling, full callback-mailbox retries, create deadlines and core-blocked
asynchronous teardown. Fragment cases exercise first/atomic fragments, fragments
behind Hop/Routing/Destination/AH extension headers, and matching final fragments
sent after destruction/recreation with the same addresses. A negotiated
`fe80::2`/`fe80::1` session exercises a checksummed valid unicast RA plus all ND6
types 133..137, directly and after an extension header: router lists and global
ND6 timers remain unchanged, while ordinary link-local UDP still works.
Core-thread assertions and owner-thread transport assertions are enabled.

Final results: all 18 groups pass under `tools/test_lwip.sh` (ASan/UBSan) and
`SANITIZE=thread tools/test_lwip.sh` (TSan). Both tested component SHA-256
`759d0b857ee709a604fb345ab9f1f80c7d1ee0a66cbd8a1f42839b3f29f147cd`.

Tests compare lwIP heap use, every enabled memp pool and netif list against their
pretest baselines. This catches retained PCBs, pbufs and fragment entries, rather
than assuming a successful destroy implies their absence. The environment's
exit-time LeakSanitizer scan is blocked by ptrace, so test commands disable that
scan and do not claim an LSan pass. ASan/UBSan remain enabled; TSan is a separate
run.

The host port retains the pinned upstream pthread implementation for threads,
mailboxes and semaphores. Its two critical-section functions are replaced only
in the host link by `tests/test_lwip/host_protect.c`, a recursive pthread mutex:
ThreadSanitizer found the original port reading a shared owner-thread identifier
without synchronization. The unmodified lwIP source checkout is still verified
against its pin; no TCP, UDP, IPv6 or callback implementation is replaced.
`SANITIZE=thread tools/test_lwip.sh` runs the same real packet suite with TSan.

A host test is not an ESP-IDF link test or hardware validation. Final firmware
compile results, exact target allocation footprint, and remaining integration
coverage belong with the aggregate validation report. No iPhone or ESP32 was used
for these tests.
