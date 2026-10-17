import SwiftUI
import Library
import Player

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
    @AppStorage("albumCoverSize") private var coverSize = 160.0
    @State private var albums: [LibraryAlbumSummary] = []
    @State private var detailTracks: [LibraryTrack] = []
    @State private var ready = false
    @State private var loadError: String?
    @State private var detailID: String?
    @AppStorage("albumBrowseFilter") private var filter: AlbumBrowseFilter = .all
    @State private var arranger = AlbumBrowseArranger()
    @State private var presentation: AlbumBrowseSnapshot?
    @State private var albumRevision = 0
    @State private var arranging = false
    @State private var loadedKey: String?
    @State private var loadGeneration = UUID()
    private struct ArrangementKey: Hashable {
        let revision: Int
        let sort: AlbumSortOrder
        let reversed: Bool
        let recent: Bool
        let filter: AlbumBrowseFilter
    }
    private var arrangementKey: ArrangementKey {
        ArrangementKey(revision: albumRevision, sort: sortOrder, reversed: reversed, recent: recent, filter: filter)
    }
    @State private var actionInProgress = false

    private var refreshKey: String {
        "\(library.isReady)-\(library.overviewRevision)-\(library.lastScanAt?.timeIntervalSince1970 ?? 0)-\(library.searchScope)-\(library.search)"
    }
    var body: some View {
        ZStack {
            // Keep the grid mounted to preserve its scroll position when returning from details.
            grid.opacity(selectedAlbum == nil ? 1 : 0)
                .allowsHitTesting(selectedAlbum == nil).accessibilityHidden(selectedAlbum != nil)
            if let selectedAlbum {
                if detailID == selectedAlbum, let album = albums.first(where: { $0.id == selectedAlbum }) {
                    detail(album)
                } else { ProgressView("Opening album…") }
            }
        }
        .task(id: refreshKey) { await reload() }
        .task(id: arrangementKey) { await arrange() }
        .task(id: "\(selectedAlbum ?? "")-\(refreshKey)-\(ready)") { await loadDetail() }
        .onChange(of: library.search) { selectedAlbum = nil }
        .onChange(of: library.searchScope) { selectedAlbum = nil }
        .onChange(of: requestedAlbum) { openRequestedAlbum() }
    }

    private var grid: some View {
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
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
                    Slider(value: $coverSize, in: 120...220, step: 20).frame(width: 90)
                        .accessibilityLabel("Album artwork size").help("Adjust album artwork size")
                    Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 28).padding(.vertical, 16)
            Picker("Filter albums", selection: $filter) {
                ForEach(AlbumBrowseFilter.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
                .frame(maxWidth: 380).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28).padding(.bottom, 12)
            if let error = library.errorMessage {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle").lineLimit(2)
                    Spacer()
                    Button { library.dismissError() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss library error")
                }.font(.caption).foregroundStyle(.orange).padding(.horizontal, 28).padding(.bottom, 10)
            }
            if let progress = library.progress {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Updating library · \(progress.completed) of \(progress.total)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 28).padding(.bottom, 10)
            }
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
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(presentation?.sections ?? []) { section in
                                if recent { Text(section.title).font(.system(size: 17, weight: .semibold)).padding(.top, 8) }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: max(120, min(220, coverSize))), spacing: density.gridGap, alignment: .top)], alignment: .leading, spacing: density.gridGap + 4) {
                                    ForEach(section.albums) { album in
                                        AlbumBrowserCard(album: album, artworkURL: library.artworkURL(album.artworkKey),
                                            busy: player.isBusy || actionInProgress,
                                            maximumPixels: coverSize <= 140 ? 256 : coverSize >= 200 ? 512 : 384,
                                            open: { selectedAlbum = album.id },
                                            play: { perform(album) })
                                            .albumActions(library: library, player: player, album: album).id(album.id)
                                    }
                                }
                            }
                        }.padding(.horizontal, 28).padding(.top, 8).padding(.bottom, clearance + 24)
                            .id("album-grid-top")
                    }
                    .onChange(of: library.search) { proxy.scrollTo("album-grid-top", anchor: .top) }
                    .onChange(of: library.searchScope) { proxy.scrollTo("album-grid-top", anchor: .top) }
                    .onChange(of: recent) { proxy.scrollTo("album-grid-top", anchor: .top) }
                    .onChange(of: sortOrder) { proxy.scrollTo("album-grid-top", anchor: .top) }
                    .onChange(of: reversed) { proxy.scrollTo("album-grid-top", anchor: .top) }
                    .onChange(of: filter) { proxy.scrollTo("album-grid-top", anchor: .top) }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func arrange() async {
        guard ready else { return }
        let key = arrangementKey
        arranging = true
        do {
            let result = try await arranger.arrange(albums, sort: key.sort, reversed: key.reversed,
                                                   recent: key.recent, filter: key.filter)
            guard !Task.isCancelled, key == arrangementKey else { return }
            presentation = result; arranging = false
        } catch is CancellationError { }
        catch { guard !Task.isCancelled else { return }; arranging = false; loadError = error.localizedDescription }
    }

    private func openRequestedAlbum() {
        guard ready, loadedKey == refreshKey, let id = requestedAlbum else { return }
        if albums.contains(where: { $0.id == id }) {
            filter = .all
            selectedAlbum = id
        }
        requestedAlbum = nil
    }

    private func reload() async {
        guard library.isReady else { return }
        let key = refreshKey, generation = UUID()
        loadGeneration = generation
        do {
            let query = library.search, scope = library.searchScope
            // The existing root debounces song queries; this browser owns its independent metadata query.
            if ready { try await Task.sleep(for: .milliseconds(200)) }
            let result = try await library.albums(search: query, scope: scope)
            guard !Task.isCancelled, key == refreshKey, generation == loadGeneration else { return }
            if !ready || albums != result { albums = result; albumRevision += 1 }
            ready = true; loadError = nil; loadedKey = key
            if let selectedAlbum, !result.contains(where: { $0.id == selectedAlbum }) { self.selectedAlbum = nil }
            openRequestedAlbum()
        } catch is CancellationError { }
        catch { guard !Task.isCancelled, key == refreshKey, generation == loadGeneration else { return }; loadError = error.localizedDescription; ready = true; selectedAlbum = nil }
    }

    private func loadDetail() async {
        guard let id = selectedAlbum else { detailID = nil; return }
        guard let album = albums.first(where: { $0.id == id }) else { return }
        let tracks = await library.tracks(in: album)
        guard !Task.isCancelled, selectedAlbum == id else { return }
        if tracks.isEmpty { selectedAlbum = nil }
        else { detailTracks = tracks; detailID = id }
    }

    private func detail(_ album: LibraryAlbumSummary) -> some View {
        AlbumDetailView(title: album.title, artist: album.artist, tracks: detailTracks,
            artworkURL: library.artworkURL(album.artworkKey), player: player, library: library,
            playlists: library.manualPlaylists, isCurrent: isCurrent,
            playAlbum: { shuffle in Task { await play(detailTracks, shuffle: shuffle) } },
            playTrack: { track in
                Task {
                    if isCurrent(track) { await player.togglePlayback() }
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
    private func isCurrent(_ track: LibraryTrack) -> Bool {
        player.currentURL != nil && (try? library.location(for: track).file.standardizedFileURL) == player.currentURL?.standardizedFileURL
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
            Button(action: open) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(album.title).font(.system(size: 13, weight: .medium)).lineLimit(2).frame(height: 32, alignment: .topLeading)
                    Text(album.artist).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    Text([album.year, "\(album.trackCount) \(album.trackCount == 1 ? "song" : "songs")"].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).focused($focus, equals: .title)
        }.onHover { hovered = $0 }
            .help("\(album.title)\n\(album.artist)\n\(album.trackCount) \(album.trackCount == 1 ? "song" : "songs")")
    }
}
