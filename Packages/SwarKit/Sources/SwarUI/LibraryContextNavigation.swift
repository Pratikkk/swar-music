import SwiftUI
import Library
import Player

enum LibraryDestination: Sendable, Equatable {
    case album(artist: String, title: String)
    case artist(String)
    case genre(String)
}

struct LibraryNavigation: Sendable {
    var go: (@MainActor @Sendable (LibraryDestination) -> Void)?
}
private struct LibraryNavigationKey: EnvironmentKey { static let defaultValue = LibraryNavigation() }
private struct LibraryPlayerKey: EnvironmentKey { static let defaultValue: Player? = nil }
extension EnvironmentValues {
    var libraryNavigation: LibraryNavigation {
        get { self[LibraryNavigationKey.self] }
        set { self[LibraryNavigationKey.self] = newValue }
    }
    var libraryPlayer: Player? {
        get { self[LibraryPlayerKey.self] }
        set { self[LibraryPlayerKey.self] = newValue }
    }
}

struct SongNavigationItems: View {
    let track: LibraryTrack
    @Environment(\.libraryNavigation) private var navigation
    var body: some View {
        Button("Go to Album", systemImage: "square.stack") {
            navigation.go?(.album(artist: track.albumArtist, title: track.album))
        }.disabled(navigation.go == nil || track.album.isEmpty)
        Button("Go to Artist", systemImage: "music.mic") { navigation.go?(.artist(track.artist)) }
            .disabled(navigation.go == nil || track.artist.isEmpty)
        if !track.albumArtist.isEmpty && track.albumArtist != track.artist {
            Button("Go to Album Artist", systemImage: "person.2") { navigation.go?(.artist(track.albumArtist)) }
                .disabled(navigation.go == nil)
        }
        if !track.genre.isEmpty && track.genre != "Unknown Genre" {
            Button("Go to Genre", systemImage: "guitars") { navigation.go?(.genre(track.genre)) }
                .disabled(navigation.go == nil)
        }
    }
}

@MainActor
enum LibraryQueueActions {
    static func entries(_ tracks: [LibraryTrack], library: LibraryModel) throws -> [QueueEntry] {
        try tracks.filter { $0.error == nil }.map { track in
            let location = try library.location(for: track)
            return QueueEntry(url: location.file, accessRoot: location.root, title: track.title,
                subtitle: track.artist + " · " + track.album, artworkURL: library.artworkURL(track.artworkKey),
                artist: track.artist, album: track.album)
        }
    }
    static func enqueue(_ tracks: [LibraryTrack], next: Bool, library: LibraryModel, player: Player) {
        do {
            let entries = try entries(tracks, library: library)
            for entry in next ? Array(entries.reversed()) : entries { player.enqueue(entry, playNext: next) }
        } catch { player.reportImportError(error) }
    }
}
