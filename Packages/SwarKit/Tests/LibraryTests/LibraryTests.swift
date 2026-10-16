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
}

private actor EventCounter {
    var value = 0
    func increment() { value += 1 }
}
