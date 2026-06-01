//
//  gm_plan.h
//  PURE (FFmpeg-free) segmentation math for the on-demand HLS-fMP4 streamer.
//
//  Given the sorted list of video keyframe presentation times and the media
//  duration, group keyframes into HLS segments each >= a target duration, with
//  every segment starting exactly on a keyframe (so each fMP4 fragment is
//  independently decodable). Also map a seek time -> segment index.
//
//  Split out from gm_stream.c with zero FFmpeg dependency so it is unit-testable
//  without the xcframework, a media file, or the network.
//
#ifndef GM_PLAN_H
#define GM_PLAN_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Build a segment plan from keyframe times.
///
/// @param kf_times    sorted ascending keyframe presentation times (seconds).
///                    kf_times[0] is expected to be ~0 (first frame is a keyframe).
/// @param n_kf        number of keyframes (>= 1).
/// @param duration    total media duration (seconds, > 0).
/// @param target_sec  desired minimum segment duration (e.g. 6.0).
/// @param out_starts  filled with each segment's start time (seconds). The first
///                    entry is always kf_times[0]. Caller allocates >= max_out.
/// @param max_out     capacity of out_starts.
/// @return number of segments written (>= 1), or -1 on bad args / overflow.
///
/// A new segment boundary is taken at the first keyframe whose time is >=
/// (current segment start + target_sec). The last segment runs to `duration`.
int gm_plan_segments(const double *kf_times, int n_kf,
                     double duration, double target_sec,
                     double *out_starts, int max_out);

/// Build a uniform time-based plan when no keyframe index is available: segments
/// of exactly `target_sec` (the last runs to `duration`). Boundaries are snapped
/// to real keyframes later by the muxer's backward seek. Returns segment count.
int gm_plan_uniform(double duration, double target_sec,
                    double *out_starts, int max_out);

/// Duration of segment `i` given the plan (start[i+1]-start[i], last uses duration).
double gm_plan_segment_duration(const double *starts, int n_seg,
                                double duration, int i);

/// Map a playback time (seconds) to the index of the segment that contains it.
/// Clamps to [0, n_seg-1]. Returns -1 only on bad args.
int gm_plan_time_to_index(const double *starts, int n_seg, double t);

#ifdef __cplusplus
}
#endif

#endif /* GM_PLAN_H */
