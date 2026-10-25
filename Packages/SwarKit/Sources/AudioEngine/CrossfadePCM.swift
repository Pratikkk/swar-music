import Foundation
import AudioToolbox
import Decoding

public enum CrossfadeCurve: Sendable {
    /// Complementary gains preserve peak headroom, with a possible perceptual dip.
    case equalGain
    /// Constant power for uncorrelated sources; -3.01 dB headroom is applied to
    /// dry audio too, so the fade endpoints do not introduce a gain step.
    case equalPower

    public var dryGain: Float { self == .equalPower ? Float(1 / sqrt(2.0)) : 1 }

    public func gains(progress: Double) -> (outgoing: Float, incoming: Float) {
        let p = progress.isFinite ? min(1, max(0, progress)) : 0
        if p == 0 { return (dryGain, 0) }
        if p == 1 { return (0, dryGain) }
        let angle = p * .pi / 2
        switch self {
        case .equalPower: return (Float(cos(angle)) * dryGain, Float(sin(angle)) * dryGain)
        case .equalGain:
            let incoming = Float(pow(sin(angle), 2))
            return (1 - incoming, incoming)
        }
    }
}

/// Two separate decoders on a producer worker, never the render callback.
/// Output is interleaved Float32. Reads perform no buffer allocation or file opens.
/// Both sources must already have the same sample rate/channel count; this first
/// mixer deliberately rejects implicit conversion. The ordinary PCM path is untouched.
public final class CrossfadePCMReader {
    public let sampleRate: Double
    public let channels: Int
    public let frameCount: Int64
    public let overlapFrames: Int64
    public let curve: CrossfadeCurve
    public private(set) var position: Int64 = 0
    private let outgoing: CrossfadeFloatSource
    private let incoming: CrossfadeFloatSource
    private let a: UnsafeMutablePointer<Float>
    private let b: UnsafeMutablePointer<Float>
    private let fadeStart: Int64
    private let fadeEnd: Int64
    private var failed = false
    public static let maximumReadFrames = 4096

    public init(outgoing: any AudioDecoding, incoming: any AudioDecoding,
                overlapFrames: Int64, curve: CrossfadeCurve = .equalPower) throws {
        let first = try CrossfadeFloatSource(outgoing)
        let second = try CrossfadeFloatSource(incoming)
        guard first.rate == second.rate, first.channels == second.channels else {
            throw AudioFailure("Crossfade requires matching sample rates and channel counts. Keep gapless playback for this pair.")
        }
        guard outgoing !== incoming else { throw AudioFailure("Crossfade requires independent decoders.") }
        guard overlapFrames >= 2, overlapFrames <= Int64(first.rate * 12),
              overlapFrames < outgoing.frameCount, overlapFrames < incoming.frameCount,
              outgoing.frameCount <= Int64.max - (incoming.frameCount - overlapFrames) else {
            throw AudioFailure("Invalid crossfade overlap or source duration.")
        }
        try outgoing.seek(to: 0)
        try incoming.seek(to: 0)
        self.outgoing = first; self.incoming = second
        sampleRate = first.rate; channels = first.channels
        self.overlapFrames = overlapFrames; self.curve = curve
        fadeStart = outgoing.frameCount - overlapFrames
        fadeEnd = outgoing.frameCount
        frameCount = outgoing.frameCount + (incoming.frameCount - overlapFrames)
        a = .allocate(capacity: Self.maximumReadFrames * channels)
        b = .allocate(capacity: Self.maximumReadFrames * channels)
    }

    deinit { a.deallocate(); b.deallocate() }

    /// Restart by source frame, including positions inside the overlap. Caller
    /// must stop/discard its output ring before adopting the new producer position.
    public func seek(to frame: Int64) throws {
        guard (0...frameCount).contains(frame) else { throw AudioFailure("Crossfade seek is out of range.") }
        do {
            try outgoing.decoder.seek(to: min(frame, fadeEnd))
            try incoming.decoder.seek(to: max(0, frame - fadeStart))
        } catch { failed = true; throw error }
        position = frame
        failed = false
    }

