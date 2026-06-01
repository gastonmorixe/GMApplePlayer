# GMApplePlayer: Plan & Architecture

A multiplatform (macOS / iOS / tvOS) SwiftUI app that plays MKV files (local or
remote) through Apple's native `AVPlayerViewController`, using FFmpeg 8.1.1
**linked directly into the app** to remux (stream-copy, no transcode) the MKV
into a fragmented MP4 that AVFoundation can play. No embedded web server.

## Why FFmpeg is required at all

AVFoundation cannot open Matroska (`.mkv`) containers. It has no MKV demuxer.
But the *elementary streams* inside a typical MKV (HEVC/H.264 video, AAC/AC-3/
E-AC-3 audio) are codecs AVFoundation decodes natively. So the job is not to
decode anything, it is to **repackage** (remux) the same compressed bytes from
the Matroska container into an ISO-BMFF (MP4/MOV) container. That is a pure
stream copy: zero quality loss, low CPU, fast.

## The hard platform constraints (discovered by probing, not assumed)

These come from `ffprobe` on the acceptance file plus Apple platform limits.
They define what "plays beautiful" can honestly mean.

| Element                         | In a typical premium MKV         | AVFoundation reality                          | Our policy                                    |
| ------------------------------- | -------------------------------- | --------------------------------------------- | --------------------------------------------- |
| Container                       | Matroska                         | Not supported                                 | Remux to fragmented MP4                       |
| HEVC Main10 (HDR10, BT.2020/PQ) | yes                              | Supported, tag must be `hvc1` (not `hev1`)    | Stream-copy, force `hvc1` tag                 |
| Dolby Vision **Profile 7**      | dual-layer (BL+EL+RPU), Blu-ray  | **Not playable** (Apple supports P5 / P8.x)   | Drop EL/RPU; base layer plays as **HDR10**    |
| H.264                           | sometimes                        | Supported, tag `avc1`                         | Stream-copy                                   |
| AAC                             | common                           | Supported                                     | Stream-copy (+ `aac_adtstoasc` bsf if needed) |
| AC-3 / E-AC-3 (Dolby Digital)   | common                           | Supported (mac/tvOS/iOS)                      | Stream-copy                                   |
| TrueHD / DTS / DTS-HD          | premium tracks                   | **Not supported** by AVFoundation             | Skip; pick a compatible audio track instead   |
| FLAC / Opus / Vorbis in MP4     | sometimes                        | Not reliably supported in MP4 on all OSes     | Skip for now (out of remux-only scope)        |

Key implication: we do **not** hardcode anything about the acceptance file. At
runtime the remuxer probes every stream and selects, per a compatibility table,
which streams to copy. If a file's only audio is TrueHD, the remux still produces
video; audio handling degrades gracefully (documented). We never transcode.

### Dolby Vision detail (verified in FFmpeg 8.1.1 source)

