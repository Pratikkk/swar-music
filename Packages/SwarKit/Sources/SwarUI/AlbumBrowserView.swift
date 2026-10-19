import SwiftUI
import Library
import Player

private enum AlbumViewMode: String { case grid, list }

@MainActor
struct AlbumBrowserView: View {
    @Environment(\.swarDensity) private var density
    let library: LibraryModel
    let player: Player
    let recent: Bool
    @Binding var selectedAlbum: String?
    @Binding var requestedAlbum: String?
    @Binding var sortOrder: AlbumSortOrder
    @Binding var reversed: Bool
    @Environment(\.floatingPlayerClearance) private var clearance
    @AppStorage("albumViewMode") private var viewMode: AlbumViewMode = .grid
    @AppStorage("albumCoverSize") private var coverSize = 160.0
    @State private var albums: [LibraryAlbumSummary] = []
    @State private var detailTracks: [LibraryTrack] = []
    @State private var ready = false
    @State private var loadError: String?
    @State private var detailID: String?
    @AppStorage("albumBrowseFilter") private var filter: AlbumBrowseFilter = .all
    @State private var arranger = AlbumBrowseArranger()
    @State private var presentation: AlbumBrowseSnapshot?
    @State private var arranging = false
    @State private var totals: AlbumBrowseTotals?
    @State private var nextOffset = 0
    @State private var hasMore = false
    @State private var loadingMore = false
    @State private var pageError: String?
    @State private var detailAlbum: LibraryAlbumSummary?
    private let pageSize = 200
    @State private var loadedKey: String?
    @State private var loadGeneration = UUID()
    @State private var actionInProgress = false

