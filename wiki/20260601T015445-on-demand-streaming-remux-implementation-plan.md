# On-demand streaming remux: implementation plan (no server, no full download)

**Date:** 2026-06-01
**Status:** In progress. Phases A (DTS commit) and B (design + spikes) done; this
doc is the build spec for Phases C-F.
**Supersedes the UX of:** the batch path in `GMPlayerModel.start` that downloads +
remuxes the entire MKV to a temp MP4 before the first frame (minutes of
"Preparing…" on a 924 MiB remote file). The batch engine stays as a fallback.

## Problem recap

Opening `https://…/Dolby Vision Universe demo (4K HDR HEVC).mkv` showed
"Preparing… 21%" for a long time. Root cause: our pipeline is
`probe → gm_remux_to_fmp4(WHOLE file → temp.mp4) → play(temp)`. AVPlayer never sees
the source; it only gets a finished local file, so time-to-first-frame = download +
remux of all 924 MiB. The origin is slow (~430 KB/s measured), so ~37 min worst case.
Other players (VLC, Infuse, Plex) don't do this: they demux on demand and fetch only
the byte ranges the playhead needs.

## What we proved in Phase B (against OUR FFmpeg + the real file)

1. **On-demand input is cheap.** A custom `AVIOContext` (read/seek callbacks) backed
   by HTTP `Range:` GETs opened the remote 924 MiB MKV, probed it, **seeked to 90s,
   and read the next video packet using 3.0 MiB total** (2.0 to open+probe, 1.0 for
   the seek). Server sends `accept-ranges: bytes`.
2. **Fragmented fMP4 output plays.** `mov` muxer with
   `+frag_keyframe+empty_moov+default_base_moof+delay_moov` yields
   `ftyp + moov(~2KB) + moof/mdat…`; `AVURLAsset` → `isPlayable=true`,
   `nominalFrameRate=23.976`, full duration, seekable. `delay_moov` is REQUIRED:
   E-AC-3/AC-3 cannot write `moov` until the first audio packet is parsed.
3. **Our build only has the `mov`/`mp4` muxers** (no `hls`/`dash`/`mpegts` muxer), so
   we hand-produce HLS-fMP4 init + media segments with the `mov` muxer.

## Architecture: on-demand HLS of fMP4, served by AVAssetResourceLoaderDelegate

No web server. A custom URL scheme (`gmstream://`) makes AVPlayer route every byte
request through our delegate. We answer three resource kinds:

- `…/index.m3u8`: a VOD media playlist built from the input keyframe plan.
- `…/init.mp4`   the fMP4 init segment (`ftyp+moov`), muxed once.
- `…/segN.m4s`   one self-contained fMP4 media fragment, muxed ON DEMAND.

```
AVPlayerViewController (unchanged)
   └─ AVPlayer.currentItem = AVPlayerItem(AVURLAsset("gmstream://<id>/index.m3u8"))
          │ resourceLoader.setDelegate(GMStreamingResourceLoader)
          ▼
   GMStreamingResourceLoader  (Swift, AVAssetResourceLoaderDelegate; NO server)
     • index.m3u8 → built from segment plan (EXTINF per segment, EXT-X-MAP=init.mp4)
     • init.mp4   → gm_stream_init_segment()  (cached)
     • segN.m4s   → gm_stream_make_segment(N) (worker queue; cancelable)
          │  (C engine; new SPM target CGMStream)
          ▼
   gm_stream_open(src_callbacks) ── input AVIO (read/seek) ◄─ Swift byte source:
     • find_stream_info, gm_auto_select (reuse compat.c)         local: pread
     • build keyframe→time plan from the demuxer index            remote: URLSession Range
   gm_stream_make_segment(N, out_buf):
     • fresh mov ctx, empty_moov+frag → output AVIO into a growable buffer
     • av_seek_frame(input, segment[N].start_keyframe)
     • copy packets in [start_N, start_{N+1}) ; DTS via gm_ts_next (shared w/ batch)
     • capture bytes AFTER ftyp+moov = the moof+mdat segment
```

### Why HLS-by-time, not a single MP4

A monolithic (even fragmented) MP4 forces a global byte layout: to satisfy AVPlayer's
seek-to-byte-offset we'd have to mux everything before that offset. HLS addresses
media by TIME: each ~6s segment is independently decodable and generated on demand.
Seeking = pick the covering segment, fetch only it. This is exactly how Infuse/VLC/
Plex DirectStream behave.

### Segment plan (keyframe-aligned)

