//
//  gm_ts.c
//  Timestamp fix-up for the stream-copy remux loop. See gm_ts.h for the full
//  background on the ~10fps judder bug this solves.
//
//  Video policy (CFR ladder): emit a uniform decode timeline at the EXACT
//  per-frame tick step, seeded `lead` frames before the first pts:
//
//      dts(i) = first_pts + floor((i - lead) * step_num / step_den)
//
//  with step = out_tb_den / fps (exact rational). Because the step is the true
//  per-frame spacing and the ladder leads pts by >= the reorder depth, every
//  reordered pts satisfies pts >= dts, so pts is passed through untouched and the
//  presentation cadence is exact. A final max(prev+1) guard makes dts strictly
//  monotonic even if integer flooring ever produced a tie.
//
//  Audio / unknown policy (fps_num == 0): the real dts is already monotonic, so
//  preserve it and only bump on a genuine collision.
//
#include "gm_ts.h"

void gm_ts_init(gm_ts_state *st,
                int64_t fps_num, int64_t fps_den,
                int64_t out_tb_num, int64_t out_tb_den,
                int64_t lead) {
    st->step_num = 0;
    st->step_den = 0;
    st->lead = lead > 0 ? lead : 0;
    st->count = 0;
    st->first_pts = 0;
    st->last_dts = GM_TS_NOPTS;
    st->have_first = 0;

    // Exact ticks per frame = (1 / fps) / out_tb
    //   = out_tb_den / (out_tb_num * fps)            [fps = fps_num/fps_den]
    //   = (fps_den * out_tb_den) / (fps_num * out_tb_num).
    if (fps_num > 0 && fps_den > 0 && out_tb_num > 0 && out_tb_den > 0) {
        st->step_num = fps_den * out_tb_den;
        st->step_den = fps_num * out_tb_num;
    }
}

// Floor division that is correct for negative numerators (C truncates toward 0).
static int64_t floordiv(int64_t a, int64_t b) {
    int64_t q = a / b, r = a % b;
    if (r != 0 && ((r < 0) != (b < 0))) q--;
    return q;
}

gm_ts_fixed gm_ts_next(gm_ts_state *st,
                       int64_t pts, int64_t dts, int64_t duration) {
    (void)duration;  // intentionally unused: the ladder uses the exact fps step.
    gm_ts_fixed r;
    r.pts = pts;
    r.dts = dts;
    r.pts_clamped = 0;

    if (st->step_den != 0) {
        // ---- CFR video ladder ----
        if (!st->have_first) {
            st->first_pts = (pts != GM_TS_NOPTS) ? pts : 0;
            st->have_first = 1;
        }
        int64_t i = st->count++;
        int64_t off = floordiv((i - st->lead) * st->step_num, st->step_den);
        int64_t d = st->first_pts + off;

        // Strictly monotonic, even against integer-floor ties.
        if (st->last_dts != GM_TS_NOPTS && d <= st->last_dts)
            d = st->last_dts + 1;

        r.dts = d;
        // pts is preserved; only clamp in the (not expected) pts < dts case.
        if (r.pts != GM_TS_NOPTS && r.pts < r.dts) {
            r.pts = r.dts;
            r.pts_clamped = 1;
        }
        st->last_dts = r.dts;
        return r;
    }

    // ---- audio / unknown: preserve real dts, bump only on collision ----
    if (dts == GM_TS_NOPTS) {
        r.dts = (st->last_dts == GM_TS_NOPTS) ? (pts != GM_TS_NOPTS ? pts : 0)
                                              : st->last_dts + 1;
    } else if (st->last_dts != GM_TS_NOPTS && dts <= st->last_dts) {
        r.dts = st->last_dts + 1;
    }
    if (r.pts != GM_TS_NOPTS && r.pts < r.dts) {
        r.pts = r.dts;
        r.pts_clamped = 1;
    }
    st->last_dts = r.dts;
    return r;
}
