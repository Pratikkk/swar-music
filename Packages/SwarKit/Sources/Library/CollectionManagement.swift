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

        
/// Only non-nil fields are overwritten during bulk editing.
/// No audio-file tags are modified.
public struct BulkMetadataPatch: Sendable, Equatable {
    public var album: String?
    public var albumArtist: String?
    public var artist: String?
    public var genre: String?
    public var year: String?
    public var discNumber: Int?

    public init(album: String? = nil, albumArtist: String? = nil, artist: String? = nil,
                genre: String? = nil, year: String? = nil, discNumber: Int? = nil) {
        self.album = album; self.albumArtist = albumArtist; self.artist = artist
        self.genre = genre; self.year = year; self.discNumber = discNumber
    }

    public var isEmpty: Bool {
        album == nil && albumArtist == nil && artist == nil && genre == nil &&
            year == nil && discNumber == nil
    }

    public func applying(to track: LibraryTrack) throws -> TrackMetadata {
        var result = TrackMetadata(track: track)
        if let album { result.album = album }
        if let albumArtist { result.albumArtist = albumArtist }
        if let artist { result.artist = artist }
        if let genre { result.genre = genre }
        if let year { result.year = year }
        if let discNumber { result.discNumber = discNumber }
        return try result.validated()
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
    /// Selects all but the best-quality candidate in every complete metadata group.
    /// The result is a review selection only: nothing is removed or trashed.
    /// Callers must supply the entire unfiltered duplicate result, not a partial page.
    public static func selectKeepingOne(_ tracks: [LibraryTrack]) -> Set<String> {
        struct Key: Hashable {
            let title: String
            let artist: String
            let seconds: Int
        }
        let groups = Dictionary(grouping: tracks.filter {
            !$0.isMissing && $0.error == nil && $0.duration.isFinite && $0.duration > 0
                && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !$0.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "unknown artist"
        }) {
            Key(title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                artist: $0.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                seconds: Int($0.duration.rounded()))
        }
        var selected = Set<String>()
        for group in groups.values where group.count > 1 {
            // Retain lossless first, then higher sample precision/rate or bitrate.
            // A stable path/ID tie-break ensures repeated selections agree.
            let ranked = group.sorted { lhs, rhs in
                if lhs.isLossless != rhs.isLossless { return lhs.isLossless }
                let leftDepth = lhs.bitDepth ?? 0, rightDepth = rhs.bitDepth ?? 0
                if leftDepth != rightDepth { return leftDepth > rightDepth }
                let leftRate = lhs.sampleRate ?? 0, rightRate = rhs.sampleRate ?? 0
                if leftRate != rightRate { return leftRate > rightRate }
                let leftBitrate = lhs.bitRate ?? 0, rightBitrate = rhs.bitRate ?? 0
                if leftBitrate != rightBitrate { return leftBitrate > rightBitrate }
                if lhs.fileSize != rhs.fileSize { return lhs.fileSize > rhs.fileSize }
                return lhs.id < rhs.id
            }
            selected.formUnion(ranked.dropFirst().map(\.id))
        }
        return selected
    }

}
