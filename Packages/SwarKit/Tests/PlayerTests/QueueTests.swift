import AudioEngine
import AppKit
import Foundation
import Observation
import Library
import os
@testable import Player
import Testing

@MainActor
struct QueueTests {
    @Test func libraryArtworkUpdatesAllQueueCopiesWithoutRestartingPlayback() async throws {
        let engine = QueueTestEngine()
        let player = Player(engine: engine)
        let first = QueueEntry(url: entry("one").url, artworkURL: URL(fileURLWithPath: "/tmp/old.png"))
        let duplicate = QueueEntry(url: first.url, artworkURL: first.artworkURL)
        let other = entry("two")
        await player.play([first, duplicate, other])
        await player.seek(to: 4)
        let order = player.queue.map(\.id), current = player.currentEntryID
        let cover = URL(fileURLWithPath: "/tmp/new.png")
        player.updateLibraryArtwork([LibraryArtworkChange(fileURL: first.url, artworkURL: cover)])
        #expect(player.artworkURL == cover && player.queue[0].artworkURL == cover && player.queue[1].artworkURL == cover)
        #expect(player.queue[2] == other && player.queue.map(\.id) == order && player.currentEntryID == current)
        #expect(player.position == 4 && player.isPlaying && engine.opened.count == 1)
        player.updateLibraryArtwork([LibraryArtworkChange(fileURL: first.url, artworkURL: nil)])
        #expect(player.artworkURL == nil && player.queue[0].artworkURL == nil && player.queue[1].artworkURL == nil)
        #expect(player.position == 4 && player.isPlaying && engine.opened.count == 1)
        player.shutdown()
    }

    @Test func artworkChangedDuringTrackOpenIsNotReplacedByCapturedOldEntry() async {
        let gate = OpenGate()
        let engine = QueueTestEngine(gate: gate)
        let player = Player(engine: engine)
        let song = QueueEntry(url: entry("one").url, artworkURL: URL(fileURLWithPath: "/tmp/old.png"))
        let opening = Task { await player.play([song]) }
        await gate.waitUntilBlocked()
        player.updateLibraryArtwork([LibraryArtworkChange(fileURL: song.url, artworkURL: nil)])
        await gate.release()
        await opening.value
        #expect(player.artworkURL == nil && player.queue[0].artworkURL == nil && player.isPlaying)
        #expect(engine.opened.count == 1)
        player.shutdown()
    }

    @Test func sleepTimerPausesWithoutClearingQueueOrSeeking() async throws {
        let clock = TimerWaitGate()
        let timer = SleepTimer(wait: { _ in await clock.wait() })
        let engine = QueueTestEngine()
        let player = Player(engine: engine, sleepTimer: timer)
        await player.play([entry("one"), entry("two")])
        await player.seek(to: 4)
        let queue = player.queue
        timer.start(minutes: 15)
        await clock.waitUntilScheduled(1)
        #expect(timer.deadline != nil)
        await clock.release(0)
        try await waitForTimer { timer.deadline == nil }
        #expect(!player.isPlaying && player.position == 4)
        #expect(player.queue == queue && player.currentEntryID == queue.first?.id)
        #expect(engine.sought == [4])
        player.shutdown()
    }

    @Test func sleepTimerAtEndOfTrackDoesNotResumeOrRepeat() async throws {
        let clock = TimerWaitGate()
        let timer = SleepTimer(wait: { _ in await clock.wait() })
        let engine = QueueTestEngine()
        let player = Player(engine: engine, sleepTimer: timer)
        let entries = [entry("one"), entry("two")]
        await player.play(entries)
        player.setRepeatMode(.all)
        timer.start(minutes: 15)
        await clock.waitUntilScheduled(1)
        engine.finish() // The displayed snapshot still says Playing.
        await clock.release(0)
        try await waitForTimer { timer.deadline == nil }
        await player.refresh()
        #expect(!player.isPlaying && player.currentEntryID == entries[0].id)
        #expect(engine.opened.count == 1)
        #expect(player.queue == entries)
        player.shutdown()
    }

