import AVFAudio
import AudioToolbox
import Foundation
import Decoding

/// Opt-in processing adapter. Own on the producer worker, never the render thread.
/// Original format metadata remains available separately from the converted format.
public final class ConvertedPCMDecoder: AudioDecoding {
    public let originalSource: SourceFormat
    public let source: SourceFormat
    public let pcmFormat: AudioStreamBasicDescription
    public let frameCount: Int64
    private let input: CrossfadeFloatSource
    private let converter: AVAudioConverter
    private let inputBuffer: AVAudioPCMBuffer
    private let outputBuffer: AVAudioPCMBuffer
    private let feed: ConverterFeed
    private let discard: UnsafeMutableRawPointer
    private var inputPosition: Int64 = 0
    private var outputPosition: Int64 = 0
    private var outputOffset = 0
    private var ended = false
    private var failed = false
    private let ratio: Double
    private let frameBytes: Int

    public init(decoder: any AudioDecoding, sampleRate: Double, channels: Int? = nil) throws {
        let input = try CrossfadeFloatSource(decoder)
        let channels = channels ?? input.channels
        // Only duplicate mono. Never infer surround layouts or discard stereo width.
        guard channels == input.channels || (input.channels == 1 && channels == 2) else {
            throw AudioFailure("This channel conversion is unavailable.")
        }
        guard sampleRate.isFinite, (8000...384000).contains(sampleRate),
              Double(decoder.frameCount) * sampleRate / input.rate < Double(Int64.max),
              let from = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: input.rate,
                  channels: AVAudioChannelCount(channels), interleaved: true),
              let to = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                  channels: AVAudioChannelCount(channels), interleaved: true),
              let converter = AVAudioConverter(from: from, to: to),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: from, frameCapacity: 4096),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: 4096) else {
            throw AudioFailure("This sample-rate conversion is unavailable.")
        }
        self.input = input; self.converter = converter
        self.inputBuffer = inputBuffer; self.outputBuffer = outputBuffer
        feed = ConverterFeed(source: input, buffer: inputBuffer)
        converter.primeMethod = .normal
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        ratio = sampleRate / input.rate
        frameCount = Int64(floor(Double(decoder.frameCount) * ratio))
        guard frameCount > 0 else { throw AudioFailure("The converted source is empty.") }
        originalSource = decoder.source
        source = SourceFormat(codec: decoder.source.codec + " (converted)", sampleRate: sampleRate,
            bitDepth: 32, channels: channels, isLossless: false, isFloat: true)
        pcmFormat = to.streamDescription.pointee
        frameBytes = channels * MemoryLayout<Float>.size
        try decoder.seek(to: 0)
        discard = .allocate(byteCount: 4096 * frameBytes, alignment: 16)
    }
    deinit { discard.deallocate() }

    /// Bounded preroll rebuilds the converter after a seek; output position is in
    /// converted frames. This processed path does not promise bit-perfect seeks.
    public func seek(to frame: Int64) throws {
        guard (0...frameCount).contains(frame) else { throw AudioFailure("Converted seek is out of range.") }
        failed = true
        if frame == frameCount {
            try input.decoder.seek(to: input.decoder.frameCount)
            inputPosition = input.decoder.frameCount; outputPosition = frame
            converter.reset(); outputBuffer.frameLength = 0; outputOffset = 0; ended = true; failed = false
            return
        }
        let preroll = Int64(ceil(input.rate * 0.05))
        let start = max(0, Int64(floor(Double(frame) / ratio)) - preroll)
        try input.decoder.seek(to: start)
        inputPosition = start
        // Round the preroll anchor up so fractional source/output ratios cannot
        // request an extra nonexistent frame at EOF after a nonzero seek.
        outputPosition = Int64(ceil(Double(start) * ratio))
        converter.reset(); outputBuffer.frameLength = 0; outputOffset = 0; ended = false; failed = false
        do {
            while outputPosition < frame {
                let count = try read(into: discard, frames: UInt32(min(4096, frame - outputPosition)))
                guard count > 0 else { throw AudioFailure("Converted seek ended early.") }
            }
        } catch { failed = true; throw error }
    }

    public func read(into buffer: UnsafeMutableRawPointer, frames: UInt32) throws -> UInt32 {
        guard !failed else { throw AudioFailure("Reset the converted decoder after a failure.") }
        guard frames <= 4096 else { throw AudioFailure("Converted reads are limited to 4096 frames.") }
        let requested = min(Int(frames), Int(min(Int64(frames), frameCount - outputPosition)))
        var copied = 0
        do {
            while copied < requested {
                if outputOffset == Int(outputBuffer.frameLength) { try refill() }
                let count = min(requested - copied, Int(outputBuffer.frameLength) - outputOffset)
                guard count > 0 else { throw AudioFailure("The converted source ended before its declared duration.") }
                let samples = outputBuffer.audioBufferList.pointee.mBuffers.mData!
                buffer.advanced(by: copied * frameBytes).copyMemory(
                    from: samples.advanced(by: outputOffset * frameBytes), byteCount: count * frameBytes)
                outputOffset += count; copied += count
            }
        } catch { failed = true; throw error }
        outputPosition += Int64(copied)
        return UInt32(copied)
    }

    private func refill() throws {
        guard !ended else { throw AudioFailure("The converted source ended early.") }
        outputBuffer.frameLength = 0; outputOffset = 0
        var conversionError: NSError?
        feed.position = inputPosition; feed.failure = nil
        let feed = feed
        let status = converter.convert(to: outputBuffer, error: &conversionError) { packets, status in
            feed.provide(packets, status: status)
        }
        inputPosition = feed.position
        if let failure = feed.failure { throw failure }
        if status == .error { throw conversionError ?? AudioFailure("Sample-rate conversion failed.") as NSError }
        if status == .endOfStream { ended = true }
        guard outputBuffer.frameLength > 0 else { throw AudioFailure("The converter produced no audio.") }
    }
}

/// The converter invokes this block synchronously during convert(). This private
/// box crosses only that API annotation, not a queue or task boundary. Both the
/// adapter and feed are confined to the same serial producer worker.
private final class ConverterFeed: @unchecked Sendable {
    let source: CrossfadeFloatSource
    let buffer: AVAudioPCMBuffer
    var position: Int64 = 0
    var failure: Error?
    init(source: CrossfadeFloatSource, buffer: AVAudioPCMBuffer) { self.source = source; self.buffer = buffer }
    func provide(_ packets: AVAudioPacketCount, status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        do {
            let count = min(Int64(min(packets, 4096)), source.decoder.frameCount - position)
            guard count > 0 else { status.pointee = .endOfStream; return nil }
            let samples = buffer.mutableAudioBufferList.pointee.mBuffers.mData!.assumingMemoryBound(to: Float.self)
            try source.read(into: samples, frames: Int(count))
            if source.channels == 1 && buffer.format.channelCount == 2 {
                // Expand backwards in the preallocated stereo buffer, preserving
                // unread mono samples. No allocation or gain change is required.
                for frame in stride(from: Int(count) - 1, through: 0, by: -1) {
                    let value = samples[frame]
                    samples[frame * 2] = value
                    samples[frame * 2 + 1] = value
                }
            }
            position += count
            buffer.frameLength = AVAudioFrameCount(count)
            status.pointee = .haveData
            return buffer
        } catch {
            failure = error; status.pointee = .endOfStream; return nil
        }
    }
}
