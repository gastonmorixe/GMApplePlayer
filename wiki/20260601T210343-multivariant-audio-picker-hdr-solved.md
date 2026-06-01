# Multivariant audio picker, HDR included: SOLVED

**Date:** 2026-06-01
**Commit:** `13fac74` feat(stream): multivariant audio picker ON by default (HDR included)
**State:** DONE and verified on real (non-headless) playback. The native AVKit picker
lists and switches every audio track of an MKV, on SDR and HDR (HDR10 + Dolby Vision),
local and remote. Default loopback path. 61 package tests green.

This supersedes `20260601T182043-multitrack-audio-hls-progress.md`, whose "remaining
blocker" (EXTINF / `-12646` alignment) was a red herring. The real story is below.

---

## TL;DR

Goal: show every audio track in the native player picker without eager-demuxing them.
That requires a **multivariant HLS master** (an `EXT-X-MEDIA` audio rendition group),
because audio muxed inside the single video resource is invisible to AVKit's picker.

Three real bugs were blocking it, plus one phantom that ate most of the debugging time:

1. **(the actual killer) Playlist build was O(segments) of full muxes.** Each media
   playlist computed an "exact real per-segment duration" by *mux-producing every
   segment*. On a 2-hour movie that's ~1,200 muxes per playlist fetch → AVPlayer timed
   out before first frame (`-1008` / `-12884`).
2. **Missing `FRAME-RATE`** on the HDR variant. AVPlayer rejects an HDR `EXT-X-STREAM-INF`
   without it (`mediastreamvalidator`: "HDR alternate is missing FRAME-RATE").
3. **`VIDEO-RANGE=SDR` declared on a PQ stream.** The master read the raw C-open color
   (often `UNSPECIFIED` → treated as SDR) instead of the AVFoundation-resolved transfer
   (PQ). Declaring SDR on a PQ HEVC variant → `-12927`.
4. **PHANTOM: `-17223` "content cannot be played on the device".** This only ever
   happened in the **headless** test harness. A headless process has no display, so
   AVPlayer's multivariant variant-selection filters out the `VIDEO-RANGE=PQ` variant as
   unplayable → nothing left → `-17223`. On a real window/display the exact same master
   plays HDR perfectly. **Not a stream bug.**

After fixing 1–3 and recognizing 4, multivariant is ON by default and HDR works.

---

## The setup (how the engine streams)

- A C demuxer (`CGMStream/gm_stream.c`) opens the MKV over a byte source (local file or
  ranged HTTP), builds a segment plan, and muxes fragmented-MP4 (fMP4) segments on demand.
- `GMLoopbackServer` serves those segments over `http://127.0.0.1:<port>/…`. AVPlayer
  plays an `AVURLAsset` pointed at a playlist on that server. This loopback/HLS path is
  the default engine (a resourceLoader path also exists but is secondary).
- **Single-variant (legacy) path**: `index.m3u8` + muxed segments carrying video + ALL
  audio. Plays everywhere including HDR. But muxed-in audio does NOT appear in the AVKit
  picker. This is the known-good fallback (`GM_MULTIVARIANT=0`).
- **Multivariant path**: `master.m3u8` with one video variant + an `EXT-X-MEDIA` audio
  group; each rendition is a **demuxed** media playlist (`video/index.m3u8`,
  `audio/<src>/index.m3u8`). This is what makes the picker populate. Now the default.

Key C entry points: `produce_sel(gm_sel{vid_src, aud_src, all_audio})` muxes a chosen
subset of streams into one segment. `gm_sel{video_in, audio_in, all_audio=1}` = the muxed
legacy segment; `gm_sel{video_in, -1}` / `gm_sel{-1, src}` = the demuxed video / audio
renditions.

---

## Bug 1: the playlist build was secretly O(n) muxes (the real killer)

### Symptom
`GM_MULTIVARIANT=1 GM_PLAYTHROUGH` on a 2-hour movie: AVPlayer fetches `master.m3u8`, then
`audio/<src>/index.m3u8`, then dies before readyToPlay with:

```
Error Domain=NSURLErrorDomain Code=-1008 "resource unavailable"
  NSUnderlyingError=CoreMediaErrorDomain Code=-12884
```

The 4-segment static validator tree passed clean, which hid this completely.

### Root cause
`mediaPlaylist(...)` called, for every segment `i`:
- video rendition → `gm_stream_real_segment_duration(i)` → `video_real_end(i)` which
  **calls `produce_sel()`** (a full demux+mux of segment i) just to read its actual
  closing-keyframe end time.
- audio rendition → `gm_stream_real_audio_segment_duration(src, i)` → seeks + scans audio
  frames per segment.

