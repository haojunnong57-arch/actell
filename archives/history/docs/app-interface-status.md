# App ↔ ESP32 interface status

The separately developed iOS App has a source-side integration candidate named
`docs/BRIDGE_PROTOCOL_V1.md` in its own artifact. Reviewed candidate SHA-256:
`f4e49ca48751a1e20e9ed69e8e06b8ba3fbc74f8d24dbfb9cd89329f238ed6df`.
This firmware v0.3 does **not** implement that App channel, does not listen or
connect on its application port, and cannot truthfully send its ready handshake.

Agreed future profile: App NWListener TCP28765; ESP32 USB host dials it through
usbmux; TLS1.2 PSK AES128GCM profile is distinct from lockdown certificate TLS.
PSK provisioning is not present here. No bearer token/plaintext downgrade or
reuse of a lockdown private key as an App secret is implied.

Frames use four-byte big-endian length and at most64KiB JSON. Envelopes carry
version1, session_id, request_id, type and payload. PNG delivery is transactional:
16KiB raw chunks, at most15MiB image, sequence/offset/hash checks, final result
before commitment. Inputs use normalized0..65535 coordinates bound to an image ID.
One action is in flight; a lost input result is not automatically replayed.
The App subset exposes screenshot/tap/drag; wait/finish are local and Home is not
in that App version. Only actually available backend capabilities may be announced.

The same-phone foreground/background limitation remains unresolved: the current
App source stops its run/listener when it leaves foreground. An action opening
another App can therefore terminate the controlling run. Neither this contract
nor the firmware library proves continuous cross-App automation is possible.

The App document lists mandatory Xcode, authentication, usbmux, image, input and
lifecycle acceptance tests. Agreement on message fields is not implementation or
hardware interoperability evidence.
