import Foundation
import Library
import Testing

struct AlbumBrowseArrangerTests {
    private func album(_ title: String, artist: String = "Artist", year: String? = nil,
                       lossless: Int = 0, artwork: String? = nil, added: Date = .distantPast) -> LibraryAlbumSummary {
        LibraryAlbumSummary(title: title, artist: artist, artworkKey: artwork, trackCount: 2,
            playableCount: 2, year: year, addedAt: added, losslessTrackCount: lossless)
    }

    @Test func naturalSortingYearsAndReverseOrder() async throws {
        let arranger = AlbumBrowseArranger()
        let source = [album("Album 10", artist: "B", year: "2024"), album("Album 2", artist: "A", year: "2020"), album("Album 1")]
        let titles = try await arranger.arrange(source, sort: .title, reversed: false, recent: false, filter: .all)
        #expect(titles.sections[0].albums.map(\.title) == ["Album 1", "Album 2", "Album 10"])
        let years = try await arranger.arrange(source, sort: .year, reversed: false, recent: false, filter: .all)
        #expect(years.sections[0].albums.map(\.title) == ["Album 10", "Album 2", "Album 1"])
        let reversed = try await arranger.arrange(source, sort: .title, reversed: true, recent: false, filter: .all)
        #expect(reversed.sections[0].albums.map(\.id) == titles.sections[0].albums.reversed().map(\.id))
    }

    @Test func filtersKeepWholeAlbumsAndAccurateCounts() async throws {
        let arranger = AlbumBrowseArranger()
        let source = [album("Lossless", lossless: 2, artwork: "cover"), album("Mixed", lossless: 1), album("Lossy", artwork: "")]
        let lossless = try await arranger.arrange(source, sort: .artist, reversed: false, recent: false, filter: .lossless)
        #expect(lossless.albumCount == 1 && lossless.totalAlbumCount == 3 && lossless.songCount == 2)
        #expect(lossless.sections[0].albums.first?.title == "Lossless")
        let missing = try await arranger.arrange(source, sort: .title, reversed: false, recent: false, filter: .missingArtwork)
        #expect(Set(missing.sections[0].albums.map(\.title)) == ["Mixed", "Lossy"])
        #expect(missing.albumCount == 2 && missing.songCount == 4)
        let empty = try await arranger.arrange([], sort: .artist, reversed: false, recent: false, filter: .all)
        #expect(empty.albumCount == 0 && empty.songCount == 0)
    }

    @Test func monthGroupingUsesStableCalendarBoundariesAndNewestFirst() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        func date(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: day))! }
        let source = [album("January", added: date(1, 31)), album("February", added: date(2, 1)), album("New", added: date(2, 10))]
        let result = try await AlbumBrowseArranger().arrange(source, sort: .title, reversed: true,
            recent: true, filter: .all, now: date(2, 15), calendar: calendar)
        #expect(result.sections.count == 2)
        #expect(result.sections[0].title == "This Month")
        #expect(result.sections[0].albums.map(\.title) == ["New", "February"])
        #expect(result.sections[1].albums.map(\.title) == ["January"])
        #expect(Set(result.sections.map(\.id)).count == 2)
    }

    @Test func largeCollectionsAndCancelledArrangement() async throws {
        let arranger = AlbumBrowseArranger()
        let source = (0..<10_000).reversed().map { album("Album \($0)", lossless: $0.isMultiple(of: 2) ? 2 : 0) }
        let result = try await arranger.arrange(source, sort: .title, reversed: false, recent: false, filter: .lossless)
        #expect(result.albumCount == 5_000 && result.totalAlbumCount == 10_000 && result.songCount == 10_000)
        #expect(result.sections[0].albums.first?.title == "Album 0")
        #expect(result.sections[0].albums.last?.title == "Album 9998")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await arranger.arrange(source, sort: .title, reversed: false, recent: false, filter: .all)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
    }
}
