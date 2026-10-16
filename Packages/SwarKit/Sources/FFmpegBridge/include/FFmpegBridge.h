#ifndef SWAR_FFMPEG_BRIDGE_H
#define SWAR_FFMPEG_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
typedef struct SwarFFDecoder SwarFFDecoder;
typedef struct {
    double sample_rate;
    int64_t frame_count;
    int channels;
    int source_bits;
    int pcm_bits;
    int is_float;
    int is_lossless;
    uint32_t bit_rate;
} SwarFFInfo;
SwarFFDecoder *swar_ff_open(const char *path, const char *library, char *error, size_t error_size);
void swar_ff_close(SwarFFDecoder *decoder);
SwarFFInfo swar_ff_info(const SwarFFDecoder *decoder);
const char *swar_ff_codec(const SwarFFDecoder *decoder);
const char *swar_ff_tag(const SwarFFDecoder *decoder, const char *key);
const uint8_t *swar_ff_artwork(const SwarFFDecoder *decoder, size_t *size);
int swar_ff_read(SwarFFDecoder *decoder, void *output, uint32_t requested, uint32_t *read, char *error, size_t error_size);
int swar_ff_seek(SwarFFDecoder *decoder, int64_t frame, char *error, size_t error_size);
#endif
