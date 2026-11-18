#include "RealtimeAudio.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <simd/simd.h>

/// Ring buffer alignment for SIMD-optimized copies (16-byte aligned)
#define SWAR_RING_ALIGNMENT 16

struct SwarRing {
    uint8_t *bytes;
    uint32_t capacity, stride;
    _Atomic(uint64_t) read, written, underruns, finished;
    // Performance metrics
    _Atomic(uint64_t) total_frames_written;
    _Atomic(uint64_t) total_frames_read;
    _Atomic(uint32_t) max_fill_frames;
    _Atomic(uint32_t) min_fill_frames;
    _Atomic(uint64_t) write_cycles;
    _Atomic(uint64_t) read_cycles;
    // Synchronization for safe destruction
    _Atomic(int32_t) active_readers;
    _Atomic(int32_t) destroyed;
};

SwarRing *swar_ring_create(uint32_t capacity, uint32_t stride) {
    if (!capacity || !stride || (size_t)capacity > SIZE_MAX / stride) return NULL;
    SwarRing *ring = calloc(1, sizeof(*ring));
    if (!ring) return NULL;
    atomic_init(&ring->read, 0); atomic_init(&ring->written, 0); atomic_init(&ring->underruns, 0);
    atomic_init(&ring->finished, 0);
    atomic_init(&ring->total_frames_written, 0); atomic_init(&ring->total_frames_read, 0);
    atomic_init(&ring->max_fill_frames, 0); atomic_init(&ring->min_fill_frames, UINT32_MAX);
    atomic_init(&ring->write_cycles, 0); atomic_init(&ring->read_cycles, 0);
    // Use atomic_store_explicit for proper memory ordering on new atomics
    atomic_store_explicit(&ring->active_readers, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->destroyed, 0, memory_order_relaxed);
    if (!atomic_is_lock_free(&ring->read) || !atomic_is_lock_free(&ring->written) ||
        !atomic_is_lock_free(&ring->underruns) || !atomic_is_lock_free(&ring->finished) ||
        !atomic_is_lock_free(&ring->active_readers) || !atomic_is_lock_free(&ring->destroyed)) { free(ring); return NULL; }
    // Aligned allocation for SIMD copies - use posix_memalign for macOS compatibility
    size_t alloc_size = ((size_t)capacity * stride + SWAR_RING_ALIGNMENT - 1) & ~(SWAR_RING_ALIGNMENT - 1);
    int err = posix_memalign((void **)&ring->bytes, SWAR_RING_ALIGNMENT, alloc_size);
    if (err != 0 || !ring->bytes) { free(ring); return NULL; }
    ring->capacity = capacity; ring->stride = stride;
    return ring;
}

void swar_ring_destroy(SwarRing *ring) {
    if (!ring) return;
    // Mark as destroyed to prevent new render callbacks from accessing it
    atomic_store_explicit(&ring->destroyed, 1, memory_order_release);
    // Brief wait for any in-flight render callbacks (they check destroyed flag at entry)
    // Use seq_cst for strongest ordering; 100 iterations * 100us = 10ms max
    for (int i = 0; i < 100; i++) {
        int32_t active = atomic_load_explicit(&ring->active_readers, memory_order_seq_cst);
        if (active == 0) break;
        usleep(100);
    }
    free(ring->bytes);
    free(ring);
}

