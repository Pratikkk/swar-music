import Foundation
import Testing
@testable import Library

struct PlaylistFileTests {
    @Test func parsesBOMCRLFRelativePathsFileURLsAndUnsupportedEntries() throws {
        let base = URL(fileURLWithPath: "/tmp/Playlists", isDirectory: true)
        let source = "\u{feff}#EXTM3U\r\n#EXTINF:123,Artist - Song\r\n../Music/मराठी #100%.flac\r\n../Music/मराठी #100%.flac\r\nfile:///tmp/Music/a%20b%23c.flac\r\nhttps://example.com/music.mp3\r\nC:\\Music\\song.mp3\r\nfile://otherhost/Music/song.flac\r\n.\\Album\\one.mp3\r\n\r\n"
        let entries = try PlaylistFile.parse(Data(source.utf8), relativeTo: base)
        #expect(entries.count == 7 && entries.map(\.id) == Array(0..<7))
        #expect(entries[0].url?.path == "/tmp/Music/मराठी #100%.flac")
        #expect(entries[0].url == entries[1].url)
        #expect(entries[2].url?.path == "/tmp/Music/a b#c.flac")
        #expect(entries[3].url == nil && entries[4].url == nil && entries[5].url == nil)
        #expect(entries[6].url?.path == "/tmp/Playlists/Album/one.mp3")
    }

    @Test func legacyM3UEncodingIsAcceptedButM3U8RequiresUTF8() throws {
        let data = Data([0x63, 0x61, 0x66, 0xe9, 0x2e, 0x6d, 0x70, 0x33])
        let base = URL(fileURLWithPath: "/tmp")
        #expect(try PlaylistFile.parse(data, relativeTo: base, strictUTF8: false).first?.url?.lastPathComponent == "café.mp3")
        #expect(throws: (any Error).self) { try PlaylistFile.parse(data, relativeTo: base) }
    }

    @Test func rejectsStreamingBinaryOversizedAndOverlongPlaylists() throws {
        let base = URL(fileURLWithPath: "/tmp")
        for source in ["#EXTM3U\n#EXT-X-TARGETDURATION:6\nsegment.ts", "song\0.wav", String(repeating: "a", count: 16_385)] {
            #expect(throws: (any Error).self) { try PlaylistFile.parse(Data(source.utf8), relativeTo: base) }
        }
        #expect(throws: (any Error).self) { try PlaylistFile.parse(Data(repeating: 32, count: PlaylistFile.maximumBytes + 1), relativeTo: base) }
        let source = Data(String(repeating: "song.wav\n", count: PlaylistFile.maximumEntries + 1).utf8)
        #expect(throws: (any Error).self) { try PlaylistFile.parse(source, relativeTo: base) }
    }

