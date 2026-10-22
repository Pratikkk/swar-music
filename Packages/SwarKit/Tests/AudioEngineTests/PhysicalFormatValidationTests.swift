import CoreAudio
import Decoding
import Foundation
import Testing
@testable import AudioEngine

/// Simulates HAL accepting, rejecting, or ignoring a physical-format request.
private final class FormatPropertyBackend: @unchecked Sendable, AudioObjectPropertyBackend {
    var expected: AudioStreamBasicDescription
    let rate: Double = 44_100
    var supported = true
    var acceptsSet = true
    var actual: AudioStreamBasicDescription

    init() {
        expected = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        actual = AudioStreamBasicDescription()
    }

    func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        initial: T) throws -> T {
        switch selector {
        case kAudioHardwarePropertyDefaultOutputDevice: return AudioDeviceID(1) as! T
        case kAudioDevicePropertyNominalSampleRate: return rate as! T
        case kAudioStreamPropertyPhysicalFormat: return actual as! T
        default: return initial
        }
    }

    func setProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        value: T) throws {
        if selector == kAudioStreamPropertyPhysicalFormat && acceptsSet {
            actual = value as! AudioStreamBasicDescription
        }
    }

    func getPropertyArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope) throws -> [T] {
        switch selector {
        case kAudioDevicePropertyStreams:
            return [AudioStreamID(101)] as! [T]
        case kAudioDevicePropertyAvailableNominalSampleRates:
            return [AudioValueRange(mMinimum: rate, mMaximum: rate)] as! [T]
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return (supported ? [AudioStreamRangedDescription(
                mFormat: expected,
                mSampleRateRange: AudioValueRange(mMinimum: rate, mMaximum: rate))] : []) as! [T]
        default: return []
        }
    }
}

struct PhysicalFormatValidationTests {
    private let source = SourceFormat(
        codec: "PCM", sampleRate: 44_100, bitDepth: 16,
        channels: 2, isLossless: true)

    private var pcm: AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
    }

    @Test func lossySourceCanUseDecodedFloat32Format() throws {
        let backend = FormatPropertyBackend()
        backend.expected = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let lossy = SourceFormat(codec: "MP3", sampleRate: 44_100,
                                 bitDepth: nil, channels: 2, isLossless: false)
        let device = try OutputDevice(id: 1, propertyBackend: backend)
        try device.configure(for: lossy, pcmFormat: backend.expected)
        #expect(backend.actual.mBitsPerChannel == 32)
        #expect(backend.actual.mFormatFlags & kAudioFormatFlagIsFloat != 0)
    }

    @Test func floatingPointDecoderCanUseIntegerDevice() throws {
        let backend = FormatPropertyBackend()
        let floatPCM = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        let lossy = SourceFormat(codec: "AAC", sampleRate: 44_100,
                                 bitDepth: nil, channels: 2, isLossless: false)
        let device = try OutputDevice(id: 1, propertyBackend: backend)
        try device.configure(for: lossy, pcmFormat: floatPCM)
        #expect(backend.actual.mBitsPerChannel == 16)
        #expect(backend.actual.mFormatFlags & kAudioFormatFlagIsFloat == 0)
    }

    @Test func integerDecoderCanUseWiderDevicePrecision() throws {
        let backend = FormatPropertyBackend()
        backend.expected.mBitsPerChannel = 24
        backend.expected.mBytesPerFrame = 8
        backend.expected.mBytesPerPacket = 8
        let device = try OutputDevice(id: 1, propertyBackend: backend)
        try device.configure(for: source, pcmFormat: pcm)
        #expect(backend.actual.mBitsPerChannel == 24)
        #expect(backend.actual.mSampleRate == source.sampleRate)
    }

    @Test func matchingFormatIsAcceptedAfterReadback() throws {
        let backend = FormatPropertyBackend()
        let device = try OutputDevice(id: 1, propertyBackend: backend)
        try device.configure(for: source, pcmFormat: pcm)
        #expect(backend.actual.mSampleRate == 44_100)
        #expect(backend.actual.mBitsPerChannel == 16)
        #expect(backend.actual.mBytesPerFrame == 4)
    }

    @Test func missingPhysicalFormatFailsInsteadOfContinuing() throws {
        let backend = FormatPropertyBackend()
        backend.supported = false
        let device = try OutputDevice(id: 1, propertyBackend: backend)
        #expect(throws: AudioFailure.self) {
            try device.configure(for: source, pcmFormat: pcm)
        }
    }

    @Test func ignoredPhysicalFormatRequestFailsInsteadOfContinuing() throws {
        let backend = FormatPropertyBackend()
        backend.acceptsSet = false
        let device = try OutputDevice(id: 1, propertyBackend: backend)
        #expect(throws: AudioFailure.self) {
            try device.configure(for: source, pcmFormat: pcm)
        }
    }
}
