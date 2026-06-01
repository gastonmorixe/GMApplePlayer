//
//  probe.c
//  Engine lifecycle (gm_init / version) and source probing: open the input,
//  read stream info, and fill a GMProbeResult with per-stream metadata,
//  AVFoundation-compat flags, and Dolby Vision detection.
//
#include "gm_internal.h"

void gm_init(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    av_log_set_level(AV_LOG_ERROR);
#if CONFIG_NETWORK
    avformat_network_init();
#endif
}

const char *gm_ffmpeg_version(void) {
    return av_version_info();
}

// Inspect coded side data for a Dolby Vision configuration record.
static void fill_dovi(AVStream *st, GMStreamDesc *d) {
    d->is_dolby_vision = false;
    d->dovi_profile = 0;
    // AV_PKT_DATA_DOVI_CONF is an ENUM constant, not a #define, so a `#if defined(...)`
    // guard here is always false and silently disables detection. Reference it directly.
    // dv_profile is the 3rd byte of the DOVI configuration record (a plain uint8_t).
    for (int i = 0; i < st->codecpar->nb_coded_side_data; i++) {
        const AVPacketSideData *sd = &st->codecpar->coded_side_data[i];
        if (sd->type == AV_PKT_DATA_DOVI_CONF && sd->data && sd->size >= 3) {
            d->is_dolby_vision = true;
            d->dovi_profile = sd->data[2];
            return;
        }
    }
}

int gm_probe(const char *input_url, GMProbeResult *out, char *errbuf, int errbuf_len) {
    if (!input_url || !out) return -1;
    memset(out, 0, sizeof(*out));
    gm_init();

    AVFormatContext *fmt = NULL;
    int ret = avformat_open_input(&fmt, input_url, NULL, NULL);
    if (ret < 0) { gm_set_err(errbuf, errbuf_len, "avformat_open_input failed", ret); return ret; }

    ret = avformat_find_stream_info(fmt, NULL);
    if (ret < 0) {
        gm_set_err(errbuf, errbuf_len, "avformat_find_stream_info failed", ret);
        avformat_close_input(&fmt);
        return ret;
    }

    if (fmt->iformat && fmt->iformat->name)
        snprintf(out->format_name, sizeof(out->format_name), "%s", fmt->iformat->name);
    if (fmt->duration > 0)
        out->duration_seconds = (double)fmt->duration / AV_TIME_BASE;

    int n = (int)fmt->nb_streams;
    if (n > GM_MAX_STREAMS) n = GM_MAX_STREAMS;
    out->stream_count = n;

    for (int i = 0; i < n; i++) {
        AVStream *st = fmt->streams[i];
        AVCodecParameters *par = st->codecpar;
        GMStreamDesc *d = &out->streams[i];
        d->index = i;
        d->kind = gm_kind_for(par->codec_type);

        const char *cn = avcodec_get_name(par->codec_id);
        if (cn) snprintf(d->codec_name, sizeof(d->codec_name), "%s", cn);

        const char *prof = avcodec_profile_name(par->codec_id, par->profile);
        if (prof) snprintf(d->profile, sizeof(d->profile), "%s", prof);

        AVDictionaryEntry *lang = av_dict_get(st->metadata, "language", NULL, 0);
        if (lang && lang->value) snprintf(d->language, sizeof(d->language), "%s", lang->value);
        AVDictionaryEntry *title = av_dict_get(st->metadata, "title", NULL, 0);
        if (title && title->value) snprintf(d->title, sizeof(d->title), "%s", title->value);

        d->width = par->width;
        d->height = par->height;
        d->channels = par->ch_layout.nb_channels;
        d->is_default = (st->disposition & AV_DISPOSITION_DEFAULT) ? 1 : 0;
        d->avf_compatible = gm_codec_is_avf_compatible(par->codec_id);

        if (par->codec_type == AVMEDIA_TYPE_VIDEO) fill_dovi(st, d);
    }

    avformat_close_input(&fmt);
    return 0;
}