    private var refreshKey: String {
        // Favourite changes must not reset album pagination; scans, metadata and
        // artwork changes bump trackActionsRevision or lastScanAt.
        "\(library.isReady)-\(library.trackActionsRevision)-\(library.lastScanAt?.timeIntervalSince1970 ?? 0)-\(library.searchScope)-\(library.search)-\(sortOrder)-\(reversed)-\(recent)-\(filter)"
    }
    var body: some View {
        let currentTrackID = library.trackID(at: player.currentURL)
        ZStack {
            // Keep the browser mounted to preserve its scroll position when returning from details.
            browser.opacity(selectedAlbum == nil ? 1 : 0)
                .allowsHitTesting(selectedAlbum == nil).accessibilityHidden(selectedAlbum != nil)
            if let selectedAlbum {
                if detailID == selectedAlbum, let album = detailAlbum {
                    detail(album, currentTrackID: currentTrackID)
                } else { ProgressView("Opening album…") }
            }
        }
        .task(id: refreshKey) { await reload() }
        .task(id: "\(selectedAlbum ?? "")-\(refreshKey)-\(ready)") { await loadDetail() }
        .onChange(of: library.search) { selectedAlbum = nil }
        .onChange(of: library.searchScope) { selectedAlbum = nil }
        .onChange(of: requestedAlbum, initial: true) { openRequestedAlbum() }
    }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recent ? "Recent arrivals" : "Albums")
                        .font(.system(size: 26, weight: .semibold, design: .serif))
                    Text(presentation?.summary ?? "")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                ZStack {
                    if arranging { ProgressView().controlSize(.small).accessibilityLabel("Updating albums") }
                }.frame(width: 14, height: 14)
                if !recent {
                    Menu {
                        Picker("Sort by", selection: $sortOrder) {
                            ForEach(AlbumSortOrder.allCases) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.inline)
                        Toggle("Reverse Order", isOn: $reversed)
                    } label: { Label(sortOrder.rawValue, systemImage: "arrow.up.arrow.down") }
                    .fixedSize().accessibilityLabel("Sort albums")
                }
                if viewMode == .grid {
                    HStack(spacing: 8) {
                        Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
                        Slider(value: $coverSize, in: 120...220, step: 20).frame(width: 90)
                            .accessibilityLabel("Album artwork size").help("Adjust album artwork size")
                        Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
                    }
                }
                Picker("Album view", selection: $viewMode) {
                    Image(systemName: "square.grid.2x2").tag(AlbumViewMode.grid).accessibilityLabel("Grid view")
                    Image(systemName: "list.bullet").tag(AlbumViewMode.list).accessibilityLabel("List view")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 76)
                    .help("Switch between grid and list")
            }.padding(.horizontal, 28).padding(.vertical, 16)
            Picker("Filter albums", selection: $filter) {
                ForEach(AlbumBrowseFilter.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
                .frame(maxWidth: 380).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.bottom, 12)
            LibraryStatusBanner(library: library, inset: 28, dismissibleError: true)
            if let loadError {
                ContentUnavailableView {
                    Label("Couldn’t Load Albums", systemImage: "exclamationmark.triangle")
                } description: { Text(loadError) } actions: {
                    Button("Try Again") { Task { await reload() } }
                }
            } else if !ready || presentation == nil {
                ProgressView("Loading albums…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if presentation?.albumCount == 0 {
                ContentUnavailableView {
                    Label(filter != .all ? "No Matching Albums" : TrackSearchQuery(library.search).isEmpty ? "No Albums Yet" : "No Matching Albums", systemImage: "square.stack")
                } description: {
                    Text(filter != .all ? "Try another filter or search." : TrackSearchQuery(library.search).isEmpty ? "Add a music folder to start your collection." : "Try a different album, artist, or song.")
                } actions: {
                    if filter != .all { Button("Show All Albums") { filter = .all } }
                    else if !TrackSearchQuery(library.search).isEmpty { Button("Clear Search") { library.search = "" } }
                    else { SettingsLink { Text("Music Folder Settings…") } }
                }
            } else {
                albumCollection
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var albumCollection: some View {
        ScrollViewReader { proxy in
            Group {
                if viewMode == .grid {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(presentation?.sections ?? []) { section in
                                if recent { Text(section.title).font(.system(size: 17, weight: .semibold)).padding(.top, 8) }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: max(120, min(220, coverSize))), spacing: density.gridGap, alignment: .top)], alignment: .leading, spacing: density.gridGap + 4) {
                                    ForEach(section.albums) { album in
                                        AlbumBrowserCard(album: album, artworkURL: library.artworkURL(album.artworkKey),
                                            busy: player.isBusy || actionInProgress,
                                            maximumPixels: coverSize <= 140 ? 256 : coverSize >= 200 ? 512 : 384,
                                            open: { selectedAlbum = album.id }, play: { perform(album) })
                                            .albumActions(library: library, player: player, album: album).id(album.id)
                                    }
                                }
                            }
                            pageFooter
                        }.padding(.horizontal, 28).padding(.top, 8).padding(.bottom, clearance + 24)
                            .id("album-browser-top")
                    }
                } else {
                    List {
                        Color.clear.frame(height: 0).id("album-browser-top")
                            .listRowSeparator(.hidden).listRowInsets(EdgeInsets())
                        ForEach(presentation?.sections ?? []) { section in
                            Section {
                                ForEach(section.albums) { album in
                                    AlbumBrowserRow(album: album, artworkURL: library.artworkURL(album.artworkKey),
                                        busy: player.isBusy || actionInProgress,
                                        open: { selectedAlbum = album.id }, play: { perform(album) })
                                        .albumActions(library: library, player: player, album: album)
                                        .listRowInsets(EdgeInsets(top: density == .compact ? 4 : 6, leading: 28, bottom: density == .compact ? 4 : 6, trailing: 28))
                                        .listRowBackground(Color.clear).id(album.id)
                                }
                            } header: {
                                if recent { Text(section.title).font(.system(size: 17, weight: .semibold)) }
                            }
                        }
                        pageFooter.listRowSeparator(.hidden).listRowBackground(Color.clear)
                        Color.clear.frame(height: clearance + 24)
                            .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    }.listStyle(.plain).scrollContentBackground(.hidden)
                        .environment(\.defaultMinListRowHeight, 0)
                        .accessibilityLabel("Album list")
                }
            }
            .onChange(of: library.search) { proxy.scrollTo("album-browser-top", anchor: .top) }
            .onChange(of: library.searchScope) { proxy.scrollTo("album-browser-top", anchor: .top) }
            .onChange(of: recent) { proxy.scrollTo("album-browser-top", anchor: .top) }
            .onChange(of: sortOrder) { proxy.scrollTo("album-browser-top", anchor: .top) }
            .onChange(of: reversed) { proxy.scrollTo("album-browser-top", anchor: .top) }
            .onChange(of: filter) { proxy.scrollTo("album-browser-top", anchor: .top) }
        }
    }

    @ViewBuilder private var pageFooter: some View {
        if hasMore {
            HStack {
                Spacer()
                if let pageError {
                    VStack(spacing: 8) {
                        Text(pageError).font(.caption).foregroundStyle(.secondary)
                        Button("Try Again") { Task { await loadMore() } }
                    }
                } else {
                    ProgressView().controlSize(.small)
                        .id("\(loadedKey ?? "")-\(nextOffset)-\(selectedAlbum == nil)")
                        // Finish this bounded request even if the footer scrolls away.
                        // Query generations still reject results after a reload.
                        .onAppear { Task { await loadMore() } }
                }
                Spacer()
            }.padding(.vertical, 12)
        }
    }

    private func openRequestedAlbum() {
        guard ready, loadedKey == refreshKey, let id = requestedAlbum else { return }
        filter = .all
        selectedAlbum = id
        requestedAlbum = nil
    }

    private func reload() async {
        guard library.isReady else { return }
        let key = refreshKey, generation = UUID()
        loadGeneration = generation
        arranging = true; loadingMore = false; pageError = nil
        defer { if generation == loadGeneration { arranging = false } }
        do {
            guard let page = try await library.albumPage(search: library.search, scope: library.searchScope,
                sort: recent ? .recentlyAdded : sortOrder, reversed: recent ? false : reversed,
                filter: filter, limit: pageSize) else { return }
            let result = try await arranger.arrange(page.albums, recent: recent, filter: .all, totals: page.totals)
            guard !Task.isCancelled, key == refreshKey, generation == loadGeneration else { return }
            albums = page.albums; totals = page.totals; presentation = result
            nextOffset = page.albums.count; hasMore = nextOffset < page.totals.albumCount
            ready = true; loadError = nil; loadedKey = key
            openRequestedAlbum()
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, key == refreshKey, generation == loadGeneration else { return }
            loadError = error.localizedDescription; ready = true
        }
    }

    private func loadMore() async {
        guard !loadingMore, hasMore, loadedKey == refreshKey, selectedAlbum == nil, let totals else { return }
        let key = refreshKey, generation = loadGeneration, offset = nextOffset
        loadingMore = true; pageError = nil
        defer { if generation == loadGeneration { loadingMore = false } }
        do {
            let page = try await library.albums(search: library.search, scope: library.searchScope,
                sort: recent ? .recentlyAdded : sortOrder, reversed: recent ? false : reversed,
                filter: filter, limit: pageSize, offset: offset)
            guard !Task.isCancelled, key == refreshKey, generation == loadGeneration else { return }
            // A scan may change rows before its revision arrives. Avoid duplicate card IDs;
            // the revision then resets pagination from a fresh database snapshot.
            var seen = Set(albums.map(\.id))
            let combined = albums + page.filter { seen.insert($0.id).inserted }
            let result = try await arranger.arrange(combined, recent: recent, filter: .all, totals: totals)
            guard !Task.isCancelled, key == refreshKey, generation == loadGeneration else { return }
            albums = combined; presentation = result; nextOffset = offset + page.count
            hasMore = !page.isEmpty && nextOffset < totals.albumCount
        } catch is CancellationError { }
        catch {
            guard !Task.isCancelled, key == refreshKey, generation == loadGeneration else { return }
            pageError = error.localizedDescription
        }
    }

    private func loadDetail() async {
        guard let id = selectedAlbum else { detailID = nil; detailAlbum = nil; return }
        guard library.isReady else { return }
        do {
            // Home and context-menu navigation may target an album outside loaded pages.
            let album: LibraryAlbumSummary?
            if let loaded = albums.first(where: { $0.id == id }) { album = loaded }
            else { album = try await library.album(id: id) }
            guard !Task.isCancelled, selectedAlbum == id else { return }
            guard let album else { selectedAlbum = nil; return }
            let tracks = await library.tracks(in: album)
            guard !Task.isCancelled, selectedAlbum == id else { return }
            if tracks.isEmpty { selectedAlbum = nil }
            else { detailTracks = tracks; detailAlbum = album; detailID = id }
        } catch {
            guard !Task.isCancelled, selectedAlbum == id else { return }
            loadError = error.localizedDescription; selectedAlbum = nil
        }
    }

    private func detail(_ album: LibraryAlbumSummary, currentTrackID: String?) -> some View {
        AlbumDetailView(title: album.title, artist: album.artist, tracks: detailTracks,
            artworkURL: library.artworkURL(album.artworkKey), player: player, library: library,
            playlists: library.manualPlaylists, currentTrackID: currentTrackID,
            playAlbum: { shuffle in Task { await play(detailTracks, shuffle: shuffle) } },
            playTrack: { track in
                Task {
                    if track.id == currentTrackID { await player.togglePlayback() }
                    else { await play(detailTracks, startingAt: track.id) }
                }
            },
            enqueueTrack: { track, next in enqueue([track], next: next) },
            enqueueAlbum: { next in enqueue(detailTracks, next: next) },
            addAlbumToPlaylist: { playlist in Task { await library.addTracks(detailTracks.filter { $0.error == nil }, to: playlist) } })
    }

    private func perform(_ album: LibraryAlbumSummary) {
        guard !actionInProgress, !player.isBusy else { return }
        actionInProgress = true
        Task {
            defer { actionInProgress = false }
            let tracks = await library.tracks(in: album)
            await play(tracks, shuffle: false)
        }
    }
    private func entry(_ track: LibraryTrack) throws -> QueueEntry {
        let location = try library.location(for: track)
        return QueueEntry(url: location.file, accessRoot: location.root, title: track.title,
            subtitle: track.artist + " · " + track.album, artworkURL: library.artworkURL(track.artworkKey), artist: track.artist, album: track.album)
    }
    private func play(_ tracks: [LibraryTrack], startingAt id: String? = nil, shuffle: Bool = false) async {
        guard !player.isBusy else { return }
        let playable = tracks.filter { $0.error == nil }
        guard !playable.isEmpty else { return }
        do { await player.play(try playable.map(entry), startingAt: id.flatMap { id in playable.firstIndex { $0.id == id } } ?? 0, shuffle: shuffle) }
        catch { player.reportImportError(error) }
    }
    private func enqueue(_ tracks: [LibraryTrack], next: Bool) {
        do {
            let entries = try tracks.filter { $0.error == nil }.map(entry)
            for entry in next ? Array(entries.reversed()) : entries { player.enqueue(entry, playNext: next) }
        } catch { player.reportImportError(error) }
    }
}

