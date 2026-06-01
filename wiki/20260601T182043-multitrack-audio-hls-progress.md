# Multi-track audio (alternate audio in the native picker): progress + the one remaining fix

**Date:** 2026-06-01
**State:** Phase A (alternate AUDIO renditions) is wired end to end and gated behind
`GM_MULTIVARIANT=1`. The default loopback path is unchanged (single muxed media
playlist), still plays everywhere, 61 tests green. One blocker remains before flipping
the multivariant master on by default.

## Goal

The native AVKit picker (AVPlayerViewController / AVPlayerView) should list every
audio track of an MKV (a remux with 4 playable AC-3 tracks; a DoVi demo with AC-3 + E-AC-3) and let the user
switch, without eager-demuxing all tracks. The user's framing: tracks must SHOW in the
list, but a track's segments are muxed only when actually selected.

## What's done (committed)

- **Track enumeration** (`694f623`): `gm_stream_track_*` + `GMStreamSession.tracks` with
  codec/language/title/channels/width/height/default/avfCompatible/isTextSubtitle and a
  friendly `displayName`. Harness `GM_TRACKS`.
- **Demuxed per-rendition muxer** (`9053e4b`): `produce_sel(gm_sel{vid_src,aud_src})`;
  `gm_stream_video_init/_segment` and `gm_stream_audio_init/_segment(source:)`. Each
  rendition opens as a valid single-track AVAsset standalone (harness `GM_DEMUX`).
- **Playlists** (`e7e5a35`): `masterPlaylist` (video variant + EXT-X-MEDIA audio group),
  `videoPlaylist`, `audioPlaylist(source:)`. Harness `GM_MASTER`.
- **Server routing + engine + validator fixes** (`00516de`): `GMLoopbackServer` routes
  `/master.m3u8`, `/video/*`, `/audio/<src>/*` on demand (legacy `/index.m3u8` etc still
  work); engine uses `master.m3u8` only when `GM_MULTIVARIANT=1`. Harness `GM_TREE`
  writes a full on-disk HLS tree for Apple's `mediastreamvalidator` (/usr/local/bin).

## Debugging with the authoritative tool

`mediastreamvalidator /tmp/hlsval/master.m3u8` (Apple's own HLS validator, present after
the Xcode tools install) is the way to debug AVPlayer's opaque `-12927`/`-12646`. Build
the tree with `GM_TREE=<audioSrc> gmstreamtest <file> loopback 6.0`.

Errors found and FIXED:
- `-12927` "EXT-X-MEDIA: duplicate name ... for rendition group": REMUX files reuse
  track titles (3x "Surround 5.1"). Fix: dedupe NAMEs (`#1/#2/#3`).
- "Variant requires playlist declared video range" + "video resolution doesn't match":
  HEVC variants REQUIRE `RESOLUTION=WxH` and `VIDEO-RANGE=PQ|SDR` on EXT-X-STREAM-INF.
  Fixed (track width/height added to the C info).
- "Measured peak bitrate exceeds declared": BANDWIDTH was 8 Mbps vs ~27 Mbps real.
  Fixed (derive from sourceTotalSize/duration).
