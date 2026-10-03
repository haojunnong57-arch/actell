# PhoneAgent bridge protocol v1 (integration candidate)

Status: implemented on the iOS **source** side; neither iOS compilation nor TLS/usbmux/hardware interoperability has been run. ESP32 bridge firmware v0.3 does **not** implement this application channel. Agreement on this document is not evidence of a working device-control loop.

## Transport and trust

- iOS App owns `NWListener`, TCP port **28765**, foreground only. The future ESP32 USB host opens an Apple usbmux connection to this device port. No Mac is required by this proposed runtime route, but that route has not been validated on a device.
- The transport profile is `tls12-psk-aes128gcm-v1`: TLS 1.2 only, `TLS_PSK_WITH_AES_128_GCM_SHA256` (0x00A8), 32 cryptographically random PSK bytes, identity UTF-8 `PhoneAgent-Bridge-v1`. TLS tickets are disabled. Both peers must be provisioned with the same PSK over a trusted out-of-band channel. Never use a short PIN, Apple lockdown certificates, pair records, or an API key as this PSK.
- iOS stores the PSK as ThisDeviceOnly/WhenUnlocked Keychain data. It is not sent in application messages. There is no plaintext downgrade and no certificate-validation bypass. The listener is not advertised over Bonjour; it may nevertheless be reachable on local interfaces. Authentication is mandatory regardless of whether the path is usbmux or LAN.
- Apple documents TLS-PSK with legacy Network.framework and TLS 1.2, not TLS 1.3. This profile follows the public PSK API and cipher used in Apple's TicTacToe sample; SDK behavior and ESP32 interoperability remain acceptance items. Reference: https://developer.apple.com/documentation/Network/building-a-custom-peer-to-peer-protocol and https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework

## Framing and envelope

Each frame is a 4-byte unsigned **big-endian** length followed by that many UTF-8 JSON bytes. Length is 1..65,536 inclusive. This limit applies to JSON body bytes only, not the 4-byte prefix. Receivers must handle arbitrary TCP fragmentation/coalescing and reject oversized lengths before allocation.

Every frame is `{ "version": 1, "session_id": "uuid", "request_id": "uuid", "type": "...", "payload": {} }`.

The app generates a new unpredictable UUID `session_id` for each authenticated connection, a unique `request_id` per handshake/request, and never resumes a prior session. Every response must match the request and session exactly. Wrong IDs, versions, message ordering, malformed JSON, unknown types and timeouts fail closed and disconnect. There is one peer and one tool operation in flight.

After TLS readiness, App sends `hello`, payload:

`{"profile":"tls12-psk-aes128gcm-v1","max_frame_bytes":65536,"max_image_bytes":15728640,"max_chunk_bytes":16384}`

ESP32 replies `hello_ack` with the same IDs, payload:

`{"profile":"tls12-psk-aes128gcm-v1","backend_ready":true,"capabilities":["screenshot","tap","drag"],"limits":{"max_frame_bytes":65536,"max_image_bytes":15728640,"max_chunk_bytes":16384}}`

`max_image_bytes` may be negotiated downward (positive, at most 15 MiB). Frame and chunk sizes must exactly match the v1 profile. Only announce implemented tools. App requires `screenshot`; unsupported tap/drag is rejected. `backend_ready: true` means the peer asserts backend readiness; the UI does not treat it as hardware verification. Firmware v0.3 cannot send a successful ready handshake.

## Commands

Type `tool_request`, payload `{"name":"screenshot|tap|drag","arguments":{...}}`.

- screenshot: `{}`
- tap: `{"x":0,"y":65535,"based_on_image_id":"..."}`
- drag: `{"from_x":0,"from_y":0,"to_x":65535,"to_y":65535,"duration_ms":500,"based_on_image_id":"..."}`

Model tools use integer screenshot pixels. App validates bounds and maps **inclusive** endpoints to normalized 0..65535: `round(pixel / (dimension - 1) * 65535)`. Origin is top-left; x rightwards, y downwards. Width and height must both exceed 1. The image ID binds the action to a validated observation. Images expire after 45 seconds locally and are invalidated before an action send. The firmware must independently reject stale/reused IDs or coordinates outside its current display profile, and map orientation consistently. No silent rotation, scale inference, text entry or home button support exists in this app version.

Every command receives `tool_ack` payload `{"accepted":true}` exactly once, followed by its result. ACK means accepted for processing, not success. Tap/drag result is `tool_result` with `{"status":"ok"}` or `{"status":"error","code":"bounded_machine_code"}`. An OK input result means delivery to the input service, **not** observed screen effect. Error descriptions are not trusted/displayed verbatim.

The agent tool `wait` runs locally (1..3000ms); `finish` is local. Neither is sent to the firmware. The app does not silently send stopAll media calls.

## Transactional PNG response

After screenshot ACK:

1. `image_begin`: `{"image_id":"opaque-unique-id","mime_type":"image/png","max_bytes":15728640}`. ID is 1..128 characters; max_bytes is positive and at most negotiated image limit
2. `image_chunk`: `{"image_id":"...","sequence":0,"offset":0,"data_base64":"..."}`. Sequence starts at 0 and increments by 1; offset equals accumulated decoded bytes; decoded chunk is 1..16,384 bytes and base64 text at most 21,848 UTF-8 bytes
3. Repeat chunks in strict order; partial images are never displayed or sent to a model
4. `image_end`: `{"image_id":"...","total_bytes":12345,"sha256":"lowercase-64-hex","width":1179,"height":2556}`. App checks total bytes, SHA-256, PNG signature, actual ImageIO dimensions and decode. Dimensions are 2..8192 and pixel product <=24,000,000
5. `tool_result`: `{"status":"ok","image_id":"..."}` commits the verified image

End without result does not commit. Duplicate/out-of-order chunks, bad hash/dimensions, non-PNG data, limits, errors, disconnect or timeout discard the entire provisional image. Firmware may stream CoreDevice's PNG bytes without decoding or retaining the image. The app retains one latest image for UI and one latest image in agent history; it does not write screenshot data to persistent storage.

## Stop, timeouts and unknown outcomes

Connection startup and each I/O operation time out after 10 seconds; each tool operation has an absolute 30-second ceiling. The full run has a 5-minute foreground watchdog. Stop cancels model requests, agent loop, pending approval and bridge connection/listener, fences late UI callbacks and clears the current observation. No tap/drag is ever automatically retransmitted after timeout, disconnect or lost result. A sent action may already have happened: its outcome remains unknown until a new, user-initiated run obtains a fresh screenshot. Continuing the same task creates a fresh agent/session rather than restoring pending tool calls.

## Mandatory acceptance before claiming live control

1. Xcode resolve/build/tests of this source with its pinned packages
2. Correct/incorrect PSK tests and plaintext rejection on a real iPhone
3. Actual ESP32 usbmux connection to App listener, capability/error handshake
4. Fragmented stream, disconnect mid-image, corrupted chunk/hash and wrong-ID tests
5. One verified CoreDevice PNG, correct orientation and coordinate endpoints
6. One explicitly approved reversible input; a post-input screenshot establishes its effect
7. Stop during approval, model call, PNG transfer and input; no reconnect/replay
8. Same-phone foreground/background limitation tested. This version deliberately stops when the App leaves foreground, so it does **not** solve continuous cross-app automation on that same phone
