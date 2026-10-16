import Foundation

/// Each insertion has its own identity, so the same track can appear more than once.
public struct QueueEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let url: URL
    public let accessRoot: URL
    public let title: String
    public let subtitle: String
    public let artworkURL: URL?
    public internal(set) var error: String?

    public init(url: URL, accessRoot: URL? = nil, title: String? = nil, subtitle: String = "", artworkURL: URL? = nil) {
        id = UUID()
        self.url = url
        self.accessRoot = accessRoot ?? url
        self.title = title ?? url.deletingPathExtension().lastPathComponent
        self.subtitle = subtitle
        self.artworkURL = artworkURL
    }
}

public enum RepeatMode: String, CaseIterable, Sendable {
    case off = "Off"
    case all = "All"
    case one = "One"
}