Each segment MUST start on a video keyframe to be independently decodable. We read
the demuxer's index (Matroska Cues populate `AVStream.index_entries` with
`AVINDEX_KEYFRAME`), then greedily group keyframes so each segment is ≥ the target
duration (6s). Boundaries are exact keyframe timestamps, so segments tile with no
overlap/gap. Fallback if no index: a bounded keyframe scan, else fall back to the
batch engine for that file.

### Init + media segment production with only the `mov` muxer

For each request we open a FRESH output `AVFormatContext` (`mp4`, movflags
`+frag_keyframe+empty_moov+default_base_moof+delay_moov`) writing to a custom output
AVIO that appends to a growable buffer:

- **init.mp4**: `avformat_write_header` then capture the bytes written so far
  (`ftyp+moov`). Deterministic across segments (same tracks/timescales), so it is the
  shared `EXT-X-MAP`.
- **segN.m4s**: `avformat_write_header` (discard the ftyp+moov prefix bytes), seek the
  input to segment N's start keyframe, write packets with pts < segment end, then
  `av_write_frame(NULL)` to flush the fragment. Capture the bytes AFTER the init
  prefix = `moof+mdat`. Packets keep their ABSOLUTE dts/pts so each fragment's
  `tfdt` (baseMediaDecodeTime) places it correctly on the global timeline → continuous
  playback and correct seeking. DTS goes through `gm_ts_next` (the CFR ladder from the
  DTS fix), PTS exact.

HDR/DoVi survives: fragmentation is container-only; the HEVC bitstream + DoVi RPU are
stream-copied untouched (same as the working batch remux).

## Local AND remote through one path

`open(fileURL:)` and `open(remoteURL:)` both build a `gmstream://` asset. The only
difference is the byte-source the loader hands the C engine:
- **local**: `FileHandle.seek/read` (or `pread`) over the path.
- **remote**: `URLSession` ranged GET (proven 3 MiB to open + seek).
Everything above the source (planning, muxing, loader, player) is identical, so macOS
opening a local `.mkv` is a normal seekable player and tvOS streaming an `https://…mkv`
uses the same code. Local seeking is essentially free; remote seeking fetches only the
target segment.

## AVPlayerViewController stays the player

`GMPlayerView` is untouched: iOS/tvOS keep `AVPlayerViewController`, macOS keeps
`AVPlayerView` (AVKit has no `AVPlayerViewController` on macOS). To AVKit a
`gmstream://` asset is just an HLS asset, so the native transport bar, scrubbing, PiP,
AirPlay, focus engine (tvOS), and HDR/EDR all keep working.

## Components and files

New SPM target **CGMStream** (C, depends on FFmpeg + CGMTimestamp):
- `Sources/CGMStream/include/gm_stream.h`: public C API + the pure plan API.
- `Sources/CGMStream/gm_plan.c`: PURE segment-plan math (no FFmpeg): keyframe list →
  segments, time → segment index, playlist EXTINF list. Unit-tested.
- `Sources/CGMStream/gm_stream.c`: FFmpeg: dual AVIO, open/probe/index, init segment,
  on-demand segment mux. Reuses `gm_ts_next`.

New Swift (in GMPlayerKit):
- `Sources/GMPlayerKit/Streaming/GMByteSource.swift`: protocol + local (FileHandle)
  and remote (URLSession range) implementations; bridges to the C input AVIO.
- `Sources/GMPlayerKit/Streaming/GMStreamingResourceLoader.swift`:
  `AVAssetResourceLoaderDelegate` routes playlist/init/segment requests to the engine.
- `Sources/GMPlayerKit/Engine/StreamingMediaEngine.swift`: builds the `gmstream://`
  asset + loader; conforms to a `StreamingEngine` seam.
- `GMPlayerModel`: try streaming first; on open failure fall back to batch remux.

Tests:
- `Tests/CGMStreamTests`: pure plan math (Swift over the C pure API), no FFmpeg/network.
- `Tests/GMPlayerKitTests`: resource-loader routing with a fake engine; an integration
  test that muxes init+seg0 via the real engine on the sample and asserts AVFoundation
  plays the concatenation.

## Public C API (sketch)

```c
typedef struct gm_stream gm_stream;

// Byte source the engine reads the INPUT (mkv) through. Swift implements these.
typedef struct {
    int64_t (*size)(void *ctx);                                   // total bytes, or -1
    int     (*read)(void *ctx, int64_t off, uint8_t *buf, int n); // bytes or <0
    void    *ctx;
} gm_source;

gm_stream *gm_stream_open(gm_source src, char *err, int errlen);
double     gm_stream_duration(gm_stream *);
int        gm_stream_segment_count(gm_stream *);
double     gm_stream_segment_duration(gm_stream *, int i);        // for EXTINF
int        gm_stream_time_to_segment(gm_stream *, double seconds);
// Fill caller buffer; returns bytes written (<0 on error). buf grows via realloc cb.
int        gm_stream_init_segment(gm_stream *, uint8_t **buf, int *cap);
int        gm_stream_make_segment(gm_stream *, int i, uint8_t **buf, int *cap);
void       gm_stream_close(gm_stream *);
```

