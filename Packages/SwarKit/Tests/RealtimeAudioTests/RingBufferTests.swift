import Foundation
import RealtimeAudio
import Testing

struct RingBufferTests {
    @Test func endOfFileSilenceIsNotAnUnderrun() throws {
        let ring = try #require(swar_ring_create(5, 6))
        defer { swar_ring_destroy(ring) }
        swar_ring_finish(ring)
        var output = [UInt8](repeating: 255, count: 6)
        #expect(output.withUnsafeMutableBytes { swar_ring_read(ring, $0.baseAddress!, 1) } == 0)
        #expect(output == [UInt8](repeating: 0, count: 6))
        #expect(swar_ring_underruns(ring) == 0)
    }

    @Test func packed24BitFramesSurviveWraparoundAndUnderflowIsSilent() throws {
        let ring = try #require(swar_ring_create(5, 6))
        defer { swar_ring_destroy(ring) }
        let input = Array(UInt8(1)...UInt8(30))
        var output = [UInt8](repeating: 255, count: 18)
        #expect(input.withUnsafeBytes { swar_ring_write(ring, $0.baseAddress!, 5) } == 5)
        #expect(output.withUnsafeMutableBytes { swar_ring_read(ring, $0.baseAddress!, 3) } == 3)
        #expect(output == Array(input.prefix(18)))
        #expect(input.withUnsafeBytes { swar_ring_write(ring, $0.baseAddress!, 3) } == 3)
        var wrapped = [UInt8](repeating: 255, count: 36)
        #expect(wrapped.withUnsafeMutableBytes { swar_ring_read(ring, $0.baseAddress!, 6) } == 5)
        #expect(wrapped == Array(input.suffix(12)) + Array(input.prefix(18)) + [UInt8](repeating: 0, count: 6))
        #expect(swar_ring_consumed(ring) == 8)
        #expect(swar_ring_underruns(ring) == 1)
        swar_ring_reset(ring)
        #expect(swar_ring_readable(ring) == 0)
        #expect(swar_ring_consumed(ring) == 0)
        #expect(swar_ring_underruns(ring) == 0)
    }

    @Test func concurrentProducerConsumerPreserveSampleOrder() throws {
        let state = try ConcurrentRing()
        DispatchQueue.concurrentPerform(iterations: 2) { worker in
            let total: UInt32 = 200_000
            if worker == 0 {
                var next: UInt32 = 0
                while next < total {
                    let batch = (0..<min(127, total - next)).map { next + $0 }
                    let count = batch.withUnsafeBytes { swar_ring_write(state.ring, $0.baseAddress!, UInt32(batch.count)) }
                    next += count
                }
            } else {
                var next: UInt32 = 0
                var batch = [UInt32](repeating: 0, count: 113)
                while next < total {
                    let available = min(113, swar_ring_readable(state.ring))
                    if available == 0 { continue }
                    let count = batch.withUnsafeMutableBytes { swar_ring_read(state.ring, $0.baseAddress!, available) }
                    for index in 0..<Int(count) {
                        if batch[index] != next { state.mismatch = true }
                        next += 1
                    }
                }
            }
        }
        #expect(!state.mismatch)
        #expect(swar_ring_consumed(state.ring) == 200_000)
        #expect(swar_ring_underruns(state.ring) == 0)
    }
}

/// Ring counters are atomic; mismatch is written only by the consumer and read after join.
private final class ConcurrentRing: @unchecked Sendable {
    let ring: OpaquePointer
    var mismatch = false
    init() throws { ring = try #require(swar_ring_create(257, 4)) }
    deinit { swar_ring_destroy(ring) }
}
