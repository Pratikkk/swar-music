import Foundation
import GRDB

public enum LibrarySearchSuggestion: Sendable, Equatable, Identifiable {
    case artist(String)
    case album(title: String, artist: String)
    case song(LibraryTrack)

    public var id: String {
        switch self {
        case .artist(let name): "artist:" + name
        case .album(let title, let artist): "album:" + artist + "\u{1f}" + title
        case .song(let track): "song:" + track.id
        }
    }
}

extension LibraryRepository {
    /// Query the full index, independently of the current screen or loaded page.
    public func searchSuggestions(for text: String, scope: TrackSearchScope = .all) throws -> [LibrarySearchSuggestion] {
        try Task.checkCancellation()
        let query = TrackSearchQuery(text)
        guard !query.isEmpty else { return [] }
        return try database.read { db in
            let visible = "NOT EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isHidden = 1)"
            func condition(_ field: TrackSearchScope) -> (String, StatementArguments)? {
                guard let match = query.expression(scope: scope == .all ? field : scope) else { return nil }
                return (" WHERE " + visible + " AND rowid IN (SELECT rowid FROM track_search WHERE track_search MATCH ?)", [match])
            }
            var results: [LibrarySearchSuggestion] = []
            if let (whereSQL, args) = condition(.artist) {
                let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT artist FROM tracks" + whereSQL + " AND trim(artist) != '' ORDER BY artist COLLATE NOCASE LIMIT 3", arguments: args)
                results += rows.map { .artist($0["artist"]) }
            }
            if let (whereSQL, args) = condition(.album) {
                let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT album, albumArtist FROM tracks" + whereSQL + " AND trim(album) != '' ORDER BY album COLLATE NOCASE, albumArtist COLLATE NOCASE LIMIT 3", arguments: args)
                results += rows.map { .album(title: $0["album"], artist: $0["albumArtist"]) }
            }
            if let (whereSQL, args) = condition(.all) {
                let tracks = try LibraryTrack.fetchAll(db, sql: "SELECT " + browseSelection + " FROM tracks" + whereSQL + " ORDER BY title COLLATE NOCASE, id LIMIT 5", arguments: args)
                results += tracks.map { .song($0) }
            }
            return results
        }
    }
}
