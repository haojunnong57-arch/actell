/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only
 *
 * New bounded implementation of wire behavior inspected in usbmuxd commit
 * 3ded00c9985a5108cfc7591a309f9a23d57a8cba, src/device.c and src/usb.h.
 * Upstream device.c: Copyright (C) 2009 Hector Martin "marcan"
 * <hector@marcansoft.com>; Copyright (C) 2014 Mikkel Kamstrup Erlandsen
 * <mikkel.kamstrup@xamarin.com>. Upstream permits GPL version 2 or version 3,
 * not an unrestricted "or later" grant. Retained conservatively for this module.
 *
 * This program is distributed without any warranty; see the GNU GPL.
 * Directional v2 magic cross-checked in hack-different/demuxusb commit
 * 778f8cd0ffd1558be857c0d170ab5d8eacd89ba3, ext/usbmux.h and
 * src/protocol/USBMUXInterfaceExpert.cpp (IN FACEFACE / OUT FEEDFACE);
 * no analyzer implementation copied. Canonical usbmuxd ignores incoming magic.
 * Deliberate differences: fixed buffers, checked bytewise encoding, fragmented
 * AND coalesced input, bounded channel/window state, and terminal framing errors.
 */
#include "bridge_usbmux.h"
#include <string.h>

#define MUX_VERSION UINT32_C(0)
#define MUX_CONTROL UINT32_C(1)
#define MUX_SETUP UINT32_C(2)
#define MUX_TCP UINT32_C(6)
#define MUX_MAGIC_OUT UINT32_C(0xfeedface)
#define MUX_MAGIC_IN UINT32_C(0xfaceface)
#define TCP_SYN 0x02u
#define TCP_RST 0x04u
#define TCP_ACK 0x10u

_Static_assert(BRIDGE_USBMUX_RX_CAPACITY % 256u == 0u, "window scale is 256");
_Static_assert(BRIDGE_USBMUX_RX_CAPACITY < 0x80000000u, "serial arithmetic bound");
_Static_assert(BRIDGE_USBMUX_TX_FRAME <= 3u * 16384u, "upstream USB_MTU");

