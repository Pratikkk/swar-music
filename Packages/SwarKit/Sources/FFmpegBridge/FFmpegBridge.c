#include "FFmpegBridge.h"
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/samplefmt.h>
#include <libavutil/mathematics.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Resolve only from the bundled library and its bundled dependencies. No Homebrew
// paths, subprocesses, network protocols, or float conversion for integer sources.
// FFmpeg's Opus decoder uses libswresample internally; Swar never resamples PCM here.
#define API_FUNCTIONS(X) \
 X(avformat_open_input) X(avformat_find_stream_info) X(av_find_best_stream) \
 X(avcodec_find_decoder) X(avcodec_alloc_context3) X(avcodec_parameters_to_context) \
 X(avcodec_open2) X(avcodec_free_context) X(avcodec_flush_buffers) \
 X(av_frame_alloc) X(av_frame_free) X(av_frame_unref) \
 X(av_packet_alloc) X(av_packet_free) X(av_packet_unref) \
 X(av_read_frame) X(avcodec_send_packet) X(avcodec_receive_frame) \
 X(avformat_close_input) X(avformat_seek_file) X(av_seek_frame) X(av_get_bytes_per_sample) \
 X(av_sample_fmt_is_planar) X(av_get_packed_sample_fmt) X(av_rescale_q) \
 X(av_strerror) X(av_get_bits_per_sample) X(avformat_version) X(avcodec_version) X(avutil_version) X(av_dict_get)
struct SwarFFDecoder {
    void *library;
    struct {
#define DECLARE(name) __typeof__(&name) name;
        API_FUNCTIONS(DECLARE)
#undef DECLARE
    } api;
    AVFormatContext *format;
    AVCodecContext *codec;
    AVPacket *packet;
    AVFrame *frame;
    int stream, offset, drained;
    int64_t seek_target, delivered;
    enum AVSampleFormat sample_format;
    SwarFFInfo info;
    const char *label;
};
#define A(name) d->api.name

static int fail(SwarFFDecoder *d, char *error, size_t size, const char *action, int code) {
    char detail[128] = {0};
    if (d && A(av_strerror)) A(av_strerror)(code, detail, sizeof(detail));
    snprintf(error, size, "%s%s%s (%d)", action, detail[0] ? ": " : "", detail, code);
    return -1;
}

void swar_ff_close(SwarFFDecoder *d) {
    if (!d) return;
    if (d->frame) A(av_frame_free)(&d->frame);
    if (d->packet) A(av_packet_free)(&d->packet);
    if (d->codec) A(avcodec_free_context)(&d->codec);
    if (d->format) A(avformat_close_input)(&d->format);
    if (d->library) dlclose(d->library);
    free(d);
}

static int next_frame(SwarFFDecoder *d, char *error, size_t size) {
    A(av_frame_unref)(d->frame);
    d->offset = 0;
    for (;;) {
        int result = A(avcodec_receive_frame)(d->codec, d->frame);
        if (result == 0) return 1;
        if (result == AVERROR_EOF) return 0;
        if (result != AVERROR(EAGAIN)) return fail(d, error, size, "Decode audio frame", result);
        if (d->drained) return fail(d, error, size, "Decoder did not finish draining", result);
        do {
            A(av_packet_unref)(d->packet);
            result = A(av_read_frame)(d->format, d->packet);
        } while (result >= 0 && d->packet->stream_index != d->stream);
        if (result == AVERROR_EOF) {
            d->drained = 1;
            result = A(avcodec_send_packet)(d->codec, NULL);
        } else if (result < 0) return fail(d, error, size, "Read audio packet", result);
        else {
            if (d->packet->flags & AV_PKT_FLAG_CORRUPT)
                return fail(d, error, size, "Damaged audio packet", AVERROR_INVALIDDATA);
            if (d->codec->codec_id == AV_CODEC_ID_WAVPACK && d->packet->size >= 32 &&
                !memcmp(d->packet->data, "wvpk", 4) && (d->packet->data[24] & 8))
                d->info.is_lossless = 0; // Hybrid WavPack is lossy without a correction stream.
            result = A(avcodec_send_packet)(d->codec, d->packet);
        }
        A(av_packet_unref)(d->packet);
        if (result < 0) return fail(d, error, size, "Submit audio packet", result);
    }
}

