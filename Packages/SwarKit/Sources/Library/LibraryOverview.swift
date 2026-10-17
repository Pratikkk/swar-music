import Foundation

public struct LibraryAlbumSummary: Identifiable, Sendable, Equatable {
    public var id: String { artist + "\u{1f}" + title }
    public let title: String
    public let artist: String
    public let artworkKey: String?
    public let trackCount: Int
    public let playableCount: Int
}

public struct LibraryOverview: Sendable, Equatable {
    public let trackCount: Int
    public let albumCount: Int
    public let losslessCount: Int
    public let favourites: [LibraryTrack]
    public let recentAlbums: [LibraryAlbumSummary]
}
