import Foundation
import GRDB

extension LibraryRepository {
    /// Only exceptional locations need a map; ordinary IDs retain their fast path.
    func relocatedTrackIDs() throws -> [String: String] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, folderID, relativePath FROM tracks WHERE id != folderID || ':' || relativePath")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["folderID"] as String + ":" + ($0["relativePath"] as String), $0["id"] as String) })
        }
    }

    /// Keep the missing song's identity and all references. If scanning already
    /// imported its new location, merge that entry in this same transaction.
    func reconnectTrack(id: String, replacement: LibraryTrack) throws {
        try database.write { db in
            guard let old = try LibraryTrack.fetchOne(db, key: id), old.isMissing else {
                throw LibraryFailure("This song is no longer missing. Refresh the collection and try again.")
            }
            guard replacement.error == nil, !replacement.isMissing else {
                throw LibraryFailure("The selected file could not be read as audio.")
            }
            if let target = try LibraryTrack.fetchOne(db, sql: "SELECT * FROM tracks WHERE folderID = ? AND relativePath = ? AND id != ?",
                                                     arguments: [replacement.folderID, replacement.relativePath, id]) {
                let hidden = try Bool.fetchOne(db, sql: "SELECT isHidden FROM track_preferences WHERE trackID = ?", arguments: [target.id]) ?? false
                guard !hidden else { throw LibraryFailure("That file is excluded from the library. Restore it from Removed before reconnecting.") }
                try db.execute(sql: "UPDATE playlist_tracks SET trackID = ? WHERE trackID = ?", arguments: [id, target.id])
                try db.execute(sql: """
                    INSERT INTO track_listening(trackID, playCount, lastPlayed)
                    SELECT ?, playCount, lastPlayed FROM track_listening WHERE trackID = ?
                    ON CONFLICT(trackID) DO UPDATE SET playCount = playCount + excluded.playCount,
                        lastPlayed = MAX(lastPlayed, excluded.lastPlayed)
                    """, arguments: [id, target.id])
                try db.execute(sql: """
                    INSERT INTO track_preferences(trackID, isFavorite, isHidden)
                    SELECT ?, isFavorite, 0 FROM track_preferences WHERE trackID = ?
                    ON CONFLICT(trackID) DO UPDATE SET isFavorite = MAX(isFavorite, excluded.isFavorite)
                    """, arguments: [id, target.id])
                for table in ["track_metadata", "track_artwork"] {
                    try db.execute(sql: "UPDATE \(table) SET trackID = ? WHERE trackID = ? AND NOT EXISTS (SELECT 1 FROM \(table) WHERE trackID = ?)", arguments: [id, target.id, id])
                }
                try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [target.id])
            }
            var track = replacement
            track.id = old.id
            track.addedAt = old.addedAt
            if let data = try Data.fetchOne(db, sql: "SELECT editsJSON FROM track_metadata WHERE trackID = ?", arguments: [id]) {
                let original = try JSONEncoder().encode(TrackMetadata(track: track))
                try db.execute(sql: "UPDATE track_metadata SET originalJSON = ? WHERE trackID = ?", arguments: [original, id])
                try JSONDecoder().decode(TrackMetadata.self, from: data).apply(to: &track)
            }
            if let key = try String.fetchOne(db, sql: "SELECT artworkKey FROM track_artwork WHERE trackID = ?", arguments: [id]) {
                try db.execute(sql: "UPDATE track_artwork SET originalKey = ? WHERE trackID = ?", arguments: [track.artworkKey, id])
                track.artworkKey = key
            }
            try track.update(db)
        }
    }
}
