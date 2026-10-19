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
            var items: [PlaylistImportItem] = []
            var matched: [String] = []
            for (index, entry) in entries.enumerated() {
                if index.isMultiple(of: 256) { try Task.checkCancellation() }
                let track = try trackIDs[index].flatMap { id in
                    try LibraryTrack.fetchOne(db, sql: "SELECT * FROM tracks WHERE id = ? AND NOT EXISTS (SELECT 1 FROM track_preferences p WHERE p.trackID = tracks.id AND p.isHidden = 1)", arguments: [id])
                }
                if let track { matched.append(track.id) }
                items.append(PlaylistImportItem(entry: entry, track: track))
            }
            return PlaylistImportPreview(name: name, items: items,
                draft: QueuePlaylistDraft(trackIDs: matched, skippedCount: entries.count - matched.count))
        }
    }
}
