import Decoding
import Foundation

/// Lightweight presentation for files opened outside the library. Call off the UI actor.
public struct TrackPresentation: Sendable {
    public let title: String?
    public let subtitle: String
    public let artworkURL: URL?

    public static func read(url: URL, artworkDirectory: URL? = nil, codecDirectory: URL? = nil) -> TrackPresentation? {
        guard let metadata = try? FFmpegDecoder(url: url, codecDirectory: codecDirectory) else { return nil }
        let subtitle = [metadata.tag("artist"), metadata.tag("album")].compactMap { $0 }.joined(separator: " · ")
        let cache = artworkDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Swar/Artwork", isDirectory: true)
        let parent = url.deletingLastPathComponent()
        let external = ["cover.jpg", "folder.jpg", "front.png"].map { parent.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        let artwork = metadata.embeddedArtwork ?? external.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
        var artworkURL: URL?
        if let artwork, let cache,
           let key = try? MediaInspector(codecDirectory: codecDirectory, artworkDirectory: cache).cacheArtwork(artwork) {
            artworkURL = cache.appendingPathComponent(key)
        }
        return TrackPresentation(title: metadata.tag("title"), subtitle: subtitle, artworkURL: artworkURL)
    }
}
