# On-demand MKV streaming on Apple platforms: what didn't work, what did, and why

**Date:** 2026-06-01
**Outcome:** Shipped. An MKV (local file or remote http(s)) plays through
`AVPlayerViewController`/`AVPlayerView` with ~1-2s time-to-first-frame and working
seek, fetching only the bytes watched. No full download, no full pre-remux. Verified
decoding 4K HEVC HDR (VideoToolbox: frames decoded, 0 dropped) + E-AC-3 audio on
macOS and the tvOS simulator.

This documents the dead ends in order, because the wrong turns are the useful part.
Two separate sub-agents independently reached the same wrong conclusion on the way;
the section "The -15514 red herring" exists so nobody repeats it.

## The starting problem

Opening a 924 MB remote MKV showed "Preparing… 21%" for minutes. The original
pipeline downloaded AND remuxed the whole file to a temp MP4 before the first frame
(`probe -> gm_remux_to_fmp4(WHOLE file) -> play(temp)`). At the origin's real speed
that is tens of minutes. The goal: demux on demand, fetch only what's played.

## What we built that was correct (and stayed)

- **`CGMStream`** C engine: a dual-AVIO pipeline. Input AVIO pulls bytes from a
  caller callback (local `pread` or HTTP byte-range GET); output AVIO muxes
  fragmented-MP4 segments on demand. Keyframe-aligned (or uniform-grid) segment
  plan. Reuses the DTS-fix ladder (`gm_ts_next`).
- **HLS of fMP4 segments addressed by time** (init.mp4 + segN.m4s + a VOD media
  playlist). Each ~6s segment is independently decodable and produced on demand by
  seeking the input cheaply.
- This output is CORRECT: the segments play perfectly in AVFoundation **when fetched
  over HTTP** (readyToPlay, video decoded 3840×2160, time advancing across segment
  boundaries). Proven repeatedly.

The engine was never the problem. Every failure below was transport.

## Dead end #1: AVAssetResourceLoaderDelegate (the "no server" design)

The plan was elegant: a custom `gmstream://` scheme + an
`AVAssetResourceLoaderDelegate` that vends the playlist, init, and segment bytes
straight from the engine. No socket, no server.

**It cannot work, by Apple design.** Playback failed with
`AVPlayerItem` error **-12881**. The trace showed the delegate was called, served
the playlist + init + seg0 (all bytes delivered), then CoreMedia rejected it.

The reason, confirmed two ways:
- Apple DTS (developer forums): "iOS only allows the following to be returned via
  AVAssetResourceLoaderDelegate for HTTP Live Streaming media: key requests,
  playlist, media redirects."
- Apple Staff, precisely: "The only response to an AVAssetResourceLoadingRequest for
  a segment that AVPlayer will accept is a **redirect** to an HTTP URL.
  respondWithData will be rejected." And: "the same limitation exists with **any**
  media segment (TS, fMP4, packed audio, …)." AVFoundation insists on fetching
  segment bytes itself (it drives bitrate adaptation).

So the delegate may serve the **playlist** and **keys** and may **302-redirect** a
segment to HTTP, but it may NOT hand over segment bytes. Our whole point was to hand
over bytes we hold in memory. Redirect-only is useless for that. The custom-scheme
no-server approach is architecturally impossible for HLS media on Apple platforms.

The literal CoreMedia error string for -12881 is "custom url not redirect", which is
the giveaway: the player wanted a redirect and got data.

## The -15514 red herring (why two analyses were wrong)

CoreMedia logged `<<HLS-FASB>> signalled err=-15514` right before the failure. Both
a prior sub-agent and a second one concluded: "your fMP4 segments are malformed
CMAF, they're missing the `styp` box; add the `+dash` movflag to fix it."

**That conclusion is false, and provably so.** The single discriminating test:
- Serve the EXACT same segments over plain HTTP and play them.
- They play perfectly (decoded 4K video, advancing time).
- And the "successful" HTTP playback emits `-15514` **three times** too.

`-15514` (HLS-FASB) is a benign log AVFoundation prints during normal HLS-fMP4
parsing, in both success and failure. Pattern-matching a scary error code to a format
theory without running the A/B test (HTTP vs loader) is the trap. The real
discriminator is `-12881`: zero occurrences over HTTP, present only through the
resource loader. `+dash` was tried; it added redundant `sidx` boxes, never produced a
leading `styp`, and did NOT fix the loader failure. It was reverted.

Lesson: when an error code appears, check whether it ALSO appears on the success
path before blaming it. A/B the one variable that differs (here: transport).

## What worked: a loopback HTTP server

The documented path (used by Infuse, VLCKit, KTVHTTPCache, VIMediaCache, and Apple's
own guidance) is a small HTTP server the app fetches from.

