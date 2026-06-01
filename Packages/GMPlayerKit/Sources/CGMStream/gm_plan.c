//
//  gm_plan.c
//  Pure segmentation math. See gm_plan.h. No FFmpeg, no I/O.
//
#include "gm_plan.h"

int gm_plan_segments(const double *kf_times, int n_kf,
                     double duration, double target_sec,
                     double *out_starts, int max_out) {
    if (!kf_times || n_kf < 1 || !out_starts || max_out < 1) return -1;
    if (duration <= 0.0 || target_sec <= 0.0) return -1;

    int count = 0;
    // First segment always starts at the first keyframe.
    out_starts[count++] = kf_times[0];
    double seg_start = kf_times[0];

    for (int i = 1; i < n_kf; i++) {
        double t = kf_times[i];
        // Ignore out-of-order / duplicate times defensively.
        if (t <= seg_start) continue;
        if (t - seg_start >= target_sec) {
            // Don't create a tiny tail segment: if the remaining media after this
            // keyframe is less than half the target, let the current segment
            // absorb it (avoids a sub-second final segment).
            if (duration - t < target_sec * 0.5) break;
            if (count >= max_out) return -1;
            out_starts[count++] = t;
            seg_start = t;
        }
    }
    return count;
}

int gm_plan_uniform(double duration, double target_sec,
                    double *out_starts, int max_out) {
    if (!out_starts || max_out < 1 || duration <= 0.0 || target_sec <= 0.0) return -1;
    int count = 0;
    double t = 0.0;
    while (t < duration - 0.001 && count < max_out) {
        out_starts[count++] = t;
        t += target_sec;
    }
    if (count < 1) { out_starts[count++] = 0.0; }
    return count;
}

double gm_plan_segment_duration(const double *starts, int n_seg,
                                double duration, int i) {
    if (!starts || n_seg < 1 || i < 0 || i >= n_seg) return 0.0;
    double end = (i + 1 < n_seg) ? starts[i + 1] : duration;
    double d = end - starts[i];
    return d > 0.0 ? d : 0.0;
}

int gm_plan_time_to_index(const double *starts, int n_seg, double t) {
    if (!starts || n_seg < 1) return -1;
    if (t <= starts[0]) return 0;
    // Linear scan from the end (segment counts are small, a few hundred max).
    for (int i = n_seg - 1; i >= 0; i--) {
        if (t >= starts[i]) return i;
    }
    return 0;
}
