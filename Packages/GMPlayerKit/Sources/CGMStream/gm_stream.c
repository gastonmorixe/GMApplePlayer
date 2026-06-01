//
//  gm_stream.c
//  On-demand streaming remux engine. See gm_stream.h.
//
//  Pipeline: caller byte source -> input AVIOContext -> matroska demuxer ->
//  (stream copy, DTS via gm_ts_next) -> fragmented mp4 muxer -> output AVIOContext
//  -> caller gm_buf. Init segment and each media segment are produced on demand.
//
//  fMP4 layout: with movflags empty_moov+delay_moov the muxer emits
//  ftyp + moov (after the first packet, so AC-3/E-AC-3 extradata is ready) +
//  (moof+mdat)+. The INIT segment is the [ftyp..moov] prefix; a MEDIA segment is
//  the [moof..] suffix. We split them by walking the top-level box headers.
//
#include "gm_stream.h"
#include "gm_ts.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include <libavformat/avformat.h>
#include <libavformat/avio.h>
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/intreadwrite.h>
#include <libavutil/mathematics.h>
#include <libavutil/dovi_meta.h>

// gm_auto_select lives in CFFmpeg/compat.c. Declare it here (same signature).
extern int gm_auto_select(AVFormatContext *fmt, enum AVMediaType type);
// gm_codec_is_avf_compatible also lives in compat.c (CFFmpeg target, linked in).
#include <stdbool.h>
extern bool gm_codec_is_avf_compatible(enum AVCodecID id);

#define GM_IO_BUFSZ 65536
#define GM_MAX_SEGS 4096
#define GM_MAX_STREAMS 64
#define GM_MAX_OUT 16

struct gm_stream {
    gm_source src;
    int64_t   src_pos;
    AVFormatContext *in;
    AVIOContext     *in_avio;
    int video_in;
    int audio_in;
    double duration;
    double seg_starts[GM_MAX_SEGS];
    double seg_real_end[GM_MAX_SEGS]; ///< actual keyframe-aligned end of segment i (lazy, -1 = unknown)
    double last_actual_end;           ///< video closing-keyframe pts from the last produce_sel
    int    out_index[GM_MAX_STREAMS]; ///< input stream index -> output stream index (-1 = not muxed)
    int    n_seg;
    double target_seg_sec;
};

// ── one-time network init (for http(s) sources opened elsewhere; harmless here) ─
static void ensure_init(void) {
    static int done = 0;
    if (!done) { avformat_network_init(); av_log_set_level(AV_LOG_ERROR); done = 1; }
}

// ── input AVIO callbacks (pull from the caller byte source) ───────────────────

static int in_read(void *opaque, uint8_t *buf, int size) {
    gm_stream *s = opaque;
    int n = s->src.read(s->src.ctx, s->src_pos, buf, size);
    if (n > 0) { s->src_pos += n; return n; }
    if (n == 0) return AVERROR_EOF;
    return AVERROR(EIO);
}

static int64_t in_seek(void *opaque, int64_t off, int whence) {
    gm_stream *s = opaque;
    int64_t sz = s->src.size ? s->src.size(s->src.ctx) : -1;
    switch (whence) {
        case AVSEEK_SIZE: return sz;
        case SEEK_SET: s->src_pos = off; break;
        case SEEK_CUR: s->src_pos += off; break;
        case SEEK_END: if (sz < 0) return -1; s->src_pos = sz + off; break;
        default: return -1;
    }
    return s->src_pos;
}

// ── output AVIO callbacks (append fMP4 into a caller gm_buf) ───────────────────

typedef struct { gm_buf *buf; int64_t pos; } out_ctx;

static int buf_ensure(gm_buf *b, int need) {
    if (need <= b->cap) return 0;
    int ncap = b->cap ? b->cap : 65536;
    while (ncap < need) ncap *= 2;
    uint8_t *p = realloc(b->data, (size_t)ncap);
    if (!p) return -1;
    b->data = p; b->cap = ncap;
    return 0;
}

static int out_write(void *opaque, const uint8_t *buf, int size) {
    out_ctx *o = opaque;
    int64_t end = o->pos + size;
    if (end > o->buf->len) {
        if (buf_ensure(o->buf, (int)end) < 0) return AVERROR(ENOMEM);
        o->buf->len = (int)end;
    }
    memcpy(o->buf->data + o->pos, buf, (size_t)size);
    o->pos += size;
    return size;
}

static int64_t out_seek(void *opaque, int64_t off, int whence) {
    out_ctx *o = opaque;
    switch (whence) {
        case AVSEEK_SIZE: return o->buf->len;
        case SEEK_SET: o->pos = off; break;
        case SEEK_CUR: o->pos += off; break;
        case SEEK_END: o->pos = o->buf->len + off; break;
        default: return -1;
    }
    return o->pos;
}

// ── helpers ───────────────────────────────────────────────────────────────────

static void set_err(char *err, int errlen, const char *msg, int averr) {
    if (!err || errlen <= 0) return;
    if (averr != 0) {
        char av[128] = {0};
        av_strerror(averr, av, sizeof(av));
        snprintf(err, errlen, "%s: %s", msg, av);
    } else {
        snprintf(err, errlen, "%s", msg);
    }
}

// Walk top-level ISO-BMFF boxes; return the byte offset just past the first box
// whose type == `type` (4 chars). Returns -1 if not found / malformed.
static int box_end_offset(const uint8_t *d, int len, const char *type) {
    int i = 0;
    while (i + 8 <= len) {
        uint32_t sz = AV_RB32(d + i);
        int64_t boxsize = sz;
        int header = 8;
        if (sz == 1) {                       // 64-bit largesize
            if (i + 16 > len) break;
            boxsize = (int64_t)AV_RB64(d + i + 8);
            header = 16;
        } else if (sz == 0) {
            boxsize = len - i;               // extends to EOF
        }
        if (boxsize < header) break;
        if (memcmp(d + i + 4, type, 4) == 0) {
            int64_t end = i + boxsize;
            return end <= len ? (int)end : -1;
        }
        i += (int)boxsize;
    }
    return -1;
}

