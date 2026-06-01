//
//  gm_internal.h
//  Private shared declarations for the CFFmpeg remux engine. NOT part of the
//  public CFFmpeg module API (that is include/gmremux.h). Split across
//  compat.c (codec policy + stream scoring), probe.c, and remux.c (SRP).
//
#ifndef GM_INTERNAL_H
#define GM_INTERNAL_H

#include "gmremux.h"

#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/dict.h>
#include <libavutil/error.h>
#include <libavutil/dovi_meta.h>
#include <libavutil/mathematics.h>

// ── error formatting (compat.c) ───────────────────────────────────────────────
void gm_set_err(char *buf, int len, const char *fmt, int averr);

// ── codec policy (compat.c) ───────────────────────────────────────────────────
/// True if AVFoundation can play this codec inside an MP4/MOV container.
bool gm_codec_is_avf_compatible(enum AVCodecID id);

/// Map an FFmpeg media type to the public GMStreamKind.
GMStreamKind gm_kind_for(enum AVMediaType t);

// ── stream selection / scoring (compat.c) ─────────────────────────────────────
/// Pick the best stream of `type` per the AVFoundation-compat scoring policy.
/// Returns the source stream index, or -1 if none is compatible.
int gm_auto_select(AVFormatContext *fmt, enum AVMediaType type);

#endif /* GM_INTERNAL_H */