- "Playlist channel count does not match parsed": container said 4 ch for an E-AC-3 that
  decodes to 7.1. Fixed by OMITTING CHANNELS (it's optional).

After those, the error moved `-12927 -> -12646`, i.e. past variant selection into
segment loading.

## UPDATE (later same day): root cause refined with mediastreamvalidator

Fixed (committed 82cd555), each one a separate validator MUST-fix error:
- LANGUAGE must be RFC5646 ("en", not the 639-2 "eng" MKV stores). Added
  Track.bcp47Language.
- CODECS must list EVERY distinct audio codec in the group (e.g. "hvc1,ac-3,ec-3"),
  not just one, or the E-AC-3 default isn't covered.
- RESOLUTION + VIDEO-RANGE are REQUIRED on an HEVC EXT-X-STREAM-INF.
- Omit CHANNELS (container count disagrees with decoded E-AC-3).

With those, the STATIC on-disk tree (GM_TREE harness, which MEASURES each segment's
real duration via AVAsset and writes it as EXTINF) validates CLEAN (zero MUST-fix).

The TRUE remaining blocker is the segment-duration model, and the earlier "align audio
to video keyframes" idea was WRONG: AC-3 audio frames are 32ms and cannot split at
arbitrary video keyframe times, so forcing audio onto video keyframe boundaries makes
audio segments OVERLAP (seg0 audio ends at 6.43 but seg1 audio starts at 6.34) and
AVPlayer hangs. Correct model (what real packagers do): each rendition tiles on its OWN
frame boundaries with its OWN EXTINF durations; video=6.34/6.05..., audio=6.0/6.0...;
they are NOT equal and that is FINE. AVPlayer aligns the demuxed renditions by absolute
tfdt timestamps, not by matching segment lengths. The media playlists therefore must
declare each rendition's OWN real per-segment durations.

Measured proof (Dolby, GM_TREE): video durs [6.339, 6.047, 6.047, 6.047], audio durs
[6.016, 5.984, 6.016, 5.984] (with independent tiling). The static tree with THESE
exact EXTINFs validates clean.

NEXT STEP (the actual finish): make the live mediaPlaylist emit each rendition's OWN
real per-segment EXTINF without producing every segment at OPEN. Options:
  (a) Add gm_stream_real_video_segment_duration(i) and gm_stream_real_audio_segment_-
      duration(src,i) that compute the real span via a cheap keyframe/frame probe
      (the resolve_real_end infra is already there for video; add the audio analogue:
      the audio segment spans whole audio frames within [seg_starts[i], seg_starts[i+1]),
      so its real end is the first audio frame pts >= seg_starts[i+1]). Cache both.
  (b) Have videoPlaylist use the video real durations and audioPlaylist(source:) use that
      source's real durations. They differ; that's correct.
Then re-run GM_TREE + mediastreamvalidator until clean AND GM_MULTIVARIANT=1
GM_PLAYTHROUGH reaches readyToPlay + plays, switch audio, and only THEN remove the
GM_MULTIVARIANT gate (flip engine default to master.m3u8). Verify the 4-AC-3 remux + a
huge REMUX.

Note: raw AVPlayer on the validator-clean STATIC tree was still status=unknown after
25s in the headless harness (likely the harness/runloop, not the stream, since the
validator passes it). Verify in-app (GM_OPEN) or with AVPlayerViewController, not the
headless probe, once the live playlists emit real durations.

## THE ONE REMAINING FIX (the blocker) [SUPERSEDED: see UPDATE above]

Validator: **"Playlist vs segment duration mismatch, Segment duration 6.3400, Playlist
duration: 6.0000"**.

Root cause: the segment PLAN is a uniform 6.0s grid (`gm_plan_uniform`, used for
sparse-index files like Dolby), but the video muxer uses keyframe-exact tiling: a
segment ENDS at the first video keyframe with pts >= seg_end, so it OVERSHOOTS to ~6.34s.
The audio rendition is time-windowed to exactly [seg_start, seg_end) = 6.0s. So:
1. EXTINF (6.000, from the plan) != the real video segment span (6.34) -> spec violation.
2. Video (6.34) and audio (6.0) renditions don't tile identical windows -> demuxed HLS
   needs aligned boundaries.

The fix (correct, not yet applied): make the segment boundaries land on REAL video
keyframe times so plan == muxed span, and have BOTH video and audio segments + the
EXTINF use those exact boundaries. Concretely:
- Build the segment plan from actual keyframe timestamps. For dense-index files the
  keyframe index already exists (gm_plan_segments path). For sparse-index files (Dolby),
  either (a) do a one-time lightweight keyframe scan at open to get real boundaries, or
  (b) produce the video segment first, record its actual end pts, and feed that as the
  audio window + the EXTINF (a "produce then report real duration" model).
- Option (b) fits the lazy model best: add a C accessor that returns the actual end time
  of video segment i (the muxer already computes `actual_end` in produce_sel; expose it),
  cache per-segment real boundaries as they're produced, and:
    - audioSegment(source,i) muxes [real_start(i), real_end(i)) instead of the planned grid;
    - videoPlaylist/audioPlaylist EXTINF(i) = real_end(i) - real_start(i).
  The catch: the playlist is requested before segments are muxed. Resolve by computing
  real boundaries lazily and regenerating/【EXT-X-】 the playlist on demand, OR do the
  cheap keyframe scan at open (option a) so boundaries are known up front. Given a movie
  is VOD and the keyframe cadence is regular, a one-time scan of the video stream's
  packet keyframe flags at open (bounded, local files are instant; remote already streams)
  is the simplest correct path and makes EXTINF exact for both renditions.

Once boundaries align: re-run `GM_TREE` + `mediastreamvalidator` until zero MUST-fix
errors, then `GM_MULTIVARIANT=1 GM_PLAYTHROUGH` should reach readyToPlay and play with a
switchable audio list. Then flip the engine default to `master.m3u8` (remove the gate),
verify on the 4-AC-3 remux + the DoVi demo + a huge REMUX, and confirm the native
picker shows + switches audio.

## Files

- C muxer: `Packages/GMPlayerKit/Sources/CGMStream/gm_stream.c` (produce_sel, the
  per-rendition entry points, the segment plan in gm_stream_open).
- Playlists: `GMStreamSession.swift` (masterPlaylist/videoPlaylist/audioPlaylist).
- Server: `GMLoopbackServer.swift` (handle routing). Engine gate: `GMStreamingEngine.swift`.
- Harness: `gmstreamtest/main.swift` (GM_TRACKS, GM_DEMUX, GM_MASTER, GM_TREE, GM_DUMP).

## Phase B (subtitles): ready to start, independent

FFmpeg build script already updated (`1d29fbc`) with subtitle text decoders + the WebVTT
encoder/muxer; user rebuilds with `./Scripts/build-ffmpeg.sh macos`. Then: C
subtitle->WebVTT transcode per segment with X-TIMESTAMP-MAP, EXT-X-MEDIA:TYPE=SUBTITLES
group, server `/subs/<src>/*` routing. PGS/VobSub stay un-carryable (image-based).
