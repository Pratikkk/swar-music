import Foundation
import Testing
@testable import Library

struct BrowsePreparationTests {
    private func track(_ id: String, title: String = "Song", artist: String = "Artist", album: String = "Album", number: Int = 1, disc: Int = 1, duration: Double = 60) -> LibraryTrack {
        LibraryTrack(id: id, folderID: "root", relativePath: id + ".wav", title: title,
            artist: artist, albumArtist: artist, album: album, genre: "Rock", trackNumber: number,
            discNumber: disc, year: "2026", tagsJSON: nil, codec: "PCM", bitDepth: 16,
            sampleRate: 44100, channels: 2, bitRate: nil, isLossless: true, isFloat: false,
            duration: duration, fileSize: 1024, modifiedAt: Date(timeIntervalSince1970: 0),
            addedAt: Date(timeIntervalSince1970: 0), artworkKey: nil, coverStamp: "", error: nil)
    }
    private func item(_ track: LibraryTrack, id: String? = nil, position: Int = 0) -> PlaylistTrackItem {
        PlaylistTrackItem(id: id ?? track.id, playlistID: "playlist", position: position, track: track)
    }

    @Test func artistsPreserveCompilationGroupingAndDiscOrder() async throws {
        var compilation = track("compilation", artist: "Soloist", album: "Anthology")
        compilation.albumArtist = "Various Artists"
        var laterDisc = track("later", title: "Song 1", artist: "Artist 2", number: 1, disc: 2)
        laterDisc.artworkKey = "cover.png"
        let source = [compilation, laterDisc,
            track("ten", title: "Song 10", artist: "Artist 2"),
            track("two", title: "Song 2", artist: "Artist 2"),
            track("other", artist: "Artist 10")]
        let result = try await ArtistBrowseArranger().arrange(source)
        #expect(result.map(\.name) == ["Artist 2", "Artist 10", "Various Artists"])
        let album = try #require(result.first?.albums.first)
        #expect(album.tracks.map(\.id) == ["two", "ten", "later"])
        #expect(album.songs.map(\.number) == [1, 2, 3])
        #expect(album.songs.map(\.startsDisc) == [false, false, true])
        #expect(album.minutes == 3 && album.artworkKey == "cover.png")
        #expect(result.last?.tracks.first?.artist == "Soloist")
        #expect(result.first?.artworkKey == "cover.png")
    }

    @Test func playlistFilteringRetainsOriginalNumbersAndDuplicateMembership() async throws {
        let shared = track("shared", title: "Café Morning", artist: "Björk")
        var broken = track("broken", title: "Cafe Evening")
        broken.error = "Unreadable"
        let source = [item(track("excluded", title: "Other")), item(shared, id: "first"),
                      item(broken), item(shared, id: "second")]
        let result = try await PlaylistBrowseArranger().arrange(source, search: "cafe", scope: .title)
        #expect(result.rows.map(\.id) == ["first", "broken", "second"])
        #expect(result.rows.map(\.number) == [2, 3, 4])
        #expect(result.rows.map(\.alternate) == [true, false, true])
        #expect(result.playableTracks.map(\.id) == ["shared", "shared"])
        #expect(result.durationDescription == "4 min")
        let artistOnly = try await PlaylistBrowseArranger().arrange(source, search: "bjork", scope: .artist)
        #expect(artistOnly.rows.map(\.id) == ["first", "second"])
    }

    @Test func changedSnapshotsDoNotReuseOldSearchResultsOrArtwork() async throws {
        let arranger = PlaylistBrowseArranger()
        var song = track("one", title: "Old", duration: 3600)
        song.artworkKey = "old.png"
        let first = try await arranger.arrange([item(song)], search: "old", scope: .title)
        #expect(first.rows.count == 1 && first.artworkKey == "old.png" && first.durationDescription == "1 hr 0 min")
        song.title = "New"; song.artworkKey = "new.png"
        let changed = try await arranger.arrange([item(song)], search: "old", scope: .title)
        #expect(changed.rows.isEmpty && changed.artworkKey == "new.png")
        let empty = try await arranger.arrange([], search: "", scope: .all)
        #expect(empty.rows.isEmpty && empty.playableTracks.isEmpty && empty.artworkKey == nil)
    }

    @Test func cancelledPreparationDoesNotPublishASnapshot() async throws {
        let source = [track("one")]
        let artists = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ArtistBrowseArranger().arrange(source)
        }
        await #expect(throws: CancellationError.self) { try await artists.value }
        let playlists = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PlaylistBrowseArranger().arrange(source.map { item($0) }, search: "", scope: .all)
        }
        await #expect(throws: CancellationError.self) { try await playlists.value }
    }

    @Test func indexedSearchMatchesExistingUnicodeAndFieldRules() {
        var song = track("folder/one", title: "Café विठ्ठल", artist: "Björk")
        song.albumArtist = "Various Artists"; song.album = "नाही Album"; song.genre = "Jazz"
        let document = TrackSearchDocument(song)
        for scope in TrackSearchScope.allCases {
            for text in ["", "cafe", "विठ्ठल", "नाही", "bjork", "Various bjork", "2026", "folder/one", "jazz", "--", "missing"] {
                let query = TrackSearchQuery(text)
                #expect(query.matches(song, scope: scope) == query.matches(document, scope: scope), "\(scope): \(text)")
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWAR_BROWSE_BENCHMARK"] == "1"))
    func largePlaylistPreparationBenchmark() async throws {
        let source = (0..<10000).map { item(track(String($0), title: "Song \($0)", artist: "Artist \($0 % 100)")) }
        let clock = ContinuousClock()
        let query = TrackSearchQuery("song 25")
        let oldStart = clock.now
        var oldCount = 0
        for _ in 0..<6 { oldCount += source.filter { query.matches($0.track) }.count }
        let oldTime = oldStart.duration(to: clock.now)
        let newStart = clock.now
        let arranger = PlaylistBrowseArranger()
        let snapshot = try await arranger.arrange(source, search: "song 25", scope: .all)
        let newTime = newStart.duration(to: clock.now)
        let warmStart = clock.now
        let warm = try await arranger.arrange(source, search: "song 250", scope: .all)
        let warmTime = warmStart.duration(to: clock.now)
        #expect(oldCount == snapshot.rows.count * 6)
        print("BROWSE BENCHMARK: 10,000 songs; six former filter passes \(oldTime); initial indexed snapshot \(newTime); subsequent query \(warmTime); \(snapshot.rows.count)/\(warm.rows.count) matches")
    }
}
