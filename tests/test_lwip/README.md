# Real lwIP packet harness

This test links the production `bridge_lwip.c`, `bridge_cdtunnel.c`, and
`bridge_io.c` to the **actual lwIP sources** pinned by ESP-IDF v5.5.5:

- Repository: https://github.com/espressif/esp-lwip
- Commit: `fd432e4ee2cfb7f7f1c7eb7227e0173412e7b84e`
- `NO_SYS=0`, real `tcpip_thread`, real TCP/UDP/IPv6/pbuf/timers
- pthread host OS port with core-thread/locking assertions enabled

There are no fake `tcp_*` or `udp_*` implementations. The synthetic peer
constructs and checks wire packets independently with its own IPv6
pseudo-header checksum implementation. Both directions use the production
CDTunnel byte-stream framing and seven-byte short reads/writes. No TAP/TUN,
root privileges, native sockets, host routes, or host network changes are used.

## Run

From the repository root:

```sh
LWIP_SOURCE_DIR=/path/to/esp-idf/components/lwip/lwip tools/test_lwip.sh
LWIP_SOURCE_DIR=/path/to/esp-idf/components/lwip/lwip SANITIZE=thread tools/test_lwip.sh
```

The source can alternatively be resolved from `$IDF_PATH`. This workspace's
fallback is `/workspace/shared/esp-idf-v5.5.5/components/lwip/lwip`. The script
checks the exact Git commit and rejects modified tracked upstream sources;
missing sources are a failure, never a silent skip. It performs no downloads.
Use GCC or a compatible compiler via `CC`. `SANITIZE=0` runs without sanitizers.
Binaries are separated under `.build/lwip/{address,thread,plain}`.

The suite takes real time to observe SYN and data retransmissions. Timers are
not replaced or artificially fast-forwarded. Default builds use AddressSanitizer
and UndefinedBehaviorSanitizer; `SANITIZE=thread` uses ThreadSanitizer instead.

## Verified behaviors

- Actual TCP SYN/SYN-ACK/ACK sequence and independently verified output checksums
- TCP payload in both directions, short application reads, corrupted TCP checksum rejection
- Out-of-order receive reassembly and duplicate suppression
- FIN EOF, buffered bytes before EOF, and writes after the peer half-closes
- Peer RST, connect deadline, read deadline, and a channel remaining usable after an empty read timeout
- Real timer-driven dropped-SYN and unacknowledged-data retransmissions
- Peer zero window, drain timeout while unacknowledged, window reopening, and real `tcp_sent` ACK-driven drain completion
- Local zero receive window, consumption credit, reopening, and receive-ring wraparound
- Real UDP checksums, connected source-port filtering, empty datagrams, and preservation when the caller's buffer is too small
- UDP queue-full drop policy and exact 2048-byte capacity versus oversized input/output at MTU 16000
- Outbound UDP limited to `min(2048, negotiated MTU - 48)`, including 1233-byte rejection at MTU 1280
- Negotiated MTUs of 1280 and 16000, and negotiated IPv6 source/destination filtering
- Four TCP and four UDP slots, reuse, and stale generation-handle rejection
- An actual core UDP burst filling the bounded output ring, returning `ERR_MEM`, then draining only through the owner task
- Failure of transport polling and a truncated CDTunnel packet failing closed
- Observation APIs avoiding borrowed transport/clock callbacks
- Nonblocking shutdown with a deliberately blocked real TCP/IP thread
- Timed-out create retaining its context until deferred cleanup acknowledgment
- Full real TCP/IP callback mailbox, failed cleanup post, and safe cleanup retry
- Posted-write acknowledgment timeout canceling deferred work before cleanup
- Rejection of first/final/atomic fragments, including fragments after Hop-by-Hop, Routing, Destination, and AH headers
- No IPv6 reassembly cache growth or cross-session delivery after destroy/recreate with the same addresses and fragment ID
- Actual negotiated `fe80::2`/`fe80::1` link-local pair, valid checksummed unicast Router Advertisements, all ND6 types 133–137, and ND6 behind Hop-by-Hop headers rejected before global router/timer mutation
- ND6 `default_router_list`, `reachable_time`, and `retrans_timer` unchanged, with ordinary link-local UDP still operational after the rejection
- No borrowed USB/TLS/read/write/poll/clock callbacks after shutdown
- All lwIP heap and memory-pool usage, netif count, and default netif restored to the pretest baseline

The test prints the fixed bridge context allocation. The current 64-bit host ABI
reports **247336 bytes**, excluding lwIP's separately bounded pools. Firmware ABI
size and physical PSRAM availability must be checked in the ESP32 build/device.

## Host-only OS adaptation

The pinned Unix `sys_arch.c` uses a shared `lwprot_thread` variable to detect
recursive critical sections before acquiring its mutex. ThreadSanitizer finds
that upstream host-port race. `host_protect.c` replaces only
`sys_arch_protect`/`sys_arch_unprotect` with a properly recursive pthread mutex;
the build renames the original two symbols. The pinned sources are not edited.
This is an OS-port adaptation, not a TCP/UDP mock or a sanitizer suppression.

The host configuration disables ESP-only hardware/system integrations and sets
`IPV6_FRAG_COPYHEADER=1` because host pointers are 64-bit. The ESP-IDF firmware
build separately checks its real target configuration. Core TCP/UDP/IPv6 sources
are the same pinned implementation in both.

LeakSanitizer's process-exit scan is disabled by default because this execution
environment rejects its thread inspection (`LeakSanitizer does not work under
ptrace`). An explicit `ASAN_OPTIONS=detect_leaks=1` attempt reached the end of all
packet tests and then failed in LeakSanitizer itself. The suite still checks all
actual lwIP heap/pool/netif baselines, while ASan/UBSan test memory accesses and
TSan checks concurrency. Do not describe this as a successful LeakSanitizer run.

## Scope limits

All peer inputs are synthetic public test data. The production profile explicitly
rejects IPv6 fragments rather than permitting retained global reassembly state. This verifies the component's
actual stack behavior in a host pthread port; it does not prove interoperability
with a physical iPhone, USB hardware, ESP32 memory timing, or an entire RSD /
RemoteXPC / screen-sharing / HID session. Accepted IPv6 extension semantics are not exhaustively tested here.
