# Synthetic USB Host adapter checks

Run `./tools/test_usb_host_sim.sh` from the project root.

These tests compile the actual `bridge_usb_host.c` adapter against a deliberately
minimal, deterministic **synthetic ESP-IDF API peer**. They do not link ESP-IDF,
operate a USB controller, or contact a real Apple device. The real ESP-IDF 5.5.5
firmware builds separately check the actual API declarations/toolchain.

## Test binaries

- `test_lifecycle.c` isolates adapter behavior with an explicitly synthetic mux
  API peer: configuration/board gates, normal no-device cleanup/retry, installation
  failures, delayed attach clock sampling, every partial allocation and initial
  submit failure, callback error/short transfer/disconnect status, queue copying,
  full-queue backpressure, reuse after completion, OUT `ZERO_PACK` flags,
  owner-task/reentrant-run and stale-generation rejection, expired close,
  session deadline overrun, and refusal to free undrained in-flight buffers.
- `test_protocol_integration.c` replaces that mux peer with the **actual raw mux,
  plist I/O, bplist parser, and QueryType probe**. Only IDF/USB and the device peer
  remain synthetic. It checks VERSION/SETUP, port 62078 SYN/SYNACK/ACK, the actual
  read-only QueryType request and framed reply, stream close, and error handling
  for the wrong service Type, wrong inbound mux magic, reset, and silence. USB
  completion sizes of 1, 7, 64, and 4096 bytes exercise fragmented and coalesced
  mux/plist framing. Device-to-host v2 headers use `FACEFACE`; host-to-device
  headers must use `FEEDFACE`.

The common peer's lifecycle behavior follows the relevant upstream 5.5.5 source:

- `components/usb/usb_host.c`: last-client deregistration queues `NO_CLIENTS`;
  uninstall rejects pending library flags; callbacks run inside client handling;
  the transfer is no longer in-flight before callback invocation
- `components/usb/enum.c`: an out-of-range selected configuration otherwise falls
  back to configuration 1; the adapter must reject it before that fallback
- `components/usb/hcd_dwc.c`: `USB_TRANSFER_FLAG_ZERO_PACK` asks the controller for
  a terminal short packet/ZLP when the complete bulk OUT length is MPS-aligned

The fake headers model only the subset exercised, not the complete real ABI.
The tests assert adapter flags, not physical USB packet timing. They cannot prove
real DMA/controller correctness, Apple firmware compatibility, iPhone
reachability, pairing/trust, TLS, screenshots, touch injection, VBUS safety, or
USB-C role/CC wiring.

Both binaries use ASan and UBSan, strict conversion/shadow warnings, and explicit
allocation/in-flight ownership counters. LeakSanitizer is disabled because it is
unsupported in the managed execution environment. All normal cases assert zero
live allocations/transfers. The undrainable-cleanup case deliberately retains
storage and rejects a second run; test-only internal recovery then drains/frees
it to assert ownership safely. That recovery is not a supported production API.
