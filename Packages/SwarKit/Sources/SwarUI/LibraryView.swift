import SwiftUI
import Player
import Library
import UniformTypeIdentifiers
import AppKit


private enum SidebarSelection: Hashable {
    case section(LibrarySection)
    case playlist(String)
}

private struct SharedTrackPageRequest: Equatable {
    let selection: SidebarSelection?
    let search: String
    let scope: TrackSearchScope
    let sort: TrackSortOrder
    let reversed: Bool
}

/// Local library browsing and the single-file playback surface.
@MainActor
public struct LibraryView: View {
    @Environment(\.swarPalette) private var palette
    @State private var selection: SidebarSelection? = .section(.home)
    @AppStorage("sidebarLayout") private var sidebarLayoutData = ""
    @State private var showSidebarCustomization = false
    private var sidebarLayout: SidebarLayout { SidebarLayout(serialized: sidebarLayoutData) }
    @AppStorage("albumSortOrder") private var albumSortOrder: AlbumSortOrder = .artist
    @AppStorage("reverseAlbumSort") private var reverseAlbumSort = false
    @AppStorage("songSortOrder") private var songSortOrder: TrackSortOrder = .album
    @AppStorage("reverseSongSort") private var reverseSongSort = false
    @FocusState private var searchFocused: Bool
    @FocusState private var sidebarFocused: Bool
    @State private var player = Player(sessionStore: .applicationDefault())
    @State private var selectedAlbum: String?
    @State private var requestedAlbum: String?
    @State private var showImporter = false
    @State private var showNowPlaying = false
    @State private var windowWidth: CGFloat = 900
    @State private var playerHeight: CGFloat = 56
    @State private var importingFolder = false
    @State private var lastTrackSearch: String?
    @State private var library: LibraryModel