`libavformat/movenc.c` only writes the DoVi configuration boxes (`dvcC`/`dvvC`)
when `strict_std_compliance <= unofficial`; otherwise it logs and omits them.
For Apple HDR10 playback of a P7 base layer we specifically **do not** want the
P7 DoVi boxes (Apple can't use them and they can confuse the parser), so we keep
strict at the default and let the HEVC HDR10 base layer carry BT.2020+PQ. Result
on Apple displays: proper 4K HDR10.

## Architecture

```
            ┌────────────────────────── App (SwiftUI) ──────────────────────────┐
            │  ContentView: Open File (native picker) | Open URL | Play          │
            │        │                                                           │
            │        ▼                                                           │
            │  GMPlayerModel  ──(source: file URL or http URL)──►  GMRemuxer     │
            │        │                                                  │        │
            │        │                                                  ▼        │
            │        │                                   ┌── GMPlayerKit (SPM) ──┐│
            │        │                                   │  GMRemuxer (Swift)    ││
            │        │                                   │     │ calls           ││
            │        │                                   │     ▼                 ││
            │        │                                   │  CFFmpeg (libav*)     ││
            │        │                                   │  avformat/avcodec/... ││
            │        │                                   └───────────────────────┘│
            │        │                                                  │        │
            │        │   fragmented .mp4 (temp file, seekable)  ◄───────┘        │
            │        ▼                                                           │
            │  GMPlayerView  ── wraps ──►  AVPlayerViewController (AVKit)         │
            │   (UIViewControllerRepresentable / NSViewControllerRepresentable)  │
            └────────────────────────────────────────────────────────────────────┘
```

### Components

- **CFFmpeg**: SPM system-library/binary target. A `module.modulemap` exposes
  the FFmpeg C headers to Swift; the actual code is `FFmpeg.xcframework`
  (static libs for macOS/iOS/tvOS, device + simulator).
- **GMPlayerKit**: Swift package with:
  - `GMRemuxer`: opens input via `libavformat`, probes streams, selects
    AVFoundation-compatible ones, stream-copies them into a fragmented MP4.
  - `GMStreamInfo`: value type describing probed streams (codec, type, lang).
  - `GMPlayerView`: SwiftUI representable wrapping `AVPlayerViewController`,
    one type that compiles on UIKit (iOS/tvOS) and AppKit (macOS).
  - `GMPlayerModel`: `@MainActor ObservableObject` orchestrating remux → player.
- **App**: thin SwiftUI shell + Info.plist + entry point. Generated into an
  Xcode project by **XcodeGen** with three app targets (mac/iOS/tvOS) sharing
  one source set.

## Remux strategy: file-mode first (chosen), direct-mode documented

Two ways to get FFmpeg output into AVPlayer without a web server:

1. **File-mode (chosen for the acceptance path).** Remux to a fragmented MP4
   written to `NSTemporaryDirectory()`, then `AVPlayer(url: tempFileURL)`.
   - Pros: dead simple, fully seekable, robust, AVPlayer owns playback 100%.
     Honors "no web server" and "FFmpeg linked directly" (libav* reads the
     source in-process and writes fMP4).
   - Cons: needs temp disk space (we use fragmented MP4 so playback can start
     before the whole remux finishes; AVPlayer tolerates a growing file with
     `+frag_keyframe+empty_moov+default_base_moof`).
   - Remote inputs: `libavformat` opens `http(s)://` directly with byte-range
     support (the `http` protocol), so the same path serves remote URLs.

2. **Direct-mode (designed, optional/advanced).** `AVAssetResourceLoaderDelegate`
   with a custom URL scheme; libavformat reads the source through a custom
   `AVIOContext` (`avio_alloc_context` with read/seek callbacks) and remuxes
   into an in-memory fragmented MP4 served back to the loader in byte ranges.
   No temp file, no server. More moving parts (seek mapping is fiddly), so it is
   documented and stubbed but not on the acceptance critical path.

Both satisfy "no embedded web server" and "hook FFmpeg libraries directly."
File-mode is what we verify against the acceptance file.

## FFmpeg build: remux-only, minimal

Confirmed component identifiers against the FFmpeg 8.1.1 source tree:

- Demuxers: `matroska` (covers webm), `mov`, `mpegts`, plus `hls` for remote.
- Muxers: `mov`, `mp4`.
- Parsers: `hevc`, `h264`, `aac`, `aac_latm`, `ac3`, `av1`, `mpegaudio`, `flac`,
  `opus`, `vorbis`, `dca`, `vp9`, `vp8`.
- Bitstream filters: `hevc_mp4toannexb`, `h264_mp4toannexb`, `aac_adtstoasc`,
  `extract_extradata`, `vvc_mp4toannexb` (for completeness).
- Protocols: `file`, `http`, `https`, `tcp`, `tls`, `crypto`, `data`.
- No encoders, no decoders, no `swscale`/`swresample`/`avfilter`/`avdevice`
  (remux needs none of them). `--disable-everything` then re-enable the above.

Per-platform matrix (all arm64; Apple silicon dev machine + modern devices):

| Platform        | SDK                    | min-version flag             |
| --------------- | ---------------------- | ---------------------------- |
| macOS arm64     | macosx                 | `-mmacosx-version-min=12.0`  |
| iOS arm64       | iphoneos               | `-mios-version-min=15.0`     |
| iOS sim arm64   | iphonesimulator        | `-mios-simulator-version-min=15.0` |
| tvOS arm64      | appletvos              | `-mtvos-version-min=15.0`    |
| tvOS sim arm64  | appletvsimulator       | `-mtvos-simulator-version-min=15.0` |

Assembled with `xcodebuild -create-xcframework` from the per-slice static libs
(`libavformat.a libavcodec.a libavutil.a`) + headers.

## Risks / mitigations

- **HEVC `hvc1` vs `hev1`.** AVFoundation needs `hvc1`. We force the codec tag
  on the output stream (the KSPlayer trick: reuse CoreMedia's
  `kCMVideoCodecType_HEVC` value, big-endian). Mitigation verified in source.
- **`moov` placement / start latency.** Use fragmented MP4
  (`+frag_keyframe+empty_moov+default_base_moof`) so no full-file `moov` rewrite
  and playback starts quickly.
- **Cross-compile of `tls`/`https`.** Use the system SecureTransport via
  `--enable-securetransport` (or fall back to disabling https and using http if
  TLS proves troublesome on a slice). macOS path is the acceptance target.
- **tvOS bitcode / no-fork.** Configure with `--disable-programs` (no CLI tools,
  which use fork/exec); we only need the libs. Good for tvOS sandbox.
- **DoVi P7.** Out of scope to "fix"; documented as HDR10 fallback.

## Acceptance

The **Dolby Vision Universe** demo (`~/Movies/Dolby Vision Universe demo (4K HDR HEVC).mkv`,
override with `GM_TEST_MKV`)
plays in the Mac app via remux: 4K HDR10 HEVC video + AC-3 5.1 audio, with
working seek. iOS/tvOS targets build and run the same code path. Honest scope:
no DoVi P7, no TrueHD/Atmos (AVFoundation limits, documented).
