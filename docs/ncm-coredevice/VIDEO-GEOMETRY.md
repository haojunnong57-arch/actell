# Video frame geometry investigation

## Wire data and decoder objects

The relay carries authenticated DisplayService UDP datagrams containing RTP/HEVC.
Rust reassembles complete HEVC access units and commits their VPS/SPS/PPS. The C
handoff contains those parameter sets, the SPS-derived dimensions and a
length-prefixed access unit. Swift creates its own CMVideoFormatDescription and
CMSampleBuffer, then VideoToolbox produces CVPixelBuffer. CMSampleBuffer is not
received from the phone; locally manufactured attachments cannot restore metadata
that was discarded before this step.

SPS dimensions currently include conformance-window cropping. CoreMedia's clean
aperture, CoreVideo's clean/preferred aperture and display dimensions describe the
decoder's interpretation. They do not necessarily distinguish an application
screen embedded inside an aligned encoded canvas. No local UIScreen dimensions,
model lookup, fixed 1179x2556 crop, or pixel-color trimming is used.

## Observed DisplayService VCL suffix

The vendored HEVC fixture contains this captured suffix:

```
04 f0 0a c0  00 00 03 00 00  04 ec 0a b0  03
```

After the HEVC emulation-prevention byte in the middle, the dimension-like fields
are two BE16 pairs: 1264x2752 and 1260x2736. Their interpretation as canvas and
content dimensions is an inference from the captured upstream bytes, not an
Apple-published schema. The four zero bytes may contain additional geometry;
nonzero values and other terminal markers are not interpreted.

Previously the reassembler stripped exactly that literal suffix, thereby both
losing geometry and assuming it was identical on every device. It now preserves
it for the decoder-side consumer. NCMDisplayPicture accepts only the observed
14-byte profile on VCL NALs, requires the first pair to equal the current SPS
canvas, requires positive content dimensions within the canvas and less than
64 pixels of right/bottom padding, and rejects conflicting declarations across
slices. Only validated trailers are removed before VideoToolbox decode. Other
bytes remain untouched. Content geometry persists across subsequent P-frames
without a trailer, and is cleared when the stream generation/configuration resets.

A synthesized trailer for canvas 1184x2576 and content 1179x2556 is tested.
The 2026-10-07 real-device capture does **not** match that profile; this parser
is not evidence of a black-border fix for the current iPhone.
Geometry logs record parsed numeric dimensions and selected rectangle when they
change; they do not log packet contents, picture pixels or credentials.

## Repeated snapshots

The previous mailbox discarded every non-sync picture. Once the initial IDR was
older than the one-second freshness window, subsequent screenshots needed another
IDR even while valid P-frames were arriving. Input timestamps were also applied to
snapshot acceptance, and the generic timeout misleadingly mentioned an operation.

The mailbox now retains an ordered reference chain (64 frames / 8 MiB maximum).
A newer keyframe may replace pending older frames. Overflow/discontinuity discards
the entire reference chain and requests recovery rather than dropping arbitrary
P-frames. A single cancellable receiver decodes continuously off the main queue;
snapshots wait for its drain receipt and encode the latest complete picture as
JPEG. Input history is no longer part of acceptance or timeout wording. Stop,
close and last-owner cleanup cancel the receiver and release decoded pixels.

Local evidence covers a real synthetic green IDR followed by a blue P-frame after
1.1 seconds, crop metadata surviving the P-frame, repeated native-fixture snapshots
after the old freshness window, decoder reset, and stopping/reopening the stream.
On 2026-10-07, repeated three-shot probes on the actual App → ESP32 → iPhone
route succeeded with 1.2-second spacing. Every JPEG remained 1184x2576.
The continuity fix was verified for these foreground probes before the display-metadata crop change.

## Real-device geometry evidence (2026-10-07)

The explicit DEBUG launch flag `--ncm-video-geometry-probe` saves three JPEGs
and one original Annex-B sync access unit to the App Documents directory, then
releases its control owner. `NCM_VIDEO_GEOMETRY_PROBE=1` additionally enables
control-plane/RTP/RTCP diagnostics. These probes do not send input.

