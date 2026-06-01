# On-demand streaming remux (no server, no full download)

**Goal.** Play an MKV (HEVC/HDR/DoVi + AC-3/E-AC-3) through `AVPlayerViewController` on
macOS / iOS / tvOS, **remote or local**, starting in ~1-2s and fetching only the
bytes actually watched. No embedded HTTP server, no full pre-download, no full
pre-remux. Seeking must be cheap (jump + fetch that region, not the prefix).

This supersedes the current "download + remux the whole file to a temp MP4, then
play" path (`GMPlayerModel.start` → full `gm_remux_to_fmp4` → `beginPlayback`),
which on a 924 MiB file over a slow origin means minutes of "Preparing…".

## Why the obvious approaches don't work (and what does)

- **Monolithic progressive MP4 (play while it writes).** Easy, but AVPlayer can't
  seek: to map a seek-target byte offset to a time it would need the file muxed up
  to that offset. Forward seeks past the buffer stall; backward re-reads. Rejected
  as the primary design (kept as a fallback only).
- **Monolithic fragmented MP4 with a global `sidx`.** `sidx` gives time→byte, but a
  *global* sidx requires knowing every fragment's size up front = mux the whole
  file. Defeats on-demand. Rejected.
- **HLS of fMP4 segments, addressed by TIME, served by the resource loader.**
  Decouples time from any global byte layout. Each ~4s segment is independently
  decodable and generated on demand by seeking the input. Seeking = pick the
  segment covering the target time and fetch only that. **This is the design.**
  It's what Infuse / VLC-on-Apple / Plex DirectStream do.

## Verified spikes (against OUR FFmpeg build, the real sample MKV)

1. **Custom-AVIO byte-range input works.** A standalone C spike (`avio_alloc_context`
   with read/seek callbacks backed by HTTP `Range:` GETs) opened the remote
   924 MiB MKV, probed it, **seeked to 90s, and read the next video packet using
   only 3.0 MiB total** (2.0 to open+probe, 1.0 for the seek). Proof that on-demand
   input needs no prefix download. Server confirmed `accept-ranges: bytes`.
