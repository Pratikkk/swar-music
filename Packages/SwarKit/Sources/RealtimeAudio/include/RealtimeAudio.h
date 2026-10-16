#ifndef SWAR_REALTIME_AUDIO_H
#define SWAR_REALTIME_AUDIO_H
#include <AudioUnit/AudioUnit.h>
#include <stdint.h>
typedef struct SwarRing SwarRing;
// Single producer/single consumer. Reset/destroy only after stopping the audio unit.
SwarRing *swar_ring_create(uint32_t capacity_frames, uint32_t bytes_per_frame);
void swar_ring_destroy(SwarRing *ring);
void swar_ring_reset(SwarRing *ring);
void swar_ring_finish(SwarRing *ring);
uint32_t swar_ring_readable(const SwarRing *ring);
uint32_t swar_ring_writable(const SwarRing *ring);
uint64_t swar_ring_consumed(const SwarRing *ring);
uint64_t swar_ring_underruns(const SwarRing *ring);
uint32_t swar_ring_write(SwarRing *ring, const void *source, uint32_t frames);
// Zero-fills missing frames and counts underrun frames.
uint32_t swar_ring_read(SwarRing *ring, void *destination, uint32_t frames);
OSStatus swar_install_render_callback(AudioUnit unit, SwarRing *ring);
#endif
