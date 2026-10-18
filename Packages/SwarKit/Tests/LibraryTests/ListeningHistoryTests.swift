import Foundation
import GRDB
import Testing
@testable import Library

struct ListeningHistoryTests {
    private func track(_ id: String) -> LibraryTrack {
        LibraryTrack(id: id, folderID: "folder", relativePath: id + ".flac", title: id, artist: "Artist", albumArtist: "Artist",
            album: "Album", genre: "Rock", trackNumber: 1, discNumber: 1, year: nil, tagsJSON: nil, codec: "FLAC",
            bitDepth: 16, sampleRate: 44100, channels: 2, bitRate: nil, isLossless: true, isFloat: false,
            duration: 60, fileSize: 1024, modifiedAt: Date(), addedAt: Date(), artworkKey: nil, coverStamp: "", error: nil)
    }

    @Test func persistsRanksPagesAndSearchesBeforeLimiting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("history.sqlite").path
        let repository = try LibraryRepository(path: path)
        try await repository.saveFolder(LibraryFolder(id: "folder", path: root.path))
        try await repository.saveTracks([track("one"), track("two"), track("three")])
        try await repository.recordListen(trackID: "one", at: Date(timeIntervalSince1970: 100))
        try await repository.recordListen(trackID: "one", at: Date(timeIntervalSince1970: 90))
        try await repository.recordListen(trackID: "two", at: Date(timeIntervalSince1970: 200))
        try await repository.recordListen(trackID: "absent")
        let restored = try LibraryRepository(path: path)
        let recent = try await restored.listening(.recent, limit: 1)
        #expect(recent.songs.map(\.id) == ["two"] && recent.matchedCount == 2)
        #expect(recent.totalPlays == 3 && recent.uniqueSongs == 2)
        let popular = try await restored.listening(.mostPlayed)
        #expect(popular.songs.map(\.id) == ["one", "two"])
        #expect(popular.songs[0].playCount == 2 && popular.songs[0].lastPlayed == Date(timeIntervalSince1970: 100))
        #expect(try await restored.listening(.recent, limit: 1, search: "one").songs.map(\.id) == ["one"])
        try await restored.saveTracks([track("one")])
        #expect(try await restored.listening(.mostPlayed).totalPlays == 3)
    }

    @Test func forgottenFavouritesHiddenTracksClearAndFolderRemoval() async throws {
        let repository = try LibraryRepository(path: ":memory:")
        try await repository.saveFolder(LibraryFolder(id: "folder", path: "/tmp/music"))
        try await repository.saveTracks([track("old"), track("fresh"), track("never"), track("ordinary")])
        for id in ["old", "fresh", "never"] { try await repository.setFavorite(trackID: id, favorite: true) }
        let now = Date(timeIntervalSince1970: 10_000_000)
        try await repository.recordListen(trackID: "old", at: now.addingTimeInterval(-31 * 86400))
        try await repository.recordListen(trackID: "fresh", at: now)
        #expect(try await repository.listening(.forgotten, now: now).songs.map(\.id) == ["never", "old"])
        try await repository.removeTrackFromLibrary(trackID: "old")
        try await repository.recordListen(trackID: "old", at: now)
        #expect(try await repository.listening(.mostPlayed).totalPlays == 1)
        try await repository.restoreTracks(ids: ["old"])
        #expect(try await repository.listening(.mostPlayed).totalPlays == 2)
        try await repository.setFavorite(trackID: "old", favorite: true)
        try await repository.clearListeningHistory()
        #expect(try await repository.listening(.recent).totalPlays == 0)
        #expect(try await repository.listening(.forgotten, now: now).matchedCount == 3)
        #expect(try await repository.trackPreferences().favorites.count == 3)
        try await repository.recordListen(trackID: "old", at: now)
        try await repository.removeFolder("folder")
        #expect(try await repository.listening(.recent).totalPlays == 0)
    }
}
