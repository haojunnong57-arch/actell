/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_NETWORK_H
#define BRIDGE_NETWORK_H
#include "bridge_lwip.h"
#include "bridge_rsd.h"
/* Caller-owned ZERO-INITIALIZED session storage. Keep it alive through successful close, including
 * deferred core-thread cleanup. A failed start may still own a net pointer;
 * start rejects reuse until close has successfully released that pointer.
 * esp_netif_init() must have initialized lwIP once before start. All calls stay
 * on the USB owner task. No credentials, ambient UUIDs, routes, or app listener.
 */
typedef struct {
    bridge_lwip_net *net;
    bridge_rsd rsd;
    bridge_lwip_tcp streams[BRIDGE_LWIP_TCP_SLOTS];
    uint8_t server_address[16];
    bridge_status failure;
    bool ready, stopping;
} bridge_network;
bridge_status bridge_network_start(bridge_network *, const bridge_packet_link *,
    const uint8_t handshake_uuid[16], uint8_t *peer_scratch, size_t peer_capacity,
    uint64_t deadline_ms);
/* Pumps one bounded lwIP iteration and available RSD control input. Does not
 * read the idle control stream just to poll it. Service replies are consumed by
 * their own RemoteXPC clients; this does not steal their bytes. */
bridge_status bridge_network_poll(bridge_network *, uint64_t deadline_ms);
/* Compatible with bridge_operation_wait_fn for the Home hold interval. Pumps
 * lwIP only while a button can be down; parsing partial RSD control frames here
 * could delay UP until an unrelated control-message deadline. */
bridge_status bridge_network_wait(void *, uint32_t milliseconds, uint64_t deadline_ms);
/* Marks network stopped, detaches RSD streams, schedules core cleanup, and tries
 * to reap. TIMEOUT/LIMIT means retain the context and retry close; no borrowed
 * link, USB, TLS or clock callback is used after the first shutdown. A pending
 * cleanup does NOT require the borrowed link/context to stay alive. */
bridge_status bridge_network_close(bridge_network *);
#endif
