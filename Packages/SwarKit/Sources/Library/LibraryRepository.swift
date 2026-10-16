import Foundation
import GRDB

public actor LibraryRepository {
    private let database: DatabaseQueue

    public init(path: String) throws {
        database = try DatabaseQueue(path: path)
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
            let condition = pattern.isEmpty ? "" : " WHERE rowid IN (SELECT rowid FROM track_search WHERE track_search MATCH ?)"
            var arguments: StatementArguments = pattern.isEmpty ? [] : [pattern]
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks" + condition, arguments: arguments) ?? 0
            arguments += [max(1, limit)]
            let order = recentFirst ? "addedAt DESC, albumArtist, album, discNumber, trackNumber" : "albumArtist COLLATE NOCASE, album COLLATE NOCASE, discNumber, trackNumber, title COLLATE NOCASE"
            let tracks = try LibraryTrack.fetchAll(db, sql: "SELECT * FROM tracks" + condition + " ORDER BY " + order + " LIMIT ?", arguments: arguments)
            let unreadable = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE error IS NOT NULL") ?? 0
            return LibraryPage(tracks: tracks, count: count, unreadableCount: unreadable)
        }
    }
}