private struct AlbumBrowserCard: View {
    @Environment(\.swarPalette) private var palette
    let album: LibraryAlbumSummary
    let artworkURL: URL?
    let busy: Bool
    let maximumPixels: Int
    let open: () -> Void
    let play: () -> Void
    @State private var hovered = false
    @FocusState private var focus: CardFocus?
    private enum CardFocus: Hashable { case cover, play, title }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Button(action: open) { CoverArt(url: artworkURL, title: album.title, cornerRadius: 10, maximumPixelSize: maximumPixels) }
                    .buttonStyle(.plain).focused($focus, equals: .cover).accessibilityLabel("Open \(album.title), \(album.artist)")
                Button(action: play) {
                    Image(systemName: "play.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 34, height: 34).background(palette.buttonFill, in: Circle())
                }.buttonStyle(PlaybackButtonStyle(unavailable: album.playableCount == 0))
                    .disabled(busy || album.playableCount == 0).padding(8)
                    .focused($focus, equals: .play).opacity(hovered || focus != nil ? 1 : 0)
                    .accessibilityLabel("Play \(album.title)")
            }
            VStack(alignment: .leading, spacing: 3) {
                Button(action: open) {
                    Text(album.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 32, alignment: .topLeading)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).focused($focus, equals: .title)
                AlbumArtistLink(artist: album.artist)
                Text([album.year, "\(album.trackCount) \(album.trackCount == 1 ? "song" : "songs")"].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.onHover { hovered = $0 }
            .help("\(album.title)\n\(album.artist)\n\(album.trackCount) \(album.trackCount == 1 ? "song" : "songs")")
    }
}

private struct AlbumBrowserRow: View {
    @Environment(\.swarPalette) private var palette
    let album: LibraryAlbumSummary
    let artworkURL: URL?
    let busy: Bool
    let open: () -> Void
    let play: () -> Void
    @State private var hovered = false
    @FocusState private var playFocused: Bool

