# Choppy 4K video in GMApplePlayer: the remux DTS bug (full post-mortem + verified fix)

**Date:** 2026-05-31 (root cause) / 2026-06-01 (verified fix + tests)
**Symptom:** On macOS, our app played the 4K HDR MKV at a juddery ~10fps while **audio was perfectly smooth**. QuickTime played a comparable remux fine.
**Status:** FIXED and verified. The remux now reproduces the reference `ffmpeg` CLI presentation timeline exactly; AVFoundation reports `isPlayable=true`, `nominalFrameRate=23.976`. Guarded by unit tests (`CGMTimestampTests`) over the real packet sequence and an integration test that remuxes the sample and checks the cadence.

> **Correction note (2026-06-01).** The first writeup of this file (and the first
> code fix) were partly wrong. Two claims did not survive measurement:
> (1) "the demuxer hands monotonic dts, only the first is NOPTS", false; and
> (2) "Fixed: uniform 23.976fps" for the `dts = prev_dts + duration` patch, that
> patch actually produced **24.39fps** and still bunched the opening ~2.5s. The
> sections below are the corrected, instrumented account. The wrong turns are kept
> on purpose; they are the most useful part.

## TL;DR

- The Matroska demuxer hands this B-frame HEVC stream packets in **decode order with `dts == pts`** (the presentation values). Confirmed by instrumenting the engine (`GM_TS_DEBUG`) and reading what `av_read_frame` actually delivers: all 4506 video packets have `dts == pts`, and that dts sequence is **non-monotonic** (1460 backward steps). `ffprobe`'s displayed dts is a clean reconstruction and does NOT match the API, which sent the first investigation down the wrong path.
- The MP4/MOV muxer requires a **strictly increasing dts**. Every naive fix failed a different way:
  - **"dts = pts, bump to last+1 on collision"** → `0, 2000, 2001, 2002, 4000, ...`, then PTS had to be raised to keep `pts >= dts`, **bunching every reordered group onto 3 adjacent ticks**. This is the ~10fps judder.
  - **"dts = prev_dts + duration"** → rebuilt dts from the source's *quantized* 41ms duration (656 ticks @ 1/16000) instead of the true 41.708ms (667 ticks), giving a uniform **24.39fps** instead of 23.976, and it still clamped PTS on the opening frames where the synthesized dts started level with pts.
- **The fix:** for a constant-frame-rate video stream, drive a uniform decode-timeline **ladder at the exact per-frame tick step** (`out_tb_den / fps`), seeded a couple of frames before the first pts. PTS is passed through untouched. This makes dts strictly monotonic, keeps `dts <= pts` for every packet (so PTS is never clamped), and reproduces the reference `ffmpeg` presentation timeline exactly.

## The numbers (measured, fixed engine vs reference)

```
                         our engine (fixed)      system ffmpeg -c copy     source MKV
avg_frame_rate           4506000/187937          4506000/187937            24000/1001
                         = 23.976                = 23.976                  = 23.976
sorted-PTS deltas        {656×1314, 672×3191}    {656×1314, 672×3191}      (= same, ×16)
decode-order DTS deltas  {667×3004, 668×1501}    {656/672 mix}             n/a
DTS strictly monotonic   yes (0 violations)      yes                       no (dts==pts)
dts > pts violations     0 / 4506                0 / 4506                  n/a
sorted PTS timeline      IDENTICAL to ffmpeg reference                     same
AVFoundation             isPlayable=true, nominalFrameRate=23.976, duration=187.97s
```

Our DTS ladder is a uniform 667.33-tick step (so its per-step deltas alternate 667/668), whereas ffmpeg reuses the source's 656/672 spacing for dts too. Both are valid: dts only has to be monotonic and `<= pts`. The **presentation** timeline (sorted PTS), which is what the eye sees, is byte-identical between the two.

## How it was actually diagnosed

