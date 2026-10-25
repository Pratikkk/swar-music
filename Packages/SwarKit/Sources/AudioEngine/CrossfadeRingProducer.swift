import Foundation
import RealtimeAudio
import Decoding

/// Producer-side bridge to the existing C render callback. The UI must derive
/// identity and time from consumed frames, never the decoder's buffered position.
/// Reset/destroy only after the audio unit is stopped and its callback detached.
public final class CrossfadeRingProducer {
    public struct AudiblePosition: Sendable, Equatable {
        public let incoming: Bool
        public let transitioning: Bool
        public let sourcePosition: Double
    }
    public let ring: OpaquePointer
    public let sampleRate: Double
    public let channels: Int
    public private(set) var eof = false
    private let reader: CrossfadePCMReader
    private let scratch: UnsafeMutablePointer<Float>
    private let fadeStart: Int64
    private let fadeEnd: Int64
    private var baseFrame: Int64 = 0
    private var failure: Error?

    public init(reader: CrossfadePCMReader, capacity: UInt32? = nil) throws {
        sampleRate = reader.sampleRate; channels = reader.channels
        self.reader = reader
        guard reader.position == 0 else { throw AudioFailure("The crossfade producer must start with a fresh reader.") }
        // Total output = outgoing + incoming - overlap. Obtain the audible boundary
        // explicitly from the reader instead of inferring it from predecoded frames.
        fadeStart = reader.outgoingTransitionFrame
        fadeEnd = reader.incomingPromotionFrame
        let frames = capacity ?? UInt32(sampleRate)
        guard frames > 0, frames <= UInt32(sampleRate * 4),
              let ring = swar_ring_create(frames, UInt32(channels * MemoryLayout<Float>.size)) else {
            throw AudioFailure("Could not allocate a bounded crossfade ring.")
        }
        self.ring = ring
        scratch = .allocate(capacity: 4096 * channels)
    }
    deinit { scratch.deallocate(); swar_ring_destroy(ring) }

    public var audible: AudiblePosition {
        let frame = min(reader.frameCount, baseFrame + Int64(swar_ring_consumed(ring)))
        return AudiblePosition(incoming: frame >= fadeEnd, transitioning: frame >= fadeStart && frame < fadeEnd,
            sourcePosition: Double(frame >= fadeEnd ? frame - fadeStart : frame) / sampleRate)
    }

    public func fill(upTo target: UInt32 = .max) throws {
        if let failure { throw failure }
        guard !eof else { return }
        do {
            while swar_ring_writable(ring) > 0, swar_ring_readable(ring) < target {
                let count = min(4096, swar_ring_writable(ring), target - swar_ring_readable(ring))
                let frames = try reader.read(into: UnsafeMutableBufferPointer(start: scratch, count: Int(count) * channels), frames: Int(count))
                if frames == 0 { eof = true; swar_ring_finish(ring); break }
                guard swar_ring_write(ring, scratch, UInt32(frames)) == UInt32(frames) else {
                    throw AudioFailure("Crossfade ring write failed.")
                }
            }
            if reader.position == reader.frameCount { eof = true; swar_ring_finish(ring) }
        } catch { failure = error; throw error }
    }

    /// Caller stops AUHAL first. Failure leaves the producer unusable until reset.
    public func seek(to frame: Int64) throws {
        do {
            try reader.seek(to: frame)
            swar_ring_reset(ring)
            baseFrame = frame; eof = false; failure = nil
        } catch { failure = error; throw error }
    }
}
