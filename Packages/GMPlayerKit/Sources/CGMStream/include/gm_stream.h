//
//  gm_stream.h
//  On-demand streaming remux: open an MKV through a caller-provided byte source,
//  expose it as on-demand HLS fragmented-MP4 (init segment + media segments) so
//  AVPlayer (via an AVAssetResourceLoaderDelegate) can play and seek without
//  downloading or remuxing the whole file.
//
//  The caller (Swift) provides the INPUT bytes via gm_source callbacks (local
//  file read or HTTP byte-range GET). The engine demuxes on demand, stream-copies
//  the AVFoundation-compatible video+audio, and muxes fragmented MP4 segments into
//  a caller-owned growable buffer. No temp file, no server.
//
//  Threading: a gm_stream wraps one stateful demuxer; serialize calls to
//  gm_stream_make_segment / _init_segment on one queue per stream.
//
#ifndef GM_STREAM_H
#define GM_STREAM_H

#include <stdint.h>
#include "gm_plan.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Byte source for the INPUT media. Implemented by the caller (Swift).
typedef struct {
    void *ctx;
    /// Total size in bytes, or -1 if unknown (disables some seeks).
    int64_t (*size)(void *ctx);
    /// Read up to `n` bytes at absolute `offset` into `buf`. Return bytes read
    /// (0 == EOF) or a negative value on error.
    int (*read)(void *ctx, int64_t offset, uint8_t *buf, int n);
} gm_source;

/// A growable output buffer owned by the caller. The engine appends via realloc.
typedef struct {
    uint8_t *data;  ///< malloc/realloc'd; caller frees with free().
    int      len;   ///< bytes used.
    int      cap;   ///< allocated capacity.
} gm_buf;

typedef struct gm_stream gm_stream;

/// Open the input via `src`, probe it, pick AVF-compatible video+audio, and build
/// the keyframe-aligned segment plan. Returns NULL on failure (err filled).
gm_stream *gm_stream_open(gm_source src, double target_seg_sec,
                          char *err, int errlen);

/// Total media duration in seconds (0 if unknown).
double gm_stream_duration(const gm_stream *s);

/// Color characteristics of the selected VIDEO stream, taken from the input
/// codec parameters at open. Values are the standard ISO/ITU enum numbers used by
/// FFmpeg (== the AVColor* enums == the H.265 VUI / MP4 `colr` nclx codes):
///   transfer 16 = SMPTE ST 2084 (PQ, HDR10), 18 = ARIB STD-B67 (HLG);
///   primaries 9 = BT.2020; matrix 9 = BT.2020 non-constant.
/// This lets the player report/handle HDR even when the playback transport (HLS)
/// does not surface the per-track color info to AVFoundation. All -1 if no video.
typedef struct {
    int transfer;     ///< AVColorTransferCharacteristic (16=PQ, 18=HLG, ...)
    int primaries;    ///< AVColorPrimaries (9=BT.2020, ...)
    int matrix;       ///< AVColorSpace / YCbCr matrix (9=BT.2020nc, ...)
    int range;        ///< AVColorRange (1=MPEG/limited, 2=JPEG/full)
    int dolby_vision; ///< 1 if a Dolby Vision configuration record is present, else 0
    int dovi_profile; ///< Dolby Vision profile (5/7/8/...), or 0
    int has_mastering;///< 1 if static mastering-display metadata (HDR10) is present
    int has_hdr10plus;///< 1 if dynamic HDR10+ (ST 2094-40) metadata was seen, else 0
} gm_color_info;

/// Fill `out` with the selected video stream's color characteristics. Returns 0 on
/// success, negative if there is no video stream (out is zeroed/-1 in that case).
int gm_stream_color_info(const gm_stream *s, gm_color_info *out);

/// True (1) if the selected video stream signals an HDR transfer function
/// (PQ / ST-2084 or HLG / ARIB STD-B67), else 0.
int gm_stream_is_hdr(const gm_stream *s);

// ── Track enumeration (for the multivariant HLS / native picker) ───────────────
// The engine plays one video + one audio by default but EXPOSES every track so the
// player can list them and switch on demand (a rendition's segments are muxed only
// when actually selected, never all up front).

typedef enum {
    GM_TRACK_VIDEO    = 1,
    GM_TRACK_AUDIO    = 2,
    GM_TRACK_SUBTITLE = 3,
} gm_track_kind;

