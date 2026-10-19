import Foundation
import GRDB

public struct QueuePlaylistDraft: Sendable {
    public let trackIDs: [String]
    public let skippedCount: Int
}

extension LibraryRepository {
    public func queuePlaylistDraft(trackIDs: [String], sourceCount: Int) throws -> QueuePlaylistDraft {
        try database.read { db in
            let allowed = try trackIDs.filter { id in
                try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tracks WHERE id = ? AND NOT EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isHidden = 1))", arguments: [id]) == true
            }
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
            for (position, id) in draft.trackIDs.enumerated() {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tracks WHERE id = ? AND NOT EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isHidden = 1))", arguments: [id]) == true else {
                    throw LibraryFailure("Some songs are no longer in your library. Close this dialog and try again.")
                }
                try PlaylistTrack(playlistID: playlist.id, trackID: id, position: position).insert(db)
            }
        }
        return playlist
    }
}
