/* SPDX-License-Identifier: GPL-3.0-or-later
 * Raw IPv6 bridge to the ESP-IDF bundled lwIP stack. No TCP/UDP reimplementation.
 */
#include "bridge_lwip.h"
#include "lwip/opt.h"
#include "lwip/ip6.h"
#include "lwip/ip6_addr.h"
#include "lwip/netif.h"
#include "lwip/pbuf.h"
#include "lwip/sys.h"
#include "lwip/tcp.h"
#include "lwip/tcpip.h"
#include "lwip/udp.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#ifdef ESP_PLATFORM
#include "esp_heap_caps.h"
#endif
#if NO_SYS || !LWIP_IPV6 || !LWIP_TCP || !LWIP_UDP
#error bridge_lwip requires NO_SYS=0, IPv6, TCP, and UDP
#endif
#if TCP_WND > BRIDGE_LWIP_TCP_RX_CAPACITY || TCP_SND_BUF > 32768 || TCP_SND_QUEUELEN > 128
#error bridge_lwip bounded profile requires TCP_WND <= 16384, TCP_SND_BUF <= 32768, TCP_SND_QUEUELEN <= 128
#endif
#if TCP_QUEUE_OOSEQ && (TCP_OOSEQ_MAX_PBUFS == 0 || TCP_OOSEQ_MAX_PBUFS > 8)
#error bridge_lwip bounded profile requires TCP_OOSEQ_MAX_PBUFS in 1..8, or TCP_QUEUE_OOSEQ=0
#endif
#if LWIP_IPV6_REASS && (IP_REASS_MAX_PBUFS == 0 || IP_REASS_MAX_PBUFS > 16)
#error bridge_lwip bounded profile requires IP_REASS_MAX_PBUFS in 1..16, or LWIP_IPV6_REASS=0
#endif

/* Only one owner task invokes public APIs. Core-owned PCBs never escape this
 * translation unit. Every cross-thread mutable field is atomic, or published
 * by a release/acquire handoff before the receiving thread touches it. */
enum channel_state { CH_FREE, CH_CONNECTING, CH_OPEN, CH_EOF, CH_ERROR };
enum control_bits { CORE_BUSY = 1u, CORE_STOP = 2u, CORE_CLEAN = 4u };
enum command_type { CMD_INIT, CMD_TICK, CMD_INPUT, CMD_TCP_OPEN, CMD_TCP_WRITE,
    CMD_TCP_CLOSE, CMD_UDP_OPEN, CMD_UDP_SEND, CMD_UDP_CLOSE, CMD_STOP };
typedef struct { uint16_t size; uint8_t bytes[BRIDGE_CDTUNNEL_MAX_MTU]; } ip_packet;
typedef struct { uint16_t size, port; uint8_t bytes[BRIDGE_LWIP_UDP_CAPACITY]; } datagram;
typedef struct {
    struct bridge_lwip_net *net;
    struct tcp_pcb *pcb; /* core only */
    _Atomic unsigned state;
    _Atomic uint32_t generation;
    _Atomic uint32_t rx_head, rx_tail, credit, outstanding;
    uint8_t rx[BRIDGE_LWIP_TCP_RX_CAPACITY];
} tcp_slot;
typedef struct {
    struct bridge_lwip_net *net;
    struct udp_pcb *pcb; /* core only */
    _Atomic unsigned state;
    _Atomic uint32_t generation;
    _Atomic uint32_t head, tail;
    datagram packets[BRIDGE_LWIP_UDP_PACKETS];
} udp_slot;
struct bridge_lwip_net {
    bridge_packet_link link; /* owner only, invalidated by stopping */
    bridge_cdtunnel_parameters parameters; /* immutable after create */
    struct netif interface; /* core only */
    ip_addr_t client, peer; /* core only */
    bool added; /* core only */
    _Atomic unsigned control;
    bridge_status failure; /* owner only */
    enum command_type command; /* owner -> core, busy release/acquire */
    unsigned slot, generation;
    uint16_t local_port, peer_port;
    size_t size;
    uint8_t command_data[BRIDGE_LWIP_WRITE_CAPACITY];
    bridge_status result; /* core -> owner, busy=false release/acquire */
    size_t accepted;
    uint8_t rx_packet[BRIDGE_CDTUNNEL_MAX_MTU];
    tcp_slot tcp[BRIDGE_LWIP_TCP_SLOTS];
    udp_slot udp[BRIDGE_LWIP_UDP_SLOTS];
    _Atomic uint32_t tx_head, tx_tail;
    ip_packet tx[BRIDGE_LWIP_TX_PACKETS];
    _Atomic uint32_t stat_tx, stat_rx, stat_backpressure, stat_rejected;
    _Atomic uint32_t stat_udp_dropped, stat_udp_received;
};
static void core_command(void *context);
static bridge_status pump(bridge_lwip_net *, uint64_t, bool);
static bridge_status lwip_status(err_t e) {
    if (e == ERR_OK) return BRIDGE_OK;
    if (e == ERR_MEM || e == ERR_BUF) return BRIDGE_E_LIMIT;
    if (e == ERR_TIMEOUT) return BRIDGE_E_TIMEOUT;
    if (e == ERR_ARG || e == ERR_VAL) return BRIDGE_E_ARGUMENT;
    return BRIDGE_E_IO;
}
static uint64_t now(bridge_lwip_net *n) {
    return n->link.tunnel->io.clock_ms(n->link.tunnel->io.context);
}
static bool stopped(const bridge_lwip_net *n) {
    return (atomic_load_explicit(&n->control, memory_order_acquire) & CORE_STOP) != 0;
}
static bool busy(const bridge_lwip_net *n) {
    return (atomic_load_explicit(&n->control, memory_order_acquire) & CORE_BUSY) != 0;
}
static bridge_status available(bridge_lwip_net *n, uint64_t deadline) {
    if (!n) return BRIDGE_E_ARGUMENT;
    if (stopped(n)) return n->failure == BRIDGE_OK ? BRIDGE_E_IO : n->failure;
    return now(n) >= deadline ? BRIDGE_E_TIMEOUT : BRIDGE_OK;
}
static bridge_status fail(bridge_lwip_net *n, bridge_status s) {
    n->failure = s;
    (void)bridge_lwip_shutdown(n);
    return s;
}
/* Reassembly in pinned lwIP is global and is not purged by netif_remove.
 * This point-to-point profile deliberately rejects every fragment (including
 * atomic fragments) so no stale payload can cross a destroyed tunnel session.
 * Walk only extension headers that can precede a fragment; the actual transport
 * and extension semantics are still validated by lwIP. Bound work to 8 headers. */