Local evidence: `.build/live-video-frame.hevc`, `.build/live-video-frame.jpg`,
`.build/live-hevc-headers.log`, `.build/live-geometry-metadata.log`,
`.build/live-geometry-padding.log`, `.build/live-geometry-displayinfo.log`.
These files contain device-local media/metadata and are not committed.

- VPS/SPS/PPS and one type-20 VCL were captured; no SEI NAL was present in
  that sync access unit.
- FFmpeg trace_headers reports SPS luma dimensions 1184x2576,
  conformance_window_flag=0, aspect_ratio_info_present_flag=0, and
  default_display_window_flag=0.
- CoreMedia presentation, CVPixelBuffer, clean aperture and selected JPEG
  rectangle all report 1184x2576; preferred clean aperture is absent.
- Negotiated streamConfig reports CustomWidth=1184 and CustomHeight=2560.
  These are not the effective screen bounds and must not be used as a crop.
- Sampled RTP extensions use profiles 0x9011 and 0x9001 with four bytes;
  sampled marker packets have padding=false. The old 14-byte candidate
  geometry suffix is absent.
- Sampled RTCP contains sender reports and SDES, with no identified display
  rectangle.
- getdisplayinfo on DisplayService explicitly returns action-not-implemented.
  DeviceInfoService is queried separately as a diagnostic comparison only.
  It returns primary displayId=1, nativeSize/currentMode.size/bounds/frame
  all 1179x2556, orientation portrait/rot0. It also exposes a wireless display
  mode of 1184x2560, matching streamConfig rather than the primary display.
  These results are recorded in `.build/live-geometry-deviceinfo.log`.
  The approved implementation now obtains the selected displayId=1 geometry
  from this service and carries it alongside each video sample.

These observations disprove the earlier assumption that this device necessarily
carries the upstream fixture trailer. They do not prove that no other packet or
control message can carry visible geometry. No hardcoded/model/UIScreen or
color-derived crop has been added.


## Display metadata crop implementation

With user approval, the media session now queries the peer's authenticated
DeviceInfoService `getdisplayinfo`, selecting exactly the same displayId used
by `startmediastream`. Only a unique, current, finite, integral, positive frame
with origin (0,0) is accepted. NativeSize/model/UIScreen are not used. The query
runs once at start, then on a separate cancellable task every second so service
latency cannot block RTP reception or frame acknowledgments. A two-second query
failure clears the metadata and closes that query channel; it is not reused
with an outstanding request. The next media session reconnects it.

Each queued access unit snapshots the geometry, provided both dimensions fit
within that frame's SPS and the right/bottom differences are under 64 pixels.
This rejects stale portrait geometry against a landscape frame. C sample flags
bit1 declares an optional pair of LE u32 dimensions after the 64-byte header;
legacy/synthetic samples without that bit retain their existing layout. Swift
validates the dimensions again and crops the decoded buffer from its top-left,
then encodes JPEG. No image rescaling, extra screenshot request, ESP32 image
storage, or agent-visible tool/schema changes are involved.

Tests cover display ID selection (including a different wireless display),
landscape dimensions, ambiguous/stale/fractional/zero geometry, per-frame
snapshot isolation, incompatible SPS dimensions, actual HEVC decode plus JPEG
cropping, and malformed C sample rejection.


## Crop validation on the real route

2026-10-07: signed App built and installed. The App → ESP32 → iPhone probe
returned three successive JPEGs at 1179x2556, spaced 1.2 seconds apart. Decoder
logs show SPS/buffer 1184x2576, display metadata 1179x2556 and CI rectangle
(0,20,1179,2556). The saved original JPEG independently reports 1179x2556.
Evidence: `.build/display-crop-device.log`, `.build/display-crop-device.jpg`.
The bottom padding is removed. A one-pixel dark column remains at x=1178;
independent FFmpeg decoding of the pre-change original HEVC capture also shows
that column (white through x=1177, dark at x=1178). This is encoded content;
no color-based trimming, synthetic edge reconstruction or resizing was added.

