import AudioToolbox
import FFmpegBridge
import Foundation

/// File probing chooses the codec; filename extensions are never used for routing.
public enum DecoderFactory {
    public static func open(url: URL, codecDirectory: URL? = nil) throws -> any AudioDecoding {
        guard url.isFileURL else { throw AudioFailure("Only local audio files are supported.") }
        do { return try NativeDecoder(url: url) }
        catch {
            let nativeFailure = error.localizedDescription
            do { return try FFmpegDecoder(url: url, codecDirectory: codecDirectory) }
            catch {
                throw AudioFailure("Could not decode this file. Native decoder: \(nativeFailure) Additional codecs: \(error.localizedDescription)")
            }
        }
    }
}

/// Background-queue decoder with a dynamically loaded, bundled LGPL backend.
public final class FFmpegDecoder: AudioDecoding {
    public let source: SourceFormat
    public let pcmFormat: AudioStreamBasicDescription
    public let frameCount: Int64
    private var decoder: OpaquePointer
    private let fileURL: URL
    private let libraryURL: URL

    public init(url: URL, codecDirectory: URL? = nil) throws {
        guard url.isFileURL else { throw AudioFailure("Only local audio files are supported.") }
        guard let directory = codecDirectory ?? Bundle.main.privateFrameworksURL else {
            throw AudioFailure("The bundled codec directory is unavailable.")
        }
        let library = directory.appendingPathComponent("libavformat.63.dylib")
        fileURL = url
        libraryURL = library
        var message = [CChar](repeating: 0, count: 512)
        guard let opened = swar_ff_open(url.path, library.path, &message, message.count) else {
            throw AudioFailure(Self.message(message))
        }
        let info = swar_ff_info(opened)
        let floating = info.is_float != 0
        let lossless = info.is_lossless != 0
        source = SourceFormat(codec: String(cString: swar_ff_codec(opened)), sampleRate: info.sample_rate,
                              bitDepth: lossless ? Int(info.source_bits) : nil, channels: Int(info.channels),
                              isLossless: lossless, isFloat: lossless && floating,
                              bitRate: info.bit_rate > 0 ? info.bit_rate : nil)
        let bytes = UInt32((info.pcm_bits + 7) / 8 * info.channels)
        pcmFormat = AudioStreamBasicDescription(
            mSampleRate: info.sample_rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: (floating ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | (info.pcm_bits % 8 == 0 ? kAudioFormatFlagIsPacked : 0),
            mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
            mChannelsPerFrame: UInt32(info.channels), mBitsPerChannel: UInt32(info.pcm_bits), mReserved: 0)
        frameCount = info.frame_count
        decoder = opened
    }

    deinit { swar_ff_close(decoder) }

    public func tag(_ aliases: String...) -> String? {
        for key in aliases {
            if let value = swar_ff_tag(decoder, key) {
                let text = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    public var embeddedArtwork: Data? {
        var size = 0
        guard let bytes = swar_ff_artwork(decoder, &size), size > 0 else { return nil }
        return Data(bytes: bytes, count: size)
    }

    public func read(into buffer: UnsafeMutableRawPointer, frames: UInt32) throws -> UInt32 {
        var message = [CChar](repeating: 0, count: 512)
        var count: UInt32 = 0
        guard swar_ff_read(decoder, buffer, frames, &count, &message, message.count) == 0 else {
            throw AudioFailure(Self.message(message))
        }
        return count
    }

    public func seek(to frame: Int64) throws {
        let target = max(0, min(frame, frameCount))
        // ASF timestamps are often coarser than sample positions and WMA needs
        // decoder preroll. Decode forward from a fresh stream for exact seeking.
        if source.codec == "WMA" || source.codec == "WMA Lossless" {
            try seekFromBeginning(to: target)
            return
        }
        var message = [CChar](repeating: 0, count: 512)
        if swar_ff_seek(decoder, target, &message, message.count) != 0 {
            try seekFromBeginning(to: target)
        }
    }

    private func seekFromBeginning(to target: Int64) throws {
        var message = [CChar](repeating: 0, count: 512)
        guard let fresh = swar_ff_open(fileURL.path, libraryURL.path, &message, message.count) else {
            throw AudioFailure(Self.message(message))
        }
        let info = swar_ff_info(fresh)
        guard info.sample_rate == source.sampleRate, Int(info.channels) == source.channels,
              UInt32(info.pcm_bits) == pcmFormat.mBitsPerChannel,
              (info.is_float != 0) == (pcmFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0),
              (info.is_lossless != 0) == source.isLossless,
              info.frame_count == frameCount,
              String(cString: swar_ff_codec(fresh)) == source.codec else {
            swar_ff_close(fresh)
            throw AudioFailure("The audio file changed while seeking. Reopen it to continue.")
        }
        swar_ff_close(decoder)
        decoder = fresh
        var remaining = target
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: 4096 * Int(pcmFormat.mBytesPerFrame), alignment: 16)
        defer { scratch.deallocate() }
        while remaining > 0 {
            let count = try read(into: scratch, frames: UInt32(min(remaining, 4096)))
            guard count > 0 else { throw AudioFailure("The seek target is beyond the decoded audio.") }
            remaining -= Int64(count)
        }
    }

    private static func message(_ bytes: [CChar]) -> String {
        let text = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return text.isEmpty ? "The codec backend reported an unknown error." : text
    }
}
