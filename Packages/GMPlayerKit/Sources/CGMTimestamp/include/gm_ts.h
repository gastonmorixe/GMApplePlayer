//
//  gm_ts.h
//  Pure, FFmpeg-free timestamp fix-up for the stream-copy remux loop.
//
//  Extracted from the remux engine so the timestamp policy can be unit-tested
//  without FFmpeg, the xcframework, or a media file. The caller (remux.c) first
//  runs av_packet_rescale_ts(pkt, in_tb, out_tb); these functions then operate on
//  the rescaled integer pts/dts/duration in the OUTPUT stream timebase.
//
//  THE BUG THIS FIXES (the ~10fps judder):
//  The Matroska demuxer hands a B-frame video stream packets in decode order but
//  with dts == pts (presentation values). That dts sequence is non-monotonic
//  (0, 2000, 672, 1328, ...), and the MP4/MOV muxer requires a strictly
//  increasing dts. Two earlier "fixes" both failed:
//    (a) "dts = prev_dts + duration" rebuilt dts from the source's quantized 41ms
//        duration (656 ticks @ 1/16000) instead of the true 41.708ms (667 ticks),
//        producing 24.39fps instead of 23.976fps; and
//    (b) "dts = pts, bump to last+1 on collision" turned the reorder into
//        0, 2000, 2001, 2002, 4000, ... then had to raise PTS to keep pts>=dts,
//        bunching every group of frames onto adjacent ticks (the visible judder).
//
//  THE FIX (video):
//  The stream is constant-frame-rate, so the correct decode timeline is a uniform
//  ladder at the EXACT per-frame tick step (out_tb_den / fps), seeded a couple of
//  frames early so the reordered presentation timestamps are always >= their dts.
//  PTS is passed through untouched (presentation cadence is exact); DTS becomes a
//  clean monotonic ramp that never forces a PTS clamp. Audio (no reordering) just
//  preserves its already-monotonic dts.
//
#ifndef GM_TS_H
#define GM_TS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// "No timestamp" sentinel, numerically identical to FFmpeg's AV_NOPTS_VALUE
/// (INT64_MIN) so callers can pass pkt->pts / pkt->dts straight through.
#define GM_TS_NOPTS INT64_MIN

/// Per-output-stream state. Zero-initialize, then call gm_ts_init once.
typedef struct {
    int64_t step_num;   ///< exact ticks-per-frame numerator (0 => no CFR ladder)
    int64_t step_den;   ///< exact ticks-per-frame denominator
    int64_t lead;       ///< frames the dts ladder leads pts by (>= reorder depth)
    int64_t count;      ///< video frames emitted so far (ladder index)
    int64_t first_pts;  ///< pts of the first packet, in output ticks
    int64_t last_dts;   ///< last dts handed to the muxer
    int     have_first; ///< 0 until the first packet sets first_pts
} gm_ts_state;

/// The dts/pts to hand the muxer for one packet (output stream timebase).
typedef struct {
    int64_t pts;          ///< pts to mux
    int64_t dts;          ///< dts to mux (strictly greater than the previous)
    int     pts_clamped;  ///< 1 if pts had to be raised to satisfy pts >= dts
} gm_ts_fixed;

/// Initialize stream state.
///
/// For a constant-frame-rate VIDEO stream, pass the output timebase and the
/// stream frame rate; the exact per-frame tick step is computed as
/// out_tb_den/(fps) = (fps_den * out_tb_den) / (fps_num * out_tb_num). `lead` is
/// how many frames the dts ladder should sit ahead of pts: it must be >= the
/// stream's reorder depth (e.g. video_delay + a small margin; 2 is enough for the
/// common B-pyramid). For AUDIO or any stream with no usable frame rate, pass
/// fps_num = 0: the policy then preserves the real (already monotonic) dts and
/// only bumps on a genuine collision.
void gm_ts_init(gm_ts_state *st,
                int64_t fps_num, int64_t fps_den,
                int64_t out_tb_num, int64_t out_tb_den,
                int64_t lead);

/// Compute the timestamps to mux for the next packet (call in decode order).
///
/// Guarantees:
///   - dts is strictly greater than the previous packet's dts (muxer requirement);
///   - for the CFR video ladder, dts <= pts for every packet, so a real pts is
///     never altered (pts_clamped stays 0) and the presentation cadence is exact;
///   - audio/unknown streams preserve their real dts and only bump on collision,
///     raising pts only in the degenerate pts < dts case.
gm_ts_fixed gm_ts_next(gm_ts_state *st,
                       int64_t pts, int64_t dts, int64_t duration);

#ifdef __cplusplus
}
#endif

#endif /* GM_TS_H */
