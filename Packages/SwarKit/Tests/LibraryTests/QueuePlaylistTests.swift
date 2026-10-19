import Foundation
import Testing
@testable import Library

struct QueuePlaylistTests {
    private func track(_ id: String) -> LibraryTrack {
        LibraryTrack(id: id, folderID: "folder", relativePath: id + ".wav", title: id, artist: "Artist", albumArtist: "Artist",
            album: "Album", genre: "", trackNumber: 1, discNumber: 1, year: nil, tagsJSON: nil, codec: "PCM",
            bitDepth: 16, sampleRate: 44100, channels: 2, bitRate: nil, isLossless: true, isFloat: false,
            duration: 10, fileSize: 1024, modifiedAt: Date(), addedAt: Date(), artworkKey: nil, coverStamp: "", error: nil)
    }

    @Test func savesOrderAndDuplicatesAndReportsExcludedEntries() async throws {
        let repository = try LibraryRepository(path: ":memory:")
        try await repository.saveFolder(LibraryFolder(id: "folder", path: "/tmp/music"))
        try await repository.saveTracks([track("one"), track("two"), track("hidden")])
        try await repository.removeTrackFromLibrary(trackID: "hidden")
        let draft = try await repository.queuePlaylistDraft(trackIDs: ["two", "hidden", "absent", "one", "two"], sourceCount: 6)
        #expect(draft.trackIDs == ["two", "one", "two"] && draft.skippedCount == 3)
        let playlist = try await repository.createQueuePlaylist(name: "  My Queue  ", draft: draft)
        let items = try await repository.playlistTrackItems(playlistID: playlist.id)
        #expect(playlist.name == "My Queue" && items.map(\.track.id) == draft.trackIDs)
        #expect(Set(items.map(\.id)).count == 3)
    }

    @Test func stalePreviewRollsBackPlaylistAndAllMembership() async throws {
        let repository = try LibraryRepository(path: ":memory:")
        try await repository.saveFolder(LibraryFolder(id: "folder", path: "/tmp/music"))
        try await repository.saveTracks([track("one"), track("two")])
        let draft = try await repository.queuePlaylistDraft(trackIDs: ["one", "two"], sourceCount: 2)
        try await repository.removeTrackFromLibrary(trackID: "two")
        await #expect(throws: (any Error).self) { try await repository.createQueuePlaylist(name: "Stale", draft: draft) }
        #expect(try await repository.playlists().isEmpty)
        let empty = try await repository.queuePlaylistDraft(trackIDs: ["absent"], sourceCount: 1)
        await #expect(throws: (any Error).self) { try await repository.createQueuePlaylist(name: "Empty", draft: empty) }
        #expect(try await repository.playlists().isEmpty)
    }

    @MainActor @Test func modelResolvesQueueFilesIndependentlyOfCurrentSearch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = root.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DecodingTests/Fixtures/44100-16.wav")
        let song = music.appendingPathComponent("one.wav")
        try FileManager.default.copyItem(at: fixture, to: song)
        let model = LibraryModel(storageDirectory: root.appendingPathComponent("Store"))
        await model.start()
        await model.addFolder(music)
        defer { model.shutdown() }
        model.search = "no match"
        await model.reload()
        let draft = try await model.queuePlaylistDraft(urls: [song, root.appendingPathComponent("outside.wav"), song])
        #expect(draft.trackIDs.count == 2 && draft.skippedCount == 1)
        let playlist = try await model.saveQueuePlaylist(name: "Saved", draft: draft)
        #expect(model.playlists.contains { $0.id == playlist.id })
        #expect(try await model.playlistItems(for: playlist.id).count == 2)
    }
}
