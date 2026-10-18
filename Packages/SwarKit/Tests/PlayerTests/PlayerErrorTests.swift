import Foundation
import AudioEngine
import Player
import Testing

@MainActor
struct PlayerErrorTests {
    @Test func openErrorSurvivesRoutinePolling() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        try Data("corrupt audio".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let player = Player()
        await player.open(file)
        let message = try #require(player.errorMessage)
        await player.refresh()
        #expect(player.errorMessage == message)
        #expect(!player.isPlaying)
        #expect(player.duration == 0)
        #expect(!player.isBusy)
    }

    @Test func filePickerErrorSurvivesRoutinePolling() async {
        let player = Player()
        player.reportImportError(CocoaError(.fileReadNoPermission))
        let message = player.errorMessage
        await player.refresh()
        #expect(message != nil)
        #expect(player.errorMessage == message)
    }

    @Test func snapshotErrorClearsOnRecoveryAndCanRecur() async {
        let engine = ErrorTestEngine()
        let player = Player(engine: engine)
        await player.open(URL(fileURLWithPath: "/tmp/error-test.wav"))
        for _ in 0..<2 {
            await engine.setError("Temporary playback failure")
            await player.refresh()
            #expect(player.errorMessage == "Temporary playback failure")
            await engine.setError(nil)
            await player.refresh()
            #expect(player.errorMessage == nil)
        }
        player.shutdown()
    }

    @Test(arguments: [false, true]) func failedControlClearsOnHealthyPolling(seek: Bool) async {
        let engine = ErrorTestEngine()
        let player = Player(engine: engine)
        await player.open(URL(fileURLWithPath: "/tmp/error-test.wav"))
        await engine.failNextControl()
        if seek { await player.seek(to: 2) }
        else { await player.togglePlayback() }
        #expect(player.errorMessage == "Temporary playback failure")
        await player.refresh()
        #expect(player.errorMessage == nil)
        #expect(!player.isBusy && !player.isSeeking)
        player.shutdown()
    }

    @Test func playbackStartFailureIsShownBeforeHealthyPollingClearsIt() async {
        let engine = ErrorTestEngine()
        let player = Player(engine: engine)
        await engine.failNextControl()
        await player.play([QueueEntry(url: URL(fileURLWithPath: "/tmp/error-test.wav"))])
        #expect(player.errorMessage == "Temporary playback failure")
        #expect(!player.isPlaying)
        await player.refresh()
        #expect(player.errorMessage == nil)
        player.shutdown()
    }

    @Test func importErrorWithIdenticalTextStillSurvivesHealthyPolling() async {
        let engine = ErrorTestEngine()
        let player = Player(engine: engine)
        await engine.setError("Temporary playback failure")
        await player.refresh()
        player.reportImportError(ErrorTestFailure())
        await engine.setError(nil)
        await player.refresh()
        #expect(player.errorMessage == "Temporary playback failure")
        await player.open(URL(fileURLWithPath: "/tmp/error-test.wav"))
        #expect(player.errorMessage == nil)
        player.shutdown()
    }

}


private struct ErrorTestFailure: LocalizedError {
    var errorDescription: String? { "Temporary playback failure" }
}

private actor ErrorTestEngine: PlaybackDriving {
    private var value = PlaybackSnapshot(duration: 10)
    private var failControl = false
    func setError(_ error: String?) {
        value = PlaybackSnapshot(duration: value.duration, position: value.position,
                                 isPlaying: value.isPlaying, error: error)
    }
    func failNextControl() { failControl = true }
    func open(_ url: URL) async throws -> PlaybackSnapshot {
        value = PlaybackSnapshot(duration: 10)
        return value
    }
    func togglePlayback() async throws -> PlaybackSnapshot {
        if failControl { failControl = false; throw ErrorTestFailure() }
        value = PlaybackSnapshot(duration: 10, position: value.position, isPlaying: !value.isPlaying)
        return value
    }
    func seek(to seconds: Double) async throws -> PlaybackSnapshot {
        if failControl { failControl = false; throw ErrorTestFailure() }
        value = PlaybackSnapshot(duration: 10, position: seconds, isPlaying: value.isPlaying)
        return value
    }
    func snapshot() async -> PlaybackSnapshot { value }
    nonisolated func shutdown() { }
}
