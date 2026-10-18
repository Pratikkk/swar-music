import Foundation
import Testing
@testable import Library

struct LibraryRecoveryTests {
    private var package: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() }
    private var fixtures: URL { package.appendingPathComponent("Tests/DecodingTests/Fixtures") }
    private var artFixture: URL { package.appendingPathComponent("Tests/LibraryTests/Fixtures/front.png") }
    private var codecs: URL { package.appendingPathComponent("Vendor/FFmpeg/lib") }

    @MainActor @Test func importedArtworkSurvivesCachePurgeAndRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = root.appendingPathComponent("Music")
        let store = root.appendingPathComponent("Store")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("one.wav"))
        try FileManager.default.copyItem(at: artFixture, to: music.appendingPathComponent("cover.jpg"))
        let model = LibraryModel(storageDirectory: store, codecDirectory: codecs)
        await model.start()
        await model.addFolder(music)
        let track = try #require(model.tracks.first)
        let key = try await model.importArtwork(artFixture)
        _ = try await model.setArtwork(ids: [track.id], key: key)
        let durable = try #require(model.artworkURL(key))
        #expect(durable.deletingLastPathComponent() != model.artworkDirectory)
        let expected = try Data(contentsOf: durable)
        try FileManager.default.removeItem(at: try #require(model.artworkDirectory))
        await model.rescan()
        #expect(model.tracks.first?.artworkKey == key)
        #expect(try Data(contentsOf: durable) == expected)
        model.shutdown()
        let restored = LibraryModel(storageDirectory: store, codecDirectory: codecs)
        await restored.start()
        defer { restored.shutdown() }
        #expect(restored.tracks.first?.artworkKey == key)
        #expect(try Data(contentsOf: #require(restored.artworkURL(key))) == expected)
    }

    @MainActor @Test func legacyCustomArtworkIsCopiedToDurableStorage() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = root.appendingPathComponent("Store")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = LibraryModel(storageDirectory: store, codecDirectory: codecs)
        await model.start()
        let key = try await model.importArtwork(artFixture)
        let durable = try #require(model.artworkURL(key))
        let expected = try Data(contentsOf: durable)
        let cache = try #require(model.artworkDirectory)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let legacy = cache.appendingPathComponent(key)
        try FileManager.default.moveItem(at: durable, to: legacy)
        model.shutdown()
        let upgraded = LibraryModel(storageDirectory: store, codecDirectory: codecs)
        await upgraded.start()
        defer { upgraded.shutdown() }
        #expect(upgraded.isReady)
        #expect(try Data(contentsOf: #require(upgraded.artworkURL(key))) == expected)
        #expect(try Data(contentsOf: legacy) == expected, "Saved queue URLs remain usable during migration")
        // A later start must preserve the already-migrated user asset.
        try Data("replacement cache data".utf8).write(to: legacy)
        upgraded.shutdown()
        let repeated = LibraryModel(storageDirectory: store, codecDirectory: codecs)
        await repeated.start()
        defer { repeated.shutdown() }
        #expect(try Data(contentsOf: #require(repeated.artworkURL(key))) == expected)
    }

    @MainActor @Test func renamedWatchedFolderCannotBeImportedTwice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = root.appendingPathComponent("Music")
        let renamed = root.appendingPathComponent("Renamed")
        let store = root.appendingPathComponent("Store")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("44100-16.wav"), to: music.appendingPathComponent("one.wav"))
        let original = LibraryModel(storageDirectory: store, codecDirectory: codecs)
        await original.start()
        await original.addFolder(music)
        let track = try #require(original.tracks.first)
        await original.toggleFavorite(track)
        let playlist = try #require(await original.createPlaylist(name: "Kept"))
        await original.addTracks([track], to: playlist)
        original.shutdown()
        try FileManager.default.moveItem(at: music, to: renamed)
        let restored = LibraryModel(storageDirectory: store, codecDirectory: codecs)
        await restored.start()
        defer { restored.shutdown() }
        #expect(restored.folders.first?.path == renamed.path)
        #expect(await restored.track(at: renamed.appendingPathComponent("one.wav"))?.id == track.id)
        await restored.addFolder(renamed)
        #expect(restored.folders.count == 1 && restored.totalCount == 1)
        #expect(restored.favoriteTrackIDs.contains(track.id))
        #expect(try await restored.playlistItems(for: playlist.id).map(\.track.id) == [track.id])
        #expect(restored.errorMessage?.contains("overlaps") == true)
    }
}
