# iOS Agent tools

The normal Agent registers screenshot, tap, drag, home, list_apps, launch_app,
type_text and wait. The demo keeps its synthetic screenshot/tap/drag/wait/finish
set. The retained legacy bridge reports unsupported capabilities through tools;
normal conversation has no device-connection preflight requirement. App startup
attempts to restore an existing paired connection without requiring the Settings
page. Device tools share connection preparation and wait up to 20 seconds while
verification/reconnection is pending; unpaired devices still need system pairing.
Explicit cancellation interrupts the wait. A new connection generation clears
old images/action grants, but fresh reads and newly authorized system actions can
bind to it without restarting the Agent run. Failed dispatched input is never
retried by connection preparation. Scene backgrounding does not close transport;
returning to foreground schedules a liveness check when maintenance is idle.

Home, launch and typing use an independent single-use action authorization,
approval digest, authenticated session generation and per-run operation ownership.
They do not require a screenshot. Tap/drag additionally require current screenshot
coordinates and consume a single-use approval before dispatch, retaining the coordinate
reference for subsequent newly authorized actions. Successful actions and waits do
not force another capture. An uncertain action is journaled as outcomeUnknown;
reconnects, process recovery and fresh images never replay it. App queries are
read-only and expose only name, bundle identifier and version. New DDIs use
advertised streamapplist rather than the non-responsive older listapps endpoint.

The C ABI adds actions 7 Home / 8 list / 9 launch / 10 text. The command API copies
bounded JSON synchronously; pending input bytes are zeroized on drop. Swift and
Rust both validate text and launch argument bounds. Errors expose numeric local
categories rather than remote payloads. Home and keyboard HID use the existing
owned DisplayService session. All text now uses the general pasteboard and Command-V, replacing clipboard
contents. The direct ASCII route and virtual keyboard registration were removed
after the user observed the software keyboard disappearing and text remaining
in the active IME candidate area. Whole input is validated before I/O: at most
8192 UTF-8 bytes, nonempty and without NUL. No old clipboard is read and no extra
Return, retry or partial prefix is sent. Paste may require iOS consent; pending
consent must not cause text to be resent. Previously registered remote virtual
keyboards are not blindly removed by guessed service ID; closing the old session
and checking software-keyboard restoration still requires device verification.
Observations are chosen according to the task, rather than required after every
action. Tool receipts describe the operation without prescribing another capture. Tool failures, including uncertain input delivery, return to the
Agent loop without pausing the run or disabling all later inputs. The failed
call remains outcomeUnknown in the durable journal, its image is consumed, and
no transport resend occurs. The Agent chooses its next step from available evidence; uncertain actions are
never blindly repeated. Lost connection generations are tool errors;
explicit run cancellation still stops execution. Process recovery never resumes
an old dispatch.

Screenshot service connection, response and PNG validation failures are scoped to
that read-only request. Swift retains the authenticated native handle and App
session generation, reports the stage/cause, and clears the previous frame's
input authorization. A later screenshot is a new explicit tool call; no capture
or input is automatically resent. This does not prove a failed tunnel is healthy:
worker closure, cancellation, malformed ABI events and failed connection
maintenance still revoke it. When disconnected, tools retain the recorded cause
instead of replacing it with a generic Settings instruction.

launch_app accepts up to 32 process arguments. It does not kill an already running
app, and such an app may ignore new arguments. Arguments are not URL parameters;
the target must implement their meaning. The protocol does not by itself provide
checkpoint restoration or background permission.

## Built-in skill

PhoneAgent/BuiltinSkills/ios-operation/SKILL.md is shipped as an immutable bundle
resource. Its stable ID and content revision participate in the existing skill
catalog and paginated load_skill path, without entering user-imported archives.
Only metadata is attached initially. The system prompt retains authority and
safety rules and requests the relevant skill before UI operations. Tool schemas
continue to describe parameters and results. Skill text cannot expand permission.

## Video-backed NCM screenshots

Normal NCM screenshot calls prepare/reuse DisplayService media. A continuous
worker drains ordered HEVC sync and reference pictures and decodes them through
VideoToolbox. Screenshot calls wait internally for a fresh decoded frame, then
encode JPEG at quality 0.85; no extra Agent wait step or prior-input condition is
required. Missing frames trigger bounded RTCP refresh requests. Decode errors
remain screenshot-scoped. There is no automatic PNG fallback; the original
capturePNG API and legacy capture routes remain intact.

The receiver does not assume that the UDP source port equals the configured
50001 feedback destination. Authenticated-tunnel delivery and negotiated RTP
payload type/SSRC still bind admission. Receiver feedback now uses the vendored
DisplayService builders: per-complete-frame ACK, 50ms RCTL, compound RR+SDES
liveness, and RR+SDES+PLI+FIR refresh with an incrementing FIR sequence. Numeric
counters distinguish absent datagrams, rejected RTP, incomplete access units,
oversized pictures, and stale images at timeout; no image bytes are logged.