SwarFFDecoder *swar_ff_open(const char *path, const char *library, char *error, size_t size) {
    SwarFFDecoder *d = calloc(1, sizeof(*d));
    if (!d) { fail(NULL, error, size, "Allocate decoder", AVERROR(ENOMEM)); return NULL; }
    d->seek_target = -1;
    d->library = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (!d->library) {
        snprintf(error, size, "Bundled codecs could not load: %s", dlerror());
        swar_ff_close(d); return NULL;
    }
#define LOAD(name) { void *symbol = dlsym(d->library, #name); \
    if (!symbol) { snprintf(error, size, "Bundled codec API missing: %s", #name); swar_ff_close(d); return NULL; } \
    memcpy(&d->api.name, &symbol, sizeof(symbol)); }
    API_FUNCTIONS(LOAD)
#undef LOAD
    if ((A(avformat_version)() >> 16) != LIBAVFORMAT_VERSION_MAJOR ||
        (A(avcodec_version)() >> 16) != LIBAVCODEC_VERSION_MAJOR ||
        (A(avutil_version)() >> 16) != LIBAVUTIL_VERSION_MAJOR) {
        snprintf(error, size, "The codec library ABI does not match this app");
        goto failure;
    }
    int result = A(avformat_open_input)(&d->format, path, NULL, NULL);
    if (result < 0) { fail(d, error, size, "Open audio content", result); goto failure; }
    result = A(avformat_find_stream_info)(d->format, NULL);
    if (result < 0) { fail(d, error, size, "Inspect audio content", result); goto failure; }
    result = A(av_find_best_stream)(d->format, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (result < 0) { fail(d, error, size, "Find audio stream", result); goto failure; }
    d->stream = result;
    AVStream *stream = d->format->streams[d->stream];
    const AVCodec *codec = A(avcodec_find_decoder)(stream->codecpar->codec_id);
    if (!codec) { snprintf(error, size, "No bundled decoder for this codec"); goto failure; }
    // Deliberate allowlist: never infer the codec from a filename or demuxer name.
    switch (codec->id) {
        case AV_CODEC_ID_FLAC: d->label = "FLAC"; d->info.is_lossless = 1; break;
        case AV_CODEC_ID_ALAC: d->label = "ALAC"; d->info.is_lossless = 1; break;
        case AV_CODEC_ID_WAVPACK: d->label = "WavPack"; d->info.is_lossless = 1; break;
        case AV_CODEC_ID_APE: d->label = "Monkey's Audio"; d->info.is_lossless = 1; break;
        case AV_CODEC_ID_WMALOSSLESS: d->label = "WMA Lossless"; d->info.is_lossless = 1; break;
        case AV_CODEC_ID_WMAV1: case AV_CODEC_ID_WMAV2: case AV_CODEC_ID_WMAPRO: d->label = "WMA"; break;
        case AV_CODEC_ID_VORBIS: d->label = "Vorbis"; break;
        case AV_CODEC_ID_OPUS: d->label = "Opus"; break;
        case AV_CODEC_ID_AAC: d->label = "AAC"; break;
        case AV_CODEC_ID_MP3: d->label = "MP3"; break;
        case AV_CODEC_ID_PCM_S16LE: case AV_CODEC_ID_PCM_S16BE:
        case AV_CODEC_ID_PCM_S24LE: case AV_CODEC_ID_PCM_S24BE:
        case AV_CODEC_ID_PCM_S32LE: case AV_CODEC_ID_PCM_S32BE:
        case AV_CODEC_ID_PCM_F32LE: case AV_CODEC_ID_PCM_F32BE: case AV_CODEC_ID_PCM_U8:
            d->label = "PCM"; d->info.is_lossless = 1; break;
        default: snprintf(error, size, "This codec is outside the bundled format set"); goto failure;
    }
    d->codec = A(avcodec_alloc_context3)(codec);
    if (!d->codec) { fail(d, error, size, "Allocate codec", AVERROR(ENOMEM)); goto failure; }
    result = A(avcodec_parameters_to_context)(d->codec, stream->codecpar);
    if (result < 0) { fail(d, error, size, "Read codec parameters", result); goto failure; }
    // Decode errors must be surfaced instead of silently concealing damaged audio.
    d->codec->err_recognition = AV_EF_CRCCHECK | AV_EF_EXPLODE;
    d->codec->thread_count = 1;
    result = A(avcodec_open2)(d->codec, codec, NULL);
    if (result < 0) { fail(d, error, size, "Open codec", result); goto failure; }
    d->packet = A(av_packet_alloc)(); d->frame = A(av_frame_alloc)();
    if (!d->packet || !d->frame) { fail(d, error, size, "Allocate audio frame", AVERROR(ENOMEM)); goto failure; }
    if (next_frame(d, error, size) != 1) {
        if (!error[0]) snprintf(error, size, "The audio stream is empty");
        goto failure;
    }
    d->sample_format = d->frame->format;
    enum AVSampleFormat packed = A(av_get_packed_sample_fmt)(d->sample_format);
    int storage_bits = 8 * A(av_get_bytes_per_sample)(packed);
    if (packed != AV_SAMPLE_FMT_S16 && packed != AV_SAMPLE_FMT_S32 && packed != AV_SAMPLE_FMT_FLT && packed != AV_SAMPLE_FMT_U8) {
        snprintf(error, size, "Unsupported decoded PCM representation"); goto failure;
    }
    d->info.is_float = packed == AV_SAMPLE_FMT_FLT;
    d->info.sample_rate = d->frame->sample_rate;
    d->info.channels = d->frame->ch_layout.nb_channels;
    d->info.source_bits = stream->codecpar->bits_per_raw_sample;
    if (!d->info.source_bits) d->info.source_bits = d->codec->bits_per_raw_sample;
    if (!d->info.source_bits && codec->id == AV_CODEC_ID_WMALOSSLESS && d->codec->extradata_size >= 2)
        d->info.source_bits = d->codec->extradata[0] | (d->codec->extradata[1] << 8);
    if (!d->info.source_bits && d->info.is_lossless) d->info.source_bits = A(av_get_bits_per_sample)(codec->id);
    if (d->info.is_lossless && (!d->info.source_bits || d->info.source_bits > 32)) {
        snprintf(error, size, "Lossless source bit depth could not be verified"); goto failure;
    }
    d->info.pcm_bits = d->info.is_lossless && !d->info.is_float ? d->info.source_bits : storage_bits;
    if (d->info.pcm_bits > storage_bits || d->info.pcm_bits < 1 ||
        d->info.channels < 1 || d->info.channels > 8 ||
        d->info.sample_rate < 1 || d->info.sample_rate > 384000) {
        snprintf(error, size, "Unsupported source format (up to 32-bit, 384 kHz, 8 channels)"); goto failure;
    }
    AVRational samples = {1, (int)d->info.sample_rate};
    if (stream->duration != AV_NOPTS_VALUE)
        d->info.frame_count = A(av_rescale_q)(stream->duration, stream->time_base, samples);
    else if (d->format->duration != AV_NOPTS_VALUE)
        d->info.frame_count = A(av_rescale_q)(d->format->duration, AV_TIME_BASE_Q, samples);
    if (codec->id == AV_CODEC_ID_OPUS) d->info.frame_count -= stream->codecpar->initial_padding;
    if (d->info.frame_count <= 0) { snprintf(error, size, "Audio duration is unavailable"); goto failure; }
    // Container bitrate includes tags and page headers; do not present it as codec bitrate.
    int64_t bitrate = stream->codecpar->bit_rate > 0 ? stream->codecpar->bit_rate : d->codec->bit_rate;
    d->info.bit_rate = bitrate > 0 && bitrate <= UINT32_MAX ? (uint32_t)bitrate : 0;
    return d;
failure:
    swar_ff_close(d); return NULL;
}

SwarFFInfo swar_ff_info(const SwarFFDecoder *d) { return d->info; }
const char *swar_ff_codec(const SwarFFDecoder *d) { return d->label; }

const char *swar_ff_tag(const SwarFFDecoder *d, const char *key) {
    const AVDictionaryEntry *entry = d->api.av_dict_get(d->format->streams[d->stream]->metadata, key, NULL, 0);
    if (!entry) entry = d->api.av_dict_get(d->format->metadata, key, NULL, 0);
    return entry ? entry->value : NULL;
}

const uint8_t *swar_ff_artwork(const SwarFFDecoder *d, size_t *size) {
    *size = 0;
    for (unsigned i = 0; i < d->format->nb_streams; ++i) {
        const AVStream *stream = d->format->streams[i];
        if ((stream->disposition & AV_DISPOSITION_ATTACHED_PIC) &&
            stream->attached_pic.size > 0 && stream->attached_pic.size <= 20 * 1024 * 1024) {
            *size = (size_t)stream->attached_pic.size;
            return stream->attached_pic.data;
        }
    }
    return NULL;
}

int swar_ff_read(SwarFFDecoder *d, void *output, uint32_t requested, uint32_t *read, char *error, size_t size) {
    *read = 0;
    int stride = (d->info.pcm_bits + 7) / 8;
    int channels = d->info.channels;
    int storage = A(av_get_bytes_per_sample)(d->sample_format);
    int planar = A(av_sample_fmt_is_planar)(d->sample_format);
    uint8_t *dest = output;
    while (*read < requested) {
        if (d->offset >= d->frame->nb_samples) {
            int result = next_frame(d, error, size);
            if (result <= 0) {
                if (result == 0 && d->info.is_lossless && d->delivered < d->info.frame_count) {
                    snprintf(error, size, "The lossless stream ended before its declared duration"); return -1;
                }
                return result < 0 ? -1 : 0;
            }
        }
        if (d->frame->format != d->sample_format || d->frame->sample_rate != d->info.sample_rate ||
            d->frame->ch_layout.nb_channels != channels) {
            snprintf(error, size, "Audio format changed inside the stream"); return -1;
        }
        if (d->seek_target >= 0) {
            AVStream *stream = d->format->streams[d->stream];
            int64_t pts = d->frame->best_effort_timestamp;
            int64_t start = stream->start_time == AV_NOPTS_VALUE ? 0 : stream->start_time;
            if (pts == AV_NOPTS_VALUE) { snprintf(error, size, "Exact seek timestamp is unavailable"); return -1; }
            int64_t frame_start = A(av_rescale_q)(pts - start, stream->time_base, (AVRational){1, (int)d->info.sample_rate});
            if (frame_start > d->seek_target) { snprintf(error, size, "The decoder overshot the seek target"); return -1; }
            int64_t skip = d->seek_target - frame_start;
            if (skip >= d->frame->nb_samples) { d->offset = d->frame->nb_samples; continue; }
            d->offset = (int)skip;
            d->seek_target = -1;
        }
        int count = d->frame->nb_samples - d->offset;
        if ((uint32_t)count > requested - *read) count = (int)(requested - *read);
        for (int frame = 0; frame < count; ++frame) {
            for (int channel = 0; channel < channels; ++channel) {
                const uint8_t *src = planar ? d->frame->extended_data[channel] + (size_t)(d->offset + frame) * storage :
                    d->frame->extended_data[0] + ((size_t)(d->offset + frame) * channels + channel) * storage;
                uint32_t value = 0;
                memcpy(&value, src, storage);
                if (!d->info.is_float && d->info.pcm_bits < storage * 8) value >>= storage * 8 - d->info.pcm_bits;
                if (A(av_get_packed_sample_fmt)(d->sample_format) == AV_SAMPLE_FMT_U8) value ^= 0x80;
                memcpy(dest, &value, stride);
                dest += stride;
            }
        }
        d->offset += count;
        *read += count;
        d->delivered += count;
    }
    return 0;
}

int swar_ff_seek(SwarFFDecoder *d, int64_t frame, char *error, size_t size) {
    AVStream *stream = d->format->streams[d->stream];
    int64_t start = stream->start_time == AV_NOPTS_VALUE ? 0 : stream->start_time;
    int64_t timestamp = A(av_rescale_q)(frame, (AVRational){1, (int)d->info.sample_rate}, stream->time_base) + start;
    int result = A(av_seek_frame)(d->format, d->stream, timestamp, AVSEEK_FLAG_BACKWARD);
    // Streams without a usable seek index can still seek exactly by decoding forward.
    if (result < 0) result = A(av_seek_frame)(d->format, d->stream, start, AVSEEK_FLAG_BACKWARD);
    if (result < 0) return fail(d, error, size, "Seek audio", result);
    A(avcodec_flush_buffers)(d->codec);
    A(av_packet_unref)(d->packet);
    A(av_frame_unref)(d->frame);
    d->offset = 0; d->drained = 0; d->seek_target = frame; d->delivered = frame;
    return 0;
}