### The misleading signal
`AVPlayerItem.accessLog()` reported `rate = 1.0` and `numberOfDroppedVideoFrames = 0` the whole time, even at ~10fps on screen. **The access log measures decode/delivery, not the final present cadence**, so it cannot see this class of bug. Trusting it cost time.

### The ffprobe trap
`ffprobe -show_entries packet=dts` displays a clean, monotonic dts (`N/A, 0, 42, 83, 125, ...`). That made it look like the demuxer delivers good dts and the bug was elsewhere. It is not what the API delivers. The only way to see the truth was to print `pkt->dts` straight out of `av_read_frame` in our own loop (`GM_TS_DEBUG`):

```
[gmraw] pts=0     dts=0       (first packet)
[gmraw] pts=125   dts=125     <- dts == pts, and 125 > next dts: NON-monotonic
[gmraw] pts=42    dts=42
[gmraw] pts=83    dts=83
[gmraw] pts=250   dts=250
...   all 4506 packets: dts == pts ; 1460 backward dts steps
```

### Wrong turns (kept on purpose)
1. **"It's the Dolby Vision Profile 7 / HEVC decode."** Disproved by measurement: VideoToolbox decoded the stream at ~255fps (10x realtime); `dovi_rpu=strip` changed the file by 2MB. Decode was never the bottleneck.
2. **"It's the Liquid Glass `.interactive()` overlay."** A real per-frame CA cost on the compositor; removed it (a good change), but it did not fix the judder.
3. **"It's the AVKit scrubber `NSSlider.drawRect`."** Over-read a symbol that was <1% of samples; setting `controlsStyle = .none` did not fix it.
4. **First "real" fix: `dts = prev_dts + duration`.** Plausible, and it killed the *pervasive* bunching, so it looked fixed. But measuring the output packets showed 24.39fps and a clamped opening. This is why the fix now has a test that measures the actual cadence, not just `nominalFrameRate` (an average that hides bunching).

### The decisive step
Stop trusting `ffprobe` and the frame-rate average. Instrument the engine to print raw `av_read_frame` timestamps, then **diff the engine's output packet timeline against a `ffmpeg -c copy` remux of the same source**. That immediately showed `dts == pts` on input and pinned the output requirements.

## The fix (code)

The timestamp policy is now a pure, FFmpeg-free function (`Sources/CGMTimestamp/gm_ts.c`) so it can be unit-tested without a media file. The remux loop (`Sources/CFFmpeg/remux.c`) calls it per packet after `av_packet_rescale_ts`.

```c
// gm_ts.c: CFR video ladder (per output stream; state in gm_ts_state):
//   dts(i) = first_pts + floor((i - lead) * step_num / step_den)
// step = out_tb_den / fps  (exact rational: step_num=fps_den*out_tb_den,
//                           step_den=fps_num*out_tb_num)
// lead = reorder depth (video_delay) + margin, so every reordered pts >= its dts.
int64_t off = floordiv((i - st->lead) * st->step_num, st->step_den);
int64_t d   = st->first_pts + off;
if (st->last_dts != GM_TS_NOPTS && d <= st->last_dts) d = st->last_dts + 1; // strict-mono guard
r.dts = d;
r.pts = pts;                                  // PTS preserved exactly
if (r.pts != GM_TS_NOPTS && r.pts < r.dts) {  // never fires for the CFR ladder
    r.pts = r.dts; r.pts_clamped = 1;
}
```

Why a uniform ladder rather than reusing the source dts:
- The source dts (`== pts`) is non-monotonic, so it can't be used directly.
- Reconstructing `sorted_pts[i-1]` (what ffmpeg emits) is exact but needs a reorder buffer.
- A constant-rate ladder at the **exact** fps step, led by `>= reorder_depth` frames, is buffer-free and provably satisfies all the muxer's requirements while leaving PTS (hence presentation) untouched. Verified: 0 `dts>pts` violations, 0 non-monotonic, presentation timeline identical to ffmpeg.

Audio (and any stream with no usable frame rate) takes the other branch: its real dts is already monotonic, so it's preserved and only bumped on a genuine collision.

