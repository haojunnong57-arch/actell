/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_LWIP_H
#define BRIDGE_LWIP_H
#include "bridge_packet_link.h"

#define BRIDGE_LWIP_TCP_SLOTS 4u
#define BRIDGE_LWIP_TCP_RX_CAPACITY 16384u
#define BRIDGE_LWIP_WRITE_CAPACITY 4096u
#define BRIDGE_LWIP_TX_PACKETS 8u
#define BRIDGE_LWIP_UDP_SLOTS 4u
#define BRIDGE_LWIP_UDP_PACKETS 4u
#define BRIDGE_LWIP_UDP_CAPACITY 2048u

typedef struct bridge_lwip_net bridge_lwip_net;
/* Caller-owned handles must outlive bridge_io copies. A copied stale handle is
 * rejected after slot reuse. Never mutate these fields or copy a live net. */
typedef struct { bridge_lwip_net *net; uint32_t generation; unsigned slot; } bridge_lwip_tcp;
typedef struct { bridge_lwip_net *net; uint32_t generation; unsigned slot; } bridge_lwip_udp;
typedef struct {
    uint32_t tx_packets, rx_packets, tx_backpressure, rx_rejected;
    uint32_t udp_dropped, udp_received;
    size_t allocation_bytes; /* fixed context, excludes separately bounded lwIP pools */
} bridge_lwip_stats;

/* One USB owner task calls EVERY public function, including bridge_io methods.
 * NO_SYS=0; initialize lwIP once before use (IDF: esp_netif_init()). No default
 * netif/route is changed. Only negotiated client <-> peer IPv6 traffic is allowed.
 * link is borrowed until shutdown. On a create timeout *out may be non-NULL:
 * call shutdown/destroy and retain it until cleanup acknowledgment. */
bridge_status bridge_lwip_create(const bridge_packet_link *link,
    bridge_lwip_net **out, uint64_t deadline_ms);
/* One bounded owner iteration: finish queued core work, forward <=8 TX packets,
 * poll USB once, and receive at most one packet only if readable is true. A
 * partial packet uses this same absolute deadline and fails the tunnel closed.
 * Does not wait for peer traffic or use an empty receive as a poll. */
bridge_status bridge_lwip_poll(bridge_lwip_net *, uint64_t deadline_ms);
bridge_status bridge_lwip_tcp_connect(bridge_lwip_net *, uint16_t peer_port,
    uint64_t deadline_ms, bridge_lwip_tcp *out);
bridge_io bridge_lwip_tcp_io(bridge_lwip_tcp *);
/* Observation only; no USB/TLS/core callback. EOF/error is reported only after
 * buffered bytes have drained. */
bridge_status bridge_lwip_tcp_pending(const bridge_lwip_tcp *, size_t *bytes);
/* Wait until the peer ACKs every byte accepted by this channel's write calls.
 * Transport acknowledgment is not application/UI acknowledgment. */
bridge_status bridge_lwip_tcp_drain(bridge_lwip_tcp *, uint64_t deadline_ms);
/* Abort/release this TCP slot; no graceful FIN guarantee. */
bridge_status bridge_lwip_tcp_close(bridge_lwip_tcp *, uint64_t deadline_ms);
/* Bind to negotiated client IPv6; remote_port=0 accepts any port on negotiated
 * peer, otherwise filters that source port too. local_port must be nonzero. */
bridge_status bridge_lwip_udp_open(bridge_lwip_net *, uint16_t local_port,
    uint16_t remote_port, uint64_t deadline_ms, bridge_lwip_udp *out);
/* No IPv6 fragmentation: payload must also fit negotiated MTU minus 48. */
bridge_status bridge_lwip_udp_send(bridge_lwip_udp *, uint16_t peer_port,
    const uint8_t *, size_t, uint64_t deadline_ms);
/* Blocking owner pump to deadline; preserves datagram if capacity is too small.
 * Empty UDP datagrams are supported. Drops oversize/full incoming datagrams. */
bridge_status bridge_lwip_udp_receive(bridge_lwip_udp *, uint8_t *, size_t,
    size_t *received, uint16_t *peer_port, uint64_t deadline_ms);
bridge_status bridge_lwip_udp_close(bridge_lwip_udp *, uint64_t deadline_ms);
void bridge_lwip_get_stats(const bridge_lwip_net *, bridge_lwip_stats *);

/* Immediately stops owner I/O. These functions NEVER call borrowed USB/TLS or
 * clock callbacks, even on retries. shutdown is nonblocking and posts cleanup;
 * retry on LIMIT (tcpip mailbox full). destroy also retries that post, returns
 * TIMEOUT until core acknowledgment, and frees only on OK. After shutdown no
 * other API except these three functions and stats may be called. Retain net
 * until destroy succeeds; borrowed transport can be released immediately. */
bridge_status bridge_lwip_shutdown(bridge_lwip_net *);
bool bridge_lwip_cleanup_complete(const bridge_lwip_net *);
bridge_status bridge_lwip_destroy(bridge_lwip_net *);
#endif
