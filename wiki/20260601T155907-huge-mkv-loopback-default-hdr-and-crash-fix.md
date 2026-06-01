# Huge-MKV playback: loopback by default, the far-seek stall, HDR detection, and a Data race crash

**Date:** 2026-06-01
**Outcome:** Shipped. A 35-81 GB 4K REMUX MKV (a 71 GB DoVi, a 35 GB HDR, an 81 GB HDR)
served over the LAN now starts in well under a second, seeks anywhere and resumes,
keeps A/V synced, and reports HDR correctly, all in the native AVKit player. The
streaming engine default flipped from the single-file resource loader to the HLS
loopback server, with a user-facing Settings toggle to switch back.

This documents four findings in order. Two were misdiagnoses worth recording: the
"tfdt" theory (wrong) and the assumption that loopback was already bug-free (it
reached `readyToPlay` fast but stalled on a far seek).

## The starting problem

The single fragmented-MP4 resource-loader engine (`gmstream://` custom scheme,
`AVAssetResourceLoaderDelegate`) hung forever on a 41-71 GB movie: the player showed,
then "loaded forever". mpv/ffplay play the same files instantly.

Root cause (re-confirmed, not new this session): handed ONE fragmented MP4 with no
trusted index, AVFoundation walks every `moof` at open to build its own index. Our
assembled buffer is append-only, so serving byte N forces muxing segments 0..N. On a
3152-fragment file that means muxing ~the whole 41 GB over the network. This is
inherent to feeding AVPlayer a non-HLS single resource; a `sidx` does not stop the
walk (measured: ~86-100% of the file transferred even with a real `global_sidx`). The
documented Apple path for random access into fragmented MP4 is HLS, not a bare fMP4.

## Fix 1: loopback (HLS) is the default for everything

The loopback engine (a 127.0.0.1 server vending `index.m3u8` + `init.mp4` + `segN.m4s`)
makes AVFoundation trust the playlist time map and fetch segments lazily. Measured
`makePlayback`:

| File              | size  | duration | makePlayback | segments fetched to start |
| ----------------- | ----- | -------- | ------------ | ------------------------- |
| 4K DoVi REMUX A   | 71 GB | 6302 s   | 0.05 s       | 1 / 1051                  |
| 4K HDR REMUX B    | 35 GB | 8178 s   | 0.05 s       | 1 / 1364                  |
| 4K HDR REMUX C    | 81 GB | 11684 s  | 0.12 s       | 1 / 1948                  |

So loopback is now the default (`GMStreamingEngine.defaultKind = .loopback`). The
resource loader stays compiled and is opt-in via Settings or `GM_PLAYER_ENGINE`. We
chose all-loopback over a segment-count heuristic because loopback is clean on small
AND huge files, so one hot path beats a fragile threshold.

## Fix 2: the far-seek stall (NOT a tfdt problem)

After loopback became default, a far seek (e.g. to 70 %) intermittently froze: the
player jumped to the right time, buffered the correct data (`loadedTimeRanges` showed
the right absolute window, e.g. `[5727..5781]`), `isPlaybackLikelyToKeepUp = true`,
but `rate` stayed `0.0`. Sometimes it crashed with `Trace/BPT trap`.

A sibling agent proposed the cause was a wrapped-negative `tfdt`
(`baseMediaDecodeTime`) that the resource loader's `normalizeFragments` clamps but the
loopback path does not. **Disproven empirically:** `GM_INSPECT_SEG` showed seg0's
tfdt values are `0, 0, 32699, 92160` and a mid-movie segment's are large positives at
the correct absolute time. No segment ever has a wrapped-negative tfdt, and the
buffered ranges were always correct, not "18 trillion seconds".

