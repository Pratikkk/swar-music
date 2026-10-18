import AudioToolbox
import Foundation

public struct SourceFormat: Sendable, Equatable {
    public let codec: String
    public let sampleRate: Double
    public let bitDepth: Int?
    public let channels: Int
    public let isLossless: Bool
    public let isFloat: Bool
    public let bitRate: UInt32?

    public init(codec: String, sampleRate: Double, bitDepth: Int?, channels: Int,
                isLossless: Bool, isFloat: Bool = false, bitRate: UInt32? = nil) {
        self.codec = codec
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
        self.isLossless = isLossless
        self.isFloat = isFloat
        self.bitRate = bitRate
    }

    public var description: String {
        let depth = bitDepth.map { "\($0)-bit / " } ?? ""
        return "\(codec) · \(depth)\(sampleRate / 1000) kHz · \(channels) ch"
    }
}

public struct AudioFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public func checkAudio(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw AudioFailure("\(operation) failed (Core Audio \(status)).") }
}

/// Confined to the engine's serial worker queue, never the render thread.
public protocol AudioDecoding: AnyObject {
    var source: SourceFormat { get }
    var pcmFormat: AudioStreamBasicDescription { get }
    var frameCount: Int64 { get }
    func read(into buffer: UnsafeMutableRawPointer, frames: UInt32) throws -> UInt32
    func seek(to frame: Int64) throws
}

public final class NativeDecoder: AudioDecoding {
    public let source: SourceFormat
    public let pcmFormat: AudioStreamBasicDescription
    public let frameCount: Int64
    private let file: ExtAudioFileRef
    private var position: Int64 = 0

