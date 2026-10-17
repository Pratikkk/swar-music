import Foundation
import GRDB
import Testing
@testable import Library

struct SmartPlaylistTests {
    private func store() async throws -> (URL, LibraryRepository) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = try LibraryRepository(path: root.appendingPathComponent("Library.sqlite").path)
        try await repository.saveFolder(LibraryFolder(id: "folder", path: root.path))
        return (root, repository)
    }
    private func track(_ id: String, artist: String = "Artist", album: String = "Album", genre: String = "Rock", year: String? = "2020", codec: String? = "FLAC", bitrate: UInt32? = 256000, lossless: Bool = true, added: Date = Date()) -> LibraryTrack {
        LibraryTrack(id: id, folderID: "folder", relativePath: id + ".flac", title: id, artist: artist, albumArtist: artist,
            album: album, genre: genre, trackNumber: 1, discNumber: 1, year: year, tagsJSON: nil, codec: codec,
            bitDepth: 16, sampleRate: 44100, channels: 2, bitRate: bitrate, isLossless: lossless, isFloat: false,
            duration: 60, fileSize: 1024, modifiedAt: Date(), addedAt: added, artworkKey: nil, coverStamp: "", error: nil)
    }
    @Test func allAndAnyRulesQueryTheFullLibraryBeforeApplyingSortAndLimit() async throws {
        let (root, repository) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let tracks = (0..<650).map { track(String(format: "%04d", $0), genre: $0 >= 600 ? "Jazz" : "Rock", lossless: $0.isMultiple(of: 2)) }
        try await repository.saveTracks(tracks)
        var rules = SmartPlaylistDefinition(rules: [SmartRule(field: .genre, value: "Jazz"), SmartRule(field: .lossless)], sort: .title, limit: 3)
        let preview = try await repository.previewSmartPlaylist(rules)
        #expect(preview.matchedCount == 25 && preview.selectedCount == 3)
        #expect(preview.samples.map(\.id) == ["0600", "0602", "0604"])
        let playlist = try await repository.saveSmartPlaylist(name: "Late Jazz", definition: rules)
        #expect(try await repository.playlistTrackItems(playlistID: playlist.id).map(\.track.id) == ["0600", "0602", "0604"])
        rules.mode = .any; rules.reversed = true
        let any = try await repository.previewSmartPlaylist(rules)
        #expect(any.matchedCount == 350 && any.selectedCount == 3)
        #expect(any.samples.map(\.id) == ["0649", "0648", "0647"])
    }
    @Test func favouritesHiddenTracksAndMetadataChangesUpdateWithoutStoredMembership() async throws {
        let (root, repository) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        try await repository.saveTracks([track("one", genre: "मराठी"), track("two", genre: "मराठी"), track("three", genre: "Pop")])
        let definition = SmartPlaylistDefinition(rules: [SmartRule(field: .genre, value: "मराठी"), SmartRule(field: .favourite)])
        let list = try await repository.saveSmartPlaylist(name: "Marathi favourites", definition: definition)
        #expect(try await repository.playlistTrackItems(playlistID: list.id).isEmpty)
        try await repository.setFavorite(trackID: "one", favorite: true)
        let first = try await repository.playlistTrackItems(playlistID: list.id)
        #expect(first.map(\.track.id) == ["one"])
        #expect(try await repository.playlistTrackItems(playlistID: list.id).first?.id == first.first?.id)
        try await repository.setFavorite(trackID: "two", favorite: true)
        #expect(try await repository.playlistTrackItems(playlistID: list.id).count == 2)
        try await repository.removeTrackFromLibrary(trackID: "one")
        #expect(try await repository.playlistTrackItems(playlistID: list.id).map(\.track.id) == ["two"])
        try await repository.restoreTracks(ids: ["one"])
        var changed = track("one", genre: "Pop")
        changed.title = "Retagged"
        try await repository.saveTracks([changed])
        #expect(try await repository.playlistTrackItems(playlistID: list.id).map(\.track.id) == ["two"])
        let any = SmartPlaylistDefinition(mode: .any, rules: [SmartRule(field: .lossless), SmartRule(field: .favourite, value: "false")])
        try await repository.removeTrackFromLibrary(trackID: "three")
        #expect(try await repository.previewSmartPlaylist(any).matchedCount == 2)
    }
    @Test func textComparisonsAreLiteralUnicodeAwareAndArtistNegationIncludesAlbumArtist() async throws {
        let (root, repository) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        var compilation = track("one", artist: "Björk", album: "Live 100%_ ' OR 1=1 --", genre: "मराठी")
        compilation.albumArtist = "Various Artists"
        try await repository.saveTracks([compilation, track("two", artist: "Other", album: "Live 100xy", genre: "Hindi")])
        for rule in [SmartRule(field: .artist, value: "BJÖRK"), SmartRule(field: .genre, comparison: .equals, value: "मराठी"), SmartRule(field: .album, value: "%_"), SmartRule(field: .album, value: "' OR 1=1 --")] {
            #expect(try await repository.previewSmartPlaylist(.init(rules: [rule])).samples.map(\.id) == ["one"])
        }
        let negative = SmartRule(field: .artist, comparison: .notContains, value: "Various")
        #expect(try await repository.previewSmartPlaylist(.init(rules: [negative])).samples.map(\.id) == ["two"])
        #expect(try await repository.previewSmartPlaylist(.init(rules: [SmartRule(field: .format, comparison: .equals, value: "flac")])).matchedCount == 2)
    }
    @Test func numericRulesExcludeUnknownValuesAndConvertKbpsToBits() async throws {
        let (root, repository) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        try await repository.saveTracks([track("old", year: "1999", bitrate: 128000), track("new", year: "2026-01-01", bitrate: 320000), track("unknown", year: nil, codec: nil, bitrate: nil), track("invalid", year: "oops", bitrate: 64000)])
        let definition = SmartPlaylistDefinition(rules: [SmartRule(field: .year, comparison: .atLeast, value: "2000"), SmartRule(field: .bitrate, comparison: .atLeast, value: "256")])
        #expect(try await repository.previewSmartPlaylist(definition).samples.map(\.id) == ["new"])
        #expect(try await repository.previewSmartPlaylist(.init(rules: [SmartRule(field: .bitrate, comparison: .less, value: "100")])).samples.map(\.id) == ["invalid"])
        #expect(try await repository.previewSmartPlaylist(.init(rules: [SmartRule(field: .year, comparison: .atMost, value: "1999")])).samples.map(\.id) == ["old"])
    }
    @Test func relativeDatesUseAnInclusiveRecentBoundaryAndAdvanceWithTime() async throws {
        let (root, repository) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1700000000)
        try await repository.saveTracks([track("today", added: now), track("boundary", added: now.addingTimeInterval(-30 * 86400)), track("old", added: now.addingTimeInterval(-31 * 86400))])
        let recent = SmartPlaylistDefinition(rules: [SmartRule(field: .added, value: "30")])
        #expect(try await repository.previewSmartPlaylist(recent, now: now).matchedCount == 2)
        #expect(try await repository.previewSmartPlaylist(recent, now: now.addingTimeInterval(1)).matchedCount == 1)
        let old = SmartPlaylistDefinition(rules: [SmartRule(field: .added, comparison: .olderDays, value: "30")])
        #expect(try await repository.previewSmartPlaylist(old, now: now).samples.map(\.id) == ["old"])
    }
    @Test func definitionsPersistAndManualMembershipCannotChangeSmartLists() async throws {
        let (root, repository) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        try await repository.saveTracks([track("one")])
        let normal = try await repository.createPlaylist(name: "Normal")
        try await repository.addTracksToPlaylist(playlistID: normal.id, trackIDs: ["one"])
        let definition = SmartPlaylistDefinition(rules: [SmartRule(field: .lossless)])
        let smart = try await repository.saveSmartPlaylist(name: "Lossless", definition: definition)
        await #expect(throws: (any Error).self) { try await repository.addTracksToPlaylist(playlistID: smart.id, trackIDs: ["one"]) }
        await #expect(throws: (any Error).self) { try await repository.moveTrackInPlaylist(playlistID: smart.id, from: 0, to: 1) }
        let savedDate = try #require(try await repository.playlist(id: smart.id)).createdAt
        let updated = try await repository.saveSmartPlaylist(id: smart.id, name: "Lossless edited", definition: .init(rules: [SmartRule(field: .lossless, value: "false")]))
        #expect(updated.id == smart.id && updated.createdAt == savedDate)
        let reopened = try LibraryRepository(path: root.appendingPathComponent("Library.sqlite").path)
        #expect(try await reopened.playlists().count == 2)
        #expect(try await reopened.playlistTrackItems(playlistID: normal.id).map(\.track.id) == ["one"])
        #expect(try await reopened.playlistTrackItems(playlistID: smart.id).isEmpty)
        #expect(try SmartPlaylistDefinition.decode(updated.smartRulesJSON!).rules.first?.value == "false")
        try await reopened.deletePlaylist(id: smart.id)
        #expect(try await reopened.page().count == 1)
    }
    @Test func invalidDraftsAndUnknownVersionsCannotBeSaved() async throws {
        let (root, repository) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        var invalid: [SmartPlaylistDefinition] = [.init(rules: []), .init(rules: [SmartRule(field: .genre, value: " ")]), .init(rules: [SmartRule(field: .year, value: "abc")]), .init(rules: [SmartRule(field: .bitrate, value: "99999999999999999999")]), .init(rules: [SmartRule(field: .lossless, value: "maybe")]), .init(rules: [SmartRule(field: .added, value: "0")]), .init(rules: [SmartRule(field: .genre, comparison: .greater, value: "Rock")]), .init(rules: [SmartRule(field: .lossless)], limit: 0)]
        var future = SmartPlaylistDefinition(rules: [SmartRule(field: .lossless)]); future.version = 2; invalid.append(future)
        for definition in invalid {
            await #expect(throws: (any Error).self) { try await repository.saveSmartPlaylist(name: "Invalid", definition: definition) }
        }
        #expect(try await repository.playlists().isEmpty)
    }
    @Test func migrationPreservesExistingManualPlaylistAndItsMembers() async throws {
        let (root, repository) = try await store()
        defer { try? FileManager.default.removeItem(at: root) }
        try await repository.saveTracks([track("one")])
        let playlist = try await repository.createPlaylist(name: "Existing")
        try await repository.addTracksToPlaylist(playlistID: playlist.id, trackIDs: ["one"])
        try await repository.restoreV7SchemaForMigrationTest()
        let migrated = try LibraryRepository(path: root.appendingPathComponent("Library.sqlite").path)
        let old = try #require(try await migrated.playlist(id: playlist.id))
        #expect(!old.isSmart && old.name == "Existing")
        #expect(try await migrated.playlistTrackItems(playlistID: old.id).map(\.track.id) == ["one"])
        _ = try await migrated.saveSmartPlaylist(name: "New", definition: .init(rules: [SmartRule(field: .lossless)]))
        #expect(try await migrated.playlists().count == 2)
    }
}

private extension LibraryRepository {
    func restoreV7SchemaForMigrationTest() throws {
        try database.write { db in
            try db.execute(sql: "ALTER TABLE playlists DROP COLUMN smartRulesJSON")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'library-smart-playlists-v8'")
        }
    }
}
