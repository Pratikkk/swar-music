import AudioEngine
import CoreAudio
import Foundation
import Testing

struct HardwarePlaybackTests {
    // Opt in with a quiet ALAC fixture. This test changes the default output rate
    // and emits audio. It is deliberately excluded from ordinary test runs.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWAR_TEST_AUDIO_FILE"] != nil))
    func nativeRateSwitchPlayPauseSeekAndEnd() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["SWAR_TEST_AUDIO_FILE"])
        let alternate = try #require(ProcessInfo.processInfo.environment["SWAR_TEST_ALTERNATE_FILE"])
        let initialRate = try defaultOutputRate()
        let engine = AudioPlaybackEngine()
        defer { engine.shutdown() }
        let first = try await engine.open(URL(fileURLWithPath: alternate))
        #expect(first.source?.sampleRate == 44_100)
        #expect(first.source?.bitDepth == 16)
        #expect(first.output?.sampleRate == 44_100)
        let opened = try await engine.open(URL(fileURLWithPath: path))
        #expect(opened.source?.codec == "ALAC")
        #expect(opened.source?.sampleRate == 96_000)
        #expect(opened.source?.bitDepth == 24)
        #expect(opened.output?.sampleRate == 96_000)
        #expect(!opened.isPlaying)
        #expect(opened.position == 0)
        let playing = try await engine.togglePlayback()
        #expect(playing.isPlaying)
        try await Task.sleep(for: .milliseconds(400))
        let paused = try await engine.togglePlayback()
        #expect(!paused.isPlaying)
        #expect(paused.position > 0)
        try await Task.sleep(for: .milliseconds(150))
        let stillPaused = await engine.snapshot()
        #expect(stillPaused.position == paused.position)
        let sought = try await engine.seek(to: 1.25)
        #expect(abs(sought.position - 1.25) < 0.001)
        #expect(!sought.isPlaying)
        _ = try await engine.togglePlayback()
        try await Task.sleep(for: .milliseconds(200))
        let resumed = await engine.snapshot()
        #expect(resumed.position > sought.position)
        #expect(resumed.error == nil)
        #expect(resumed.underrunFrames == 0)
        _ = try await engine.seek(to: opened.duration - 0.1)
        try await Task.sleep(for: .milliseconds(300))
        let ended = await engine.snapshot()
        #expect(!ended.isPlaying)
        #expect(abs(ended.position - opened.duration) < 0.001)
        #expect(ended.error == nil)
        engine.shutdown()
        for _ in 0..<100 {
            if try defaultOutputRate() == initialRate { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(try defaultOutputRate() == initialRate)
        print("AUHAL verified: 44.1 → 96 kHz on \(opened.output?.name ?? "output"); restored \(initialRate) Hz. Physical output: \(opened.output?.text ?? "unknown").")
    }

    private func defaultOutputRate() throws -> Double {
        var device = AudioDeviceID(0)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 4
        try #require(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr)
        var rate: Double = 0
        size = 8
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        try #require(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr)
        return rate
    }
}
