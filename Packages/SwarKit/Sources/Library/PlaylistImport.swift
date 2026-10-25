import Foundation
import GRDB

public struct PlaylistImportItem: Sendable, Identifiable {
    public let entry: PlaylistFileEntry
    public let track: LibraryTrack?
    public var id: Int { entry.id }
}

public struct PlaylistImportPreview: Sendable {
    public let name: String
    public let items: [PlaylistImportItem]
    public let draft: QueuePlaylistDraft
}

extension LibraryRepository {
    func playlistImportPreview(name: String, entries: [PlaylistFileEntry], trackIDs: [String?]) throws -> PlaylistImportPreview {
        try database.read { db in
            // Collect non-nil track IDs
            let allTrackIDs = trackIDs.compactMap { $0 }
            // Fetch in chunks to avoid SQLite parameter limit (999)
            var matchedMap: [String: LibraryTrack] = [:]
            let chunkSize = 900
            for chunk in allTrackIDs.chunked(into: chunkSize) {
                try Task.checkCancellation()
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let sql = "SELECT * FROM tracks WHERE id IN (\(placeholders)) AND NOT EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isHidden = 1)"
                let tracks = try LibraryTrack.fetchAll(db, sql: sql, arguments: StatementArguments(chunk))
                for track in tracks { matchedMap[track.id] = track }
            }
            var items: [PlaylistImportItem] = []
            var matched: [String] = []
            for (index, entry) in entries.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                let track = trackIDs[index].flatMap { matchedMap[$0] }
                if let track { matched.append(track.id) }
                items.append(PlaylistImportItem(entry: entry, track: track))
            }
            return PlaylistImportPreview(name: name, items: items,
                draft: QueuePlaylistDraft(trackIDs: matched, skippedCount: entries.count - matched.count))
        }
    }
}
