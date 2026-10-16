import AudioEngine
import Foundation
import Observation
import os
import Player
import Testing

@MainActor
struct VolumeTests {
    @Test func unchangedHardwareVolumeDoesNotInvalidateViews() async {
        let player = Player(volumeController: TestVolumeController())
        await player.refreshVolume()
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking { _ = player.outputVolume } onChange: { changes.withLock { $0 += 1 } }
        await player.refreshVolume()
        await player.refreshVolume()
        #expect(changes.withLock { $0 } == 0)
    }

    @Test func volumeClampsRejectsInvalidValuesAndDoesNotOpenPlayback() async {
        let controller = TestVolumeController()
        let player = Player(volumeController: controller)
        await player.refreshVolume()
        #expect(player.outputVolume.level == 0.4)
        await player.setVolume(to: 4)
        await player.setVolume(to: .nan)
        await player.setVolume(to: -2)
        #expect(await controller.levels == [1, 0])
        #expect(player.outputVolume.level == 0)
        #expect(player.duration == 0)
        #expect(player.currentURL == nil)
        #expect(player.errorMessage == nil)
    }

    @Test func unavailableVolumeDoesNotWriteAndDeviceChangesClearOldErrors() async {
        let controller = TestVolumeController()
        let player = Player(volumeController: controller)
        await controller.change(OutputVolume(deviceID: 42))
        await player.refreshVolume()
        await player.setVolume(to: 0.5)
        #expect(await controller.levels.isEmpty)
        await controller.change(OutputVolume(deviceID: 42, level: 0.4, canSet: true))
        await controller.failWrites(true)
        await player.refreshVolume()
        await player.setVolume(to: 0.5)
        #expect(player.volumeError != nil)
        #expect(player.errorMessage == nil)
        await controller.failWrites(false)
        await controller.change(OutputVolume(deviceID: 99, level: 0.7, canSet: true))
        await player.refreshVolume()
        #expect(player.volumeError == nil)
        #expect(player.outputVolume.deviceID == 99)
        await player.setVolume(to: 0.2)
        #expect(await controller.devices.last == 99)
        #expect(player.outputVolume.level == 0.2)
    }

    @Test func rapidChangesCoalesceToTheLastRequestedLevel() async {
        let controller = TestVolumeController(gated: true)
        let player = Player(volumeController: controller)
        await player.refreshVolume()
        let first = Task { await player.setVolume(to: 0.2) }
        await controller.waitUntilWriting()
        await player.setVolume(to: 0.3)
        await player.setVolume(to: 0.8)
        await controller.release()
        await first.value
        #expect(await controller.levels == [0.2, 0.8])
        #expect(player.outputVolume.level == 0.8)
    }
}

private actor TestVolumeController: OutputVolumeControlling {
    private var state = OutputVolume(deviceID: 42, level: 0.4, canSet: true)
    private var failing = false
    private var gated: Bool
    private var blocked = false
    private var held: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var levels: [Double] = []
    private(set) var devices: [UInt32] = []
    init(gated: Bool = false) { self.gated = gated }
    func snapshot(deviceID: UInt32?) async -> OutputVolume { state }
    func change(_ value: OutputVolume) { state = value }
    func failWrites(_ value: Bool) { failing = value }
    func setLevel(_ level: Double, deviceID: UInt32) async throws -> OutputVolume {
        if failing { throw CocoaError(.fileWriteNoPermission) }
        levels.append(level); devices.append(deviceID)
        if gated {
            gated = false
            await withCheckedContinuation { continuation in
                held = continuation; blocked = true
                waiting?.resume(); waiting = nil
            }
        }
        state = OutputVolume(deviceID: deviceID, level: level, canSet: true)
        return state
    }
    func waitUntilWriting() async {
        if blocked { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { held?.resume(); held = nil }
}