    @Test func cancelledAndReplacedSleepTimersCannotPausePlayback() async throws {
        let clock = TimerWaitGate()
        let timer = SleepTimer(wait: { _ in await clock.wait() })
        let player = Player(engine: QueueTestEngine(), sleepTimer: timer)
        await player.play([entry("one")])
        timer.start(minutes: 15)
        await clock.waitUntilScheduled(1)
        timer.start(minutes: 30)
        await clock.waitUntilScheduled(2)
        let replacement = timer.deadline
        await clock.release(0)
        for _ in 0..<10 { await Task.yield() }
        #expect(player.isPlaying && timer.deadline == replacement)
        timer.cancel()
        await clock.release(1)
        for _ in 0..<10 { await Task.yield() }
        #expect(player.isPlaying && timer.deadline == nil)
        player.shutdown()
    }

    @Test func sleepTimerWaitsForOpeningAndCanBeCancelledDuringThatWait() async throws {
        for cancel in [false, true] {
            let clock = TimerWaitGate()
            let openingGate = OpenGate()
            let timer = SleepTimer(wait: { _ in await clock.wait() })
            let player = Player(engine: QueueTestEngine(gate: openingGate), sleepTimer: timer)
            let opening = Task { await player.play([entry("one")]) }
            await openingGate.waitUntilBlocked()
            timer.start(minutes: 15)
            await clock.waitUntilScheduled(1)
            await clock.release(0)
            for _ in 0..<10 { await Task.yield() }
            if cancel { timer.cancel() }
            await openingGate.release()
            await opening.value
            if !cancel { try await waitForTimer { timer.deadline == nil } }
            else { try await Task.sleep(for: .milliseconds(40)) }
            #expect(player.isPlaying == cancel)
            #expect(timer.deadline == nil)
            player.shutdown()
        }
    }

    @Test func sleepTimerNeverResumesPausedPlaybackAndShutdownCancelsIt() async throws {
        let clock = TimerWaitGate()
        let timer = SleepTimer(wait: { _ in await clock.wait() })
        let player = Player(engine: QueueTestEngine(), sleepTimer: timer)
        await player.play([entry("one")])
        await player.togglePlayback()
        timer.start(minutes: 15)
        await clock.waitUntilScheduled(1)
        await clock.release(0)
        try await waitForTimer { timer.deadline == nil }
        #expect(!player.isPlaying)
        timer.start(minutes: 30)
        await clock.waitUntilScheduled(2)
        let deadline = timer.deadline
        for minutes in [0, -1, 721, Int.max] { timer.start(minutes: minutes) }
        #expect(timer.deadline == deadline)
        player.shutdown()
        await clock.release(1)
        for _ in 0..<10 { await Task.yield() }
        #expect(timer.deadline == nil && !player.isPlaying && player.currentURL == nil)
    }

