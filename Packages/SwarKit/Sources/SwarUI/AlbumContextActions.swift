import SwiftUI
import AppKit
import Library
import Player

@MainActor
private struct AlbumContextActions: ViewModifier {
    let library: LibraryModel
    let player: Player
    let album: LibraryAlbumSummary
    let showsButton: Bool
    @Environment(\.libraryNavigation) private var navigation
    @State private var working = false
    @State private var creatingPlaylist = false
    @State private var editAlbumTracks: [LibraryTrack] = []
    @State private var showBulkEditor = false
    @State private var showTrashConfirmation = false
    @State private var name = ""
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .padding(.trailing, showsButton ? 28 : 0)
            .overlay(alignment: .trailing) {
                if showsButton {
                    Menu { items } label: { Image(systemName: "ellipsis.circle.fill").font(.title2) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Album actions")
                }
            }
            .contextMenu { items }
            .sheet(isPresented: $showBulkEditor) {
                BulkMetadataEditorView(tracks: editAlbumTracks, library: library)
            }
            .alert("Move Album to Trash?", isPresented: $showTrashConfirmation) {
                Button("Move to Trash", role: .destructive) { perform(.trash) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Move all \(album.trackCount) songs in “\(album.title)” to macOS Trash? Audio files will be removed from their folders and their library and playlist entries removed. If one file fails, previously moved files remain recoverable in Trash.")
            }
            .alert("New Playlist", isPresented: $creatingPlaylist) {
                TextField("Playlist Name", text: $name)
                Button("Create") { perform(.create(name.trimmingCharacters(in: .whitespacesAndNewlines))) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) { }
            }
            .alert("Couldn’t Complete Action", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }

    @ViewBuilder private var items: some View {
        Button("Go to Album", systemImage: "square.stack") { navigation.go?(.album(artist: album.artist, title: album.title)) }
            .disabled(navigation.go == nil)
        Button("Go to Artist", systemImage: "music.mic") { navigation.go?(.artist(album.artist)) }
            .disabled(navigation.go == nil || album.artist.isEmpty)
        Divider()
        Group {
            Button("Play", systemImage: "play.fill") { perform(.play(false)) }
            Button("Shuffle", systemImage: "shuffle") { perform(.play(true)) }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { perform(.enqueue(true)) }
            Button("Play Last", systemImage: "text.append") { perform(.enqueue(false)) }
        }.disabled(working || player.isBusy || album.playableCount == 0)
        Menu("Add to Playlist", systemImage: "music.note.list") {
            Button("New Playlist…", systemImage: "plus") { name = ""; creatingPlaylist = true }
            if !library.manualPlaylists.isEmpty { Divider() }
            ForEach(library.manualPlaylists) { playlist in
                Button(playlist.name) { perform(.playlist(playlist)) }
            }
        }.disabled(working || !library.isReady)
        Divider()
        Button("Edit Album Metadata…", systemImage: "pencil") { prepareBulkEdit() }
            .disabled(working || !library.isReady)
        Button("Show in Finder", systemImage: "folder") { perform(.reveal) }.disabled(working)
        Divider()
        Button("Move Album to Trash…", systemImage: "trash", role: .destructive) { showTrashConfirmation = true }
            .disabled(working || !library.isReady || library.isScanning || library.isRecovering || album.trackCount == 0)
        Button("Copy Album Details", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(album.title + " — " + album.artist, forType: .string)
        }
    }

    private func prepareBulkEdit() {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            let tracks = await library.tracks(in: album)
            guard !tracks.isEmpty else {
                error = "No editable tracks were found in this album."
                return
            }
            editAlbumTracks = tracks
            showBulkEditor = true
        }
    }

    private enum Action { case play(Bool), enqueue(Bool), playlist(LibraryPlaylist), create(String), reveal, trash }
    private func perform(_ action: Action) {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            let tracks = await library.tracks(in: album)
            guard !tracks.isEmpty else { error = "This album is no longer available in the library."; return }
            do {
                switch action {
                case .play(let shuffle):
                    let entries = try LibraryQueueActions.entries(tracks, library: library)
                    if !entries.isEmpty { await player.play(entries, startingAt: 0, shuffle: shuffle) }
                case .enqueue(let next): LibraryQueueActions.enqueue(tracks, next: next, library: library, player: player)
                case .playlist(let playlist): await library.addTracks(tracks, to: playlist)
                case .create(let name):
                    guard !name.isEmpty else { return }
                    if let playlist = await library.createPlaylist(name: name) { await library.addTracks(tracks, to: playlist) }
                case .reveal:
                    NSWorkspace.shared.activateFileViewerSelecting(try tracks.map { try library.location(for: $0).file })
                case .trash:
                    _ = try await library.moveTracksToTrash(tracks)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

extension View {
    @MainActor func albumActions(library: LibraryModel, player: Player, album: LibraryAlbumSummary, showsButton: Bool = false) -> some View {
        modifier(AlbumContextActions(library: library, player: player, album: album, showsButton: showsButton))
    }
}
