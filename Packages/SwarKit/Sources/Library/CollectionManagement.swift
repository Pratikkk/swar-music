import Foundation

public enum CollectionFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All Songs"
    case incomplete = "Incomplete Details"
    case artwork = "Missing Artwork"
    case duplicates = "Possible Duplicates"
    case missing = "Missing Files"
    case unreadable = "Unreadable"
    case removed = "Removed"
    public var id: Self { self }
}

public struct CollectionSummary: Sendable {
    public let songs: Int
    public let albums: Int
    public let bytes: Int64
    public let duration: Double
    public let incomplete: Int
    public let artwork: Int
    public let duplicates: Int
    public let missing: Int
    public let unreadable: Int
    public let removed: Int
    public func count(_ filter: CollectionFilter) -> Int {
        switch filter {
        case .all: songs
        case .incomplete: incomplete
        case .artwork: artwork
        case .duplicates: duplicates
        case .missing: missing
        case .unreadable: unreadable
        case .removed: removed
        }
    }
}

public struct CollectionPage: Sendable {
    public let summary: CollectionSummary
    public let tracks: [LibraryTrack]
    public let count: Int
}

/// Library-only metadata. File tags and scan fingerprints remain independent.
public struct TrackMetadata: Codable, Sendable, Equatable {
    public var title: String
    public var artist: String
    public var albumArtist: String
    public var album: String
    public var genre: String
    public var year: String
    public var trackNumber: Int
    public var discNumber: Int

    public init(track: LibraryTrack) {
        title = track.title; artist = track.artist; albumArtist = track.albumArtist
        album = track.album; genre = track.genre; year = track.year ?? ""
        trackNumber = track.trackNumber; discNumber = track.discNumber
    }

    func validated() throws -> Self {
        var result = self
        result.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        result.artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        result.albumArtist = albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        result.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        result.genre = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        result.year = year.trimmingCharacters(in: .whitespacesAndNewlines)
        guard [result.title, result.artist, result.albumArtist, result.album].allSatisfy({ !$0.isEmpty }) else {
            throw LibraryFailure("Title, artist, album artist, and album are required.")
        }
        guard [result.title, result.artist, result.albumArtist, result.album, result.genre, result.year].allSatisfy({ $0.count <= 1024 }),
              (0...9999).contains(trackNumber), (1...9999).contains(discNumber) else {
            throw LibraryFailure("Use shorter details, a track number from 0–9999, and a disc number from 1–9999.")
        }
        return result
    }

    func apply(to track: inout LibraryTrack) {
        track.title = title; track.artist = artist; track.albumArtist = albumArtist
        track.album = album; track.genre = genre.isEmpty ? "Unknown Genre" : genre
        track.year = year.isEmpty ? nil : year; track.trackNumber = trackNumber; track.discNumber = discNumber
    }
}

        
/// Information for comparing *candidate* duplicates; metadata similarity is not
/// proof of identical audio content. Never use these details for auto-deletion.
public enum DuplicateReview {
    public static func details(for track: LibraryTrack) -> String {
        var parts: [String] = []
        parts.append(track.isLossless ? "Lossless" : "Lossy")
        if let codec = track.codec, !codec.isEmpty { parts.append(codec) }
        if let depth = track.bitDepth, depth > 0 { parts.append("\(depth)-bit") }
        if let rate = track.sampleRate, rate.isFinite, rate > 0 {
            parts.append(String(format: "%g kHz", rate / 1000))
        }
        if let bitrate = track.bitRate, bitrate > 0 {
            parts.append("\(bitrate / 1000) kbps")
        }
        if track.fileSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: track.fileSize, countStyle: .file))
        }
        if track.duration.isFinite, track.duration > 0 {
            let seconds = Int(track.duration.rounded())
            parts.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
        return parts.joined(separator: " · ")
    }
}
