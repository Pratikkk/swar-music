import Foundation
import Testing
@testable import Library

struct LibraryTests {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("DecodingTests/Fixtures")
    }
    private var codecs: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Vendor/FFmpeg/lib")
    }

    private func workspace() throws -> (URL, URL, URL) {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = temporary.appendingPathComponent("Music/Album")
        let artwork = temporary.appendingPathComponent("Artwork")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        return (temporary, music, artwork)
    }

    @Test func standalonePresentationReadsTagsAndCachesCoverWithoutImporting() throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let tagged = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        let source = music.appendingPathComponent("song.mp3")
        try FileManager.default.copyItem(at: tagged.appendingPathComponent("44100-16.mp3"), to: source)
        let presentation = try #require(TrackPresentation.read(url: source, artworkDirectory: artwork, codecDirectory: codecs))
        #expect(presentation.title == "Morning Light")
        #expect(presentation.subtitle == "Björk · Test Album")
        let cover = try #require(presentation.artworkURL)
        #expect(FileManager.default.fileExists(atPath: cover.path))
        #expect(TrackPresentation.read(url: source, artworkDirectory: artwork, codecDirectory: codecs)?.artworkURL == cover)
        #expect(TrackPresentation.read(url: music.appendingPathComponent("missing.wav"), artworkDirectory: artwork, codecDirectory: codecs) == nil)
    }

    @Test func scanPersistsSearchesSkipsUnchangedAndReconcilesDeletedFiles() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = music.appendingPathComponent("A Special Track.flac")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("96000-24.flac"), to: source)
        let path = temporary.appendingPathComponent("library.sqlite").path
        let repository = try LibraryRepository(path: path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        let scanner = LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs)
        let initial = try await scanner.scan(folder: folder, root: music)
        #expect(initial.total == 1)
        #expect(initial.changed == 1)
        #expect(initial.failed == 0)
        let first = try await repository.page()
        let track = try #require(first.tracks.first)
        #expect(track.title == "A Special Track")
        #expect(track.album == "Album")
        #expect(track.codec == "FLAC")
        #expect(track.bitDepth == 24)
        #expect(track.sampleRate == 96_000)
        let unchanged = try await scanner.scan(folder: folder, root: music)
        #expect(unchanged.changed == 0)
        let reopened = try LibraryRepository(path: path)
        #expect(try await reopened.page(search: "Special").count == 1)
        #expect(try await reopened.page(search: "Special OR invalid").count == 0)
        #expect(try await reopened.page(search: "\"; DROP TABLE tracks;").count == 0)
        let updated = Date().addingTimeInterval(20)
        try FileManager.default.setAttributes([.modificationDate: updated], ofItemAtPath: source.path)
        #expect(try await scanner.scan(folder: folder, root: music).changed == 1)
        #expect(try await repository.page().tracks.first?.id == track.id)
        #expect(try await repository.page().tracks.first?.addedAt == track.addedAt)
        try FileManager.default.removeItem(at: source)
        #expect(try await scanner.scan(folder: folder, root: music).total == 0)
        #expect(try await repository.page(search: "Special").count == 0)
    }

    @Test func failedFilesStayVisibleAndFolderRemovalLeavesSourceUntouched() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = music.appendingPathComponent("broken.opus")
        try Data("broken audio".utf8).write(to: source)
        let repository = try LibraryRepository(path: temporary.appendingPathComponent("library.sqlite").path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        let scanner = LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs)
        #expect(try await scanner.scan(folder: folder, root: music).failed == 1)
        let track = try #require(try await repository.page().tracks.first)
        #expect(track.error != nil)
        #expect(track.sourceFormat == nil)
        try await repository.removeFolder(folder.id)
        #expect(try await repository.page().count == 0)
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func inaccessibleRootPreservesStoredTracksAndSymlinksAreNotFollowed() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("real.wav"))
        try FileManager.default.createSymbolicLink(at: music.appendingPathComponent("alias.wav"), withDestinationURL: fixtures.appendingPathComponent("44100-16.wav"))
        let repository = try LibraryRepository(path: temporary.appendingPathComponent("library.sqlite").path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        let scanner = LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs)
        #expect(try await scanner.scan(folder: folder, root: music).total == 1)
        try FileManager.default.moveItem(at: music, to: temporary.appendingPathComponent("Moved"))
        await #expect(throws: (any Error).self) { try await scanner.scan(folder: folder, root: music) }
        #expect(try await repository.page().count == 1)
    }
}

