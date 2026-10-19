import AudioEngine
import Foundation
import Player
import Testing

@MainActor
struct GaplessPlayerTests {
    @Test func audibleBoundaryChangesMetadataAndQueueWithoutReopeningOrStopping() async {
        let engine = ContinuationEngine()
        let actual = Player(engine: engine)
        let songs = entries()
        await actual.play(songs)
        await engine.waitFor(songs[1].id)
        #expect(actual.currentEntryID == songs[0].id && actual.title == "One")
        let revision = actual.sourceRevision
        await engine.cross(to: songs[1].id)
        await actual.refresh()
        #expect(actual.currentEntryID == songs[1].id && actual.title == "Two")
        #expect(actual.currentURL == songs[1].url && actual.isPlaying && actual.position == 0.25)
        #expect(actual.sourceRevision == revision + 1)
        #expect(await engine.openCount == 1)
        await engine.waitFor(songs[2].id)
        actual.shutdown()
    }

    @Test func removingAndClearingUpcomingUpdatesThePreparedSuccessor() async {
        let engine = ContinuationEngine(), songs = entries()
        let player = Player(engine: engine)
        await player.play(songs)
        await engine.waitFor(songs[1].id)
        player.removeUpcoming(songs[1].id)
        await engine.waitFor(songs[2].id)
        player.clearUpcoming()
        await engine.waitFor(nil)
        #expect(player.currentEntryID == songs[0].id && player.isPlaying)
        #expect(await engine.openCount == 1)
        player.shutdown()
    }

    @Test func repeatOneUsesNewPlaybackIdentityForTheSameQueueEntry() async {
        let engine = ContinuationEngine(), songs = entries()
        let player = Player(engine: engine)
        await player.play(songs)
        player.setRepeatMode(.one)
        await engine.waitFor(songs[0].id)
        let revision = player.sourceRevision
        await engine.cross(to: songs[0].id)
        await player.refresh()
        #expect(player.sourceRevision == revision + 1)
        #expect(player.currentEntryID == songs[0].id && player.isPlaying)
        #expect(await engine.openCount == 1)
        player.shutdown()
    }

    @Test func seekAndOutputChangesReprepareEvenWhenSuccessorDidNotChange() async {
        let engine = ContinuationEngine(), songs = entries()
        let reader = ContinuationOutputs()
        let player = Player(engine: engine, outputsReader: reader, outputPreferences: UserDefaults(suiteName: UUID().uuidString)!)
        await player.play(songs)
        await engine.waitFor(songs[1].id)
        let first = await engine.prepareCount
        await player.seek(to: 40)
        await engine.waitFor(songs[1].id, after: first)
        let second = await engine.prepareCount
        await player.selectOutput(uid: "test-output")
        await engine.waitFor(songs[1].id, after: second)
        #expect(player.position == 40)
        player.shutdown()
    }

    @Test func repeatAllWrapsAndBoundaryRaceKeepsAlreadyAudibleSongIdentifiable() async {
        let engine = ContinuationEngine(), songs = entries()
        let player = Player(engine: engine)
        await player.play(songs, startingAt: 2)
        player.setRepeatMode(.all)
        await engine.waitFor(songs[0].id)
        await engine.cross(to: songs[0].id)
        await player.refresh()
        #expect(player.currentEntryID == songs[0].id)
        await engine.waitFor(songs[1].id)
        await engine.cross(to: songs[1].id)
        player.removeUpcoming(songs[1].id) // Audio crossed before the UI's next poll.
        await player.refresh()
        #expect(player.currentEntryID == songs[1].id && player.title == "Two")
        #expect(player.queue.contains { $0.id == songs[1].id })
        player.shutdown()
    }

    private func entries() -> [QueueEntry] {
        ["One", "Two", "Three"].map { QueueEntry(url: URL(fileURLWithPath: "/test/\($0).wav"), title: $0) }
    }
}

private struct ContinuationOutputs: AudioOutputsReading {
    func snapshot() async throws -> AudioOutputs {
        AudioOutputs(devices: [AudioOutputDevice(id: 7, uid: "test-output", name: "Test Output")], defaultID: 7)
    }
}

private actor ContinuationEngine: PlaybackDriving {
    var token = UUID()
    var entryID: UUID?
    var playing = false
    var position: Double = 0
    private(set) var openCount = 0
    private(set) var prepareCount = 0
    private var lastID: UUID?
    private var waiting: [(UUID?, Int, CheckedContinuation<Void, Never>)] = []
    func open(_ url: URL) -> PlaybackSnapshot { openCount += 1; token = UUID(); entryID = nil; position = 0; playing = false; return value() }
    func togglePlayback() -> PlaybackSnapshot { playing.toggle(); return value() }
    func seek(to seconds: Double) -> PlaybackSnapshot { position = seconds; return value() }
    func snapshot() -> PlaybackSnapshot { value() }
    func selectOutput(_ deviceID: UInt32?, pause: Bool) -> PlaybackSnapshot { if pause { playing = false }; return value() }
    func cross(to id: UUID) { token = UUID(); entryID = id; position = 0.25 }
    func prepareNext(_ next: PlaybackContinuation?, after token: UUID) {
        guard token == self.token else { return }
        lastID = next?.id; prepareCount += 1
        let ready = waiting.filter { $0.0 == lastID && prepareCount > $0.1 }
        waiting.removeAll { $0.0 == lastID && prepareCount > $0.1 }
        ready.forEach { $0.2.resume() }
    }
    func waitFor(_ id: UUID?, after count: Int = 0) async {
        if prepareCount > count && lastID == id { return }
        await withCheckedContinuation { waiting.append((id, count, $0)) }
    }
    private func value() -> PlaybackSnapshot {
        PlaybackSnapshot(duration: 180, position: position, isPlaying: playing, playbackToken: token, continuationID: entryID)
    }
    nonisolated func shutdown() {}
}
