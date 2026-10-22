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

/// Injectable backend for Core Audio object property access.
///
/// Core Audio's `kAudioDevicePropertyHogMode` is a toggle property: the value
/// written is ignored, and writing toggles hog mode on or off. Tests use a mock
/// backend to model this behavior without touching real audio hardware.
protocol AudioObjectPropertyBackend: Sendable {
    func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        initial: T) throws -> T
    func setProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        value: T) throws
    func getPropertyArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope) throws -> [T]
}

/// Real backend that calls Core Audio directly.
struct SystemAudioObjectPropertyBackend: AudioObjectPropertyBackend {
    func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        initial: T) throws -> T {
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try checkAudio(withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }, "Read device property")
        return value
    }

    func setProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        value: T) throws {
        var value = value
        var address = AudioObjectPropertyAddress(mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try checkAudio(withUnsafePointer(to: &value) {
            AudioObjectSetPropertyData(object, &address, 0, nil,
                                       UInt32(MemoryLayout<T>.size), $0)
        }, "Set device property")
    }

    func getPropertyArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope) throws -> [T] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try checkAudio(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size),
            "Read device property size")
        guard size > 0 else { return [] }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { storage.deallocate() }
        try checkAudio(AudioObjectGetPropertyData(object, &address, 0, nil, &size, storage),
            "Read device formats")
        return Array(UnsafeBufferPointer(
            start: storage.assumingMemoryBound(to: T.self),
            count: Int(size) / MemoryLayout<T>.stride))
    }
}

/// Configuration/restoration run on the engine queue. Periodic read-only probes
/// use an independent monitor queue and capture only immutable device identifiers.
/// No device calls run on the render thread.
final class OutputDevice {
    let id: AudioDeviceID
    let stream: AudioStreamID
    let name: String
    private let originalRate: Double
    private let originalPhysical: AudioStreamBasicDescription
    private var requestedRate: Double?
    private var changedPhysical = false
    /// Whether this instance acquired process-wide ownership. Teardown also
    /// checks the current owner PID before writing the toggle property.
    private var isHogged = false
    private let propertyBackend: any AudioObjectPropertyBackend

    init(id selectedID: AudioDeviceID? = nil,
         propertyBackend: any AudioObjectPropertyBackend = SystemAudioObjectPropertyBackend()) throws {
        self.propertyBackend = propertyBackend
        // A pinned output must take precedence over the system default.
        // Only consult the default device when no explicit selection was made.
        if let selectedID {
            id = selectedID
        } else {
            id = try propertyBackend.getProperty(
                AudioObjectID(kAudioObjectSystemObject),
                kAudioHardwarePropertyDefaultOutputDevice,
                initial: AudioDeviceID(0))
        }
        guard id != kAudioObjectUnknown else {
            throw AudioFailure("No default audio output is available.")
        }
        let streams: [AudioStreamID] = try propertyBackend.getPropertyArray(
            id, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
        guard let first = streams.first else {
            throw AudioFailure("The output has no audio stream.")
        }
        stream = first
        originalRate = try propertyBackend.getProperty(
            id, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
        originalPhysical = try propertyBackend.getProperty(
            stream, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription())
        var label: Unmanaged<CFString>?
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout.size(ofValue: label))
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &label)
        name = label?.takeRetainedValue() as String? ?? "Audio Output"
    }

    /// Hog mode writes toggle process-wide ownership. Verify the actual PID
    /// instead of treating a successful write as proof of acquisition.
    func setHogged(_ exclusive: Bool) throws {
        guard exclusive else { try releaseHog(); return }
        let owner = try hogOwner()
        if owner == getpid() { return }
        guard owner == -1 else {
            throw AudioFailure("The output device is exclusively owned by another process.")
        }
        try propertyBackend.setProperty(id, kAudioDevicePropertyHogMode, value: pid_t(-1))
        guard try hogOwner() == getpid() else {
            throw AudioFailure("The output device did not grant exclusive access.")
        }
        isHogged = true
    }

    private func hogOwner() throws -> pid_t {
        try propertyBackend.getProperty(id, kAudioDevicePropertyHogMode, initial: pid_t(-1))
    }

