import Foundation

public struct LibraryArtworkChange: Sendable {
    public let fileURL: URL
    public let artworkURL: URL?
    public init(fileURL: URL, artworkURL: URL?) { self.fileURL = fileURL; self.artworkURL = artworkURL }
}

public struct ArtworkSelection: Sendable {
    public let customCount: Int
    public let originalKey: String?
}
