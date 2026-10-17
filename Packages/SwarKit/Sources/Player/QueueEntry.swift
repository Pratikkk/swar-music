import Foundation

/// Each insertion has its own identity, so the same track can appear more than once.
public struct QueueEntry: Identifiable, Sendable, Equatable, Codable {
    public let id: UUID
    public let url: URL
    public let accessRoot: URL
    public let title: String
    public let subtitle: String
    public internal(set) var artworkURL: URL?
    public let artist: String?
    public let album: String?
    public internal(set) var error: String?

    public init(url: URL, accessRoot: URL? = nil, title: String? = nil, subtitle: String = "", artworkURL: URL? = nil,
                artist: String? = nil, album: String? = nil, id: UUID = UUID()) {
        self.id = id
        self.url = url
        self.accessRoot = accessRoot ?? url
        self.title = title ?? url.deletingPathExtension().lastPathComponent
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.artist = artist
        self.album = album
    }
}

public enum RepeatMode: String, CaseIterable, Sendable, Codable {
    case off = "Off"
    case all = "All"
    case one = "One"
}