static bool ingress_profile(const uint8_t *packet, size_t size) {
    uint8_t next = packet[6];
    size_t offset = 40;
    for (unsigned depth = 0; depth <= 8; ++depth) {
        if (next == 44) return false;
        /* This raw point-to-point netif needs no neighbor/router discovery.
         * ND6 can mutate lwIP-global router/timer state even with netif flags=0
         * when the negotiated peer happens to be link-local. */
        if (next == 58 && (offset >= size ||
            (packet[offset] >= 133 && packet[offset] <= 137))) return false;
        if (next != 0 && next != 43 && next != 60 && next != 51) return true;
        if (depth == 8 || offset > size || size - offset < 2) return false;
        size_t length = next == 51 ? ((size_t)packet[offset + 1] + 2u) * 4u :
            ((size_t)packet[offset + 1] + 1u) * 8u;
        if (length > size - offset) return false;
        next = packet[offset]; offset += length;
    }
    return false;
}
static err_t raw_output(struct netif *interface, struct pbuf *p, const ip6_addr_t *destination) {
    (void)destination;
    bridge_lwip_net *n = interface->state;
    if (stopped(n)) return ERR_IF;
    uint8_t header[40];
    if (p->tot_len < sizeof header || p->tot_len > n->parameters.mtu ||
        pbuf_copy_partial(p, header, sizeof header, 0) != sizeof header ||
        (header[0] >> 4) != 6 ||
        memcmp(header + 8, n->parameters.client_address, 16) ||
        memcmp(header + 24, n->parameters.server_address, 16)) return ERR_RTE;
    uint32_t h = atomic_load_explicit(&n->tx_head, memory_order_relaxed);
    uint32_t t = atomic_load_explicit(&n->tx_tail, memory_order_acquire);
    if (h - t >= BRIDGE_LWIP_TX_PACKETS) {
        atomic_fetch_add_explicit(&n->stat_backpressure, 1, memory_order_relaxed);
        return ERR_MEM;
    }
    ip_packet *packet = &n->tx[h % BRIDGE_LWIP_TX_PACKETS];
    packet->size = p->tot_len;
    if (pbuf_copy_partial(p, packet->bytes, p->tot_len, 0) != p->tot_len) return ERR_BUF;
    atomic_store_explicit(&n->tx_head, h + 1u, memory_order_release);
    return ERR_OK;
}
static err_t netif_initialize(struct netif *interface) {
    bridge_lwip_net *n = interface->state;
    interface->name[0] = 'c'; interface->name[1] = 'd';
    interface->output_ip6 = raw_output;
    interface->mtu = n->parameters.mtu;
#if LWIP_IPV6 && LWIP_ND6_ALLOW_RA_UPDATES
    interface->mtu6 = n->parameters.mtu;
#endif
    interface->flags = 0; /* deliberately no Ethernet/ARP/MLD */
#if LWIP_IPV6_AUTOCONFIG
    interface->ip6_autoconfig_enabled = 0;
#endif
#if LWIP_IPV6_SEND_ROUTER_SOLICIT
    interface->rs_count = 0;
#endif
    return ERR_OK;
}
static void tcp_error(void *context, err_t error) {
    (void)error;
    tcp_slot *s = context;
    s->pcb = NULL;
    atomic_store_explicit(&s->state, CH_ERROR, memory_order_release);
}
static err_t tcp_connected(void *context, struct tcp_pcb *pcb, err_t error) {
    (void)pcb;
    tcp_slot *s = context;
    atomic_store_explicit(&s->state, error == ERR_OK ? CH_OPEN : CH_ERROR, memory_order_release);
    return ERR_OK;
}
static err_t tcp_acked(void *context, struct tcp_pcb *pcb, u16_t bytes) {
    (void)pcb;
    tcp_slot *s = context;
    atomic_fetch_sub_explicit(&s->outstanding, bytes, memory_order_release);
    return ERR_OK;
}
static err_t tcp_receive(void *context, struct tcp_pcb *pcb, struct pbuf *p, err_t error) {
    (void)pcb;
    tcp_slot *s = context;
    if (!p) {
        atomic_store_explicit(&s->state, CH_EOF, memory_order_release);
        return ERR_OK;
    }
    if (error != ERR_OK) return error; /* non-OK retains pbuf ownership in lwIP */
    uint32_t h = atomic_load_explicit(&s->rx_head, memory_order_relaxed);
    uint32_t t = atomic_load_explicit(&s->rx_tail, memory_order_acquire);
    if ((uint32_t)p->tot_len > BRIDGE_LWIP_TCP_RX_CAPACITY - (h - t)) return ERR_MEM;
    size_t offset = h % BRIDGE_LWIP_TCP_RX_CAPACITY;
    size_t first = BRIDGE_LWIP_TCP_RX_CAPACITY - offset;
    if (first > p->tot_len) first = p->tot_len;
    (void)pbuf_copy_partial(p, s->rx + offset, (u16_t)first, 0);
    if (first < p->tot_len)
        (void)pbuf_copy_partial(p, s->rx, (u16_t)(p->tot_len - first), (u16_t)first);
    atomic_store_explicit(&s->rx_head, h + p->tot_len, memory_order_release);
    pbuf_free(p);
    /* Advertise credit only after the owner actually consumes these bytes. */
    return ERR_OK;
}
static void udp_receive(void *context, struct udp_pcb *pcb, struct pbuf *p,
    const ip_addr_t *address, u16_t port) {
    (void)pcb;
    udp_slot *s = context;
    bridge_lwip_net *n = s->net;
    uint32_t h = atomic_load_explicit(&s->head, memory_order_relaxed);
    uint32_t t = atomic_load_explicit(&s->tail, memory_order_acquire);
    if (!ip_addr_cmp(address, &n->peer) || p->tot_len > BRIDGE_LWIP_UDP_CAPACITY ||
        h - t >= BRIDGE_LWIP_UDP_PACKETS || stopped(n)) {
        atomic_fetch_add_explicit(&n->stat_udp_dropped, 1, memory_order_relaxed);
        pbuf_free(p); return;
    }
    datagram *d = &s->packets[h % BRIDGE_LWIP_UDP_PACKETS];
    d->size = p->tot_len; d->port = port;
    (void)pbuf_copy_partial(p, d->bytes, p->tot_len, 0);
    pbuf_free(p);
    atomic_store_explicit(&s->head, h + 1u, memory_order_release);
    atomic_fetch_add_explicit(&n->stat_udp_received, 1, memory_order_relaxed);
}
static void tcp_release(tcp_slot *s) {
    if (s->pcb) {
        tcp_arg(s->pcb, NULL); tcp_recv(s->pcb, NULL); tcp_err(s->pcb, NULL); tcp_sent(s->pcb, NULL);
        tcp_abort(s->pcb); s->pcb = NULL;
    }
    atomic_store_explicit(&s->state, CH_FREE, memory_order_release);
}
static void udp_release(udp_slot *s) {
    if (s->pcb) { udp_remove(s->pcb); s->pcb = NULL; }
    atomic_store_explicit(&s->state, CH_FREE, memory_order_release);
}
static void core_cleanup(bridge_lwip_net *n) {
    for (unsigned i = 0; i < BRIDGE_LWIP_TCP_SLOTS; ++i) tcp_release(&n->tcp[i]);
    for (unsigned i = 0; i < BRIDGE_LWIP_UDP_SLOTS; ++i) udp_release(&n->udp[i]);
    if (n->added) { netif_set_down(&n->interface); netif_remove(&n->interface); n->added = false; }
}
static void apply_credits(bridge_lwip_net *n) {
    for (unsigned i = 0; i < BRIDGE_LWIP_TCP_SLOTS; ++i) {
        tcp_slot *s = &n->tcp[i];
        uint32_t credit = atomic_exchange_explicit(&s->credit, 0, memory_order_acq_rel);
        if (s->pcb) {
            while (credit) {
                u16_t amount = credit > UINT16_MAX ? UINT16_MAX : (u16_t)credit;
                tcp_recved(s->pcb, amount); credit -= amount;
            }
            (void)tcp_output(s->pcb);
        }
    }
}
static void core_command(void *context) {
    bridge_lwip_net *n = context;
    (void)atomic_load_explicit(&n->control, memory_order_acquire);
    n->result = BRIDGE_OK; n->accepted = 0;
    if (stopped(n) || n->command == CMD_STOP) {
        core_cleanup(n);
        atomic_store_explicit(&n->control, CORE_STOP | CORE_CLEAN, memory_order_release); return;
    }
    apply_credits(n);
    switch (n->command) {
    case CMD_INIT: {
        IP_SET_TYPE_VAL(n->client, IPADDR_TYPE_V6); IP_SET_TYPE_VAL(n->peer, IPADDR_TYPE_V6);
        memcpy(ip_2_ip6(&n->client)->addr, n->parameters.client_address, 16);
        memcpy(ip_2_ip6(&n->peer)->addr, n->parameters.server_address, 16);
        if (!netif_add_noaddr(&n->interface, n, netif_initialize, ip6_input)) {
            n->result = BRIDGE_E_LIMIT; break;
        }
        n->added = true;
        ip6_addr_assign_zone(ip_2_ip6(&n->client), IP6_UNICAST, &n->interface);
        ip6_addr_assign_zone(ip_2_ip6(&n->peer), IP6_UNICAST, &n->interface);
        netif_ip6_addr_set(&n->interface, 0, ip_2_ip6(&n->client));
        netif_ip6_addr_set_state(&n->interface, 0, IP6_ADDR_PREFERRED);
        netif_set_link_up(&n->interface); netif_set_up(&n->interface);
        break;
    }
    case CMD_TICK: break;
    case CMD_INPUT: {
        struct pbuf *p = pbuf_alloc(PBUF_RAW, (u16_t)n->size, PBUF_RAM);
        if (!p) { n->result = BRIDGE_E_LIMIT; break; }
        if (pbuf_take(p, n->rx_packet, (u16_t)n->size) != ERR_OK) {
            pbuf_free(p); n->result = BRIDGE_E_LIMIT; break;
        }
        err_t e = n->interface.input(p, &n->interface);
        if (e != ERR_OK) pbuf_free(p);
        n->result = lwip_status(e);
        break;
    }
    case CMD_TCP_OPEN: {
        tcp_slot *s = &n->tcp[n->slot];
        s->pcb = tcp_new_ip_type(IPADDR_TYPE_V6);
        if (!s->pcb) { n->result = BRIDGE_E_LIMIT; break; }
        atomic_fetch_add_explicit(&s->generation, 1, memory_order_relaxed);
        atomic_store_explicit(&s->rx_head, 0, memory_order_relaxed);
        atomic_store_explicit(&s->rx_tail, 0, memory_order_relaxed);
        atomic_store_explicit(&s->credit, 0, memory_order_relaxed);
        atomic_store_explicit(&s->outstanding, 0, memory_order_relaxed);
        atomic_store_explicit(&s->state, CH_CONNECTING, memory_order_release);
        tcp_arg(s->pcb, s); tcp_recv(s->pcb, tcp_receive); tcp_err(s->pcb, tcp_error); tcp_sent(s->pcb, tcp_acked);
        tcp_bind_netif(s->pcb, &n->interface);
        tcp_nagle_disable(s->pcb);
        err_t e = tcp_bind(s->pcb, &n->client, 0);
        if (e == ERR_OK) e = tcp_connect(s->pcb, &n->peer, n->peer_port, tcp_connected);
        if (e != ERR_OK) { tcp_release(s); n->result = lwip_status(e); }
        break;
    }
    case CMD_TCP_WRITE: {
        tcp_slot *s = &n->tcp[n->slot];
        unsigned state = atomic_load_explicit(&s->state, memory_order_relaxed);
        if (!s->pcb || atomic_load_explicit(&s->generation, memory_order_relaxed) != n->generation ||
            (state != CH_OPEN && state != CH_EOF)) {
            n->result = BRIDGE_E_IO; break;
        }
        size_t amount = n->size;
        if (amount > tcp_sndbuf(s->pcb)) amount = tcp_sndbuf(s->pcb);
        if (!amount) { n->result = BRIDGE_E_LIMIT; break; }
        err_t e = tcp_write(s->pcb, n->command_data, (u16_t)amount, TCP_WRITE_FLAG_COPY);
        n->result = lwip_status(e);
        if (e == ERR_OK) {
            atomic_fetch_add_explicit(&s->outstanding, (uint32_t)amount, memory_order_release);
            n->accepted = amount; (void)tcp_output(s->pcb);
        }
        break;
    }
    case CMD_TCP_CLOSE:
        if (atomic_load_explicit(&n->tcp[n->slot].generation, memory_order_relaxed) != n->generation)
            n->result = BRIDGE_E_ARGUMENT;
        else tcp_release(&n->tcp[n->slot]);
        break;
    case CMD_UDP_OPEN: {
        udp_slot *s = &n->udp[n->slot];
        s->pcb = udp_new_ip_type(IPADDR_TYPE_V6);
        if (!s->pcb) { n->result = BRIDGE_E_LIMIT; break; }
        atomic_fetch_add_explicit(&s->generation, 1, memory_order_relaxed);
        atomic_store_explicit(&s->head, 0, memory_order_relaxed);
        atomic_store_explicit(&s->tail, 0, memory_order_relaxed);
        udp_bind_netif(s->pcb, &n->interface);
        err_t e = udp_bind(s->pcb, &n->client, n->local_port);
        if (e == ERR_OK && n->peer_port) e = udp_connect(s->pcb, &n->peer, n->peer_port);
        if (e != ERR_OK) { udp_release(s); n->result = lwip_status(e); break; }
        udp_recv(s->pcb, udp_receive, s);
        atomic_store_explicit(&s->state, CH_OPEN, memory_order_release);
        break;
    }
    case CMD_UDP_SEND: {
        udp_slot *s = &n->udp[n->slot];
        if (!s->pcb || atomic_load_explicit(&s->generation, memory_order_relaxed) != n->generation) {
            n->result = BRIDGE_E_ARGUMENT; break;
        }
        struct pbuf *p = pbuf_alloc(PBUF_TRANSPORT, (u16_t)n->size, PBUF_RAM);
        if (!p) { n->result = BRIDGE_E_LIMIT; break; }
        err_t e = pbuf_take(p, n->command_data, (u16_t)n->size);
        if (e == ERR_OK) e = udp_sendto_if_src(s->pcb, p, &n->peer, n->peer_port,
            &n->interface, &n->client);
        pbuf_free(p); n->result = lwip_status(e);
        break;
    }
    case CMD_UDP_CLOSE:
        if (atomic_load_explicit(&n->udp[n->slot].generation, memory_order_relaxed) != n->generation)
            n->result = BRIDGE_E_ARGUMENT;
        else udp_release(&n->udp[n->slot]);
        break;
    case CMD_STOP: break;
    }
    /* A single CAS linearizes command completion against shutdown. If stop
     * won the race while this callback was running, clean up here. If normal
     * completion wins, shutdown sees idle and posts its own cleanup. There is
     * no lost-stop interval between a separate stop check and busy=false. */
    unsigned expected = CORE_BUSY;
    if (!atomic_compare_exchange_strong_explicit(&n->control, &expected, 0,
        memory_order_acq_rel, memory_order_acquire)) {
        core_cleanup(n);
        atomic_store_explicit(&n->control, CORE_STOP | CORE_CLEAN, memory_order_release);
    }
    /* Never access n after either final completion publication. */
}
static bridge_status post(bridge_lwip_net *n) {
    (void)atomic_fetch_or_explicit(&n->control, CORE_BUSY, memory_order_release);
    err_t e = tcpip_try_callback(core_command, n);
    if (e != ERR_OK) (void)atomic_fetch_and_explicit(&n->control, ~(unsigned)CORE_BUSY, memory_order_release);
    return lwip_status(e);
}
static bridge_status idle(bridge_lwip_net *n, uint64_t deadline) {
    bridge_status s = available(n, deadline);
    if (s != BRIDGE_OK) return s;
    while (busy(n)) {
        s = pump(n, deadline, false);
        if (s != BRIDGE_OK) return s;
        sys_msleep(1);
        if (now(n) >= deadline) return fail(n, BRIDGE_E_TIMEOUT);
    }
    return BRIDGE_OK;
}
static bridge_status submit(bridge_lwip_net *n, uint64_t deadline) {
    bridge_status s;
    while ((s = post(n)) == BRIDGE_E_LIMIT) {
        if (now(n) >= deadline) return BRIDGE_E_TIMEOUT;
        s = pump(n, deadline, false);
        if (s != BRIDGE_OK) return s;
        sys_msleep(1);
    }
    if (s != BRIDGE_OK) return s;
    s = idle(n, deadline);
    /* Once a command was posted, a missed acknowledgment deadline leaves its
     * effect indeterminate to the caller (for example an opened PCB without a
     * returned handle). Stop this net instead of leaking an unreachable slot
     * or allowing a timed-out copied write to race a subsequent operation. */
    if (s == BRIDGE_E_TIMEOUT) return fail(n, s);
    return s == BRIDGE_OK ? n->result : s;
}
static bridge_status pump(bridge_lwip_net *n, uint64_t deadline, bool receive) {
    bridge_status s = available(n, deadline);
    if (s != BRIDGE_OK) return s;
    /* Take a snapshot: a busy peer cannot keep the owner in an unbounded drain. */
    uint32_t h = atomic_load_explicit(&n->tx_head, memory_order_acquire);
    uint32_t t = atomic_load_explicit(&n->tx_tail, memory_order_relaxed);
    while (t != h) {
        ip_packet *p = &n->tx[t % BRIDGE_LWIP_TX_PACKETS];
        s = bridge_cdtunnel_send_ipv6(n->link.tunnel, p->bytes, p->size, deadline);
        if (s != BRIDGE_OK) return fail(n, s);
        atomic_store_explicit(&n->tx_tail, ++t, memory_order_release);
        atomic_fetch_add_explicit(&n->stat_tx, 1, memory_order_relaxed);
    }
    if (now(n) >= deadline) return BRIDGE_E_TIMEOUT;
    s = n->link.poll(n->link.context, deadline);
    if (s != BRIDGE_OK) return fail(n, s);
    if (now(n) >= deadline) return BRIDGE_E_TIMEOUT;
    if (!receive || busy(n)) return BRIDGE_OK;
    bool ready = false;
    s = n->link.readable(n->link.context, &ready);
    if (s != BRIDGE_OK) return fail(n, s);
    n->command = CMD_TICK;
    if (ready) {
        size_t size = 0;
        s = bridge_cdtunnel_recv_ipv6(n->link.tunnel, n->rx_packet, sizeof n->rx_packet, &size, deadline);
        if (s != BRIDGE_OK) return fail(n, s);
        if (memcmp(n->rx_packet + 8, n->parameters.server_address, 16) ||
            memcmp(n->rx_packet + 24, n->parameters.client_address, 16) ||
            !ingress_profile(n->rx_packet, size)) {
            atomic_fetch_add_explicit(&n->stat_rejected, 1, memory_order_relaxed);
            return BRIDGE_OK;
        }
        n->size = size; n->command = CMD_INPUT;
        atomic_fetch_add_explicit(&n->stat_rx, 1, memory_order_relaxed);
    }
    /* Failure to queue INPUT cannot be retried after reading another packet.
     * Keep the staging buffer and retry through submit; TICK may be skipped. */
    if (n->command == CMD_INPUT) return submit(n, deadline);
    s = post(n);
    return s == BRIDGE_E_LIMIT ? BRIDGE_OK : s;
}
bridge_status bridge_lwip_create(const bridge_packet_link *link, bridge_lwip_net **out,
    uint64_t deadline) {
    if (!out) return BRIDGE_E_ARGUMENT;
    *out = NULL;
    if (!link || !link->tunnel || !link->poll || !link->readable ||
        link->tunnel->state != BRIDGE_CDTUNNEL_READY || !link->tunnel->io.clock_ms ||
        link->tunnel->parameters.mtu < BRIDGE_CDTUNNEL_MIN_MTU ||
        link->tunnel->parameters.mtu > BRIDGE_CDTUNNEL_MAX_MTU) return BRIDGE_E_ARGUMENT;
#ifdef ESP_PLATFORM
    bridge_lwip_net *n = heap_caps_calloc(1, sizeof *n, MALLOC_CAP_SPIRAM | MALLOC_CAP_8BIT);
#else
    bridge_lwip_net *n = calloc(1, sizeof *n);
#endif
    if (!n) return BRIDGE_E_LIMIT;
    n->link = *link; n->parameters = link->tunnel->parameters;
    atomic_init(&n->control, 0);
    atomic_init(&n->tx_head, 0); atomic_init(&n->tx_tail, 0);
    atomic_init(&n->stat_tx, 0); atomic_init(&n->stat_rx, 0);
    atomic_init(&n->stat_backpressure, 0); atomic_init(&n->stat_rejected, 0);
    atomic_init(&n->stat_udp_dropped, 0); atomic_init(&n->stat_udp_received, 0);
    for (unsigned i = 0; i < BRIDGE_LWIP_TCP_SLOTS; ++i) {
        tcp_slot *s = &n->tcp[i]; s->net = n;
        atomic_init(&s->state, CH_FREE); atomic_init(&s->generation, 0);
        atomic_init(&s->rx_head, 0); atomic_init(&s->rx_tail, 0);
        atomic_init(&s->credit, 0); atomic_init(&s->outstanding, 0);
    }
    for (unsigned i = 0; i < BRIDGE_LWIP_UDP_SLOTS; ++i) {
        udp_slot *s = &n->udp[i]; s->net = n;
        atomic_init(&s->state, CH_FREE); atomic_init(&s->generation, 0);
        atomic_init(&s->head, 0); atomic_init(&s->tail, 0);
    }
    *out = n;
    n->command = CMD_INIT;
    bridge_status s = available(n, deadline);
    if (s == BRIDGE_OK) s = submit(n, deadline);
    if (s != BRIDGE_OK) (void)bridge_lwip_shutdown(n);
    return s;
}
bridge_status bridge_lwip_poll(bridge_lwip_net *n, uint64_t deadline) {
    return pump(n, deadline, true);
}
static bool tcp_valid(const bridge_lwip_tcp *handle) {
    return handle && handle->net && handle->slot < BRIDGE_LWIP_TCP_SLOTS &&
        atomic_load_explicit(&handle->net->tcp[handle->slot].generation, memory_order_acquire) == handle->generation &&
        atomic_load_explicit(&handle->net->tcp[handle->slot].state, memory_order_acquire) != CH_FREE;
}
static bool udp_valid(const bridge_lwip_udp *handle) {
    return handle && handle->net && handle->slot < BRIDGE_LWIP_UDP_SLOTS &&
        atomic_load_explicit(&handle->net->udp[handle->slot].generation, memory_order_acquire) == handle->generation &&
        atomic_load_explicit(&handle->net->udp[handle->slot].state, memory_order_acquire) == CH_OPEN;
}
bridge_status bridge_lwip_tcp_connect(bridge_lwip_net *n, uint16_t port, uint64_t deadline,
    bridge_lwip_tcp *out) {
    if (!out || !port) return BRIDGE_E_ARGUMENT;
    memset(out, 0, sizeof *out);
    bridge_status s = idle(n, deadline);
    if (s != BRIDGE_OK) return s;
    unsigned slot;
    for (slot = 0; slot < BRIDGE_LWIP_TCP_SLOTS; ++slot)
        if (atomic_load_explicit(&n->tcp[slot].state, memory_order_acquire) == CH_FREE &&
            atomic_load_explicit(&n->tcp[slot].generation, memory_order_acquire) != UINT32_MAX) break;
    if (slot == BRIDGE_LWIP_TCP_SLOTS) return BRIDGE_E_LIMIT;
    n->slot = slot; n->peer_port = port; n->command = CMD_TCP_OPEN;
    s = submit(n, deadline);
    if (s != BRIDGE_OK) return s;
    out->net = n; out->slot = slot;
    out->generation = atomic_load_explicit(&n->tcp[slot].generation, memory_order_acquire);
    while (atomic_load_explicit(&n->tcp[slot].state, memory_order_acquire) == CH_CONNECTING) {
        s = bridge_lwip_poll(n, deadline);
        if (s != BRIDGE_OK) return s; /* handle is retained for close, even on timeout */
        sys_msleep(1);
    }
    return atomic_load_explicit(&n->tcp[slot].state, memory_order_acquire) == CH_OPEN ? BRIDGE_OK : BRIDGE_E_IO;
}
static uint64_t io_clock(void *context) {
    bridge_lwip_tcp *handle = context;
    if (!tcp_valid(handle) || stopped(handle->net)) return UINT64_MAX;
    return now(handle->net);
}
static uint64_t io_deadline(bridge_lwip_net *n, uint32_t timeout) {
    uint64_t t = now(n);
    return UINT64_MAX - t < timeout ? UINT64_MAX : t + timeout;
}
static ptrdiff_t io_read(void *context, uint8_t *data, size_t length, uint32_t timeout) {
    bridge_lwip_tcp *handle = context;
    if (!tcp_valid(handle) || !data || !length) return -(ptrdiff_t)BRIDGE_E_ARGUMENT;
    bridge_lwip_net *n = handle->net;
    if (stopped(n)) return -(ptrdiff_t)BRIDGE_E_IO;
    uint64_t deadline = io_deadline(n, timeout);
    tcp_slot *slot = &n->tcp[handle->slot];
    for (;;) {
        bridge_status s = available(n, deadline);
        if (s != BRIDGE_OK) return -(ptrdiff_t)s;
        uint32_t t = atomic_load_explicit(&slot->rx_tail, memory_order_relaxed);
        uint32_t h = atomic_load_explicit(&slot->rx_head, memory_order_acquire);
        if (h != t) {
            size_t count = h - t;
            if (count > length) count = length;
            size_t offset = t % BRIDGE_LWIP_TCP_RX_CAPACITY;
            size_t first = BRIDGE_LWIP_TCP_RX_CAPACITY - offset;
            if (first > count) first = count;
            memcpy(data, slot->rx + offset, first);
            memcpy(data + first, slot->rx, count - first);
            atomic_store_explicit(&slot->rx_tail, t + (uint32_t)count, memory_order_release);
            atomic_fetch_add_explicit(&slot->credit, (uint32_t)count, memory_order_release);
            return (ptrdiff_t)count;
        }
        unsigned state = atomic_load_explicit(&slot->state, memory_order_acquire);
        if (state == CH_EOF) return 0;
        if (state != CH_OPEN) return -(ptrdiff_t)BRIDGE_E_IO;
        s = bridge_lwip_poll(n, deadline);
        if (s != BRIDGE_OK) return -(ptrdiff_t)s;
        sys_msleep(1);
    }
}
static ptrdiff_t io_write(void *context, const uint8_t *data, size_t length, uint32_t timeout) {
    bridge_lwip_tcp *handle = context;
    if (!tcp_valid(handle) || !data || !length) return -(ptrdiff_t)BRIDGE_E_ARGUMENT;
    bridge_lwip_net *n = handle->net;
    if (stopped(n)) return -(ptrdiff_t)BRIDGE_E_IO;
    uint64_t deadline = io_deadline(n, timeout);
    if (length > BRIDGE_LWIP_WRITE_CAPACITY) length = BRIDGE_LWIP_WRITE_CAPACITY;
    for (;;) {
        bridge_status s = idle(n, deadline);
        if (s != BRIDGE_OK) return -(ptrdiff_t)s;
        n->slot = handle->slot; n->generation = handle->generation;
        n->size = length; memcpy(n->command_data, data, length); n->command = CMD_TCP_WRITE;
        s = submit(n, deadline);
        if (s == BRIDGE_OK) return (ptrdiff_t)n->accepted;
        if (s != BRIDGE_E_LIMIT) return -(ptrdiff_t)s;
        s = bridge_lwip_poll(n, deadline);
        if (s != BRIDGE_OK) return -(ptrdiff_t)s;
        sys_msleep(1);
    }
}
bridge_io bridge_lwip_tcp_io(bridge_lwip_tcp *handle) {
    bridge_io io = {handle, io_read, io_write, io_clock};
    return io;
}
bridge_status bridge_lwip_tcp_pending(const bridge_lwip_tcp *handle, size_t *bytes) {
    if (!bytes) return BRIDGE_E_ARGUMENT;
    *bytes = 0;
    if (!tcp_valid(handle)) return BRIDGE_E_ARGUMENT;
    if (stopped(handle->net)) return BRIDGE_E_IO;
    const tcp_slot *s = &handle->net->tcp[handle->slot];
    uint32_t t = atomic_load_explicit(&s->rx_tail, memory_order_relaxed);
    uint32_t h = atomic_load_explicit(&s->rx_head, memory_order_acquire);
    *bytes = h - t;
    if (*bytes) return BRIDGE_OK;
    unsigned state = atomic_load_explicit(&s->state, memory_order_acquire);
    return state == CH_EOF ? BRIDGE_E_EOF : state == CH_OPEN ? BRIDGE_OK : BRIDGE_E_IO;
}
bridge_status bridge_lwip_tcp_drain(bridge_lwip_tcp *handle, uint64_t deadline) {
    if (!tcp_valid(handle)) return BRIDGE_E_ARGUMENT;
    bridge_lwip_net *n = handle->net;
    tcp_slot *slot = &n->tcp[handle->slot];
    for (;;) {
        bridge_status s = available(n, deadline);
        if (s != BRIDGE_OK) return s;
        unsigned state = atomic_load_explicit(&slot->state, memory_order_acquire);
        if (state != CH_OPEN && state != CH_EOF) return BRIDGE_E_IO;
        if (!atomic_load_explicit(&slot->outstanding, memory_order_acquire)) return BRIDGE_OK;
        s = bridge_lwip_poll(n, deadline);
        if (s != BRIDGE_OK) return s;
        sys_msleep(1);
    }
}
bridge_status bridge_lwip_tcp_close(bridge_lwip_tcp *handle, uint64_t deadline) {
    if (!tcp_valid(handle)) return BRIDGE_E_ARGUMENT;
    bridge_lwip_net *n = handle->net;
    bridge_status s = idle(n, deadline);
    if (s != BRIDGE_OK) return s;
    n->slot = handle->slot; n->generation = handle->generation; n->command = CMD_TCP_CLOSE;
    s = submit(n, deadline);
    if (s == BRIDGE_OK) handle->net = NULL;
    return s;
}
bridge_status bridge_lwip_udp_open(bridge_lwip_net *n, uint16_t local_port,
    uint16_t remote_port, uint64_t deadline, bridge_lwip_udp *out) {
    if (!out || !local_port) return BRIDGE_E_ARGUMENT;
    memset(out, 0, sizeof *out);
    bridge_status s = idle(n, deadline);
    if (s != BRIDGE_OK) return s;
    unsigned slot;
    for (slot = 0; slot < BRIDGE_LWIP_UDP_SLOTS; ++slot)
        if (atomic_load_explicit(&n->udp[slot].state, memory_order_acquire) == CH_FREE &&
            atomic_load_explicit(&n->udp[slot].generation, memory_order_acquire) != UINT32_MAX) break;
    if (slot == BRIDGE_LWIP_UDP_SLOTS) return BRIDGE_E_LIMIT;
    n->slot = slot; n->local_port = local_port; n->peer_port = remote_port; n->command = CMD_UDP_OPEN;
    s = submit(n, deadline);
    if (s == BRIDGE_OK) {
        out->net = n; out->slot = slot;
        out->generation = atomic_load_explicit(&n->udp[slot].generation, memory_order_acquire);
    }
    return s;
}
bridge_status bridge_lwip_udp_send(bridge_lwip_udp *handle, uint16_t port,
    const uint8_t *data, size_t length, uint64_t deadline) {
    if (!udp_valid(handle) || !port || (!data && length)) return BRIDGE_E_ARGUMENT;
    bridge_lwip_net *n = handle->net;
    if (length > BRIDGE_LWIP_UDP_CAPACITY || length > (size_t)n->parameters.mtu - 48u)
        return BRIDGE_E_LIMIT;
    bridge_status s = idle(n, deadline);
    if (s != BRIDGE_OK) return s;
    n->slot = handle->slot; n->generation = handle->generation; n->peer_port = port;
    n->size = length; if (length) memcpy(n->command_data, data, length);
    n->command = CMD_UDP_SEND;
    return submit(n, deadline);
}
bridge_status bridge_lwip_udp_receive(bridge_lwip_udp *handle, uint8_t *data, size_t capacity,
    size_t *received, uint16_t *port, uint64_t deadline) {
    if (!udp_valid(handle) || !received || !port || (!data && capacity)) return BRIDGE_E_ARGUMENT;
    *received = 0; *port = 0;
    bridge_lwip_net *n = handle->net;
    udp_slot *slot = &n->udp[handle->slot];
    for (;;) {
        bridge_status s = available(n, deadline);
        if (s != BRIDGE_OK) return s;
        uint32_t t = atomic_load_explicit(&slot->tail, memory_order_relaxed);
        uint32_t h = atomic_load_explicit(&slot->head, memory_order_acquire);
        if (h != t) {
            const datagram *d = &slot->packets[t % BRIDGE_LWIP_UDP_PACKETS];
            if (capacity < d->size) return BRIDGE_E_LIMIT;
            if (d->size) memcpy(data, d->bytes, d->size);
            *received = d->size; *port = d->port;
            atomic_store_explicit(&slot->tail, t + 1u, memory_order_release);
            return BRIDGE_OK;
        }
        s = bridge_lwip_poll(n, deadline);
        if (s != BRIDGE_OK) return s;
        sys_msleep(1);
    }
}
bridge_status bridge_lwip_udp_close(bridge_lwip_udp *handle, uint64_t deadline) {
    if (!udp_valid(handle)) return BRIDGE_E_ARGUMENT;
    bridge_lwip_net *n = handle->net;
    bridge_status s = idle(n, deadline);
    if (s != BRIDGE_OK) return s;
    n->slot = handle->slot; n->generation = handle->generation; n->command = CMD_UDP_CLOSE;
    s = submit(n, deadline);
    if (s == BRIDGE_OK) handle->net = NULL;
    return s;
}
void bridge_lwip_get_stats(const bridge_lwip_net *n, bridge_lwip_stats *out) {
    if (!n || !out) return;
    *out = (bridge_lwip_stats){
        atomic_load_explicit(&n->stat_tx, memory_order_relaxed),
        atomic_load_explicit(&n->stat_rx, memory_order_relaxed),
        atomic_load_explicit(&n->stat_backpressure, memory_order_relaxed),
        atomic_load_explicit(&n->stat_rejected, memory_order_relaxed),
        atomic_load_explicit(&n->stat_udp_dropped, memory_order_relaxed),
        atomic_load_explicit(&n->stat_udp_received, memory_order_relaxed), sizeof *n};
}
bridge_status bridge_lwip_shutdown(bridge_lwip_net *n) {
    if (!n) return BRIDGE_E_ARGUMENT;
    unsigned previous = atomic_fetch_or_explicit(&n->control, CORE_STOP, memory_order_acq_rel);
    if (previous & (CORE_BUSY | CORE_CLEAN)) return BRIDGE_OK;
    n->command = CMD_STOP;
    return post(n);
}
bool bridge_lwip_cleanup_complete(const bridge_lwip_net *n) {
    return n && (atomic_load_explicit(&n->control, memory_order_acquire) & (CORE_BUSY | CORE_CLEAN)) == CORE_CLEAN;
}
bridge_status bridge_lwip_destroy(bridge_lwip_net *n) {
    if (!n) return BRIDGE_E_ARGUMENT;
    bridge_status s = bridge_lwip_shutdown(n);
    if (s != BRIDGE_OK) return s;
    if (!bridge_lwip_cleanup_complete(n)) return BRIDGE_E_TIMEOUT;
    free(n);
    return BRIDGE_OK;
}
