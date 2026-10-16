import AudioEngine
import CoreAudio
import Foundation
import Player
import Testing

@MainActor
struct HardwareSessionTests {
    // Separate opt-in: do not run concurrently with other hardware-owning tests.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWAR_TEST_SESSION_FILE"] != nil))
    func restoreDoesNotOpenAudioUntilResumeAndSeeksToTheSavedPosition() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SWAR_TEST_SESSION_FILE"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PlaybackSessionStore(url: directory.appendingPathComponent("Session.json"))
        let initialRate = try outputRate()
        let first = Player(sessionStore: store)
        await first.restoreSession()
        await first.play([QueueEntry(url: URL(fileURLWithPath: path), title: "Quiet Track")])
        try #require(first.errorMessage == nil)
        await first.seek(to: 2)
        await first.togglePlayback()
        await first.saveSessionIfNeeded()
        let savedPosition = first.position
        first.shutdown()
        #expect(try outputRate() == initialRate)

        let engine = AudioPlaybackEngine()
        let restored = Player(engine: engine, sessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("Session.json")))
        defer { restored.shutdown() }
        await restored.restoreSession()
        #expect(restored.isRestoredSession)
        #expect(!restored.isPlaying)
        #expect(restored.position == savedPosition)
        #expect(await engine.snapshot().source == nil)
        #expect(try outputRate() == initialRate)
        await restored.togglePlayback()
        try #require(restored.errorMessage == nil)
        #expect(restored.isPlaying)
        #expect(!restored.isRestoredSession)
        #expect(abs(restored.position - savedPosition) < 0.05)
        #expect(await engine.snapshot().source?.sampleRate == 96_000)
        #expect(await engine.snapshot().output?.sampleRate == 96_000)
        await restored.togglePlayback()
        restored.shutdown()
        #expect(try outputRate() == initialRate)
    }

    private func outputRate() throws -> Double {
        var device = AudioDeviceID(0)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 4
        try #require(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr)
        var rate = Double(0)
        size = 8
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        try #require(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr)
        return rate
    }
}
