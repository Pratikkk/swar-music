import AudioToolbox
import Decoding
import Foundation
import RealtimeAudio
import Testing
@testable import AudioEngine

struct CrossfadeConversionTests {
    @Test(arguments: [(44100.0, 48000.0), (48000, 44100), (96000, 44100), (44100, 96000), (44100, 44100)])
    func conversionPreservesDurationChannelsAndSignal(rates: (Double, Double)) throws {
        let converted = try ConvertedPCMDecoder(decoder: ConversionFixture(rate: rates.0), sampleRate: rates.1)
        let samples = try drain(converted, chunk: 127)
        #expect(samples.count == Int(rates.1 * 0.2) * 2)
        #expect(converted.pcmFormat.mSampleRate == rates.1)
        #expect(converted.originalSource.sampleRate == rates.0)
        #expect(!converted.source.isLossless)
        #expect(samples.allSatisfy { $0.isFinite })
        let errors = (100..<(samples.count / 2 - 100)).map { frame in
            abs(samples[frame * 2] - Float(sin(2 * .pi * 440 * Double(frame) / rates.1) * 0.5))
        }
        #expect((errors.max() ?? 1) < 0.04, "Rates: \(rates); first samples: \(Array(samples.prefix(12)))")
        #expect(stride(from: 0, to: samples.count, by: 2).allSatisfy { abs(samples[$0] + samples[$0 + 1]) < 0.001 })
        try converted.seek(to: 0)
        #expect(try drain(converted, chunk: 4096) == samples)
    }

    @Test func convertedSeekIsBoundedAndRetainsTargetTime() throws {
        let converted = try ConvertedPCMDecoder(decoder: ConversionFixture(rate: 44100), sampleRate: 48000)
        let all = try drain(converted, chunk: 4096)
        try converted.seek(to: 6000)
        let tail = try drain(converted, chunk: 113)
        #expect(tail.count == (9600 - 6000) * 2)
        #expect((100..<tail.count).allSatisfy { abs(tail[$0] - all[12000 + $0]) < 0.05 })
        try converted.seek(to: converted.frameCount)
        #expect(try drain(converted, chunk: 32).isEmpty)
        #expect(throws: (any Error).self) { try converted.seek(to: -1) }
    }

    @Test func mixedRatesFeedExistingCRingWithoutEarlyIdentityPromotion() throws {
        let reader = try makeReader()
        let expected = try drainReader(try makeReader())
        let producer = try CrossfadeRingProducer(reader: reader, capacity: 257)
        let initial = producer.audible
        try producer.fill()
        #expect(producer.audible == initial)
        var output: [Float] = [], buffer = [Float](repeating: 0, count: 113 * 2)
        while !producer.eof || swar_ring_readable(producer.ring) > 0 {
            try producer.fill()
            let count = min(113, swar_ring_readable(producer.ring))
            let received = buffer.withUnsafeMutableBytes { swar_ring_read(producer.ring, $0.baseAddress!, count) }
            output.append(contentsOf: buffer.prefix(Int(received) * 2))
            let consumed = Int64(output.count / 2)
            #expect(producer.audible.incoming == (consumed >= reader.incomingPromotionFrame))
            #expect(producer.audible.transitioning == (consumed >= reader.outgoingTransitionFrame && consumed < reader.incomingPromotionFrame))
        }
        #expect(output == expected)
        #expect(swar_ring_underruns(producer.ring) == 0)
        #expect(abs(producer.audible.sourcePosition - 0.2) < 1e-8)
        // EOF drain must not count as starvation.
        _ = buffer.withUnsafeMutableBytes { swar_ring_read(producer.ring, $0.baseAddress!, 113) }
        #expect(swar_ring_underruns(producer.ring) == 0)
        try producer.seek(to: reader.incomingPromotionFrame)
        #expect(producer.audible.incoming)
        #expect(abs(producer.audible.sourcePosition - 0.05) < 1e-8)
        try producer.fill()
        #expect(swar_ring_readable(producer.ring) > 0)
        try producer.seek(to: 0)
        #expect(!producer.audible.incoming && !producer.audible.transitioning)
        #expect(swar_ring_readable(producer.ring) == 0)
    }

    @Test func converterRejectsUnsupportedOutputAndPropagatesDecodeFailure() throws {
        #expect(throws: (any Error).self) { try ConvertedPCMDecoder(decoder: ConversionFixture(rate: 44100), sampleRate: .nan) }
        let fixture = ConversionFixture(rate: 44100)
        fixture.fail = true
        let decoder = try ConvertedPCMDecoder(decoder: fixture, sampleRate: 48000)
        #expect(throws: (any Error).self) { try drain(decoder, chunk: 127) }
        fixture.fail = false
        #expect(throws: (any Error).self) { try drain(decoder, chunk: 127) }
        try decoder.seek(to: 0)
        #expect(!(try drain(decoder, chunk: 127)).isEmpty)
    }

    private func makeReader() throws -> CrossfadePCMReader {
        let first = try ConvertedPCMDecoder(decoder: ConversionFixture(rate: 44100), sampleRate: 48000)
        let second = try ConvertedPCMDecoder(decoder: ConversionFixture(rate: 96000), sampleRate: 48000)
        return try CrossfadePCMReader(outgoing: first, incoming: second, overlapFrames: 2400)
    }
    private func drain(_ decoder: ConvertedPCMDecoder, chunk: Int) throws -> [Float] {
        var buffer = [Float](repeating: 0, count: chunk * 2), all: [Float] = []
        while true {
            let count = try buffer.withUnsafeMutableBytes { try decoder.read(into: $0.baseAddress!, frames: UInt32(chunk)) }
            if count == 0 { return all }
            all.append(contentsOf: buffer.prefix(Int(count) * 2))
        }
    }
    private func drainReader(_ reader: CrossfadePCMReader) throws -> [Float] {
        var buffer = [Float](repeating: 0, count: 4096 * 2), all: [Float] = []
        while true {
            let count = try buffer.withUnsafeMutableBufferPointer { try reader.read(into: $0, frames: 4096) }
            if count == 0 { return all }
            all.append(contentsOf: buffer.prefix(count * 2))
        }
    }
}

private final class ConversionFixture: AudioDecoding {
    let pcmFormat: AudioStreamBasicDescription
    let source: SourceFormat
    let frameCount: Int64
    var position = 0
    var fail = false
    init(rate: Double) {
        frameCount = Int64(rate * 0.2)
        source = SourceFormat(codec: "Test", sampleRate: rate, bitDepth: 32, channels: 2, isLossless: true, isFloat: true)
        pcmFormat = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    }
    func read(into buffer: UnsafeMutableRawPointer, frames: UInt32) throws -> UInt32 {
        if fail { throw AudioFailure("Injected decoder failure") }
        let count = min(Int(frames), Int(frameCount) - position, 503)
        let out = buffer.assumingMemoryBound(to: Float.self)
        for frame in 0..<count {
            let value = Float(sin(2 * .pi * 440 * Double(position + frame) / source.sampleRate) * 0.5)
            out[frame * 2] = value; out[frame * 2 + 1] = -value
        }
        position += count
        return UInt32(count)
    }
    func seek(to frame: Int64) throws { position = Int(frame) }
}