// movflags shared by init + media segments:
//  - frag_keyframe+empty_moov+default_base_moof: fragmented MP4 with an init moov.
//  - delay_moov: write the moov after the first packet so AC-3/E-AC-3 extradata is
//    ready (required; otherwise write_header fails on these codecs).
//  - frag_discont: each segment is muxed by a FRESH context, so signal the timeline
//    is discontinuous. With this flag and no edit list, movenc sets the track
//    start_dts to 0 (movenc.c:7100), so tfdt = the packet's ABSOLUTE dts. Without
//    it start_dts = first dts and every segment's tfdt rebases to 0 (segments
//    overlap, AVFoundation rejects the HLS timeline with err -16913).
static int set_frag_opts(AVDictionary **opts) {
    // This output is VERIFIED to play in AVFoundation over HTTP (AVPlayerItem
    // readyToPlay, video decoded at full resolution, time advancing). The `dash`
    // movflag (styp/sidx) was tried and is NOT needed: AVFoundation accepts these
    // segments as-is. The CoreMedia "HLS-FASB err -15514" log is BENIGN: it also
    // appears 3x during a SUCCESSFUL HTTP playback of the identical bytes, so it is
    // not a format rejection. (The real -12881 failure was the AVAssetResourceLoader
    // transport, which Apple does not allow to serve HLS media segments.)
    return av_dict_set(opts, "movflags",
                       "frag_keyframe+empty_moov+default_base_moof+delay_moov+frag_discont", 0);
}

// Build a fresh fragmented-mp4 output writing into `buf`. Caller frees via close_output.
// `ts_offset_sec` shifts all output timestamps so an independently-muxed segment
// lands at its ABSOLUTE position on the HLS timeline (each fresh muxer otherwise
// rebases its first fragment's baseMediaDecodeTime to 0, overlapping every segment).
// Which source streams a produced segment carries. For the legacy muxed segment both
// are set (video_in + audio_in). For demuxed HLS renditions exactly one is set:
//   video rendition  -> vid_src = video_in, aud_src = -1
//   audio rendition i -> vid_src = -1,       aud_src = <that audio source index>
// vid_src/aud_src pick the streams a segment carries. all_audio=1 means "add EVERY
// AVFoundation-compatible audio track" (so a single muxed fMP4 exposes them all to
// AVPlayer's native media-selection picker, no HLS rendition groups needed).
typedef struct { int vid_src; int aud_src; int all_audio; } gm_sel;

// Add one output stream copied from input `src_idx`; returns the new output index or <0.
static int add_out_stream(gm_stream *s, AVFormatContext *oc, int src_idx, int *vout, int *aout) {
    AVStream *ist = s->in->streams[src_idx];
    AVStream *ost = avformat_new_stream(oc, NULL);
    if (!ost) return -1;
    if (avcodec_parameters_copy(ost->codecpar, ist->codecpar) < 0) return -1;
    ost->codecpar->codec_tag = 0;
    ost->time_base = ist->time_base;
    // Carry language/title + default disposition so the native picker labels each track.
    AVDictionaryEntry *lang = av_dict_get(ist->metadata, "language", NULL, 0);
    if (lang) av_dict_set(&ost->metadata, "language", lang->value, 0);
    AVDictionaryEntry *title = av_dict_get(ist->metadata, "title", NULL, 0);
    if (title) av_dict_set(&ost->metadata, "title", title->value, 0);
    ost->disposition = ist->disposition;
    if (ist->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
        if (ist->codecpar->codec_id == AV_CODEC_ID_HEVC) ost->codecpar->codec_tag = MKTAG('h','v','c','1');
        else if (ist->codecpar->codec_id == AV_CODEC_ID_H264) ost->codecpar->codec_tag = MKTAG('a','v','c','1');
        if (vout) *vout = ost->index;
    } else if (aout && *aout < 0) {
        *aout = ost->index;
    }
    s->out_index[src_idx] = ost->index;
    return ost->index;
}

static int open_output(gm_stream *s, gm_buf *buf, double ts_offset_sec, gm_sel sel,
                       AVFormatContext **oc_out,
                       AVIOContext **avio_out, out_ctx **octx_out,
                       int *vout, int *aout, char *err, int errlen) {
    *vout = -1; *aout = -1;
    for (int i = 0; i < (int)s->in->nb_streams; i++) s->out_index[i] = -1;
    AVFormatContext *oc = NULL;
    int ret = avformat_alloc_output_context2(&oc, NULL, "mp4", NULL);
    if (ret < 0 || !oc) { set_err(err, errlen, "alloc output", ret); return ret ? ret : -1; }

    // Video first (output stream 0), then audio: either the single selected track or,
    // when all_audio is set, every AVFoundation-compatible audio track in source order.
    if (sel.vid_src >= 0 && add_out_stream(s, oc, sel.vid_src, vout, aout) < 0) {
        avformat_free_context(oc); set_err(err, errlen, "new stream", 0); return -1;
    }
    if (sel.all_audio) {
        for (int i = 0; i < (int)s->in->nb_streams; i++) {
            AVCodecParameters *p = s->in->streams[i]->codecpar;
            if (p->codec_type == AVMEDIA_TYPE_AUDIO && gm_codec_is_avf_compatible(p->codec_id)) {
                if (add_out_stream(s, oc, i, NULL, aout) < 0) {
                    avformat_free_context(oc); set_err(err, errlen, "new audio stream", 0); return -1;
                }
            }
        }
    } else if (sel.aud_src >= 0 && add_out_stream(s, oc, sel.aud_src, NULL, aout) < 0) {
        avformat_free_context(oc); set_err(err, errlen, "new stream", 0); return -1;
    }

    if (0) for (int pass = 0; pass < 2; pass++) { // (old per-pass loop kept disabled)
        int src_idx = pass == 0 ? sel.vid_src : sel.aud_src;
        if (src_idx < 0) continue;
        AVStream *ist = s->in->streams[src_idx];
        AVStream *ost = avformat_new_stream(oc, NULL);
        if (!ost) { avformat_free_context(oc); set_err(err, errlen, "new stream", 0); return -1; }
        ret = avcodec_parameters_copy(ost->codecpar, ist->codecpar);
        if (ret < 0) { avformat_free_context(oc); set_err(err, errlen, "copy codecpar", ret); return ret; }
        ost->codecpar->codec_tag = 0;
        ost->time_base = ist->time_base;
        if (ist->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            if (ist->codecpar->codec_id == AV_CODEC_ID_HEVC)
                ost->codecpar->codec_tag = MKTAG('h','v','c','1');
            else if (ist->codecpar->codec_id == AV_CODEC_ID_H264)
                ost->codecpar->codec_tag = MKTAG('a','v','c','1');
            *vout = ost->index;
        } else {
            *aout = ost->index;
        }
    }

    out_ctx *octx = calloc(1, sizeof(out_ctx));
    octx->buf = buf; octx->pos = 0;
    uint8_t *iob = av_malloc(GM_IO_BUFSZ);
    AVIOContext *avio = avio_alloc_context(iob, GM_IO_BUFSZ, 1, octx, NULL, out_write, out_seek);
    if (!avio) { av_free(iob); free(octx); avformat_free_context(oc); set_err(err, errlen, "alloc out avio", 0); return -1; }
    oc->pb = avio;
    oc->flags |= AVFMT_FLAG_BITEXACT;  // deterministic moov across segments
    // Each segment is produced by a fresh muxer but must keep ABSOLUTE timestamps
    // so its tfdt (baseMediaDecodeTime) places it on the global HLS timeline. Keep
    // negative ts (don't let the muxer shift toward zero) and add the segment's
    // absolute start as an output offset so fragment N begins at its real time.
    oc->avoid_negative_ts = AVFMT_AVOID_NEG_TS_DISABLED;
    (void)ts_offset_sec;  // timestamps from gm_ts are already absolute; see produce().

    *oc_out = oc; *avio_out = avio; *octx_out = octx;
    return 0;
}