    func releaseHog() throws {
        guard isHogged else { return }
        guard try hogOwner() == getpid() else { isHogged = false; return }
        try propertyBackend.setProperty(id, kAudioDevicePropertyHogMode, value: pid_t(-1))
        guard try hogOwner() != getpid() else {
            throw AudioFailure("The output device did not release exclusive access.")
        }
        isHogged = false
    }

    func configure(for source: SourceFormat, pcmFormat: AudioStreamBasicDescription) throws {
        guard source.channels <= 2 else {
            throw AudioFailure("This playback prototype supports mono and stereo. Multichannel "
                + "routing is not implemented yet.")
        }
        let ranges: [AudioValueRange] = try propertyBackend.getPropertyArray(
            id, kAudioDevicePropertyAvailableNominalSampleRates,
            scope: kAudioObjectPropertyScopeGlobal)
        guard ranges.contains(where: { $0.mMinimum <= source.sampleRate
            && source.sampleRate <= $0.mMaximum }) else {
            throw AudioFailure("\(name) does not support \(source.sampleRate / 1000) kHz. "
                + "Choose a compatible output in Swar.")
        }
        requestedRate = source.sampleRate
        if originalRate != source.sampleRate {
            try propertyBackend.setProperty(id, kAudioDevicePropertyNominalSampleRate,
                value: source.sampleRate)
            try waitForRate(source.sampleRate)
        }
        // Preserve the driver's physical layout (including 24-bit-in-32 containers).
        let formats: [AudioStreamRangedDescription] = try propertyBackend.getPropertyArray(
            stream, kAudioStreamPropertyAvailablePhysicalFormats,
            scope: kAudioObjectPropertyScopeOutput)
        // AUHAL can convert PCM representation at the source sample rate.
        // Prefer an exact representation, then lossless integer widening, then
        // another supported layout. The inspector reports the actual output.
        let compatible = formats.filter {
            $0.mFormat.mFormatID == kAudioFormatLinearPCM &&
            Int($0.mFormat.mChannelsPerFrame) >= source.channels &&
            $0.mSampleRateRange.mMinimum <= source.sampleRate &&
            source.sampleRate <= $0.mSampleRateRange.mMaximum
        }
        func rank(_ format: AudioStreamBasicDescription) -> Int {
            let sameRepresentation = (format.mFormatFlags & kAudioFormatFlagIsFloat) ==
                (pcmFormat.mFormatFlags & kAudioFormatFlagIsFloat)
            if sameRepresentation && format.mBitsPerChannel == pcmFormat.mBitsPerChannel { return 0 }
            if sameRepresentation && format.mBitsPerChannel > pcmFormat.mBitsPerChannel { return 1 }
            return 2
        }
        guard let match = compatible.min(by: { rank($0.mFormat) < rank($1.mFormat) }) else {
            throw AudioFailure("\(name) has no compatible physical PCM format for this source.")
        }

        var physical = match.mFormat
        physical.mSampleRate = source.sampleRate
        try propertyBackend.setProperty(stream, kAudioStreamPropertyPhysicalFormat,
            value: physical)
        changedPhysical = true

        // HAL format changes are asynchronous. Never silently continue if the
        // requested representation was not actually accepted by the driver.
        var confirmed = false
        for _ in 0..<100 {
            let actual = try propertyBackend.getProperty(
                stream, kAudioStreamPropertyPhysicalFormat,
                initial: AudioStreamBasicDescription())
            if actual.mFormatID == physical.mFormatID &&
               actual.mSampleRate == physical.mSampleRate &&
               actual.mBitsPerChannel == physical.mBitsPerChannel &&
               (actual.mFormatFlags & kAudioFormatFlagIsFloat) ==
                   (physical.mFormatFlags & kAudioFormatFlagIsFloat) &&
               actual.mChannelsPerFrame == physical.mChannelsPerFrame &&
               actual.mBytesPerFrame == physical.mBytesPerFrame &&
               actual.mBytesPerPacket == physical.mBytesPerPacket &&
               actual.mFramesPerPacket == physical.mFramesPerPacket &&
               actual.mFormatFlags == physical.mFormatFlags {
                confirmed = true
                break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard confirmed else {
            throw AudioFailure("\(name) did not accept the requested physical PCM format.")
        }
        try waitForRate(source.sampleRate)
        deviceLog.info("Configured \(self.name, privacy: .public) at \(source.sampleRate) Hz")
    }

    func validate(rate: Double) throws {
        do { try Self.validate(id: id, rate: rate) }
        catch { throw OutputRecoveryFailure(message: error.localizedDescription) }
    }

    private static func validate(id: AudioDeviceID, rate: Double) throws {
        // Static helper used by OutputSession; reads via the system backend.
        let backend = SystemAudioObjectPropertyBackend()
        let alive = try backend.getProperty(id, kAudioDevicePropertyDeviceIsAlive,
            initial: UInt32(0))
        guard alive != 0 else { throw AudioFailure("The output device disconnected.") }
        let actual = try backend.getProperty(id, kAudioDevicePropertyNominalSampleRate,
            initial: Double(0))
        guard actual == rate else {
            throw AudioFailure("The output sample rate changed. Reconnecting the audio output.")
        }
    }

    func description() throws -> OutputDescription {
        try Self.description(id: id, stream: stream, name: name)
    }

    func makeMonitor(rate: Double) -> OutputDeviceMonitor {
        let id = id, stream = stream, name = name
        return OutputDeviceMonitor(initial: try? description()) {
            try Self.validate(id: id, rate: rate)
            return try Self.description(id: id, stream: stream, name: name)
        }
    }

    private static func description(id: AudioDeviceID, stream: AudioStreamID,
                                    name: String) throws -> OutputDescription {
        let backend = SystemAudioObjectPropertyBackend()
        let physical = try backend.getProperty(
            stream, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription())
        let rawTransport = try? backend.getProperty(
            id, kAudioDevicePropertyTransportType, initial: UInt32(0))
        let transport: DeviceTransport
        switch rawTransport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            transport = .bluetooth
        case kAudioDeviceTransportTypeAirPlay:
            transport = .airPlay
        case kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB,
             kAudioDeviceTransportTypePCI, kAudioDeviceTransportTypeFireWire,
             kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeHDMI,
             kAudioDeviceTransportTypeDisplayPort:
            transport = .local
        default:
            transport = .unknown
        }
        return OutputDescription(id: id, name: name, sampleRate: physical.mSampleRate,
                                 bitDepth: physical.mBitsPerChannel,
                                 isFloat: physical.mFormatFlags & kAudioFormatFlagIsFloat != 0,
                                 channels: physical.mChannelsPerFrame, transport: transport)
    }

    func restore() {
        guard let requestedRate else { return }
        self.requestedRate = nil
        // Avoid overwriting a rate another app has chosen since playback stopped.
        guard let current = try? propertyBackend.getProperty(
            id, kAudioDevicePropertyNominalSampleRate, initial: Double(0)),
            current == requestedRate else { return }
        do {
            if changedPhysical {
                try propertyBackend.setProperty(stream, kAudioStreamPropertyPhysicalFormat,
                    value: originalPhysical)
                try waitForPhysical(originalPhysical)
            }
            let restoredRate = try propertyBackend.getProperty(
                id, kAudioDevicePropertyNominalSampleRate, initial: Double(0))
            if restoredRate != originalRate {
                try propertyBackend.setProperty(id, kAudioDevicePropertyNominalSampleRate,
                    value: originalRate)
            }
            // HAL writes complete asynchronously. A following session must not read
            // the old rate and then be interrupted by this pending restoration.
            try waitForRate(originalRate)
        } catch {
            deviceLog.error("Restore output format: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func waitForPhysical(_ format: AudioStreamBasicDescription) throws {
        for _ in 0..<100 {
            let actual = try propertyBackend.getProperty(
                stream, kAudioStreamPropertyPhysicalFormat, initial: AudioStreamBasicDescription())
            if actual.mSampleRate == format.mSampleRate,
               actual.mFormatID == format.mFormatID,
               actual.mFormatFlags == format.mFormatFlags,
               actual.mBitsPerChannel == format.mBitsPerChannel,
               actual.mChannelsPerFrame == format.mChannelsPerFrame,
               actual.mBytesPerFrame == format.mBytesPerFrame { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw AudioFailure("The output did not restore its physical format in time.")
    }

    private func waitForRate(_ rate: Double) throws {
        for _ in 0..<100 {
            if try propertyBackend.getProperty(
                id, kAudioDevicePropertyNominalSampleRate, initial: Double(0)) == rate { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw AudioFailure("The output did not switch to \(rate / 1000) kHz in time.")
    }
}
