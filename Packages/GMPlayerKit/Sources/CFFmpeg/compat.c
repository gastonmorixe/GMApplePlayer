//
//  compat.c
//  AVFoundation compatibility policy + stream scoring/selection, plus error
//  formatting. The single source of truth for "what can Apple play" and "which
//  track should we pick" (Strategy-style scoring), shared by probe.c & remux.c.
//
#include "gm_internal.h"

#include <libavutil/error.h>

void gm_set_err(char *buf, int len, const char *fmt, int averr) {
    if (!buf || len <= 0) return;
    char av[AV_ERROR_MAX_STRING_SIZE] = {0};
    av_strerror(averr, av, sizeof(av));
    snprintf(buf, (size_t)len, "%s (%s)", fmt, av);
}

// AVFoundation can play these inside an MP4/MOV container (decode support on
// macOS/iOS/tvOS). Conservative allow-list; everything else we skip.
bool gm_codec_is_avf_compatible(enum AVCodecID id) {
    switch (id) {
        // Video
        case AV_CODEC_ID_HEVC:        // HEVC / H.265 (tag hvc1), incl. HDR10
        case AV_CODEC_ID_H264:        // AVC / H.264 (tag avc1)
        case AV_CODEC_ID_MPEG4:       // MPEG-4 Part 2
        case AV_CODEC_ID_PRORES:      // ProRes
            return true;
        // Audio
        case AV_CODEC_ID_AAC:         // AAC-LC / HE-AAC
        case AV_CODEC_ID_AC3:         // Dolby Digital
        case AV_CODEC_ID_EAC3:        // Dolby Digital Plus
        case AV_CODEC_ID_ALAC:        // Apple Lossless
        case AV_CODEC_ID_MP3:
        case AV_CODEC_ID_PCM_S16LE:   // LPCM
        case AV_CODEC_ID_PCM_S16BE:
            return true;
        default:
            return false;
    }
}

GMStreamKind gm_kind_for(enum AVMediaType t) {
    switch (t) {
        case AVMEDIA_TYPE_VIDEO:    return GM_STREAM_VIDEO;
        case AVMEDIA_TYPE_AUDIO:    return GM_STREAM_AUDIO;
        case AVMEDIA_TYPE_SUBTITLE: return GM_STREAM_SUBTITLE;
        default:                    return GM_STREAM_UNKNOWN;
    }
}

// Codec desirability for audio: prefer the richest codec AVFoundation can
// decode. E-AC-3 (DD+) can carry Atmos (JOC) and beats plain AC-3; ALAC is
// lossless. Higher score wins.
static int audio_codec_rank(enum AVCodecID id) {
    switch (id) {
        case AV_CODEC_ID_ALAC: return 50;
        case AV_CODEC_ID_EAC3: return 40;
        case AV_CODEC_ID_AC3:  return 30;
        case AV_CODEC_ID_AAC:  return 20;
        case AV_CODEC_ID_MP3:  return 10;
        default:               return 5;
    }
}

// Video: prefer compatible, then higher resolution; tiny DEFAULT tiebreak.
static long video_score(AVStream *st) {
    AVCodecParameters *par = st->codecpar;
    if (!gm_codec_is_avf_compatible(par->codec_id)) return -1;
    long score = (long)par->width * par->height;
    if (st->disposition & AV_DISPOSITION_DEFAULT) score += 1;
    return score;
}

// Audio: codec rank PRIMARY (E-AC-3 feature track over an AC-3 "companion"
// track that may be the DEFAULT), channels secondary, tiny DEFAULT tiebreak.
static long audio_score(AVStream *st) {
    AVCodecParameters *par = st->codecpar;
    if (!gm_codec_is_avf_compatible(par->codec_id)) return -1;
    int channels = par->ch_layout.nb_channels;
    long score = (long)audio_codec_rank(par->codec_id) * 1000;
    score += (long)channels * 10;
    if (st->disposition & AV_DISPOSITION_DEFAULT) score += 1;
    return score;
}

int gm_auto_select(AVFormatContext *fmt, enum AVMediaType type) {
    int best = -1;
    long best_score = -1;
    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVStream *st = fmt->streams[i];
        if (st->codecpar->codec_type != type) continue;
        long s = (type == AVMEDIA_TYPE_VIDEO) ? video_score(st) : audio_score(st);
        if (s > best_score) { best_score = s; best = (int)i; }
    }
    return best;
}
