These five unmodified Python source files are test oracles only, not firmware
and not a vendored installation of pymobiledevice3. They originate from:
https://github.com/doronz88/pymobiledevice3/tree/cd895d17ce8a97d883c10f87b26c7356d5e0ccb1

- remote_service_discovery.py: pymobiledevice3/remote/remote_service_discovery.py (only selected source methods)
- remotexpc.py: pymobiledevice3/remote/remotexpc.py (handshake methods selected by AST)
- xpc_message.py: pymobiledevice3/remote/xpc_message.py
- hid_service.py: pymobiledevice3/remote/core_device/hid_service.py
- media_stream_offer.py: pymobiledevice3/remote/core_device/media_stream_offer.py

Upstream license: GPL-3.0-or-later; full text is ../../LICENSE. Authors and
maintainers include doronz88 and matan (see upstream pyproject.toml).
manifest.json pins byte hashes; tests verify hashes before executing the pure
serialization code. The HID test extracts only pure builder functions by AST.
No actual transport, remote service, pairing, or phone-control function executes.