The pure plan API in `gm_plan.c` (FFmpeg-free, unit-tested):

```c
// Group sorted keyframe times into segments of >= target_sec; fill seg_starts.
int  gm_plan_segments(const double *kf_times, int n_kf, double duration,
                      double target_sec, double *seg_starts, int max_segs);
int  gm_plan_time_to_index(const double *seg_starts, int n_seg, double t);
```

## Threading / backpressure / lifecycle

- Loader requests arrive on AVFoundation's queue; each segment is muxed on a serial
  worker queue, replied via `finishLoading()`. AVPlayer paces requests slightly ahead
  of the playhead, so we never run far ahead (natural backpressure).
- LRU-cache the init segment + last K media segments (small, bounded) so re-buffers
  and short back-seeks don't refetch.
- Cancellation: `resourceLoader(_:didCancel:)` cancels the in-flight `URLSession` task
  and aborts the segment mux.
- One `gm_stream` (one input AVIO) per asset; segment muxing is serialized on it
  (seeking the shared demuxer is stateful).

## Risks / mitigations

- **No Cues** → bounded keyframe scan; else fall back to batch engine.
- **E-AC-3/AC-3 init** needs `delay_moov` (verified).
- **Custom-scheme HLS via resource loader** is supported macOS 12+/iOS 15+/tvOS 15+
  (our targets). Use a single MEDIA playlist (not master) and ensure every URI uses
  the custom scheme so the loader is asked for it.
- **Fallback always present**: keep `gm_remux_to_fmp4`; if streaming open fails, the
  user still gets playback via the batch path.

## Acceptance

- tvOS sim: open the remote mkv → first frame in ~1-2s; scrub to 75% → resumes quickly
  fetching only that region (verified via byte-accounting in logs).
- macOS: open a LOCAL mkv → normal seekable playback, instant start.
- `swift test` green (pure plan tests + loader tests + init/seg integration test).
- `xcodebuild` macOS + iOS-sim + tvOS-sim all BUILD SUCCEEDED. Lint green. Committed.

## Build order (phases C-F)

- **C**: CGMStream C engine + pure plan tests.
- **D**: GMByteSource + GMStreamingResourceLoader + loader tests.
- **E**: StreamingMediaEngine + GMPlayerModel wiring (local + remote); AVPlayerViewController unchanged.
- **F**: multi-platform build, tests, manual play, lint, commit.

---

## Implemented (2026-06-01)

All phases landed and verified.

- **C engine** `Sources/CGMStream/` (`gm_plan.c` pure + `gm_stream.c` dual-AVIO).
  Validated on the 924 MB DV/E-AC3 sample (dense Cues → 30 segments) and a 41 GB
  4K DV/TrueHD remux over SMB (sparse Cues → uniform 1051 segments). Segments tile
  exactly (presentation-contiguous, no gap/overlap/dup), absolute tfdt via
  `frag_discont`. Bounded probe (8 MiB / 5 s) keeps open fast on long files.
- **Swift bridge** `Sources/GMPlayerKit/Streaming/`: `GMByteSource` (local pread /
  remote URLSession Range), `GMStreamSession`, `GMStreamingResourceLoader`
  (`gmstream://`, no server), `GMStreamingEngine`.
- **Model**: `GMPlayerModel` tries streaming first, falls back to batch remux;
  track reselect forces batch. `AVPlayerViewController`/`AVPlayerView` wrapper
  unchanged.
- **Verified**: 42 package tests green; `xcodebuild` macOS + iOS-sim + tvOS-sim all
  BUILD SUCCEEDED; lint PASS. tvOS simulator opened the remote MKV and reported
  `streaming: 30 segments, 187.9s` ~2.6 s after open (vs minutes of "Preparing…"),
  attached the player item, activated audio, and streamed over TLS.

### Known follow-ups (not blocking)
- Segment LRU cache + in-flight cancellation on seek (the design's nice-to-haves);
  current code muxes per request and relies on AVPlayer's pacing.
- A unit test with a fake AVAssetResourceLoadingRequest for the loader routing
  (currently covered via the real engine + on-device smoke test).
