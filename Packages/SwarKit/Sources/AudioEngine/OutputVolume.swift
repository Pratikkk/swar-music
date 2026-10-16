import AudioToolbox
import CoreAudio
import Decoding
import Foundation

public struct OutputVolume: Sendable, Equatable {
    public let deviceID: UInt32
    public let deviceName: String
    public let level: Double?
    public let canSet: Bool
    public let isMuted: Bool

    public init(deviceID: UInt32 = 0, deviceName: String = "Audio Output", level: Double? = nil, canSet: Bool = false, isMuted: Bool = false) {
        self.deviceID = deviceID; self.deviceName = deviceName
        self.level = level; self.canSet = canSet; self.isMuted = isMuted
    }
}

public protocol OutputVolumeControlling: Sendable {
    func snapshot(deviceID: UInt32?) async -> OutputVolume
    func setLevel(_ level: Double, deviceID: UInt32) async throws -> OutputVolume
}

/// Controls HAL volume properties only. No PCM processing or audio session is opened.
public final class HardwareVolumeController: OutputVolumeControlling, @unchecked Sendable {
    private let queue = DispatchQueue(label: "catto.swar.volume", qos: .userInitiated)
    public init() {}

    public func snapshot(deviceID: UInt32?) async -> OutputVolume {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Self.read(deviceID: deviceID)) }
        }
    }

    public func setLevel(_ level: Double, deviceID: UInt32) async throws -> OutputVolume {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    guard level.isFinite, deviceID != 0, let address = Self.volumeAddress(deviceID), Self.settable(deviceID, address) else {
                        throw AudioFailure("This output does not expose an adjustable volume control.")
                    }
                    var scalar = Float32(max(0, min(level, 1)))
                    var property = address
                    try checkAudio(AudioObjectSetPropertyData(deviceID, &property, 0, nil, 4, &scalar), "Set output volume")
                    if scalar > 0 {
                        var mute = Self.address(kAudioDevicePropertyMute)
                        if Self.settable(deviceID, mute) {
                            var unmuted: UInt32 = 0
                            try checkAudio(AudioObjectSetPropertyData(deviceID, &mute, 0, nil, 4, &unmuted), "Unmute output")
                        }
                    }
                    return Self.read(deviceID: deviceID)
                })
            }
        }
    }

    private static func read(deviceID: UInt32?) -> OutputVolume {
        var id = deviceID ?? 0
        if deviceID == nil {
            var property = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size: UInt32 = 4
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &id) == noErr else { return OutputVolume() }
        }
        guard id != 0 else { return OutputVolume() }
        var nameProperty = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout.size(ofValue: name))
        _ = AudioObjectGetPropertyData(id, &nameProperty, 0, nil, &size, &name)
        let label = name?.takeRetainedValue() as String? ?? "Audio Output"
        var muteProperty = address(kAudioDevicePropertyMute)
        var muted: UInt32 = 0
        size = 4
        _ = AudioObjectGetPropertyData(id, &muteProperty, 0, nil, &size, &muted)
        guard var property = volumeAddress(id) else { return OutputVolume(deviceID: id, deviceName: label, isMuted: muted != 0) }
        var scalar = Float32(0)
        size = 4
        guard AudioObjectGetPropertyData(id, &property, 0, nil, &size, &scalar) == noErr, scalar.isFinite else {
            return OutputVolume(deviceID: id, deviceName: label, isMuted: muted != 0)
        }
        return OutputVolume(deviceID: id, deviceName: label, level: Double(max(0, min(scalar, 1))),
                            canSet: settable(id, property), isMuted: muted != 0)
    }

    private static func volumeAddress(_ id: UInt32) -> AudioObjectPropertyAddress? {
        // The virtual main property preserves channel balance on devices with per-channel controls.
        var readable: AudioObjectPropertyAddress?
        for selector in [kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyVolumeScalar] {
            var property = address(selector)
            if AudioObjectHasProperty(id, &property) {
                if settable(id, property) { return property }
                if readable == nil { readable = property }
            }
        }
        return readable
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private static func settable(_ id: UInt32, _ property: AudioObjectPropertyAddress) -> Bool {
        var property = property
        var result = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(id, &property, &result) == noErr && result.boolValue
    }
}
