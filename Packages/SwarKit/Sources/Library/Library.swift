import Decoding
import Foundation
import GRDB

public struct LibraryFolder: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable {
    public static let databaseTableName = "folders"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public var id: String
    public var path: String
    public var bookmark: Data
    public var addedAt: Date
    public init(id: String = UUID().uuidString, path: String, bookmark: Data = Data(), addedAt: Date = Date()) {
        self.id = id; self.path = path; self.bookmark = bookmark; self.addedAt = addedAt
    }
}

public struct LibraryTrack: Codable, FetchableRecord, PersistableRecord, Sendable, Identifiable, Equatable {
    public static let databaseTableName = "tracks"
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy { .timeIntervalSince1970 }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    public var id: String
    public var folderID: String
    public var relativePath: String
    public var title: String
    public var artist: String
    public var albumArtist: String
    public var album: String
    public var genre: String
    public var trackNumber: Int
    public var discNumber: Int
    public var year: String?
    public var tagsJSON: String?
    public var codec: String?
    public var bitDepth: Int?
    public var sampleRate: Double?
    public var channels: Int?
    public var bitRate: UInt32?
    public var isLossless: Bool
    public var isFloat: Bool
    public var duration: Double
    public var fileSize: Int64
    public var modifiedAt: Date
    public var addedAt: Date
    public var artworkKey: String?
    public var coverStamp: String
    public var error: String?

    public var sourceFormat: SourceFormat? {
        guard let codec, let sampleRate, let channels else { return nil }
        return SourceFormat(codec: codec, sampleRate: sampleRate, bitDepth: bitDepth, channels: channels,
                            isLossless: isLossless, isFloat: isFloat, bitRate: bitRate)
    }
}

public struct LibraryAlbum: Identifiable, Sendable {
    public var id: String { artist + "\u{1f}" + title }
    public let title: String
    public let artist: String
    public let count: Int
    public let artworkKey: String?
}

public struct LibraryPage: Sendable {
    public let tracks: [LibraryTrack]
    public let count: Int
    public let unreadableCount: Int
}

struct ScanFingerprint: Decodable, FetchableRecord, Sendable {
    static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy { .timeIntervalSince1970 }
    let relativePath: String
    let fileSize: Int64
    let modifiedAt: Date
    let addedAt: Date
    let artworkKey: String?
    let coverStamp: String
    let error: String?
}

public struct LibraryProgress: Sendable {
    public let folder: String
    public let completed: Int
    public let total: Int
    public let changed: Int
    public let failed: Int
}