Validation: Rust 38 tests, Swift/C/Rust chain 33 tests, App core 291 tests,
signed iPhoneOS build, and git diff --check pass. Foreground portrait snapshots
were tested; rotation/background behavior was not reverified in this probe.


## Mac and Apple Device Hub comparison (2026-10-07)

Mac calls use the local pymobiledevice3 checkout through a cached uv environment
and Apple's native development tunnel, bypassing ESP32 completely. Captures are
local only. Tests do not inject touches or type text.

- Default Python negotiation, the App feature profile, audio-before-video, and
  explicit customVideoWidth/customVideoHeight from getdisplayinfo all produce
  HEVC 1184x2576. Explicit size requests are answered with streamConfig
  1184x2560. Every tested stream has a dark luma column at x=1178.
- Software decoding and FFmpeg's DeviceHub-style `-hwaccel auto` give the same
  edge. Thus ESP32, Swift VideoToolbox and JPEG encoding are not its origin.
- Apple Device Hub itself was opened and its logs inspected. AVCRemoteVideoClient
  reports ratio 1184x2576 and contentsRect (0,0,0.995777027027027,
  0.9922360248447205). DeviceKit calculates pixelSize 1179x2556 and applies
  this contentsRect. The live viewer then fits the image in its device window.
- Apple's screenshot button logs CaptureScreenshotActionDeclaration /
  com.apple.coredevice.feature.capturescreenshot. This is a separate service
  from the live display stream. A Mac call to that same screenshot service
  gives a 1179x2556 PNG whose x=1178 column is white in the corresponding
  white UI region, whereas the video column is dark. The production App does
  not switch to this screenshot service.
- The one-column loss is consistent with a 4:2:0 odd-width conversion boundary
  (native width 1179 versus 1178 even columns), but that exact internal cause
  has **not** been proven. No synthetic edge replication, extra one-pixel crop,
  or scaling is applied to disguise it.

Evidence: `.build/mac-direct-default.rtp/.hevc`, `.build/mac-rust-profile.*`,
`.build/mac-audio-rust-profile.*`, `.build/mac-requested-native.*`,
`.build/mac-direct-screenshot.png`, `.build/apple-devicehub-geometry.log`,
`.build/apple-devicehub-screenshot.log`.

## Missing SW:1 capability and actual stream rectangle

A single-variable Mac test added `SW:1;` to the App's HEVC capability string
while retaining its other features/LTRP settings. This causes the video to
carry the current display's contents rectangle. Without SW:1 the tested App
profile omits it. The App now advertises SW:1 and prefers valid video metadata
over the approved DeviceInfoService fallback. Existing fallback/reset behavior
is retained, and no screenshot/input tool schema changes are required.

The current captured footer is RBSP BE16 (x=0,y=0,w=1179,h=2556), followed
by flag 0x02. A previously observed flag-0x03 profile additionally prefixes
encoded width/height. The private layout remains reverse engineered. Unlike
the earlier fixed-14-byte assumption, HEVC emulation prevention spans the
coded-slice/footer boundary, so the EBSP footer length depends on preceding
slice bytes. The parser now unescapes the NAL payload, validates the supported
rectangle/profile against SPS, removes only validated metadata, then reescapes
the remaining slice. Unknown or invalid profiles remain untouched.

Tests cover both observed profiles, single-/double-zero slice suffixes crossing
the metadata boundary, original slice preservation and incompatible orientation.
The rightmost encoded dark column also remains with SW:1 enabled: obtaining
correct metadata does not recreate a source pixel missing from the video.