## Tests now guarding this

- **`Packages/GMPlayerKit/Tests/CGMTimestampTests/`**: pure, no FFmpeg, no media file. The fixture (`Fixture.swift`) is the **real** 4506-packet decode-order sequence captured from `av_read_frame` via `GM_TS_DEBUG` (not ffprobe). It replays the sequence through `gm_ts_next` and asserts:
  - `testDTSStrictlyMonotonic`: dts strictly increases;
  - `testPTSNeverClamped` / `testOutputPTSEqualsRescaledInputPTS`: PTS passes through exactly;
  - `testDTSNeverExceedsPTS`: `dts <= pts` for every packet;
  - `testFrameRateIs23_976` + `testPTSDeltasAreOnlyTheSourceCadence`: presentation cadence is the real `{656,672}` mix (23.976fps), not the flattened 24.39;
  - `testDTSDeltasMatchSourceCadence`: decode-order dts is the uniform ~667-tick ladder;
  - `testAudioPreservesMonotonicDTS` / `testCollisionGuardBumpsEqualDTS`: the audio/collision branch.
  These start RED against both buggy policies and GREEN on the ladder.
- **`Tests/GMPlayerKitTests/testRemuxProducesUniform23_976CFR`**: end-to-end: remuxes the sample MKV through the real engine and asserts AVFoundation sees ~23.976 CFR and `isPlayable`.

Run: `cd Packages/GMPlayerKit && swift test` (13 tests). The macOS app target builds clean: `xcodebuild -scheme GMApplePlayer-macOS -configuration Debug build` → **BUILD SUCCEEDED**.

## Lessons captured

1. `AVPlayerItem.accessLog` dropped-frame count does **not** detect present-cadence / timestamp-cadence judder. For "video slow, audio fine, zero drops," suspect the **container timestamps**.
2. **`ffprobe`'s displayed dts is not what `av_read_frame` hands your code.** ffprobe reconstructs a clean dts. If you're writing a remuxer, instrument your own loop; don't trust the probe's dts column.
3. **`nominalFrameRate` / `avg_frame_rate` is an average and hides bunching.** A stream can read "23.976fps" and still present in ~8 bursts/second. Test the actual per-frame cadence (sorted-PTS deltas), not just the average. This is exactly how the first "fix" passed inspection while still being wrong.
4. The fastest bisection when the player is suspect: remux the same source with the reference `ffmpeg` CLI, play THAT, and diff your engine's packet timeline against ffmpeg's. If the timelines match, the bug isn't your timestamps.
5. Matroska B-frame rips: the demuxer gives `dts == pts` (non-monotonic). For CFR content, synthesize a uniform decode ladder at the exact fps step, led by the reorder depth, and leave PTS alone.
6. A symbol in a CA-commit backtrace is not guilty until its sample weight is large relative to the frame budget. Check the number, not just the name.

## Files touched (this fix)

- `Packages/GMPlayerKit/Sources/CGMTimestamp/gm_ts.{h,c}`: **new** pure timestamp module (CFR ladder + audio/collision policy).
- `Packages/GMPlayerKit/Sources/CFFmpeg/remux.c`: call `gm_ts_init`/`gm_ts_next` per stream; env-gated `GM_TS_DEBUG` raw-timestamp dump.
- `Packages/GMPlayerKit/Package.swift`: add `CGMTimestamp` target + `CGMTimestampTests`; `CFFmpeg` depends on `CGMTimestamp`.
- `Packages/GMPlayerKit/Tests/CGMTimestampTests/`: **new** tests + real-packet fixture.

### Earlier related changes (still valid, from the original investigation)
- `Sources/GMApplePlayer/GlassStyle.swift`: dropped `.interactive()` from the player-overlay glass (real CA cost, not the judder root cause).
- `Packages/GMPlayerKit/Sources/GMPlayerKit/GMPlayerView.swift`: reverted EDR layer meddling; restored native controls.