typedef struct {
    int  src_index;      ///< source stream index (stable id for selection)
    int  kind;           ///< gm_track_kind
    char codec[16];      ///< e.g. "ac3", "eac3", "aac", "hevc", "subrip", "hdmv_pgs"
    char language[8];    ///< ISO 639 code, or "" if unknown
    char title[96];      ///< track title metadata, or ""
    int  channels;       ///< audio only (0 otherwise)
    int  width;          ///< video only (0 otherwise)
    int  height;         ///< video only (0 otherwise)
    int  fps_num;        ///< video only: frame-rate numerator (0 if unknown)
    int  fps_den;        ///< video only: frame-rate denominator (0 if unknown)
    int  is_default;     ///< 1 if the source marks this track DEFAULT
    int  avf_compatible; ///< 1 if AVFoundation can play/copy it inside fMP4 (HLS)
    int  is_text_sub;    ///< subtitle only: 1 if a TEXT subtitle (srt/ass/mov_text),
                         ///< 0 for image subs (PGS/dvdsub) that can't become WebVTT
} gm_track_info;

/// Number of tracks in the source (video+audio+subtitle).
int gm_stream_track_count(const gm_stream *s);

/// Fill `out` with track `i` (0-based over all tracks). Returns 0 on success.
int gm_stream_track_info(const gm_stream *s, int i, gm_track_info *out);

/// The source index of the default-selected video / audio track (-1 if none).
int gm_stream_selected_video(const gm_stream *s);
int gm_stream_selected_audio(const gm_stream *s);

// ── Demuxed per-rendition segments (multivariant HLS) ──────────────────────────
// These mux a SINGLE track into a segment so the native player can list & switch
// audio/video renditions. Produced on demand: a rendition's segments are built only
// when AVPlayer actually requests them (the selected track), never all up front.

/// Produce the video-only fMP4 init segment (ftyp+moov with just the video track).
int gm_stream_video_init(gm_stream *s, gm_buf *out, char *err, int errlen);
/// Produce video-only media segment `i` (moof+mdat, video only).
int gm_stream_video_segment(gm_stream *s, int i, gm_buf *out, char *err, int errlen);

/// The ACTUAL keyframe-aligned duration (seconds) of segment `i`, for EXTINF. Both the
/// video and audio rendition of segment `i` span exactly this, so their media playlists
/// agree and AVPlayer can combine the demuxed renditions. May seek the demuxer (serialize
/// with the segment producers); cached after first call.
double gm_stream_real_segment_duration(gm_stream *s, int i);

/// The actual duration (seconds) of AUDIO segment `i` for source index `src`, on the
/// audio frame grid (differs from the video keyframe duration; each rendition's EXTINF
/// reports its own span).
double gm_stream_real_audio_segment_duration(gm_stream *s, int src, int i);

/// Produce the audio-only init segment for the audio track at SOURCE index `src`.
int gm_stream_audio_init(gm_stream *s, int src, gm_buf *out, char *err, int errlen);
/// Produce audio-only media segment `i` for the audio track at SOURCE index `src`.
int gm_stream_audio_segment(gm_stream *s, int src, int i, gm_buf *out, char *err, int errlen);

/// Produce the WebVTT text segment for the (TEXT) subtitle track at SOURCE index `src`,
/// segment `i`. Writes a complete .webvtt body (WEBVTT header + X-TIMESTAMP-MAP + cues
/// with ABSOLUTE movie timestamps). A cue straddling a boundary is emitted in both
/// neighbouring segments. Only valid for text subs (subrip/ass/mov_text); image subs
/// (PGS/VobSub) are not carryable. Returns 0 on success.
int gm_stream_subtitle_segment(gm_stream *s, int src, int i, gm_buf *out, char *err, int errlen);

/// Number of segments in the plan.
int gm_stream_segment_count(const gm_stream *s);

/// Duration (seconds) of segment `i`, for the playlist EXTINF.
double gm_stream_segment_duration(const gm_stream *s, int i);

/// Start time (seconds) of segment `i`.
double gm_stream_segment_start(const gm_stream *s, int i);

/// Segment index containing playback time `t` seconds.
int gm_stream_time_to_segment(const gm_stream *s, double t);

/// Produce the fMP4 init segment (ftyp+moov) into `out` (reset+filled).
/// Returns 0 on success, negative on error.
int gm_stream_init_segment(gm_stream *s, gm_buf *out, char *err, int errlen);

/// Produce media segment `i` (moof+mdat, absolute timestamps) into `out`.
/// Returns 0 on success, negative on error.
int gm_stream_make_segment(gm_stream *s, int i, gm_buf *out, char *err, int errlen);

/// Produce segment `i` ONCE as a full unit (ftyp+moov+moof+mdat...) into `out`, and
/// report the byte offset that splits init (ftyp+moov, [0,*moov_end)) from media
/// (moof+mdat..., [*moov_end, out->len)). Lets the caller obtain both the init
/// segment and the media segment from a SINGLE demux+mux pass (avoids muxing seg0
/// twice at startup: once for init, once for the first media segment). Returns 0 on
/// success, negative on error.
int gm_stream_make_unit(gm_stream *s, int i, gm_buf *out, int *moov_end, char *err, int errlen);

/// Close and free the stream.
void gm_stream_close(gm_stream *s);

#ifdef __cplusplus
}
#endif

#endif /* GM_STREAM_H */
