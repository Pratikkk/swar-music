import Foundation
import GRDB

extension LibraryRepository {
    @discardableResult
    public func saveSmartPlaylist(id: String? = nil, name: String, definition: SmartPlaylistDefinition) throws -> LibraryPlaylist {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 100 else { throw LibraryFailure("Enter a playlist name using 1–100 characters.") }
        let json = try definition.encoded()
        return try database.write { db in
            if let id {
                guard var playlist = try LibraryPlaylist.fetchOne(db, key: id), playlist.isSmart else { throw LibraryFailure("This Smart Playlist is no longer available.") }
                playlist.name = name; playlist.smartRulesJSON = json; playlist.updatedAt = Date()
                try playlist.update(db)
                return playlist
            }
            let playlist = LibraryPlaylist(name: name, smartRulesJSON: json)
            try playlist.insert(db)
            return playlist
        }
    }

    public func previewSmartPlaylist(_ definition: SmartPlaylistDefinition, now: Date = Date()) throws -> SmartPlaylistPreview {
        try Task.checkCancellation()
        try definition.validate()
        return try database.read { db in
            let (predicate, arguments) = try Self.smartPredicate(definition, now: now)
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE " + predicate, arguments: arguments) ?? 0
            let selected = min(count, definition.limit ?? count)
            return SmartPlaylistPreview(matchedCount: count, selectedCount: selected,
                samples: try Self.smartTracks(db, definition: definition, now: now, sampleLimit: min(8, selected)))
        }
    }

    static func smartTracks(_ db: Database, definition: SmartPlaylistDefinition, now: Date = Date(), sampleLimit: Int? = nil) throws -> [LibraryTrack] {
        let (predicate, values) = try smartPredicate(definition, now: now)
        var arguments = values
        let cap = min(definition.limit ?? Int.max, sampleLimit ?? Int.max)
        let limit = cap == Int.max ? "" : " LIMIT ?"
        if cap != Int.max { arguments += [cap] }
        return try LibraryTrack.fetchAll(db, sql: "SELECT * FROM tracks WHERE " + predicate + " ORDER BY " + definition.sort.sqlOrder(reversed: definition.reversed) + limit, arguments: arguments)
    }

    static func smartPredicate(_ definition: SmartPlaylistDefinition, now: Date) throws -> (String, StatementArguments) {
        try definition.validate()
        guard now.timeIntervalSince1970.isFinite else { throw LibraryFailure("The playlist date is invalid.") }
        var parts: [String] = []
        var arguments = StatementArguments()
        for rule in definition.rules {
            let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
            switch rule.field {
            case .favourite:
                parts.append((value == "false" ? "NOT " : "") + "EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isFavorite = 1)")
            case .lossless:
                parts.append("isLossless = ?"); arguments += [value == "true"]
            case .added:
                parts.append("addedAt " + (rule.comparison == .withinDays ? ">= ?" : "< ?"))
                arguments += [now.timeIntervalSince1970 - Double(Int(value)!) * 86400]
            case .year, .bitrate:
                let column = rule.field == .year ? "CASE WHEN substr(year,1,4) NOT GLOB '*[^0-9]*' AND length(substr(year,1,4)) = 4 THEN CAST(substr(year,1,4) AS INTEGER) END" : "bitRate"
                let op: String
                switch rule.comparison { case .equals: op = "="; case .atLeast: op = ">="; case .atMost: op = "<="; case .greater: op = ">"; case .less: op = "<"; default: throw LibraryFailure("Invalid numeric comparison.") }
                parts.append("(\(column)) \(op) ?")
                arguments += [Int(value)! * (rule.field == .bitrate ? 1000 : 1)]
            case .artist, .album, .genre, .format:
                let columns = rule.field == .artist ? ["artist", "albumArtist"] : [rule.field == .format ? "codec" : rule.field.rawValue.lowercased()]
                let contains = rule.comparison == .contains || rule.comparison == .notContains
                let negative = rule.comparison == .notContains || rule.comparison == .notEquals
                let expressions = columns.map { column in
                    contains ? "instr(swar_fold(COALESCE(\(column), '')), ?) > 0" : "swar_fold(COALESCE(\(column), '')) = ?"
                }
                parts.append((negative ? "NOT " : "") + "(" + expressions.joined(separator: " OR ") + ")")
                for _ in columns { arguments += [SmartPlaylistDefinition.folded(value)] }
            }
        }
        let visible = "NOT EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isHidden = 1)"
        return (visible + " AND (" + parts.joined(separator: definition.mode == .all ? " AND " : " OR ") + ")", arguments)
    }
}
