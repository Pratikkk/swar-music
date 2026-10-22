import CoreAudio
import Decoding
import Foundation
import Testing
@testable import AudioEngine

/// Shared backend factory so multiple `OutputDevice` instances can model the same
/// physical device under Core Audio's toggle hog-mode semantics.
private func sharedHogBackend() -> HogModeTestBackend {
    HogModeTestBackend()
}

struct HogModeOwnershipTests {
    /// Creates an `OutputDevice` that shares `backend`, mimicking two Swar
    /// sessions targeting the same physical output.
    private func makeDevice(
        _ id: AudioDeviceID = 1,
        backend: HogModeTestBackend
    ) throws -> OutputDevice {
        try OutputDevice(id: id, propertyBackend: backend)
    }

    @Test func hoggingAnAlreadyHoggedDeviceIsANop() throws {
        let backend = sharedHogBackend()
        let device = try makeDevice(backend: backend)

        try device.setHogged(true)
        #expect(backend.hoggedByUs == true)

        // Calling setHogged(true) again must not toggle ownership off.
        try device.setHogged(true)
        #expect(backend.hoggedByUs == true)
    }

    @Test func releasingAnUnhoggedDeviceIsANop() throws {
        let backend = sharedHogBackend()
        let device = try makeDevice(backend: backend)

        // We never hogged; release must not acquire ownership (toggle semantics).
        try device.releaseHog()
        #expect(backend.hoggedByUs == false)
    }

    @Test func hogThenReleaseRestoresNonHoggedState() throws {
        let backend = sharedHogBackend()
        let device = try makeDevice(backend: backend)

        try device.setHogged(true)
        #expect(backend.hoggedByUs == true)

        try device.releaseHog()
        #expect(backend.hoggedByUs == false)

        // Releasing again must remain a no-op.
        try device.releaseHog()
        #expect(backend.hoggedByUs == false)
    }

    @Test func releaseDoesNotReleaseAnotherProcesssHog() throws {
        let backend = sharedHogBackend()
        let device = try makeDevice(backend: backend)

        // Another process (not Swar) hogs the device.
        backend.setHoggedByOther(true)

        // Our releaseHog must be a no-op; it must not release the other process's hog.
        try device.releaseHog()
        #expect(backend.hoggedByUs == false)
        #expect(backend.hoggedByOther == true)
    }

    @Test func hogFailsWhenAnotherProcessHogs() throws {
        let backend = sharedHogBackend()
        let device = try makeDevice(backend: backend)

        backend.setHoggedByOther(true)

        // Attempting to hog while another process owns it must fail and must not
        // toggle our ownership state.
        #expect(throws: AudioFailure.self) { try device.setHogged(true) }
        #expect(backend.hoggedByUs == false)
    }

    @Test func sharedSessionCloseNeverAcquiresHog() throws {
        // Two OutputDevice instances share one backend, modeling two Swar
        // sessions targeting the same physical device. One session hogs, then
        // closes without exclusive mode; the other session must not acquire hog
        // when it closes.
        let backend = sharedHogBackend()
        let hoggingDevice = try makeDevice(backend: backend)
        let sharedDevice = try makeDevice(backend: backend)

        try hoggingDevice.setHogged(true)
        #expect(backend.hoggedByUs == true)

        // Close the shared (non-exclusive) device. Under the buggy toggle-based
        // code this would acquire hog mode; under the fixed code it must not.
        try sharedDevice.releaseHog()
        #expect(backend.hoggedByUs == true)
    }

    @Test func exclusiveSessionAcquiresHogThenReleasesOnClose() throws {
        let backend = sharedHogBackend()
        let device = try makeDevice(backend: backend)

        // Simulate an exclusive output session opening and closing.
        try device.setHogged(true)
        #expect(backend.hoggedByUs == true)

        try device.releaseHog()
        #expect(backend.hoggedByUs == false)
    }

    @Test func ignoredAcquisitionDoesNotClaimOwnership() throws {
        let backend = sharedHogBackend()
        backend.ignoreAcquisition = true
        let device = try makeDevice(backend: backend)
        #expect(throws: AudioFailure.self) { try device.setHogged(true) }
        backend.ignoreAcquisition = false
        try device.releaseHog()
        #expect(!backend.hoggedByUs)
    }

    @Test func existingProcessOwnershipIsNotToggledOrReleasedByAnotherSession() throws {
        let backend = sharedHogBackend()
        let first = try makeDevice(backend: backend)
        let second = try makeDevice(backend: backend)
        try first.setHogged(true)
        try second.setHogged(true)
        try second.releaseHog()
        #expect(backend.hoggedByUs)
        try first.releaseHog()
        #expect(!backend.hoggedByUs)
    }

    @Test func repeatedCloseIsSafe() throws {
        let backend = sharedHogBackend()
        let device = try makeDevice(backend: backend)

        try device.setHogged(true)
        #expect(backend.hoggedByUs == true)

        try device.releaseHog()
        #expect(backend.hoggedByUs == false)

        // Repeated close must not toggle ownership back on.
        try device.releaseHog()
        #expect(backend.hoggedByUs == false)

        try device.releaseHog()
        #expect(backend.hoggedByUs == false)
    }

    @Test func failedInitializationDoesNotLeaveHogState() throws {
        // If hog acquisition fails partway through session setup, isHogged must
        // not be left in a state where close() would release another process's hog.
        let backend = sharedHogBackend()
        backend.setHoggedByOther(true)

        let device = try makeDevice(backend: backend)

        // Acquisition fails because another process owns the device; isHogged
        // must remain false.
        #expect(throws: AudioFailure.self) { try device.setHogged(true) }
        #expect(backend.hoggedByUs == false)

        // Close/release must be a no-op and must not release the other process's hog.
        try device.releaseHog()
        #expect(backend.hoggedByUs == false)
        #expect(backend.hoggedByOther == true)
    }
}

/// Test backend that models `kAudioDevicePropertyHogMode` toggle semantics.
final class HogModeTestBackend: @unchecked Sendable, AudioObjectPropertyBackend {
    /// Whether the device is currently hogged by this process (Swar).
    private(set) var hoggedByUs = false
    var ignoreAcquisition = false
    /// Whether another process has hogged the device.
    private(set) var hoggedByOther = false

    func getProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        initial: T) throws -> T {
        if selector == kAudioDevicePropertyHogMode {
            return (hoggedByOther ? pid_t(getpid() + 1) : hoggedByUs ? getpid() : pid_t(-1)) as! T
        }
        if selector == kAudioHardwarePropertyDefaultOutputDevice {
            return UInt32(1) as! T
        }
        return initial
    }

    func setProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                        value: T) throws {
        if selector == kAudioDevicePropertyHogMode {
            // Core Audio hog mode is a toggle: the value is ignored.
            // If another process owns it, we cannot hog.
            if hoggedByOther {
                return
            }
            if !hoggedByUs && ignoreAcquisition { return }
            hoggedByUs.toggle()
        }
    }

    func getPropertyArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope) throws -> [T] {
        if selector == kAudioDevicePropertyStreams {
            return [AudioStreamID(1)] as! [T]
        }
        return []
    }

    func setHoggedByOther(_ value: Bool) {
        hoggedByOther = value
    }

    func reset() {
        hoggedByUs = false
        hoggedByOther = false
    }
}
