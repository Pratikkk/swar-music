import Foundation
import GRDB

public enum ListeningMode: String, CaseIterable, Identifiable, Sendable {
    case recent = "Recently Played"
    case mostPlayed = "Most Played"
    case forgotten = "Forgotten Favourites"
    public var id: Self { self }
}

public struct ListeningSong: Identifiable, Sendable {
    public var id: String { track.id }
    public let track: LibraryTrack
    public let playCount: Int
    public let lastPlayed: Date?
}

public struct ListeningOverview: Sendable {
    public let songs: [ListeningSong]
    public let totalPlays: Int
    public let uniqueSongs: Int
    public let matchedCount: Int
}

extension LibraryRepository {
    /// One qualified listen per playback; no file metadata or audio is modified.
    public func recordListen(trackID: String, at date: Date = Date()) throws {
        guard date.timeIntervalSince1970.isFinite else { return }
        try database.write { db in
            try db.execute(sql: """
                INSERT INTO track_listening(trackID, playCount, lastPlayed)
                SELECT id, 1, ? FROM tracks WHERE id = ?
                  AND NOT EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isHidden = 1)
                ON CONFLICT(trackID) DO UPDATE SET playCount = playCount + 1,
                    lastPlayed = MAX(lastPlayed, excluded.lastPlayed)
                """, arguments: [date.timeIntervalSince1970, trackID])
        }
    }

    public func listening(_ mode: ListeningMode, limit: Int = 100, now: Date = Date(), search: String = "", scope: TrackSearchScope = .all) throws -> ListeningOverview {
        try database.read { db in
            let visible = "NOT EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = t.id AND p.isHidden = 1)"
            let join = " FROM tracks t LEFT JOIN track_listening l ON l.trackID = t.id WHERE " + visible
            let filter: String
            let order: String
            var arguments = StatementArguments()
            switch mode {
            case .recent:
                filter = " AND l.playCount > 0"; order = "l.lastPlayed DESC, t.id"
            case .mostPlayed:
                filter = " AND l.playCount > 0"; order = "l.playCount DESC, l.lastPlayed DESC, t.id"
            case .forgotten:
                filter = " AND EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = t.id AND p.isFavorite = 1) AND (l.lastPlayed IS NULL OR l.lastPlayed < ?)"
                order = "l.lastPlayed ASC, t.title COLLATE NOCASE, t.id"
                arguments += [now.addingTimeInterval(-30 * 86400).timeIntervalSince1970]
            }
            let pattern = TrackSearchQuery(search).expression(scope: scope)
            let searchFilter = pattern == nil ? "" : " AND t.rowid IN (SELECT rowid FROM track_search WHERE track_search MATCH ?)"
            if let pattern { arguments += [pattern] }
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*)" + join + filter + searchFilter, arguments: arguments) ?? 0
            var pageArguments = arguments
            pageArguments += [max(1, min(limit, 10000))]
            let rows = try Row.fetchAll(db, sql: "SELECT t.*, COALESCE(l.playCount, 0) AS listeningCount, l.lastPlayed AS listeningDate" + join + filter + searchFilter + " ORDER BY " + order + " LIMIT ?", arguments: pageArguments)
            let songs = try rows.map { row in
                ListeningSong(track: try LibraryTrack(row: row), playCount: row["listeningCount"],
                    lastPlayed: (row["listeningDate"] as Double?).map { Date(timeIntervalSince1970: $0) })
            }
            let totals = try Row.fetchOne(db, sql: "SELECT COALESCE(SUM(l.playCount), 0) AS plays, COUNT(l.trackID) AS songs" + join)
            return ListeningOverview(songs: songs, totalPlays: totals?["plays"] ?? 0,
                                     uniqueSongs: totals?["songs"] ?? 0, matchedCount: count)
        }
    }

    public func clearListeningHistory() throws {
        try database.write { try $0.execute(sql: "DELETE FROM track_listening") }
    }
}