static void close_output(AVFormatContext *oc, AVIOContext *avio, out_ctx *octx) {
    if (avio) { av_free(avio->buffer); avio_context_free(&avio); }
    if (oc) avformat_free_context(oc);
    free(octx);
}

static void ts_init_for(gm_stream *s, AVFormatContext *oc, int vout, gm_ts_state *ts) {
    for (int k = 0; k < (int)oc->nb_streams; k++) {
        AVStream *ost = oc->streams[k];
        int64_t fn = 0, fd = 0, lead = 0;
        if (k == vout && s->video_in >= 0) {
            AVStream *iv = s->in->streams[s->video_in];
            AVRational fr = iv->avg_frame_rate;
            if (fr.num <= 0 || fr.den <= 0) fr = iv->r_frame_rate;
            if (fr.num > 0 && fr.den > 0) { fn = fr.num; fd = fr.den; }
            int vd = iv->codecpar->video_delay;
            lead = (vd > 0 ? vd : 1) + 2; if (lead > 16) lead = 16;
        }
        gm_ts_init(&ts[k], fn, fd, ost->time_base.num, ost->time_base.den, lead);
    }
}

// Mux the packets in [seg_start, seg_end); fill `buf` with the FULL output
// (ftyp+moov+moof+mdat...). Sets *moov_end to the offset splitting init/media.
// `sel` chooses which source streams the segment carries (muxed video+audio for the
// legacy single resource, or a single demuxed video / audio rendition for HLS).
static int produce_sel(gm_stream *s, double seg_start, double seg_end,
                       double ts_offset_sec, gm_sel sel,
                       gm_buf *buf, int *moov_end, char *err, int errlen) {
    buf->len = 0;
    AVFormatContext *oc = NULL; AVIOContext *avio = NULL; out_ctx *octx = NULL;
    int vout, aout;
    int ret = open_output(s, buf, ts_offset_sec, sel, &oc, &avio, &octx, &vout, &aout, err, errlen);
    if (ret < 0) return ret;

    AVDictionary *opts = NULL; set_frag_opts(&opts);
    ret = avformat_write_header(oc, &opts);
    av_dict_free(&opts);
    if (ret < 0) { set_err(err, errlen, "write_header", ret); close_output(oc, avio, octx); return ret; }

    int seek_stream = sel.vid_src >= 0 ? sel.vid_src : (sel.all_audio ? s->audio_in : sel.aud_src);
    AVStream *sst = s->in->streams[seek_stream];
    int64_t seek_ts = (int64_t)(seg_start / av_q2d(sst->time_base) + 0.5);
    ret = av_seek_frame(s->in, seek_stream, seek_ts, AVSEEK_FLAG_BACKWARD);
    if (ret < 0) { set_err(err, errlen, "seek input", ret); close_output(oc, avio, octx); return ret; }

    gm_ts_state ts[GM_MAX_OUT];
    ts_init_for(s, oc, vout, ts);

    // Boundary rule (keyframe-exact tiling): a segment begins at the first VIDEO
    // keyframe with pts >= seg_start and ends just before the first video keyframe
    // with pts >= seg_end. Because segment i's end test and segment i+1's start
    // test use the same "first keyframe >= boundary time", adjacent segments share
    // the exact boundary keyframe: no overlap, no gap, and every segment starts on
    // a keyframe (independently decodable). The backward seek lands at or before
    // seg_start; we skip packets until the opening keyframe. Audio rides the same
    // [actual_start, actual_end) window. (For a dense keyframe index seg_start/end
    // already sit on keyframes, so the skip is a no-op.)
    int have_video = (sel.vid_src >= 0);
    int started = 0;            // have we hit the opening video keyframe yet?
    double actual_start = seg_start, actual_end = seg_end;

    AVPacket *pkt = av_packet_alloc();
    int wrote_any = 0;
    while ((ret = av_read_frame(s->in, pkt)) >= 0) {
        int si = pkt->stream_index;
        // Route via the input->output map (handles >1 audio stream in all_audio mode).
        int oidx = (si >= 0 && si < (int)s->in->nb_streams) ? s->out_index[si] : -1;
        if (oidx < 0) { av_packet_unref(pkt); continue; }

        AVStream *ist = s->in->streams[si];
        AVStream *ost = oc->streams[oidx];
        int64_t raw = (pkt->pts != AV_NOPTS_VALUE) ? pkt->pts
                    : (pkt->dts != AV_NOPTS_VALUE ? pkt->dts : 0);
        double t = raw * av_q2d(ist->time_base);
        int is_video = (si == sel.vid_src);
        int is_kf = (pkt->flags & AV_PKT_FLAG_KEY) != 0;

        if (!is_video) {
            // AUDIO: bound by the segment's own [seg_start, seg_end) TIME window,
            // independent of the video keyframe boundaries. Across all segments the
            // audio windows tile [0, duration) with no gaps or overlaps, so the
            // concatenated single-file resource has complete, contiguous audio.
            //
            // The previous logic gated audio behind the first video keyframe AND
            // dropped audio with t >= seg_end while the video kept running to its
            // closing keyframe (actual_end >= seg_end). That permanently lost the audio
            // in [seg_end, next-video-keyframe) at EVERY segment boundary (~0.1-0.8s
            // each), so audio fell progressively behind video. HLS hid it by resyncing
            // both tracks per segment; the single-file resource accumulated the gaps
            // into seconds of A/V desync. (Bug #akm19m.)
            if (t < seg_start - 1e-6) { av_packet_unref(pkt); continue; } // prior segment
            if (t >= seg_end - 1e-6) {
                // Belongs to the next segment. With video present, keep reading so the
                // video can reach its closing keyframe; without video, we're done.
                av_packet_unref(pkt);
                if (!have_video) break;
                continue;
            }
            // else: in-window audio -> write below.
        } else {
            // VIDEO: keyframe-exact tiling. Skip until the opening keyframe, then stop
            // at the first keyframe at/after seg_end (that same keyframe opens the next
            // segment, so adjacent segments share the boundary keyframe).
            if (have_video && !started) {
                if (is_kf && t >= seg_start - 1e-6) {
                    started = 1;
                    actual_start = t;
                } else {
                    av_packet_unref(pkt);
                    continue;
                }
            }
            if (is_kf && started && t >= seg_end - 1e-6 && t > actual_start) {
                actual_end = t;
                av_packet_unref(pkt);
                break;
            }
        }

        av_packet_rescale_ts(pkt, ist->time_base, ost->time_base);
        pkt->pos = -1;
        pkt->stream_index = oidx;
        gm_ts_fixed f = gm_ts_next(&ts[oidx], pkt->pts, pkt->dts, pkt->duration);
        pkt->pts = f.pts; pkt->dts = f.dts;

        ret = av_interleaved_write_frame(oc, pkt);
        if (ret < 0) { set_err(err, errlen, "write_frame", ret); break; }
        wrote_any = 1;
    }
    av_packet_free(&pkt);
    // Report the VIDEO segment's real end (the closing keyframe pts) so EXTINF can match
    // the actual muxed span. Audio (no video) ends at its own frame boundary == seg_end.
    s->last_actual_end = (sel.vid_src >= 0) ? actual_end : seg_end;
    if (ret == AVERROR_EOF) ret = 0;

    if (ret == 0) {
        int wret = av_write_trailer(oc);
        if (wret < 0) { set_err(err, errlen, "write_trailer", wret); ret = wret; }
    }
    avio_flush(oc->pb);
    close_output(oc, avio, octx);

    if (ret == 0 && !wrote_any) { set_err(err, errlen, "empty segment", 0); ret = -1; }
    if (ret == 0) {
        int me = box_end_offset(buf->data, buf->len, "moov");
        if (me <= 0) { set_err(err, errlen, "moov not found", 0); return -1; }
        *moov_end = me;
    }
    return ret;
}

