import Testing
import Foundation
import AudioToolbox
import Decoding
@testable import AudioEngine

struct CrossfadePCMTests {
    @Test(arguments: [1, 3, 7, 4096]) func chunkBoundariesNeverChangeSamples(chunk: Int) throws {
        let out = (0..<40).map { Float($0) / 100 }
        let incoming = (0..<40).map { Float($0 + 50) / 100 }
        let reader = try CrossfadePCMReader(outgoing: FloatDecoder(out, channels: 2, chunk: 3),
            incoming: FloatDecoder(incoming, channels: 2, chunk: 2), overlapFrames: 8)
        let result = try drain(reader, chunk: chunk)
        #expect(result.count == 32 * 2)
        for frame in 0..<32 {
            for channel in 0..<2 {
                let expected: Float
                if frame < 12 { expected = out[frame * 2 + channel] * reader.curve.dryGain }
                else if frame < 20 {
                    let gain = reader.curve.gains(progress: Double(frame - 12) / 7)
                    expected = out[frame * 2 + channel] * gain.outgoing + incoming[(frame - 12) * 2 + channel] * gain.incoming
                } else { expected = incoming[(frame - 12) * 2 + channel] * reader.curve.dryGain }
                #expect(abs(result[frame * 2 + channel] - expected) < 1e-6)
            }
        }
        #expect(reader.position == reader.frameCount)
    }

    @Test(arguments: [CrossfadeCurve.equalGain, .equalPower]) func fullScaleCorrelatedSourcesStayBounded(curve: CrossfadeCurve) throws {
        let reader = try CrossfadePCMReader(outgoing: FloatDecoder(Array(repeating: 1, count: 200)),
            incoming: FloatDecoder(Array(repeating: 1, count: 200)), overlapFrames: 100, curve: curve)
        let result = try drain(reader, chunk: 17)
        #expect(result.allSatisfy { $0.isFinite && abs($0) <= 1 })
        #expect(result.first == curve.dryGain && result.last == curve.dryGain)
        #expect(abs(result[99] - result[100]) < 1e-6)
        #expect(abs(result[199] - result[200]) < 1e-6)
    }

    @Test func seekingWithinEveryPhaseMatchesUninterruptedPCM() throws {
        let values = (0..<60).map { Float($0) / 100 }
        let reader = try CrossfadePCMReader(outgoing: FloatDecoder(values), incoming: FloatDecoder(values.reversed()), overlapFrames: 20)
        let all = try drain(reader, chunk: 11)
        for position in [0, 39, 40, 50, 59, 60, 99, 100] {
            try reader.seek(to: Int64(position))
            #expect(try drain(reader, chunk: 7) == Array(all.dropFirst(position)))
        }
    }

