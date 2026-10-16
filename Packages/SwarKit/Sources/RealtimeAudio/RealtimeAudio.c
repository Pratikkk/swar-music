#include "RealtimeAudio.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct SwarRing {
    uint8_t *bytes;
    uint32_t capacity, stride;
    _Atomic(uint64_t) read, written, underruns, finished;
};
SwarRing *swar_ring_create(uint32_t capacity, uint32_t stride) {
    if (!capacity || !stride || (size_t)capacity > SIZE_MAX / stride) return NULL;
    SwarRing *ring = calloc(1, sizeof(*ring));
    if (!ring) return NULL;
    atomic_init(&ring->read, 0); atomic_init(&ring->written, 0); atomic_init(&ring->underruns, 0);
    atomic_init(&ring->finished, 0);
    if (!atomic_is_lock_free(&ring->read) || !atomic_is_lock_free(&ring->written) ||
        !atomic_is_lock_free(&ring->underruns) || !atomic_is_lock_free(&ring->finished)) { free(ring); return NULL; }
    ring->bytes = calloc(capacity, stride);
    if (!ring->bytes) { free(ring); return NULL; }
    ring->capacity = capacity; ring->stride = stride;
    return ring;
}
void swar_ring_destroy(SwarRing *ring) { if (ring) { free(ring->bytes); free(ring); } }
void swar_ring_reset(SwarRing *ring) {
    atomic_store_explicit(&ring->read, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->written, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->underruns, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->finished, 0, memory_order_relaxed);
}
void swar_ring_finish(SwarRing *ring) { atomic_store_explicit(&ring->finished, 1, memory_order_release); }
uint32_t swar_ring_readable(const SwarRing *ring) {
    uint64_t r = atomic_load_explicit(&ring->read, memory_order_acquire);
    uint64_t w = atomic_load_explicit(&ring->written, memory_order_acquire);
    return (uint32_t)(w - r);
}
uint32_t swar_ring_writable(const SwarRing *ring) { return ring->capacity - swar_ring_readable(ring); }
uint64_t swar_ring_consumed(const SwarRing *ring) { return atomic_load_explicit(&ring->read, memory_order_acquire); }
uint64_t swar_ring_underruns(const SwarRing *ring) { return atomic_load_explicit(&ring->underruns, memory_order_relaxed); }
uint32_t swar_ring_write(SwarRing *ring, const void *source, uint32_t frames) {
    uint64_t w = atomic_load_explicit(&ring->written, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&ring->read, memory_order_acquire);
    uint32_t count = frames < ring->capacity - (w - r) ? frames : (uint32_t)(ring->capacity - (w - r));
    uint32_t offset = (uint32_t)(w % ring->capacity);
    uint32_t first = count < ring->capacity - offset ? count : ring->capacity - offset;
    memcpy(ring->bytes + (size_t)offset * ring->stride, source, (size_t)first * ring->stride);
    memcpy(ring->bytes, (const uint8_t *)source + (size_t)first * ring->stride, (size_t)(count - first) * ring->stride);
    atomic_store_explicit(&ring->written, w + count, memory_order_release);
    return count;
}
uint32_t swar_ring_read(SwarRing *ring, void *destination, uint32_t frames) {
    uint64_t r = atomic_load_explicit(&ring->read, memory_order_relaxed);
    // Observing EOF before written ensures all final PCM writes are visible.
    uint64_t finished = atomic_load_explicit(&ring->finished, memory_order_acquire);
    uint64_t w = atomic_load_explicit(&ring->written, memory_order_acquire);
    uint32_t count = frames < w - r ? frames : (uint32_t)(w - r);
    uint32_t offset = (uint32_t)(r % ring->capacity);
    uint32_t first = count < ring->capacity - offset ? count : ring->capacity - offset;
    memcpy(destination, ring->bytes + (size_t)offset * ring->stride, (size_t)first * ring->stride);
    memcpy((uint8_t *)destination + (size_t)first * ring->stride, ring->bytes, (size_t)(count - first) * ring->stride);
    if (count < frames) {
        memset((uint8_t *)destination + (size_t)count * ring->stride, 0, (size_t)(frames - count) * ring->stride);
        if (!finished)
            atomic_fetch_add_explicit(&ring->underruns, frames - count, memory_order_relaxed);
    }
    atomic_store_explicit(&ring->read, r + count, memory_order_release);
    return count;
}
static OSStatus render(void *context, AudioUnitRenderActionFlags *flags,
                       const AudioTimeStamp *time, UInt32 bus, UInt32 frames, AudioBufferList *data) {
    (void)flags; (void)time; (void)bus;
    SwarRing *ring = context;
    if (!data) return kAudio_ParamError;
    if (data->mNumberBuffers != 1 || !data->mBuffers[0].mData ||
        data->mBuffers[0].mDataByteSize < (size_t)frames * ring->stride) {
        for (UInt32 i = 0; i < data->mNumberBuffers; ++i)
            if (data->mBuffers[i].mData) memset(data->mBuffers[i].mData, 0, data->mBuffers[i].mDataByteSize);
        return kAudio_ParamError;
    }
    swar_ring_read(ring, data->mBuffers[0].mData, frames);
    data->mBuffers[0].mDataByteSize = frames * ring->stride;
    return noErr;
}
OSStatus swar_install_render_callback(AudioUnit unit, SwarRing *ring) {
    AURenderCallbackStruct callback = { .inputProc = render, .inputProcRefCon = ring };
    return AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
}
