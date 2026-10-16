import AudioEngine
import Foundation
import Player
import Testing

@MainActor
struct QueueTests {
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
    init(gate: OpenGate? = nil) { self.gate = gate }
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
        lock.withLock {
            value = PlaybackSnapshot(duration: 10, position: value.position, isPlaying: !value.isPlaying)
            return value
        }
    }
    func seek(to seconds: Double) async throws -> PlaybackSnapshot {
        lock.withLock {
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
    func release() { pending?.resume(); pending = nil }
}