Final ESP32 validation with SW:1: `.build/sw-geometry-device.log` records both
DeviceInfoService size and independently parsed trailerContent 1179x2556. Three
successive snapshots at 1.2-second spacing produce JPEG 1179x2556. Evidence
image: `.build/sw-geometry-device.jpg`. The one encoded dark column remains;
the metadata/crop fix does not claim to repair missing source pixels. Signed
iPhoneOS build, Swift/C/Rust 34 tests and upstream display_stream 57 tests pass.

Final default backend 38 tests and App core 291 tests pass (`.build/sw-geometry-rust.log`, `.build/validation/core.Fo1662/test.log`).

## Background change audit (2026-10-07)

Earlier experiments reproduced VideoToolbox -12903, then replaced decoding with
libde265. That was not a valid necessity proof: feedback routing was still wrong
in the earlier decoder experiments, and CPU decoding did not fix the later
no-new-frame failure. The conclusions below supersede that interpretation.

### Controlled decoder comparisons

All live decoder comparisons retain the corrected dynamic feedback destination,
RCTL layout and ongoing RR. No stream restart, PNG fallback or old cached-image
success is used.

| Comparison | Observed result | Decision |
| --- | --- | --- |
| Original/default VT + software CI, actual ESP32 stream | Foreground JPEG succeeds; old session returns -12903 on background transition; new VT session is hardware accelerated and generates a 1179x2556 background JPEG; later RTP discontinuity/stall still occurs | CPU decoding is not required to recover this session failure |
| VT + software CI, fixed local synthetic HEVC frame, no ESP32/media transport | First background decode fails -12903; recreated hardware session decodes and encodes five consecutive background pictures | Proves transition invalidation independently of protocol/network; disproves a blanket background hardware-decoding prohibition on this target |
| VT + default CI, same offline fixture | Same transition/recreation result and five successful background JPEGs | No demonstrated need for forced software JPEG rendering |
| VT + default CI, actual full-resolution stream | Foreground and Home background JPEGs both 1179x2556; later no-new-frame timeout remains | Remove forced software rendering; it does not solve the stall |

Evidence: `.build/decoder-audit/vt-live-console.log`, `vt-offline-console.log`,
`vt-default-ci-offline-console.log`, `vt-default-ci-live-retry-console.log`.
The offline fixture and temporary experiment configurations were removed from
App source after the comparisons. Hardware selection was verified through
`UsingHardwareAcceleratedVideoDecoder`, rather than inferred from a requested
configuration flag. The OS's internal reason for transition invalidation remains
unknown; it is not necessary to infer that reason to retain the existing local
reset/new-keyframe recovery.

### Audit of retained and removed changes

| Change | Evidence / necessity boundary | Final handling |
| --- | --- | --- |
| libde265, C++ YUV copy, static archives, CMake scripts and link flags | Does not fix later stall; VT recreation works in background | Removed, including vendored source and added license/build requirements |
| Force Core Image software renderer | Default CI successfully produces the actual full-resolution background JPEG | Removed |
| Disable hardware decoder / RealTime / power-efficiency hints | Old experiments did not fix failure; software selection was not verified | Remain removed |
| Dynamic feedback port and SSRC roles | Authenticated `streamConfig.SourcePort` differs from requested 50001; sender SSRC agrees with negotiated media identity | Retained as a concrete routing correction, not claimed to resolve every stall |
| RCTL timestamp/packet-count wire fields | Matches independently captured layout in local pymobiledevice3 source; old fields described decoded frames and a different clock | Retained for protocol correctness; sufficiency for this failure is unproven |
| Receipt ACK on admitted RTP marker | Receipt must not depend on successful assembly of a damaged AU; decoder does not participate in pacing | Retained; sender-side effect during stall is still to be verified |
| RR/SDES continues during keyframe recovery, one source report block | Old code suppresses reports while recovering and emits no source statistics | Retained; actual timeout is 3600 seconds, so it does not establish a roughly 25-second timeout cause |
| Receipt counts versus highest sequence | Audit found new statistics skipped reordered packets and could skip a reordered marker ACK | Corrected; regression covers 10,12,11 reordering with zero reported loss |
| One PLI rather than original PLI+FIR | The simplification lacks independent necessity evidence and static refresh still fails | Reverted to the original request for comparison |
| Empty receive-queue / newer-output-serial requirement | Can reject a recent complete picture while a continuous stream remains busy | Removed; receive-poll/reset barrier and current-time age bound retained |
| Skipped predictive frame clearing decode failure | Returning without pixels previously erased the actual failure | `consume` returns whether pixels were produced; failure retained until genuine decode success |
| Per-call immediate refresh | No demonstrated need to request before the pump has a chance to deliver | Restored original 100ms initial grace period |
| Timeout counters and opt-in read-only probe | Separates receive, assembly, decode and freshness failure; does not change Agent tool schema | Retained as diagnostics; background/repeated modes are DEBUG opt-in |
| Cached old-image / PNG fallback / automatic media reconnection | Would mask an unresolved failure | None introduced |

