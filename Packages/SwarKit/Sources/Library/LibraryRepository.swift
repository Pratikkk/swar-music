import Foundation
import GRDB

public actor LibraryRepository {
    private let database: DatabaseQueue

    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        database = try DatabaseQueue(path: path, configuration: config)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("library-v1") { db in
            try db.create(table: "folders") { t in
                t.column("id", .text).primaryKey()
                t.column("path", .text).notNull().unique()
                t.column("bookmark", .blob).notNull()
                t.column("addedAt", .datetime).notNull()
            }
            try db.create(table: "tracks") { t in
                t.column("id", .text).primaryKey()
                t.column("folderID", .text).notNull().references("folders", onDelete: .cascade)
                for name in ["relativePath", "title", "artist", "albumArtist", "album", "genre", "coverStamp"] { t.column(name, .text).notNull() }
                t.column("trackNumber", .integer).notNull()
                t.column("discNumber", .integer).notNull()
                for name in ["year", "tagsJSON", "codec", "artworkKey", "error"] { t.column(name, .text) }
                for name in ["bitDepth", "channels", "bitRate"] { t.column(name, .integer) }
                t.column("sampleRate", .double)
                t.column("isLossless", .boolean).notNull()
                t.column("isFloat", .boolean).notNull()
                t.column("duration", .double).notNull()
                t.column("fileSize", .integer).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("addedAt", .datetime).notNull()
            }
            try db.create(index: "tracks_folder", on: "tracks", columns: ["folderID"])
            try db.create(index: "tracks_album", on: "tracks", columns: ["albumArtist", "album", "discNumber", "trackNumber", "title"])
            try db.execute(sql: """
                CREATE VIRTUAL TABLE track_search USING fts5(title, artist, album, content='tracks', content_rowid='rowid', tokenize='unicode61 remove_diacritics 2');
                CREATE TRIGGER tracks_ai AFTER INSERT ON tracks BEGIN
                  INSERT INTO track_search(rowid,title,artist,album) VALUES(new.rowid,new.title,new.artist,new.album); END;
                CREATE TRIGGER tracks_ad AFTER DELETE ON tracks BEGIN
                  INSERT INTO track_search(track_search,rowid,title,artist,album) VALUES('delete',old.rowid,old.title,old.artist,old.album); END;
                CREATE TRIGGER tracks_au AFTER UPDATE ON tracks BEGIN
                  INSERT INTO track_search(track_search,rowid,title,artist,album) VALUES('delete',old.rowid,old.title,old.artist,old.album);
                  INSERT INTO track_search(rowid,title,artist,album) VALUES(new.rowid,new.title,new.artist,new.album); END;
                """)
        }
        migrator.registerMigration("library-browse-indexes-v2") { db in
            try db.execute(sql: """
                DROP INDEX tracks_album;
                CREATE INDEX tracks_album_sort ON tracks(albumArtist COLLATE NOCASE, album COLLATE NOCASE, discNumber, trackNumber, title COLLATE NOCASE);
                CREATE INDEX tracks_recent ON tracks(addedAt DESC, albumArtist, album, discNumber, trackNumber);
                CREATE INDEX tracks_errors ON tracks(id) WHERE error IS NOT NULL;
                """)
        }
        migrator.registerMigration("library-playlists-v3") { db in
            try db.create(table: "playlists") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            try db.create(table: "playlist_tracks") { t in
                t.column("id", .text).primaryKey()
                t.column("playlistID", .text).notNull().references("playlists", onDelete: .cascade)
                t.column("trackID", .text).notNull().references("tracks", onDelete: .cascade)
                t.column("position", .integer).notNull()
                t.column("addedAt", .datetime).notNull()
            }
            try db.create(index: "playlist_tracks_order", on: "playlist_tracks", columns: ["playlistID", "position"])
            try db.create(index: "playlist_tracks_track", on: "playlist_tracks", columns: ["trackID"])
        }
        migrator.registerMigration("library-track-preferences-v4") { db in
            try db.create(table: "track_preferences") { t in
                t.column("trackID", .text).primaryKey().references("tracks", onDelete: .cascade)
                t.column("isFavorite", .boolean).notNull().defaults(to: false)
                t.column("isHidden", .boolean).notNull().defaults(to: false)
            }
        }
        try migrator.migrate(database)
    }

    public func folders() throws -> [LibraryFolder] {
        try database.read { try LibraryFolder.fetchAll($0, sql: "SELECT * FROM folders ORDER BY addedAt") }
    }

    public func saveFolder(_ folder: LibraryFolder) throws {
        try database.write { try folder.save($0) }
    }

    public func removeFolder(_ id: String) throws {
        _ = try database.write { try LibraryFolder.deleteOne($0, key: id) }
    }

    func existingTracks(folderID: String) throws -> [String: ScanFingerprint] {
        let tracks = try database.read { try ScanFingerprint.fetchAll($0, sql: "SELECT relativePath, fileSize, modifiedAt, addedAt, artworkKey, coverStamp, error FROM tracks WHERE folderID = ?", arguments: [folderID]) }
        return Dictionary(uniqueKeysWithValues: tracks.map { ($0.relativePath, $0) })
    }

    public func saveTracks(_ tracks: [LibraryTrack]) throws {
        try database.write { db in
            for track in tracks { try track.save(db) }
        }
    }

    /// Called only after a complete, successful enumeration, never after cancellation/access failure.
    public func reconcile(folderID: String, seen: Set<String>) throws {
        try database.write { db in
            let existing = try Row.fetchAll(db, sql: "SELECT id, relativePath FROM tracks WHERE folderID = ?", arguments: [folderID])
            for row in existing where !seen.contains(row["relativePath"] as String) {
                try db.execute(sql: "DELETE FROM tracks WHERE id = ?", arguments: [row["id"] as String])
            }
        }
    }

    public func page(search: String = "", limit: Int = 500, recentFirst: Bool = false) throws -> LibraryPage {
        let tokens = search.split(whereSeparator: \.isWhitespace).prefix(20)
        let pattern = tokens.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")
        return try database.read { db in
            let visible = "NOT EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isHidden = 1)"
            let condition = " WHERE " + visible + (pattern.isEmpty ? "" : " AND rowid IN (SELECT rowid FROM track_search WHERE track_search MATCH ?)")
            var arguments: StatementArguments = pattern.isEmpty ? [] : [pattern]
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks" + condition, arguments: arguments) ?? 0
            arguments += [max(1, limit)]
            let order = recentFirst ? "addedAt DESC, albumArtist, album, discNumber, trackNumber" : "albumArtist COLLATE NOCASE, album COLLATE NOCASE, discNumber, trackNumber, title COLLATE NOCASE"
            let tracks = try LibraryTrack.fetchAll(db, sql: "SELECT * FROM tracks" + condition + " ORDER BY " + order + " LIMIT ?", arguments: arguments)
            let unreadable = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE error IS NOT NULL AND " + visible) ?? 0
            return LibraryPage(tracks: tracks, count: count, unreadableCount: unreadable)
        }
    }

    public func trackPreferences() throws -> (favorites: Set<String>, hiddenCount: Int) {
        try database.read { db in
            let favorites = try String.fetchAll(db, sql: "SELECT trackID FROM track_preferences WHERE isFavorite = 1 AND isHidden = 0")
            let hidden = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_preferences WHERE isHidden = 1") ?? 0
            return (Set(favorites), hidden)
        }
    }

    public func setFavorite(trackID: String, favorite: Bool) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO track_preferences(trackID, isFavorite, isHidden) VALUES (?, ?, 0)
                ON CONFLICT(trackID) DO UPDATE SET isFavorite = excluded.isFavorite
                """, arguments: [trackID, favorite])
        }
    }

    /// Retain the scan fingerprint, so monitored files do not reappear at the next scan.
    public func removeTrackFromLibrary(trackID: String) throws {
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO track_preferences(trackID, isFavorite, isHidden) VALUES (?, 0, 1)
                ON CONFLICT(trackID) DO UPDATE SET isFavorite = 0, isHidden = 1
                """, arguments: [trackID])
            try db.execute(sql: "DELETE FROM playlist_tracks WHERE trackID = ?", arguments: [trackID])
        }
    }

    public func restoreRemovedTracks() throws {
        try database.write { db in
            try db.execute(sql: "UPDATE track_preferences SET isHidden = 0 WHERE isHidden = 1")
        }
    }

    public func playlists() throws -> [LibraryPlaylist] {
        try database.read { try LibraryPlaylist.fetchAll($0, sql: "SELECT * FROM playlists ORDER BY name COLLATE NOCASE") }
    }

    public func playlist(id: String) throws -> LibraryPlaylist? {
        try database.read { try LibraryPlaylist.fetchOne($0, key: id) }
    }

    public func createPlaylist(name: String) throws -> LibraryPlaylist {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = LibraryPlaylist(name: trimmed.isEmpty ? "New Playlist" : trimmed)
        try database.write { try playlist.save($0) }
        return playlist
    }

    public func renamePlaylist(id: String, name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "New Playlist" : trimmed
        let now = Date().timeIntervalSince1970
        try database.write { db in
            try db.execute(sql: "UPDATE playlists SET name = ?, updatedAt = ? WHERE id = ?", arguments: [finalName, now, id])
        }
    }

    public func deletePlaylist(id: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM playlist_tracks WHERE playlistID = ?", arguments: [id])
            _ = try LibraryPlaylist.deleteOne(db, key: id)
        }
    }

    public func addTracksToPlaylist(playlistID: String, trackIDs: [String]) throws {
        guard !trackIDs.isEmpty else { return }
        try database.write { db in
            guard try LibraryPlaylist.exists(db, key: playlistID) else { return }
            let currentMax = try Int.fetchOne(db, sql: "SELECT MAX(position) FROM playlist_tracks WHERE playlistID = ?", arguments: [playlistID]) ?? -1
            var nextPosition = currentMax + 1
            let now = Date()
            for trackID in trackIDs {
                let hidden = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM track_preferences WHERE trackID = ? AND isHidden = 1)", arguments: [trackID]) ?? false
                if hidden { continue }
                let item = PlaylistTrack(playlistID: playlistID, trackID: trackID, position: nextPosition, addedAt: now)
                try item.save(db)
                nextPosition += 1
            }
            try db.execute(sql: "UPDATE playlists SET updatedAt = ? WHERE id = ?", arguments: [now.timeIntervalSince1970, playlistID])
        }
    }

    public func removeTrackFromPlaylist(playlistTrackID: String) throws {
        try database.write { db in
            guard let item = try PlaylistTrack.fetchOne(db, key: playlistTrackID) else { return }
            _ = try PlaylistTrack.deleteOne(db, key: playlistTrackID)
            try db.execute(sql: "UPDATE playlist_tracks SET position = position - 1 WHERE playlistID = ? AND position > ?", arguments: [item.playlistID, item.position])
            try db.execute(sql: "UPDATE playlists SET updatedAt = ? WHERE id = ?", arguments: [Date().timeIntervalSince1970, item.playlistID])
        }
    }

    public func moveTrackInPlaylist(playlistID: String, from: Int, to: Int) throws {
        guard from != to else { return }
        try database.write { db in
            var items = try PlaylistTrack.fetchAll(db, sql: "SELECT * FROM playlist_tracks WHERE playlistID = ? ORDER BY position ASC", arguments: [playlistID])
            guard items.indices.contains(from), items.indices.contains(to) else { return }
            let moved = items.remove(at: from)
            items.insert(moved, at: to)
            for (index, var item) in items.enumerated() {
                if item.position != index {
                    item.position = index
                    try item.save(db)
                }
            }
            try db.execute(sql: "UPDATE playlists SET updatedAt = ? WHERE id = ?", arguments: [Date().timeIntervalSince1970, playlistID])
        }
    }

    public func playlistTrackItems(playlistID: String) throws -> [PlaylistTrackItem] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT pt.id AS pt_id, pt.position AS pt_position, pt.playlistID AS pt_playlistID, t.*
                FROM playlist_tracks pt
                INNER JOIN tracks t ON pt.trackID = t.id
                WHERE pt.playlistID = ?
                  AND NOT EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = t.id AND p.isHidden = 1)
                ORDER BY pt.position ASC
                """, arguments: [playlistID])
            return try rows.map { row in
                let track = try LibraryTrack(row: row)
                let ptID: String = row["pt_id"]
                let ptPosition: Int = row["pt_position"]
                let ptPlaylistID: String = row["pt_playlistID"]
                return PlaylistTrackItem(id: ptID, playlistID: ptPlaylistID, position: ptPosition, track: track)
            }
        }
    }
}
