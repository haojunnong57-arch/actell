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
