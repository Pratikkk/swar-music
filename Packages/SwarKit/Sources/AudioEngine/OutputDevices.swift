import CoreAudio
import Decoding
import Foundation

public struct AudioOutputDevice: Sendable, Equatable, Identifiable {
    public let id: UInt32
    public let uid: String
    public let name: String
    public init(id: UInt32, uid: String, name: String) { self.id = id; self.uid = uid; self.name = name }
}

public struct AudioOutputs: Sendable, Equatable {
    public let devices: [AudioOutputDevice]
    public let defaultID: UInt32?
    public init(devices: [AudioOutputDevice] = [], defaultID: UInt32? = nil) {
        self.devices = devices; self.defaultID = defaultID
    }
    public func resolve(_ uid: String?) -> AudioOutputDevice? {
        if let uid, let device = devices.first(where: { $0.uid == uid }) { return device }
        return devices.first { $0.id == defaultID }
    }
}

public protocol AudioOutputsReading: Sendable { func snapshot() async throws -> AudioOutputs }

/// HAL enumeration stays off the main actor and the playback/render queues.
public struct SystemAudioOutputs: AudioOutputsReading {
    public init() {}
    public func snapshot() async throws -> AudioOutputs {
        try await Task.detached(priority: .utility) { try Self.read() }.value
    }
    private static func read() throws -> AudioOutputs {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        try checkAudio(AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size), "List audio outputs")
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.stride)
        guard !ids.isEmpty else { return AudioOutputs() }
        try checkAudio(ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!) }, "Read audio outputs")
        var devices: [AudioOutputDevice] = []
        for id in ids {
            var alive: UInt32 = 0, bytes: UInt32 = 4
            address.mScope = kAudioObjectPropertyScopeGlobal
            address.mSelector = kAudioDevicePropertyDeviceIsAlive
            guard AudioObjectGetPropertyData(id, &address, 0, nil, &bytes, &alive) == noErr, alive != 0 else { continue }
            address.mSelector = kAudioDevicePropertyStreams; address.mScope = kAudioDevicePropertyScopeOutput
            var streamBytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &streamBytes) == noErr, streamBytes > 0 else { continue }
            address.mScope = kAudioObjectPropertyScopeGlobal
            guard let uid = string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty else { continue }
            devices.append(AudioOutputDevice(id: id, uid: uid, name: string(id, kAudioObjectPropertyName) ?? "Audio Output"))
        }
        address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var defaultID: AudioDeviceID = 0; size = 4
        try checkAudio(AudioObjectGetPropertyData(system, &address, 0, nil, &size, &defaultID), "Read default output")
        return AudioOutputs(devices: devices.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, defaultID: defaultID == 0 ? nil : defaultID)
    }
    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?; var size = UInt32(MemoryLayout.size(ofValue: value))
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
