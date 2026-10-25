import Foundation
import GRDB

public struct QueuePlaylistDraft: Sendable {
    public let trackIDs: [String]
    public let skippedCount: Int
}

extension LibraryRepository {
    public func queuePlaylistDraft(trackIDs: [String], sourceCount: Int) throws -> QueuePlaylistDraft {
        try database.read { db in
            guard !trackIDs.isEmpty else { return QueuePlaylistDraft(trackIDs: [], skippedCount: sourceCount) }
            // Batch check: fetch all valid tracks in one query
            let placeholders = trackIDs.map { _ in "?" }.joined(separator: ",")
            let sql = "SELECT id FROM tracks WHERE id IN (\(placeholders)) AND NOT EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isHidden = 1)"
            let validIDs = try String.fetchAll(db, sql: sql, arguments: StatementArguments(trackIDs))
            let allowedSet = Set(validIDs)
            let allowed = trackIDs.filter { allowedSet.contains($0) }
            return QueuePlaylistDraft(trackIDs: allowed, skippedCount: sourceCount - allowed.count)
        }
    }

    /// Creation and membership commit together; a stale preview never leaves an empty playlist.
    public func createQueuePlaylist(name: String, draft: QueuePlaylistDraft) throws -> LibraryPlaylist {
        guard !draft.trackIDs.isEmpty else { throw LibraryFailure("There are no library songs to save.") }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = LibraryPlaylist(name: trimmed.isEmpty ? "Saved Queue" : trimmed)
        try database.write { db in
            try playlist.insert(db)
            // Batch validate all track IDs before inserting
            let placeholders = draft.trackIDs.map { _ in "?" }.joined(separator: ",")
            let validIDs = try String.fetchAll(db, sql: "SELECT id FROM tracks WHERE id IN (\(placeholders)) AND NOT EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isHidden = 1)", arguments: StatementArguments(draft.trackIDs))
            let validSet = Set(validIDs)
            for (position, id) in draft.trackIDs.enumerated() {
                guard validSet.contains(id) else {
                    throw LibraryFailure("Some songs are no longer in your library. Close this dialog and try again.")
                }
                try PlaylistTrack(playlistID: playlist.id, trackID: id, position: position).insert(db)
            }
        }
        return playlist
    }
}
