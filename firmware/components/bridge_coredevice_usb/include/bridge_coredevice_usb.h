/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_COREDEVICE_USB_H
#define BRIDGE_COREDEVICE_USB_H
#include "bridge_usb_host.h"
#include "bridge_tls.h"
#include "bridge_lockdown_session.h"
#include "bridge_cdtunnel.h"
#include "bridge_packet_link.h"

typedef bridge_status (*bridge_coredevice_tunnel_fn)(void *, bridge_packet_link *, uint64_t deadline_ms);
typedef struct {
    /* A separately authorized, already paired identity; never generated, loaded
     * from storage or logged by this component. All pointers borrowed for run. */
    const char *host_id, *system_buid;
    const bridge_tls_config *tls;
    uint64_t deadline_ms;
    bridge_coredevice_tunnel_fn consume;
    void *context;
} bridge_coredevice_usb_config;
typedef enum {
    BRIDGE_COREDEVICE_PHASE_ARGUMENT = 0, BRIDGE_COREDEVICE_PHASE_OPEN_LOCKDOWN,
    BRIDGE_COREDEVICE_PHASE_QUERY_TYPE, BRIDGE_COREDEVICE_PHASE_START_SESSION,
    BRIDGE_COREDEVICE_PHASE_START_SERVICE, BRIDGE_COREDEVICE_PHASE_CDTUNNEL,
    BRIDGE_COREDEVICE_PHASE_CONSUMER, BRIDGE_COREDEVICE_PHASE_STOP_SESSION,
    BRIDGE_COREDEVICE_PHASE_DONE
} bridge_coredevice_usb_phase;
typedef struct {
    bridge_status status;
    bridge_coredevice_usb_phase phase;
    bridge_lockdown_failure lockdown_failure;
    bridge_lockdown_peer_error peer_error;
    int tls_error;
    bool query_type_verified, session_authenticated, service_opened;
    bool tunnel_negotiated, consumer_completed, stop_session_confirmed;
    /* USB controller cleanup is separately reported by bridge_usb_host_run. */
} bridge_coredevice_usb_result;

/* Call only inside the USB Host session callback, on its owner task. Composes
 * actual USB mux streams -> QueryType -> StartSession -> pinned TLS -> fixed
 * CoreDeviceProxy StartService -> service TLS when requested -> CDTunnel.
 * Runs consume only after a complete validated tunnel handshake, then performs
 * StopSession. The tunnel/IO are borrowed and invalid after consume returns.
 * Every failure is terminal; TLS is destroyed before nonblocking mux abort.
 * Do not reconnect repeatedly in the same host run after failure.
 * This does not activate USB, provision trust/pairing, provide an IP/TCP stack,
 * discover RSD services, capture a screenshot, or send input by itself.
 * Missing identity fails before opening a mux stream. No plaintext fallback.
 * No credentials are built into the default application or test firmware.
 */
bridge_status bridge_coredevice_usb_run(bridge_usb_host *,
    const bridge_coredevice_usb_config *, bridge_coredevice_usb_result *);
#endif
