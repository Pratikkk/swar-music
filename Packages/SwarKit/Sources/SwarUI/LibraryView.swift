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
    case favorites = "Favourites"
    case genres = "Genres"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .home: "house"
        case .recentlyAdded: "clock"
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .favorites: "star"
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
    private static let brandIcon = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) } ?? NSImage(named: NSImage.applicationIconName) ?? NSImage()
    @State private var selection: SidebarSelection? = .section(.albums)
    @AppStorage("albumSortOrder") private var albumSortOrder: AlbumSortOrder = .artist
    @AppStorage("songSortOrder") private var songSortOrder: TrackSortOrder = .album
    @AppStorage("reverseSongSort") private var reverseSongSort = false
    @FocusState private var searchFocused: Bool
    @FocusState private var sidebarFocused: Bool
    @State private var player = Player(sessionStore: .applicationDefault())
    @State private var selectedAlbum: String?
    @State private var showImporter = false
    @State private var showNowPlaying = false
    @State private var windowWidth: CGFloat = 900
    @State private var playerHeight: CGFloat = 56
    @State private var importingFolder = false
    @State private var library: LibraryModel

    @State private var showNewPlaylistAlert = false
    @State private var showRenameAlert = false
    @State private var showDeleteAlert = false
    @State private var playlistNameInput = ""
    @State private var playlistToRename: LibraryPlaylist?
    @State private var playlistToDelete: LibraryPlaylist?

    public init(library: LibraryModel = LibraryModel()) {
        _library = State(initialValue: library)
    }

    public var body: some View {
        playbackLifecycle
    }

    private var playbackLifecycle: some View {
        playlistPresentation
        .playbackCommands(player: player, canOpen: !showNowPlaying,
            open: { importingFolder = false; showImporter = true },
            nowPlaying: { showNowPlaying = true })
        .task { await library.start() }
        .task {
            player.enableSystemMediaControls()
            await player.restoreSession()
        }
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
            library.favoritesOnly = selection == .section(.favorites)
            library.sortOrder = showsSongSort ? songSortOrder : .album
            library.reverseSort = showsSongSort && reverseSongSort
            if case .section(let s) = selection {
                library.recentFirst = s == .recentlyAdded || s == .home
            } else {
                library.recentFirst = false
            }
            await library.reload(resetLimit: true)
        }
        .task(id: songSortOrder.rawValue + String(reverseSongSort)) {
            guard showsSongSort else { return }
            library.sortOrder = songSortOrder
            library.reverseSort = reverseSongSort
            await library.reload(resetLimit: true)
        }
        .task(id: library.searchScope) {
            guard case .section = selection else { return }
            await library.reload(resetLimit: true)
        }
        .task(id: library.search) {
            guard case .section = selection else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            await library.reload(resetLimit: true)
        }
        .task(id: player.isPlaying) {
            while player.isPlaying && !Task.isCancelled {
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
                    }
                    .onChange(of: geometry.size.width) { _, width in windowWidth = width }
            }
        }
        .onChange(of: selection) { selectedAlbum = nil }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView(player: player, width: max(640, min(900, windowWidth - 40)))
        }
    }

    private var libraryLayout: some View {
        NavigationSplitView {
            sidebar
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detailPane
                .toolbar(removing: .sidebarToggle)
        }
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            sectionHeader
            selectedContent
                .environment(\.floatingPlayerClearance, playerHeight + 36)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .textBackgroundColor))
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .bottom) {
            ToolbarPlayer(player: player, openNowPlaying: { showNowPlaying = true })
                .frame(maxWidth: 760)
                .background {
                    GeometryReader { geometry in
                        Color.clear.onAppear { playerHeight = geometry.size.height }
                            .onChange(of: geometry.size.height) { _, height in playerHeight = height }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 18)
        }
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
                .id(playlist.id)
            } else {
                let sectionName: String = {
                    if case .section(let s) = selection {
                        return s == .home ? "Recently Added" : s.rawValue
                    }
                    return "Recently Added"
                }()
                LibraryContent(library: library, player: player,
                               section: sectionName,
                               selectedAlbum: $selectedAlbum, albumSortOrder: albumSortOrder)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sectionTitle: String {
        switch selection {
        case .section(let section): section.rawValue
        case .playlist(let id): library.playlists.first { $0.id == id }?.name ?? "Playlist"
        case nil: "Albums"
        }
    }

    private var showsSongSort: Bool {
        selection == .section(.songs) || selection == .section(.favorites)
    }

    private var sectionHeader: some View {
        HStack(spacing: 12) {
            if selectedAlbum != nil {
                Button { selectedAlbum = nil } label: {
                    Image(systemName: "chevron.left").frame(width: 24, height: 28)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Back to albums").help("Back to albums")
            }
            Text(sectionTitle).font(.system(size: 13, weight: .semibold))
                .lineLimit(1).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Menu {
                if case .section(.albums) = selection {
                    Picker("Sort Albums", selection: $albumSortOrder) {
                        ForEach(AlbumSortOrder.allCases) { order in Text(order.rawValue).tag(order) }
                    }
                    Divider()
                }
                if showsSongSort {
                    Picker("Sort Songs", selection: $songSortOrder) {
                        ForEach(TrackSortOrder.allCases) { order in Text(order.rawValue).tag(order) }
                    }
                    Toggle("Reverse Order", isOn: $reverseSongSort)
                    Divider()
                }
                SettingsLink { Label("Music Folder Settings…", systemImage: "gearshape") }
                Divider()
                Button("Open Audio File…", systemImage: "doc.waveform") { importingFolder = false; showImporter = true }
                    .disabled(player.isBusy)
                Button("Add Folder…", systemImage: "folder.badge.plus") { openFolderPicker() }
                    .disabled(library.isScanning)
                Button("Rescan Library", systemImage: "arrow.clockwise") { Task { await library.rescan() } }
                    .disabled(library.isScanning || library.folders.isEmpty)
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 13)).frame(width: 30, height: 30)
                    .background(.regularMaterial, in: Circle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(.secondary)
            .help("View and library options").accessibilityLabel("View and library options")
            HStack(spacing: 6) {
                Menu {
                    Picker("Search In", selection: $library.searchScope) {
                        ForEach(TrackSearchScope.allCases) { scope in Text(scope.rawValue).tag(scope) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(library.searchScope == .all ? Color.secondary : .pink)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Search field: " + library.searchScope.rawValue)
                .help("Search in " + library.searchScope.rawValue + ". Click to change fields.")
                TextField(library.searchScope == .all ? "Find in \(sectionTitle)" : "Search \(library.searchScope.rawValue)", text: $library.search)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel("Search " + library.searchScope.rawValue)
                    .help("Match the beginning of words in " + library.searchScope.rawValue.lowercased())
                    .onKeyPress(.escape) { library.search = ""; searchFocused = false; return .handled }
                if !library.search.isEmpty {
                    Button { library.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel("Clear search")
                }
            }
            .font(.system(size: 12)).padding(.horizontal, 10).frame(width: 180, height: 30)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.primary.opacity(0.04), lineWidth: 0.5))
        }
        .padding(.horizontal, 24).frame(height: 54)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    Button { searchFocused = true } label: {
                        sidebarLabel("Search", symbol: "magnifyingglass", selected: false)
                    }
                    .buttonStyle(.plain).keyboardShortcut("f", modifiers: .command).help("Find music (⌘F)")
                    navigationRow(.section(.home), title: "Home", symbol: "house")
                    sidebarHeading("Library").padding(.top, 18)
                    ForEach(LibrarySection.allCases.filter { $0 != .home }) { section in
                        navigationRow(.section(section), title: section.rawValue, symbol: section.symbol)
                    }
                    HStack {
                        sidebarHeading("Playlists")
                        Spacer()
                        Button {
                            playlistNameInput = ""; showNewPlaylistAlert = true
                        } label: { Image(systemName: "plus").font(.system(size: 11)) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .help("New Playlist").accessibilityLabel("Create New Playlist")
                    }.padding(.top, 18).padding(.trailing, 10)
                    ForEach(library.playlists) { playlist in
                        navigationRow(.playlist(playlist.id), title: playlist.name, symbol: "music.note.list")
                            .contextMenu {
                                Button("Rename…") {
                                    playlistToRename = playlist; playlistNameInput = playlist.name; showRenameAlert = true
                                }
                                Button("Delete Playlist", role: .destructive) {
                                    playlistToDelete = playlist; showDeleteAlert = true
                                }
                            }
                    }
                    sidebarHeading("Music Folders").padding(.top, 18)
                    ForEach(library.folders) { folder in
                        Label(URL(fileURLWithPath: folder.path).lastPathComponent, systemImage: "folder")
                            .font(.system(size: 12)).lineLimit(1).foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 6).help(folder.path)
                            .contextMenu {
                                Button("Remove from Library", role: .destructive) { Task { await library.removeFolder(folder) } }
                                    .disabled(library.isScanning)
                            }
                    }
                    Button { openFolderPicker() } label: {
                        sidebarLabel("Add Folder…", symbol: "folder.badge.plus", selected: false)
                    }.buttonStyle(.plain).disabled(library.isScanning)
                }.padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 16)
            }
            .focusable().focused($sidebarFocused).focusEffectDisabled()
            .onMoveCommand { direction in
                let choices = LibrarySection.allCases.map { SidebarSelection.section($0) } + library.playlists.map { .playlist($0.id) }
                guard let selection, let index = choices.firstIndex(of: selection) else { return }
                let next = direction == .down ? index + 1 : direction == .up ? index - 1 : index
                if choices.indices.contains(next) { self.selection = choices[next] }
            }
            HStack(spacing: 8) {
                Image(nsImage: Self.brandIcon)
                    .resizable().frame(width: 28, height: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Swar").font(.system(size: 12, weight: .semibold))
                    Text("Your local music").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                SettingsLink { Image(systemName: "gearshape").font(.system(size: 12)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Settings (⌘,)")
                    .accessibilityLabel("Settings")
            }.padding(12)
        }
        .background { SidebarMaterial().ignoresSafeArea() }
        .navigationSplitViewColumnWidth(min: 170, ideal: 184, max: 200)
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)
    }

    private func navigationRow(_ choice: SidebarSelection, title: String, symbol: String) -> some View {
        Button { selection = choice; sidebarFocused = true } label: {
            sidebarLabel(title, symbol: symbol, selected: selection == choice)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == choice ? .isSelected : [])
    }

    private func sidebarLabel(_ title: String, symbol: String, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 14)).frame(width: 17)
            Text(title).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.pink : .primary)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Color.primary.opacity(0.055) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
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
