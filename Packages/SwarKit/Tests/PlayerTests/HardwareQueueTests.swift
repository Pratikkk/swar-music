import AudioEngine
import Foundation
import Player
import Testing

@MainActor
struct HardwareQueueTests {
    // Separate opt-in from HardwarePlaybackTests: never run competing device owners.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWAR_TEST_QUEUE_FILE"] != nil))
    func automaticAdvanceAcrossRatesSkipsCorruptEntryAndStopsAtEnd() async throws {
        let firstPath = try #require(ProcessInfo.processInfo.environment["SWAR_TEST_QUEUE_FILE"])
        let secondPath = try #require(ProcessInfo.processInfo.environment["SWAR_TEST_QUEUE_ALTERNATE_FILE"])
        let corrupt = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".flac")
        try Data("broken audio".utf8).write(to: corrupt)
        defer { try? FileManager.default.removeItem(at: corrupt) }
        let engine = AudioPlaybackEngine()
        let player = Player(engine: engine)
        defer { player.shutdown() }
        let entries = [QueueEntry(url: URL(fileURLWithPath: firstPath), title: "96 kHz"),
                       QueueEntry(url: corrupt, title: "Broken"),
                       QueueEntry(url: URL(fileURLWithPath: secondPath), title: "44.1 kHz")]
        await player.play(entries)
        try #require(player.errorMessage == nil)
        #expect(player.isPlaying)
        #expect(await engine.snapshot().source?.sampleRate == 96_000)
        #expect(await engine.snapshot().output?.sampleRate == 96_000)
        await player.seek(to: max(0, player.duration - 0.15))
        let deadline = Date().addingTimeInterval(15)
        while player.currentEntryID != entries[2].id, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            await player.refresh()
        }
        try #require(player.currentEntryID == entries[2].id)
        #expect(player.isPlaying)
        #expect(player.errorMessage == nil)
        #expect(player.queue[1].error != nil)
        #expect(await engine.snapshot().source?.sampleRate == 44_100)
        #expect(await engine.snapshot().output?.sampleRate == 44_100)
        await player.seek(to: max(0, player.duration - 0.15))
        while player.isPlaying, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
            await player.refresh()
        }
        #expect(!player.isPlaying)
        #expect(!player.canGoNext)
        #expect(player.underrunFrames == 0)
        #expect(player.errorMessage == nil)

        // Replay One must restart the final track; Repeat All must then wrap.
        player.setRepeatMode(.one)
        await player.togglePlayback()
        await player.seek(to: max(0, player.duration - 0.15))
        let repeatDeadline = Date().addingTimeInterval(5)
        while player.position > 1, Date() < repeatDeadline {
            try await Task.sleep(for: .milliseconds(50))
            await player.refresh()
        }
        #expect(player.currentEntryID == entries[2].id)
        #expect(player.position < 1)
        #expect(player.isPlaying)
        player.setRepeatMode(.all)
        await player.seek(to: max(0, player.duration - 0.15))
        let wrapDeadline = Date().addingTimeInterval(5)
        while player.currentEntryID != entries[0].id, Date() < wrapDeadline {
            try await Task.sleep(for: .milliseconds(50))
            await player.refresh()
        }
        #expect(player.currentEntryID == entries[0].id)
        #expect(player.isPlaying)
        #expect(await engine.snapshot().output?.sampleRate == 96_000)
        #expect(player.errorMessage == nil)
    }
}
