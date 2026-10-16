import CoreAudio
import Decoding
import Foundation
import os

private let deviceLog = Logger(subsystem: "catto.swar", category: "AudioDevice")

public enum DeviceTransport: Sendable, Equatable { case local, bluetooth, airPlay, unknown }

public struct OutputDescription: Sendable, Equatable {
    public let id: UInt32
    public let name: String
    public let sampleRate: Double
    public let bitDepth: UInt32
    public let isFloat: Bool
    public let channels: UInt32
    public let transport: DeviceTransport
    public var text: String {
        "\(name) · \(bitDepth)-bit \(isFloat ? "float" : "integer") / \(sampleRate / 1000) kHz"
    }
}

/// All device calls run on the engine's serial queue, never on the render thread.
final class OutputDevice {
    let id: AudioDeviceID
    let stream: AudioStreamID
    let name: String
    private let originalRate: Double
    private let originalPhysical: AudioStreamBasicDescription
    private var requestedRate: Double?
    private var changedPhysical = false

    init() throws {
        id = try Self.value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioDeviceID(0))
        guard id != kAudioObjectUnknown else { throw AudioFailure("No default audio output is available.") }
        let streams: [AudioStreamID] = try Self.array(id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        guard let first = streams.first else { throw AudioFailure("The output has no audio stream.") }
        stream = first
        originalRate = try Self.value(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
        originalPhysical = try Self.value(stream, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription())
        var label: Unmanaged<CFString>?
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout.size(ofValue: label))
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &label)
        name = label?.takeRetainedValue() as String? ?? "Audio Output"
    }

    func configure(for source: SourceFormat) throws {
        guard source.channels <= 2 else {
            throw AudioFailure("This playback prototype supports mono and stereo. Multichannel routing is not implemented yet.")
        }
        let ranges: [AudioValueRange] = try Self.array(id, kAudioDevicePropertyAvailableNominalSampleRates)
        guard ranges.contains(where: { $0.mMinimum <= source.sampleRate && source.sampleRate <= $0.mMaximum }) else {
            throw AudioFailure("\(name) does not support \(source.sampleRate / 1000) kHz. Choose a compatible output in macOS Sound settings and reopen the file.")
        }
        requestedRate = source.sampleRate
        if originalRate != source.sampleRate {
            try Self.set(id, kAudioDevicePropertyNominalSampleRate, value: source.sampleRate)
            try waitForRate(source.sampleRate)
        }
        // Preserve the driver's physical layout (including 24-bit-in-32 containers).
        let formats: [AudioStreamRangedDescription] = try Self.array(stream, kAudioStreamPropertyAvailablePhysicalFormats)
        if let match = formats.first(where: {
            $0.mFormat.mFormatID == kAudioFormatLinearPCM &&
            Int($0.mFormat.mBitsPerChannel) == source.bitDepth &&
            ($0.mFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0) == source.isFloat &&
            Int($0.mFormat.mChannelsPerFrame) >= source.channels &&
            $0.mSampleRateRange.mMinimum <= source.sampleRate && source.sampleRate <= $0.mSampleRateRange.mMaximum
        }) {
            var physical = match.mFormat
            physical.mSampleRate = source.sampleRate
            try Self.set(stream, kAudioStreamPropertyPhysicalFormat, value: physical)
            changedPhysical = true
            // Readback, rather than assuming the set request completed synchronously.
            for _ in 0..<100 {
                let current = try description()
                if current.sampleRate == source.sampleRate && current.bitDepth == physical.mBitsPerChannel && current.isFloat == source.isFloat { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        try waitForRate(source.sampleRate)
        deviceLog.info("Configured \(self.name, privacy: .public) at \(source.sampleRate) Hz")
    }

    func validate(rate: Double) throws {
        let alive = try Self.value(id, kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))
        guard alive != 0 else { throw AudioFailure("The output device disconnected. Reconnect it and reopen the file.") }
        let actual = try Self.value(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
        guard actual == rate else { throw AudioFailure("The output sample rate changed outside Swar. Reopen the file to configure playback again.") }
    }

    func description() throws -> OutputDescription {
        let physical = try Self.value(stream, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription())
        let rawTransport = try? Self.value(id, kAudioDevicePropertyTransportType, initial: UInt32(0))
        let transport: DeviceTransport
        switch rawTransport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: transport = .bluetooth
        case kAudioDeviceTransportTypeAirPlay: transport = .airPlay
        case kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypeThunderbolt,
             kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: transport = .local
        default: transport = .unknown
        }
        return OutputDescription(id: id, name: name, sampleRate: physical.mSampleRate, bitDepth: physical.mBitsPerChannel,
                                 isFloat: physical.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                                 channels: physical.mChannelsPerFrame, transport: transport)
    }

    func restore() {
        guard let requestedRate else { return }
        self.requestedRate = nil
        // Avoid overwriting a rate another app has chosen since playback stopped.
        guard let current = try? Self.value(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0)), current == requestedRate else { return }
        do {
            if changedPhysical {
                try Self.set(stream, kAudioStreamPropertyPhysicalFormat, value: originalPhysical)
                try waitForPhysical(originalPhysical)
            }
            let restoredRate = try Self.value(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
            if restoredRate != originalRate { try Self.set(id, kAudioDevicePropertyNominalSampleRate, value: originalRate) }
            // HAL writes complete asynchronously. A following session must not read
            // the old rate and then be interrupted by this pending restoration.
            try waitForRate(originalRate)
        } catch { deviceLog.error("Restore output format: \(error.localizedDescription, privacy: .public)") }
    }

    private func waitForPhysical(_ format: AudioStreamBasicDescription) throws {
        for _ in 0..<100 {
            let actual = try Self.value(stream, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription())
            if actual.mSampleRate == format.mSampleRate,
               actual.mFormatID == format.mFormatID, actual.mFormatFlags == format.mFormatFlags,
               actual.mBitsPerChannel == format.mBitsPerChannel,
               actual.mChannelsPerFrame == format.mChannelsPerFrame,
               actual.mBytesPerFrame == format.mBytesPerFrame { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw AudioFailure("The output did not restore its physical format in time.")
    }

    private func waitForRate(_ rate: Double) throws {
        for _ in 0..<100 {
            if try Self.value(id, kAudioDevicePropertyNominalSampleRate, initial: Double(0)) == rate { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw AudioFailure("The output did not switch to \(rate / 1000) kHz in time.")
    }

    private static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try checkAudio(withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }, "Read device property")
        return value
    }

    private static func set<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, value: T) throws {
        var value = value
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try checkAudio(withUnsafePointer(to: &value) { AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), $0) }, "Set device format")
    }

    private static func array<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) throws -> [T] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try checkAudio(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), "Read device property size")
        guard size > 0 else { return [] }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { storage.deallocate() }
        try checkAudio(AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage), "Read device formats")
        return Array(UnsafeBufferPointer(start: storage.assumingMemoryBound(to: T.self), count: Int(size) / MemoryLayout<T>.stride))
    }
}
