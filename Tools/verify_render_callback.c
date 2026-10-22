// Exercises the actual static AUHAL render callback without opening hardware.
// Including the implementation makes the internal callback visible to this test
// translation unit; production exports and the render hot path remain unchanged.
#include "../Packages/SwarKit/Sources/RealtimeAudio/RealtimeAudio.c"
#include <assert.h>
#include <stdio.h>

static OSStatus invoke(SwarRing *ring, AudioBufferList *list, UInt32 frames) {
    AudioUnitRenderActionFlags flags = 0;
    AudioTimeStamp time = {0};
    return render(ring, &flags, &time, 0, frames, list);
}

static void exact_and_eof(void) {
    SwarRing *ring = swar_ring_create(4, 4);
    assert(ring);
    uint8_t pcm[12] = {0x00,0x80,0xff,0x7f, 0x01,0x00,0xff,0xff,
                       0x34,0x12,0xcc,0xed};
    assert(swar_ring_write(ring, pcm, 3) == 3);
    swar_ring_finish(ring);
    uint8_t out[16];
    memset(out, 0xa5, sizeof out);
    AudioBufferList list = { .mNumberBuffers = 1,
        .mBuffers = {{ .mNumberChannels = 2, .mDataByteSize = sizeof out, .mData = out }} };
    assert(invoke(ring, &list, 4) == noErr);
    assert(list.mBuffers[0].mDataByteSize == 16);
    assert(memcmp(out, pcm, sizeof pcm) == 0);
    const uint8_t zeros[4] = {0};
    assert(memcmp(out + 12, zeros, 4) == 0);
    assert(swar_ring_consumed(ring) == 3);
    assert(swar_ring_underruns(ring) == 0);
    swar_ring_destroy(ring);
}

static void starvation(void) {
    SwarRing *ring = swar_ring_create(4, 4);
    assert(ring);
    uint8_t pcm[4] = {1, 2, 3, 4}, out[12];
    assert(swar_ring_write(ring, pcm, 1) == 1);
    memset(out, 0xa5, sizeof out);
    AudioBufferList list = { .mNumberBuffers = 1,
        .mBuffers = {{ .mNumberChannels = 2, .mDataByteSize = sizeof out, .mData = out }} };
    assert(invoke(ring, &list, 3) == noErr);
    assert(memcmp(out, pcm, 4) == 0);
    const uint8_t zeros[8] = {0};
    assert(memcmp(out + 4, zeros, 8) == 0);
    assert(swar_ring_underruns(ring) == 2);
    swar_ring_destroy(ring);
}

static void invalid_buffer(void) {
    SwarRing *ring = swar_ring_create(4, 4);
    assert(ring);
    uint8_t out[8];
    memset(out, 0xa5, sizeof out);
    AudioBufferList list = { .mNumberBuffers = 1,
        .mBuffers = {{ .mNumberChannels = 2, .mDataByteSize = sizeof out, .mData = out }} };
    assert(invoke(ring, &list, 3) == kAudio_ParamError);
    const uint8_t zeros[8] = {0};
    assert(memcmp(out, zeros, sizeof out) == 0);
    assert(swar_ring_consumed(ring) == 0);
    assert(invoke(ring, NULL, 1) == kAudio_ParamError);
    swar_ring_destroy(ring);
}

int main(void) {
    exact_and_eof();
    starvation();
    invalid_buffer();
    puts("AUHAL render callback checks passed");
    return 0;
}