// Legacy entry: the muxed video+default-audio segment used by the single-resource
// (resource loader) engine and the default HLS video rendition.
static int produce(gm_stream *s, double seg_start, double seg_end,
                   double ts_offset_sec,
                   gm_buf *buf, int *moov_end, char *err, int errlen) {
    // The single muxed resource carries the video + ALL AVFoundation-compatible audio
    // tracks, so AVPlayer's native media-selection picker lists every audio track from
    // one playlist (no demuxed HLS rendition groups needed). The other audio tracks are
    // muxed alongside; AVPlayer plays the default and offers the rest in the picker.
    gm_sel sel = { s->video_in, s->audio_in, 1 };
    return produce_sel(s, seg_start, seg_end, ts_offset_sec, sel, buf, moov_end, err, errlen);
}

// ── open / probe / plan ───────────────────────────────────────────────────────

gm_stream *gm_stream_open(gm_source src, double target_seg_sec,
                          char *err, int errlen) {
    if (target_seg_sec <= 0) target_seg_sec = 6.0;
    ensure_init();

    gm_stream *s = calloc(1, sizeof(gm_stream));
    if (!s) { set_err(err, errlen, "oom", 0); return NULL; }
    s->src = src; s->video_in = -1; s->audio_in = -1; s->target_seg_sec = target_seg_sec;

    uint8_t *iob = av_malloc(GM_IO_BUFSZ);
    s->in_avio = avio_alloc_context(iob, GM_IO_BUFSZ, 0, s, in_read, NULL, in_seek);
    if (!s->in_avio) { av_free(iob); free(s); set_err(err, errlen, "alloc in avio", 0); return NULL; }

    s->in = avformat_alloc_context();
    if (!s->in) { av_free(s->in_avio->buffer); avio_context_free(&s->in_avio); free(s); set_err(err, errlen, "alloc in ctx", 0); return NULL; }
    s->in->pb = s->in_avio;
    // Bound probing: a long remux-grade MKV (e.g. a 100-minute TrueHD + 16 PGS-sub
    // remux) makes the DEFAULT find_stream_info read an enormous amount before it
    // settles every track's parameters, which can take minutes over the network.
    // We only stream-copy the best video+audio, so a few MB / a few seconds of
    // analysis is plenty to learn their codecpar. (probesize floor is 32 each.)
    s->in->probesize = 2 * 1024 * 1024;       // 2 MiB (enough for codecpar; keeps OPEN fast)
    s->in->max_analyze_duration = 2 * AV_TIME_BASE;  // 2 s

    int ret = avformat_open_input(&s->in, NULL, NULL, NULL);
    if (ret < 0) { set_err(err, errlen, "open input", ret); gm_stream_close(s); return NULL; }
    ret = avformat_find_stream_info(s->in, NULL);
    if (ret < 0) { set_err(err, errlen, "find stream info", ret); gm_stream_close(s); return NULL; }

    s->video_in = gm_auto_select(s->in, AVMEDIA_TYPE_VIDEO);
    s->audio_in = gm_auto_select(s->in, AVMEDIA_TYPE_AUDIO);
    if (s->video_in < 0 && s->audio_in < 0) {
        set_err(err, errlen, "no AVFoundation-compatible streams", 0);
        gm_stream_close(s); return NULL;
    }

    s->duration = (s->in->duration > 0) ? (double)s->in->duration / AV_TIME_BASE : 0.0;

    int plan_stream = s->video_in >= 0 ? s->video_in : s->audio_in;
    AVStream *vst = s->in->streams[plan_stream];

    // Use whatever keyframe index find_stream_info already populated WITHOUT forcing
    // a Cues parse. We deliberately do NOT seek-to-EOF-and-back here: over HTTP that
    // round-trip near the end of the file cost seconds at OPEN for zero playback
    // benefit (it just yields a denser index). The uniform time-grid plan is fine,
    // each segment's backward seek snaps to a real keyframe at mux time, so segments
    // stay keyframe-aligned and independently decodable either way. (Time-to-first-
    // frame matters more than perfectly even segment boundaries.)
    int n_entries = avformat_index_get_entries_count(vst);
    int want_segs = (s->duration > 0) ? (int)(s->duration / target_seg_sec) : 0;
    int dense = (n_entries >= 2) && (want_segs <= 1 || n_entries >= want_segs / 2);

    if (dense) {
        double *kf = malloc(sizeof(double) * (size_t)n_entries);
        int n_kf = 0;
        for (int i = 0; i < n_entries; i++) {
            const AVIndexEntry *e = avformat_index_get_entry(vst, i);
            if (!e) continue;
            if (s->video_in >= 0 && !(e->flags & AVINDEX_KEYFRAME)) continue;
            kf[n_kf++] = e->timestamp * av_q2d(vst->time_base);
        }
        if (n_kf >= 2) {
            if (s->duration <= 0) s->duration = kf[n_kf - 1] + target_seg_sec;
            s->n_seg = gm_plan_segments(kf, n_kf, s->duration, target_seg_sec,
                                        s->seg_starts, GM_MAX_SEGS);
        }
        free(kf);
    }
    if (s->n_seg < 1) {  // sparse/no index: uniform time grid (muxer snaps to keyframes)
        if (s->duration <= 0) { set_err(err, errlen, "unknown duration", 0); gm_stream_close(s); return NULL; }
        s->n_seg = gm_plan_uniform(s->duration, target_seg_sec, s->seg_starts, GM_MAX_SEGS);
        if (getenv("GM_COLOR_DEBUG")) fprintf(stderr, "[plan] SPARSE uniform grid: %d segs (n_entries=%d want=%d)\n", s->n_seg, n_entries, want_segs);
    } else if (getenv("GM_COLOR_DEBUG")) {
        fprintf(stderr, "[plan] DENSE keyframe plan: %d segs (n_entries=%d)\n", s->n_seg, n_entries);
    }
    if (s->n_seg < 1) { set_err(err, errlen, "segment plan failed", 0); gm_stream_close(s); return NULL; }
    for (int i = 0; i < s->n_seg; i++) s->seg_real_end[i] = -1.0;
    return s;
}

