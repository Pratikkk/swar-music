import Foundation

public enum AlbumSortOrder: String, CaseIterable, Identifiable, Sendable {
    case title = "Album Title", artist = "Artist", year = "Release Year", recentlyAdded = "Recently Added"
    public var id: Self { self }
}

public enum AlbumBrowseFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All Albums", lossless = "Lossless", missingArtwork = "Missing Artwork"
    public var id: Self { self }
}

public struct AlbumBrowseSection: Identifiable, Sendable {
    public let id: String
    public let title: String
    public var albums: [LibraryAlbumSummary]
}

public struct AlbumBrowseSnapshot: Sendable {
    public let sections: [AlbumBrowseSection]
    public let albumCount: Int
    public let totalAlbumCount: Int
    public let songCount: Int
    public var summary: String {
        let count = albumCount == totalAlbumCount ? "\(albumCount)" : "\(albumCount) of \(totalAlbumCount)"
        return "\(count) \(totalAlbumCount == 1 ? "album" : "albums") · \(songCount) \(songCount == 1 ? "song" : "songs")"
    }
}

/// Preserves repository order while filtering and grouping off the UI actor.
public actor AlbumBrowseArranger {
    public init() { }
    public func arrange(_ source: [LibraryAlbumSummary], recent: Bool, filter: AlbumBrowseFilter, now: Date = Date(),
                        calendar: Calendar = .current) throws -> AlbumBrowseSnapshot {
        try Task.checkCancellation()
        let albums = source.filter { album in
            switch filter {
            case .all: true
            case .lossless: album.trackCount > 0 && album.losslessTrackCount == album.trackCount
            case .missingArtwork: album.artworkKey?.isEmpty != false
            }
        }
        try Task.checkCancellation()
        var sections: [AlbumBrowseSection] = []
        if recent {
            var indices: [Date: Int] = [:]
            var monthStyle = Date.FormatStyle().month(.wide).year()
            monthStyle.calendar = calendar
            monthStyle.timeZone = calendar.timeZone
            for album in albums {
                try Task.checkCancellation()
                let month = calendar.dateInterval(of: .month, for: album.addedAt)?.start ?? album.addedAt
                if let index = indices[month] { sections[index].albums.append(album) }
                else {
                    indices[month] = sections.count
                    let title = calendar.isDate(month, equalTo: now, toGranularity: .month)
                        ? "This Month" : month.formatted(monthStyle)
                    sections.append(AlbumBrowseSection(id: String(month.timeIntervalSince1970), title: title, albums: [album]))
                }
            }
        } else { sections = [AlbumBrowseSection(id: "all", title: "Albums", albums: albums)] }
        return AlbumBrowseSnapshot(sections: sections, albumCount: albums.count, totalAlbumCount: source.count,
                                   songCount: albums.reduce(0) { $0 + $1.trackCount })
    }
}
