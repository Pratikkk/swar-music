import CoreAudio
import Decoding
import Foundation
import Testing
@testable import AudioEngine

/// Exercises real OutputDevice initialization with an injected Core Audio backend.
/// Player routing mocks cannot detect a device ID being discarded by OutputDevice.
private final class RoutingPropertyBackend: @unchecked Sendable, AudioObjectPropertyBackend {
    let defaultID: AudioDeviceID = 1
    private(set) var defaultLookups = 0
    private(set) var streamLookups: [AudioObjectID] = []

    func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        initial: T) throws -> T {
        if selector == kAudioHardwarePropertyDefaultOutputDevice {
            defaultLookups += 1
            return defaultID as! T
        }
        if selector == kAudioDevicePropertyNominalSampleRate {
            return 44_100.0 as! T
        }
        if selector == kAudioStreamPropertyPhysicalFormat {
            return AudioStreamBasicDescription() as! T
        }
        return initial
    }

    func setProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        value: T) throws {}

    func getPropertyArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope) throws -> [T] {
        if selector == kAudioDevicePropertyStreams {
            streamLookups.append(object)
            return (object == 1 || object == 2 ? [AudioStreamID(object + 100)] : []) as! [T]
        }
        return []
    }
}

struct OutputDeviceSelectionTests {
    @Test func selectedDeviceOverridesSystemDefault() throws {
        let backend = RoutingPropertyBackend()
        let device = try OutputDevice(id: 2, propertyBackend: backend)
        #expect(device.id == 2)
        #expect(device.stream == 102)
        #expect(backend.defaultLookups == 0)
        #expect(backend.streamLookups == [2])
    }

    @Test func absentSelectionUsesSystemDefault() throws {
        let backend = RoutingPropertyBackend()
        let device = try OutputDevice(propertyBackend: backend)
        #expect(device.id == 1)
        #expect(backend.defaultLookups == 1)
        #expect(backend.streamLookups == [1])
    }

    @Test func unavailableSelectedDeviceDoesNotSilentlyFallBack() throws {
        let backend = RoutingPropertyBackend()
        #expect(throws: AudioFailure.self) {
            try OutputDevice(id: 999, propertyBackend: backend)
        }
        #expect(backend.defaultLookups == 0)
        #expect(backend.streamLookups == [999])
    }
}