    @Test func absoluteAndRelativeRoundTripsPreserveOrderDuplicatesAndUnicode() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = ["Music/मराठी #100%.wav", "#first.wav", "a:b.wav", "trailing space ", "Music/मराठी #100%.wav"]
            .map { base.appendingPathComponent($0) }
        let entries = files.map { PlaylistExportEntry(url: $0, title: "Song\n#bad", artist: "Artist\rname", duration: 123.5) }
        for relative in [false, true] {
            let data = try PlaylistFile.encode(entries, relativeTo: relative ? base : nil)
            let parsed = try PlaylistFile.parse(data, relativeTo: base)
            #expect(parsed.map(\.url) == files.map { Optional($0.standardizedFileURL) })
            #expect(String(decoding: data, as: UTF8.self).contains("#EXTINF:123,Artist name - Song #bad"))
        }
        #expect(try PlaylistFile.parse(PlaylistFile.encode([]), relativeTo: base).isEmpty)
    }

    @Test func resolvesFolderAliasesWithoutMatchingOutsidePrefixNeighbours() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = root.appendingPathComponent("Music")
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: music.appendingPathComponent("one.wav"))
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: music)
        let entries = try PlaylistFile.parse(Data("Alias/one.wav\nMusic-other/two.wav\nMusic/one.wav\nhttps://example.com/three.wav".utf8), relativeTo: root)
        #expect(try PlaylistFile.trackIDs(for: entries, roots: ["folder": music]) == ["folder:one.wav", nil, "folder:one.wav", nil])
    }

    @Test func fileReadWriteAndRejectedExportPreserveExistingData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Test.M3U8")
        let entry = PlaylistExportEntry(url: root.appendingPathComponent("one.wav"), title: "One", artist: "", duration: .nan)
        try PlaylistFile.write([entry], to: target, relativePaths: true)
        #expect(try PlaylistFile.read(target).first?.url == entry.url)
        let original = try Data(contentsOf: target)
        let bad = PlaylistExportEntry(url: root.appendingPathComponent("bad\nfile.wav"), title: "", artist: "", duration: 1)
        #expect(throws: (any Error).self) { try PlaylistFile.write([bad], to: target, relativePaths: false) }
        #expect(try Data(contentsOf: target) == original)
    }

    @MainActor @Test func importExportRoundTripMatchesFullLibraryAndPersistsMembership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = root.appendingPathComponent("Music")
        let store = root.appendingPathComponent("Store")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DecodingTests/Fixtures/44100-16.wav")
        for file in ["one.wav", "दोन.wav"] { try FileManager.default.copyItem(at: fixture, to: music.appendingPathComponent(file)) }
        let source = root.appendingPathComponent("Imported.m3u8")
        let data = Data("#EXTM3U\nMusic/दोन.wav\nMusic/missing.wav\nMusic/one.wav\nhttps://example.com/live\nMusic/दोन.wav\n".utf8)
        try data.write(to: source)
        let library = LibraryModel(storageDirectory: store)
        await library.start()
        await library.addFolder(music)
        library.search = "does not match"
        await library.reload()
        let preview = try await library.previewPlaylistImport(from: source)
        #expect(preview.name == "Imported" && preview.draft.trackIDs.count == 3 && preview.draft.skippedCount == 2)
        #expect(preview.items[1].track == nil && preview.items[3].entry.url == nil)
        let imported = try await library.saveQueuePlaylist(name: preview.name, draft: preview.draft)
        let exported = try await library.playlistExportEntries(for: imported)
        #expect(exported.map(\.url.lastPathComponent) == ["दोन.wav", "one.wav", "दोन.wav"])
        let target = root.appendingPathComponent("Roundtrip.m3u8")
        try PlaylistFile.write(exported, to: target, relativePaths: true)
        let again = try await library.previewPlaylistImport(from: target)
        #expect(again.draft.trackIDs == preview.draft.trackIDs && again.draft.skippedCount == 0)
        #expect(await library.overview()?.trackCount == 2)
        #expect(library.playlists.count == 1)
        #expect(try Data(contentsOf: source) == data)
        #expect(try Data(contentsOf: music.appendingPathComponent("one.wav")) == Data(contentsOf: fixture))
        library.shutdown()
        let restored = LibraryModel(storageDirectory: store)
        await restored.start()
        defer { restored.shutdown() }
        #expect(try await restored.playlistItems(for: imported.id).map(\.track.id) == preview.draft.trackIDs)
    }

    @MainActor @Test func importSkipsHiddenTracksAndStalePreviewCannotCreatePartialPlaylist() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let music = root.appendingPathComponent("Music")
        try FileManager.default.createDirectory(at: music, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("DecodingTests/Fixtures/44100-16.wav")
        try FileManager.default.copyItem(at: fixture, to: music.appendingPathComponent("one.wav"))
        let file = root.appendingPathComponent("Test.m3u8")
        try Data("Music/one.wav\n".utf8).write(to: file)
        let library = LibraryModel(storageDirectory: root.appendingPathComponent("Store"))
        await library.start(); await library.addFolder(music)
        defer { library.shutdown() }
        let preview = try await library.previewPlaylistImport(from: file)
        let track = try #require(library.tracks.first)
        await library.removeTrackFromLibrary(track)
        let hidden = try await library.previewPlaylistImport(from: file)
        #expect(hidden.draft.trackIDs.isEmpty && hidden.draft.skippedCount == 1)
        await #expect(throws: (any Error).self) { try await library.saveQueuePlaylist(name: "Stale", draft: preview.draft) }
        #expect(library.playlists.isEmpty)
    }
}
