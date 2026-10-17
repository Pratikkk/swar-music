import Foundation
import Decoding
import GRDB
import Observation
import os
import Testing
@testable import Library

struct LibraryTests {
    @MainActor @Test func smartPlaylistModelTracksRescansFavouritesAndHiddenSongs() async throws {
        let (temporary, music, _) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("one.wav"))
        let model = LibraryModel(storageDirectory: temporary.appendingPathComponent("Store"), codecDirectory: codecs)
        await model.start()
        defer { model.shutdown() }
        await model.addFolder(music)
        let definition = SmartPlaylistDefinition(rules: [SmartRule(field: .lossless), SmartRule(field: .favourite)])
        let playlist = try await model.saveSmartPlaylist(name: "Favourite lossless", definition: definition)
        #expect(model.playlists.first?.isSmart == true && model.manualPlaylists.isEmpty)
        #expect(await model.playlistTracks(for: playlist.id).isEmpty)
        let first = try #require(model.tracks.first)
        await model.toggleFavorite(first)
        #expect(try await model.smartPlaylistPreview(definition).selectedCount == 1)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("two.wav"))
        await model.rescan()
        let second = try #require(model.tracks.first { $0.relativePath == "two.wav" })
        await model.toggleFavorite(second)
        #expect(await model.playlistTracks(for: playlist.id).count == 2)
        await model.removeTrackFromLibrary(first)
        #expect(await model.playlistTracks(for: playlist.id).map(\.track.id) == [second.id])
        await model.removeFolder(try #require(model.folders.first))
        #expect(await model.playlistTracks(for: playlist.id).isEmpty)
        #expect(model.playlists.first?.id == playlist.id)
    }