For the test REMUXes (1216 and 1270 segs), building one media playlist = over
a thousand muxes/scans. AVPlayer's playlist fetch blocked for minutes → URL timeout
`-1008` (and the CoreMedia `-12884` underneath).

### Why the "exact real duration" code existed
The prior session believed AVPlayer required EXTINF to byte-exactly match each demuxed
rendition's real span, or it would reject the combination with `-12646`. So it built
infra to compute each rendition's true per-segment span (video on the keyframe grid,
audio on its frame grid). That belief was wrong (see below).

### The fix
Use the **planned-grid duration** (`gm_stream_segment_duration(i)`) for EXTINF. It's
already computed at OPEN, so it's instant. `mediaPlaylist` lost its `dur:` closure
parameter; both video and audio playlists call the same plan-grid body.

### Why this is correct (Apple docs)
`https://developer.apple.com/documentation/http-live-streaming/video-on-demand-playlist-construction`:

> **EXTINF** … specifies the duration of the media segment in seconds. This value must be
> **less than or equal to the target duration.**

The spec wants floating-point EXTINF for seek accuracy and `EXTINF <= TARGETDURATION`. It
does NOT require byte-exact per-segment spans. And AVPlayer aligns demuxed renditions by
**absolute `tfdt` (baseMediaDecodeTime)**, not by matching segment lengths. So the uniform
plan grid is both correct and instant.

### Proof
With plan durations (then gated behind `GM_FASTDUR=1`, now unconditional), the SAME live
multivariant server that timed out before:

```
engine=loopback makePlayback=0.04s duration=7294.8s segs=1216
readyToPlay in 0.70s  served=2/1216
PLAY1: 0.00s -> 3.90s (advanced 3.90s)
SEEK -> 5106s (70%) landed 5106.00  served=20/1216
PLAY2 advanced 3.99s
PLAYTHROUGH OK
```

Note `served=2/1216` then `20/1216`: audio renditions are fetched lazily, never "the whole
movie up front". The expensive path wasn't just unnecessary, it was THE bug.

---

## Bug 2: missing FRAME-RATE on the HDR variant

### Symptom
`mediastreamvalidator /tmp/hlsval/master.m3u8` on a 4K HDR10 REMUX:

```
Critical: HDR alternate is missing FRAME-RATE
--> Line: video/index.m3u8
Critical: Stream type unrecognized
```

### Root cause
`masterPlaylist` emitted `BANDWIDTH`, `CODECS`, `RESOLUTION`, `VIDEO-RANGE` but no
`FRAME-RATE`. For an HDR/HEVC `EXT-X-STREAM-INF`, `FRAME-RATE` is REQUIRED.

### The fix
Plumb frame rate from FFmpeg through to the master:
- C: `gm_track_info` gained `int fps_num, fps_den`. `gm_stream_track_info` fills them from
  `st->avg_frame_rate` (falling back to `st->r_frame_rate`).
- Swift: `Track.fpsNum/fpsDen` + a computed `Track.frameRate: Double?`.
- `masterPlaylist`: `if let fr = v?.frameRate { s += ",FRAME-RATE=\(%.3f fr)" }`.

After this, the HDR variant declared `FRAME-RATE=23.976` and both CRITICAL errors cleared (the
"Stream type unrecognized" was a downstream effect of the malformed HDR variant).

---

## Bug 3: VIDEO-RANGE=SDR on a PQ stream

### Symptom
The live master for a `smpte2084`/PQ HDR10 REMUX declared:

```
#EXT-X-STREAM-INF:...,VIDEO-RANGE=SDR,AUDIO="aud"
```

Yet `GM_HDR` probe reported `isHDR=true transfer=SMPTE ST 2084 (PQ)`. The two disagreed.

### Root cause
`GMStreamSession` has two color views:
- `color`: the raw `ColorInfo` captured at C-open. For files where the container leaves
  transfer UNSPECIFIED until decode, this reads SDR.
- `resolvedColor` / `isHDR`: calls `resolveColor()`, which probes via AVFoundation and
  recovers the real transfer (PQ).

`masterPlaylist` used the raw `color.isHDR` (false) → declared `VIDEO-RANGE=SDR` on a PQ
HEVC variant. AVPlayer rejects that mismatch with `-12927`.

### The fix
Use the resolved color, and distinguish HLG:
```swift
let rc = resolvedColor
s += ",VIDEO-RANGE=\(rc.isHDR ? (rc.isHLG ? "HLG" : "PQ") : "SDR")"
```
Added `ColorInfo.isHLG` (`transfer == 18`). After this the HDR master correctly declares
`VIDEO-RANGE=PQ`, and the error advanced from `-12927` to `-17223` (i.e. past variant
parsing into the phantom).

---

## Bug 4 (the PHANTOM): `-17223` is a headless artifact, not a stream bug