The side-channel C ABI requires SCREEN permission, is scoped to one native handle,
and never consumes command receipts. Its queue holds at most 64 pictures/eight
MiB, preserving reference order. A new sync picture replaces the pending chain;
overflow or discontinuity invalidates it and requests a new sync picture.
Parameter changes rebuild the decoder; closed generations cannot deliver images
into a later connection. Valid stream contents-rectangle metadata takes precedence
over the same peer's DeviceInfoService dimensions. Cropping does not scale pixels.
See VIDEO-GEOMETRY.md for parsing, real-device evidence and the remaining encoded
dark column. MIME metadata and attachment names match JPEG bytes. ESP32 remains a
byte relay; video traffic continues while media is open, with no firmware update.

The final registered control task releases this App's owned video/HID streams,
decoder and queued frames through action 11 while retaining authentication. Runs
waiting for the same connection prevent premature cleanup, and a new operation
queues behind in-flight cleanup before reopening media. Termination notification
closes owned native handles synchronously; scene backgrounding does not.
Cleanup does not send global stopAll. Abrupt process termination may not deliver
the termination notification. Immediate remote indicator removal remains unverified.

Local validation covers HEVC decoding, JPEG creation, bounded reference queues and
geometry parsing. After real-device testing was authorized again, three consecutive
ESP32-backed screenshots returned 1179x2556 with independently parsed video
contents metadata. See VIDEO-GEOMETRY.md for the precise validation boundary.

## Independent ESP32 recovery: not implemented

The present firmware is an NCM relay. RemotePairing identity, Pair Verify,
TLS tunnel, RSD and CoreDevice calls are owned by the iPhone process. The default
firmware has CONFIG_TINYUSB_HID_COUNT=0. No independent launcher exists on ESP32;
queuing a launch request for the stopped iPhone to execute would not implement
external recovery, and replaying captured TLS bytes would be invalid and unsafe.

A complete external recovery feature needs an ESP32-owned authenticated controller
and bounded launch job, plus durable App continuation semantics. Its design must:

- Transfer a scoped controller identity explicitly to the trusted USB device;
  retain only volatile controller secrets unless a protected persistence design is
  separately implemented. Retire secrets and jobs on USB epoch change.
- Arm one expiring, run-bound foreground/relaunch job before losing execution;
  acknowledge arming from ESP32. Do not rely exclusively on an expiry callback,
  which may never run for abrupt process termination.
- Cancel armed jobs on manual stop, lock, revoked permission, task completion and
  generation change. Use one launch attempt per job; never loop-launch the App.
- Persist checkpoints before tool dispatch. Relaunch only eligible paused runs;
  never dispatch a previous action with an unknown result. Bind continuation to
  an unguessable nonce, run identity and generation, independent of model text.
- Revalidate device, connection and actual execution grant before continuing.

Current launch_app can bring an app forward while the controlling iPhone process
is alive. It does not demonstrate autonomous recovery after that process stops.

## Historical real-device acceptance, 2026-10-07

ESP32 firmware was unchanged. App-owned Rust → authenticated ESP32 relay → iPhone
CoreDevice returned 226 visible apps, including com.apple.mobilenotes. Home's
actual effect was verified in a desktop screenshot; launching Notes was verified
in its folder view. A new blank note was created via the existing touch tool.
The earlier clipboard implementation (now restored for all text) inserted
Unicode `你好 ESP32 🌟`, which was visually confirmed. iOS initially showed
Notes' one-time paste request from dtpasteboardd; accepting that requested paste
completed insertion without resending text. The test ran with PhoneAgent in the
background and actual AVKit PiP start receipts. Metadata-only logs and screenshots
are under .build/notes-tools-*. The DEBUG --ncm-tools-probe fixture is bounded to
10 minutes and accepts only new monotonic test commands, never arbitrary text or
paths. It is absent from Release builds. This validates the device bridge, not a
live-provider model's end-to-end tool selection or independent ESP32 recovery.
The restored paste-only implementation has local tests/build validation
only. That replacement was made while hardware testing was prohibited; later geometry
testing does not validate text entry. The earlier Unicode/paste result does not
validate the replacement.

## Connection and independent-action regression validation

App startup calls restoreConnection independently of Settings and without changing
scene visibility. Returning foreground can wake an idle heartbeat, but must not
cancel an in-flight native request (cancellation closes its transport). Tool
connection waits share verification and honor manual service/run stop. Rebinding
for reads clears coordinate images, task input grants and system action tokens.
Application queries acknowledge metadata receipt, not visual observation.

Validation: 301 default App core tests passed
(.build/validation/core.E4Wgdp/test.log); the final 39 NCM bridge tests, including
startup visibility and manual connection-wait stop, passed
(.build/connection-final-ncm-tests.log). Signed iPhoneOS build succeeded
(.build/connection-tools-build.log). Real-device installation and repeated
foreground/background screenshot acceptance remain pending.


## Consecutive operations and operation-only receipts

Action/wait results no longer prescribe screenshot calls. The bundled iOS skill
and system prompt allow known action sequences using the latest coordinate
reference. NCM retains that reference after successful input, but consumes each
single-use dispatch approval; a new action still needs its own authorization.
An in-flight fence rejects concurrent input. Stop, reconnect and uncertain input
retain their invalidation/no-replay behavior.

Validation: 305 default App core tests passed
(.build/validation/core.0qJEXE/test.log). After removing the remaining screenshot
guidance from shared error text, 62 safety, NCM bridge and batch tests passed
(.build/action-receipts-focused.log). Final unsigned iPhoneOS build succeeded
(.build/action-receipts-build-final.log). No real-device installation or test was
performed for this change.
