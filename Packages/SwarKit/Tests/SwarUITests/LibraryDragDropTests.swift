import AppKit
import Foundation
import Testing
import Library
import Player
@testable import SwarUI

struct LibraryDragDropTests {
    @Test func rejectsMalformedOversizedAndRemoteReferences() throws {
        #expect(LibrarySongDrag.url(from: Data("not json".utf8)) == nil)
        #expect(LibrarySongDrag.url(from: Data(repeating: 0, count: 65_537)) == nil)
        #expect(LibrarySongDrag.url(from: try JSONEncoder().encode(URL(string: "https://example.com/song.flac")!)) == nil)
        let file = URL(fileURLWithPath: "/tmp/Music/गीत #1.wav")
        #expect(LibrarySongDrag.url(from: try JSONEncoder().encode(file)) == file)
    }

    @Test @MainActor func resolvesBeyondVisiblePagePreservesOrderAndRejectsRemovedTracks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = root.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DecodingTests/Fixtures/44100-16.wav")
        for name in ["one.wav", "two.wav"] {
            try FileManager.default.copyItem(at: fixture, to: music.appendingPathComponent(name))
        }
        let library = LibraryModel(storageDirectory: root.appendingPathComponent("Database"))
        await library.start()
        defer { library.shutdown() }
        await library.addFolder(music)
        #expect(library.errorMessage == nil)
        let one = try #require(await library.track(at: music.appendingPathComponent("one.wav")))
        let two = try #require(await library.track(at: music.appendingPathComponent("two.wav")))
        let providers = [two, one, two].map { LibrarySongDrag.provider(for: $0, library: library) }
        library.search = "no matching song"
        await library.reload()
        #expect(library.tracks.isEmpty)
        let tracks = try await LibrarySongDrag.tracks(from: providers, library: library)
        #expect(tracks.map(\.id) == [two.id, one.id, two.id])
        let playlist = try #require(await library.createPlaylist(name: "Dropped Songs"))
        await library.addTracks(tracks, to: playlist)
        #expect(await library.playlistTracks(for: playlist.id).map(\.track.id) == [two.id, one.id, two.id])
        let player = Player()
        defer { player.shutdown() }
        LibraryQueueActions.enqueue(tracks, next: false, library: library, player: player)
        #expect(player.queue.map(\.url.lastPathComponent) == ["two.wav", "one.wav", "two.wav"])
        await library.removeTrackFromLibrary(one)
        await #expect(throws: (any Error).self) {
            try await LibrarySongDrag.tracks(from: providers, library: library)
        }
    }
}
