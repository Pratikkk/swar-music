import SwiftUI
import Player
import Library
import UniformTypeIdentifiers
import AppKit

private enum LibrarySection: String, CaseIterable, Identifiable {
    case home = "Home"
    case recentlyAdded = "Recently Added"
    case artists = "Artists"
    case albums = "Albums"
    case songs = "Songs"
    case genres = "Genres"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .home: "house"
        case .recentlyAdded: "clock"
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .genres: "guitars"
        }
    }
}

private enum SidebarSelection: Hashable {
    case section(LibrarySection)
    case playlist(String)
}

/// Local library browsing and the single-file playback surface.
@MainActor
public struct LibraryView: View {
    @State private var selection: SidebarSelection? = .section(.recentlyAdded)
    @State private var player = Player(sessionStore: .applicationDefault())
    @State private var selectedAlbum: String?
    @State private var showImporter = false
    @State private var showNowPlaying = false
    @State private var windowWidth: CGFloat = 900
    @State private var importingFolder = false
    @State private var library = LibraryModel()

    @State private var showNewPlaylistAlert = false
    @State private var showRenameAlert = false
    @State private var showDeleteAlert = false
    @State private var playlistNameInput = ""
    @State private var playlistToRename: LibraryPlaylist?
    @State private var playlistToDelete: LibraryPlaylist?

    private struct AlbumSummary: Identifiable {
        let id: String
        let title: String
        let artist: String
    }