The real cause, grounded in Apple's own docs: `beginPlayback` set
`automaticallyWaitsToMinimizeStalling = false` (commit 860191b, to dodge the resource
loader's many-`moof` buffering evaluation). Apple's documentation states plainly that
with this `false`, a drained buffer flips `timeControlStatus` to paused and `rate` to
`0.0` and STAYS there. A far seek over the LAN momentarily drains the buffer, and our
`GMPlaybackMonitor` only counts stalls, it never calls `play()` to recover. For HLS,
`true` is Apple's documented behavior and it auto-resumes after a stall.

The fix is engine-aware playback config in `GMPlayerModel.beginPlayback`:

- loopback (HLS): `automaticallyWaitsToMinimizeStalling = true` + `play()`. Self-heals.
- resource loader / batch: keep `false` + `playImmediately` (the many-`moof` reason
  still applies there).

Verified: with the fix, 70 % seek passes; stress (seeks at 0.2/0.4/0.6/0.7/0.8/0.95)
passes on the 71 GB DoVi REMUX with no stall and no crash.

## Fix 3: a Data in-place-mutation crash on the stream queue

A crash report (`EXC_BREAKPOINT`, `Trace/BPT trap`) on `com.gm.appleplayer.stream`
landed in `Data._Representation.replaceSubrange`, reached from
`GMHTTPByteSource.openConnection(at:)` → `buffer.removeAll(keepingCapacity: true)`.

Cause: `removeAll(keepingCapacity: true)` mutates `Data`'s backing store in place.
`GMHTTPByteSource.buffer` could share storage with a URLSession-delegate-delivered
`Data` chunk (`append(data)` can adopt the NSData/dispatch_data backing by reference).
When `openConnection` then cleared that shared store in place, the CoW invariant broke
and the runtime trapped. Loopback's heavier reopen churn (prefetch + seeks) is why it
surfaced now.

Two-part fix in `GMByteSource.swift`:

1. `openConnection`: `buffer = Data()` (fresh value) instead of `removeAll(keepingCapacity:)`.
2. `didReceive data`: append a COPY of the delivered bytes
   (`data.withUnsafeBytes { buffer.append(contentsOf: $0...) }`) so `buffer` is always
   the sole owner of its storage and later `removeFirst`/`removeAll` can never race.

## Fix 4: HDR detection regression (HUD said "HDR = no")

Switching to HLS broke HDR detection. `GMPlaybackMonitor.detectHDR` reads the video
`AVAssetTrack.formatDescriptions` transfer function. For a progressive/fragmented
single-file asset that works; for an HLS (`m3u8`) asset AVFoundation does not surface
per-track format descriptions, so the probe came back empty and the HUD showed SDR.

The content was never stripped: the muxed segments carry PQ in the HEVC SPS (the
resource-loader path reads `SMPTE_ST_2084_PQ` from the same bytes). It was purely a
detection gap, and the container's codec params are unreliable here too: matroska
leaves `color_trc` UNSPECIFIED for these HEVC files (PQ lives in the SPS VUI, which the
fast 2 MB / 2 s OPEN probe does not fully resolve, and neither opening a decoder nor
decoding a frame in the C layer recovered it in this FFmpeg build).

Fix that is correct on every engine: `GMStreamSession` resolves HDR by muxing the init
+ first segment (already needed to start playback), writing them to a tiny temp `.mp4`,
and reading the video track's transfer function via `AVAsset`, letting AVFoundation
parse the HEVC SPS the way it does for the single-file path. Cached after first
resolve. The result is handed to the monitor as `knownHDR`/`knownTransferName` so the
HUD never depends on HLS track descriptions. Verified `isHDR = true,
transfer = SMPTE ST 2084 (PQ)` on the local DoVi demo and the 71 GB REMUX over LAN.

Still open (follow-up, detection works without it): for correct EDR *rendering* of
HDR over HLS, the playlist should advertise `VIDEO-RANGE=PQ` + a proper `CODECS`
attribute and the init `moov` should carry a `colr` box. Tracked separately.

## The Settings toggle

Added `EngineSettingsSheet` (a Picker over `GMStreamingEngine.Preference`:
auto / loopback / single-file), persisted via `@AppStorage("enginePreference")`,
surfaced from the landing-screen gear button and the macOS `Settings…` (⌘,) menu. The
preference flows `ContentView → GMPlayerModel.enginePreference →
GMStreamingEngine.makePlayback(preference:)`. `GM_PLAYER_ENGINE` still overrides for
tests.

## Test + harness additions

- `gmstreamtest` gained `GM_PLAYTHROUGH` (build → readyToPlay → play → far seek →
  play, asserting `currentTime` advances and status stays `readyToPlay`; reports lazy
  fetch growth) and `GM_HDR` (prints the engine-resolved transfer function).
- New `GMEngineSelectionTests` (default/preference/env resolution, raw-value stability
  for `@AppStorage`) and a `testLoopbackStreamsLazily` case proving loopback fetches
  only a few segments to reach `readyToPlay`. Suite: 59 green.

## One-line status

Huge MKVs play instantly and seek cleanly on the HLS loopback default; the far-seek
stall (waiting-policy, not tfdt), the Data race crash, and HDR detection are fixed;
a Settings toggle exposes the engine choice. HDR *rendering* signalling in the
playlist/`colr` box is the remaining follow-up.