    @Test func rejectsAliasedDecodersMismatchedRatesAndInvalidRequests() throws {
        let one = FloatDecoder(Array(repeating: 0, count: 20))
        #expect(throws: (any Error).self) { try CrossfadePCMReader(outgoing: one, incoming: one, overlapFrames: 4) }
        #expect(throws: (any Error).self) {
            try CrossfadePCMReader(outgoing: one, incoming: FloatDecoder(Array(repeating: 0, count: 20), rate: 48000), overlapFrames: 4)
        }
        for overlap in [Int64(-1), 0, 1, 20, .max] {
            #expect(throws: (any Error).self) {
                try CrossfadePCMReader(outgoing: one, incoming: FloatDecoder(Array(repeating: 0, count: 20)), overlapFrames: overlap)
            }
        }
        let reader = try CrossfadePCMReader(outgoing: one, incoming: FloatDecoder(Array(repeating: 0, count: 20)), overlapFrames: 4)
        var buffer = [Float](repeating: 0, count: 3)
        #expect(throws: (any Error).self) { try buffer.withUnsafeMutableBufferPointer { try reader.read(into: $0, frames: 4) } }
        #expect(throws: (any Error).self) { try reader.seek(to: -1) }
    }

    @Test func decoderFailureNeverPublishesPartialMixedBlockOrAllowsMisalignedRetry() throws {
        let missing = FloatDecoder(Array(repeating: 0, count: 20))
        missing.availableFrames = 0
        let reader = try CrossfadePCMReader(outgoing: FloatDecoder(Array(repeating: 1, count: 20)), incoming: missing, overlapFrames: 8)
        var buffer = [Float](repeating: 123, count: 20)
        _ = try buffer.withUnsafeMutableBufferPointer { try reader.read(into: $0, frames: 12) }
        buffer = Array(repeating: 123, count: 20)
        #expect(throws: (any Error).self) { try buffer.withUnsafeMutableBufferPointer { try reader.read(into: $0, frames: 8) } }
        #expect(buffer.allSatisfy { $0 == 123 })
        #expect(reader.position == 12)
        #expect(throws: (any Error).self) { try buffer.withUnsafeMutableBufferPointer { try reader.read(into: $0, frames: 1) } }
        try reader.seek(to: 0)
        #expect(try buffer.withUnsafeMutableBufferPointer { try reader.read(into: $0, frames: 2) } == 2)
    }

    @Test func packed24BitConversionAndNonfiniteFloatSafety() throws {
        let packed = Packed24Decoder()
        let reader = try CrossfadePCMReader(outgoing: packed, incoming: FloatDecoder([.nan, .infinity, -.infinity, 2, -2, 0, 0, 0]), overlapFrames: 2, curve: .equalGain)
        let result = try drain(reader, chunk: 3)
        #expect(abs(result[0] - Float(8388607.0 / 8388608)) < 1e-6)
        #expect(result[1] == -1)
        #expect(result.allSatisfy { $0.isFinite && abs($0) <= 1 })
    }

    private func drain(_ reader: CrossfadePCMReader, chunk: Int) throws -> [Float] {
        var buffer = [Float](repeating: 0, count: chunk * reader.channels), result: [Float] = []
        while true {
            let count = try buffer.withUnsafeMutableBufferPointer { try reader.read(into: $0, frames: chunk) }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count * reader.channels))
        }
    }
}

private final class FloatDecoder: AudioDecoding {
    let samples: [Float]
    let pcmFormat: AudioStreamBasicDescription
    let source: SourceFormat
    let frameCount: Int64
    var availableFrames: Int
    let chunk: Int
    var position = 0
    init(_ samples: [Float], channels: Int = 1, rate: Double = 44100, chunk: Int = 4096) {
        self.samples = samples; self.chunk = chunk
        availableFrames = samples.count / channels; frameCount = Int64(availableFrames)
        source = SourceFormat(codec: "Test", sampleRate: rate, bitDepth: 32, channels: channels, isLossless: true, isFloat: true)
        pcmFormat = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: UInt32(channels * 4),
            mFramesPerPacket: 1, mBytesPerFrame: UInt32(channels * 4), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    }
    func read(into buffer: UnsafeMutableRawPointer, frames: UInt32) throws -> UInt32 {
        let channels = Int(pcmFormat.mChannelsPerFrame)
        let count = max(0, min(Int(frames), chunk, availableFrames - position))
        let output = buffer.assumingMemoryBound(to: Float.self)
        for i in 0..<(count * channels) { output[i] = samples[position * channels + i] }
        position += count
        return UInt32(count)
    }
    func seek(to frame: Int64) throws { position = Int(frame) }
}

private final class Packed24Decoder: AudioDecoding {
    let frameCount: Int64 = 8
    let source = SourceFormat(codec: "PCM", sampleRate: 44100, bitDepth: 24, channels: 1, isLossless: true)
    let pcmFormat = AudioStreamBasicDescription(mSampleRate: 44100, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 3,
        mFramesPerPacket: 1, mBytesPerFrame: 3, mChannelsPerFrame: 1, mBitsPerChannel: 24, mReserved: 0)
    var position = 0
    func read(into buffer: UnsafeMutableRawPointer, frames: UInt32) throws -> UInt32 {
        let count = min(Int(frames), 8 - position)
        let output = buffer.assumingMemoryBound(to: UInt8.self)
        for i in 0..<count {
            let value: UInt32 = (position + i) % 2 == 0 ? 0x7fffff : 0x800000
            for byte in 0..<3 { output[i * 3 + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
        }
        position += count; return UInt32(count)
    }
    func seek(to frame: Int64) throws { position = Int(frame) }
}