    @State private var showPlaylistImport = false
    @State private var playlistToExport: LibraryPlaylist?
    @State private var showNewSmartPlaylist = false
    @State private var smartPlaylistToEdit: LibraryPlaylist?
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
        .onChange(of: sidebarLayoutData, initial: true) {
            switch selection {
            case .section(let section) where !sidebarLayout.visibleSections.contains(section):
                selection = .section(sidebarLayout.visibleSections[0])
            case .playlist where !sidebarLayout.visibleGroups.contains(.playlists):
                selection = .section(sidebarLayout.visibleSections[0])
            case nil: selection = .section(sidebarLayout.visibleSections[0])
            default: break
            }
        }
        .sheet(isPresented: $showSidebarCustomization) {
            VStack(spacing: 0) {
                HStack {
                    Text("Sidebar").font(.headline)
                    Spacer()
                    Button("Done") { showSidebarCustomization = false }.keyboardShortcut(.defaultAction)
                }.padding(20)
                SidebarSettingsView()
            }.frame(width: 480, height: 480)
        }
        .task {
            player.onQualifiedListen = { [weak library] url, date in
                Task { await library?.recordListen(at: url, date: date) }
            }
            player.enableSystemMediaControls()
            await player.restoreSession()
        }
        .task(id: "\(library.isReady)-\(player.isRestoredSession)") {
            guard library.isReady else { return }
            // Older saved queues can still point at migrated custom-art cache URLs.
            let changes = player.queue.compactMap { entry -> LibraryArtworkChange? in
                guard let old = entry.artworkURL, old.lastPathComponent.hasPrefix("custom-"),
                      let durable = library.artworkURL(old.lastPathComponent), durable != old else { return nil }
                return LibraryArtworkChange(fileURL: entry.url, artworkURL: durable)
            }
            if !changes.isEmpty { player.updateLibraryArtwork(changes) }
        }
        .task {
            while !Task.isCancelled {
                await player.refreshVolume()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                await player.saveSessionIfNeeded()
            }
        }
        .task(id: sharedTrackPageRequest) {
            guard !Task.isCancelled else { return }
            let request = sharedTrackPageRequest
            library.favoritesOnly = request.selection == .section(.favorites)
            library.sortOrder = request.sort
            library.reverseSort = request.reversed
            library.recentFirst = request.selection == .section(.recentlyAdded) || request.selection == .section(.home)
            guard usesSharedTrackPage else { return }
            if let previous = lastTrackSearch, previous != request.search {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            guard !Task.isCancelled, request == sharedTrackPageRequest else { return }
            lastTrackSearch = request.search
            await library.reload(resetLimit: true)
        }
        .task(id: player.isPlaying) {
            while player.isPlaying && !Task.isCancelled {
                await player.refresh()
                do { try await Task.sleep(for: .milliseconds(400)) }
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
        .sheet(isPresented: $showPlaylistImport) {
            PlaylistImportView(library: library) { playlist in
                library.search = ""; selection = .playlist(playlist.id); showPlaylistImport = false
            }
        }
        .sheet(item: $playlistToExport) { playlist in PlaylistExportView(library: library, playlist: playlist) }
        .sheet(isPresented: $showNewSmartPlaylist) {
            SmartPlaylistEditorView(library: library) { playlist in
                library.search = ""; selection = .playlist(playlist.id)
            }
        }
        .sheet(item: $smartPlaylistToEdit) { playlist in
            SmartPlaylistEditorView(library: library, playlist: playlist) { _ in }
        }
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
        .tint(palette.accent)
        .accentColor(palette.accent)
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
            if new != .section(.albums) { requestedAlbum = nil }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView(player: player, library: library, width: max(640, min(900, windowWidth - 40)),
                browseArtist: { artist in
                    library.searchScope = .artist; library.search = artist
                    selection = .section(.artists)
                }, browseAlbum: { album in
                    library.searchScope = .album; library.search = album
                    selection = .section(.albums)
                })
        }
        .environment(\.libraryNavigation, LibraryNavigation(go: navigate))
        .environment(\.libraryPlayer, player)
    }

    private func navigate(_ destination: LibraryDestination) {
        showNowPlaying = false
        searchFocused = false
        switch destination {
        case .album(let artist, let title):
            library.search = ""; library.searchScope = .all
            requestedAlbum = artist + "\u{1f}" + title
            selection = .section(.albums)
        case .artist(let name):
            library.searchScope = .artist; library.search = name
            selection = .section(.artists)
        case .genre(let name):
            library.searchScope = .genre; library.search = name
            selection = .section(.genres)
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
            ToolbarPlayer(player: player, library: library, openNowPlaying: { showNowPlaying = true })
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
                    openListening: { selection = .section(.listening) },
                    browseAlbum: { album in
                        navigate(.album(artist: album.artist, title: album.title))
                    }, addFolder: openFolderPicker)
                .libraryFolderDrop(library: library)
            } else if selection == .section(.listening) {
                ListeningHistoryView(library: library, player: player)
                .libraryFolderDrop(library: library)
            } else if selection == .section(.manage) {
                CollectionManagerView(library: library, player: player, addFolder: openFolderPicker)
                .libraryFolderDrop(library: library)
            } else if selection == .section(.albums) || selection == .section(.recentlyAdded) {
                AlbumBrowserView(library: library, player: player,
                    recent: selection == .section(.recentlyAdded), selectedAlbum: $selectedAlbum, requestedAlbum: $requestedAlbum,
                    sortOrder: $albumSortOrder, reversed: $reverseAlbumSort)
                .libraryFolderDrop(library: library)
            } else {
                let sectionName: String = {
                    if case .section(let s) = selection {
                        return s == .home ? "Songs" : s.rawValue
                    }
                    return "Recently Added"
                }()
                LibraryContent(library: library, player: player,
                               section: sectionName)
                .libraryFolderDrop(library: library)
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

    private var sharedTrackPageRequest: SharedTrackPageRequest {
        SharedTrackPageRequest(selection: selection, search: library.search, scope: library.searchScope,
                               sort: showsSongSort ? songSortOrder : .album,
                               reversed: showsSongSort && reverseSongSort)
    }

    // Albums, collection management and playlists own their database snapshots.
    // Do not also fetch/sort an unused 500-song page for their search updates.
    private var usesSharedTrackPage: Bool {
        switch selection {
        case .section(.albums), .section(.recentlyAdded), .section(.manage), .section(.listening), .playlist: false
        case .section(.home): !TrackSearchQuery(library.search).isEmpty
        default: true
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: 12) {
            if selectedAlbum != nil {
                Button { selectedAlbum = nil } label: {
                    Image(systemName: "chevron.left").frame(width: 24, height: 28)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Back to albums").help("Back to albums")
            }
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
                Button("Import Playlist…", systemImage: "square.and.arrow.down") { showPlaylistImport = true }
                    .disabled(!library.isReady)
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
                        .foregroundStyle(library.searchScope == .all ? Color.secondary : palette.accent)
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
                    .foregroundStyle(palette.accent).frame(width: 42, height: 42)
                    .background(palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityHidden(true)
                Text("Swar").font(.system(size: 24, weight: .semibold, design: .serif))
                Spacer(minLength: 0)
            }.padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 18)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    Button { searchFocused = true } label: {
                        SidebarItemLabel(title: "Search", symbol: "magnifyingglass", isSearch: true)
                    }
                    .buttonStyle(.plain).keyboardShortcut("f", modifiers: .command).help("Find music (⌘F)")
                    .padding(.bottom, 10)
                    ForEach(sidebarLayout.visibleGroups) { group in
                        switch group {
                        case .library:
                            sidebarHeading("Library").padding(.top, 8)
                            ForEach(sidebarLayout.visibleSections) { section in
                                navigationRow(.section(section), title: section.rawValue, symbol: section.symbol)
                            }
                        case .playlists: sidebarPlaylists
                        case .folders: sidebarFolders
                        }
                    }
                }.padding(.horizontal, 12).padding(.bottom, 18)
            }
            .focusable().focused($sidebarFocused).focusEffectDisabled()
            .onMoveCommand { direction in
                let choices: [SidebarSelection] = sidebarLayout.visibleGroups.flatMap { group -> [SidebarSelection] in
                    switch group {
                    case .library: return sidebarLayout.visibleSections.map { SidebarSelection.section($0) }
                    case .playlists: return library.playlists.map { SidebarSelection.playlist($0.id) }
                    case .folders: return []
                    }
                }
                guard direction == .down || direction == .up else { return }
                guard let selection, let index = choices.firstIndex(of: selection) else {
                    self.selection = direction == .down ? choices.first : choices.last
                    return
                }
                let next = direction == .down ? index + 1 : index - 1
                if choices.indices.contains(next) { self.selection = choices[next] }
            }
            HStack(spacing: 0) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                        .font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12).contentShape(RoundedRectangle(cornerRadius: 12))
                        .background(SwarTheme.surface.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Settings (⌘,)")
                Button { showSidebarCustomization = true } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 30, height: 36)
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("Customize Sidebar…").accessibilityLabel("Customize Sidebar")
            }.padding(12)
        }
        .background {
            SidebarMaterial().ignoresSafeArea()
                .overlay { SwarTheme.canvas.opacity(0.18).ignoresSafeArea().allowsHitTesting(false) }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    }

    private var sidebarPlaylists: some View {
        Group {
            HStack {
                sidebarHeading("Playlists")
                Spacer()
                Menu {
                    Button("New Playlist…") { playlistNameInput = ""; showNewPlaylistAlert = true }
                    Button("New Smart Playlist…", systemImage: "sparkles") { showNewSmartPlaylist = true }
                    Divider()
                    Button("Import Playlist…", systemImage: "square.and.arrow.down") { showPlaylistImport = true }.disabled(!library.isReady)
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                        .frame(width: 24, height: 24).contentShape(Circle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(palette.accent)
                .help("New Playlist").accessibilityLabel("Create Playlist")
            }.padding(.top, 16).padding(.trailing, 4)
            ForEach(library.playlists) { playlist in
                navigationRow(.playlist(playlist.id), title: playlist.name, symbol: playlist.isSmart ? "sparkles" : "music.note.list")
                    .playlistSongDrop(library: library, playlist: playlist)
                    .help(playlist.name)
                    .contextMenu {
                        Button("Export Playlist…", systemImage: "square.and.arrow.up") { playlistToExport = playlist }
                    if playlist.isSmart { Button("Edit Rules…") { smartPlaylistToEdit = playlist } }
                        Button("Rename…") {
                            playlistToRename = playlist; playlistNameInput = playlist.name; showRenameAlert = true
                        }
                        Button("Delete Playlist", role: .destructive) {
                            playlistToDelete = playlist; showDeleteAlert = true
                        }
                    }
            }
        }
    }

    private var sidebarFolders: some View {
        Group {
            sidebarHeading("Music Folders").padding(.top, 16)
            ForEach(library.folders) { folder in
                HStack(spacing: 10) {
                    Image(systemName: "folder").font(.system(size: 14)).frame(width: 22)
                        .foregroundStyle(palette.accent.opacity(0.8))
                    Text(URL(fileURLWithPath: folder.path).lastPathComponent)
                        .font(.system(size: 12)).lineLimit(1)
                    Spacer(minLength: 0)
                    Circle().fill(library.isMonitoring(folder) ? palette.accent : .orange)
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
            .libraryFolderDrop(library: library)
        }
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

#if canImport(PreviewsMacros)
#Preview {
    LibraryView()
        .frame(width: 1100, height: 740)
}
#endif