`GMLoopbackServer` (Network.framework `NWListener`):
- Binds to **127.0.0.1 only** (`requiredInterfaceType = .loopback`), on an
  OS-assigned **ephemeral port**. In-process, lives and dies with the player,
  reachable only from inside this process. Nothing is exposed to the network. This
  is not a "web service"; it's the minimal socket the OS forces for this job.
- Serves `GET /index.m3u8`, `/init.mp4`, `/segN.m4s` from `GMStreamSession` (the
  same engine output that already plays over HTTP), with byte-range (206) support.
- AVPlayer plays `http://127.0.0.1:<port>/index.m3u8`. To AVKit it's a normal HLS
  asset, so native controls/scrubbing/PiP/HDR + ABR all work, and
  `AVPlayerViewController` is unchanged.

Result: decodes immediately, seeks cheaply, local + remote, on macOS/iOS/tvOS.

## Dead end #2: 416 past-EOF responses treated as data (the seek-back hang)

After the server worked, a BIG BACKWARD seek hung forever buffering. The user's
server log was the proof: AVFoundation issued ranged GETs **starting past the file
end** (offset 973003902 > size 969251142). The server correctly returned
**416 Range Not Satisfiable** with a ~33-byte error page. `GMHTTPByteSource` only
special-cased status 200, so for 416 it fed those 33 error-page bytes to FFmpeg as
media. The demuxer advanced 33 bytes, re-requested, got the same page, forever.

This only affected the HTTP source; local files use `pread`, which returns clean EOF
past the end, so local seeks always worked (a telling asymmetry).

Fix in `GMHTTPByteSource.read`:
- short-circuit reads at/after EOF (`offset >= totalSize`) → 0 (clean EOF).
- only 200/206 bodies are media; 416 → EOF; any other non-2xx / transport error →
  -1 (I/O error) so the demuxer fails fast instead of ingesting an error page.

Verified: forward to 90%, then jump back to 10% resumes instantly.

## Component map (final)

```
AVPlayerViewController / AVPlayerView   (unchanged)
        │ plays
        ▼
http://127.0.0.1:<port>/index.m3u8
        │ served by
        ▼
GMLoopbackServer (Network.framework, 127.0.0.1, ephemeral port)  ← the transport
        │ calls
        ▼
GMStreamSession ──► CGMStream (gm_stream.c): dual AVIO, on-demand fMP4 segments
        ▲                       │ input bytes from
        │                       ▼
        │              GMByteSource:  local pread  |  remote URLSession Range GET
        └─ playlist / init / segN built on demand; init cached
```

Streaming-first in `GMPlayerModel`; falls back to the batch remux if streaming open
fails (e.g. an unseekable or unusably-slow source). Track reselection forces batch
(streaming auto-selects the best video+audio).

## Files

- `Sources/CGMStream/{gm_plan,gm_stream}.c` + headers: on-demand engine (unchanged
  by the transport fix; its output was always correct).
- `Sources/GMPlayerKit/Streaming/GMLoopbackServer.swift`: the loopback HTTP server.
- `…/Streaming/GMByteSource.swift`: local + remote input sources (EOF/416 hardened).
- `…/Streaming/GMStreamSession.swift`: playlist/init/segment generation.
- `…/Streaming/GMStreamingEngine.swift` + `GMStreamingPlayback.swift`: build the
  asset + own the server.
- `…/Model/GMPlayerModel.swift`: streaming-first with batch fallback.
- REMOVED: `GMStreamingResourceLoader.swift` (the proven dead end).
- Tests: `CGMStreamTests` (plan math), `GMStreamSessionTests` (engine via the bridge),
  `GMLoopbackServerTests` (serves over HTTP + AVPlayer reaches readyToPlay, the case
  that failed at -12881). 44 tests green.

## Lessons

1. `AVAssetResourceLoaderDelegate` can't vend HLS segment bytes. For on-demand local
   muxing → AVPlayer, you need a loopback HTTP server. This is not optional.
2. Don't trust a scary error code until you've checked the SUCCESS path for it.
   `-15514` was benign; `-12881` was the real one. The A/B (HTTP vs loader) settled it
   in one test.
3. A custom byte source must treat only 200/206 as data. 416/4xx/5xx error pages are
   not media; feeding them to a demuxer causes infinite re-reads.
4. `AVPlayerItem.status == .readyToPlay` and "the playlist parsed" are NOT proof of
   playback. Verify decode: VideoToolbox frame counts, `rate > 0`, advancing time.
   (An earlier "tvOS streaming works" claim was wrong because it only checked the
   plan/attach, not decode.)
