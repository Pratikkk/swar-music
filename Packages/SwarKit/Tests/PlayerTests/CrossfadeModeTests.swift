import Foundation
import AudioEngine
import Player
import Testing

@MainActor
struct CrossfadeModeTests {
    @Test func optInPersistsAndAppliesOnlyOnTheNextOpen() async {
        let suite = "CrossfadeModeTests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let engine = ModeEngine()
        let player = Player(engine: engine, outputPreferences: preferences)
        let song = QueueEntry(url: URL(fileURLWithPath: "/test/one.wav"), title: "One")
        #expect(!player.crossfadeEnabled)
        await player.play([song])
        #expect(await engine.modes == [false])
        player.crossfadeEnabled = true
        #expect(preferences.bool(forKey: "smartCrossfade"))
        #expect(await engine.modes == [false])
        await player.play([song])
        #expect(await engine.modes == [false, true])
        let restored = Player(engine: ModeEngine(), outputPreferences: preferences)
        #expect(restored.crossfadeEnabled)
        restored.shutdown()
        player.crossfadeEnabled = false
        await player.play([song])
        #expect(await engine.modes == [false, true, false])
        player.shutdown()
    }

    @Test func sameAlbumAndRepeatUseGaplessPreparationInProcessedMode() async {
        let suite = "CrossfadeModeTests." + UUID().uuidString
        let preferences = UserDefaults(suiteName: suite)!
        preferences.set(true, forKey: "smartCrossfade")
        defer { preferences.removePersistentDomain(forName: suite) }
        let engine = ModeEngine()
        let player = Player(engine: engine, outputPreferences: preferences)
        let songs = ["One", "Two"].map { QueueEntry(url: URL(fileURLWithPath: "/test/\($0).wav"), title: $0, album: "Continuous Album") }
        await player.play(songs)
        await engine.waitForPreparation(songs[1].id)
        #expect(await engine.prepared == songs[1].id)
        #expect(await engine.crossfadeCalls == 0)
        player.setRepeatMode(.one)
        await engine.waitForPreparation(songs[0].id)
        #expect(await engine.prepared == songs[0].id)
        #expect(await engine.crossfadeCalls == 0)
        player.shutdown()
    }
}

private actor ModeEngine: PlaybackDriving {
    var modes: [Bool] = []
    var prepared: UUID?
    var crossfadeCalls = 0
    var token = UUID()
    var playing = false
    var position = 0.0
    func open(_ url: URL) -> PlaybackSnapshot { token = UUID(); playing = false; position = 0; return value() }
    func open(_ url: URL, outputDeviceID: UInt32?, crossfade: Bool) -> PlaybackSnapshot {
        modes.append(crossfade); return open(url)
    }
    func togglePlayback() -> PlaybackSnapshot { playing.toggle(); return value() }
    func seek(to seconds: Double) -> PlaybackSnapshot { position = seconds; return value() }
    func snapshot() -> PlaybackSnapshot { value() }
    func prepareNext(_ next: PlaybackContinuation?, after token: UUID) { prepared = next?.id }
    func prepareCrossfade(_ next: PlaybackContinuation, currentRoot: URL, overlap: Double, after token: UUID) { crossfadeCalls += 1 }
    func waitForPreparation(_ id: UUID) async { for _ in 0..<1000 { if prepared == id { return }; try? await Task.sleep(for: .milliseconds(2)) } }
    private func value() -> PlaybackSnapshot { PlaybackSnapshot(duration: 60, position: position, isPlaying: playing, playbackToken: token) }
    nonisolated func shutdown() {}
}