    private func waitForTimer(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "Timer did not complete")
    }

    @Test func systemArtworkCanBeRequestedFromABackgroundQueue() async throws {
        let context = try #require(CGContext(data: nil, width: 16, height: 16,
            bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let decoded = MediaArtworkImage(try #require(context.makeImage()))
        let hasImage = await Task.detached {
            let artwork = MacNowPlayingOutput.makeArtwork(decoded)
            return artwork.image(at: NSSize(width: 16, height: 16)) != nil
        }.value
        #expect(hasImage)
    }

    @Test func mediaCommandsAreIdempotentAndRespectQueueAndSeekBounds() async {
        let player = Player(engine: QueueTestEngine())
        let output = TestNowPlayingOutput()
        let controls = SystemMediaControls(player: player, output: output)
        controls.start()
        controls.start()
        #expect(output.starts == 1)
        #expect(await controls.handle(.play) == false)
        #expect(await controls.handle(.pause) == false)
        let first = QueueEntry(url: entry("one").url, title: "One", artist: "Artist", album: "Album")
        let second = entry("two")
        await player.play([first, second])
        #expect(await controls.handle(.pause))
        #expect(await controls.handle(.pause))
        #expect(!player.isPlaying)
        #expect(output.last?.presentation.artist == "Artist")
        #expect(output.last?.presentation.album == "Album")
        #expect(await controls.handle(.play))
        #expect(await controls.handle(.play))
        #expect(player.isPlaying)
        #expect(await controls.handle(.next))
        #expect(player.currentURL == second.url)
        #expect(await controls.handle(.next) == false)
        #expect(await controls.handle(.seek(.nan)) == false)
        #expect(await controls.handle(.seek(99)))
        #expect(player.position == 10)
        #expect(await controls.handle(.previous))
        #expect(player.position == 0)
        #expect(await controls.handle(.previous))
        #expect(player.currentURL == first.url)
        #expect(await controls.handle(.toggle))
        #expect(!player.isPlaying)
        controls.stop()
        controls.stop()
        #expect(output.stops == 1)
        #expect(await controls.handle(.play) == false)
    }

    @Test func mediaCommandsRejectConflictingActionsAndStopPendingObservation() async {
        let gate = OpenGate()
        let player = Player(engine: QueueTestEngine(gate: gate))
        let output = TestNowPlayingOutput()
        let controls = SystemMediaControls(player: player, output: output)
        controls.start()
        let opening = Task { await player.play([entry("one"), entry("two")]) }
        await gate.waitUntilBlocked()
        #expect(await controls.handle(.toggle) == false)
        #expect(await controls.handle(.next) == false)
        #expect(await controls.handle(.seek(5)) == false)
        controls.stop()
        let count = output.updates
        await gate.release()
        await opening.value
        await Task.yield()
        #expect(output.updates == count)
        #expect(output.stops == 1)
    }

    @Test func mediaTimelineUsesSystemExtrapolationButPublishesSeeksAndPauses() async {
        let player = Player(engine: QueueTestEngine())
        await player.play([entry("one")])
        var timeline = MediaTimeline()
        let initial = timeline.needsUpdate(MediaState(player), at: 100, force: false)
        #expect(initial)
        await player.seek(to: 0.2)
        let regularTick = timeline.needsUpdate(MediaState(player), at: 100.2, force: false)
        #expect(!regularTick)
        await player.seek(to: 6)
        let seek = timeline.needsUpdate(MediaState(player), at: 100.3, force: false)
        #expect(seek)
        await player.togglePlayback()
        let pause = timeline.needsUpdate(MediaState(player), at: 100.3, force: false)
        #expect(pause)
        let idle = timeline.needsUpdate(MediaState(player), at: 200, force: false)
        #expect(!idle)
        await player.seek(to: 6.1)
        let pausedSeek = timeline.needsUpdate(MediaState(player), at: 200, force: false)
        #expect(pausedSeek)
        let artworkLoaded = timeline.needsUpdate(MediaState(player), at: 200, force: true)
        #expect(artworkLoaded)
    }

    @Test func queueMetadataDecodesOldSessionsAndRoundTripsNewFields() throws {
        let song = QueueEntry(url: entry("one").url, subtitle: "Artist · Album", artist: "Artist", album: "Album")
        let data = try JSONEncoder().encode(song)
        #expect(try JSONDecoder().decode(QueueEntry.self, from: data) == song)
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "artist")
        old.removeValue(forKey: "album")
        let restored = try JSONDecoder().decode(QueueEntry.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(restored.artist == nil && restored.album == nil)
        #expect(restored.subtitle == song.subtitle)
        #expect(restored.url == song.url)
    }

    @Test func unchangedPollingDoesNotInvalidatePlaybackViews() async {
        let player = Player(engine: QueueTestEngine())
        await player.play([entry("one")])
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking {
            _ = player.duration; _ = player.position; _ = player.isPlaying
            _ = player.formatInfo; _ = player.sourceDescription; _ = player.outputDescription
        } onChange: { changes.withLock { $0 += 1 } }
        await player.refresh()
        await player.refresh()
        #expect(changes.withLock { $0 } == 0)
    }

    private func entry(_ name: String) -> QueueEntry {
        QueueEntry(url: URL(fileURLWithPath: "/tmp/\(name).wav"), title: name)
    }

    @Test func albumStartsAtSelectionAndAdvancesExactlyOnceAtEOF() async {
        let engine = QueueTestEngine()
        let player = Player(engine: engine)
        let entries = [entry("one"), entry("two"), entry("three")]
        await player.play(entries, startingAt: 1)
        #expect(player.currentEntryID == entries[1].id)
        #expect(player.isPlaying)
        engine.finish()
        await player.refresh()
        #expect(player.currentEntryID == entries[2].id)
        #expect(player.isPlaying)
        await player.refresh()
        #expect(engine.opened.count == 2)
        engine.finish()
        await player.refresh()
        await player.refresh()
        #expect(!player.isPlaying)
        #expect(engine.opened.count == 2)
        #expect(!player.canGoNext)
    }

    @Test func explicitAlbumShufflePlaysEverySongOnceAndPlayResetsToDiscOrder() async {
        let engine = QueueTestEngine()
        let player = Player(engine: engine)
        let entries = (0..<12).map { entry("album-\($0)") }
        await player.play(entries, shuffle: true)
        #expect(player.shuffleEnabled)
        #expect(player.currentEntryID == player.queue.first?.id)
        #expect(Set(player.queue.map(\.id)) == Set(entries.map(\.id)))
        for _ in entries {
            engine.finish()
            await player.refresh()
        }
        #expect(!player.isPlaying)
        #expect(engine.opened.count == entries.count)
        #expect(Set(engine.opened) == Set(entries.map(\.url)))
        await player.play(entries, shuffle: false)
        #expect(!player.shuffleEnabled)
        #expect(player.currentEntryID == entries.first?.id)
        #expect(player.queue.map(\.id) == entries.map(\.id))
    }

    @Test func songChangePublishesPlayingStateAndPresentationTogether() async {
        let gate = OpenGate()
        let engine = QueueTestEngine(toggleGate: gate)
        let player = Player(engine: engine)
        let entries = [entry("one"), entry("two")]
        let initial = Task { await player.play(entries) }
        await gate.waitUntilBlocked()
        await gate.release()
        await initial.value
        await player.seek(to: 5)

        let changing = Task { await player.next() }
        await gate.waitUntilBlocked()
        #expect(player.isBusy)
        #expect(player.isPlaying)
        #expect(player.currentURL == entries[0].url)
        #expect(player.title == "one")
        #expect(player.position == 5)
        await gate.release()
        await changing.value
        #expect(player.currentURL == entries[1].url)
        #expect(player.title == "two")
        #expect(player.position == 0)
        #expect(player.isPlaying)
        #expect(!player.isBusy)
    }

    @Test func failedStartShowsOpenedSongAndDoesNotSkipToNextEntry() async {
        let engine = QueueTestEngine()
        let player = Player(engine: engine)
        let entries = [entry("one"), entry("two")]
        engine.failNextToggle()
        await player.play(entries)
        #expect(player.currentURL == entries[0].url)
        #expect(engine.opened == [entries[0].url])
        #expect(player.errorMessage != nil)
        #expect(player.queue[0].error != nil)
        #expect(!player.isPlaying && !player.isBusy)
        await player.togglePlayback()
        #expect(player.isPlaying)
        #expect(player.errorMessage == nil)
    }

    @Test func rapidSeeksKeepLatestPositionAndSkipIntermediateDecoderWork() async {
        let gate = OpenGate()
        let engine = QueueTestEngine(seekGate: gate)
        let player = Player(engine: engine)
        let entries = [entry("one"), entry("two")]
        await player.play(entries)
        let title = player.title
        let seeking = Task { await player.seek(to: 2) }
        await gate.waitUntilBlocked()
        #expect(player.isSeeking && player.isBusy)
        #expect(player.position == 2)
        await player.seek(to: 4)
        await player.seek(to: 8)
        #expect(player.position == 8)
        #expect(player.title == title)
        #expect(player.currentEntryID == entries[0].id)
        await gate.release()
        await seeking.value
        #expect(engine.sought == [2, 8])
        #expect(player.position == 8)
        #expect(player.isPlaying)
        #expect(!player.isBusy && !player.isSeeking)
    }

    @Test func failedSeekRestoresActualPositionAndAllowsRetry() async {
        let engine = QueueTestEngine()
        let player = Player(engine: engine)
        await player.play([entry("one")])
        engine.failNextSeek()
        await player.seek(to: 5)
        #expect(player.errorMessage != nil)
        #expect(player.position == 0)
        #expect(!player.isBusy && !player.isSeeking)
        await player.seek(to: 6)
        #expect(player.position == 6)
        #expect(player.errorMessage == nil)
    }

    @Test func shutdownDuringSeekDoesNotRestoreStalePlaybackState() async {
        let gate = OpenGate()
        let engine = QueueTestEngine(seekGate: gate)
        let player = Player(engine: engine)
        await player.play([entry("one")])
        let seeking = Task { await player.seek(to: 2) }
        await gate.waitUntilBlocked()
        await player.seek(to: 8)
        player.shutdown()
        await gate.release()
        await seeking.value
        #expect(engine.sought == [2])
        #expect(player.position == 0)
        #expect(!player.isPlaying && !player.isSeeking && !player.isBusy)
    }

    @Test func queueEditsAreBlockedDuringAnAsynchronousOpen() async {
        let gate = OpenGate()
        let engine = QueueTestEngine(gate: gate)
        let player = Player(engine: engine)
        let entries = [entry("one"), entry("two")]
        let opening = Task { await player.play(entries) }
        await gate.waitUntilBlocked()
        #expect(player.isBusy)
        player.enqueue(entry("extra"))
        player.toggleShuffle()
        player.setRepeatMode(.all)
        #expect(!player.shuffleEnabled)
        #expect(player.repeatMode == .off)
        player.clearUpcoming()
        player.removeUpcoming(entries[1].id)
        await player.next()
        #expect(player.queue.map(\.id) == entries.map(\.id))
        await gate.release()
        await opening.value
        #expect(!player.isBusy)
        #expect(player.isPlaying)
        #expect(engine.opened.count == 1)
    }

    @Test func shufflePreservesCurrentAndHistoryAndRestoresUpcomingOrder() async {
        let player = Player(engine: QueueTestEngine())
        let entries = (0..<12).map { entry("track-\($0)") }
        await player.play(entries, startingAt: 3)
        player.toggleShuffle()
        #expect(player.shuffleEnabled)
        #expect(Array(player.queue.prefix(4)).map(\.id) == Array(entries.prefix(4)).map(\.id))
        #expect(Set(player.upcomingEntries.map(\.id)) == Set(entries.dropFirst(4).map(\.id)))
        await player.next()
        let played = Set(player.queue.prefix(5).map(\.id))
        player.toggleShuffle()
        #expect(!player.shuffleEnabled)
        #expect(player.upcomingEntries.map(\.id) == entries.filter { !played.contains($0.id) }.map(\.id))
    }

    @Test func shuffleRestorationIncludesQueueEditsAndNewSelections() async {
        let player = Player(engine: QueueTestEngine())
        let entries = [entry("one"), entry("two"), entry("three"), entry("four")]
        player.toggleShuffle()
        await player.play(entries)
        let next = entry("next"), last = entry("last")
        player.enqueue(next, playNext: true)
        player.enqueue(last)
        player.removeUpcoming(entries[2].id)
        player.toggleShuffle()
        #expect(player.queue.map(\.id) == [entries[0].id, next.id, entries[1].id, entries[3].id, last.id])
    }

    @Test func repeatOneReplaysOnEOFButManualNextAdvances() async {
        let engine = QueueTestEngine()
        let player = Player(engine: engine)
        let entries = [entry("one"), entry("two")]
        player.setRepeatMode(.one)
        await player.play(entries)
        engine.finish()
        await player.refresh()
        #expect(player.currentEntryID == entries[0].id)
        #expect(player.isPlaying)
        #expect(engine.opened.count == 2)
        await player.next()
        #expect(player.currentEntryID == entries[1].id)
        #expect(!player.canGoNext)
    }

    @Test func repeatAllWrapsAtEOFAndManualNextAndOffStops() async {
        let engine = QueueTestEngine()
        let player = Player(engine: engine)
        let entries = [entry("one"), entry("two")]
        player.setRepeatMode(.all)
        await player.play(entries, startingAt: 1)
        #expect(player.canGoNext)
        engine.finish()
        await player.refresh()
        #expect(player.currentEntryID == entries[0].id)
        await player.next()
        await player.next()
        #expect(player.currentEntryID == entries[0].id)
        await player.next()
        player.setRepeatMode(.off)
        engine.finish()
        await player.refresh()
        #expect(player.currentEntryID == entries[1].id)
        #expect(!player.isPlaying)
    }

    @Test func repeatAllSkipsFailuresOncePerAdvanceAndStopsWhenAllFail() async {
        let engine = QueueTestEngine()
        let player = Player(engine: engine)
        let entries = [entry("one"), entry("two"), entry("three")]
        await player.play(entries, startingAt: 1)
        player.setRepeatMode(.all)
        engine.fail(entries[0].url); engine.fail(entries[2].url)
        await player.next()
        #expect(player.currentEntryID == entries[1].id)
        #expect(engine.opened.count == 4)
        engine.fail(entries[1].url)
        engine.finish()
        await player.refresh()
        await player.refresh()
        #expect(engine.opened.count == 7)
        #expect(!player.isPlaying)
        #expect(player.queue.allSatisfy { $0.error != nil })
    }

    @Test func repeatOneSupportsStandaloneFiles() async {
        let engine = QueueTestEngine()
        let player = Player(engine: engine)
        let file = entry("standalone")
        await player.open(file.url)
        player.setRepeatMode(.one)
        await player.togglePlayback()
        engine.finish()
        await player.refresh()
        #expect(player.isPlaying)
        #expect(player.queue.count == 1)
        #expect(engine.opened.count == 2)
    }

    @Test func artworkAndSubtitleFollowQueueTransitionsAndClearOnStandaloneOpen() async {
        let engine = QueueTestEngine()
        let player = Player(engine: engine)
        let cover = URL(fileURLWithPath: "/tmp/swar-cover.png")
        let first = QueueEntry(url: entry("one").url, title: "One", subtitle: "Artist · Album", artworkURL: cover)
        let second = entry("two")
        await player.play([first, second])
        #expect(player.artworkURL == cover)
        #expect(player.subtitle == "Artist · Album")
        #expect(player.currentURL == first.url)
        engine.finish()
        await player.refresh()
        #expect(player.artworkURL == nil)
        #expect(player.subtitle.isEmpty)
        #expect(player.currentURL == second.url)
        await player.play([first])
        await player.open(second.url)
        #expect(player.artworkURL == nil)
        #expect(player.subtitle.isEmpty)
        #expect(player.currentURL == second.url)
    }

    @Test func replayAndShuffleKeepDisplayedSongUntilOpenCompletes() async {
        let gate = OpenGate()
        let engine = QueueTestEngine(gate: gate)
        let player = Player(engine: engine)
        let song = QueueEntry(url: entry("one").url, title: "One", subtitle: "Artist",
                              artworkURL: URL(fileURLWithPath: "/tmp/cover.png"))
        let initial = Task { await player.play([song]) }
        await gate.waitUntilBlocked()
        await gate.release()
        await initial.value

        for shuffle in [false, true] {
            let replay = Task { await player.play([song], shuffle: shuffle) }
            await gate.waitUntilBlocked()
            #expect(player.isBusy)
            #expect(player.currentURL == song.url)
            #expect(player.title == "One")
            #expect(player.subtitle == "Artist")
            #expect(player.artworkURL == song.artworkURL)
            await gate.release()
            await replay.value
            #expect(player.currentURL == song.url)
            #expect(player.isPlaying)
            #expect(!player.isBusy)
        }
    }

    @Test func failedOpenDoesNotKeepThePreviousCover() async {
        let engine = QueueTestEngine()
        let player = Player(engine: engine)
        let first = QueueEntry(url: entry("one").url, artworkURL: URL(fileURLWithPath: "/tmp/cover.png"))
        let second = entry("bad")
        await player.play([first, second])
        engine.fail(second.url)
        await player.next()
        #expect(player.artworkURL == nil)
        #expect(player.currentURL == nil)
        #expect(player.subtitle.isEmpty)
        #expect(player.errorMessage != nil)
    }

    @Test func pauseAndSeekToEndDoNotAdvance() async {
        let engine = QueueTestEngine()
        let player = Player(engine: engine)
        let entries = [entry("one"), entry("two")]
        await player.play(entries)
        await player.togglePlayback()
        await player.seek(to: 10)
        await player.refresh()
        #expect(player.currentEntryID == entries[0].id)
        #expect(!player.isPlaying)
        #expect(engine.opened.count == 1)
    }

    @Test func playNextReorderAndRemovalPreserveCurrentTrackAndDuplicates() async {
        let player = Player(engine: QueueTestEngine())
        let entries = [entry("one"), entry("two"), entry("three")]
        await player.play(entries)
        let duplicate = entry("one")
        player.enqueue(duplicate, playNext: true)
        #expect(player.upcomingEntries.map(\.id) == [duplicate.id, entries[1].id, entries[2].id])
        player.moveUpcoming(from: IndexSet(integer: 2), to: 0)
        #expect(player.upcomingEntries.map(\.id) == [entries[2].id, duplicate.id, entries[1].id])
        player.moveUpcoming(from: IndexSet(integer: 0), to: 3)
        #expect(player.upcomingEntries.map(\.id) == [duplicate.id, entries[1].id, entries[2].id])
        player.removeUpcoming(entries[0].id)
        #expect(player.currentEntryID == entries[0].id)
        player.removeUpcoming(duplicate.id)
        #expect(player.queue.count == 3)
        player.clearUpcoming()
        #expect(player.queue.map(\.id) == [entries[0].id])
    }

    @Test func brokenEntriesStayVisibleAndAreSkippedWithoutLooping() async {
        let engine = QueueTestEngine()
        let entries = [entry("bad"), entry("good"), entry("also-bad")]
        engine.fail(entries[0].url); engine.fail(entries[2].url)
        let player = Player(engine: engine)
        await player.play(entries)
        #expect(player.currentEntryID == entries[1].id)
        #expect(player.queue[0].error != nil)
        #expect(player.errorMessage == nil)
        engine.finish()
        await player.refresh()
        await player.refresh()
        #expect(player.queue[2].error != nil)
        #expect(!player.isPlaying)
        #expect(!player.isBusy)
        #expect(engine.opened.count == 3)
    }

    @Test func previousRestartsAfterThreeSecondsOtherwiseReturnsToPreviousTrack() async {
        let engine = QueueTestEngine()
        let player = Player(engine: engine)
        let entries = [entry("one"), entry("two")]
        await player.play(entries, startingAt: 1)
        await player.seek(to: 5)
        await player.previous()
        #expect(player.position == 0)
        #expect(player.currentEntryID == entries[1].id)
        await player.previous()
        #expect(player.currentEntryID == entries[0].id)
    }

    @Test func replayingAfterEndRearmsAutomaticAdvance() async {
        let engine = QueueTestEngine()
        let player = Player(engine: engine)
        await player.play([entry("one")])
        engine.finish()
        await player.refresh()
        player.enqueue(entry("two"))
        await player.seek(to: 0)
        await player.togglePlayback()
        engine.finish()
        await player.refresh()
        #expect(player.title == "two")
        #expect(player.isPlaying)
    }

    @Test func standaloneOpenResetsQueueAndCanReceiveSuccessors() async {
        let player = Player(engine: QueueTestEngine())
        let one = entry("one"), two = entry("two")
        await player.play([one, two])
        await player.open(one.url)
        #expect(player.queue.isEmpty)
        #expect(!player.isPlaying)
        player.enqueue(two)
        #expect(player.queue.count == 2)
        #expect(player.upcomingEntries.map(\.id) == [two.id])
        await player.next()
        #expect(player.currentEntryID == two.id)
        #expect(player.isPlaying)
    }
}

