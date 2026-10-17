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
    @State private var selection: SidebarSelection? = .section(.home)
    @AppStorage("albumSortOrder") private var albumSortOrder: AlbumSortOrder = .artist
    @AppStorage("reverseAlbumSort") private var reverseAlbumSort = false
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
        .tint(SwarTheme.accent)
        .accentColor(SwarTheme.accent)
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
        .onChange(of: selection) { old, new in
            if old != .section(.home) || new != .section(.albums) { selectedAlbum = nil }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView(player: player, width: max(640, min(900, windowWidth - 40)),
                browseArtist: { artist in
                    library.searchScope = .artist; library.search = artist
                    selection = .section(.artists)
                }, browseAlbum: { album in
                    library.searchScope = .album; library.search = album
                    selection = .section(.albums)
                })
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
        .background(SwarTheme.canvas)
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
            } else if selection == .section(.home), TrackSearchQuery(library.search).isEmpty {
                HomeView(library: library, player: player,
                    openNowPlaying: { showNowPlaying = true },
                    openFavourites: { selection = .section(.favorites) },
                    openRecent: { selection = .section(.recentlyAdded) },
                    browseAlbum: { album in
                        library.search = ""
                        selection = .section(.albums)
                        selectedAlbum = album.id
                    }, addFolder: openFolderPicker)
            } else if selection == .section(.albums) || selection == .section(.recentlyAdded) {
                AlbumBrowserView(library: library, player: player,
                    recent: selection == .section(.recentlyAdded), selectedAlbum: $selectedAlbum,
                    sortOrder: albumSortOrder, reversed: reverseAlbumSort)
            } else {
                let sectionName: String = {
                    if case .section(let s) = selection {
                        return s == .home ? "Songs" : s.rawValue
                    }
                    return "Recently Added"
                }()
                LibraryContent(library: library, player: player,
                               section: sectionName)
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
                    Toggle("Reverse Order", isOn: $reverseAlbumSort)
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
                        .foregroundStyle(library.searchScope == .all ? Color.secondary : SwarTheme.accent)
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
        .background(SwarTheme.canvas)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Text("स्व").font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(SwarTheme.accent).frame(width: 42, height: 42)
                    .background(SwarTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Swar").font(.system(size: 24, weight: .semibold, design: .serif))
                    Text("Your music, close by.").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    Button { searchFocused = true } label: {
                        SidebarItemLabel(title: "Search", symbol: "magnifyingglass", isSearch: true)
                    }
                    .buttonStyle(.plain).keyboardShortcut("f", modifiers: .command).help("Find music (⌘F)")
                    .padding(.bottom, 10)
                    navigationRow(.section(.home), title: "Home", symbol: "house")
                    sidebarHeading("Library").padding(.top, 16)
                    ForEach(LibrarySection.allCases.filter { $0 != .home }) { section in
                        navigationRow(.section(section), title: section.rawValue, symbol: section.symbol)
                    }
                    HStack {
                        sidebarHeading("Playlists")
                        Spacer()
                        Button {
                            playlistNameInput = ""; showNewPlaylistAlert = true
                        } label: {
                            Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                                .frame(width: 24, height: 24).contentShape(Circle())
                        }
                        .buttonStyle(.plain).foregroundStyle(SwarTheme.accent)
                        .help("New Playlist").accessibilityLabel("Create New Playlist")
                    }.padding(.top, 16).padding(.trailing, 4)
                    if library.playlists.isEmpty {
                        Text("Your playlists will appear here.").font(.system(size: 11))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    ForEach(library.playlists) { playlist in
                        navigationRow(.playlist(playlist.id), title: playlist.name, symbol: "music.note.list")
                            .help(playlist.name)
                            .contextMenu {
                                Button("Rename…") {
                                    playlistToRename = playlist; playlistNameInput = playlist.name; showRenameAlert = true
                                }
                                Button("Delete Playlist", role: .destructive) {
                                    playlistToDelete = playlist; showDeleteAlert = true
                                }
                            }
                    }
                    sidebarHeading("Music Folders").padding(.top, 16)
                    ForEach(library.folders) { folder in
                        HStack(spacing: 10) {
                            Image(systemName: "folder").font(.system(size: 14)).frame(width: 22)
                                .foregroundStyle(SwarTheme.accent.opacity(0.8))
                            Text(URL(fileURLWithPath: folder.path).lastPathComponent)
                                .font(.system(size: 12)).lineLimit(1)
                            Spacer(minLength: 0)
                            Circle().fill(library.isMonitoring(folder) ? SwarTheme.accent : .orange)
                                .frame(width: 5, height: 5).accessibilityHidden(true)
                        }
                        .padding(.horizontal, 12).frame(minHeight: 34)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(URL(fileURLWithPath: folder.path).lastPathComponent)
                        .accessibilityValue(library.isMonitoring(folder) ? "Watching for changes" : "Folder needs attention")
                        .help(folder.path + (library.isMonitoring(folder) ? "\nWatching for changes" : "\nCheck access in Settings"))
                        .contextMenu {
                            Button("Remove from Library", role: .destructive) { Task { await library.removeFolder(folder) } }
                                .disabled(library.isScanning)
                        }
                    }
                    Button { openFolderPicker() } label: {
                        SidebarItemLabel(title: "Add Folder…", symbol: "folder.badge.plus")
                    }.buttonStyle(.plain).disabled(library.isScanning)
                }.padding(.horizontal, 12).padding(.bottom, 18)
            }
            .focusable().focused($sidebarFocused).focusEffectDisabled()
            .onMoveCommand { direction in
                let choices = LibrarySection.allCases.map { SidebarSelection.section($0) } + library.playlists.map { .playlist($0.id) }
                guard let selection, let index = choices.firstIndex(of: selection) else { return }
                let next = direction == .down ? index + 1 : direction == .up ? index - 1 : index
                if choices.indices.contains(next) { self.selection = choices[next] }
            }
            HStack(spacing: 9) {
                Image(systemName: "waveform.circle.fill").font(.system(size: 25)).foregroundStyle(SwarTheme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Local library").font(.system(size: 12, weight: .medium))
                    Text("\(library.folders.count) \(library.folders.count == 1 ? "music folder" : "music folders")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                SettingsLink {
                    Image(systemName: "gearshape").font(.system(size: 13))
                        .frame(width: 30, height: 30).background(SwarTheme.surface.opacity(0.65), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Settings (⌘,)")
                .accessibilityLabel("Settings")
            }
            .padding(12).background(SwarTheme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.04), lineWidth: 0.5))
            .padding(12)
        }
        .background {
            SidebarMaterial().ignoresSafeArea()
                .overlay { SwarTheme.canvas.opacity(0.18).ignoresSafeArea().allowsHitTesting(false) }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    }

    private func sidebarHeading(_ title: String) -> some View {
        Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(1.2)
            .foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func navigationRow(_ choice: SidebarSelection, title: String, symbol: String) -> some View {
        Button { selection = choice; sidebarFocused = true } label: {
            SidebarItemLabel(title: title, symbol: symbol, selected: selection == choice)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == choice ? .isSelected : [])
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
