import Foundation

/// Sorting happens before pagination, so every loaded page shares one order.
public enum TrackSortOrder: String, CaseIterable, Identifiable, Sendable {
    case album = "Album"
    case title = "Song Title"
    case artist = "Artist"
    case duration = "Duration"
    case recentlyAdded = "Recently Added"

    public var id: Self { self }

    func sqlOrder(reversed: Bool) -> String {
        let direction = reversed ? " DESC" : " ASC"
        let primary: String
        switch self {
        case .album: primary = "albumArtist COLLATE NOCASE" + direction + ", album COLLATE NOCASE" + direction
        case .title: primary = "title COLLATE NOCASE" + direction
        case .artist: primary = "artist COLLATE NOCASE" + direction
        case .duration: primary = "duration" + direction
        case .recentlyAdded: primary = "addedAt" + (reversed ? " ASC" : " DESC")
        }
        // Stable tie-breakers prevent tied records from swapping across reloads.
        return primary + ", albumArtist COLLATE NOCASE, album COLLATE NOCASE, discNumber, trackNumber, title COLLATE NOCASE, id"
    }
}
