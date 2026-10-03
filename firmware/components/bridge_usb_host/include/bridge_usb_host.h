/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_USB_HOST_H
#define BRIDGE_USB_HOST_H
#include "bridge_core.h"
#include "bridge_usbmux.h"
#include "esp_err.h"
typedef struct bridge_usb_host bridge_usb_host;
typedef bridge_status (*bridge_usb_session_fn)(bridge_usb_host *, void *);
typedef struct {
    bool wiring_and_vbus_confirmed;
    bool enable_controller_requested;
    uint8_t configuration_value; /* observed bConfigurationValue, not interface index */
    uint32_t runtime_ms; /* active phase deadline, 1000..600000 ms; cleanup waits are separate */
    bridge_usb_session_fn session;
    void *session_context;
} bridge_usb_host_config;
typedef struct {
    bridge_status status;
    esp_err_t driver_error;
    bool enumerated, interface_claimed, mux_ready, session_completed;
    bool cleanup_complete; /* this attempt: also true when no resources were acquired */
    uint64_t rx_bytes, tx_bytes;
} bridge_usb_host_result;
typedef struct {
    bridge_usb_host *host;
    bridge_usbmux_channel_id channel;
    uint64_t generation; /* rejects a stale stream after host storage reuse */
    bridge_io io;
} bridge_usb_stream;
/* Blocking owner-task run. Pumps both ESP-IDF host-library and client events;
 * callbacks never block. At most one run can own the host library.
 * Session runs on this task after the real mux handshake, never before.
 * It must cooperate through the provided bounded I/O and avoid unrelated
 * blocking; runtime checks cannot preempt arbitrary user callback code.
 * Default firmware does NOT call this: board/VBUS configuration must be explicit.
 * No GPIO/power-switch/vendor-mode assumptions; controller activation does not
 * provide physical 5 V VBUS, and does not solve USB-C power/CC wiring.
 * Never call from an ESP-IDF USB callback or another task.
 */
bridge_status bridge_usb_host_run(const bridge_usb_host_config *, bridge_usb_host_result *);
/* Valid ONLY during the session callback. Deadline is absolute monotonic ms;
 * earlier of per-operation and run deadline wins. Distinct mux channels may be
 * held simultaneously but all accesses stay serialized on the owner task. */
uint64_t bridge_usb_host_now_ms(void);
bridge_status bridge_usb_stream_open(bridge_usb_host *, uint16_t remote_port,
    uint64_t deadline_ms, bridge_usb_stream *);
bridge_status bridge_usb_stream_close(bridge_usb_stream *, uint64_t deadline_ms);
/* Owner-task, nonblocking terminal teardown. Queues RST if possible and
 * invalidates this stream immediately; no USB event pump or deadline wait.
 * A queue-blocked channel remains owned by the host until normal run cleanup.
 * Use only when ending the enclosing session, not for unlimited reconnects.
 * Zeroed streams are already aborted. Stale/foreign streams are rejected.
 */
bridge_status bridge_usb_stream_abort(bridge_usb_stream *);
/* Single owner-task event/timer iteration, for a higher-level bounded network
 * scheduler. Never call from callbacks, another task, or after session return.
 * The earlier of this deadline and the host run deadline is enforced. */
bridge_status bridge_usb_host_poll(bridge_usb_host *, uint64_t deadline_ms);
/* Nonblocking buffered-byte observation; no event pump and no read. OK/0 means
 * an open channel currently has no bytes. Buffered bytes precede terminal EOF.
 * This is not a packet-length guarantee: a begun record/packet can still need
 * additional I/O under its own absolute deadline. */
bridge_status bridge_usb_stream_read_available(bridge_usb_stream *, size_t *bytes);
#endif
