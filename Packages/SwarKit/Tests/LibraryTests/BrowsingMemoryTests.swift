import Foundation
import Darwin
import Testing
@testable import Library

struct BrowsingMemoryTests {
    private func track(_ index: Int, tags: String) -> LibraryTrack {
        LibraryTrack(id: "browse-\(index)", folderID: "folder", relativePath: "\(index).wav",
            title: String(format: "Song %05d", index), artist: "Artist", albumArtist: "Artist",
            album: "Album", genre: "Ambient", trackNumber: index + 1, discNumber: 1,
            year: "2026", tagsJSON: tags, codec: "PCM", bitDepth: 24, sampleRate: 96000,
            channels: 2, bitRate: nil, isLossless: true, isFloat: false, duration: 180,
            fileSize: 1024, modifiedAt: Date(timeIntervalSince1970: 1000),
            addedAt: Date(timeIntervalSince1970: 1000), artworkKey: nil, coverStamp: "", error: nil)
    }

    @Test func displayQueriesPreserveMetadataAndStoredTagPayload() async throws {
        let repository = try LibraryRepository(path: ":memory:")
        try await repository.saveFolder(LibraryFolder(id: "folder", path: "/tmp/music"))
        let tags = "{\"title\":\"Original\",\"lyrics\":\"" + String(repeating: "lyric ", count: 2000) + "\"}"
        try await repository.saveTracks((0..<12).map { track($0, tags: tags) })
        let full = try await repository.page()
        let light = try await repository.page(includeTagPayload: false)
        let expected = full.tracks.map { original in
            var result = original; result.tagsJSON = nil; return result
        }
        #expect(light.tracks == expected)
        #expect(light.count == full.count && light.unreadableCount == full.unreadableCount)
        #expect(try await repository.albumTracks(artist: "Artist", title: "Album", includeTagPayload: false) == expected)
        let collection = try await repository.collectionPage(includeTagPayload: false)
        #expect(collection.tracks == expected)
        let completeCollection = try await repository.collectionPage()
        for filter in CollectionFilter.allCases {
            #expect(collection.summary.count(filter) == completeCollection.summary.count(filter))
        }
        #expect(collection.summary.bytes == completeCollection.summary.bytes)
        #expect(collection.summary.duration == completeCollection.summary.duration)
        #expect(try await repository.visibleTrack(id: "browse-0")?.tagsJSON == tags)
        #expect(try await repository.page(search: "Song 00011", includeTagPayload: false).tracks.map(\.id) == ["browse-11"])
        #expect(try await repository.page(limit: 2, offset: 10, includeTagPayload: false).tracks.map(\.id) == ["browse-10", "browse-11"])
    }

    // Opt-in, separate processes for comparable peak RSS (no compiler in the measured process).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWAR_BROWSE_BENCHMARK"] != nil))
    func largeTagPayloadBenchmark() async throws {
        let mode = try #require(ProcessInfo.processInfo.environment["SWAR_BROWSE_BENCHMARK"])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try LibraryRepository(path: folder.appendingPathComponent("Library.sqlite").path)
        try await repository.saveFolder(LibraryFolder(id: "folder", path: "/tmp/music"))
        let tags = "{\"lyrics\":\"" + String(repeating: "x", count: 65_536) + "\"}"
        try await repository.saveTracks((0..<1000).map { track($0, tags: tags) })
        let start = ContinuousClock.now
        let page = try await repository.page(limit: 1000, includeTagPayload: mode == "full")
        let elapsed = ContinuousClock.now - start
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let payloadBytes = page.tracks.reduce(0) { $0 + ($1.tagsJSON?.utf8.count ?? 0) }
        print("BROWSE_BENCH mode=\(mode) tracks=\(page.tracks.count) payloadBytes=\(payloadBytes) query=\(elapsed) peakRSSBytes=\(usage.ru_maxrss)")
        #expect(page.tracks.count == 1000)
        #expect(payloadBytes == (mode == "full" ? tags.utf8.count * 1000 : 0))
    }
}
