//
//  remux.c
//  The stream-copy remux: select streams, create the MP4 output, copy packets
//  with correct timestamps, and finalize. No transcode. See gm_internal.h /
//  compat.c for the AVFoundation-compat selection policy.
//
#include "gm_internal.h"
#include "gm_ts.h"

#include <libavformat/avio.h>

int gm_remux_to_fmp4(const char *input_url,
                     const char *output_path,
                     int video_stream,
                     int audio_stream,
                     gm_progress_cb progress,
                     void *progress_ctx,
                     char *errbuf, int errbuf_len) {
    if (!input_url || !output_path) return -1;
    gm_init();

    AVFormatContext *in = NULL, *out = NULL;
    int *stream_map = NULL;        // in-index -> out-index (or -1)
    gm_ts_state *ts_state = NULL;  // per-output-stream timestamp policy state
    AVPacket *pkt = NULL;
    int ret = 0;

    ret = avformat_open_input(&in, input_url, NULL, NULL);
    if (ret < 0) { gm_set_err(errbuf, errbuf_len, "open input failed", ret); goto done; }
    ret = avformat_find_stream_info(in, NULL);
    if (ret < 0) { gm_set_err(errbuf, errbuf_len, "find stream info failed", ret); goto done; }

    if (video_stream == -1) video_stream = gm_auto_select(in, AVMEDIA_TYPE_VIDEO);
    if (audio_stream == -1) audio_stream = gm_auto_select(in, AVMEDIA_TYPE_AUDIO);

    if (video_stream < 0 && audio_stream < 0) {
        snprintf(errbuf, errbuf_len, "no AVFoundation-compatible streams found");
        ret = AVERROR_INVALIDDATA; goto done;
    }

    ret = avformat_alloc_output_context2(&out, NULL, "mp4", output_path);
    if (ret < 0 || !out) { gm_set_err(errbuf, errbuf_len, "alloc output failed", ret); goto done; }

    stream_map = av_malloc_array(in->nb_streams, sizeof(int));
    for (unsigned i = 0; i < in->nb_streams; i++) stream_map[i] = -1;

    // Create output streams for the selected source streams (copy codecpar).
    int out_idx = 0;
    for (unsigned i = 0; i < in->nb_streams; i++) {
        if ((int)i != video_stream && (int)i != audio_stream) continue;

        AVStream *ist = in->streams[i];
        AVStream *ost = avformat_new_stream(out, NULL);
        if (!ost) { ret = AVERROR(ENOMEM); goto done; }

        ret = avcodec_parameters_copy(ost->codecpar, ist->codecpar);
        if (ret < 0) { gm_set_err(errbuf, errbuf_len, "copy codecpar failed", ret); goto done; }
        ost->codecpar->codec_tag = 0;

        // Force the fourcc AVFoundation expects.
        if (ist->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            if (ist->codecpar->codec_id == AV_CODEC_ID_HEVC)
                ost->codecpar->codec_tag = MKTAG('h', 'v', 'c', '1');
            else if (ist->codecpar->codec_id == AV_CODEC_ID_H264)
                ost->codecpar->codec_tag = MKTAG('a', 'v', 'c', '1');
        }

        AVDictionaryEntry *lang = av_dict_get(ist->metadata, "language", NULL, 0);
        if (lang) av_dict_set(&ost->metadata, "language", lang->value, 0);

        ost->time_base = ist->time_base;
        stream_map[i] = out_idx++;
    }

    if (!(out->oformat->flags & AVFMT_NOFILE)) {
        ret = avio_open(&out->pb, output_path, AVIO_FLAG_WRITE);
        if (ret < 0) { gm_set_err(errbuf, errbuf_len, "avio_open failed", ret); goto done; }
    }

    // Plain (non-fragmented) MP4 with the moov atom at the front (+faststart).
    // We fully remux before playback, so an indexed MP4 gives AVPlayer the best
    // buffering + seeking. (The earlier empty_moov+frag layout stalled on large
    // 4K fragments.)
    AVDictionary *mux_opts = NULL;
    av_dict_set(&mux_opts, "movflags", "faststart", 0);
    ret = avformat_write_header(out, &mux_opts);
    av_dict_free(&mux_opts);
    if (ret < 0) { gm_set_err(errbuf, errbuf_len, "write_header failed", ret); goto done; }

    // Per-output-stream timestamp policy. For a CFR video stream we drive a
    // uniform DTS ladder at the exact per-frame tick step (out_tb_den / fps),
    // leading PTS by a few frames so the B-frame reorder never forces a PTS
    // clamp. Audio (fps_num = 0) just preserves its already-monotonic DTS.
    // See gm_ts.c / CGMTimestampTests for the why and the regression guard.
    ts_state = av_malloc_array(out->nb_streams, sizeof(gm_ts_state));
    if (!ts_state) { ret = AVERROR(ENOMEM); goto done; }
    for (unsigned oi = 0; oi < out->nb_streams; oi++) {
        // Find the input stream feeding this output stream to read its frame rate.
        AVStream *src = NULL;
        for (unsigned i = 0; i < in->nb_streams; i++)
            if (stream_map[i] == (int)oi) { src = in->streams[i]; break; }

        int64_t fps_num = 0, fps_den = 0, lead = 0;
        if (src && src->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            // Prefer the container/codec average frame rate; fall back to r_frame_rate.
            AVRational fr = src->avg_frame_rate;
            if (fr.num <= 0 || fr.den <= 0) fr = src->r_frame_rate;
            if (fr.num > 0 && fr.den > 0) { fps_num = fr.num; fps_den = fr.den; }
            // Lead the ladder by the reorder depth (video_delay) plus a small
            // margin, clamped to a sane bound. A larger lead is always safe (it
            // only makes the first DTS more negative); too small risks pts<dts.
            int vd = src->codecpar->video_delay;
            lead = (vd > 0 ? vd : 1) + 2;
            if (lead > 16) lead = 16;
        }
        gm_ts_init(&ts_state[oi], fps_num, fps_den,
                   out->streams[oi]->time_base.num,
                   out->streams[oi]->time_base.den, lead);
    }

    pkt = av_packet_alloc();
    if (!pkt) { ret = AVERROR(ENOMEM); goto done; }

    double total = (in->duration > 0) ? (double)in->duration / AV_TIME_BASE : 0.0;

    while ((ret = av_read_frame(in, pkt)) >= 0) {
        int si = pkt->stream_index;
        if (si < 0 || (unsigned)si >= in->nb_streams || stream_map[si] < 0) {
            av_packet_unref(pkt);
            continue;
        }
        AVStream *ist = in->streams[si];
        int oi = stream_map[si];
        AVStream *ost = out->streams[oi];

        // DEBUG (env-gated, ships disabled): dump the RAW demuxer timestamps as
        // av_read_frame delivers them ("[gmraw] pts dts dur", pre-rescale). This
        // is the ground truth for the timestamp policy: ffprobe's displayed dts is
        // a clean reconstruction and differs from what the API actually hands us
        // (the demuxer gives dts == pts here). Set GM_TS_DEBUG=1 to enable.
        if (getenv("GM_TS_DEBUG") && ist->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {
            fprintf(stderr, "[gmraw] %lld %lld %lld\n",
                    (long long)pkt->pts, (long long)pkt->dts,
                    (long long)pkt->duration);
        }

        av_packet_rescale_ts(pkt, ist->time_base, ost->time_base);
        pkt->pos = -1;
        pkt->stream_index = oi;

        // Fix up timestamps for the mov muxer. The Matroska demuxer hands this
        // B-frame video stream packets with dts == pts (non-monotonic), which the
        // muxer rejects. gm_ts_next replaces DTS with a uniform CFR ladder at the
        // exact per-frame step and leaves PTS exact, so the real 23.976fps cadence
        // is preserved (no bunching, no PTS clamp). GM_TS_NOPTS == AV_NOPTS_VALUE
        // == INT64_MIN, so values pass straight through.
        gm_ts_fixed ts = gm_ts_next(&ts_state[oi], pkt->pts, pkt->dts, pkt->duration);
        pkt->pts = ts.pts;
        pkt->dts = ts.dts;

        double cur = (pkt->pts != AV_NOPTS_VALUE)
            ? (double)pkt->pts * av_q2d(ost->time_base) : 0.0;

        ret = av_interleaved_write_frame(out, pkt);  // takes ownership, resets pkt
        if (ret < 0) { gm_set_err(errbuf, errbuf_len, "write_frame failed", ret); break; }

        if (progress && total > 0) {
            if (progress(cur / total, progress_ctx) != 0) {
                ret = AVERROR_EXIT;   // cancelled
                break;
            }
        }
    }
    if (ret == AVERROR_EOF) ret = 0;

    if (ret == 0) {
        int wret = av_write_trailer(out);
        if (wret < 0) { gm_set_err(errbuf, errbuf_len, "write_trailer failed", wret); ret = wret; }
    }

done:
    if (pkt) av_packet_free(&pkt);
    if (ts_state) av_free(ts_state);
    if (stream_map) av_free(stream_map);
    if (out) {
        if (out->pb && !(out->oformat->flags & AVFMT_NOFILE)) avio_closep(&out->pb);
        avformat_free_context(out);
    }
    if (in) avformat_close_input(&in);
    return ret;
}