This is the one that cost the most time and nearly led to a wrong "HDR can't be demuxed"
conclusion. Document it loudly so nobody re-walks it.

### Symptom
After Bugs 2–3 were fixed, HDR multivariant in the **headless harness** failed with:

```
AVFoundationErrorDomain Code=-11868 "Cannot open"
  NSLocalizedFailureReason=The content cannot be played on the device.
  NSUnderlyingError=CoreMediaErrorDomain Code=-17223
```

### The bisection that proved it's NOT our code
Built the tree from `gm-muxed.mp4` (our muxed video+audio that plays great single-variant)
and tested the SAME bytes four ways. Video bytes identical in all four:

| Test                                            | Result |
| ----------------------------------------------- | ------ |
| A: media playlist **direct** (no master)        | PLAYS OK |
| B: behind a master, no VIDEO-RANGE              | `-12927` |
| C: behind a master, VIDEO-RANGE=SDR             | `-12927` |
| D: behind a master, VIDEO-RANGE=PQ              | `-17223` |

So the trigger is simply **"HDR HEVC behind a multivariant master in a headless process"**,
muxed or demuxed, any attribute combo.

Then the decisive control: rebuilt the entire tree with **100% Apple tooling**: `ffmpeg
-c copy` to demux + Apple's own `mediafilesegmenter` to fragment + a standard master,
and played it through a clean headless `AVPlayer`. **Same `-17223`.** Our muxer was
exonerated: even Apple's bytes fail demuxed-HDR-multivariant in a headless process.

### What `-17223` actually is
Not a documented CoreMedia constant. It's an internal media-format-reader / variant-
selection rejection. The operative phrase is the AVFoundation wrapper: **"content cannot
be played on the device."** In multivariant mode AVPlayer does variant SELECTION first,
and it filters variants against what the current **display** can present. A headless
process has no display and no HDR-capable output, so the `VIDEO-RANGE=PQ` variant is
filtered out → no variant remains → failure. A direct media playlist skips selection
entirely, so it just plays (and tone-maps).

### Proof it's a phantom (windowed verification)
Added a `GM_SERVE` harness mode that keeps the loopback server alive and prints the asset
URL, plus a standalone `winprobe` that creates a real `NSWindow` + `AVPlayerView` and
plays that URL. On a REAL window:

```
# local DoVi/HDR demo (4 audio tracks)
readyToPlay in 0.6s
  Audible: 4 -> English | English | English | English
  Legible: 1 -> CC
currentTime=2.23 rate=1.0 → PLAYS OK

# remote 4K HDR10 REMUX over HTTP (3 EN + IT audio)
readyToPlay in 1.4s
  Audible: 4 -> English | English | English | Italian
  Legible: 1 -> CC
currentTime=1.49 rate=1.0 → PLAYS OK
```

Same multivariant master, same demuxed renditions, but a real display context → plays HDR
with the full picker. Cross-confirmed by the user in the actual app (screenshot showed the
Audio Track submenu listing English/English/English/Italian).

### Lesson
The headless harness is great for SDR playback, segment timing, tfdt, lazy-fetch
regression, and `mediastreamvalidator` structural checks. It is **useless for HDR
multivariant playback verification** because it has no display, and AVPlayer's variant
selection is display-aware. Verify HDR multivariant on a real window
(`GM_SERVE` + `winprobe`) or in-app, never on the headless probe.

---

## Secondary fix: BANDWIDTH headroom