    private var songCount: String { "\(album.trackCount) \(album.trackCount == 1 ? "song" : "songs")" }
    private var duration: String {
        guard album.duration.isFinite, album.duration > 0, album.duration < Double(Int.max) else { return "—" }
        let seconds = Int(album.duration)
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Button(action: open) {
                    CoverArt(url: artworkURL, title: album.title, cornerRadius: 5, maximumPixelSize: 128)
                        .frame(width: 40, height: 40)
                }.buttonStyle(.plain).accessibilityLabel("Open \(album.title), \(album.artist)")
                Button(action: play) {
                    Image(systemName: "play.fill").font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 26, height: 26)
                        .background(palette.buttonFill, in: Circle())
                }.buttonStyle(PlaybackButtonStyle(unavailable: album.playableCount == 0))
                    .disabled(busy || album.playableCount == 0)
                    .focused($playFocused).opacity(hovered || playFocused ? 1 : 0)
                    .accessibilityLabel("Play \(album.title)")
            }
            VStack(alignment: .leading, spacing: 3) {
                Button(action: open) {
                    Text(album.title).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Open \(album.title)")
                AlbumArtistLink(artist: album.artist)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button(action: open) {
                HStack(spacing: 12) {
                    Text(album.year.flatMap { $0.isEmpty ? nil : $0 } ?? "—").lineLimit(1)
                        .frame(width: 46, alignment: .trailing)
                    Text(songCount).frame(width: 72, alignment: .trailing)
                    Text(duration).monospacedDigit().frame(width: 64, alignment: .trailing)
                }.font(.system(size: 12)).foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("\(album.title), \(album.year ?? "Unknown year"), \(songCount), \(duration)")
        }.padding(.vertical, 2).contentShape(Rectangle())
            .onHover { hovered = $0 }
            .help("\(album.title)\n\(album.artist)\n\(songCount) · \(duration)")
    }
}

/// A separate button keeps artist navigation independent of album opening/playback.
private struct AlbumArtistLink: View {
    @Environment(\.libraryNavigation) private var navigation
    @Environment(\.swarPalette) private var palette
    let artist: String
    @State private var hovered = false
    @FocusState private var focused: Bool

    var body: some View {
        Button { navigation.go?(.artist(artist)) } label: {
            Text(artist).font(.system(size: 12)).lineLimit(1)
                .foregroundStyle(hovered || focused ? palette.accent : Color.secondary)
                .underline(hovered || focused)
        }.buttonStyle(.plain).focused($focused)
            .onHover { hovered = $0 }
            .disabled(navigation.go == nil || artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Browse artist \(artist)")
            .help("Browse \(artist)")
    }
}