2. **Fragmented fMP4 output is AVFoundation-playable.** `mov` muxer with
   `+frag_keyframe+empty_moov+default_base_moof+delay_moov` (the `delay_moov` is
   required: E-AC-3/AC-3 can't write the moov until the first packet is parsed)
   produces `ftyp + moov(~2KB init) + moof/mdat…`. `AVURLAsset` reports
   `isPlayable=true, nominalFrameRate=23.976, duration=187.968s, 2 tracks`.

Both halves are green. The DTS fix (`gm_ts_next`) already lands the per-frame
timestamps correctly and is reused unchanged in the segment muxer.

## Components

```
┌──────────────────────────────────────────────────────────────────────────┐
│ Swift (GMPlayerKit)                                                        │
│                                                                            │
│  GMPlayerModel ──makes──► AVURLAsset(url: "gmstream://<id>/master.m3u8")   │
│        │                         │ resourceLoader.delegate                 │
│        │                         ▼                                         │
│        │             GMStreamingResourceLoader  (AVAssetResourceLoader-    │
│        │                 Delegate, NO server)                              │
│        │                  ├─ master.m3u8   → built from input keyframe map │
│        │                  ├─ init.mp4      → muxed once                    │
│        │                  └─ seg<N>.m4s    → muxed on demand               │
│        │                         │ calls                                   │
│        ▼                         ▼                                         │
│  AVPlayerViewController    StreamingMediaEngine (Swift) ──► CGMStream (C)  │
│   (UNCHANGED wrapper)                                                       │
└──────────────────────────────────────────────────────────────────────────┘
                                          │ C engine (new target CGMStream)
                                          ▼
        gm_stream_open(source)         input AVIO  ◄── read/seek callbacks
        gm_stream_init_segment(...)        │            (Swift provides bytes)
        gm_stream_segment(n, buf, ...)     ▼
        gm_stream_keyframes(...)       matroska demuxer → gm_ts_next → mov
        gm_stream_close()                  frag muxer → output AVIO → buffer
```

Two custom AVIO contexts wrap one demux→mux pipeline:

- **Input AVIO** (`read`/`seek`): bytes come from Swift. Local file = `pread`;
  remote = HTTP `Range:` GET via `URLSession`. Same C code path; the byte source
  is a Swift callback, so local and remote are identical below the source.
- **Output AVIO** (`write`/`seek`): the fragmented-MP4 muxer writes into a growable
  memory buffer for the current segment; we hand that buffer back to the loader.

## Data flow

1. **Open.** `gm_stream_open` opens the input (one ranged read of the MKV header +
   first cluster, ~2 MiB), runs `find_stream_info`, picks the AVFoundation-compatible
   video+audio (reuse `gm_auto_select`), reads the **keyframe index** (Matroska Cues
   near EOF, one ranged read; fallback: a light packet scan). Builds the segment
   plan: boundaries at keyframes grouped into ~4s segments. Cheap, no media bytes.
2. **Playlist.** The loader answers `master.m3u8` from the segment plan
   (`#EXTINF` per segment from keyframe deltas; `#EXT-X-MAP:URI="init.mp4"`;
   all URLs use the `gmstream://` scheme so the loader sees every request).
3. **Init segment.** `init.mp4` = `ftyp+moov` muxed once (empty_moov+delay_moov),
   cached.
4. **Segment N.** On request: seek input to segment N's start keyframe (cheap), mux
   frames in `[start_N, start_{N+1})` to one self-contained `moof+mdat` fragment via
   the output AVIO, return the buffer. DTS via `gm_ts_next`; PTS exact. Stream copy
   only (no transcode), measured at hundreds of × realtime, so CPU is negligible;
   the only real cost is fetching that segment's input bytes.
5. **Seek.** AVPlayer maps the seek time to the covering segment (from `#EXTINF`),
   requests just that `seg<N>.m4s`. We fetch only that region. No prefix read.

## Threading / backpressure

- The loader is asked for segments slightly ahead of the playhead; AVPlayer paces
  the requests, so backpressure is automatic (we never run ahead of demand).
- Each segment is generated on a worker queue; the loader request is satisfied
  asynchronously (`AVAssetResourceLoadingRequest.finishLoading()` when ready).
- Cache the last K segments + the init segment (small LRU) so short back-seeks and
  re-buffers don't refetch. No giant in-RAM buffer; bounded by K·segment-size.
- Cancellation: AVPlayer cancels loading requests on seek; map that to cancelling
  the in-flight input `URLSession` task and aborting the segment mux.

## Local AND remote (one path)

`open(fileURL:)` and `open(remoteURL:)` both produce a `gmstream://` asset; the only
difference is the input-source callback the engine is given:
- **local**: `FileHandle`/`pread` over the path (fast, seekable).
- **remote**: `URLSession` ranged GETs (proven 3 MiB to open+seek).
Everything above the source (segmenting, muxing, the loader, the player) is shared.
So macOS opening a local `.mkv` behaves like a normal seekable player, and tvOS
opening an `https://…mkv` streams on demand, through identical code.

## AVPlayerViewController stays unchanged

`GMPlayerView` (the `UI/NSViewControllerRepresentable` over `AVPlayerViewController`)
does not change. It still gets a plain `AVPlayer` whose current item is the
`gmstream://` `AVURLAsset`. Native transport bar, scrubbing, PiP, HDR/EDR, and the
Liquid Glass chrome all keep working because to AVKit this is just an HLS asset.

## Platform notes

- **Resource-loader + custom-scheme HLS** is supported on macOS 12+/iOS 15+/tvOS 15+
  (our deployment targets). Use a single **media** playlist (not master) to dodge
  older master-playlist-via-loader quirks. Every URI in the playlist must use the
  custom scheme or the loader won't be asked for it.
- **tvOS**: no local files normally, remote is the main path, already covered.
- **HDR10/DoVi P7** survives: fragmentation is container-only; the HEVC bitstream
  (incl. DoVi RPU) is stream-copied untouched, same as the batch remux today.
- **App Transport Security**: remote `https://` is fine; if any source is `http://`
  the existing ATS exception applies (unchanged).

## Risks / mitigations

- **No Cues in a pathological MKV** → fall back to a one-time light packet scan for
  keyframes (bounded), or to the progressive-monolithic fallback for that file.
- **E-AC-3/AC-3 init** needs `delay_moov` (verified). The init segment is emitted
  after the first audio packet is parsed; we generate it from a tiny prefix mux.
- **Segment boundary must be a video keyframe** so each segment is decodable; we
  align boundaries to the input keyframe list.
- **Fallback**: keep the current batch `gm_remux_to_fmp4` engine behind the
  `MediaEngine` seam. If streaming open fails (unindexed/odd source), fall back to
  the batch path so playback still works.

## Build order

- **Phase C**: C engine `CGMStream` (dual AVIO, segment muxer, keyframe plan),
  reusing `gm_ts_next`. Pure unit tests for the segment/keyframe math.
- **Phase D**: `GMStreamingResourceLoader` (AVAssetResourceLoaderDelegate) +
  Swift bridge; tests with a fake engine.
- **Phase E**: `StreamingMediaEngine` behind the `MediaEngine` seam; `GMPlayerModel`
  starts playback on the `gmstream://` asset immediately; local + remote.
- **Phase F**: macOS/iOS/tvOS builds, tests, manual play (fast first frame + seek),
  lint, commit.

---

## UPDATE (2026-06-01): the resource-loader transport was a dead end

This plan's "no server / AVAssetResourceLoaderDelegate" transport DOES NOT WORK on
Apple platforms. AVFoundation will not let a resource loader vend HLS media-segment
bytes (only playlists, keys, redirects); vending segment data fails with
`AVPlayerItem` -12881. The engine output (segments) is correct, it plays fine over
HTTP, so the fix is a loopback HTTP server (127.0.0.1, ephemeral port, in-process).

Everything else in this plan held: the dual-AVIO C engine, the keyframe/uniform
segment plan, GMStreamSession, init/segment generation, the local+remote byte
sources, AVPlayerViewController unchanged. Only the transport changed (loader ->
loopback server) and GMHTTPByteSource was hardened to return clean EOF on 416/past
-EOF range requests (a backward-seek hang).

Full post-mortem (dead ends, the -15514 red herring, evidence):
`wiki/20260601T051137-on-demand-streaming-loopback-server-postmortem.md`.
