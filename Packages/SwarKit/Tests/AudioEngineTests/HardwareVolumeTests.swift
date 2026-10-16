import AudioEngine
import Foundation
import Testing

struct HardwareVolumeTests {
    // No audio is played. An opt-in write briefly lowers volume, then restores it.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWAR_TEST_VOLUME"] == "1"))
    func deviceVolumeReadWriteAndRestore() async throws {
        let controller = HardwareVolumeController()
        let initial = await controller.snapshot(deviceID: nil)
        let original = try #require(initial.level)
        try #require(initial.canSet)
        guard !initial.isMuted else { print("Volume read succeeded; write skipped to preserve system mute."); return }
        do {
            let target = max(0, original - 0.05)
            _ = try await controller.setLevel(target, deviceID: initial.deviceID)
            try await Task.sleep(for: .milliseconds(100))
            let lowered = await controller.snapshot(deviceID: initial.deviceID)
            #expect(abs((lowered.level ?? -1) - target) < 0.03)
            _ = try await controller.setLevel(original, deviceID: initial.deviceID)
            try await Task.sleep(for: .milliseconds(100))
            let restored = await controller.snapshot(deviceID: initial.deviceID)
            #expect(abs((restored.level ?? -1) - original) < 0.03)
            #expect(restored.deviceID == initial.deviceID)
            print("Volume read/write/restore verified on \(initial.deviceName).")
        } catch {
            _ = try? await controller.setLevel(original, deviceID: initial.deviceID)
            throw error
        }
    }
}