extension LibraryTests {
    @Test func metadataAcrossContainersAndArtworkCaching() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let tagged = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
        for name in ["96000-24.flac", "96000-24.m4a", "44100-16.mp3", "44100-16.opus", "96000-24.wv", "front.png"] {
            try FileManager.default.copyItem(at: tagged.appendingPathComponent(name), to: music.appendingPathComponent(name))
        }
        let repository = try LibraryRepository(path: temporary.appendingPathComponent("library.sqlite").path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        let scanner = LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs)
        let summary = try await scanner.scan(folder: folder, root: music)
        #expect(summary.total == 5)
        #expect(summary.failed == 0)
        let page = try await repository.page()
        for track in page.tracks {
            #expect(track.title == "Morning Light", "\(track.relativePath): \(track.error ?? "")")
            #expect(track.artist == "Björk")
            #expect(track.albumArtist == "Ensemble")
            #expect(track.album == "Test Album")
            #expect(track.genre == "Classical")
            #expect(track.trackNumber == 2)
            #expect(track.discNumber == 2)
            #expect(track.year == "2024")
            #expect(track.artworkKey != nil)
            let tags = try JSONDecoder().decode(AudioTags.self, from: Data(try #require(track.tagsJSON).utf8))
            #expect(tags.composer == "Test Composer")
            #expect(tags.comment == "Original fixture")
        }
        #expect(try await repository.page(search: "bjork").count == 5)
        let thumbnails = try FileManager.default.contentsOfDirectory(at: artwork, includingPropertiesForKeys: nil)
        #expect(thumbnails.count == 1)
        let unchanged = try await scanner.scan(folder: folder, root: music)
        #expect(unchanged.changed == 0)
        // MP3's embedded artwork must remain available without an external cover.
        try FileManager.default.removeItem(at: music.appendingPathComponent("front.png"))
        _ = try await scanner.scan(folder: folder, root: music)
        let mp3 = try #require(try await repository.page().tracks.first { $0.relativePath.hasSuffix(".mp3") })
        #expect(mp3.artworkKey != nil)
    }

    @MainActor @Test func modelRestoresBookmarksAndRejectsOverlappingFolders() async throws {
        let (temporary, music, _) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("song.wav"))
        let storage = temporary.appendingPathComponent("Store")
        let model = LibraryModel(storageDirectory: storage, codecDirectory: codecs)
        await model.start()
        await model.addFolder(music)
        #expect(model.errorMessage == nil)
        #expect(model.folders.count == 1)
        #expect(model.tracks.count == 1)
        await model.addFolder(music.deletingLastPathComponent())
        #expect(model.folders.count == 1)
        #expect(model.errorMessage != nil)
        model.shutdown()
        let restored = LibraryModel(storageDirectory: storage, codecDirectory: codecs)
        await restored.start()
        #expect(restored.folders.count == 1)
        #expect(restored.tracks.count == 1)
        let track = try #require(restored.tracks.first)
        #expect(try restored.location(for: track).file.lastPathComponent == "song.wav")
        await restored.removeFolder(try #require(restored.folders.first))
        #expect(restored.tracks.isEmpty)
        #expect(FileManager.default.fileExists(atPath: music.appendingPathComponent("song.wav").path))
        restored.shutdown()
    }

    @Test func pagedSearchAcrossFiftyThousandStoredTracks() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("song.wav"))
        let repository = try LibraryRepository(path: temporary.appendingPathComponent("library.sqlite").path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        _ = try await LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs).scan(folder: folder, root: music)
        let template = try #require(try await repository.page().tracks.first)
        let tracks = (0..<50_000).map { index in
            var track = template
            track.id = "synthetic-\(index)"; track.relativePath = "\(index).wav"; track.title = "Track \(index)"
            return track
        }
        try await repository.saveTracks(tracks)
        let page = try await repository.page()
        #expect(page.count == 50_001)
        #expect(page.tracks.count == 500)
        #expect(try await repository.page(limit: 50_500).tracks.count == 50_001)
        #expect(try await repository.page(search: "Track 49999").count == 1)
    }

    @MainActor @Test func restoredMonitoredFolderAutomaticallyImportsUpdatesAndRemovesFiles() async throws {
        let (temporary, music, _) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let storage = temporary.appendingPathComponent("Store")
        let original = LibraryModel(storageDirectory: storage, codecDirectory: codecs)
        await original.start()
        await original.addFolder(music)
        #expect(original.isReady)
        #expect(original.isMonitoring(try #require(original.folders.first)))
        original.shutdown()

        let restored = LibraryModel(storageDirectory: storage, codecDirectory: codecs)
        await restored.start()
        defer { restored.shutdown() }
        let folder = try #require(restored.folders.first)
        #expect(restored.isMonitoring(folder))
        let nested = music.appendingPathComponent("New Album")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let song = nested.appendingPathComponent("new.wav")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: song)
        try await waitForLibrary { restored.tracks.contains { $0.relativePath == "New Album/new.wav" && $0.codec == "PCM" } }
        let id = try #require(restored.tracks.first?.id)

        // An atomic replacement must refresh metadata without duplicating the library entry.
        try Data(contentsOf: fixtures.appendingPathComponent("44100-16.mp3")).write(to: song, options: .atomic)
        try await waitForLibrary { restored.tracks.count == 1 && restored.tracks.first?.codec == "MP3" }
        #expect(restored.tracks.first?.id == id)
        try FileManager.default.removeItem(at: song)
        try await waitForLibrary { restored.totalCount == 0 }
        #expect(restored.lastScanAt != nil)
        #expect(restored.folderErrors.isEmpty)
        await restored.removeFolder(folder)
        #expect(!restored.isMonitoring(folder))
        #expect(FileManager.default.fileExists(atPath: music.path))
    }

    @MainActor private func waitForLibrary(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(condition(), "Folder monitoring did not update the library in time")
    }

    @Test func folderWatcherReportsNestedChanges() async throws {
        let (temporary, music, _) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let counter = EventCounter()
        let watcher = try #require(FolderWatcher(url: music) { Task { await counter.increment() } })
        defer { withExtendedLifetime(watcher) {} }
        let nested = music.appendingPathComponent("Disc 2")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: nested.appendingPathComponent("new.wav"))
        for _ in 0..<50 {
            if await counter.value > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(await counter.value > 0)
    }

    @Test func playlistCreationTrackManagementAndCascadeDeletion() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("song1.wav"))
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.mp3"), to: music.appendingPathComponent("song2.mp3"))

        let repository = try LibraryRepository(path: temporary.appendingPathComponent("library.sqlite").path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        _ = try await LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs).scan(folder: folder, root: music)

        let tracks = try await repository.page().tracks
        #expect(tracks.count == 2)

        // 1. Create playlist
        let playlist = try await repository.createPlaylist(name: "Favorites")
        #expect(playlist.name == "Favorites")
        var allPlaylists = try await repository.playlists()
        #expect(allPlaylists.count == 1)
        #expect(allPlaylists.first?.id == playlist.id)

        // 2. Add tracks (including duplicate, which is valid in playlists)
        try await repository.addTracksToPlaylist(playlistID: playlist.id, trackIDs: [tracks[0].id, tracks[1].id, tracks[0].id])
        var items = try await repository.playlistTrackItems(playlistID: playlist.id)
        #expect(items.count == 3)
        #expect(items[0].track.id == tracks[0].id)
        #expect(items[0].position == 0)
        #expect(items[1].track.id == tracks[1].id)
        #expect(items[1].position == 1)
        #expect(items[2].track.id == tracks[0].id)
        #expect(items[2].position == 2)

        // 3. Reorder track (move index 1 to index 0)
        try await repository.moveTrackInPlaylist(playlistID: playlist.id, from: 1, to: 0)
        items = try await repository.playlistTrackItems(playlistID: playlist.id)
        #expect(items.count == 3)
        #expect(items[0].track.id == tracks[1].id)
        #expect(items[0].position == 0)
        #expect(items[1].track.id == tracks[0].id)
        #expect(items[1].position == 1)

        // 4. Remove track from playlist
        try await repository.removeTrackFromPlaylist(playlistTrackID: items[0].id)
        items = try await repository.playlistTrackItems(playlistID: playlist.id)
        #expect(items.count == 2)
        #expect(items[0].track.id == tracks[0].id)
        #expect(items[0].position == 0)
        #expect(items[1].track.id == tracks[0].id)
        #expect(items[1].position == 1)

        // 5. Rename playlist
        try await repository.renamePlaylist(id: playlist.id, name: "Chill Vibes")
        let updated = try await repository.playlist(id: playlist.id)
        #expect(updated?.name == "Chill Vibes")

        // 6. Delete playlist removes its playlist_tracks
        try await repository.deletePlaylist(id: playlist.id)
        allPlaylists = try await repository.playlists()
        #expect(allPlaylists.isEmpty)
        items = try await repository.playlistTrackItems(playlistID: playlist.id)
        #expect(items.isEmpty)
        // Tracks themselves remain intact in library
        #expect(try await repository.page().count == 2)
    }

    @MainActor @Test func modelManagesPlaylists() async throws {
        let (temporary, music, _) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("track.wav"))

        let storage = temporary.appendingPathComponent("Store")
        let model = LibraryModel(storageDirectory: storage, codecDirectory: codecs)
        await model.start()
        await model.addFolder(music)
        #expect(model.tracks.count == 1)

        let playlist = try #require(await model.createPlaylist(name: "Road Trip"))
        #expect(model.playlists.count == 1)
        #expect(model.playlists.first?.name == "Road Trip")

        await model.addTracks(model.tracks, to: playlist)
        let items = await model.playlistTracks(for: playlist.id)
        #expect(items.count == 1)
        #expect(items.first?.track.title == "track")

        await model.renamePlaylist(playlist, newName: "Highway Tunes")
        #expect(model.playlists.first?.name == "Highway Tunes")

        await model.removeTrack(playlistTrackID: try #require(items.first?.id), from: playlist)
        #expect(await model.playlistTracks(for: playlist.id).isEmpty)

        await model.deletePlaylist(playlist)
        #expect(model.playlists.isEmpty)
        model.shutdown()
    }
}

private actor EventCounter {
    var value = 0
    func increment() { value += 1 }
}
