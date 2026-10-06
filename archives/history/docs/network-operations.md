# Layer composition and operations

`bridge_coredevice_usb_run` is called only from an already-authorized USB Host
owner session. It binds actual raw mux streams, QueryType, lockdown, pinned TLS,
CoreDeviceProxy and CDTunnel. Its consumer receives a borrowed `bridge_packet_link`.
No identity loader or default controller activation is provided.

`bridge_network_start` adapts that packet link to actual lwIP, then performs RSD
through real TCP streams. Initialize ESP-IDF's lwIP runtime once with
`esp_netif_init()` before starting a network session. Supply a ZERO-initialized
`bridge_network`, caller-selected handshake UUID, and up to 64 KiB PSRAM scratch.
A live or pending-cleanup context cannot be restarted; successful close is required.

The network's RSD dialer permits only its negotiated peer address. It maintains
four generation-tagged TCP handles; RSD control consumes one. A service close
has a separate bounded 100 ms transport cleanup allowance. Cleanup failure stops
the entire net rather than concealing uncertain ownership. Transaction deadlines
bound wire operations; this bounded cleanup can extend the function's return time.

## Screenshot

Call `bridge_capture_screenshot(&network.rsd, ...)` with fresh invocation UUIDs,
caller scratch (at least 2048 bytes), an image-wrapper limit at most 16 MiB and a
bounded sink. The helper opens the discovered screenshot service, initializes
RemoteXPC, sends the actual CoreDevice request and selects its correlated payload
on stream 1 or 3. Sink bytes remain provisional until the entire operation returns
OK. A wrong ID, malformed trailing object, reset, timeout or sink failure invalidates
all bytes. PNG signature/IHDR and container bounds are checked; full PNG CRC/decode
is the consumer's responsibility. No framebuffer or whole-image allocation occurs.

## Home

`bridge_press_home` requires a real dialer ACK-drain implementation before any
input. It sends DOWN, waits for peer TCP ACK, holds at least 50 ms using the caller
scheduler, sends UP, and drains it before closing. `bridge_network_wait` is the
compatible hold callback; it services lwIP only during the hold, not potentially
partial RSD application frames. `down_written`, `down_peer_acked`, `up_written`
and `bytes_peer_acked` are separate evidence. None proves a UIKit visual effect.

A link failure or expired deadline can prevent release. The flags report that
uncertainty; there is no automatic replay, success-on-EOF, or unbounded recovery.
A wait callback failing early still triggers a release attempt when transport and
deadline permit. Subsequent workflow should obtain a fresh screenshot, not infer
state from a write result. No keyboard text helper or other hardware button is exposed.

## Teardown

Close service objects before their RSD/network parent. `bridge_network_close`
marks stopping, detaches RSD, requests core-thread cleanup and tries to reap.
TIMEOUT/LIMIT means retain the caller context and retry close. After first stop,
cleanup retries do not call borrowed USB/TLS/clock callbacks; the enclosing USB
session may therefore release its transport while the independent net cleanup
remains pending. Never free a pending context or abandon its retained net pointer.
The default firmware does not exercise this path on hardware.

`bridge_network_poll` services the network and only parses RSD control when TCP
bytes are actually available. Individual operations consume their own service
RemoteXPC replies; the scheduler does not steal those bytes.

## Touch/media boundary

The packet/report and offer builders are implemented, including bounded real
zlib9. A UDP receiver is available in the lwIP layer. Automatic touch-session
orchestration is deliberately absent pending verified ownership of a media stream
token and safe cleanup. Pinned pymobiledevice3 `touch_session` invokes stopAll on a
fresh display connection; pinned idevice `display_stream/client.rs` also uses
stopAll. Neither provides a checked rule to extract the token needed by this
project's own-stream-only stop builder. The offer's random session_id is not assumed
to be that token. No global stop is silently substituted.

## Validation boundaries

- `test_coredevice_usb.sh`: actual plist/session/CDTunnel composition; controlled
  USB/TLS API fakes isolate binding ownership. Real TLS and raw mux have separate tests
- `test_network.sh`: actual network binding; controlled lwIP/RSD API fakes isolate
  mapping, partial failures and deferred cleanup. Real lwIP/RSD have separate suites
- `test_operations.sh`: actual operation, HTTP2/XPC, request and PNG code; controlled
  RSD and ACK boundary. Tests include both reply streams, errors and release paths

These tests do not combine every layer into one physical or fully virtual iPhone.
Their passing results must not be presented as real screenshot/Home success.
