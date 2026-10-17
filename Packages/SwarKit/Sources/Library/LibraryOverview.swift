import Foundation

public struct LibraryAlbumSummary: Identifiable, Sendable, Equatable {
    public var id: String { artist + "\u{1f}" + title }
    public let title: String
    public let artist: String
    public let artworkKey: String?
    public let trackCount: Int
    public let playableCount: Int
    public let year: String?
    public let addedAt: Date
    public let duration: Double

    public init(title: String, artist: String, artworkKey: String?, trackCount: Int,
                playableCount: Int, year: String? = nil, addedAt: Date = .distantPast, duration: Double = 0) {
        self.title = title; self.artist = artist; self.artworkKey = artworkKey
        self.trackCount = trackCount; self.playableCount = playableCount
        self.year = year; self.addedAt = addedAt; self.duration = duration
    }
}

public struct LibraryOverview: Sendable, Equatable {
    public let trackCount: Int
    public let albumCount: Int
    public let losslessCount: Int
    public let favourites: [LibraryTrack]
    public let recentAlbums: [LibraryAlbumSummary]
}
