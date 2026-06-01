//
//  gmremux.h
//  CFFmpeg, the C remux engine that wraps FFmpeg 8.1.1 (libav*).
//
//  This is the ONLY header Swift sees (module CFFmpeg). It exposes a small,
//  Swift-friendly C API for probing a media source and remuxing (stream-copy,
//  no transcode) AVFoundation-compatible streams into a fragmented MP4 that
//  AVPlayer can play. The raw libav* API stays private to the C target.
//
#ifndef GMREMUX_H
#define GMREMUX_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Kind of an elementary stream.
typedef enum {
    GM_STREAM_UNKNOWN  = 0,
    GM_STREAM_VIDEO    = 1,
    GM_STREAM_AUDIO    = 2,
    GM_STREAM_SUBTITLE = 3,
} GMStreamKind;

/// Description of one source stream, filled by gm_probe().
typedef struct {
    int          index;          ///< source stream index
    GMStreamKind kind;
    char         codec_name[32]; ///< e.g. "hevc", "h264", "ac3", "truehd", "aac"
    char         profile[48];    ///< e.g. "Main 10", "Dolby TrueHD + Dolby Atmos"
    char         language[8];    ///< ISO 639 language code, or "" if unknown
    char         title[128];     ///< track title metadata, or ""
    int          width;          ///< video only (0 otherwise)
    int          height;         ///< video only (0 otherwise)
    int          channels;       ///< audio only (0 otherwise)
    int          is_default;     ///< 1 if the stream has the DEFAULT disposition
    bool         avf_compatible; ///< true if AVFoundation can play it inside MP4
    bool         is_dolby_vision;///< true if a Dolby Vision configuration is present
    int          dovi_profile;   ///< Dolby Vision profile (e.g. 5, 7, 8), or 0
} GMStreamDesc;

#define GM_MAX_STREAMS 32

/// Result of probing an input. duration_seconds may be 0 if unknown.
typedef struct {
    int          stream_count;
    GMStreamDesc streams[GM_MAX_STREAMS];
    double       duration_seconds;
    char         format_name[64];
} GMProbeResult;

/// Progress callback. `fraction` is 0..1. Return non-zero to request cancel.
typedef int (*gm_progress_cb)(double fraction, void *ctx);

/// Initialize the engine (logging, network). Safe to call multiple times.
void gm_init(void);

/// FFmpeg version string, e.g. "8.1.1".
const char *gm_ffmpeg_version(void);

/// Probe a local file path or an http(s):// URL.
/// Returns 0 on success; negative on error (errbuf gets a message).
int gm_probe(const char *input_url,
             GMProbeResult *out,
             char *errbuf, int errbuf_len);

/// Remux `input_url` -> fragmented MP4 at `output_path`, copying streams.
///
/// `video_stream` / `audio_stream` are SOURCE stream indices, or -1 to let the
/// engine auto-select the best AVFoundation-compatible video/audio stream.
/// Pass -2 to omit that media type entirely.
///
/// Streams are stream-copied (no re-encode). HEVC is tagged `hvc1` and H.264
/// `avc1` so AVFoundation accepts them. Output uses
/// movflags=frag_keyframe+empty_moov+default_base_moof+delay_moov so playback
/// can start before the whole file is written and AC-3 muxes correctly.
///
/// Returns 0 on success; negative AVERROR-style code on failure.
int gm_remux_to_fmp4(const char *input_url,
                     const char *output_path,
                     int video_stream,
                     int audio_stream,
                     gm_progress_cb progress,
                     void *progress_ctx,
                     char *errbuf, int errbuf_len);

#ifdef __cplusplus
}
#endif

#endif /* GMREMUX_H */