static uint16_t be16(const uint8_t *p)
{
    return (uint16_t)(((uint16_t)p[0] << 8) | (uint16_t)p[1]);
}
static uint32_t be32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}
static void put16(uint8_t *p, uint16_t x)
{
    p[0] = (uint8_t)(x >> 8); p[1] = (uint8_t)x;
}
static void put32(uint8_t *p, uint32_t x)
{
    p[0] = (uint8_t)(x >> 24); p[1] = (uint8_t)(x >> 16);
    p[2] = (uint8_t)(x >> 8); p[3] = (uint8_t)x;
}
static bool before(uint32_t a, uint32_t b)
{
    return a != b && (uint32_t)(b - a) < UINT32_C(0x80000000);
}
static bool expired(uint64_t now, uint64_t since)
{
    return now - since >= BRIDGE_USBMUX_TIMEOUT_MS;
}
static bridge_usbmux_channel *channel(bridge_usbmux *m, bridge_usbmux_channel_id id)
{
    if (id == 0u) return NULL;
    for (size_t i = 0; i < BRIDGE_USBMUX_CHANNELS; ++i)
        if (m->channels[i].id == id) return &m->channels[i];
    return NULL;
}
static bridge_status reason_status(bridge_usbmux_reason reason)
{
    switch (reason) {
    case BRIDGE_USBMUX_REASON_LOCAL_CLOSE: return BRIDGE_E_EOF;
    case BRIDGE_USBMUX_REASON_TIMEOUT: return BRIDGE_E_TIMEOUT;
    case BRIDGE_USBMUX_REASON_PROTOCOL: return BRIDGE_E_FORMAT;
    case BRIDGE_USBMUX_REASON_OVERFLOW: return BRIDGE_E_LIMIT;
    case BRIDGE_USBMUX_REASON_NONE: return BRIDGE_OK;
    default: return BRIDGE_E_IO;
    }
}
static bridge_status fail_link(bridge_usbmux *m, bridge_status error,
    bridge_usbmux_reason reason)
{
    m->state = BRIDGE_USBMUX_DEAD;
    m->error = error;
    m->frame_used = 0;
    m->frame_expected = 0;
    m->anonymous_reset_pending = false;
    for (size_t i = 0; i < BRIDGE_USBMUX_CHANNELS; ++i) {
        bridge_usbmux_channel *c = &m->channels[i];
        if (c->state != BRIDGE_USBMUX_CH_FREE && c->state != BRIDGE_USBMUX_CH_CLOSED) {
            c->state = BRIDGE_USBMUX_CH_CLOSED;
            c->reason = reason;
            c->ack_pending = false;
        }
    }
    return error;
}
static size_t header_size(const bridge_usbmux *m)
{
    return m->version >= 2u ? 16u : 8u;
}
/* Body is already in m->tx at the appropriate mux-header offset. */
static bridge_status emit(bridge_usbmux *m, uint32_t protocol, size_t size)
{
    put32(m->tx, protocol);
    put32(m->tx + 4, (uint32_t)size);
    if (m->version >= 2u) {
        put32(m->tx + 8, MUX_MAGIC_OUT);
        put16(m->tx + 12, m->tx_seq);
        put16(m->tx + 14, m->rx_seq);
    }
    bridge_status result = m->send(m->send_context, m->tx, size);
    if (result == BRIDGE_OK) {
        if (m->version >= 2u) m->tx_seq = (uint16_t)(m->tx_seq + 1u);
    } else if (result != BRIDGE_E_LIMIT) {
        return fail_link(m, result, BRIDGE_USBMUX_REASON_IO);
    }
    return result;
}
static bridge_status tcp(bridge_usbmux *m, bridge_usbmux_channel *c,
    uint8_t flags, const uint8_t *data, size_t size)
{
    size_t h = header_size(m);
    uint8_t *t = m->tx + h;
    uint32_t window = (uint32_t)(BRIDGE_USBMUX_RX_CAPACITY - c->rx_size) & ~UINT32_C(255);
    memset(t, 0, 20);
    put16(t, c->local_port); put16(t + 2, c->remote_port);
    put32(t + 4, c->tx_next); put32(t + 8, c->rx_next);
    t[12] = 0x50; t[13] = flags;
    put16(t + 14, (uint16_t)(window >> 8));
    if (size != 0u) memcpy(t + 20, data, size);
    bridge_status result = emit(m, MUX_TCP, h + 20u + size);
    if (result == BRIDGE_OK) {
        /* Rounding free space down to the implicit 256-byte window unit may
         * move the advertised right edge left by up to 255 bytes. Keep honoring
         * previously granted in-flight bytes; never shrink the receive limit. */
        uint32_t limit = c->rx_next + window;
        if (before(c->rx_limit, limit)) c->rx_limit = limit;
        c->ack_pending = false;
    }
    return result;
}
static void closing(bridge_usbmux_channel *c, bridge_usbmux_reason reason, uint64_t now)
{
    c->state = BRIDGE_USBMUX_CH_CLOSING;
    c->reason = reason;
    c->state_since_ms = now;
    c->ack_pending = false;
}
static bridge_status service_channel(bridge_usbmux *m, bridge_usbmux_channel *c, uint64_t now)
{
    bridge_status result = BRIDGE_OK;
    switch (c->state) {
    case BRIDGE_USBMUX_CH_SYN_PENDING:
        result = tcp(m, c, TCP_SYN, NULL, 0);
        if (result == BRIDGE_OK) {
            c->tx_next = 1;
            c->state = BRIDGE_USBMUX_CH_SYN_SENT;
        }
        break;
    case BRIDGE_USBMUX_CH_ACK_PENDING:
        result = tcp(m, c, TCP_ACK, NULL, 0);
        if (result == BRIDGE_OK) {
            c->state = BRIDGE_USBMUX_CH_OPEN;
            c->state_since_ms = now;
        }
        break;
    case BRIDGE_USBMUX_CH_CLOSING:
        result = tcp(m, c, TCP_RST, NULL, 0);
        if (result == BRIDGE_OK) c->state = BRIDGE_USBMUX_CH_CLOSED;
        break;
    case BRIDGE_USBMUX_CH_OPEN:
        if (c->ack_pending) result = tcp(m, c, TCP_ACK, NULL, 0);
        break;
    default: break;
    }
    return result == BRIDGE_E_LIMIT ? BRIDGE_OK : result;
}
static bridge_status anonymous_reset(bridge_usbmux *m)
{
    if (!m->anonymous_reset_pending) return BRIDGE_OK;
    size_t h = header_size(m);
    uint8_t *t = m->tx + h;
    memset(t, 0, 20);
    put16(t, m->anonymous_local); put16(t + 2, m->anonymous_remote);
    put32(t + 8, m->anonymous_ack);
    t[12] = 0x50; t[13] = TCP_RST;
    bridge_status result = emit(m, MUX_TCP, h + 20u);
    if (result == BRIDGE_OK) m->anonymous_reset_pending = false;
    return result == BRIDGE_E_LIMIT ? BRIDGE_OK : result;
}
bridge_status bridge_usbmux_init(bridge_usbmux *m, bridge_usbmux_send_fn send, void *context)
{
    if (!m || !send) return BRIDGE_E_ARGUMENT;
    memset(m, 0, sizeof(*m));
    m->send = send; m->send_context = context;
    m->next_port = 1; m->next_id = 1;
    return BRIDGE_OK;
}
bridge_status bridge_usbmux_start(bridge_usbmux *m, uint64_t now)
{
    if (!m || !m->send) return BRIDGE_E_ARGUMENT;
    if (m->state != BRIDGE_USBMUX_IDLE) return BRIDGE_E_UNSUPPORTED;
    m->state = BRIDGE_USBMUX_VERSION_PENDING;
    m->state_since_ms = now;
    return bridge_usbmux_tick(m, now);
}
void bridge_usbmux_disconnect(bridge_usbmux *m)
{
    if (m && m->state != BRIDGE_USBMUX_DEAD)
        (void)fail_link(m, BRIDGE_E_IO, BRIDGE_USBMUX_REASON_DISCONNECTED);
}
bridge_usbmux_state bridge_usbmux_get_state(const bridge_usbmux *m)
{
    return m ? m->state : BRIDGE_USBMUX_DEAD;
}
bridge_status bridge_usbmux_get_error(const bridge_usbmux *m)
{
    return m ? m->error : BRIDGE_E_ARGUMENT;
}
bridge_status bridge_usbmux_tick(bridge_usbmux *m, uint64_t now)
{
    if (!m || !m->send) return BRIDGE_E_ARGUMENT;
    if (m->state == BRIDGE_USBMUX_DEAD) return m->error;
    if (m->state == BRIDGE_USBMUX_IDLE) return BRIDGE_OK;
    if (m->state != BRIDGE_USBMUX_READY && expired(now, m->state_since_ms))
        return fail_link(m, BRIDGE_E_TIMEOUT, BRIDGE_USBMUX_REASON_TIMEOUT);
    if (m->frame_used != 0u && expired(now, m->frame_since_ms))
        return fail_link(m, BRIDGE_E_TIMEOUT, BRIDGE_USBMUX_REASON_TIMEOUT);
    if (m->state == BRIDGE_USBMUX_VERSION_PENDING) {
        put32(m->tx + 8, 2); put32(m->tx + 12, 0); put32(m->tx + 16, 0);
        bridge_status result = emit(m, MUX_VERSION, 20);
        if (result == BRIDGE_OK) m->state = BRIDGE_USBMUX_WAIT_VERSION;
        else if (result != BRIDGE_E_LIMIT) return result;
    }
    if (m->state == BRIDGE_USBMUX_SETUP_PENDING) {
        m->tx[16] = 7;
        bridge_status result = emit(m, MUX_SETUP, 17);
        if (result == BRIDGE_OK) m->state = BRIDGE_USBMUX_READY;
        else if (result != BRIDGE_E_LIMIT) return result;
    }
    if (m->state != BRIDGE_USBMUX_READY) return BRIDGE_OK;
    for (size_t i = 0; i < BRIDGE_USBMUX_CHANNELS; ++i) {
        bridge_usbmux_channel *c = &m->channels[i];
        if ((c->state == BRIDGE_USBMUX_CH_SYN_PENDING ||
             c->state == BRIDGE_USBMUX_CH_SYN_SENT ||
             c->state == BRIDGE_USBMUX_CH_ACK_PENDING) && expired(now, c->state_since_ms)) {
            /* No SYN reached USB when still pending; no RST needed then. */
            bool unsent = c->state == BRIDGE_USBMUX_CH_SYN_PENDING;
            closing(c, BRIDGE_USBMUX_REASON_TIMEOUT, now);
            if (unsent) c->state = BRIDGE_USBMUX_CH_CLOSED;
        } else if (c->state == BRIDGE_USBMUX_CH_OPEN && c->tx_next != c->tx_acked &&
                   expired(now, c->progress_since_ms)) {
            closing(c, BRIDGE_USBMUX_REASON_TIMEOUT, now);
        } else if (c->state == BRIDGE_USBMUX_CH_CLOSING && expired(now, c->state_since_ms)) {
            if (c->reason == BRIDGE_USBMUX_REASON_LOCAL_CLOSE) c->reason = BRIDGE_USBMUX_REASON_TIMEOUT;
            c->state = BRIDGE_USBMUX_CH_CLOSED;
        }
        bridge_status result = service_channel(m, c, now);
        if (result != BRIDGE_OK) return result;
    }
    return anonymous_reset(m);
}
bridge_status bridge_usbmux_open(bridge_usbmux *m, uint16_t remote, uint64_t now,
    bridge_usbmux_channel_id *id)
{
    if (id) *id = 0;
    if (!m || !id || remote == 0u) return BRIDGE_E_ARGUMENT;
    if (m->state != BRIDGE_USBMUX_READY) return BRIDGE_E_UNSUPPORTED;
    if (m->next_port == 0u || m->next_id == 0u) return BRIDGE_E_LIMIT;
    for (size_t i = 0; i < BRIDGE_USBMUX_CHANNELS; ++i) {
        bridge_usbmux_channel *c = &m->channels[i];
        if (c->state != BRIDGE_USBMUX_CH_FREE) continue;
        memset(c, 0, sizeof(*c));
        c->id = m->next_id++;
        c->local_port = m->next_port;
        m->next_port = (uint16_t)(m->next_port + 1u);
        c->remote_port = remote;
        c->state = BRIDGE_USBMUX_CH_SYN_PENDING;
        c->state_since_ms = now;
        *id = c->id;
        return service_channel(m, c, now);
    }
    return BRIDGE_E_LIMIT;
}
bridge_status bridge_usbmux_channel_status(const bridge_usbmux *m, bridge_usbmux_channel_id id,
    bridge_usbmux_channel_state *state, bridge_usbmux_reason *reason)
{
    if (!m || !state || !reason) return BRIDGE_E_ARGUMENT;
    for (size_t i = 0; id != 0u && i < BRIDGE_USBMUX_CHANNELS; ++i) {
        if (m->channels[i].id == id) {
            *state = m->channels[i].state; *reason = m->channels[i].reason;
            return BRIDGE_OK;
        }
    }
    return BRIDGE_E_NOT_FOUND;
}
bridge_status bridge_usbmux_write(bridge_usbmux *m, bridge_usbmux_channel_id id,
    const uint8_t *data, size_t size, size_t *count, uint64_t now)
{
    if (count) *count = 0;
    if (!m || !count || (!data && size != 0u)) return BRIDGE_E_ARGUMENT;
    bridge_usbmux_channel *c = channel(m, id);
    if (!c) return BRIDGE_E_NOT_FOUND;
    if (c->state == BRIDGE_USBMUX_CH_CLOSED || c->state == BRIDGE_USBMUX_CH_CLOSING)
        return reason_status(c->reason);
    if (c->state != BRIDGE_USBMUX_CH_OPEN || size == 0u) return BRIDGE_OK;
    uint32_t outstanding = c->tx_next - c->tx_acked;
    if (outstanding >= c->peer_window) return BRIDGE_OK;
    size_t available = (size_t)(c->peer_window - outstanding);
    if (size > available) size = available;
    if (size > BRIDGE_USBMUX_TX_PAYLOAD) size = BRIDGE_USBMUX_TX_PAYLOAD;
    bridge_status result = tcp(m, c, TCP_ACK, data, size);
    if (result == BRIDGE_E_LIMIT) return BRIDGE_OK;
    if (result != BRIDGE_OK) return result;
    if (outstanding == 0u) c->progress_since_ms = now;
    c->tx_next += (uint32_t)size;
    *count = size;
    return BRIDGE_OK;
}
bridge_status bridge_usbmux_read(bridge_usbmux *m, bridge_usbmux_channel_id id,
    uint8_t *out, size_t capacity, size_t *count)
{
    if (count) *count = 0;
    if (!m || !count || (!out && capacity != 0u)) return BRIDGE_E_ARGUMENT;
    bridge_usbmux_channel *c = channel(m, id);
    if (!c) return BRIDGE_E_NOT_FOUND;
    if (c->rx_size != 0u) {
        size_t size = c->rx_size < capacity ? c->rx_size : capacity;
        size_t first = BRIDGE_USBMUX_RX_CAPACITY - c->rx_head;
        if (first > size) first = size;
        if (first != 0u) memcpy(out, c->rx + c->rx_head, first);
        if (size > first) memcpy(out + first, c->rx, size - first);
        c->rx_head = (c->rx_head + size) % BRIDGE_USBMUX_RX_CAPACITY;
        c->rx_size -= size;
        *count = size;
        if (size != 0u && c->state == BRIDGE_USBMUX_CH_OPEN) c->ack_pending = true;
        return BRIDGE_OK;
    }
    if (c->state == BRIDGE_USBMUX_CH_CLOSED || c->state == BRIDGE_USBMUX_CH_CLOSING)
        return reason_status(c->reason);
    return BRIDGE_OK;
}
bridge_status bridge_usbmux_close(bridge_usbmux *m, bridge_usbmux_channel_id id, uint64_t now)
{
    if (!m) return BRIDGE_E_ARGUMENT;
    bridge_usbmux_channel *c = channel(m, id);
    if (!c) return BRIDGE_E_NOT_FOUND;
    if (c->state == BRIDGE_USBMUX_CH_CLOSED || c->state == BRIDGE_USBMUX_CH_CLOSING) return BRIDGE_OK;
    bool unsent = c->state == BRIDGE_USBMUX_CH_SYN_PENDING;
    closing(c, BRIDGE_USBMUX_REASON_LOCAL_CLOSE, now);
    if (unsent) { c->state = BRIDGE_USBMUX_CH_CLOSED; return BRIDGE_OK; }
    return service_channel(m, c, now);
}
bridge_status bridge_usbmux_release(bridge_usbmux *m, bridge_usbmux_channel_id id)
{
    if (!m) return BRIDGE_E_ARGUMENT;
    bridge_usbmux_channel *c = channel(m, id);
    if (!c) return BRIDGE_E_NOT_FOUND;
    if (c->state != BRIDGE_USBMUX_CH_CLOSED) return BRIDGE_E_UNSUPPORTED;
    memset(c, 0, sizeof(*c));
    return BRIDGE_OK;
}
static bridge_status input_tcp(bridge_usbmux *m, const uint8_t *t, size_t size, uint64_t now)
{
    /* usbmux uses precisely the fixed 20-byte pseudo-TCP header, no options. */
    if (size < 20u || t[12] != 0x50u)
        return fail_link(m, BRIDGE_E_FORMAT, BRIDGE_USBMUX_REASON_PROTOCOL);
    uint16_t remote = be16(t), local = be16(t + 2);
    uint32_t seq = be32(t + 4), ack = be32(t + 8);
    uint32_t window = (uint32_t)be16(t + 14) << 8;
    uint8_t flags = t[13];
    const uint8_t *data = t + 20;
    size_t payload = size - 20u;
    bridge_usbmux_channel *c = NULL;
    for (size_t i = 0; i < BRIDGE_USBMUX_CHANNELS; ++i) {
        bridge_usbmux_channel *candidate = &m->channels[i];
        if (candidate->state != BRIDGE_USBMUX_CH_FREE && candidate->state != BRIDGE_USBMUX_CH_CLOSED &&
            candidate->local_port == local && candidate->remote_port == remote) {
            c = candidate; break;
        }
    }
    if (!c) {
        if ((flags & TCP_RST) == 0u && !m->anonymous_reset_pending) {
            m->anonymous_reset_pending = true;
            m->anonymous_local = local; m->anonymous_remote = remote;
            m->anonymous_ack = seq;
        }
        return anonymous_reset(m);
    }
    if ((flags & TCP_RST) != 0u) {
        c->reason = (c->state == BRIDGE_USBMUX_CH_SYN_SENT || c->state == BRIDGE_USBMUX_CH_SYN_PENDING)
            ? BRIDGE_USBMUX_REASON_REFUSED : BRIDGE_USBMUX_REASON_RESET;
        c->state = BRIDGE_USBMUX_CH_CLOSED;
        c->ack_pending = false;
        return BRIDGE_OK;
    }
    if (c->state == BRIDGE_USBMUX_CH_CLOSING) return service_channel(m, c, now);
    if (c->state == BRIDGE_USBMUX_CH_SYN_SENT) {
        if (flags != (TCP_SYN | TCP_ACK) || ack != 1u || payload != 0u) {
            closing(c, BRIDGE_USBMUX_REASON_PROTOCOL, now);
        } else {
            c->tx_acked = ack; c->peer_window = window;
            c->peer_initial_seq = seq;
            c->rx_next = seq + 1u;
            c->rx_limit = c->rx_next;
            c->state = BRIDGE_USBMUX_CH_ACK_PENDING;
        }
        return service_channel(m, c, now);
    }
    if ((c->state == BRIDGE_USBMUX_CH_ACK_PENDING || c->state == BRIDGE_USBMUX_CH_OPEN) &&
        flags == (TCP_SYN | TCP_ACK) && seq == c->peer_initial_seq && ack == 1u && payload == 0u) {
        /* A queued SYNACK may arrive while tick finishes our deferred ACK. */
        c->ack_pending = true;
        return service_channel(m, c, now);
    }
    if (c->state != BRIDGE_USBMUX_CH_OPEN || flags != TCP_ACK || before(c->tx_next, ack) ||
        (!before(ack, c->tx_acked) && (uint32_t)(ack - c->tx_acked) > c->tx_next - c->tx_acked)) {
        closing(c, BRIDGE_USBMUX_REASON_PROTOCOL, now);
        return service_channel(m, c, now);
    }
    /* Reject future/out-of-order data rather than buffering an unbounded gap.
     * Fully duplicate or overlapping retransmissions are never delivered twice. */
    if (seq != c->rx_next) {
        if (!before(seq, c->rx_next)) {
            closing(c, BRIDGE_USBMUX_REASON_PROTOCOL, now);
            return service_channel(m, c, now);
        }
        uint32_t overlap = c->rx_next - seq;
        if ((size_t)overlap >= payload) payload = 0;
        else { data += overlap; payload -= overlap; }
    }
    if (!before(ack, c->tx_acked)) {
        if (ack != c->tx_acked) c->progress_since_ms = now;
        c->tx_acked = ack;
        c->peer_window = window;
    }
    if (payload > BRIDGE_USBMUX_RX_CAPACITY - c->rx_size ||
        payload > (size_t)(c->rx_limit - c->rx_next)) {
        closing(c, BRIDGE_USBMUX_REASON_OVERFLOW, now);
        return service_channel(m, c, now);
    }
    if (payload != 0u) {
        size_t tail = (c->rx_head + c->rx_size) % BRIDGE_USBMUX_RX_CAPACITY;
        size_t first = BRIDGE_USBMUX_RX_CAPACITY - tail;
        if (first > payload) first = payload;
        memcpy(c->rx + tail, data, first);
        if (payload > first) memcpy(c->rx, data + first, payload - first);
        c->rx_size += payload;
        c->rx_next += (uint32_t)payload;
    }
    /* ACK data (including duplicates) promptly; avoid an ACK-only ping-pong. */
    if (size != 20u) c->ack_pending = true;
    return service_channel(m, c, now);
}
static bridge_status input_frame(bridge_usbmux *m, size_t size, uint64_t now)
{
    uint32_t protocol = be32(m->frame);
    size_t h = header_size(m);
    if (size < h) return fail_link(m, BRIDGE_E_FORMAT, BRIDGE_USBMUX_REASON_PROTOCOL);
    if (m->version >= 2u) {
        if (be32(m->frame + 8) != MUX_MAGIC_IN)
            return fail_link(m, BRIDGE_E_FORMAT, BRIDGE_USBMUX_REASON_PROTOCOL);
        /* This is intentionally the incoming rx_seq field, matching device.c.
         * Upstream does not impose monotonicity on the incoming tx_seq field. */
        m->rx_seq = be16(m->frame + 14);
    }
    if (protocol == MUX_VERSION) {
        if (m->state != BRIDGE_USBMUX_WAIT_VERSION || size < 20u)
            return fail_link(m, BRIDGE_E_FORMAT, BRIDGE_USBMUX_REASON_PROTOCOL);
        /* Reserved padding and optional trailing bytes are ignored exactly as
         * device.c does; known fields are still covered by the minimum length. */
        uint32_t version = be32(m->frame + 8);
        if (version != 1u && version != 2u)
            return fail_link(m, BRIDGE_E_UNSUPPORTED, BRIDGE_USBMUX_REASON_PROTOCOL);
        m->version = version; m->minor = be32(m->frame + 12);
        if (version == 2u) {
            m->tx_seq = 0; m->rx_seq = UINT16_MAX;
            m->state = BRIDGE_USBMUX_SETUP_PENDING;
        } else m->state = BRIDGE_USBMUX_READY;
        return bridge_usbmux_tick(m, now);
    }
    if (m->state != BRIDGE_USBMUX_READY)
        return fail_link(m, BRIDGE_E_FORMAT, BRIDGE_USBMUX_REASON_PROTOCOL);
    if (protocol == MUX_CONTROL) return BRIDGE_OK; /* Diagnostic bytes, no string assumptions. */
    if (protocol == MUX_TCP) return input_tcp(m, m->frame + h, size - h, now);
    return fail_link(m, BRIDGE_E_UNSUPPORTED, BRIDGE_USBMUX_REASON_PROTOCOL);
}
bridge_status bridge_usbmux_feed(bridge_usbmux *m, const uint8_t *data, size_t size, uint64_t now)
{
    if (!m || !m->send || (!data && size != 0u)) return BRIDGE_E_ARGUMENT;
    if (m->state == BRIDGE_USBMUX_DEAD) return m->error;
    if (m->state == BRIDGE_USBMUX_IDLE) return BRIDGE_E_UNSUPPORTED;
    bridge_status tick_result = bridge_usbmux_tick(m, now);
    if (tick_result != BRIDGE_OK) return tick_result;
    while (size != 0u) {
        if (m->frame_used == 0u) m->frame_since_ms = now;
        size_t target = m->frame_expected != 0u ? m->frame_expected : 8u;
        size_t take = target - m->frame_used;
        if (take > size) take = size;
        memcpy(m->frame + m->frame_used, data, take);
        m->frame_used += take; data += take; size -= take;
        if (m->frame_expected == 0u && m->frame_used == 8u) {
            uint32_t expected = be32(m->frame + 4);
            if (expected < header_size(m))
                return fail_link(m, BRIDGE_E_FORMAT, BRIDGE_USBMUX_REASON_PROTOCOL);
            if (expected > BRIDGE_USBMUX_MAX_FRAME)
                return fail_link(m, BRIDGE_E_LIMIT, BRIDGE_USBMUX_REASON_OVERFLOW);
            m->frame_expected = (size_t)expected;
        }
        if (m->frame_expected != 0u && m->frame_used == m->frame_expected) {
            size_t complete = m->frame_expected;
            m->frame_used = 0; m->frame_expected = 0;
            bridge_status result = input_frame(m, complete, now);
            if (result != BRIDGE_OK) return result;
        }
    }
    return BRIDGE_OK;
}