`mediastreamvalidator` flagged "Measured peak bitrate exceeds declared" because BANDWIDTH
was derived from the AVERAGE (`size*8/duration`) while remux peaks run ~1.5–2x average.
Now: `bw = max(8 Mbps, avg * 2.5)`. Over-declaring on a single video variant is harmless
(there's no adaptation to mislead). This is an authoring-spec nicety, not a playback
blocker.

---

## Authoritative tooling notes (for the next person)

- **`mediastreamvalidator /tmp/hlsval/master.m3u8`** (Apple's HLS validator, `/usr/local/bin`)
  is the way to debug opaque AVPlayer codes structurally. Build a static tree with the
  `GM_TREE=<audioSrc>` harness. It catches FRAME-RATE/CODECS/VIDEO-RANGE/RESOLUTION/LANGUAGE
  issues. It does NOT catch the headless display-filter phantom (it's a static check).
- **`mediafilesegmenter --format iso -t 6 -f <dir> <file.mp4>`** fragments an mp4 and
  writes a `<name>.plist` next to the SOURCE. The plist's `videoCodecInfo` is Apple's own
  RFC6381 string. For our Dolby HEVC Main10 it computed `hvc1.2.20000000.H153.90` (note:
  High tier `H`, constraint flags `20000000`, level 153, suffix `90`). It refused the MKV
  directly (`-12847`); feed it our demuxed/remuxed mp4 instead. NB: even Apple's own codec
  string did not change the headless `-17223`: because the issue was never the codec
  string, it was the missing display.
- **`variantplaylistcreator`** is finicky about cwd/relative paths; the plist already gives
  you everything you need, so you can skip it.
- **`ffprobe`** (`/opt/homebrew/bin`) for stream truth: `profile=Main 10`, `level=153`,
  `color_transfer=smpte2084`, and side-data `DOVI configuration record dv_profile=7` (the
  local DoVi demo is Dolby Vision Profile 7, dual-layer BL+EL+RPU; the other REMUX is plain HDR10).

---

## Files changed (commit 13fac74)

- `CGMStream/include/gm_stream.h`: `gm_track_info` gained `fps_num`, `fps_den`.
- `CGMStream/gm_stream.c`: fill fps from `avg_frame_rate`/`r_frame_rate` in
  `gm_stream_track_info`.
- `Streaming/GMStreamSession+Tracks.swift`: `Track.fpsNum/fpsDen`, `Track.frameRate`,
  `ColorInfo.isHLG`.
- `Streaming/GMStreamSession.swift`: `masterPlaylist`: FRAME-RATE, resolved VIDEO-RANGE
  (PQ/HLG/SDR), BANDWIDTH headroom. `mediaPlaylist`: plan-grid EXTINF only (dropped the
  per-rendition real-duration closure). Removed diagnostic env knobs
  (GM_VCODEC/NOVRANGE/MAXAUD/FASTDUR).
- `Streaming/GMStreamingEngine.swift`: multivariant ON by default; `GM_MULTIVARIANT=0`
  forces the legacy single muxed playlist. Removed the GM_LEAF diagnostic.
- `gmstreamtest/main.swift`: added `GM_SERVE` (keep loopback server alive + print asset
  URL, for windowed verification).

The real-duration C functions (`gm_stream_real_segment_duration`,
`gm_stream_real_audio_segment_duration`) are KEPT, they're still used by the `GM_TREE`
validator harness to MEASURE real spans for comparison, but they're no longer on the live
playback path.

---

## How to run / verify

```bash
# Default build = multivariant audio picker on.
make build-mac
# IMPORTANT: fully quit the app (Cmd-Q) between runs. `open` does NOT relaunch a running
# app, so a stale instance keeps its old environment and old GM_MULTIVARIANT value. This
# is what made "unset looks broken" earlier: it was a stale instance, not the default.
make run-mac FILE="/path/to/movie.mkv"          # picker shows every audio track
GM_MULTIVARIANT=0 make run-mac FILE="..."         # fallback: plays, single audio, no picker

# Headless harness (SDR playback / timing / lazy-fetch regressions only):
gmstreamtest <file> loopback 6.0                  # default multivariant
GM_PLAYTHROUGH=1 gmstreamtest <file> loopback 6.0 # start+play+seek+play gate
GM_TREE=<audioSrc> gmstreamtest <file> loopback 6.0 && mediastreamvalidator /tmp/hlsval/master.m3u8

# HDR multivariant playback MUST be verified on a real window, not headless:
GM_SERVE=1 gmstreamtest <file> loopback 6.0 &     # prints "SERVE_URL http://127.0.0.1:<port>/master.m3u8"
winprobe "$SERVE_URL"                              # real NSWindow + AVPlayerView
```

Verified files this session: the local Dolby Vision Universe demo (4K HDR HEVC,
DoVi P7, 4 audio), a remote 4K HDR10 REMUX (3 EN + IT), a remote 1080p SDR REMUX
(1 audio control), and a 4K DoVi REMUX (confirmed in app).

---

## What remains: Phase B: subtitles via WebVTT

Independent of this work. FFmpeg build script already updated (`1d29fbc`) with subtitle
text decoders (subrip/ass/mov_text) + the WebVTT encoder/muxer. Steps:

1. Rebuild the xcframework: `./Scripts/build-ffmpeg.sh macos`.
2. C: per-segment subtitle→WebVTT transcode with `X-TIMESTAMP-MAP` aligned to the fMP4 PTS.
3. `GMStreamSession`: `EXT-X-MEDIA:TYPE=SUBTITLES` group + `SUBTITLES=` on the variant;
   `subs/<src>/index.m3u8` + `.vtt` segments.
4. `GMLoopbackServer`: route `/subs/<src>/*` on demand.
5. Image subs (PGS/VobSub) are NOT carryable as text: omit from the master or mark
   unsupported, no crash. A text SRT (e.g. an Italian "Forced" track) is the kind of
   track that should appear.
6. Verify the SRT shows + renders aligned; then build/test/lint/commit Phase B.

Track enumeration already classifies text vs image subs (`Track.isTextSubtitle`), so the
foundation is in place.