Unrelated UI, conversation, Agent authorization and connection-lifetime changes
from earlier user requests are preserved; this audit does not revert them.

### Historical unresolved boundary before the sender-side investigation

With either CPU decoding or restored VT, live RTP sequence gaps can invalidate
the reference chain and later requests receive RTCP but no complete new picture.
Both routes reproduce failure; decoder replacement is not the causal repair.
The reason for assembler SequenceGap events (actual loss versus packets arriving
beyond its reorder window) and the sender's handling of refresh feedback still
need direct evidence. A sequence-gap event alone does not establish permanent
packet loss.

The authenticated configuration observed in `negotiated-retry-console.log`
reports `RTCPTimeoutEnabled=true`, `RTCPTimeoutInterval=3600`, bitrate 6000000,
framerate 60 and `IsltrpEnabled=true`. The previous inference of a roughly
25-second RTCP timeout is withdrawn. Suppressed reports are a protocol issue,
but this configuration does not support that timing explanation.

A one-variable LTRP-off experiment was accepted by the peer
(`IsltrpEnabled=false`) and still produced SequenceGap and no-new-frame timeout
with zero mailbox overflow. It was reverted. Evidence:
`.build/decoder-audit/ltrp-off-console.log`. Unsupported negotiation features,
transport capacity, PLI handling and sender throttling remain hypotheses until
separated by controlled evidence. IPv6 fragmentation has not been established.

A second experiment changed only the negotiated bitrate from 6000000 to 2000000.
The peer echoed the lower cap. Four captures (one foreground, three background)
succeeded, with discontinuities=0 and overflows=0, but the fifth request still
failed: sentPackets=receivedPackets=3047 remained constant through the timeout,
requiresSync=false, latestAge=9.28 seconds. This separates the later no-new-frame
condition from packet gaps, overflow and decoder failure. It does not yet
separate normal static-screen suppression from an unresponsive refresh/encoder.
The cap was reverted; it is not a demonstrated repair. Evidence:
`.build/decoder-audit/cap2m-console.log`.

With the original 6000000 cap, corrected receipt statistics and default VT/CI,
a continuous **foreground-only** run passed all seven 1179x2556 captures, with
sender and receiver packet counts matching. Evidence:
`.build/decoder-audit/foreground-repeat-console.log`. This does not establish
background acceptance and does not justify assuming the later silent sender is
caused by a suspended App.

A controlled visible-change test kept the receiver **in the background**. After
the timeout, the same bridge launched Calculator; a new 1179x2556 JPEG then
succeeded with `sameSession=true` and `appState=2`. No media restart or PNG
fallback occurred. The sender resumed its RTP packet counter when the visible
screen changed. Evidence:
`.build/decoder-audit/background-visible-change-console.log` (16:04:55 timeout,
16:04:56 recovery). The temporary launch/recovery code was removed afterwards.

This narrows the silent period to static-screen production / refresh handling.
It excludes a blanket loss of background execution, permanent decoder failure
or a required transport reconnect in that reproduction. A one-second age rule
can reject an otherwise valid last frame of a static stream; whether the sender
honours an on-demand refresh must be established before treating its silence as
an abnormal stopped encoder. No expired-image fallback was added.