/// State is protected by a lock; no real audio device is opened by these tests.
private final class QueueTestEngine: PlaybackDriving, @unchecked Sendable {
    private let lock = NSLock()
    private let gate: OpenGate?
    private let seekGate: OpenGate?
    private let toggleGate: OpenGate?
    private var toggleFailure = false
    func failNextToggle() { lock.withLock { toggleFailure = true } }
    private var seekHistory: [Double] = []
    private var seekFailure = false
    func failNextSeek() { lock.withLock { seekFailure = true } }
    var sought: [Double] { lock.withLock { seekHistory } }
    init(gate: OpenGate? = nil, seekGate: OpenGate? = nil, toggleGate: OpenGate? = nil) {
        self.gate = gate; self.seekGate = seekGate; self.toggleGate = toggleGate
    }
    private var value = PlaybackSnapshot()
    private var failures: Set<URL> = []
    private var history: [URL] = []
    var opened: [URL] { lock.withLock { history } }
    func fail(_ url: URL) { lock.withLock { _ = failures.insert(url) } }
    func finish() { lock.withLock { value = PlaybackSnapshot(duration: 10, position: 10, didFinish: true) } }
    func open(_ url: URL) async throws -> PlaybackSnapshot {
        if let gate { await gate.block() }
        return try lock.withLock {
            history.append(url)
            value = PlaybackSnapshot()
            if failures.contains(url) { throw CocoaError(.fileReadCorruptFile) }
            value = PlaybackSnapshot(duration: 10)
            return value
        }
    }
    func togglePlayback() async throws -> PlaybackSnapshot {
        if let toggleGate { await toggleGate.block() }
        return try lock.withLock {
            if toggleFailure { toggleFailure = false; throw CocoaError(.fileReadUnknown) }
            value = PlaybackSnapshot(duration: 10, position: value.position, isPlaying: !value.isPlaying)
            return value
        }
    }
    func seek(to seconds: Double) async throws -> PlaybackSnapshot {
        let first = lock.withLock { seekHistory.append(seconds); return seekHistory.count == 1 }
        if first, let seekGate { await seekGate.block() }
        return try lock.withLock {
            if seekFailure { seekFailure = false; throw CocoaError(.fileReadCorruptFile) }
            value = PlaybackSnapshot(duration: 10, position: seconds, isPlaying: value.isPlaying)
            return value
        }
    }
    func snapshot() async -> PlaybackSnapshot { lock.withLock { value } }
    func shutdown() { lock.withLock { value = PlaybackSnapshot() } }
}

private actor OpenGate {
    private var blocked = false
    private var entered: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    func block() async {
        await withCheckedContinuation { continuation in
            pending = continuation
            blocked = true
            entered?.resume(); entered = nil
        }
    }
    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release() { pending?.resume(); pending = nil; blocked = false }
}

@MainActor private final class TestNowPlayingOutput: NowPlayingOutput {
    var starts = 0
    var stops = 0
    var updates = 0
    var last: MediaState?
    func start(handler: @escaping @MainActor (MediaCommand) async -> Bool) { starts += 1 }
    func update(_ state: MediaState, forceTimeline: Bool) { updates += 1; last = state }
    func stop() { stops += 1 }
}

/// The wait deliberately ignores cancellation: stale wakeups must still be safe.
private actor TimerWaitGate {
    private var waits: [CheckedContinuation<Void, Never>?] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            waits.append(continuation)
            for (_, observer) in observers.filter({ $0.0 <= waits.count }) { observer.resume() }
            observers.removeAll { $0.0 <= waits.count }
        }
    }
    func waitUntilScheduled(_ count: Int) async {
        if waits.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func release(_ index: Int) { waits[index]?.resume(); waits[index] = nil }
}