    public init(url: URL) throws {
        var opened: ExtAudioFileRef?
        try checkAudio(ExtAudioFileOpenURL(url as CFURL, &opened), "Open audio file")
        guard let opened else { throw AudioFailure("The decoder did not open the file.") }
        do {
            var original = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout.size(ofValue: original))
            try checkAudio(ExtAudioFileGetProperty(opened, kExtAudioFileProperty_FileDataFormat, &size, &original), "Read source format")
            guard original.mSampleRate.isFinite, original.mSampleRate > 0,
                  original.mSampleRate <= 384_000, (1...8).contains(original.mChannelsPerFrame) else {
                throw AudioFailure("This prototype supports up to 8 channels and 384 kHz PCM.")
            }
            let codec: String
            let lossless: Bool
            var bits = Int(original.mBitsPerChannel)
            switch original.mFormatID {
            case kAudioFormatAppleLossless:
                codec = "ALAC"; lossless = true
                switch original.mFormatFlags {
                case kAppleLosslessFormatFlag_16BitSourceData: bits = 16
                case kAppleLosslessFormatFlag_20BitSourceData: bits = 20
                case kAppleLosslessFormatFlag_24BitSourceData: bits = 24
                case kAppleLosslessFormatFlag_32BitSourceData: bits = 32
                default: break
                }
            case kAudioFormatFLAC:
                codec = "FLAC"; lossless = true
                // AudioToolbox can omit FLAC precision from its ASBD. STREAMINFO
                // describes actual audio samples (not user-editable tag metadata).
                if bits == 0 { bits = try Self.flacBitDepth(url: url) }
            case kAudioFormatLinearPCM: codec = "PCM"; lossless = true
            case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2:
                codec = "AAC"; lossless = false
            case kAudioFormatMPEGLayer3: codec = "MP3"; lossless = false
            default: throw AudioFailure("This codec is not supported by the native decoder yet.")
            }
            let floating = original.mFormatID == kAudioFormatLinearPCM && original.mFormatFlags & kAudioFormatFlagIsFloat != 0
            if lossless && ![8, 16, 20, 24, 32].contains(bits) {
                throw AudioFailure("The decoder could not establish a supported source bit depth.")
            }
            // Lossy sources have no integer PCM depth; integer lossless sources stay integer.
            // 20-bit samples use a low-aligned 24-bit container.
            let clientFloat = floating || !lossless
            let clientBits = clientFloat ? 32 : bits
            let bytes = UInt32((clientBits + 7) / 8) * original.mChannelsPerFrame
            var pcm = AudioStreamBasicDescription(
                mSampleRate: original.mSampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: (clientFloat ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) | (clientBits % 8 == 0 ? kAudioFormatFlagIsPacked : 0),
                mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
                mChannelsPerFrame: original.mChannelsPerFrame, mBitsPerChannel: UInt32(clientBits), mReserved: 0
            )
            try checkAudio(ExtAudioFileSetProperty(opened, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout.size(ofValue: pcm)), &pcm), "Set decoder PCM format")
            var length: Int64 = 0
            size = UInt32(MemoryLayout.size(ofValue: length))
            try checkAudio(ExtAudioFileGetProperty(opened, kExtAudioFileProperty_FileLengthFrames, &size, &length), "Read file duration")
            guard length > 0 else { throw AudioFailure("The audio file is empty.") }
            var audioFile: AudioFileID?
            size = UInt32(MemoryLayout.size(ofValue: audioFile))
            var bitRate: UInt32 = 0
            if ExtAudioFileGetProperty(opened, kExtAudioFileProperty_AudioFile, &size, &audioFile) == noErr, let audioFile {
                if original.mFormatID == kAudioFormatAppleLossless {
                    var table = AudioFilePacketTableInfo()
                    size = UInt32(MemoryLayout.size(ofValue: table))
                    if AudioFileGetProperty(audioFile, kAudioFilePropertyPacketTableInfo, &size, &table) == noErr,
                       table.mPrimingFrames > 0 {
                        // ALAC has no encoder delay. Transcodes sometimes retain AAC
                        // iTunSMPB tags; Core Audio trims real samples using that delay
                        // and then reports EOF before FileLengthFrames. Let the factory
                        // use the bundled decoder, which uses the ALAC stream timeline.
                        throw AudioFailure("This ALAC file needs the bundled decoder to ignore inconsistent encoder-delay metadata.")
                    }
                }
                size = UInt32(MemoryLayout.size(ofValue: bitRate))
                _ = AudioFileGetProperty(audioFile, kAudioFilePropertyBitRate, &size, &bitRate)
            }
            if original.mFormatID == kAudioFormatAppleLossless,
               try MP4Timeline.requiresBundledDecoder(url: url, frames: length, sampleRate: original.mSampleRate) {
                throw AudioFailure("This ALAC file needs the bundled decoder to preserve its MP4 timeline edits.")
            }
            source = SourceFormat(codec: codec, sampleRate: original.mSampleRate,
                                  bitDepth: lossless ? bits : nil, channels: Int(original.mChannelsPerFrame),
                                  isLossless: lossless, isFloat: floating, bitRate: bitRate > 0 ? bitRate : nil)
            pcmFormat = pcm
            frameCount = length
            file = opened
        } catch {
            ExtAudioFileDispose(opened)
            throw error
        }
    }

    deinit { ExtAudioFileDispose(file) }

    private static func flacBitDepth(url: URL) throws -> Int {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 42) ?? Data()
        let bytes = [UInt8](data)
        guard bytes.count == 42, Array(bytes.prefix(4)) == Array("fLaC".utf8),
              bytes[4] & 0x7f == 0, bytes[5] == 0, bytes[6] == 0, bytes[7] == 34 else {
            throw AudioFailure("FLAC STREAMINFO is missing or truncated.")
        }
        return Int((bytes[20] & 1) << 4 | bytes[21] >> 4) + 1
    }

    public func read(into buffer: UnsafeMutableRawPointer, frames: UInt32) throws -> UInt32 {
        guard frames > 0 else { return 0 }
        var count = frames
        var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
            mNumberChannels: pcmFormat.mChannelsPerFrame,
            mDataByteSize: frames * pcmFormat.mBytesPerFrame, mData: buffer))
        try checkAudio(ExtAudioFileRead(file, &count, &list), "Decode audio")
        if count == 0 && source.isLossless && position < frameCount {
            throw AudioFailure("The lossless file ended before its declared duration.")
        }
        position += Int64(count)
        return count
    }

    public func seek(to frame: Int64) throws {
        let target = max(0, min(frame, frameCount))
        try checkAudio(ExtAudioFileSeek(file, target), "Seek audio")
        position = target
    }
}