Restoring the original PLI+FIR combination, with the same corrected feedback
endpoint and VT/CI path, also reproduced the background timeout
(`.build/decoder-audit/original-refresh-console.log`). The experimental PLI-only
replacement is therefore removed; neither request form is a proven repair of
static-screen snapshot production. The one-second freshness policy is an App
implementation choice, not an established iOS requirement. It remains unchanged
pending a precise static-frame validity / refresh contract; this audit does not
claim that policy is necessary or that repeated background snapshots are fixed.

The source manifest also had four stale hashes for already-committed local
adaptations (`app_service`, HEVC assembly, video negotiation, CoreDevice module
exports). Their hashes and modified markers now match the committed sources;
upstream snapshot hashes are retained. No additional changes to those source
files were made by this audit.

### Final validation after cleanup

- 305 default App core tests passed: `.build/validation/core.lfTqSX/test.log`.
- 36 Swift/C/Rust chain tests passed: `.build/decoder-audit/final-chain-tests.log`.
- 215 Rust library tests passed (175 vendor + 40 backend): `.build/decoder-audit/final-rust-tests.log`.
- Final unsigned iPhoneOS build passed: `.build/decoder-audit/final-unsigned-build.log`.
- Signed cleanup build installed, normal launch restored without probe arguments.
- All source-manifest hashes match; linked App contains no `de265_` / `ncm_hevc_` symbols.
- Firmware was not changed or flashed. No git commit was requested or created.

These checks validate cleanup and regressions, not completed repair of repeated
background screenshots. The unresolved static-refresh / age-policy and
SequenceGap questions above remain explicit acceptance failures.


## Refresh and sequence-gap root causes (2026-10-07)

This section supersedes the unresolved items and one-second age policy in the
preceding audit. Evidence was collected from both the receiver and the real
`avconferenced` sender using the Mac's already paired NativeRemotedTunnel and
`com.apple.os_trace_relay.shim.remote`. No privileged `log collect`, firmware
replacement, CPU decoder, PNG fallback or automatic media restart was required.

### Static picture production is distinct from an encoder keyframe request

An independent Mac receiver, without ESP32 or an iOS receiver App, reproduced
this sequence (`.build/refresh-investigation/mac-static.log`):

- Calculator initially produced frames, then stopped on a static display.
- Between seconds 9 and 20, sender reports continued every second with
  `sentPackets=receivedPackets=593`; encoder statistics showed `Input_fps=0`,
  `Enc_fps=0`, `Tx_fps=0` and no packet loss.
- PLI+FIR at seconds 10, 15 and 20 reached the encoder hook. The second of the
  two simultaneous requests logged `Request key frame too soon, discard`.
  Neither forced the capture source to supply another picture.
- A visible App change at 20.211 seconds produced an HEVC IDR (NAL 20) at
  20.248 seconds on the **same stream**, without reconnecting.