// Resolve the REAL keyframe-aligned end time of segment i: the pts of the first VIDEO
// keyframe at/after the planned seg_starts[i+1] (the same keyframe that opens segment
// i+1). Video segments end here (keyframe-exact tiling), so audio MUST end here too for
// the renditions to tile identical windows (HLS demuxed playback requires aligned
// segment boundaries; a planned-grid EXTINF that disagrees makes AVPlayer fail -12646).
// Cached. Seeks the shared demuxer, so callers must hold the same serialization as the
// segment producers. With no video, the planned end is exact. The last segment ends at
// duration. Cheap: reads keyframe-flagged packet headers only, no decode.
static double resolve_real_end(gm_stream *s, int i) {
    if (i < 0 || i >= s->n_seg) return s->duration;
    if (s->seg_real_end[i] >= 0) return s->seg_real_end[i];
    double planned_end = (i + 1 < s->n_seg) ? s->seg_starts[i + 1] : s->duration;
    if (s->video_in < 0) { s->seg_real_end[i] = planned_end; return planned_end; }

    AVStream *vst = s->in->streams[s->video_in];
    int64_t seek_ts = (int64_t)(planned_end / av_q2d(vst->time_base) + 0.5);
    if (av_seek_frame(s->in, s->video_in, seek_ts, AVSEEK_FLAG_BACKWARD) < 0) {
        s->seg_real_end[i] = planned_end; return planned_end;
    }
    double real = planned_end;
    AVPacket *pkt = av_packet_alloc();
    int guard = 0;
    while (guard++ < 4096 && av_read_frame(s->in, pkt) >= 0) {
        if (pkt->stream_index == s->video_in && (pkt->flags & AV_PKT_FLAG_KEY)) {
            int64_t raw = (pkt->pts != AV_NOPTS_VALUE) ? pkt->pts : pkt->dts;
            double t = (raw == AV_NOPTS_VALUE) ? planned_end : raw * av_q2d(vst->time_base);
            if (t >= planned_end - 1e-6) { real = t; av_packet_unref(pkt); break; }
        }
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
    s->seg_real_end[i] = real;
    return real;
}

// The real closing-keyframe end of VIDEO segment i, as the muxer actually produces it.
// Produces the segment once (discarding the bytes) and caches its actual_end, so EXTINF
// matches the real muxed span exactly (resolve_real_end's keyframe guess was ~1 frame
// off, which made AVPlayer reject the demuxed combination, -12646).
static double video_real_end(gm_stream *s, int i) {
    if (i < 0 || i >= s->n_seg) return s->duration;
    if (s->seg_real_end[i] >= 0) return s->seg_real_end[i];
    if (s->video_in < 0) { s->seg_real_end[i] = (i + 1 < s->n_seg) ? s->seg_starts[i + 1] : s->duration; return s->seg_real_end[i]; }
    gm_sel sel = { s->video_in, -1 };
    double start = s->seg_starts[i];
    double end = (i + 1 < s->n_seg) ? s->seg_starts[i + 1] : s->duration + 1.0;
    gm_buf tmp = {0};
    int moov = 0;
    char e[64];
    s->last_actual_end = end;
    if (produce_sel(s, start, end, start, sel, &tmp, &moov, e, sizeof(e)) == 0) {
        s->seg_real_end[i] = s->last_actual_end;
    } else {
        s->seg_real_end[i] = end;
    }
    if (tmp.data) free(tmp.data);
    return s->seg_real_end[i];
}

// Public: the actual VIDEO duration of segment i (for the video rendition's EXTINF).
double gm_stream_real_segment_duration(gm_stream *s, int i) {
    if (!s || i < 0 || i >= s->n_seg) return 0.0;
    double start = (i > 0) ? video_real_end(s, i - 1) : s->seg_starts[0];
    double end = video_real_end(s, i);
    double d = end - start;
    return d > 0.0 ? d : 0.0;
}

// The real END time of an AUDIO segment: the pts of the first audio frame of `src`
// at/after the planned boundary `t`. Audio frames are whole units (e.g. AC-3 = 32ms),
// so the segment ends on a frame boundary, which differs from the video keyframe end.
// Each audio rendition tiles on its own frame grid; EXTINF reports its OWN span, and
// AVPlayer aligns video+audio by absolute tfdt, not by matching segment lengths.
static double audio_frame_boundary(gm_stream *s, int src, double t) {
    if (src < 0 || src >= (int)s->in->nb_streams) return t;
    AVStream *ast = s->in->streams[src];
    int64_t seek_ts = (int64_t)(t / av_q2d(ast->time_base) + 0.5);
    if (av_seek_frame(s->in, src, seek_ts, AVSEEK_FLAG_BACKWARD) < 0) return t;
    double real = t;
    AVPacket *pkt = av_packet_alloc();
    int guard = 0;
    while (guard++ < 8192 && av_read_frame(s->in, pkt) >= 0) {
        if (pkt->stream_index == src) {
            int64_t raw = (pkt->pts != AV_NOPTS_VALUE) ? pkt->pts : pkt->dts;
            double pt = (raw == AV_NOPTS_VALUE) ? t : raw * av_q2d(ast->time_base);
            if (pt >= t - 1e-6) { real = pt; av_packet_unref(pkt); break; }
        }
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
    return real;
}

// Public: the actual duration of AUDIO segment i for source `src` (its own EXTINF).
double gm_stream_real_audio_segment_duration(gm_stream *s, int src, int i) {
    if (!s || i < 0 || i >= s->n_seg) return 0.0;
    double pStart = s->seg_starts[i];
    double pEnd = (i + 1 < s->n_seg) ? s->seg_starts[i + 1] : s->duration;
    double start = (i > 0) ? audio_frame_boundary(s, src, pStart) : s->seg_starts[0];
    double end = audio_frame_boundary(s, src, pEnd);
    double d = end - start;
    return d > 0.0 ? d : 0.0;
}

double gm_stream_duration(const gm_stream *s) { return s ? s->duration : 0.0; }
int gm_stream_segment_count(const gm_stream *s) { return s ? s->n_seg : 0; }

int gm_stream_color_info(const gm_stream *s, gm_color_info *out) {
    if (!out) return -1;
    out->transfer = -1; out->primaries = -1; out->matrix = -1; out->range = -1;
    out->dolby_vision = 0; out->dovi_profile = 0;
    out->has_mastering = 0; out->has_hdr10plus = 0;
    if (!s || s->video_in < 0 || !s->in) return -1;
    AVStream *st = s->in->streams[s->video_in];
    AVCodecParameters *par = st->codecpar;
    out->transfer  = (int)par->color_trc;
    out->primaries = (int)par->color_primaries;
    out->matrix    = (int)par->color_space;
    out->range     = (int)par->color_range;
    // Coded side data carries the HDR format signalling: a Dolby Vision config record,
    // static mastering-display + content-light (HDR10), and dynamic HDR10+ (ST 2094-40).
    // NB: these are enum constants, not #defines, so a `#if defined(...)` guard around
    // them is ALWAYS false and silently compiles the checks out. Reference them directly.
    for (int i = 0; i < par->nb_coded_side_data; i++) {
        const AVPacketSideData *sd = &par->coded_side_data[i];
        if (sd->type == AV_PKT_DATA_DOVI_CONF && sd->data && sd->size >= 3) {
            out->dolby_vision = 1;
            out->dovi_profile = sd->data[2]; // dv_profile is the 3rd byte of the DOVI record
        } else if (sd->type == AV_PKT_DATA_MASTERING_DISPLAY_METADATA) {
            out->has_mastering = 1;
        } else if (sd->type == AV_PKT_DATA_DYNAMIC_HDR10_PLUS) {
            out->has_hdr10plus = 1;
        }
    }
    return 0;
}

int gm_stream_is_hdr(const gm_stream *s) {
    gm_color_info ci;
    if (gm_stream_color_info(s, &ci) != 0) return 0;
    return (ci.transfer == AVCOL_TRC_SMPTE2084 || ci.transfer == AVCOL_TRC_ARIB_STD_B67) ? 1 : 0;
}

// ── Track enumeration ──────────────────────────────────────────────────────────

int gm_stream_track_count(const gm_stream *s) {
    return (s && s->in) ? (int)s->in->nb_streams : 0;
}

int gm_stream_selected_video(const gm_stream *s) { return s ? s->video_in : -1; }
int gm_stream_selected_audio(const gm_stream *s) { return s ? s->audio_in : -1; }

// 1 if a subtitle codec is TEXT (convertible to WebVTT), 0 if image-based (PGS/dvdsub)
// which cannot be carried as HLS text subtitles.
static int is_text_subtitle(enum AVCodecID id) {
    switch (id) {
        case AV_CODEC_ID_SUBRIP:
        case AV_CODEC_ID_TEXT:
        case AV_CODEC_ID_ASS:
        case AV_CODEC_ID_SSA:
        case AV_CODEC_ID_MOV_TEXT:
        case AV_CODEC_ID_WEBVTT:
            return 1;
        default: // hdmv_pgs_subtitle, dvd_subtitle, dvb_subtitle, xsub, ...
            return 0;
    }
}

int gm_stream_track_info(const gm_stream *s, int i, gm_track_info *out) {
    if (!s || !s->in || !out || i < 0 || i >= (int)s->in->nb_streams) return -1;
    memset(out, 0, sizeof(*out));
    AVStream *st = s->in->streams[i];
    AVCodecParameters *par = st->codecpar;
    out->src_index = i;

    switch (par->codec_type) {
        case AVMEDIA_TYPE_VIDEO:    out->kind = GM_TRACK_VIDEO; break;
        case AVMEDIA_TYPE_AUDIO:    out->kind = GM_TRACK_AUDIO; break;
        case AVMEDIA_TYPE_SUBTITLE: out->kind = GM_TRACK_SUBTITLE; break;
        default:                    out->kind = 0; break;
    }

    const AVCodecDescriptor *desc = avcodec_descriptor_get(par->codec_id);
    snprintf(out->codec, sizeof(out->codec), "%s", desc ? desc->name : "");

    AVDictionaryEntry *lang = av_dict_get(st->metadata, "language", NULL, 0);
    if (lang && lang->value) snprintf(out->language, sizeof(out->language), "%s", lang->value);
    AVDictionaryEntry *title = av_dict_get(st->metadata, "title", NULL, 0);
    if (title && title->value) snprintf(out->title, sizeof(out->title), "%s", title->value);

    out->channels = (par->codec_type == AVMEDIA_TYPE_AUDIO) ? par->ch_layout.nb_channels : 0;
    out->width = (par->codec_type == AVMEDIA_TYPE_VIDEO) ? par->width : 0;
    out->height = (par->codec_type == AVMEDIA_TYPE_VIDEO) ? par->height : 0;
    if (par->codec_type == AVMEDIA_TYPE_VIDEO) {
        AVRational fr = st->avg_frame_rate;
        if (fr.num <= 0 || fr.den <= 0) fr = st->r_frame_rate;
        if (fr.num > 0 && fr.den > 0) { out->fps_num = fr.num; out->fps_den = fr.den; }
    }
    out->is_default = (st->disposition & AV_DISPOSITION_DEFAULT) ? 1 : 0;
    out->avf_compatible = gm_codec_is_avf_compatible(par->codec_id) ? 1 : 0;
    out->is_text_sub = (par->codec_type == AVMEDIA_TYPE_SUBTITLE) ? is_text_subtitle(par->codec_id) : 0;
    return 0;
}

double gm_stream_segment_start(const gm_stream *s, int i) {
    return (s && i >= 0 && i < s->n_seg) ? s->seg_starts[i] : 0.0;
}
double gm_stream_segment_duration(const gm_stream *s, int i) {
    return s ? gm_plan_segment_duration(s->seg_starts, s->n_seg, s->duration, i) : 0.0;
}
int gm_stream_time_to_segment(const gm_stream *s, double t) {
    return s ? gm_plan_time_to_index(s->seg_starts, s->n_seg, t) : -1;
}

int gm_stream_init_segment(gm_stream *s, gm_buf *out, char *err, int errlen) {
    if (!s || !out) return -1;
    int moov_end = 0;
    double end = (s->n_seg > 1) ? s->seg_starts[1] : s->duration + 1.0;
    int ret = produce(s, s->seg_starts[0], end, 0.0, out, &moov_end, err, errlen);
    if (ret < 0) return ret;
    out->len = moov_end;                  // keep only ftyp+moov
    return 0;
}

int gm_stream_make_unit(gm_stream *s, int i, gm_buf *out, int *moov_end, char *err, int errlen) {
    if (!s || !out || !moov_end || i < 0 || i >= s->n_seg) {
        set_err(err, errlen, "bad segment index", 0);
        return -1;
    }
    int me = 0;
    double start = s->seg_starts[i];
    double end = (i + 1 < s->n_seg) ? s->seg_starts[i + 1] : s->duration + 1.0;
    // ts_offset is the segment start (matches gm_stream_make_segment) so tfdt lands
    // at the absolute timeline position. Returns the full ftyp+moov+moof+mdat unit.
    int ret = produce(s, start, end, start, out, &me, err, errlen);
    if (ret < 0) return ret;
    if (me <= 0 || me >= out->len) { set_err(err, errlen, "bad moov split", 0); return -1; }
    *moov_end = me;
    return 0;
}

int gm_stream_make_segment(gm_stream *s, int i, gm_buf *out, char *err, int errlen) {
    if (!s || !out || i < 0 || i >= s->n_seg) { set_err(err, errlen, "bad segment index", 0); return -1; }
    int moov_end = 0;
    double start = s->seg_starts[i];
    double end = (i + 1 < s->n_seg) ? s->seg_starts[i + 1] : s->duration + 1.0;
    // Offset the muxer's (rebased-to-zero) output by the segment's absolute start
    // so this fragment's tfdt lands at its real timeline position.
    int ret = produce(s, start, end, start, out, &moov_end, err, errlen);
    if (ret < 0) return ret;
    int media = out->len - moov_end;      // keep only moof+mdat...
    if (media <= 0) { set_err(err, errlen, "empty media segment", 0); return -1; }
    memmove(out->data, out->data + moov_end, (size_t)media);
    out->len = media;
    return 0;
}

// ── Demuxed per-rendition segments ─────────────────────────────────────────────

// Produce a single-track (video-only or audio-only) full unit over segment i, then
// keep either the init prefix (want_init) or the media suffix.
static int produce_single(gm_stream *s, gm_sel sel, int i, int want_init,
                          gm_buf *out, char *err, int errlen) {
    if (!s || !out || i < 0 || i >= s->n_seg) { set_err(err, errlen, "bad segment index", 0); return -1; }
    int moov_end = 0;
    // Each rendition tiles on its OWN frame boundaries (no shared window): video
    // keyframe-tiles to the next keyframe; audio time-windows on [seg_starts[i],
    // seg_starts[i+1]) which lands on whole audio frames. They have different real
    // segment durations, but each rendition's timeline is internally gap/overlap-free,
    // and AVPlayer aligns the demuxed renditions via absolute tfdt, not matching lengths.
    // (Tying audio to video keyframe times caused audio-frame overlap -> AVPlayer hang.)
    double start = s->seg_starts[i];
    double end = (i + 1 < s->n_seg) ? s->seg_starts[i + 1] : s->duration + 1.0;
    int ret = produce_sel(s, start, end, start, sel, out, &moov_end, err, errlen);
    if (ret < 0) return ret;
    if (moov_end <= 0 || moov_end >= out->len) { set_err(err, errlen, "bad moov split", 0); return -1; }
    if (want_init) {
        out->len = moov_end;              // keep ftyp+moov only
    } else {
        int media = out->len - moov_end;  // keep moof+mdat...
        if (media <= 0) { set_err(err, errlen, "empty media segment", 0); return -1; }
        memmove(out->data, out->data + moov_end, (size_t)media);
        out->len = media;
    }
    return 0;
}

int gm_stream_video_init(gm_stream *s, gm_buf *out, char *err, int errlen) {
    if (!s || s->video_in < 0) { set_err(err, errlen, "no video track", 0); return -1; }
    gm_sel sel = { s->video_in, -1 };
    return produce_single(s, sel, 0, 1, out, err, errlen);
}

int gm_stream_video_segment(gm_stream *s, int i, gm_buf *out, char *err, int errlen) {
    if (!s || s->video_in < 0) { set_err(err, errlen, "no video track", 0); return -1; }
    gm_sel sel = { s->video_in, -1 };
    return produce_single(s, sel, i, 0, out, err, errlen);
}

int gm_stream_audio_init(gm_stream *s, int src, gm_buf *out, char *err, int errlen) {
    if (!s || src < 0 || src >= (int)s->in->nb_streams ||
        s->in->streams[src]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
        set_err(err, errlen, "bad audio source", 0); return -1;
    }
    gm_sel sel = { -1, src };
    return produce_single(s, sel, 0, 1, out, err, errlen);
}

int gm_stream_audio_segment(gm_stream *s, int src, int i, gm_buf *out, char *err, int errlen) {
    if (!s || src < 0 || src >= (int)s->in->nb_streams ||
        s->in->streams[src]->codecpar->codec_type != AVMEDIA_TYPE_AUDIO) {
        set_err(err, errlen, "bad audio source", 0); return -1;
    }
    gm_sel sel = { -1, src };
    return produce_single(s, sel, i, 0, out, err, errlen);
}

// ── Subtitles -> WebVTT (HLS TYPE=SUBTITLES renditions) ─────────────────────────
// Image subs (PGS/VobSub) can't become WebVTT; only TEXT subs (subrip/ass/mov_text)
// are carried. We DECODE the source text subtitle to AVSubtitle, then format each cue
// as a WebVTT block with ABSOLUTE movie timestamps (matching Apple's
// mediasubtitlesegmenter output). A cue overlapping a segment boundary is emitted in
// BOTH neighbouring segments so it stays on screen across a segment fetch.

static void vtt_append(gm_buf *b, const char *str, int n) {
    if (n < 0) n = (int)strlen(str);
    if (buf_ensure(b, b->len + n) < 0) return;
    memcpy(b->data + b->len, str, (size_t)n);
    b->len += n;
}

// "HH:MM:SS.mmm" per WebVTT.
static void vtt_time(gm_buf *b, double t) {
    if (t < 0) t = 0;
    long ms = (long)(t * 1000.0 + 0.5);
    int h = (int)(ms / 3600000); ms -= (long)h * 3600000;
    int m = (int)(ms / 60000);   ms -= (long)m * 60000;
    int sec = (int)(ms / 1000);  ms -= (long)sec * 1000;
    char tmp[32];
    snprintf(tmp, sizeof(tmp), "%02d:%02d:%02d.%03d", h, m, sec, (int)ms);
    vtt_append(b, tmp, -1);
}

// Extract the displayable text from one ASS dialogue line ("...,Text") into `b`,
// stripping {\override} tags and converting "\N"/"\n" to real newlines. subrip/ass/
// mov_text decoders all set rect->ass in this canonical 9-comma dialogue format.
static void vtt_emit_ass_text(gm_buf *b, const char *ass) {
    if (!ass) return;
    // Skip the first 8 commas (Layer,Start,End,Style,Name,MarginL,MarginR,MarginV,Effect)
    const char *p = ass;
    for (int commas = 0; *p && commas < 8; p++) if (*p == ',') commas++;
    // p now points at the Text field (may itself contain commas; keep all of it).
    int brace = 0;
    for (; *p; p++) {
        if (*p == '{') { brace = 1; continue; }
        if (*p == '}') { brace = 0; continue; }
        if (brace) continue;
        if (p[0] == '\\' && (p[1] == 'N' || p[1] == 'n')) { vtt_append(b, "\n", 1); p++; continue; }
        if (*p == '\r') continue;
        vtt_append(b, p, 1);
    }
}

// Open (and cache nothing; cheap) a decoder context for subtitle stream `src`.
static AVCodecContext *open_sub_decoder(gm_stream *s, int src) {
    AVStream *ist = s->in->streams[src];
    const AVCodec *dec = avcodec_find_decoder(ist->codecpar->codec_id);
    if (!dec) return NULL;
    AVCodecContext *cc = avcodec_alloc_context3(dec);
    if (!cc) return NULL;
    if (avcodec_parameters_to_context(cc, ist->codecpar) < 0) { avcodec_free_context(&cc); return NULL; }
    if (avcodec_open2(cc, dec, NULL) < 0) { avcodec_free_context(&cc); return NULL; }
    return cc;
}

// Produce the WebVTT text segment for subtitle source `src`, segment `i`. Writes a
// complete .webvtt body (header + X-TIMESTAMP-MAP + cues) into `out`.
int gm_stream_subtitle_segment(gm_stream *s, int src, int i, gm_buf *out, char *err, int errlen) {
    if (!s || !out || src < 0 || src >= (int)s->in->nb_streams) {
        set_err(err, errlen, "bad subtitle source", 0); return -1;
    }
    if (i < 0 || i >= s->n_seg) { set_err(err, errlen, "bad segment index", 0); return -1; }
    AVStream *ist = s->in->streams[src];
    if (ist->codecpar->codec_type != AVMEDIA_TYPE_SUBTITLE) {
        set_err(err, errlen, "not a subtitle track", 0); return -1;
    }

    double seg_start = s->seg_starts[i];
    double seg_end = (i + 1 < s->n_seg) ? s->seg_starts[i + 1] : s->duration;

    out->len = 0;
    // Fixed header matching Apple's mediasubtitlesegmenter (MPEGTS:900000 = 10s @ 90kHz,
    // LOCAL 0 -> WebVTT cue times ARE absolute media times).
    vtt_append(out, "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000\n\n", -1);

    AVCodecContext *dec = open_sub_decoder(s, src);
    if (!dec) { set_err(err, errlen, "open sub decoder", 0); return -1; }

    // Seek a little before the segment so a cue that STARTED earlier but is still on
    // screen at seg_start is decoded and emitted (overlap rule).
    double seek_to = seg_start > 30.0 ? seg_start - 30.0 : 0.0;
    int64_t seek_ts = (int64_t)(seek_to / av_q2d(ist->time_base) + 0.5);
    av_seek_frame(s->in, src, seek_ts, AVSEEK_FLAG_BACKWARD);

    AVPacket *pkt = av_packet_alloc();
    AVSubtitle sub;
    int got = 0, ncues = 0, guard = 0;
    while (guard++ < 100000 && av_read_frame(s->in, pkt) >= 0) {
        if (pkt->stream_index != src) { av_packet_unref(pkt); continue; }
        double pts = (pkt->pts != AV_NOPTS_VALUE ? pkt->pts : pkt->dts) * av_q2d(ist->time_base);
        double dur = pkt->duration > 0 ? pkt->duration * av_q2d(ist->time_base) : 0.0;
        // Past this segment (account for cues that may carry their own display window).
        if (pts >= seg_end) { av_packet_unref(pkt); break; }

        memset(&sub, 0, sizeof(sub));
        int ok = avcodec_decode_subtitle2(dec, &sub, &got, pkt);
        av_packet_unref(pkt);
        if (ok < 0 || !got) { if (got) avsubtitle_free(&sub); continue; }

        // Cue times: prefer the subtitle's own display window (start/end_display_time are
        // ms relative to pts); fall back to the packet duration.
        double cstart = pts + sub.start_display_time / 1000.0;
        double cend = (sub.end_display_time > sub.start_display_time)
            ? pts + sub.end_display_time / 1000.0
            : (dur > 0 ? pts + dur : pts + 5.0);

        // Overlap test against [seg_start, seg_end): keep the cue if it is visible at any
        // point inside this segment.
        if (cend > seg_start && cstart < seg_end) {
            gm_buf text = {0};
            for (unsigned r = 0; r < sub.num_rects; r++) {
                AVSubtitleRect *rect = sub.rects[r];
                if (rect->ass) vtt_emit_ass_text(&text, rect->ass);
                else if (rect->text) vtt_append(&text, rect->text, -1);
                if (r + 1 < sub.num_rects) vtt_append(&text, "\n", 1);
            }
            // Trim trailing whitespace/newlines.
            while (text.len > 0 && (text.data[text.len - 1] == '\n' || text.data[text.len - 1] == ' '))
                text.len--;
            if (text.len > 0) {
                vtt_time(out, cstart);
                vtt_append(out, " --> ", 5);
                vtt_time(out, cend);
                vtt_append(out, "\n", 1);
                vtt_append(out, (const char *)text.data, text.len);
                vtt_append(out, "\n\n", 2);
                ncues++;
            }
            free(text.data);
        }
        avsubtitle_free(&sub);
    }
    av_packet_free(&pkt);
    avcodec_free_context(&dec);
    (void)ncues;
    return 0;
}

void gm_stream_close(gm_stream *s) {
    if (!s) return;
    if (s->in) avformat_close_input(&s->in);
    if (s->in_avio) { av_free(s->in_avio->buffer); avio_context_free(&s->in_avio); }
    free(s);
}
