<p>
   <h1 align="center">
      <img  height="200" alt="GMPlayer" src="https://github.com/user-attachments/assets/ed124345-846a-4bf9-932b-d474a9df0610" /> <br> GMPlayer <br> <br>
   </h1>
</p>

<p align="center">
   <img height="684" alt="Screenshot GMApplePlayer MacOS App" src="https://github.com/user-attachments/assets/4f755683-06ce-4862-8cee-c7861cd73ad7" />
</p>


[![CI](https://github.com/gastonmorixe/GMApplePlayer/actions/workflows/ci.yml/badge.svg)](https://github.com/gastonmorixe/GMApplePlayer/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20iOS%20%7C%20tvOS-lightgrey)

A multiplatform (macOS / iOS / tvOS) SwiftUI app that plays **MKV** files, local
or remote, through Apple's **native AVKit player**, by **remuxing** the file
on-device with **FFmpeg 8.1.1** linked directly into the app. No transcoding.

> Status: builds on macOS, iOS, and tvOS (Xcode 26, Swift 6). Verified playing
> large 35-81 GB 4K HDR REMUX MKVs over the
> LAN: sub-second start, seek anywhere and resume, A/V synced, HDR (HDR10 + Dolby
> Vision base layer) playing. The default engine builds a **multivariant HLS** stream,
> so every audio track and every text subtitle shows up in the **native AVKit picker**
> and switches on demand, without demuxing tracks you don't watch. Two streaming
> engines (multivariant HLS loopback, the default; single-file resource loader, opt-in)
> plus a **batch remux** fallback. The engine is user-selectable in Settings. 61 tests
> pass; build is warning-free. See `wiki/` for the DTS fix, the streaming post-mortem,
> the huge-MKV / HDR / crash write-up, and the multivariant audio-picker + HDR
> write-up (including the headless `-17223` phantom).

## How it plays

The same on-demand engine demuxes the MKV and stream-copies the watched window into
fragmented-MP4 segments on the fly. Two transports feed those segments to AVPlayer,
both keeping the native AVKit chrome; a third path is a non-streaming fallback.

1. **Multivariant HLS loopback (default).** AVPlayer plays a `master.m3u8` served over
   a tiny **loopback HTTP server** (127.0.0.1, ephemeral port, in-process). The master
   lists one video variant plus an `EXT-X-MEDIA` audio group (one rendition per
   playable audio track) and, when the file has text subtitles, an `EXT-X-MEDIA`
   subtitle group. So the **native picker lists every audio track and every text
   subtitle**, and a rendition's segments are produced only when AVPlayer actually
   selects it: you never demux audio you don't listen to. The video variant streams
   lazily as the playhead moves, so even a 70 GB movie starts in well under a second
   and only watched ranges are fetched. This is the engine that scales to huge
   many-fragment files. `GM_MULTIVARIANT=0` falls back to a single muxed media playlist
   (plays everywhere, but no track picker), a known-good safety net.
2. **Single-file resource loader (opt-in).** The segments are concatenated into ONE
   fragmented-MP4 resource vended through a custom-scheme `AVAssetResourceLoaderDelegate`
   (no server). Best for small/medium files. It does NOT scale to very large
   many-fragment movies: AVFoundation walks every fragment at open to build its own
   index, which forces muxing nearly the whole file ("loads forever"). Kept for the
   files where it's fine; select it in Settings or with `GM_PLAYER_ENGINE=resourceloader`.
3. **Batch remux (fallback).** Stream-copy the whole file to a temp faststart MP4, then
   play it. Used automatically if streaming can't open the source.

> Engine choice is in **Settings** (gear on the landing screen, or `Settings…`/⌘, on
> macOS): Automatic (loopback), HLS loopback, or Single file. The choice persists.
> Why loopback for large files, and why a `sidx` does not rescue the single-file path,
> is in `wiki/20260601T155907-huge-mkv-loopback-default-hdr-and-crash-fix.md`; why a
> loopback HTTP server at all (AVFoundation rejects resource-loader-vended HLS segment
> bytes with `-12881`) is in
> `wiki/20260601T051137-on-demand-streaming-loopback-server-postmortem.md`.

## What problem this solves

`AVFoundation`/`AVPlayer` cannot open Matroska (`.mkv`) at all, it has no MKV
demuxer. But the compressed streams *inside* a typical MKV (HEVC/H.264 video,
AAC/AC-3/E-AC-3 audio) are codecs AVFoundation decodes natively. So instead of
re-encoding (slow, lossy) we **repackage** the same bytes from Matroska into a
faststart MP4 that AVPlayer plays. This is a pure stream copy: no quality loss,
runs at hundreds of times real-time, tiny CPU.

## How it works

```
 source (file path or http(s)://)
        │
        ▼  on-demand streaming (default)
 GMStreamSession ──► CGMStream engine (dual AVIO):
        │   • input AVIO: bytes from GMByteSource (local pread | HTTP Range GET)
        │   • plan keyframe-aligned ~6s segments (Cues, else a uniform grid)
        │   • enumerate tracks; build a multivariant master (video variant +
        │                audio renditions + WebVTT subtitle renditions)
        │   • on demand: seek input, stream-copy the SELECTED rendition's window
        │                -> fragmented MP4 segment (hvc1/avc1, CFR DTS ladder)
        ▼
 GMLoopbackServer   127.0.0.1:<ephemeral>  serves master.m3u8 + per-rendition
        │           video/*, audio/<src>/*, subs/<src>/* (in-process, HTTP range)
        ▼
 AVPlayer(url: http://127.0.0.1:<port>/master.m3u8)   native HLS playback +
        │                                              audio/subtitle picker
        ▼
 GMPlayerView          AVPlayerViewController (iOS/tvOS) or AVPlayerView (macOS)
```

If streaming can't open the source, `GMPlayerModel` falls back to the **batch**
path: `GMRemuxer.probe()` + `GMRemuxer.remux()` stream-copy the whole file to a
temp faststart MP4 and hand its URL to AVPlayer. Same DTS handling, same codecs.

FFmpeg runs **in-process** (static libs in the app). The only "server" is the
loopback socket above, required because AVFoundation must fetch HLS segments over
HTTP (it rejects resource-loader-vended segment bytes); it binds to 127.0.0.1 on an
OS-assigned port and is unreachable from outside the process.

### The transport gotcha (why a loopback server)

The first design was a no-server `AVAssetResourceLoaderDelegate` over a custom
`gmstream://` scheme. It does not work: AVFoundation only lets a resource loader
return **playlists, keys, or redirects** for HLS, never segment **bytes** (it drives
bitrate adaptation itself). Vending segment data fails with `AVPlayerItem` error
`-12881`. The exact same segments play fine over HTTP, so the fix is a loopback HTTP
server, the approach Infuse/VLCKit/KTVHTTPCache use. Details, including the `-15514`
red herring that misled two analyses, are in the streaming post-mortem under `wiki/`.

## Multiple audio tracks and subtitles (the native picker)

A typical movie MKV ships several audio tracks (a main mix, commentaries, other
languages) and a pile of subtitles. The default engine surfaces all of them in
Apple's own track picker by building a **multivariant** HLS master: one video
variant, an `EXT-X-MEDIA` audio rendition group, and (when text subs exist) a
subtitle group. The picker then lists and switches them with zero custom UI.

```
master.m3u8
├── EXT-X-STREAM-INF  ->  video/index.m3u8   (video-only fMP4, lazy)
├── EXT-X-MEDIA TYPE=AUDIO      GROUP-ID="aud"   (one per audio track)
│   ├── audio/<src>/index.m3u8  ->  init.mp4 + segN.m4s
│   └── audio/<src>/index.m3u8  ->  ...   (muxed only when selected)
└── EXT-X-MEDIA TYPE=SUBTITLES  GROUP-ID="subs"   (text subs only)
    └── subs/<src>/index.m3u8   ->  segN.vtt   (WebVTT, X-TIMESTAMP-MAP)
```

The lazy model holds: a rendition's segments are produced only when AVPlayer
actually selects it, so picking the third audio track demuxes that track from then
on, never all tracks up front. Three details earned their keep:

- **Audio renditions are demuxed**, video segments carry video only. Muxed-in audio
  plays, but it's invisible to the AVKit picker, so exposing a switchable list means
  splitting the tracks.
- **Subtitles are WebVTT.** Text subs (SubRip/ASS/mov_text) are decoded and emitted
  as `.vtt` segments with the `X-TIMESTAMP-MAP` header AVPlayer expects, matching what
  Apple's own `mediasubtitlesegmenter` produces. **Image subtitles (PGS / VobSub)
  carry no text**, only bitmaps, and HLS has no image-subtitle rendition (Apple
  supports the WebVTT/IMSC text profile only). They're excluded from the master
  cleanly, no crash; carrying them would need OCR, a separate lossy feature.
- **HDR demands an exact variant declaration.** An HDR variant must carry
  `FRAME-RATE` and a `VIDEO-RANGE` that matches the real transfer (`PQ`/`HLG`), read
  from the AVFoundation-resolved color, not the container's often-unspecified value.
  Get either wrong and AVPlayer rejects the stream (`-12927`). With them right, HDR
  plays behind the multivariant master with the full picker. The full investigation,
  including a headless `-17223` that turned out to be a display-less test artifact, is
  in `wiki/20260601T210343-multivariant-audio-picker-hdr-solved.md`.

`GM_MULTIVARIANT=0` forces the legacy single muxed playlist (plays everywhere, no
picker) as a fallback.

## Project layout

```
GMApplePlayer/
├── Makefile                          build/test/run/install shortcuts (make help)
├── project.yml                       XcodeGen project (macOS/iOS/tvOS app targets)
├── PLAN.md                           architecture, data flow, capability matrix
├── wiki/                             engineering post-mortems (e.g. the DTS judder fix)
├── Scripts/
│   ├── build-ffmpeg.sh               cross-compiles the remux-only xcframework
│   ├── run-app.sh                    launch/install on mac + simulators
│   ├── lint.sh                       SwiftLint + SwiftFormat + structure check
│   └── check-structure.sh            ≤500 lines/file, ≤1 SwiftUI View per file
├── Sources/GMApplePlayer/            the app (one view per file, by folder)
│   ├── App/GMApplePlayerApp.swift    @main + macOS File-menu commands
│   ├── Screens/                      ContentView (router), LandingScreen, PlayerScreen
│   ├── Components/                   LandingActions, OpenURLSheet, TrackPicker,
│   │                                 TelemetryHUD, PlayerControlsOverlay, MouseActivity…
│   ├── Style/GlassStyle.swift        Liquid Glass helpers + fallbacks
│   └── Support/                      MediaImportCoordinator, ControlsVisibilityModel
│                                     (the UI<->logic boundary: no views here)
└── Packages/GMPlayerKit/             local Swift package
    ├── Package.swift
    ├── Frameworks/FFmpeg.xcframework  FFmpeg 8.1.1 static libs (all Apple slices)
    ├── Tests/
    │   ├── GMPlayerKitTests/         probe + remux-timing + streaming session + loopback server (needs an MKV; skips if absent)
    │   ├── CGMTimestampTests/        pure timestamp-policy tests (no FFmpeg, no media file)
    │   └── CGMStreamTests/           pure segment-plan tests (keyframe/uniform grouping, time->segment)
    └── Sources/
        ├── CFFmpeg/                  C batch remux engine (split for SRP)
        │   ├── include/gmremux.h     the only header Swift sees (public API)
        │   ├── compat.c              codec policy + AVFoundation-compat scoring
        │   ├── probe.c               init/version/probe + Dolby Vision detection
        │   ├── remux.c               stream-copy MKV -> faststart MP4 (calls gm_ts_*)
        │   └── ffmpeg-include/       FFmpeg headers (private to this target)
        ├── CGMTimestamp/             pure, FFmpeg-free DTS policy (gm_ts_init/next, CFR ladder)
        ├── CGMStream/                on-demand streaming engine (dual AVIO)
        │   ├── include/{gm_stream,gm_plan}.h
        │   ├── gm_plan.c             pure segment-plan math (unit-tested)
        │   └── gm_stream.c           input AVIO + per-rendition fMP4 segment muxer +
        │                             track enum + text-sub->WebVTT; reuses gm_ts
        └── GMPlayerKit/              Swift API (one type per file, by folder)
            ├── Engine/               MediaEngine (DIP), GMRemuxer, GMStreamInfo, GMAudioSession
            ├── Streaming/            GMByteSource (local/HTTP), GMStreamSession
            │                         (+multivariant master, audio/subtitle renditions),
            │                         GMLoopbackServer (127.0.0.1), GMStreamingEngine/Playback
            ├── Model/GMPlayerModel   streaming-first orchestration + batch fallback
            ├── Player/GMPlayerView   AVPlayerViewController (iOS/tvOS) / AVPlayerView (macOS)
            └── Telemetry/GMPlaybackMonitor  rate, dropped frames, HDR/EDR
```

## Make targets

```
make bootstrap     # first-time: build FFmpeg xcframework + generate project
make mac           # build + run the macOS app   (FILE=/path to auto-open)
make ios-sim       # build + install + launch in the iOS simulator
make tvos-sim      # build + install + launch in the tvOS simulator
make tvos-device   # signed build + install on a paired Apple TV (DEVICE=, TEAM=)
make tvos-launch   # launch on the Apple TV (URL=... to auto-open a remote stream)
make test          # run the GMPlayerKit engine tests
make lint          # SwiftLint + SwiftFormat + structure check
make help          # full list
```

## Decoupling & structure rules

- **One view per file**, one type per file; nothing over 500 lines. Enforced by
  `Scripts/check-structure.sh`, wired into `make lint`.
- **UI is decoupled from logic.** Views are declarative and dumb (data in,
  intents out as closures). All file-picking, security-scoped access, drag/drop,
  and launch-arg parsing live in `MediaImportCoordinator`; auto-hide behavior in
  `ControlsVisibilityModel`; the player model depends on a `MediaEngine`
  protocol (DIP), so it is testable with a fake engine.

## Build & run

Prereqs: Xcode 26.x and `xcodegen` (`brew install xcodegen`). Apple-silicon Mac
(the shipped xcframework is arm64 for all slices). No system `ffmpeg` is needed:
the FFmpeg source is fetched and built by the bootstrap step.

> **Three things are gitignored and must exist before a build** (see
> `.gitignore`): `Packages/GMPlayerKit/Frameworks/FFmpeg.xcframework`,
> `Packages/GMPlayerKit/Sources/CFFmpeg/ffmpeg-include/`, and
> `GMApplePlayer.xcodeproj` (generated from `project.yml`). On a fresh clone,
> `make bootstrap` produces all three: it **downloads and checksum-verifies the
> pinned FFmpeg 8.1.1 source automatically** (no manual download), cross-compiles
> the remux-only xcframework, and runs `xcodegen`. Then `make build-all`. If you
> already have them (this working copy does), skip straight to `make build-all` /
> `make mac`.

### Clone and build (fresh machine)

```sh
git clone https://github.com/gastonmorixe/GMApplePlayer.git
cd GMApplePlayer
brew install xcodegen          # the only prerequisite besides Xcode 26.x
make bootstrap                 # downloads + verifies FFmpeg 8.1.1, builds the
                               # xcframework, runs xcodegen (no manual steps)
make mac                       # build + launch the macOS app
```

### Fast path (Makefile)

```sh
make bootstrap     # fresh clone only: fetch+build FFmpeg xcframework + xcodegen generate
make build-all     # compile macOS + iOS + tvOS
make mac           # build + launch the macOS app   (FILE=/path/to.mkv to auto-open)
make test          # run the package tests
make lint          # SwiftLint + SwiftFormat + structure gate
```

The manual steps below are what `make bootstrap` / `make build-*` wrap.

### 1. Build the FFmpeg xcframework (once)

```sh
cd GMApplePlayer
./Scripts/build-ffmpeg.sh            # all 5 slices: macOS, iOS (dev+sim), tvOS (dev+sim)
# or just the Mac slice for a fast loop:
./Scripts/build-ffmpeg.sh macos
```

Output: `Packages/GMPlayerKit/Frameworks/FFmpeg.xcframework` (~27 MB).
Set `FFMPEG_SRC=/path/to/ffmpeg-8.1.1` if the source isn't at
`../repos/ffmpeg-8.1.1`. Set `FFMPEG_ENABLE_NETWORK=0` for a local-file-only,
smaller build.

### 2. Generate the Xcode project

```sh
xcodegen generate
open GMApplePlayer.xcodeproj
```

### 3. Run

Pick the scheme (`GMApplePlayer-macOS`, `-iOS`, or `-tvOS`) and Run.

- **macOS / iOS:** tap **Open File**, pick an `.mkv`, or **Open URL** for a remote one.
- **tvOS:** **Open URL** only (tvOS has no user file picker).

### Command-line builds

```sh
# macOS app
xcodebuild -scheme GMApplePlayer-macOS -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build

# simulators (arm64 to match the xcframework)
xcodebuild -scheme GMApplePlayer-iOS  -destination 'generic/platform=iOS Simulator' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
xcodebuild -scheme GMApplePlayer-tvOS -destination 'generic/platform=tvOS Simulator' \
  ARCHS=arm64 ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

## Testing

```sh
make test                  # == cd Packages/GMPlayerKit && swift test  (61 tests)
```

Test targets:

- **`CGMTimestampTests`** (pure, no FFmpeg/media): replay the real captured
  4506-packet sequence through the timestamp policy: DTS strictly monotonic, PTS
  preserved, `dts <= pts`, true `{656,672}`-tick (23.976fps) cadence. Run anywhere.
- **`CGMStreamTests`** (pure, no FFmpeg/media): segment-plan math: keyframe and
  uniform-grid grouping, time→segment mapping, tiny-tail absorption. Run anywhere.
- **`GMPlayerKitTests`**: probe + batch remux + the streaming session/engine
  (`GMStreamSessionTests`) + the loopback server reaching `readyToPlay`
  (`GMLoopbackServerTests`, the case that failed at `-12881` through the resource
  loader). These need a real MKV and **skip gracefully** (`XCTSkip`) when none is
  present, so a fresh clone still passes.

**No sample MKV is bundled in the repo** (they're huge). The integration tests
look for one in this order:

1. `$GM_TEST_MKV` if set and the file exists;
2. else `~/Movies/Dolby Vision Universe demo (4K HDR HEVC).mkv` (the
   freely-distributed **Dolby Vision Universe** demo);
3. else they skip.

```sh
GM_TEST_MKV=/path/to/any.mkv make test    # exercise the full remux path
```

### Headless engine (no UI)

The package ships a CLI that drives the exact same engine:

```sh
cd Packages/GMPlayerKit
swift run gmremux-cli "/path/to/movie.mkv" /tmp/out.mp4
# or: make remux IN=/path/to/movie.mkv OUT=/tmp/out.mp4
# add GM_TS_DEBUG=1 to dump raw per-packet timestamps from the demuxer
```

It prints the probed streams and remuxes to a playable faststart MP4.

The Mac app also accepts `--open <path-or-url>` to auto-load on launch (used for
the acceptance check):

```sh
open GMApplePlayer-macOS.app --args --open "/Users/you/Movies/movie.mkv"
```

## Capability matrix (the honest part)

What "plays beautiful" means depends on what AVFoundation can natively decode.
The remuxer probes each file at runtime and copies what Apple can play; it does
**not** assume anything about a specific file.

| Source element                | Handling                                                        |
| ----------------------------- | --------------------------------------------------------------- |
| MKV / MPEG-TS container       | Remuxed to faststart MP4 (stream copy)                          |
| HEVC / H.265, incl. **HDR10** | Played; tagged `hvc1`. BT.2020 + PQ HDR preserved.              |
| H.264 / AVC                   | Played; tagged `avc1`.                                          |
| AAC, AC-3, E-AC-3, ALAC, MP3  | Played (stream copy).                                           |
| **Dolby Vision Profile 7**    | Not playable on Apple (dual-layer). Falls back to its **HDR10** base layer, which looks great. |
| **TrueHD / DTS / DTS-HD**     | Not supported by AVFoundation. The remuxer skips it and selects a compatible audio track (e.g. the AC-3 track) instead. |
| Dolby Atmos (in TrueHD/EAC3)  | Object audio isn't decoded by AVFoundation; you get the channel bed of a compatible track. |
| **Multiple audio tracks**     | Every AVFoundation-playable track (AAC/AC-3/E-AC-3/...) appears in the native picker; switching demuxes that track on demand. |
| **Text subtitles** (SubRip/ASS/mov_text) | Carried as WebVTT renditions; appear in the native picker. |
| **Image subtitles** (PGS/VobSub) | Bitmap, not text; HLS has no image-subtitle rendition, so they're omitted from the picker (would need OCR). |

These are Apple-platform limits, not bugs in the remuxer. A file whose only audio
is TrueHD will play video with no audio (and the UI says why). Everything that
*can* be stream-copied to play natively, is.

## FFmpeg build details

Remux-only configure: `--disable-everything` then re-enable just the matroska/
mov/mpegts/hls demuxers, the mov/mp4 muxers, the parsers and bitstream filters
needed to repacketize elementary streams, and the file/http/https/tls protocols.
The one exception to "no codecs": **text-subtitle decoders** (SubRip/ASS/mov_text)
plus the **WebVTT encoder + muxer**, so the engine can turn in-container text subs
into the WebVTT segments HLS subtitle renditions require. No video/audio decoders,
no swscale/swresample/avfilter/avdevice. Result: three small static libs
(`libavformat`, `libavcodec`, `libavutil`) per slice, merged into one `libFFmpeg.a`
per platform inside the xcframework.

## Known gotchas (baked into the engine)

- **HEVC needs the `hvc1` tag**, not `hev1`, or AVFoundation rejects it. The
  output stream's `codec_tag` is forced.
- **Output is a plain faststart MP4** (`movflags=faststart`: moov atom at the
  front, fully indexed), not fragmented. We remux the whole file before playback,
  so an indexed MP4 gives AVPlayer the best buffering + seeking. An earlier
  `empty_moov+frag` layout stalled on large 4K fragments.
- **macOS has no `AVPlayerViewController`** (iOS/tvOS only). On macOS the wrapper
  uses `AVPlayerView` (AppKit). Same native controls, transport, full-screen.
- **Matroska DTS is presentation-ordered (the judder bug).** For a B-frame
  stream the demuxer hands packets in decode order but with `dts == pts`, so the
  raw DTS is non-monotonic and the mov muxer rejects it. The fix lives in
  `CGMTimestamp` (`gm_ts.c`): for a constant-frame-rate video stream it drives a
  uniform DTS ladder at the **exact** per-frame tick step (`out_tb_den / fps`),
  led by the reorder depth so every reordered PTS stays `>= dts`; PTS is passed
  through untouched. Two earlier attempts were wrong and are worth not repeating:
  "dts = pts, bump on collision" bunched frames onto adjacent ticks, and
  "dts = prev_dts + duration" rebuilt DTS from the source's *quantized* 41ms
  duration and produced 24.39fps instead of 23.976. Both look like ~10fps judder
  while audio stays smooth, and `AVPlayerItem.accessLog` reports zero dropped
  frames (it only sees decode, not the present cadence). Note `nominalFrameRate`
  is an average and hides bunching, so the tests assert the actual per-frame
  cadence, not just the average. Pure unit tests (`CGMTimestampTests`) over the
  real captured packet sequence guard it; full post-mortem in `wiki/`.
- **`ffprobe`'s displayed DTS is not what `av_read_frame` delivers.** ffprobe
  reconstructs a clean monotonic DTS; the libavformat API hands this stream
  `dts == pts`. When debugging the remux, instrument the loop (`GM_TS_DEBUG=1`
  prints the raw per-packet timestamps), don't trust the probe's DTS column.
- **HDR/EDR is automatic.** AVKit drives PQ/HLG -> EDR on capable displays; no
  layer/colorspace poking needed (forcing it caused a slow compositing path).
  The telemetry HUD reports live `NSScreen` EDR headroom.
- **HDR detection can't rely on the HLS track descriptions.** For an HLS (`m3u8`)
  asset AVFoundation does not surface the per-track transfer function, and the
  matroska container often leaves `color_trc` unspecified for HEVC (PQ/HLG live in the
  SPS VUI). So HDR is detected by muxing the init + first segment, handing those bytes
  to an `AVAsset`, and reading the transfer function the way AVFoundation parses the
  HEVC SPS for a file. The result is passed to the playback monitor, so the HUD is
  correct on every engine. (Playlist-level `VIDEO-RANGE`/`colr` signalling for EDR
  *rendering* over HLS is a tracked follow-up.)
- **The streaming engine sets the AVPlayer waiting policy per transport.** HLS
  loopback uses `automaticallyWaitsToMinimizeStalling = true` (Apple's documented HLS
  behavior; it auto-resumes after a buffer-drained stall, which a far seek over the
  network can cause). The single-file/batch path keeps it `false` + `playImmediately`
  to skip the many-`moof` buffering evaluation. Mixing them up froze playback after a
  far seek; see the huge-MKV wiki write-up.

## License

GMApplePlayer is released under the [MIT License](LICENSE), © 2026 Gaston Morixe.

It links FFmpeg 8.1.1, built remux-only (no GPL components) under the LGPL-2.1+.
The repository ships no FFmpeg binaries or source: `Scripts/build-ffmpeg.sh`
downloads and checksum-verifies the official source at build time. See
[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) for details.
