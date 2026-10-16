import AudioEngine
import Foundation
@testable import Player
import Testing

@MainActor
struct SessionTests {
    private func workspace() throws -> (URL, URL, [QueueEntry]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let music = root.appendingPathComponent("Music", isDirectory: true)
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        let entries = try (0..<4).map { index in
            let file = music.appendingPathComponent("song-\(index).wav")
            try Data("fixture".utf8).write(to: file)
            return QueueEntry(url: file, accessRoot: music, title: "Song \(index)", subtitle: "Artist · Album",
                              artworkURL: root.appendingPathComponent("cover.png"))
        }
        return (root, root.appendingPathComponent("Session.json"), entries)
    }

    @Test func restoredQueueStaysPausedAndDoesNotOpenADeviceUntilResume() async throws {
        let (root, file, entries) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Player(engine: SessionEngine(), sessionStore: PlaybackSessionStore(url: file))
        await first.restoreSession()
        await first.play(entries, startingAt: 1)
        first.toggleShuffle(); first.setRepeatMode(.all)
        await first.seek(to: 6)
        await first.saveSessionIfNeeded()
        let ids = first.queue.map(\.id)
        first.shutdown()

        let engine = SessionEngine()
        let restored = Player(engine: engine, sessionStore: PlaybackSessionStore(url: file))
        await restored.restoreSession()
        #expect(restored.queue.map(\.id) == ids)
        #expect(restored.currentEntryID == entries[1].id)
        #expect(restored.title == "Song 1")
        #expect(restored.subtitle == "Artist · Album")
        #expect(restored.artworkURL == entries[1].artworkURL)
        #expect(restored.position == 6)
        #expect(restored.shuffleEnabled)
        #expect(restored.repeatMode == .all)
        #expect(restored.isRestoredSession)
        #expect(!restored.isPlaying)
        #expect(restored.formatInfo == nil)
        #expect(engine.opened.isEmpty)
        await restored.refresh()
        #expect(restored.position == 6)
        await restored.seek(to: 4)
        #expect(engine.opened.isEmpty)
        await restored.togglePlayback()
        #expect(!restored.isRestoredSession)
        #expect(restored.isPlaying)
        #expect(restored.position == 4)
        #expect(engine.opened.count == 1)
        #expect(engine.seeks == [4])
        // Original ordering survives restoring a shuffled session.
        restored.toggleShuffle()
        let played = Set(restored.queue.prefix(2).map(\.id))
        #expect(restored.upcomingEntries.map(\.id) == entries.filter { !played.contains($0.id) }.map(\.id))
    }

    @Test func quitFlushesTheLatestPositionWithoutWaitingForPeriodicSave() async throws {
        let (root, file, entries) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let player = Player(engine: SessionEngine(), sessionStore: PlaybackSessionStore(url: file))
        await player.restoreSession()
        await player.open(entries[0].url, accessRoot: entries[0].accessRoot, displayTitle: "Standalone")
        await player.seek(to: 7.25)
        player.setRepeatMode(.one)
        player.shutdown()
        player.shutdown() // Termination cleanup must be idempotent.
        let saved = try #require(try await PlaybackSessionStore(url: file).load())
        #expect(saved.position == 7.25)
        #expect(saved.entries.count == 1)
        #expect(saved.entries[0].title == "Standalone")
        #expect(saved.currentID == saved.entries[0].id)
        #expect(saved.repeatMode == .one)
    }

    @Test func corruptSessionIsPreservedUntilANewListeningSessionReplacesIt() async throws {
        let (root, file, entries) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = Data("not JSON".utf8)
        try invalid.write(to: file)
        let player = Player(engine: SessionEngine(), sessionStore: PlaybackSessionStore(url: file))
        await player.restoreSession()
        #expect(player.sessionNotice != nil)
        #expect(player.queue.isEmpty)
        await player.saveSessionIfNeeded()
        player.shutdown()
        #expect(try Data(contentsOf: file) == invalid)
        let next = Player(engine: SessionEngine(), sessionStore: PlaybackSessionStore(url: file))
        await next.restoreSession()
        await next.play(entries)
        await next.saveSessionIfNeeded()
        #expect(try await PlaybackSessionStore(url: file).load()?.entries.count == 4)
        #expect(next.sessionNotice == nil)
    }

    @Test func missingFilesStayInTheQueueAndFailedResumeKeepsAnError() async throws {
        let (root, file, entries) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaybackSessionStore(url: file)
        try await store.save(PlaybackSession(entries: entries, currentID: entries[0].id, position: 5, duration: 10,
                                            shuffle: false, repeatMode: .off, originalOrder: entries.map(\.id)))
        try FileManager.default.removeItem(at: entries[0].url)
        let engine = SessionEngine()
        let player = Player(engine: engine, sessionStore: store)
        await player.restoreSession()
        #expect(player.queue.count == 4)
        #expect(engine.opened.isEmpty)
        await player.togglePlayback()
        #expect(!player.isPlaying)
        #expect(player.errorMessage != nil)
        #expect(player.queue[0].error != nil)
        #expect(player.isRestoredSession)
        #expect(player.position == 5)
        // Reconnecting the file allows retrying from the original saved position.
        try Data("fixture".utf8).write(to: entries[0].url)
        await player.togglePlayback()
        #expect(player.isPlaying)
        #expect(player.position == 5)
        #expect(player.errorMessage == nil)
        await player.next()
        #expect(player.currentEntryID == entries[1].id)
        #expect(player.isPlaying)
    }