The silent interval is normal capture-source idleness in this reproduction,
not a GPU permission failure or an unreceived refresh request. PLI/FIR request
encoding recovery; they do not provide a synchronous screen-capture contract.
The generic PLI semantics also allow the sender discretion:
[RFC 4585 section 6.3.1.1](https://www.rfc-editor.org/rfc/rfc4585.html#section-6.3.1.1).
Sending both messages only duplicated the encoder request here; the NCM recovery
path now sends one PLI. Snapshot calls no longer continuously send refreshes.
Recovery after a real decoder/assembly failure still requests a keyframe.

The old one-second maximum picture age was purely an App policy and caused
false screenshot timeouts. It has been replaced by two valid completion cases:

1. A complete picture received after the screenshot request has been decoded.
2. A sender report received after the request confirms that all emitted packets
   have arrived, the assembler is synchronized with no partial/reordered AU,
   and the decoder has reached that confirmed serial in the same stream epoch.

The second case is a live snapshot of an unchanged stream, not a timeout
fallback to arbitrary cached pixels. New packets revoke the prior confirmation;
reset/overflow invalidates its epoch. An absent sender report, incomplete frame,
duplicate packets masking a missing packet, decoder lag or reset cannot satisfy
it. Silent/dead streams still time out. A separate additive C ABI state struct
keeps the existing status-struct layout intact. Agent tool schema and input
ordering are unchanged.

### Packet gaps originated in sender buffer exhaustion

The S3 baseline (`trace-console.log`, `sender-syslog.log`) recorded:

- 5680 unique admitted RTP packets, 3391 missing sequence numbers, no late
  arrivals or duplicate receipts in the trace. These were not reorder-window
  false positives.
- iOS logged `VTP_Send failed with errno=55` (`ENOBUFS`) during these bursts.
- Sender packet count still equaled receiver count (5680): packets rejected
  before successful transmission consumed sequence numbers but did not appear
  in the sender's transmitted-packet total. Equal totals therefore did **not**
  rule out these sequence gaps.
- The receiver's copied RCTL suffix `0xEA61` was parsed by iOS as
  `RemoteBWE=60001 kbps`, while its encoder target remained 5490 kbps.

A one-variable experiment changed only that RCTL field to 2000. iOS reported
`RemoteBWE=2000 kbps` and converged to a target near 1681 kbps. All 8374 captured
RTP packets were contiguous, all seven screenshots passed, and no sender
`ENOBUFS` appeared in that run (`bwe2m-console.log`, `bwe2m-syslog.log`).
This is direct evidence for the field's bandwidth meaning and its effect, not
an inferred magic constant. The final S3 profile advertises 2000 kbps both in
negotiation and RCTL, avoiding an initial 6 Mbps burst before feedback adapts.
This is a measured budget for the current S3 relay, not a universal iOS limit;
other future transports may supply a different budget. Frame size and geometry
remain unchanged. The generic desktop/audio offer still defaults to 6 Mbps.

### Final device acceptance and limits

`fix-console.log` / `fix-events.log` recorded seven successful 1179×2556 JPEGs,
including six while the receiver was in background. The test changed from Home
to Calculator, kept it static, then opened Settings without foregrounding the
receiver. Static captures succeeded with last-frame ages of 5.385 and 6.777
seconds; new sender reports validated those frames. The following screenshot
visually showed Settings, confirming that the cached Calculator picture was
not returned after the screen changed. There were 2764 RTP packets, no sequence
gaps, no assembly discontinuities and no whole-stream restart. Only two recovery
requests were sent during initial/background decoder setup, rather than a
refresh every second of each idle screenshot call.

Artifacts are local under `.build/refresh-investigation/`; `mac_static.py`,
`sender_log.py` and the packet trace make the comparisons reproducible. The
DEBUG `--ncm-static-screen-probe` flag adds Calculator/Settings transitions to
`--ncm-video-geometry-probe --ncm-video-background-probe`; it performs no provider
calls or conversation writes. These controlled runs validate this device/link,
not unlimited background lifetime or every future ESP32 model.

An additional teardown boundary was observed and kept separate: closing the
owned transport can leave the remote media session present (confirmed by its
exact diagnostic session UUID). It was explicitly stopped before each independent
comparison, only when the status contained that one known session. The source
already labels remote media stop as unconfirmed; this investigation does not
claim that dropping the transport is a verified server-side stop, nor introduce
a global stopAll in production. It did not account for the static Mac reproduction
or the bandwidth-only comparison above.

Validation of the final source: 305 default App core tests passed on isolated
simulator `05AFF9F1-0C40-4F07-AD5B-66D2C718F795`; 36 Swift/C/Rust chain tests and
216 Rust library tests (175 vendor, 41 backend) passed. The signed device build,
installation and final unsigned iPhoneOS build passed. Default core result:
`.build/validation/core.zN7p71/Tests.xcresult`. Ordinary App launch was restored
after the diagnostic run. No firmware or Git commit was changed by this investigation.