    @MainActor @Test func playingFileLookupIgnoresSearchAndExcludesHiddenOrOutsideFiles() async throws {
        let (temporary, music, _) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = music.appendingPathComponent("song.wav")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: file)
        let model = LibraryModel(storageDirectory: temporary.appendingPathComponent("Store"), codecDirectory: codecs)
        await model.start()
        defer { model.shutdown() }
        await model.addFolder(music)
        let original = try #require(model.tracks.first)
        model.search = "no matching song"
        await model.reload()
        #expect(model.tracks.isEmpty)
        #expect(await model.track(at: file)?.id == original.id)
        #expect(await model.track(at: music.deletingLastPathComponent().appendingPathComponent("MusicSibling/song.wav")) == nil)
        #expect(await model.track(at: URL(string: "https://example.com/song.wav")!) == nil)
        await model.removeTrackFromLibrary(original)
        #expect(await model.track(at: file) == nil)
        await model.restoreRemovedTracks()
        #expect(await model.track(at: file)?.id == original.id)
    }

    @Test func exactTrackLookupWorksBeyondTheVisiblePageAndHonoursRemoval() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("song.wav"))
        let repository = try LibraryRepository(path: temporary.appendingPathComponent("library.sqlite").path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        _ = try await LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs).scan(folder: folder, root: music)
        let seed = try #require(try await repository.page().tracks.first)
        let tracks = (0..<600).map { index in
            var track = seed
            track.id = folder.id + ":extra-\(index).wav"
            track.relativePath = "extra-\(index).wav"
            track.title = String(format: "%04d", index)
            return track
        }
        try await repository.saveTracks(tracks)
        let target = tracks[599]
        #expect(!(try await repository.page(limit: 500).tracks.contains { $0.id == target.id }))
        #expect(try await repository.visibleTrack(id: target.id)?.title == target.title)
        try await repository.removeTrackFromLibrary(trackID: target.id)
        #expect(try await repository.visibleTrack(id: target.id) == nil)
    }

    @MainActor @Test func unchangedReloadAndScanDoNotInvalidateTracksAndFolderRemovalRefreshesPlaylists() async throws {
        let (temporary, music, _) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("song.wav"))
        let model = LibraryModel(storageDirectory: temporary.appendingPathComponent("Store"), codecDirectory: codecs)
        await model.start()
        defer { model.shutdown() }
        await model.addFolder(music)
        let changes = OSAllocatedUnfairLock(initialState: 0)
        withObservationTracking { _ = model.tracks } onChange: { changes.withLock { $0 += 1 } }
        await model.reload()
        await model.rescan()
        #expect(changes.withLock { $0 } == 0)
        let playlist = try #require(await model.createPlaylist(name: "Folder songs"))
        await model.addTracks(model.tracks, to: playlist)
        #expect(await model.playlistTracks(for: playlist.id).count == 1)
        let revision = model.trackActionsRevision
        await model.removeFolder(try #require(model.folders.first))
        #expect(model.tracks.isEmpty)
        #expect(model.trackActionsRevision == revision + 1)
        #expect(await model.playlistTracks(for: playlist.id).isEmpty)
        let lastScan = model.lastScanAt
        model.shutdown()
        await model.rescan()
        #expect(model.lastScanAt == lastScan)
        #expect(!model.isScanning)
    }

    @Test func cancelledScanDoesNotReconcileDeletedFiles() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = music.appendingPathComponent("song.wav")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: file)
        let repository = try LibraryRepository(path: temporary.appendingPathComponent("library.sqlite").path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        let scanner = LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs)
        _ = try await scanner.scan(folder: folder, root: music)
        try FileManager.default.removeItem(at: file)
        let gate = ScanCancellationGate()
        let scanning = Task { try await scanner.scan(folder: folder, root: music) { _ in await gate.block() } }
        await gate.waitUntilBlocked()
        scanning.cancel()
        await gate.release()
        do {
            _ = try await scanning.value
            Issue.record("Cancelled scanning should throw CancellationError")
        } catch is CancellationError { }
        #expect(try await repository.page().count == 1)
        _ = try await scanner.scan(folder: folder, root: music)
        #expect(try await repository.page().count == 0)
    }

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
    @Test(arguments: ["44100-16.wav", "96000-24.flac", "192000-24.m4a", "96000-24.aiff", "96000-float.caf"])
    func singleProbeInspectionPreservesNativeSourceFacts(name: String) throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DecodingTests/Fixtures").appendingPathComponent(name)
        let url = music.appendingPathComponent(name)
        try FileManager.default.copyItem(at: source, to: url)
        let native = try NativeDecoder(url: url)
        let folder = LibraryFolder(path: music.path)
        let file = ScanFile(url: url, relativePath: name, size: Int64(try Data(contentsOf: url).count),
            modified: Date(), coverURL: nil, coverStamp: "")
        let track = MediaInspector(codecDirectory: codecs, artworkDirectory: artwork)
            .inspect(file: file, folder: folder, prior: nil)
        #expect(track.error == nil)
        #expect(track.codec == native.source.codec)
        #expect(track.bitDepth == native.source.bitDepth)
        #expect(track.sampleRate == native.source.sampleRate)
        #expect(track.channels == native.source.channels)
        #expect(track.isLossless == native.source.isLossless)
        #expect(track.isFloat == native.source.isFloat)
        #expect(abs(track.duration - Double(native.frameCount) / native.source.sampleRate) < 0.000001)
    }

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
        #expect(try await repository.collectionPage(limit: 50).summary.songs == 50_001)
        #expect(try await repository.page(search: "Track 49999").count == 1)
    }

    @Test func homeOverviewUsesWholeLibraryAndDistinctAlbumsAndExcludesHiddenSongs() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("song.wav"))
        let repository = try LibraryRepository(path: temporary.appendingPathComponent("library.sqlite").path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        _ = try await LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs).scan(folder: folder, root: music)
        var template = try #require(try await repository.page().tracks.first)
        template.albumArtist = "A"; template.album = "One"; template.addedAt = Date(timeIntervalSince1970: 5000)
        let tracks = (0..<600).map { index in
            var track = template
            track.id = "home-\(index)"; track.relativePath = "home-\(index).wav"
            track.title = "Song \(index)"; track.trackNumber = index + 1
            track.addedAt = Date(timeIntervalSince1970: 100)
            if index == 599 {
                track.album = "Two"; track.artworkKey = "two-cover"
                track.addedAt = Date(timeIntervalSince1970: 1)
                track.error = "Unavailable"; track.isLossless = false
            }
            return track
        }
        try await repository.saveTracks([template] + tracks)
        try await repository.setFavorite(trackID: tracks[0].id, favorite: true)
        try await repository.setFavorite(trackID: tracks[599].id, favorite: true)
        let overview = try await repository.overview()
        #expect(overview.trackCount == 601 && overview.albumCount == 2 && overview.losslessCount == 600)
        #expect(overview.recentAlbums.map(\.title) == ["One", "Two"])
        #expect(overview.recentAlbums.map(\.trackCount) == [600, 1])
        #expect(overview.recentAlbums.map(\.playableCount) == [600, 0])
        #expect(overview.recentAlbums.last?.artworkKey == "two-cover")
        #expect(Set(overview.favourites.map(\.id)) == [tracks[0].id, tracks[599].id])
        #expect(try await repository.albumTracks(artist: "A", title: "One").count == 600)
        let browsed = try await repository.albums()
        #expect(browsed.count == 2 && browsed.map(\.trackCount) == [600, 1])
        #expect(try await repository.albums(search: "Song 0", searchScope: .title).first?.trackCount == 600)
        #expect(try await repository.albums(search: "Song 599", searchScope: .title).first?.title == "Two")
        #expect(try await repository.albums(search: "One", searchScope: .album).first?.trackCount == 600)
        #expect(try await repository.albums(search: "One", searchScope: .title).isEmpty)
        #expect(try await repository.albums(search: "*** : ()").isEmpty)

        #expect(try await repository.overview(limit: 1).recentAlbums.count == 1)
        try await repository.removeTrackFromLibrary(trackID: tracks[599].id)
        #expect(try await repository.albums(search: "Song 599", searchScope: .title).isEmpty)
        let afterRemoval = try await repository.overview()
        #expect(afterRemoval.albumCount == 1 && afterRemoval.trackCount == 600)
        #expect(afterRemoval.favourites.map(\.id) == [tracks[0].id])
        try await repository.removeTrackFromLibrary(trackID: tracks[1].id)
        #expect(try await repository.albumTracks(artist: "A", title: "One").count == 599)
        try await repository.removeFolder(folder.id)
        let empty = try await repository.overview()
        #expect(empty.trackCount == 0 && empty.albumCount == 0 && empty.losslessCount == 0)
        #expect(empty.recentAlbums.isEmpty && empty.favourites.isEmpty)
    }

    @Test func albumSearchKeepsArtistsDistinctAndReturnsCompleteVisibleMetadata() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("song.wav"))
        let repository = try LibraryRepository(path: temporary.appendingPathComponent("library.sqlite").path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        _ = try await LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs).scan(folder: folder, root: music)
        var first = try #require(try await repository.page().tracks.first)
        first.title = "Needle"; first.album = "Same Title"; first.albumArtist = "Artist A"
        first.year = "2020"; first.duration = 30; first.addedAt = Date(timeIntervalSince1970: 10)
        var second = first
        second.id = "second"; second.title = "Other"; second.trackNumber = 2; second.duration = 60
        second.error = "Unavailable"; second.artworkKey = "cover"; second.addedAt = Date(timeIntervalSince1970: 20)
        var third = first
        third.id = "third"; third.albumArtist = "Artist B"; third.year = nil
        try await repository.saveTracks([first, second, third])
        let albums = try await repository.albums(search: "Need", searchScope: .title)
        #expect(albums.count == 2)
        let album = try #require(albums.first { $0.artist == "Artist A" })
        #expect(album.trackCount == 2 && album.playableCount == 1)
        #expect(album.duration == 90 && album.year == "2020" && album.artworkKey == "cover")
        #expect(album.addedAt == Date(timeIntervalSince1970: 20))
        #expect(try await repository.albumTracks(artist: album.artist, title: album.title).count == 2)
        try await repository.removeTrackFromLibrary(trackID: first.id)
        #expect(try await repository.albums(search: "Need", searchScope: .title).map(\.artist) == ["Artist B"])
        let visible = try #require(try await repository.albums().first { $0.artist == "Artist A" })
        #expect(visible.trackCount == 1 && visible.playableCount == 0 && visible.duration == 60)
        try await repository.removeFolder(folder.id)
        #expect(try await repository.albums().isEmpty)
    }

    @MainActor @Test func customArtworkImportValidatesImagesAndPreservesSource() async throws {
        let (temporary, _, _) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let model = LibraryModel(storageDirectory: temporary.appendingPathComponent("Store"), codecDirectory: codecs)
        await model.start()
        defer { model.shutdown() }
        let source = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/front.png")
        let original = try Data(contentsOf: source)
        let key = try await model.importArtwork(source)
        #expect(key.hasPrefix("custom-1024-"))
        #expect(FileManager.default.fileExists(atPath: try #require(model.artworkURL(key)).path))
        #expect(try Data(contentsOf: source) == original)
        #expect(try await model.importArtwork(source) == key)
        let invalid = temporary.appendingPathComponent("bad.png")
        try Data("Not an image".utf8).write(to: invalid)
        await #expect(throws: (any Error).self) { try await model.importArtwork(invalid) }
        let oversized = temporary.appendingPathComponent("large.png")
        FileManager.default.createFile(atPath: oversized.path, contents: nil)
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: 21 * 1024 * 1024)
        try handle.close()
        await #expect(throws: (any Error).self) { try await model.importArtwork(oversized) }
    }

    @Test func artworkOverridesSurviveActualRescansAndResetIndependentlyOfMetadata() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = music.appendingPathComponent("song.wav")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: source)
        let original = try Data(contentsOf: source)
        let path = temporary.appendingPathComponent("library.sqlite").path
        let repository = try LibraryRepository(path: path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        let scanner = LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs)
        _ = try await scanner.scan(folder: folder, root: music)
        let track = try #require(try await repository.page().tracks.first)
        #expect(track.artworkKey == nil)
        _ = try await repository.setArtwork(ids: [track.id], key: "custom.png")
        let selection = try await repository.artworkSelection(ids: [track.id], referenceID: track.id)
        #expect(selection.customCount == 1 && selection.originalKey == nil)
        _ = try await repository.setArtwork(ids: [track.id], key: "replacement.png")
        #expect(try await repository.artworkSelection(ids: [track.id], referenceID: track.id).originalKey == nil)
        let reopened = try LibraryRepository(path: path)
        #expect(try await reopened.page().tracks.first?.artworkKey == "replacement.png")
        var details = TrackMetadata(track: track)
        details.title = "Local title"; details.artist = "Artist"; details.albumArtist = "Artist"; details.album = "Album"
        try await repository.updateMetadata(trackID: track.id, metadata: details)
        try FileManager.default.copyItem(at: Bundle.module.resourceURL!.appendingPathComponent("Fixtures/front.png"), to: music.appendingPathComponent("front.png"))
        _ = try await scanner.scan(folder: folder, root: music)
        let rescanned = try #require(try await repository.page().tracks.first)
        #expect(rescanned.artworkKey == "replacement.png" && rescanned.title == "Local title")
        let scannedCover = try #require(try await repository.artworkSelection(ids: [track.id], referenceID: track.id).originalKey)
        #expect(scannedCover != "replacement.png")
        _ = try await repository.setArtwork(ids: [track.id], key: nil)
        let reset = try #require(try await repository.page().tracks.first)
        #expect(reset.artworkKey == scannedCover && reset.title == "Local title")
        #expect(try await repository.hasMetadataEdits(trackID: track.id))
        #expect(try await repository.artworkSelection(ids: [track.id], referenceID: track.id).customCount == 0)
        #expect(try Data(contentsOf: source) == original)
    }

    @Test func albumArtworkAppliesBeyondFirstPageAndResetsMissingCovers() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("song.wav"))
        let repository = try LibraryRepository(path: temporary.appendingPathComponent("library.sqlite").path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        _ = try await LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs).scan(folder: folder, root: music)
        var template = try #require(try await repository.page().tracks.first)
        template.album = "Album"; template.albumArtist = "Artist"
        let tracks = (0..<601).map { i in
            var track = template
            track.id = "art-\(i)"; track.trackNumber = i + 1
            return track
        }
        try await repository.saveTracks(tracks)
        let album = try await repository.albumTracks(artist: "Artist", title: "Album")
        #expect(album.count == 601)
        let ids = Set(album.map(\.id))
        #expect(try await repository.setArtwork(ids: ids, key: "cover.png").count == 601)
        #expect(try await repository.albums().first { $0.title == "Album" }?.artworkKey == "cover.png")
        #expect(try await repository.artworkSelection(ids: ids, referenceID: album[0].id).customCount == 601)
        _ = try await repository.setArtwork(ids: [album[0].id], key: nil)
        #expect(try await repository.artworkSelection(ids: ids, referenceID: album[0].id).customCount == 600)
        #expect(try await repository.collectionPage(filter: .artwork).count == 2)
        await #expect(throws: (any Error).self) { try await repository.setArtwork(ids: ids, key: "../bad.png") }
        try await repository.removeFolder(folder.id)
        #expect(try await repository.artworkSelection(ids: ids, referenceID: album[0].id).customCount == 0)
    }

    @Test func collectionReviewUsesFullLibraryAndTreatsDuplicatesAsCandidates() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("song.wav"))
        let repository = try LibraryRepository(path: temporary.appendingPathComponent("library.sqlite").path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        _ = try await LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs).scan(folder: folder, root: music)
        var template = try #require(try await repository.page().tracks.first)
        template.title = "Shared Song"; template.artist = "Singer"; template.albumArtist = "Singer"
        template.album = "Album"; template.duration = 60.2; template.artworkKey = "art"
        template.tagsJSON = "{\"title\":\"Shared Song\",\"artist\":\"Singer\",\"album\":\"Album\"}"
        var tracks = (0..<600).map { index in
            var track = template
            track.id = "review-\(index)"; track.title = "Unique \(index)"; track.trackNumber = index + 1
            return track
        }
        tracks[599].title = " shared song "; tracks[599].artist = " singer "; tracks[599].duration = 60.4
        tracks[598].tagsJSON = "invalid JSON"; tracks[598].artworkKey = nil
        tracks[597].error = "Corrupt file"; tracks[597].artworkKey = nil
        try await repository.saveTracks([template] + tracks)
        let all = try await repository.collectionPage(limit: 200)
        #expect(all.summary.songs == 601 && all.tracks.count == 200 && all.count == 601)
        #expect(all.summary.incomplete == 1 && all.summary.artwork == 2 && all.summary.unreadable == 1)
        #expect(all.summary.duplicates == 2 && all.summary.removed == 0)
        #expect(try await repository.collectionPage(filter: .duplicates).tracks.count == 2)
        #expect(try await repository.collectionPage(filter: .incomplete).tracks.map(\.id) == [tracks[598].id])
        let searched = try await repository.collectionPage(filter: .all, search: "Unique 598", scope: .title)
        #expect(searched.count == 1 && searched.summary.songs == 601)
        #expect(try await repository.collectionPage(search: "*** : ()").count == 0)
        try await repository.removeTracksFromLibrary(ids: [tracks[599].id, tracks[598].id, "missing-id"])
        let hidden = try await repository.collectionPage(filter: .removed)
        #expect(hidden.count == 2 && hidden.summary.songs == 599 && hidden.summary.duplicates == 0)
        #expect(hidden.summary.incomplete == 0 && hidden.summary.artwork == 1)
        #expect(try await repository.collectionPage(filter: .removed, search: "Unique 598", scope: .title).count == 1)
        try await repository.restoreTracks(ids: [tracks[598].id])
        #expect(try await repository.collectionPage(filter: .removed).count == 1)
        #expect(try await repository.collectionPage(filter: .incomplete).count == 1)
    }

    @Test func metadataCorrectionsSurviveRescansAndResetToLatestFileDetails() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let source = music.appendingPathComponent("song.wav")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: source)
        let before = try Data(contentsOf: source)
        let path = temporary.appendingPathComponent("library.sqlite").path
        let repository = try LibraryRepository(path: path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        _ = try await LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs).scan(folder: folder, root: music)
        let original = try #require(try await repository.page().tracks.first)
        var edits = TrackMetadata(track: original)
        edits.title = "Corrected Title"; edits.artist = "Artist"; edits.albumArtist = "Album Artist"
        edits.album = "Corrected Album"; edits.genre = "Jazz"; edits.year = "2026"; edits.discNumber = 2; edits.trackNumber = 4
        try await repository.updateMetadata(trackID: original.id, metadata: edits)
        #expect(try await repository.hasMetadataEdits(trackID: original.id))
        #expect(try await repository.collectionPage(filter: .incomplete).count == 0)
        #expect(try await repository.page(search: "Corrected Title", searchScope: .title).count == 1)
        let albums = try await repository.albums(search: "Corrected Album", searchScope: .album)
        #expect(albums.first?.artist == "Album Artist")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(20)], ofItemAtPath: source.path)
        _ = try await LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs).scan(folder: folder, root: music)
        #expect(try await repository.page().tracks.first?.title == "Corrected Title")
        var rescanned = original
        rescanned.title = "New File Title"; rescanned.year = "2030"; rescanned.duration = 123
        rescanned.tagsJSON = "{\"title\":\"New File Title\",\"artist\":\"Singer\",\"album\":\"Album\"}"
        try await repository.saveTracks([rescanned])
        let persisted = try #require(try await LibraryRepository(path: path).page().tracks.first)
        #expect(persisted.title == "Corrected Title" && persisted.year == "2026" && persisted.duration == 123)
        #expect(persisted.tagsJSON == rescanned.tagsJSON && persisted.relativePath == original.relativePath)
        edits.year = "2025"
        try await repository.updateMetadata(trackID: original.id, metadata: edits)
        try await repository.resetMetadata(trackID: original.id)
        let reset = try #require(try await repository.page().tracks.first)
        #expect(reset.title == "New File Title" && reset.year == "2030" && reset.duration == 123)
        #expect(try await repository.hasMetadataEdits(trackID: original.id) == false)
        #expect(try await repository.page(search: "Corrected Title", searchScope: .title).count == 0)
        #expect(try await repository.page(search: "New File", searchScope: .title).count == 1)
        #expect(try Data(contentsOf: source) == before)
        edits.title = "   "
        await #expect(throws: (any Error).self) { try await repository.updateMetadata(trackID: original.id, metadata: edits) }
        #expect(try await repository.page().tracks.first?.title == "New File Title")
    }

    @Test func bulkRemovalRestoresVisibilityWithoutRecreatingPlaylistMembership() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("song.wav"))
        let repository = try LibraryRepository(path: temporary.appendingPathComponent("library.sqlite").path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        _ = try await LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs).scan(folder: folder, root: music)
        let track = try #require(try await repository.page().tracks.first)
        let playlist = try await repository.createPlaylist(name: "Review")
        try await repository.addTracksToPlaylist(playlistID: playlist.id, trackIDs: [track.id])
        try await repository.setFavorite(trackID: track.id, favorite: true)
        try await repository.removeTracksFromLibrary(ids: [track.id])
        #expect(try await repository.page().count == 0)
        #expect(try await repository.playlistTrackItems(playlistID: playlist.id).isEmpty)
        #expect(try await repository.trackPreferences().favorites.isEmpty)
        try await repository.restoreTracks(ids: [track.id])
        #expect(try await repository.page().count == 1)
        #expect(try await repository.playlistTrackItems(playlistID: playlist.id).isEmpty)
        #expect(FileManager.default.fileExists(atPath: music.appendingPathComponent("song.wav").path))
    }

    @Test func expandedSearchMatchesScopesPunctuationAccentsAndIndianScripts() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("song.wav"))
        let repository = try LibraryRepository(path: temporary.appendingPathComponent("library.sqlite").path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        _ = try await LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs).scan(folder: folder, root: music)
        var track = try #require(try await repository.page().tracks.first)
        track.title = "Crème—Night (Live)"; track.artist = "Björk"; track.albumArtist = "संगीत समूह"
        track.album = "Ocean"; track.genre = "Dream Pop"; track.year = "2011"
        track.relativePath = "Disc 1/02 - Evening.flac"
        try await repository.saveTracks([track])
        let cases: [(String, TrackSearchScope, Bool)] = [
            ("creme LIVE", .all, true), ("bjork cre", .all, true),
            ("Dream-Pop", .genre, true), ("संगीत", .artist, true), ("समू", .artist, true),
            ("201", .year, true), ("Even flac", .file, true), ("disc 1", .file, true),
            ("Ocean", .album, true), ("Ocean", .title, false), ("Dream", .artist, false),
            ("  ", .genre, true), ("*** : ()", .all, false), ("Night OR missing", .all, false),
            ("\"; DROP TABLE tracks;", .all, false), ("creme--night", .title, true)
        ]
        for (text, scope, expected) in cases {
            #expect((try await repository.page(search: text, searchScope: scope).count == 1) == expected, "Indexed: \(text) / \(scope)")
            #expect(TrackSearchQuery(text).matches(track, scope: scope) == expected, "Playlist: \(text) / \(scope)")
        }
        track.genre = "Jazz"
        try await repository.saveTracks([track])
        #expect(try await repository.page(search: "Dream", searchScope: .genre).count == 0)
        #expect(try await repository.page(search: "Jazz", searchScope: .genre).count == 1)
        try await repository.removeFolder(folder.id)
        #expect(try await repository.page(search: "Jazz").count == 0)
    }

    @Test func expandedSearchMigrationReindexesExistingTracksWithoutLosingPreferences() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("song.wav"))
        let path = temporary.appendingPathComponent("library.sqlite").path
        let repository = try LibraryRepository(path: path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        _ = try await LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs).scan(folder: folder, root: music)
        var track = try #require(try await repository.page().tracks.first)
        track.genre = "Migration Jazz"; track.albumArtist = "Migration Orchestra"
        try await repository.saveTracks([track])
        try await repository.setFavorite(trackID: track.id, favorite: true)
        // Recreate the v4 search index to exercise an upgrade with existing music.
        let legacy = try DatabaseQueue(path: path)
        try await legacy.write { db in
            try db.execute(sql: """
                DROP TRIGGER tracks_ai; DROP TRIGGER tracks_ad; DROP TRIGGER tracks_au;
                DROP TABLE track_search;
                CREATE VIRTUAL TABLE track_search USING fts5(title,artist,album,content='tracks',content_rowid='rowid');
                CREATE TRIGGER tracks_ai AFTER INSERT ON tracks BEGIN
                  INSERT INTO track_search(rowid,title,artist,album) VALUES(new.rowid,new.title,new.artist,new.album); END;
                CREATE TRIGGER tracks_ad AFTER DELETE ON tracks BEGIN
                  INSERT INTO track_search(track_search,rowid,title,artist,album) VALUES('delete',old.rowid,old.title,old.artist,old.album); END;
                CREATE TRIGGER tracks_au AFTER UPDATE ON tracks BEGIN
                  INSERT INTO track_search(track_search,rowid,title,artist,album) VALUES('delete',old.rowid,old.title,old.artist,old.album);
                  INSERT INTO track_search(rowid,title,artist,album) VALUES(new.rowid,new.title,new.artist,new.album); END;
                INSERT INTO track_search(track_search) VALUES('rebuild');
                DELETE FROM grdb_migrations WHERE identifier = 'library-expanded-search-v5';
                """)
        }
        let upgraded = try LibraryRepository(path: path)
        #expect(try await upgraded.page(search: "Migration Jazz", searchScope: .genre).tracks.first?.id == track.id)
        #expect(try await upgraded.page(search: "Orchestra", searchScope: .artist).count == 1)
        #expect(try await upgraded.trackPreferences().favorites == [track.id])
    }

    @Test func trackSortingAppliesBeforePagingWithStableTies() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("song.wav"))
        let repository = try LibraryRepository(path: temporary.appendingPathComponent("library.sqlite").path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        _ = try await LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs).scan(folder: folder, root: music)
        let template = try #require(try await repository.page().tracks.first)
        let tracks = (0..<3).map { index in
            var track = template
            track.id = "sort-\(index)"; track.relativePath = "sort-\(index).wav"
            track.title = ["Sortcase C", "Sortcase A", "Sortcase B"][index]
            track.artist = ["Z", "Y", "X"][index]
            track.album = ["B", "C", "A"][index]
            track.duration = [30.0, 10.0, 20.0][index]
            track.addedAt = Date(timeIntervalSince1970: [3.0, 1.0, 2.0][index])
            return track
        }
        try await repository.saveTracks(tracks)
        let expected: [(TrackSortOrder, [Int])] = [
            (.title, [1, 2, 0]), (.artist, [2, 1, 0]), (.album, [2, 0, 1]),
            (.duration, [1, 2, 0]), (.recentlyAdded, [0, 2, 1])
        ]
        for (order, indices) in expected {
            let page = try await repository.page(search: "Sortcase", limit: 2, sortOrder: order)
            #expect(page.count == 3)
            #expect(page.tracks.map(\.id) == indices.prefix(2).map { tracks[$0].id })
            let reversed = try await repository.page(search: "Sortcase", limit: 2, sortOrder: order, reversed: true)
            #expect(reversed.tracks.map(\.id) == indices.reversed().prefix(2).map { tracks[$0].id })
        }
        var tie = tracks[0]
        tie.title = "Tiecase"; tie.id = "tie-b"; tie.relativePath = "tie-b.wav"
        var otherTie = tie
        otherTie.id = "tie-a"; otherTie.relativePath = "tie-a.wav"
        try await repository.saveTracks([tie, otherTie])
        for reversed in [false, true] {
            #expect(try await repository.page(search: "Tiecase", limit: 1, sortOrder: .title, reversed: reversed).tracks.first?.id == "tie-a")
        }
        // A recent-library request retains its newest-first semantics.
        #expect(try await repository.page(search: "Sortcase", recentFirst: true, sortOrder: .title, reversed: true).tracks.map(\.id) == [tracks[0].id, tracks[2].id, tracks[1].id])
    }

    @Test func favouritesFilterBeforePaginationAndCombineWithSearch() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("song.wav"))
        let repository = try LibraryRepository(path: temporary.appendingPathComponent("library.sqlite").path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        _ = try await LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs).scan(folder: folder, root: music)
        let template = try #require(try await repository.page().tracks.first)
        let tracks = (0..<600).map { index in
            var track = template
            track.id = "fav-test-\(index)"; track.relativePath = "\(index).wav"
            track.title = "Song \(index)"; track.trackNumber = index + 1
            return track
        }
        try await repository.saveTracks(tracks)
        // This favourite lies outside the first unfiltered page.
        try await repository.setFavorite(trackID: tracks[599].id, favorite: true)
        try await repository.setFavorite(trackID: tracks[598].id, favorite: true)
        let page = try await repository.page(limit: 1, favoritesOnly: true)
        #expect(page.count == 2 && page.tracks.count == 1)
        #expect(try await repository.page(limit: 500, favoritesOnly: true).tracks.map(\.id) == [tracks[598].id, tracks[599].id])
        #expect(try await repository.page(search: "Song 599", favoritesOnly: true).tracks.map(\.id) == [tracks[599].id])
        #expect(try await repository.page(search: "Song 100", favoritesOnly: true).count == 0)
        try await repository.setFavorite(trackID: tracks[599].id, favorite: false)
        #expect(try await repository.page(favoritesOnly: true).count == 1)
        try await repository.removeTrackFromLibrary(trackID: tracks[598].id)
        #expect(try await repository.page(favoritesOnly: true).count == 0)
        #expect(try await repository.page().count == 600)
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

    @Test func songPreferencesPersistAcrossRescansAndLibraryRemovalStaysExcluded() async throws {
        let (temporary, music, artwork) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = music.appendingPathComponent("favourite.wav")
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: file)
        let path = temporary.appendingPathComponent("library.sqlite").path
        let repository = try LibraryRepository(path: path)
        let folder = LibraryFolder(path: music.path)
        try await repository.saveFolder(folder)
        let scanner = LibraryScanner(repository: repository, artworkDirectory: artwork, codecDirectory: codecs)
        _ = try await scanner.scan(folder: folder, root: music)
        let track = try #require(try await repository.page().tracks.first)
        try await repository.setFavorite(trackID: track.id, favorite: true)
        let reopened = try LibraryRepository(path: path)
        #expect(try await reopened.trackPreferences().favorites == [track.id])
        // A metadata refresh must leave user preferences intact.
        try Data(contentsOf: fixtures.appendingPathComponent("44100-16.mp3")).write(to: file, options: .atomic)
        _ = try await scanner.scan(folder: folder, root: music)
        #expect(try await repository.trackPreferences().favorites == [track.id])
        let playlist = try await repository.createPlaylist(name: "Test")
        try await repository.addTracksToPlaylist(playlistID: playlist.id, trackIDs: [track.id, track.id])
        try await repository.removeTrackFromLibrary(trackID: track.id)
        #expect(try await repository.page().count == 0)
        #expect(try await repository.page(search: "favourite").count == 0)
        #expect(try await repository.playlistTrackItems(playlistID: playlist.id).isEmpty)
        #expect(try await repository.trackPreferences().favorites.isEmpty)
        #expect(try await repository.trackPreferences().hiddenCount == 1)
        _ = try await scanner.scan(folder: folder, root: music)
        #expect(try await reopened.page().count == 0)
        #expect(FileManager.default.fileExists(atPath: file.path))
        // Stale UI actions must not put an excluded song back into a playlist.
        try await repository.addTracksToPlaylist(playlistID: playlist.id, trackIDs: [track.id])
        try await repository.restoreRemovedTracks()
        #expect(try await repository.page().count == 1)
        #expect(try await repository.trackPreferences().hiddenCount == 0)
        #expect(try await repository.playlistTrackItems(playlistID: playlist.id).isEmpty)
        try await repository.setFavorite(trackID: track.id, favorite: true)
        try await repository.removeFolder(folder.id)
        #expect(try await repository.trackPreferences().favorites.isEmpty)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @MainActor @Test func modelPublishesSongPreferencesAndRestoration() async throws {
        let (temporary, music, _) = try workspace()
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("song.wav"))
        let storage = temporary.appendingPathComponent("Store")
        let model = LibraryModel(storageDirectory: storage, codecDirectory: codecs)
        await model.start()
        await model.addFolder(music)
        let track = try #require(model.tracks.first)
        await model.toggleFavorite(track)
        #expect(model.favoriteTrackIDs.contains(track.id))
        model.favoritesOnly = true
        await model.reload(resetLimit: true)
        #expect(model.tracks.map(\.id) == [track.id] && model.totalCount == 1)
        await model.toggleFavorite(track)
        #expect(model.tracks.isEmpty && model.totalCount == 0)
        model.favoritesOnly = false
        await model.reload(resetLimit: true)
        #expect(model.tracks.map(\.id) == [track.id])
        await model.toggleFavorite(track)
        let revision = model.overviewRevision
        model.search = "not-a-match"
        await model.reload()
        #expect(model.tracks.isEmpty && model.overviewRevision > revision)
        #expect(await model.overview()?.trackCount == 1)
        #expect(await model.overview()?.favourites.first?.id == track.id)
        model.search = ""
        await model.reload()
        model.shutdown()
        let restored = LibraryModel(storageDirectory: storage, codecDirectory: codecs)
        await restored.start()
        defer { restored.shutdown() }
        #expect(restored.favoriteTrackIDs.contains(track.id))
        await restored.removeTrackFromLibrary(track)
        #expect(restored.tracks.isEmpty && restored.hiddenTrackCount == 1)
        #expect(restored.favoriteTrackIDs.isEmpty)
        #expect(restored.trackActionsRevision == 1)
        await restored.rescan()
        #expect(restored.tracks.isEmpty)
        await restored.restoreRemovedTracks()
        #expect(restored.tracks.first?.id == track.id)
        #expect(restored.hiddenTrackCount == 0 && restored.trackActionsRevision == 2)
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

private actor ScanCancellationGate {
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
