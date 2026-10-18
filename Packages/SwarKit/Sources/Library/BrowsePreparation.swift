import Foundation

public struct ArtistBrowseSong: Identifiable, Sendable {
    public var id: String { track.id }
    public let track: LibraryTrack
    public let number: Int
    public let startsDisc: Bool
}

public struct ArtistBrowseAlbum: Identifiable, Sendable {
    public var id: String { title }
    public let title: String
    public let tracks: [LibraryTrack]
    public let songs: [ArtistBrowseSong]
    public let artworkKey: String?
    public let minutes: Int
}

public struct ArtistBrowseCollection: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let albums: [ArtistBrowseAlbum]
    public let tracks: [LibraryTrack]
    public let artworkKey: String?
}

/// Grouping, natural sorting and row preparation never occupy the UI actor.
public actor ArtistBrowseArranger {
    public init() { }

    public func arrange(_ tracks: [LibraryTrack]) throws -> [ArtistBrowseCollection] {
        try Task.checkCancellation()
        var result: [ArtistBrowseCollection] = []
        for (name, tracks) in Dictionary(grouping: tracks, by: { $0.albumArtist.isEmpty ? $0.artist : $0.albumArtist }) {
            try Task.checkCancellation()
            var albums: [ArtistBrowseAlbum] = []
            for (title, tracks) in Dictionary(grouping: tracks, by: \.album) {
                try Task.checkCancellation()
                let ordered = tracks.sorted {
                    if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                    if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                    let comparison = $0.title.localizedStandardCompare($1.title)
                    return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
                }
                let songs = ordered.enumerated().map { index, track in
                    ArtistBrowseSong(track: track, number: index + 1,
                        startsDisc: index > 0 && track.discNumber != ordered[index - 1].discNumber)
                }
                let seconds = ordered.reduce(0) { $0 + ($1.duration.isFinite ? max(0, $1.duration) : 0) }
                let minutes = ceil(seconds / 60)
                albums.append(ArtistBrowseAlbum(title: title, tracks: ordered, songs: songs,
                    artworkKey: ordered.first { $0.artworkKey != nil }?.artworkKey,
                    minutes: minutes.isFinite && minutes < Double(Int.max) ? Int(minutes) : 0))
            }
            albums.sort {
                let comparison = $0.title.localizedStandardCompare($1.title)
                return comparison == .orderedSame ? $0.title < $1.title : comparison == .orderedAscending
            }
            let ordered = albums.flatMap(\.tracks)
            result.append(ArtistBrowseCollection(name: name, albums: albums, tracks: ordered,
                artworkKey: ordered.first { $0.artworkKey != nil }?.artworkKey))
        }
        result.sort {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.name < $1.name : comparison == .orderedAscending
        }
        try Task.checkCancellation()
        return result
    }
}

public struct PlaylistBrowseRow: Identifiable, Sendable {
    public var id: String { item.id }
    public let item: PlaylistTrackItem
    public let number: Int
    public let alternate: Bool
}

public struct PlaylistBrowseSnapshot: Sendable {
    public let rows: [PlaylistBrowseRow]
    public let playableTracks: [LibraryTrack]
    public let artworkKey: String?
    public let durationDescription: String
}

/// Filtering runs once per changed query/data snapshot, rather than per view update.
public actor PlaylistBrowseArranger {
    private var indexedItems: [PlaylistTrackItem] = []
    private var documents: [TrackSearchDocument] = []
    public init() { }

    public func arrange(_ items: [PlaylistTrackItem], search: String, scope: TrackSearchScope) throws -> PlaylistBrowseSnapshot {
        try Task.checkCancellation()
        if indexedItems != items {
            var prepared: [TrackSearchDocument] = []
            prepared.reserveCapacity(items.count)
            for (index, item) in items.enumerated() {
                if index.isMultiple(of: 64) { try Task.checkCancellation() }
                prepared.append(TrackSearchDocument(item.track))
            }
            try Task.checkCancellation()
            documents = prepared; indexedItems = items
        }
        let query = TrackSearchQuery(search)
        var rows: [PlaylistBrowseRow] = []
        var playable: [LibraryTrack] = []
        var seconds = 0.0
        var artworkKey: String?
        for (index, item) in items.enumerated() {
            if index.isMultiple(of: 64) { try Task.checkCancellation() }
            if item.track.duration.isFinite { seconds += max(0, item.track.duration) }
            if artworkKey == nil { artworkKey = item.track.artworkKey }
            if query.matches(documents[index], scope: scope) {
                rows.append(PlaylistBrowseRow(item: item, number: index + 1, alternate: rows.count.isMultiple(of: 2)))
                if item.track.error == nil { playable.append(item.track) }
            }
        }
        let minutes = seconds.isFinite && seconds < Double(Int.max) ? Int(seconds) / 60 : 0
        let duration = minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
        try Task.checkCancellation()
        return PlaylistBrowseSnapshot(rows: rows, playableTracks: playable,
                                      artworkKey: artworkKey, durationDescription: duration)
    }
}
