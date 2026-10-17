import AppKit
import SwiftUI
import Library
import Player

/// One menu definition powers the ellipsis and right-click menus in every song list.
@MainActor
private struct SongActions<Extra: View>: ViewModifier {
    let library: LibraryModel
    let track: LibraryTrack
    let busy: Bool
    let play: (() -> Void)?
    let playLabel: String
    let showsButton: Bool
    @Environment(\.libraryPlayer) private var player
    let enqueue: (Bool) -> Void
    let extra: Extra
    @State private var showArtwork = false
    @State private var showInfo = false
    @State private var showEditor = false
    @State private var showRemoval = false
    @State private var showNewPlaylist = false
    @State private var playlistName = ""
    @State private var actionError: String?

    func body(content: Content) -> some View {
        content
            .padding(.trailing, showsButton ? 32 : 0)
            .overlay(alignment: .trailing) {
                if showsButton {
                    Menu { menuItems } label: { Image(systemName: "ellipsis").frame(width: 18, height: 28) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("Actions for \(track.title)").padding(.trailing, showsButton ? 10 : 0)
                }
            }
            .contextMenu { menuItems }
            .sheet(isPresented: $showEditor) { MetadataEditorView(track: track, library: library) }
            .sheet(isPresented: $showArtwork) {
                if let player { ArtworkEditorView(tracks: [track], library: library, player: player) }
            }
            .sheet(isPresented: $showInfo) { SongInfoView(track: track, library: library) }
            .alert("New Playlist", isPresented: $showNewPlaylist) {
                TextField("Playlist Name", text: $playlistName)
                Button("Create") {
                    let name = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    Task {
                        if let playlist = await library.createPlaylist(name: name) {
                            await library.addTracks([track], to: playlist)
                        }
                    }
                }
                .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .alert("Remove from Library?", isPresented: $showRemoval) {
                Button("Remove", role: .destructive) { Task { await library.removeTrackFromLibrary(track) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("“\(track.title)” will be removed from the library and playlists. Its file stays in place and will stay excluded from automatic scans. Restore it from Settings → Files → Restore Removed Songs.")
            }
            .alert("Couldn’t Complete Action", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
                Button("OK") { actionError = nil }
            } message: { Text(actionError ?? "") }
    }

    @ViewBuilder private var items: some View {
        if let play {
            Button(playLabel, systemImage: playLabel == "Pause" ? "pause.fill" : "play.fill", action: play).disabled(busy || track.error != nil)
        }
        Menu("Add to Playlist", systemImage: "music.note.list") {
            Button("New Playlist…", systemImage: "plus") { playlistName = ""; showNewPlaylist = true }
            if !library.playlists.isEmpty {
                Divider()
                ForEach(library.playlists) { playlist in
                    Button(playlist.name) { Task { await library.addTracks([track], to: playlist) } }
                }
            }
        }.disabled(!library.isReady)
        Divider()
        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { enqueue(true) }
            .disabled(busy || track.error != nil)
        Button("Play Last", systemImage: "text.append") { enqueue(false) }
            .disabled(busy || track.error != nil)
        Divider()
        SongNavigationItems(track: track)
        Divider()
        Button("Get Info", systemImage: "info.circle") { showInfo = true }
        Button("Edit Details…", systemImage: "pencil") { showEditor = true }
        if player != nil { Button("Edit Album Artwork…", systemImage: "photo") { showArtwork = true } }
        Button(library.favoriteTrackIDs.contains(track.id) ? "Remove from Favourites" : "Add to Favourites",
               systemImage: library.favoriteTrackIDs.contains(track.id) ? "star.slash" : "star") {
            Task { await library.toggleFavorite(track) }
        }
        Divider()
        Menu("Copy", systemImage: "doc.on.doc") {
            Button("Song Details") { copyText([track.title, track.artist, track.album].filter { !$0.isEmpty }.joined(separator: " — ")) }
            Button("File Path") {
                do { copyText(try library.location(for: track).file.path) }
                catch { actionError = error.localizedDescription }
            }
            Button("File") {
                do {
                    let url = try library.location(for: track).file
                    NSPasteboard.general.clearContents()
                    if !NSPasteboard.general.writeObjects([url as NSURL]) { actionError = "The file could not be copied to the clipboard." }
                } catch { actionError = error.localizedDescription }
            }
        }
        Button("Show in Finder", systemImage: "folder") {
            do { NSWorkspace.shared.activateFileViewerSelecting([try library.location(for: track).file]) }
            catch { actionError = error.localizedDescription }
        }
    }

    private func copyText(_ text: String) {
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(text, forType: .string) { actionError = "The text could not be copied." }
    }

    @ViewBuilder private var menuItems: some View {
        items
        extra
        Divider()
        Button("Remove from Library…", systemImage: "minus.circle", role: .destructive) { showRemoval = true }
    }
}

extension View {
    @MainActor func songActions(library: LibraryModel, track: LibraryTrack, busy: Bool, play: (() -> Void)? = nil, playLabel: String = "Play", showsButton: Bool = true, enqueue: @escaping (Bool) -> Void) -> some View {
        modifier(SongActions(library: library, track: track, busy: busy, play: play, playLabel: playLabel, showsButton: showsButton, enqueue: enqueue, extra: EmptyView()))
    }

    @MainActor func songActions<Extra: View>(library: LibraryModel, track: LibraryTrack, busy: Bool, play: (() -> Void)? = nil, playLabel: String = "Play", showsButton: Bool = true,
                                 enqueue: @escaping (Bool) -> Void, @ViewBuilder extra: () -> Extra) -> some View {
        modifier(SongActions(library: library, track: track, busy: busy, play: play, playLabel: playLabel, showsButton: showsButton, enqueue: enqueue, extra: extra()))
    }
}

@MainActor
private struct SongInfoView: View {
    let track: LibraryTrack
    let library: LibraryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                CoverArt(url: library.artworkURL(track.artworkKey), title: track.album).frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title).font(.title3.bold())
                    Text(track.artist).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                    info("Album", track.album)
                    info("Album Artist", track.albumArtist)
                    info("Genre", track.genre)
                    info("Year", track.year ?? "—")
                    info("Track / Disc", "\(track.trackNumber) / \(track.discNumber)")
                    info("Duration", String(format: "%d:%02d", Int(max(0, track.duration)) / 60, Int(max(0, track.duration)) % 60))
                    info("Source", track.sourceFormat?.description ?? track.codec ?? "Unavailable")
                    info("Bitrate", track.bitRate.map { String(format: "%.0f kbps", Double($0) / 1000) } ?? "—")
                    info("File Size", ByteCountFormatter.string(fromByteCount: track.fileSize, countStyle: .file))
                    info("Modified", track.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    info("Location", (try? library.location(for: track).file.path) ?? track.relativePath)
                    if let error = track.error { info("Read Error", error) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(24).frame(width: 500, height: 500).textSelection(.enabled)
    }

    private func info(_ name: String, _ value: String) -> some View {
        GridRow(alignment: .top) {
            Text(name).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
