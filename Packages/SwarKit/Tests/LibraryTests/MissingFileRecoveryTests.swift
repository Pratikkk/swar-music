import Foundation
import Testing
import GRDB
@testable import Library

struct MissingFileRecoveryTests {
    private var package: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private var fixture: URL { package.appendingPathComponent("Tests/DecodingTests/Fixtures/44100-16.wav") }
    private var codecs: URL { package.appendingPathComponent("Vendor/FFmpeg/lib") }

    @Test func upgradingLegacyLibraryKeepsSongsAndHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = root.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture, to: music.appendingPathComponent("song.wav"))
        let path = root.appendingPathComponent("Library.sqlite").path
        let repository = try LibraryRepository(path: path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        _ = try await LibraryScanner(repository: repository, artworkDirectory: root.appendingPathComponent("Art"), codecDirectory: codecs).scan(folder: folder, root: music)
        let song = try #require(try await repository.page().tracks.first)
        let playlist = try await repository.createPlaylist(name: "Legacy")
        try await repository.addTracksToPlaylist(playlistID: playlist.id, trackIDs: [song.id])
        try await repository.setFavorite(trackID: song.id, favorite: true)
        try await repository.recordListen(trackID: song.id)
        let legacy = try DatabaseQueue(path: path)
        try await legacy.write { db in
            try db.execute(sql: "DROP INDEX tracks_location; ALTER TABLE tracks DROP COLUMN isMissing; DELETE FROM grdb_migrations WHERE identifier = 'library-missing-files-v10';")
        }
        let upgraded = try LibraryRepository(path: path)
        #expect(try await upgraded.page().tracks.first?.isMissing == false)
        #expect(try await upgraded.trackPreferences().favorites == [song.id])
        #expect(try await upgraded.playlistTrackItems(playlistID: playlist.id).first?.track.id == song.id)
        #expect(try await upgraded.listening(.recent).totalPlays == 1)
    }

    @MainActor @Test func missingSongAndIndexedReplacementMergeWithoutLosingReferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = root.appendingPathComponent("Music"), store = root.appendingPathComponent("Store")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = music.appendingPathComponent("original.wav"), destination = music.appendingPathComponent("renamed.wav")
        try FileManager.default.copyItem(at: fixture, to: source)
        let model = LibraryModel(storageDirectory: store, codecDirectory: codecs)
        await model.start(); await model.addFolder(music)
        defer { model.shutdown() }
        let original = try #require(model.tracks.first)
        let playlist = try #require(await model.createPlaylist(name: "Keep me"))
        await model.addTracks([original], to: playlist)
        await model.toggleFavorite(original)
        await model.recordListen(at: source)
        var edits = TrackMetadata(track: original); edits.title = "My title"
        try await model.updateMetadata(original, metadata: edits)
        let art = try await model.importArtwork(package.appendingPathComponent("Tests/LibraryTests/Fixtures/front.png"))
        _ = try await model.setArtwork(ids: [original.id], key: art)
        try FileManager.default.moveItem(at: source, to: destination)
        await model.rescan()
        let missing = try #require(model.tracks.first { $0.id == original.id })
        #expect(missing.isMissing && missing.title == "My title")
        let review = try await model.collectionPage(filter: .missing, search: "", scope: .all, limit: 200)
        #expect(review.count == 1 && review.summary.missing == 1 && review.summary.unreadable == 0)
        #expect(try await model.playlistItems(for: playlist.id).first?.track.id == original.id)
        let target = try #require(model.tracks.first { $0.relativePath == "renamed.wav" })
        await model.addTracks([target], to: playlist)
        await model.recordListen(at: destination)
        try await model.reconnectTrack(missing, to: destination)
        #expect(model.totalCount == 1)
        let repaired = try #require(model.tracks.first)
        #expect(repaired.id == original.id && !repaired.isMissing && repaired.error == nil)
        #expect(repaired.relativePath == "renamed.wav" && repaired.addedAt == original.addedAt)
        #expect(repaired.title == "My title" && repaired.artworkKey == art)
        #expect(model.trackID(at: destination) == original.id)
        #expect(await model.track(at: destination)?.id == original.id)
        #expect(model.favoriteTrackIDs.contains(original.id))
        #expect(try await model.playlistItems(for: playlist.id).map(\.track.id) == [original.id, original.id])
        #expect(try await model.listening(.recent).songs.first?.playCount == 2)
        // Rescanning a relocated song and reusing its old path must not steal its ID.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: destination.path)
        try FileManager.default.copyItem(at: fixture, to: source)
        await model.rescan()
        #expect(model.totalCount == 2)
        #expect(await model.track(at: destination)?.id == original.id)
        #expect(await model.track(at: source)?.id != original.id)
        model.shutdown()
        let restarted = LibraryModel(storageDirectory: store, codecDirectory: codecs)
        await restarted.start(); defer { restarted.shutdown() }
        #expect(await restarted.track(at: destination)?.id == original.id)
        #expect(try await restarted.playlistItems(for: playlist.id).map(\.track.id) == [original.id, original.id])
        #expect(try await restarted.listening(.recent).songs.first?.playCount == 2)
    }

    @Test func returningFileRecoversAndFailedEnumerationDoesNotMarkMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = root.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = music.appendingPathComponent("song.wav")
        try FileManager.default.copyItem(at: fixture, to: source)
        let repository = try LibraryRepository(path: root.appendingPathComponent("Library.sqlite").path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        let scanner = LibraryScanner(repository: repository, artworkDirectory: root.appendingPathComponent("Art"), codecDirectory: codecs)
        _ = try await scanner.scan(folder: folder, root: music)
        let original = try #require(try await repository.page().tracks.first)
        do {
            _ = try await scanner.scan(folder: folder, root: root.appendingPathComponent("offline"))
            Issue.record("An unavailable root must fail")
        } catch { }
        #expect(try await repository.page().tracks.first?.isMissing == false)
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("backup.wav"))
        _ = try await scanner.scan(folder: folder, root: music)
        #expect(try await repository.collectionPage(filter: .missing).count == 1)
        try FileManager.default.moveItem(at: root.appendingPathComponent("backup.wav"), to: source)
        _ = try await scanner.scan(folder: folder, root: music)
        let restored = try #require(try await repository.page().tracks.first)
        #expect(restored.id == original.id && !restored.isMissing && restored.error == nil)
        #expect(try await repository.collectionPage(filter: .missing).count == 0)
    }

    @MainActor @Test func reconnectingRootKeepsIdentityAndRejectsOverlap() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = root.appendingPathComponent("Music"), moved = root.appendingPathComponent("Elsewhere")
        let store = root.appendingPathComponent("Store")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixture, to: music.appendingPathComponent("song.wav"))
        let model = LibraryModel(storageDirectory: store, codecDirectory: codecs)
        await model.start(); await model.addFolder(music); defer { model.shutdown() }
        let track = try #require(model.tracks.first), folder = try #require(model.folders.first)
        let playlist = try #require(await model.createPlaylist(name: "Collection"))
        await model.addTracks([track], to: playlist); await model.toggleFavorite(track)
        await model.recordListen(at: music.appendingPathComponent("song.wav"))
        // Copy rather than rename so bookmark auto-resolution cannot mask the repair.
        try FileManager.default.copyItem(at: music, to: moved)
        try FileManager.default.removeItem(at: music)
        try await model.reconnectFolder(folder, to: moved)
        #expect(model.folders.first?.id == folder.id && model.folders.first?.path == moved.path)
        #expect(model.isMonitoring(try #require(model.folders.first)))
        #expect(model.tracks.first?.id == track.id && model.tracks.first?.isMissing == false)
        #expect(await model.track(at: moved.appendingPathComponent("song.wav"))?.id == track.id)
        #expect(model.favoriteTrackIDs.contains(track.id))
        #expect(try await model.playlistItems(for: playlist.id).first?.track.id == track.id)
        #expect(try await model.listening(.recent).totalPlays == 1)
        let other = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        do { try await model.reconnectFolder(folder, to: other); Issue.record("Unrelated empty roots must be rejected") } catch { }
        #expect(model.folders.first?.path == moved.path)
        await model.addFolder(other)
        do { try await model.reconnectFolder(folder, to: other); Issue.record("Overlapping roots must be rejected") } catch { }
        #expect(model.folders.first?.path == moved.path)
        #expect(!model.isRecovering)
    }

    @MainActor @Test func invalidReplacementLeavesMissingSongAndReferencesIntact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = root.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = music.appendingPathComponent("song.wav")
        try FileManager.default.copyItem(at: fixture, to: source)
        let model = LibraryModel(storageDirectory: root.appendingPathComponent("Store"), codecDirectory: codecs)
        await model.start(); await model.addFolder(music); defer { model.shutdown() }
        let track = try #require(model.tracks.first)
        let playlist = try #require(await model.createPlaylist(name: "Safe"))
        await model.addTracks([track], to: playlist)
        try FileManager.default.removeItem(at: source)
        await model.rescan()
        let invalid = music.appendingPathComponent("invalid.wav")
        try Data("not audio".utf8).write(to: invalid)
        do { try await model.reconnectTrack(track, to: invalid); Issue.record("Invalid audio must be rejected") } catch { }
        do { try await model.reconnectTrack(track, to: fixture); Issue.record("Unwatched locations need durable folder access") } catch { }
        #expect(model.tracks.first { $0.id == track.id }?.isMissing == true)
        #expect(try await model.playlistItems(for: playlist.id).first?.track.id == track.id)
        #expect(!model.isRecovering)
    }
}
