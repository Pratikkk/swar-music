import Foundation
import GRDB

public actor LibraryRepository {
    let database: DatabaseQueue

    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            db.add(function: DatabaseFunction("swar_fold", argumentCount: 1, pure: true) { values in
                guard let text = String.fromDatabaseValue(values[0]) else { return nil }
                return SmartPlaylistDefinition.folded(text)
            })
        }
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
        migrator.registerMigration("library-expanded-search-v5") { db in
            try db.execute(sql: """
                DROP TRIGGER tracks_ai;
                DROP TRIGGER tracks_ad;
                DROP TRIGGER tracks_au;
                DROP TABLE track_search;
                CREATE VIRTUAL TABLE track_search USING fts5(title,artist,album,albumArtist,genre,year,relativePath, content='tracks', content_rowid='rowid', tokenize="unicode61 remove_diacritics 2 categories 'L* N* Co M*'");
                CREATE TRIGGER tracks_ai AFTER INSERT ON tracks BEGIN
                  INSERT INTO track_search(rowid,title,artist,album,albumArtist,genre,year,relativePath) VALUES(new.rowid,new.title,new.artist,new.album,new.albumArtist,new.genre,new.year,new.relativePath); END;
                CREATE TRIGGER tracks_ad AFTER DELETE ON tracks BEGIN
                  INSERT INTO track_search(track_search,rowid,title,artist,album,albumArtist,genre,year,relativePath) VALUES('delete',old.rowid,old.title,old.artist,old.album,old.albumArtist,old.genre,old.year,old.relativePath); END;
                CREATE TRIGGER tracks_au AFTER UPDATE ON tracks BEGIN
                  INSERT INTO track_search(track_search,rowid,title,artist,album,albumArtist,genre,year,relativePath) VALUES('delete',old.rowid,old.title,old.artist,old.album,old.albumArtist,old.genre,old.year,old.relativePath);
                  INSERT INTO track_search(rowid,title,artist,album,albumArtist,genre,year,relativePath) VALUES(new.rowid,new.title,new.artist,new.album,new.albumArtist,new.genre,new.year,new.relativePath); END;
                INSERT INTO track_search(track_search) VALUES('rebuild');
                """)
        }
        migrator.registerMigration("library-metadata-v6") { db in
            try db.create(table: "track_metadata") { t in
                t.column("trackID", .text).primaryKey().references("tracks", onDelete: .cascade)
                t.column("originalJSON", .blob).notNull()
                t.column("editsJSON", .blob).notNull()
            }
        }
        migrator.registerMigration("library-artwork-v7") { db in
            try db.create(table: "track_artwork") { t in
                t.column("trackID", .text).primaryKey().references("tracks", onDelete: .cascade)
                t.column("originalKey", .text)
                t.column("artworkKey", .text).notNull()
            }
        }
        migrator.registerMigration("library-smart-playlists-v8") { db in
            try db.alter(table: "playlists") { $0.add(column: "smartRulesJSON", .text) }
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
            for var track in tracks {
                if let data = try Data.fetchOne(db, sql: "SELECT editsJSON FROM track_metadata WHERE trackID = ?", arguments: [track.id]) {
                    let edits = try JSONDecoder().decode(TrackMetadata.self, from: data)
                    let original = try JSONEncoder().encode(TrackMetadata(track: track))
                    try db.execute(sql: "UPDATE track_metadata SET originalJSON = ? WHERE trackID = ?", arguments: [original, track.id])
                    edits.apply(to: &track)
                }
                if let key = try String.fetchOne(db, sql: "SELECT artworkKey FROM track_artwork WHERE trackID = ?", arguments: [track.id]) {
                    try db.execute(sql: "UPDATE track_artwork SET originalKey = ? WHERE trackID = ?", arguments: [track.artworkKey, track.id])
                    track.artworkKey = key
                }
                try track.save(db)
            }
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

    public func page(search: String = "", limit: Int = 500, recentFirst: Bool = false, favoritesOnly: Bool = false, sortOrder: TrackSortOrder = .album, reversed: Bool = false, searchScope: TrackSearchScope = .all) throws -> LibraryPage {
        let query = TrackSearchQuery(search)
        let pattern = query.expression(scope: searchScope)
        return try database.read { db in
            let visible = "NOT EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isHidden = 1)"
                + (favoritesOnly ? " AND EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isFavorite = 1)" : "")
            let condition = " WHERE " + visible + (query.isEmpty ? "" : pattern == nil ? " AND 0" : " AND rowid IN (SELECT rowid FROM track_search WHERE track_search MATCH ?)")
            var arguments: StatementArguments = pattern.map { StatementArguments([$0]) } ?? []
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks" + condition, arguments: arguments) ?? 0
            arguments += [max(1, limit)]
            let order = (recentFirst ? TrackSortOrder.recentlyAdded : sortOrder).sqlOrder(reversed: recentFirst ? false : reversed)
            let tracks = try LibraryTrack.fetchAll(db, sql: "SELECT * FROM tracks" + condition + " ORDER BY " + order + " LIMIT ?", arguments: arguments)
            let unreadable = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE error IS NOT NULL AND " + visible) ?? 0
            return LibraryPage(tracks: tracks, count: count, unreadableCount: unreadable)
        }
    }

    public func overview(limit: Int = 8) throws -> LibraryOverview {
        try database.read { db in
            let visible = "NOT EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isHidden = 1)"
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE " + visible) ?? 0
            let lossless = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE isLossless = 1 AND " + visible) ?? 0
            let albums = "SELECT albumArtist, album FROM tracks WHERE " + visible + " GROUP BY albumArtist, album"
            let albumCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (" + albums + ")") ?? 0
            let rows = try Row.fetchAll(db, sql: "SELECT albumArtist, album, MAX(artworkKey) AS artworkKey, COUNT(*) AS trackCount, SUM(CASE WHEN error IS NULL THEN 1 ELSE 0 END) AS playableCount, SUM(CASE WHEN isLossless = 1 THEN 1 ELSE 0 END) AS losslessTrackCount FROM tracks WHERE " + visible + " GROUP BY albumArtist, album ORDER BY MAX(addedAt) DESC, albumArtist COLLATE NOCASE, album COLLATE NOCASE LIMIT ?", arguments: [max(1, limit)])
            let recent = rows.map { row in
                LibraryAlbumSummary(title: row["album"], artist: row["albumArtist"], artworkKey: row["artworkKey"], trackCount: row["trackCount"], playableCount: row["playableCount"], losslessTrackCount: row["losslessTrackCount"])
            }
            let favourites = try LibraryTrack.fetchAll(db, sql: "SELECT * FROM tracks WHERE " + visible + " AND EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isFavorite = 1) ORDER BY addedAt DESC, id LIMIT ?", arguments: [max(1, limit)])
            return LibraryOverview(trackCount: count, albumCount: albumCount, losslessCount: lossless, favourites: favourites, recentAlbums: recent)
        }
    }

    /// Search selects matching albums; metadata and counts always describe the full visible album.
    public func albums(search: String = "", searchScope: TrackSearchScope = .all) throws -> [LibraryAlbumSummary] {
        try Task.checkCancellation()
        let query = TrackSearchQuery(search)
        let pattern = query.expression(scope: searchScope)
        return try database.read { db in
            let visible = "NOT EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isHidden = 1)"
            let match = query.isEmpty ? "" : pattern == nil ? " AND 0" : " AND (albumArtist, album) IN (SELECT albumArtist, album FROM tracks WHERE " + visible + " AND rowid IN (SELECT rowid FROM track_search WHERE track_search MATCH ?))"
            let arguments: StatementArguments = pattern.map { StatementArguments([$0]) } ?? []
            let rows = try Row.fetchAll(db, sql: "SELECT albumArtist, album, MAX(artworkKey) AS artworkKey, COUNT(*) AS trackCount, SUM(CASE WHEN error IS NULL THEN 1 ELSE 0 END) AS playableCount, SUM(CASE WHEN isLossless = 1 THEN 1 ELSE 0 END) AS losslessTrackCount, MIN(NULLIF(year, '')) AS year, MAX(addedAt) AS addedAt, SUM(CASE WHEN duration > 0 THEN duration ELSE 0 END) AS duration FROM tracks WHERE " + visible + match + " GROUP BY albumArtist, album ORDER BY albumArtist COLLATE NOCASE, album COLLATE NOCASE", arguments: arguments)
            return rows.map { row in
                LibraryAlbumSummary(title: row["album"], artist: row["albumArtist"], artworkKey: row["artworkKey"], trackCount: row["trackCount"], playableCount: row["playableCount"], year: row["year"], addedAt: row["addedAt"], duration: row["duration"], losslessTrackCount: row["losslessTrackCount"])
            }
        }
    }

    /// An exact lookup independent of the current search, sort and page limit.
    public func visibleTrack(id: String) throws -> LibraryTrack? {
        try database.read { db in
            try LibraryTrack.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = ? AND NOT EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isHidden = 1)", arguments: [id])
        }
    }

    public func albumTracks(artist: String, title: String) throws -> [LibraryTrack] {
        try database.read { db in
            try LibraryTrack.fetchAll(db, sql: "SELECT * FROM tracks WHERE albumArtist = ? AND album = ? AND NOT EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isHidden = 1) ORDER BY discNumber, trackNumber, title COLLATE NOCASE, id", arguments: [artist, title])
        }
    }

    public func trackPreferences() throws -> (favorites: Set<String>, hiddenCount: Int) {
        try database.read { db in
            let favorites = try String.fetchAll(db, sql: "SELECT trackID FROM track_preferences WHERE isFavorite = 1 AND isHidden = 0")
            let hidden = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_preferences WHERE isHidden = 1") ?? 0
            return (Set(favorites), hidden)
        }
    }

    public func collectionPage(filter: CollectionFilter = .all, search: String = "", scope: TrackSearchScope = .all, limit: Int = 200) throws -> CollectionPage {
        let query = TrackSearchQuery(search)
        let pattern = query.expression(scope: scope)
        return try database.read { db in
            let hidden = "EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isHidden = 1)"
            let visible = "NOT " + hidden
            let incomplete = "error IS NULL AND (trim(title) = '' OR trim(artist) IN ('', 'Unknown Artist') OR trim(album) = '' OR (NOT EXISTS (SELECT 1 FROM track_metadata m WHERE m.trackID = tracks.id) AND CASE WHEN json_valid(tagsJSON) THEN (NULLIF(trim(json_extract(tagsJSON, '$.title')), '') IS NULL OR NULLIF(trim(json_extract(tagsJSON, '$.artist')), '') IS NULL OR NULLIF(trim(json_extract(tagsJSON, '$.album')), '') IS NULL) ELSE 1 END))"
            let duplicate = "error IS NULL AND duration > 0 AND trim(artist) NOT IN ('', 'Unknown Artist') AND trim(title) != '' AND (lower(trim(title)), lower(trim(artist)), CAST(round(duration) AS INTEGER)) IN (SELECT lower(trim(title)), lower(trim(artist)), CAST(round(duration) AS INTEGER) FROM tracks WHERE " + visible + " AND error IS NULL AND duration > 0 AND trim(artist) NOT IN ('', 'Unknown Artist') AND trim(title) != '' GROUP BY lower(trim(title)), lower(trim(artist)), CAST(round(duration) AS INTEGER) HAVING COUNT(*) > 1)"
            let conditions: [CollectionFilter: String] = [.all: "1", .incomplete: incomplete, .artwork: "artworkKey IS NULL OR artworkKey = ''", .duplicates: duplicate, .unreadable: "error IS NOT NULL", .removed: "1"]
            func count(_ condition: String, removed: Bool = false) throws -> Int {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE " + (removed ? hidden : visible) + " AND (" + condition + ")") ?? 0
            }
            let stats = try Row.fetchOne(db, sql: "SELECT COUNT(*) AS songs, COALESCE(SUM(fileSize), 0) AS bytes, COALESCE(SUM(CASE WHEN duration > 0 THEN duration ELSE 0 END), 0) AS duration FROM tracks WHERE " + visible)!
            let albums = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM (SELECT albumArtist, album FROM tracks WHERE " + visible + " GROUP BY albumArtist, album)") ?? 0
            let summary = try CollectionSummary(songs: stats["songs"], albums: albums, bytes: stats["bytes"], duration: stats["duration"], incomplete: count(incomplete), artwork: count("artworkKey IS NULL OR artworkKey = ''"), duplicates: count(duplicate), unreadable: count("error IS NOT NULL"), removed: count("1", removed: true))
            let condition = " WHERE " + (filter == .removed ? hidden : visible) + " AND (" + (conditions[filter] ?? "1") + ")" + (query.isEmpty ? "" : pattern == nil ? " AND 0" : " AND rowid IN (SELECT rowid FROM track_search WHERE track_search MATCH ?)")
            let arguments: StatementArguments = pattern.map { StatementArguments([$0]) } ?? []
            let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks" + condition, arguments: arguments) ?? 0
            var pageArguments = arguments
            pageArguments += [max(1, limit)]
            let order = filter == .duplicates ? "title COLLATE NOCASE, artist COLLATE NOCASE, duration, relativePath, id" : "albumArtist COLLATE NOCASE, album COLLATE NOCASE, discNumber, trackNumber, title COLLATE NOCASE, id"
            let tracks = try LibraryTrack.fetchAll(db, sql: "SELECT * FROM tracks" + condition + " ORDER BY " + order + " LIMIT ?", arguments: pageArguments)
            return CollectionPage(summary: summary, tracks: tracks, count: total)
        }
    }

    public func artworkSelection(ids: Set<String>, referenceID: String) throws -> ArtworkSelection {
        try database.read { db in
            var count = 0
            for id in ids {
                count += try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM track_artwork WHERE trackID = ?", arguments: [id]) ?? 0
            }
            let row = try Row.fetchOne(db, sql: "SELECT originalKey FROM track_artwork WHERE trackID = ?", arguments: [referenceID])
            let key: String?
            if let row { key = row["originalKey"] }
            else { key = try String.fetchOne(db, sql: "SELECT artworkKey FROM tracks WHERE id = ?", arguments: [referenceID]) }
            return ArtworkSelection(customCount: count, originalKey: key)
        }
    }

    /// A nil key resets overrides; originalKey retains the latest scanner result.
    public func setArtwork(ids: Set<String>, key: String?) throws -> [LibraryTrack] {
        if let key, key.isEmpty || key.contains("/") || key.contains("\\") || key == "." || key == ".." { throw LibraryFailure("Invalid artwork key.") }
        return try database.write { db in
            var result: [LibraryTrack] = []
            for id in ids.sorted() {
                guard var track = try LibraryTrack.fetchOne(db, key: id) else { continue }
                if let key {
                    try db.execute(sql: "INSERT INTO track_artwork(trackID, originalKey, artworkKey) VALUES (?, ?, ?) ON CONFLICT(trackID) DO UPDATE SET artworkKey = excluded.artworkKey", arguments: [id, track.artworkKey, key])
                    track.artworkKey = key
                } else if let row = try Row.fetchOne(db, sql: "SELECT originalKey FROM track_artwork WHERE trackID = ?", arguments: [id]) {
                    track.artworkKey = row["originalKey"]
                    try db.execute(sql: "DELETE FROM track_artwork WHERE trackID = ?", arguments: [id])
                } else { continue }
                try track.update(db)
                result.append(track)
            }
            return result
        }
    }

    public func updateMetadata(trackID: String, metadata: TrackMetadata) throws {
        let edits = try metadata.validated()
        try database.write { db in
            guard var track = try LibraryTrack.fetchOne(db, key: trackID) else { throw LibraryFailure("This song is no longer in the library.") }
            let original = try JSONEncoder().encode(TrackMetadata(track: track))
            let encoded = try JSONEncoder().encode(edits)
            try db.execute(sql: "INSERT INTO track_metadata(trackID, originalJSON, editsJSON) VALUES (?, ?, ?) ON CONFLICT(trackID) DO UPDATE SET editsJSON = excluded.editsJSON", arguments: [trackID, original, encoded])
            edits.apply(to: &track)
            try track.update(db)
        }
    }

    public func hasMetadataEdits(trackID: String) throws -> Bool {
        try database.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM track_metadata WHERE trackID = ?", arguments: [trackID]) == 1 }
    }

    public func resetMetadata(trackID: String) throws {
        try database.write { db in
            guard var track = try LibraryTrack.fetchOne(db, key: trackID),
                  let data = try Data.fetchOne(db, sql: "SELECT originalJSON FROM track_metadata WHERE trackID = ?", arguments: [trackID]) else { return }
            try JSONDecoder().decode(TrackMetadata.self, from: data).apply(to: &track)
            try track.update(db)
            try db.execute(sql: "DELETE FROM track_metadata WHERE trackID = ?", arguments: [trackID])
        }
    }

    public func restoreTracks(ids: Set<String>) throws {
        try database.write { db in
            for id in ids { try db.execute(sql: "UPDATE track_preferences SET isHidden = 0 WHERE trackID = ?", arguments: [id]) }
        }
    }

    public func removeTracksFromLibrary(ids: Set<String>) throws {
        try database.write { db in
            for id in ids {
                try db.execute(sql: "INSERT INTO track_preferences(trackID, isFavorite, isHidden) SELECT id, 0, 1 FROM tracks WHERE id = ? ON CONFLICT(trackID) DO UPDATE SET isFavorite = 0, isHidden = 1", arguments: [id])
                try db.execute(sql: "DELETE FROM playlist_tracks WHERE trackID = ?", arguments: [id])
            }
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
            guard let playlist = try LibraryPlaylist.fetchOne(db, key: playlistID) else { return }
            guard !playlist.isSmart else { throw LibraryFailure("Smart Playlists update from rules. Edit their rules instead of adding songs.") }
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
            guard try LibraryPlaylist.fetchOne(db, key: item.playlistID)?.isSmart != true else { throw LibraryFailure("Edit this Smart Playlist’s rules instead of removing songs.") }
            _ = try PlaylistTrack.deleteOne(db, key: playlistTrackID)
            try db.execute(sql: "UPDATE playlist_tracks SET position = position - 1 WHERE playlistID = ? AND position > ?", arguments: [item.playlistID, item.position])
            try db.execute(sql: "UPDATE playlists SET updatedAt = ? WHERE id = ?", arguments: [Date().timeIntervalSince1970, item.playlistID])
        }
    }

    public func moveTrackInPlaylist(playlistID: String, from: Int, to: Int) throws {
        guard from != to else { return }
        try database.write { db in
            guard try LibraryPlaylist.fetchOne(db, key: playlistID)?.isSmart != true else { throw LibraryFailure("Smart Playlist order is set by its rules.") }
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
            if let playlist = try LibraryPlaylist.fetchOne(db, key: playlistID), let json = playlist.smartRulesJSON {
                return try Self.smartTracks(db, definition: .decode(json)).enumerated().map { index, track in
                    PlaylistTrackItem(id: playlistID + ":" + track.id, playlistID: playlistID, position: index, track: track)
                }
            }
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