void swar_ring_reset(SwarRing *ring) {
    atomic_store_explicit(&ring->read, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->written, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->underruns, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->finished, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->total_frames_written, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->total_frames_read, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->max_fill_frames, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->min_fill_frames, UINT32_MAX, memory_order_relaxed);
    atomic_store_explicit(&ring->write_cycles, 0, memory_order_relaxed);
    atomic_store_explicit(&ring->read_cycles, 0, memory_order_relaxed);
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

// Performance metrics
uint64_t swar_ring_total_written(const SwarRing *ring) { return atomic_load_explicit(&ring->total_frames_written, memory_order_relaxed); }
uint64_t swar_ring_total_read(const SwarRing *ring) { return atomic_load_explicit(&ring->total_frames_read, memory_order_relaxed); }
uint32_t swar_ring_max_fill(const SwarRing *ring) { return atomic_load_explicit(&ring->max_fill_frames, memory_order_relaxed); }
uint32_t swar_ring_min_fill(const SwarRing *ring) { return atomic_load_explicit(&ring->min_fill_frames, memory_order_relaxed); }
uint64_t swar_ring_write_cycles(const SwarRing *ring) { return atomic_load_explicit(&ring->write_cycles, memory_order_relaxed); }
uint64_t swar_ring_read_cycles(const SwarRing *ring) { return atomic_load_explicit(&ring->read_cycles, memory_order_relaxed); }

/// SIMD-optimized memory copy for Float32 frames (4 channels max)
static inline void simd_copy_frames_float32(uint8_t *dst, const uint8_t *src, uint32_t frames, uint32_t stride, uint32_t channels) {
    const uint32_t frame_bytes = channels * 4;
    const uint32_t simd_width = 16; // 16 bytes = 4 floats
    const uint32_t frames_per_iter = simd_width / frame_bytes;
    if (frames_per_iter == 0) { memcpy(dst, src, (size_t)frames * stride); return; }
    
    uint32_t i = 0;
    for (; i + frames_per_iter <= frames; i += frames_per_iter) {
        simd_float4 *d = (simd_float4 *)(dst + (size_t)i * stride);
        const simd_float4 *s = (const simd_float4 *)(src + (size_t)i * stride);
        *d = *s;
    }
    // Remainder
    if (i < frames) {
        memcpy(dst + (size_t)i * stride, src + (size_t)i * stride, (size_t)(frames - i) * stride);
    }
}

uint32_t swar_ring_write(SwarRing *ring, const void *source, uint32_t frames) {
    uint64_t w = atomic_load_explicit(&ring->written, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&ring->read, memory_order_acquire);
    uint32_t count = frames < ring->capacity - (w - r) ? frames : (uint32_t)(ring->capacity - (w - r));
    
    // Track max fill level
    uint32_t fill_before = (uint32_t)(w - r);
    uint32_t fill_after = fill_before + count;
    uint32_t old_max = atomic_load_explicit(&ring->max_fill_frames, memory_order_relaxed);
    while (fill_after > old_max && !atomic_compare_exchange_weak_explicit(&ring->max_fill_frames, &old_max, fill_after, memory_order_relaxed, memory_order_relaxed)) {}
    
    uint32_t offset = (uint32_t)(w % ring->capacity);
    uint32_t first = count < ring->capacity - offset ? count : ring->capacity - offset;
    
    // SIMD-optimized copy for Float32 stereo (most common case)
    if (ring->stride == 8) { // Float32 stereo
        simd_copy_frames_float32(ring->bytes + (size_t)offset * ring->stride, (const uint8_t *)source, first, ring->stride, 2);
    } else {
        memcpy(ring->bytes + (size_t)offset * ring->stride, source, (size_t)first * ring->stride);
    }
    
    if (count > first) {
        if (ring->stride == 8) {
            simd_copy_frames_float32(ring->bytes, (const uint8_t *)source + (size_t)first * ring->stride, count - first, ring->stride, 2);
        } else {
            memcpy(ring->bytes, (const uint8_t *)source + (size_t)first * ring->stride, (size_t)(count - first) * ring->stride);
        }
    }
    
    atomic_store_explicit(&ring->written, w + count, memory_order_release);
    atomic_fetch_add_explicit(&ring->total_frames_written, count, memory_order_relaxed);
    atomic_fetch_add_explicit(&ring->write_cycles, 1, memory_order_relaxed);
    return count;
}

static void copy_frames(const SwarRing *ring, void *destination, uint64_t r, uint32_t count) {
    uint32_t offset = (uint32_t)(r % ring->capacity);
    uint32_t first = count < ring->capacity - offset ? count : ring->capacity - offset;
    
    // SIMD-optimized copy for Float32 stereo (most common case)
    if (ring->stride == 8) { // Float32 stereo
        simd_copy_frames_float32((uint8_t *)destination, ring->bytes + (size_t)offset * ring->stride, first, ring->stride, 2);
    } else {
        memcpy(destination, ring->bytes + (size_t)offset * ring->stride, (size_t)first * ring->stride);
    }
    
    if (count > first) {
        if (ring->stride == 8) {
            simd_copy_frames_float32((uint8_t *)destination + (size_t)first * ring->stride, ring->bytes, count - first, ring->stride, 2);
        } else {
            memcpy((uint8_t *)destination + (size_t)first * ring->stride, ring->bytes, (size_t)(count - first) * ring->stride);
        }
    }
}

uint32_t swar_ring_read(SwarRing *ring, void *destination, uint32_t frames) {
    uint64_t r = atomic_load_explicit(&ring->read, memory_order_relaxed);
    // Observing EOF before written ensures all final PCM writes are visible.
    uint64_t finished = atomic_load_explicit(&ring->finished, memory_order_acquire);
    uint64_t w = atomic_load_explicit(&ring->written, memory_order_acquire);
    uint32_t count = frames < w - r ? frames : (uint32_t)(w - r);
    
    // Track min fill level
    uint32_t fill = (uint32_t)(w - r);
    uint32_t old_min = atomic_load_explicit(&ring->min_fill_frames, memory_order_relaxed);
    while (fill < old_min && !atomic_compare_exchange_weak_explicit(&ring->min_fill_frames, &old_min, fill, memory_order_relaxed, memory_order_relaxed)) {}
    
    copy_frames(ring, destination, r, count);
    if (count < frames && !finished) {
        // EOF can be published while the final PCM block is being copied. Do
        // not classify its tail using the stale flag from the start of the read.
        finished = atomic_load_explicit(&ring->finished, memory_order_acquire);
        if (finished) {
            // The producer may also have published its final samples since our
            // first written load. Drain them before zero-filling the EOF tail.
            w = atomic_load_explicit(&ring->written, memory_order_acquire);
            uint32_t final_count = frames < w - r ? frames : (uint32_t)(w - r);
            copy_frames(ring, (uint8_t *)destination + (size_t)count * ring->stride,
                        r + count, final_count - count);
            count = final_count;
        }
    }
    if (count < frames) {
        memset((uint8_t *)destination + (size_t)count * ring->stride, 0, (size_t)(frames - count) * ring->stride);
        if (!finished)
            atomic_fetch_add_explicit(&ring->underruns, frames - count, memory_order_relaxed);
    }
    atomic_store_explicit(&ring->read, r + count, memory_order_release);
    atomic_fetch_add_explicit(&ring->total_frames_read, count, memory_order_relaxed);
    atomic_fetch_add_explicit(&ring->read_cycles, 1, memory_order_relaxed);
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
    // Track active readers for safe destruction - increment BEFORE checking destroyed
    atomic_fetch_add_explicit(&ring->active_readers, 1, memory_order_acq_rel);
    // Check if ring is being destroyed
    if (atomic_load_explicit(&ring->destroyed, memory_order_acquire)) {
        // Ring is destroyed, return silence
        memset(data->mBuffers[0].mData, 0, data->mBuffers[0].mDataByteSize);
        data->mBuffers[0].mDataByteSize = frames * ring->stride;
        atomic_fetch_sub_explicit(&ring->active_readers, 1, memory_order_acq_rel);
        return noErr;
    }
    swar_ring_read(ring, data->mBuffers[0].mData, frames);
    atomic_fetch_sub_explicit(&ring->active_readers, 1, memory_order_acq_rel);
    data->mBuffers[0].mDataByteSize = frames * ring->stride;
    return noErr;
}

OSStatus swar_uninstall_render_callback(AudioUnit unit) {
    AURenderCallbackStruct callback = { .inputProc = NULL, .inputProcRefCon = NULL };
    return AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
}

OSStatus swar_install_render_callback(AudioUnit unit, SwarRing *ring) {
    AURenderCallbackStruct callback = { .inputProc = render, .inputProcRefCon = ring };
    return AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
}
