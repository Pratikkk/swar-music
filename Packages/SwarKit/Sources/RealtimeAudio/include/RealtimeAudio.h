#ifndef SWAR_REALTIME_AUDIO_H
#define SWAR_REALTIME_AUDIO_H
#include <AudioUnit/AudioUnit.h>
#include <stdint.h>
typedef struct SwarRing SwarRing;
// Single producer/single consumer. Reset/destroy only after stopping the audio unit.
SwarRing *swar_ring_create(uint32_t capacity_frames, uint32_t bytes_per_frame);
void swar_ring_destroy(SwarRing *ring);
// Uninstall render callback before destroying the ring to prevent use-after-free.
OSStatus swar_uninstall_render_callback(AudioUnit unit);
void swar_ring_reset(SwarRing *ring);
// Publish EOF after the final write. Do not write again until a stopped reset.
void swar_ring_finish(SwarRing *ring);
uint32_t swar_ring_readable(const SwarRing *ring);
uint32_t swar_ring_writable(const SwarRing *ring);
uint64_t swar_ring_consumed(const SwarRing *ring);
uint64_t swar_ring_underruns(const SwarRing *ring);
uint32_t swar_ring_write(SwarRing *ring, const void *source, uint32_t frames);
// Zero-fill missing frames; count starvation only while EOF is unpublished.
// A short read rechecks EOF and drains any final PCM published with it.
uint32_t swar_ring_read(SwarRing *ring, void *destination, uint32_t frames);
OSStatus swar_install_render_callback(AudioUnit unit, SwarRing *ring);

// Performance metrics (audiophile diagnostics)
uint64_t swar_ring_total_written(const SwarRing *ring);
uint64_t swar_ring_total_read(const SwarRing *ring);
uint32_t swar_ring_max_fill(const SwarRing *ring);
uint32_t swar_ring_min_fill(const SwarRing *ring);
uint64_t swar_ring_write_cycles(const SwarRing *ring);
uint64_t swar_ring_read_cycles(const SwarRing *ring);
#endif