    private var albumGroups: [AlbumSummary] {
        let groups = Dictionary(grouping: library.tracks, by: { $0.albumArtist + "\u{1f}" + $0.album })
        return groups.map { key, tracks in
            AlbumSummary(
                id: key,
                title: tracks[0].album,
                artist: tracks[0].albumArtist
            )
        }.sorted { lhs, rhs in
            if lhs.artist != rhs.artist {
                return lhs.artist.localizedStandardCompare(rhs.artist) == .orderedAscending
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private var defaultAlbumID: String? {
        albumGroups.first?.id
    }

    public init() {}

    public var body: some View {
        playbackLifecycle
    }

    private var playbackLifecycle: some View {
        playlistPresentation
        .playbackCommands(player: player, canOpen: !showNowPlaying,
            open: { importingFolder = false; showImporter = true },
            nowPlaying: { showNowPlaying = true })
        .task { await library.start() }
        .task { await player.restoreSession() }
        .task {
            while !Task.isCancelled {
                await player.refreshVolume()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                await player.saveSessionIfNeeded()
            }
        }
        .task(id: selection) {
            if case .section(let s) = selection {
                library.recentFirst = s == .recentlyAdded || s == .home
            } else {
                library.recentFirst = false
            }
            await library.reload(resetLimit: true)
        }
        .task(id: library.search) {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            await library.reload(resetLimit: true)
        }
        .task {
            while !Task.isCancelled {
                await player.refresh()
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { break }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            player.shutdown()
            library.shutdown()
        }
    }

    private var playlistPresentation: some View {
        windowPresentation
        .alert("New Playlist", isPresented: $showNewPlaylistAlert) {
            TextField("Playlist Name", text: $playlistNameInput)
            Button("Create") {
                let name = playlistNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                Task {
                    if let created = await library.createPlaylist(name: name.isEmpty ? "New Playlist" : name) {
                        selection = .playlist(created.id)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Playlist", isPresented: $showRenameAlert) {
            TextField("Playlist Name", text: $playlistNameInput)
            Button("Save") {
                if let playlist = playlistToRename {
                    let name = playlistNameInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await library.renamePlaylist(playlist, newName: name.isEmpty ? "New Playlist" : name) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete Playlist", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let playlist = playlistToDelete {
                    Task {
                        await library.deletePlaylist(playlist)
                        if selection == .playlist(playlist.id) {
                            selection = .section(.recentlyAdded)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Are you sure you want to delete \"\(playlistToDelete?.name ?? "this playlist")\"? Songs in your library will not be deleted.")
        }
    }

    private var windowPresentation: some View {
        libraryLayout
        .toolbar(removing: .sidebarToggle)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .tint(.pink)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importingFolder ? [.folder] : [.item]) { result in
            switch result {
            case .success(let url):
                if importingFolder { Task { await library.addFolder(url) } }
                else { Task { await player.open(url) } }
            case .failure(let error): player.reportImportError(error)
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        windowWidth = geometry.size.width
                        if case .section(let section) = selection, section == .albums, selectedAlbum == nil {
                            selectedAlbum = defaultAlbumID
                        }
                    }
                    .onChange(of: geometry.size.width) { _, width in windowWidth = width }
            }
        }
        .onChange(of: selection) {
            if case .section(let section) = selection, section == .albums, selectedAlbum == nil {
                selectedAlbum = defaultAlbumID
            }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView(player: player, width: max(640, min(900, windowWidth - 40)))
        }
    }

    private var libraryLayout: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailPane
        }
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            ToolbarPlayer(player: player, openNowPlaying: { showNowPlaying = true })
            Divider()
            sectionHeader

            selectedContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
    }

    private var selectedContent: some View {
        Group {
            if case .playlist(let id) = selection, let playlist = library.playlists.first(where: { $0.id == id }) {
                PlaylistDetailView(
                    playlist: playlist,
                    library: library,
                    player: player,
                    onRename: { p in
                        playlistToRename = p
                        playlistNameInput = p.name
                        showRenameAlert = true
                    },
                    onDelete: { p in
                        playlistToDelete = p
                        showDeleteAlert = true
                    }
                )
            } else {
                let sectionName: String = {
                    if case .section(let s) = selection {
                        return s == .home ? "Recently Added" : s.rawValue
                    }
                    return "Recently Added"
                }()
                LibraryContent(library: library, player: player,
                               section: sectionName,
                               selectedAlbum: $selectedAlbum)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sectionHeader: some View {
        ZStack {
            if selectedAlbum == nil {
                Group {
                    switch selection {
                    case .section(let s):
                        Text(s.rawValue).font(.headline)
                    case .playlist(let id):
                        Text(library.playlists.first(where: { $0.id == id })?.name ?? "Playlist").font(.headline)
                    case nil:
                        Text("Recently Added").font(.headline)
                    }
                }
            }
            HStack {
                if selectedAlbum != nil {
                    Button { selectedAlbum = nil } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .accessibilityLabel("Back to albums").help("Back to albums")
                }
                if let info = player.formatInfo { FormatChip(info: info) }
                Spacer()
                Menu {
                    Button("Open Audio File…", systemImage: "doc.waveform") { importingFolder = false; showImporter = true }
                        .disabled(player.isBusy)
                    Button("Add Folder…", systemImage: "folder.badge.plus") { openFolderPicker() }
                        .disabled(library.isScanning)
                    Button("Rescan Library", systemImage: "arrow.clockwise") { Task { await library.rescan() } }
                        .disabled(library.isScanning || library.folders.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().help("Library actions")
            }
        }
        .padding(.horizontal, 18).frame(height: 36)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var sidebar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search", text: $library.search)
                    .textFieldStyle(.plain)
                    .accessibilityLabel("Search title, artist, album")
            }
            .padding(6).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))
            .padding(.horizontal, 12).padding(.top, 12)
            List(selection: $selection) {
                Section("Swar") {
                    Label("Home", systemImage: "house").tag(SidebarSelection.section(.home))
                }
                Section("Library") {
                    ForEach(LibrarySection.allCases.filter { $0 != .home }) { section in
                        Label(section.rawValue, systemImage: section.symbol).tag(SidebarSelection.section(section))
                    }
                }
                Section {
                    ForEach(library.playlists) { playlist in
                        Label(playlist.name, systemImage: "music.note.list")
                            .tag(SidebarSelection.playlist(playlist.id))
                            .contextMenu {
                                Button("Rename…") {
                                    playlistToRename = playlist
                                    playlistNameInput = playlist.name
                                    showRenameAlert = true
                                }
                                Button("Delete Playlist", role: .destructive) {
                                    playlistToDelete = playlist
                                    showDeleteAlert = true
                                }
                            }
                    }
                } header: {
                    HStack {
                        Text("Playlists")
                        Spacer()
                        Button {
                            playlistNameInput = ""
                            showNewPlaylistAlert = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .help("New Playlist")
                        .accessibilityLabel("Create New Playlist")
                    }
                }
                Section("Music Folders") {
                    ForEach(library.folders) { folder in
                        Label(URL(fileURLWithPath: folder.path).lastPathComponent, systemImage: "folder")
                            .help(folder.path)
                            .contextMenu {
                                Button("Remove from Library", role: .destructive) { Task { await library.removeFolder(folder) } }
                                    .disabled(library.isScanning)
                            }
                    }
                    Button("Add Folder…", systemImage: "folder.badge.plus") { openFolderPicker() }
                        .disabled(library.isScanning)
                }
            }
            .listStyle(.sidebar).scrollContentBackground(.hidden)
        }
        .background {
            SidebarMaterial().ignoresSafeArea()
        }
        .navigationSplitViewColumnWidth(min: 190, ideal: 202, max: 260)
    }

    private func openFolderPicker() {
        importingFolder = true
        showImporter = true
    }

}

#Preview {
    LibraryView()
        .frame(width: 1100, height: 740)
}
