import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import Library
import Player

/// Private-format drags contain references, never trusted track metadata.
enum LibrarySongDrag {
    static let type = UTType(exportedAs: "com.swar.library-song", conformingTo: .data).identifier

    @MainActor static func provider(for track: LibraryTrack, library: LibraryModel) -> NSItemProvider {
        Logger(subsystem: "catto.swar", category: "DragDrop").info("Song drag began")
        let provider = NSItemProvider()
        provider.suggestedName = track.title
        guard let location = try? library.location(for: track),
              let data = try? JSONEncoder().encode(location.file) else { return provider }
        provider.registerDataRepresentation(forTypeIdentifier: type, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }

    static func url(from data: Data) -> URL? {
        guard data.count <= 65_536, let url = try? JSONDecoder().decode(URL.self, from: data),
              url.isFileURL else { return nil }
        return url
    }

    @MainActor static func tracks(from providers: [NSItemProvider], library: LibraryModel) async throws -> [LibraryTrack] {
        var tracks: [LibraryTrack] = []
        // Sequential reads preserve the order of a multi-item drop.
        for provider in providers {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                    if let data { continuation.resume(returning: data) }
                    else { continuation.resume(throwing: error ?? DropFailure("This song could not be read.")) }
                }
            }
            guard let url = url(from: data), let track = await library.track(at: url) else {
                throw DropFailure("This song is no longer available in your library.")
            }
            tracks.append(track)
        }
        return tracks
    }
}

private struct DropFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor
private struct LibrarySongDrop: ViewModifier {
    let library: LibraryModel
    let enabled: Bool
    let receive: @MainActor ([LibraryTrack]) async throws -> Void
    @State private var targeted = false
    @State private var loading = false
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: targeted && enabled && library.isReady && !loading ? 2 : 0).allowsHitTesting(false) }
            .onDrop(of: [LibrarySongDrag.type], isTargeted: $targeted) { providers in
                Logger(subsystem: "catto.swar", category: "DragDrop").info("Song drop received")
                guard enabled, library.isReady, !loading, !providers.isEmpty else { return false }
                loading = true
                Task {
                    defer { loading = false }
                    do { try await receive(try await LibrarySongDrag.tracks(from: providers, library: library)) }
                    catch { self.error = error.localizedDescription }
                }
                return true
            }
            .alert("Couldn’t Add Songs", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }
}

@MainActor
private struct LibraryFolderDrop: ViewModifier {
    let library: LibraryModel
    @State private var targeted = false
    @State private var loading = false
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(.tint, lineWidth: targeted && library.isReady && !library.isScanning && !loading ? 3 : 0).padding(3).allowsHitTesting(false) }
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $targeted) { providers in
                guard library.isReady, !library.isScanning, !loading, !providers.isEmpty else { return false }
                loading = true
                Task {
                    defer { loading = false }
                    do {
                        var urls: [URL] = []
                        for provider in providers {
                            let data: Data = try await withCheckedThrowingContinuation { continuation in
                                provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, error in
                                    if let data { continuation.resume(returning: data) }
                                    else { continuation.resume(throwing: error ?? DropFailure("The dropped folder could not be read.")) }
                                }
                            }
                            guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                                throw DropFailure("Drop music folders here to add them to your library.")
                            }
                            let isDirectory = await Task.detached(priority: .userInitiated) {
                                let access = url.startAccessingSecurityScopedResource()
                                defer { if access { url.stopAccessingSecurityScopedResource() } }
                                return (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                            }.value
                            guard isDirectory else { throw DropFailure("Drop music folders here to add them to your library.") }
                            if !urls.contains(url) { urls.append(url) }
                        }
                        for url in urls {
                            await library.addFolder(url)
                            if let message = library.errorMessage { throw DropFailure(message) }
                        }
                    } catch { self.error = error.localizedDescription }
                }
                return true
            }
            .alert("Couldn’t Add Folder", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }
}

extension View {
    @MainActor func libraryFolderDrop(library: LibraryModel) -> some View {
        modifier(LibraryFolderDrop(library: library))
    }

    @MainActor func playlistSongDrop(library: LibraryModel, playlist: LibraryPlaylist) -> some View {
        modifier(LibrarySongDrop(library: library, enabled: !playlist.isSmart) { tracks in
            // Recheck after asynchronous provider loading in case the playlist was deleted.
            guard library.manualPlaylists.contains(where: { $0.id == playlist.id }) else {
                throw DropFailure("This playlist is no longer available.")
            }
            await library.addTracks(tracks, to: playlist)
            if let message = library.errorMessage { throw DropFailure(message) }
        })
    }

    @MainActor func queueSongDrop(library: LibraryModel, player: Player) -> some View {
        modifier(LibrarySongDrop(library: library, enabled: !player.isBusy && !player.isSystemSleeping) { tracks in
            guard !player.isBusy, !player.isSystemSleeping else {
                throw DropFailure("Wait for playback to finish opening, then try again.")
            }
            guard tracks.allSatisfy({ $0.error == nil }) else {
                throw DropFailure("One of these songs cannot be played. Check its details in the library.")
            }
            LibraryQueueActions.enqueue(tracks, next: false, library: library, player: player)
        })
    }
}
