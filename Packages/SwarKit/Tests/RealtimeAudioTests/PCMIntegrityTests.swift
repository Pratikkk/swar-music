import Foundation
import RealtimeAudio
import Testing

/// Verify decoded PCM bytes can traverse the real-time ring unchanged.
/// These tests cover the C ring, not AUHAL or the physical DAC.
struct PCMIntegrityTests {
    @Test func stereo16BitFramesRemainByteExactAcrossWraparound() throws {
        let ring = try #require(swar_ring_create(5, 4))
        defer { swar_ring_destroy(ring) }

        // Stereo signed 16-bit, interleaved little-endian. Include extrema.
        let frames: [UInt8] = [
            0x00, 0x80, 0xff, 0x7f,
            0xff, 0xff, 0x01, 0x00,
            0x34, 0x12, 0xcc, 0xed,
            0x00, 0x00, 0x00, 0x80,
            0x7f, 0x00, 0x80, 0xff,
            0xff, 0x7f, 0x00, 0x80,
            0x11, 0x22, 0x33, 0x44
        ]
        #expect(frames.prefix(20).withUnsafeBytes {
            swar_ring_write(ring, $0.baseAddress!, 5)
        } == 5)

        var first = [UInt8](repeating: 0, count: 12)
        #expect(first.withUnsafeMutableBytes {
            swar_ring_read(ring, $0.baseAddress!, 3)
        } == 3)
        #expect(first == Array(frames.prefix(12)))

        let tail = Array(frames.suffix(8))
        #expect(tail.withUnsafeBytes {
            swar_ring_write(ring, $0.baseAddress!, 2)
        } == 2)
        swar_ring_finish(ring)
        var last = [UInt8](repeating: 0xff, count: 20)
        #expect(last.withUnsafeMutableBytes {
            swar_ring_read(ring, $0.baseAddress!, 5)
        } == 4)
        #expect(last == Array(frames[12...]) + [UInt8](repeating: 0, count: 4))
        #expect(swar_ring_consumed(ring) == 7)
        #expect(swar_ring_underruns(ring) == 0)
    }

    @Test func float32PCMRetainsOriginalBitPatternsWithoutArithmetic() throws {
        let ring = try #require(swar_ring_create(4, 8))
        defer { swar_ring_destroy(ring) }

        // Two channels of 32-bit float. Raw bytes include signed zero,
        // subnormal, and NaN payloads; equality is bitwise, not numeric.
        let patterns: [UInt32] = [
            0x00000000, 0x80000000,
            0x3f800000, 0xbf800000,
            0x00000001, 0x7fc00042,
            0x3f000000, 0x7f7fffff
        ]
        let input = patterns.flatMap { value in
            (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        }
        #expect(input.withUnsafeBytes {
            swar_ring_write(ring, $0.baseAddress!, 4)
        } == 4)
        swar_ring_finish(ring)

        var output = [UInt8](repeating: 0, count: input.count)
        #expect(output.withUnsafeMutableBytes {
            swar_ring_read(ring, $0.baseAddress!, 4)
        } == 4)
        #expect(output == input)
        #expect(swar_ring_underruns(ring) == 0)
    }
}