    /// Returns up to 4096 frames. A phase boundary may produce a shorter block;
    /// callers refill rather than interpreting a short nonzero read as EOF.
    public func read(into destination: UnsafeMutableBufferPointer<Float>, frames: Int) throws -> Int {
        guard !failed else { throw AudioFailure("The crossfade source must be reset after a decoding failure.") }
        guard frames >= 0, frames <= Self.maximumReadFrames,
              destination.count >= frames * channels else { throw AudioFailure("Invalid crossfade output buffer.") }
        guard frames > 0, position < frameCount else { return 0 }
        let boundary = position < fadeStart ? fadeStart : position < fadeEnd ? fadeEnd : frameCount
        let count = min(frames, Int(min(Int64(frames), boundary - position)))
        if position < fadeStart {
            try read(outgoing, into: a, frames: count)
            for i in 0..<(count * channels) { destination[i] = a[i] * curve.dryGain }
        } else if position < fadeEnd {
            try read(outgoing, into: a, frames: count)
            try read(incoming, into: b, frames: count)
            for frame in 0..<count {
                let progress = Double(position - fadeStart + Int64(frame)) / Double(overlapFrames - 1)
                let gain = curve.gains(progress: progress)
                for channel in 0..<channels {
                    let i = frame * channels + channel
                    // Inputs are bounded at conversion; these curves reserve enough
                    // headroom even for fully correlated full-scale sources.
                    destination[i] = max(-1, min(1, a[i] * gain.outgoing + b[i] * gain.incoming))
                }
            }
        } else {
            try read(incoming, into: b, frames: count)
            for i in 0..<(count * channels) { destination[i] = b[i] * curve.dryGain }
        }
        position += Int64(count)
        return count
    }

    private func read(_ source: CrossfadeFloatSource, into buffer: UnsafeMutablePointer<Float>, frames: Int) throws {
        do { try source.read(into: buffer, frames: frames) }
        catch { failed = true; throw error }
    }
}

private final class CrossfadeFloatSource {
    let decoder: any AudioDecoding
    let channels: Int
    let rate: Double
    private let bytes: Int
    private let bits: Int
    private let sampleBytes: Int
    private let floating: Bool
    private let signed: Bool
    private let bigEndian: Bool
    private let highAligned: Bool
    private let scratch: UnsafeMutableRawPointer

    init(_ decoder: any AudioDecoding) throws {
        let format = decoder.pcmFormat
        let channels = Int(format.mChannelsPerFrame), bytes = Int(format.mBytesPerFrame), bits = Int(format.mBitsPerChannel)
        let floating = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        guard format.mFormatID == kAudioFormatLinearPCM, (1...8).contains(channels),
              format.mSampleRate.isFinite, (8000...384000).contains(format.mSampleRate),
              decoder.frameCount > 0, bytes > 0, bytes <= 64, bytes % channels == 0,
              format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
              floating ? [32, 64].contains(bits) : [8, 16, 20, 24, 32].contains(bits),
              bytes / channels == (bits + 7) / 8 else { throw AudioFailure("Unsupported crossfade PCM layout.") }
        self.decoder = decoder; self.channels = channels; rate = format.mSampleRate
        self.bytes = bytes; self.bits = bits; self.floating = floating; sampleBytes = bytes / channels
        signed = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        bigEndian = format.mFormatFlags & kAudioFormatFlagIsBigEndian != 0
        highAligned = format.mFormatFlags & kAudioFormatFlagIsAlignedHigh != 0
        scratch = .allocate(byteCount: CrossfadePCMReader.maximumReadFrames * bytes, alignment: 16)
    }
    deinit { scratch.deallocate() }

    func read(into output: UnsafeMutablePointer<Float>, frames: Int) throws {
        var received = 0
        while received < frames {
            let count = Int(try decoder.read(into: scratch.advanced(by: received * bytes), frames: UInt32(frames - received)))
            guard count > 0, count <= frames - received else { throw AudioFailure("Crossfade source ended before its scheduled boundary.") }
            received += count
        }
        let data = scratch.assumingMemoryBound(to: UInt8.self)
        for i in 0..<(frames * channels) {
            var raw: UInt64 = 0
            for byte in 0..<sampleBytes {
                raw |= UInt64(data[i * sampleBytes + byte]) << ((bigEndian ? sampleBytes - byte - 1 : byte) * 8)
            }
            let sample: Double
            if floating { sample = bits == 32 ? Double(Float(bitPattern: UInt32(truncatingIfNeeded: raw))) : Double(bitPattern: raw) }
            else {
                if highAligned { raw >>= sampleBytes * 8 - bits }
                let range = UInt64(1) << bits
                raw &= range - 1
                let half = Int64(range / 2)
                let value = signed ? (raw >= range / 2 ? Int64(raw) - Int64(range) : Int64(raw)) : Int64(raw) - half
                sample = Double(value) / Double(half)
            }
            output[i] = sample.isFinite ? Float(max(-1, min(1, sample))) : 0
        }
    }
}