    @Test func unsupportedVersionsAndEscapingPathsAreRejected() async throws {
        let (root, file, entries) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaybackSessionStore(url: file)
        try await store.save(PlaybackSession(entries: entries, currentID: entries[0].id, position: 2, duration: 10,
                                            shuffle: false, repeatMode: .off, originalOrder: entries.map(\.id)))
        let original = try Data(contentsOf: file)
        var json = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
        json["version"] = 99
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        await #expect(throws: (any Error).self) { try await store.load() }
        json["version"] = 1
        var savedEntries = try #require(json["entries"] as? [[String: Any]])
        savedEntries[0]["relativePath"] = "../outside.wav"
        json["entries"] = savedEntries
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        await #expect(throws: (any Error).self) { try await store.load() }
    }

    @Test func restoredBookmarksFollowAMovedFolder() async throws {
        let (root, file, entries) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaybackSessionStore(url: file)
        try await store.save(PlaybackSession(entries: entries, currentID: entries[2].id, position: 3, duration: 10,
                                            shuffle: false, repeatMode: .off, originalOrder: entries.map(\.id)))
        let moved = root.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.moveItem(at: entries[0].accessRoot, to: moved)
        let loaded = try #require(try await PlaybackSessionStore(url: file).load())
        #expect(loaded.entries[2].id == entries[2].id)
        #expect(loaded.entries[2].url.standardizedFileURL == moved.appendingPathComponent("song-2.wav").standardizedFileURL)
        #expect(loaded.entries[2].error == nil)
    }

    @Test func pendingQueueCanBeStartedWithPlayAfterRestoration() async throws {
        let (root, file, entries) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = Player(engine: SessionEngine(), sessionStore: PlaybackSessionStore(url: file))
        await first.restoreSession()
        first.enqueue(entries[0]); first.enqueue(entries[1])
        first.shutdown()
        let engine = SessionEngine()
        let restored = Player(engine: engine, sessionStore: PlaybackSessionStore(url: file))
        await restored.restoreSession()
        #expect(restored.currentEntryID == nil)
        #expect(restored.canTogglePlayback)
        #expect(engine.opened.isEmpty)
        await restored.togglePlayback()
        #expect(restored.currentEntryID == entries[0].id)
        #expect(restored.isPlaying)
    }

    @Test func missingBookmarksKeepQueueEntriesAndShowReconnectMessage() async throws {
        let (root, file, entries) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaybackSessionStore(url: file)
        try await store.save(PlaybackSession(entries: entries, currentID: entries[0].id, position: 2, duration: 10,
                                            shuffle: false, repeatMode: .off, originalOrder: entries.map(\.id)))
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var roots = try #require(json["roots"] as? [String: [String: Any]])
        for key in roots.keys { roots[key]?.removeValue(forKey: "bookmark") }
        json["roots"] = roots
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let engine = SessionEngine()
        let restored = Player(engine: engine, sessionStore: PlaybackSessionStore(url: file))
        await restored.restoreSession()
        #expect(restored.queue.count == entries.count)
        #expect(restored.queue.allSatisfy { $0.error != nil })
        #expect(restored.errorMessage?.contains("access") == true)
        #expect(engine.opened.isEmpty)
        #expect(!restored.isPlaying)
    }

    @Test func startupRestoreDoesNotReplaceANewlySelectedQueue() async throws {
        let (root, file, entries) = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PlaybackSessionStore(url: file)
        try await store.save(PlaybackSession(entries: entries, currentID: entries[0].id, position: 3, duration: 10,
                                            shuffle: false, repeatMode: .off, originalOrder: entries.map(\.id)))
        let player = Player(engine: SessionEngine(), sessionStore: store)
        await player.play([entries[3]])
        await player.restoreSession()
        #expect(player.currentEntryID == entries[3].id)
        #expect(player.queue.count == 1)
        #expect(player.isPlaying)
    }
}

private final class SessionEngine: PlaybackDriving, @unchecked Sendable {
    private let lock = NSLock()
    private var value = PlaybackSnapshot()
    private var history: [URL] = []
    private var positions: [Double] = []
    private var failures: Set<String> = []
    var opened: [URL] { lock.withLock { history } }
    var seeks: [Double] { lock.withLock { positions } }
    func fail(_ url: URL) { lock.withLock { _ = failures.insert(url.standardizedFileURL.path) } }
    func open(_ url: URL) async throws -> PlaybackSnapshot {
        try lock.withLock {
            history.append(url)
            value = PlaybackSnapshot()
            if !FileManager.default.fileExists(atPath: url.path) || failures.contains(url.standardizedFileURL.path) { throw CocoaError(.fileReadNoSuchFile) }
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
            positions.append(seconds)
            value = PlaybackSnapshot(duration: 10, position: seconds, isPlaying: value.isPlaying)
            return value
        }
    }
    func snapshot() async -> PlaybackSnapshot { lock.withLock { value } }
    func shutdown() { lock.withLock { value = PlaybackSnapshot() } }
}
