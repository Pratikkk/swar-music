// Deterministic EOF-race regression. Compile/run instructions: Docs/ResourceEfficiency.md.
// Interpose only this test translation unit's memcpy so EOF can be published
// exactly between swar_ring_read's initial snapshot and its short-read decision.
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "RealtimeAudio.h"

static SwarRing *finish_during_copy;
static uint32_t append_frames;
static const uint32_t final_samples[] = {44, 55};
static void *copy_and_finish(void *destination, const void *source, size_t size);
#undef memcpy
#define memcpy copy_and_finish
#ifndef SWAR_RING_SOURCE
#define SWAR_RING_SOURCE "../Packages/SwarKit/Sources/RealtimeAudio/RealtimeAudio.c"
#endif
#include SWAR_RING_SOURCE
#undef memcpy

static void *copy_and_finish(void *destination, const void *source, size_t size) {
    void *result = memcpy(destination, source, size);
    if (finish_during_copy && size) {
        SwarRing *ring = finish_during_copy;
        finish_during_copy = NULL; // The nested write must not trigger this hook.
        if (append_frames) assert(swar_ring_write(ring, final_samples, append_frames) == append_frames);
        swar_ring_finish(ring);
    }
    return result;
}

static int verify(uint32_t appended) {
    SwarRing *ring = swar_ring_create(5, sizeof(uint32_t));
    assert(ring);
    const uint32_t initial[] = {11, 22, 33};
    assert(swar_ring_write(ring, initial, 3) == 3);
    uint32_t output[6];
    memset(output, 0xff, sizeof(output));
    append_frames = appended;
    finish_during_copy = ring;
    uint32_t count = swar_ring_read(ring, output, 6);
    int failed = count != 3 + appended || swar_ring_underruns(ring) != 0 || swar_ring_consumed(ring) != count;
    for (unsigned i = 0; i < 6; ++i) {
        uint32_t expected = i < 3 ? initial[i] : i < 3 + appended ? final_samples[i - 3] : 0;
        if (output[i] != expected) failed = 1;
    }
    if (failed) fprintf(stderr, "Late EOF (append %u): read %u, underruns %llu\n", appended,
                        count, (unsigned long long)swar_ring_underruns(ring));
    swar_ring_destroy(ring);
    return failed;
}

int main(void) {
    int failed = verify(0) | verify(2);
    if (!failed) puts("Late EOF during copy: tail counting and final PCM drain passed.");
    return failed;
}
