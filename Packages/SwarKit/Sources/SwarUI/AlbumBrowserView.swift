import SwiftUI
import Library
import Player

enum AlbumSortOrder: String, CaseIterable, Identifiable {
    case title = "Album Title"
    case artist = "Artist"
    case year = "Release Year"
    case recentlyAdded = "Recently Added"
    var id: Self { self }
}

@MainActor
struct AlbumBrowserView: View {
    @Environment(\.swarDensity) private var density
    let library: LibraryModel
    let player: Player
    let recent: Bool
    @Binding var selectedAlbum: String?
    let sortOrder: AlbumSortOrder
    let reversed: Bool
    @Environment(\.floatingPlayerClearance) private var clearance
    @AppStorage("albumCoverSize") private var coverSize = 160.0
    @State private var albums: [LibraryAlbumSummary] = []
    @State private var detailTracks: [LibraryTrack] = []
    @State private var ready = false
    @State private var loadError: String?
    @State private var detailID: String?
    @State private var scrollPosition: String?
    @State private var actionInProgress = false

    private var refreshKey: String {
        "\(library.isReady)-\(library.overviewRevision)-\(library.lastScanAt?.timeIntervalSince1970 ?? 0)-\(library.searchScope)-\(library.search)"
    }
    private var collectionSummary: String {
        let songs = albums.reduce(0) { $0 + $1.trackCount }
        return "\(albums.count) \(albums.count == 1 ? "album" : "albums") · \(songs) \(songs == 1 ? "song" : "songs")"
    }
    private var sortedAlbums: [LibraryAlbumSummary] {
        let sorted = albums.sorted { a, b in
            let order = recent ? .recentlyAdded : sortOrder
            if order == .recentlyAdded, a.addedAt != b.addedAt { return a.addedAt > b.addedAt }
            if order == .year {
                let first = Int(a.year?.prefix(4) ?? "") ?? 0
                let second = Int(b.year?.prefix(4) ?? "") ?? 0
                if first != second { return first > second }
            }
            if order == .title {
                let comparison = a.title.localizedStandardCompare(b.title)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            let artist = a.artist.localizedStandardCompare(b.artist)
            if artist != .orderedSame { return artist == .orderedAscending }
            let title = a.title.localizedStandardCompare(b.title)
            if title != .orderedSame { return title == .orderedAscending }
            return a.id < b.id
        }
        return !recent && reversed ? sorted.reversed() : sorted
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
        .task(id: "\(selectedAlbum ?? "")-\(refreshKey)-\(ready)") { await loadDetail() }
        .onChange(of: library.search) { selectedAlbum = nil; scrollPosition = nil }
        .onChange(of: library.searchScope) { selectedAlbum = nil; scrollPosition = nil }
        .onChange(of: recent) { scrollPosition = nil }
    }

    private var grid: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recent ? "Recent arrivals" : "Albums")
                        .font(.system(size: 26, weight: .semibold, design: .serif))
                    Text(collectionSummary)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.3x3").foregroundStyle(.secondary)
                    Slider(value: $coverSize, in: 120...220, step: 20).frame(width: 90)
                        .accessibilityLabel("Album artwork size").help("Adjust album artwork size")
                    Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 28).padding(.vertical, 16)
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
            } else if !ready {
                ProgressView("Loading albums…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if albums.isEmpty {
                ContentUnavailableView {
                    Label(TrackSearchQuery(library.search).isEmpty ? "No Albums Yet" : "No Matching Albums", systemImage: "square.stack")
                } description: {
                    Text(TrackSearchQuery(library.search).isEmpty ? "Add a music folder to start your collection." : "Try a different album, artist, or song.")
                } actions: {
                    if !TrackSearchQuery(library.search).isEmpty { Button("Clear Search") { library.search = "" } }
                    else { SettingsLink { Text("Music Folder Settings…") } }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(sections, id: \.title) { section in
                            if recent { Text(section.title).font(.system(size: 17, weight: .semibold)).padding(.top, 8) }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: max(120, min(220, coverSize))), spacing: density.gridGap, alignment: .top)], alignment: .leading, spacing: density.gridGap + 4) {
                                ForEach(section.albums) { album in
                                    AlbumBrowserCard(album: album, artworkURL: library.artworkURL(album.artworkKey),
                                        busy: player.isBusy || actionInProgress,
                                        open: { selectedAlbum = album.id },
                                        play: { perform(album, action: .play(false)) })
                                        .contextMenu { albumMenu(album) }.id(album.id)
                                }
                            }.scrollTargetLayout()
                        }
                    }.padding(.horizontal, 28).padding(.top, 8).padding(.bottom, clearance + 24)
                }.scrollPosition(id: $scrollPosition, anchor: .top)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var sections: [(title: String, albums: [LibraryAlbumSummary])] {
        guard recent else { return [("Albums", sortedAlbums)] }
        var result: [(title: String, albums: [LibraryAlbumSummary])] = []
        for album in sortedAlbums {
            let title = Calendar.current.isDate(album.addedAt, equalTo: Date(), toGranularity: .month)
                ? "This Month" : album.addedAt.formatted(.dateTime.month(.wide).year())
            if let index = result.firstIndex(where: { $0.title == title }) { result[index].albums.append(album) }
            else { result.append((title, [album])) }
        }
        return result
    }

    @ViewBuilder private func albumMenu(_ album: LibraryAlbumSummary) -> some View {
        Button("Open Album", systemImage: "square.stack") { selectedAlbum = album.id }
        Divider()
        Group {
            Button("Play", systemImage: "play.fill") { perform(album, action: .play(false)) }
            Button("Shuffle", systemImage: "shuffle") { perform(album, action: .play(true)) }
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { perform(album, action: .enqueue(true)) }
            Button("Play Last", systemImage: "text.append") { perform(album, action: .enqueue(false)) }
            Menu("Add to Playlist") {
                ForEach(library.playlists) { playlist in
                    Button(playlist.name) { perform(album, action: .playlist(playlist)) }
                }
                if library.playlists.isEmpty { Text("Create a playlist from the sidebar first") }
            }
        }.disabled(player.isBusy || actionInProgress || album.playableCount == 0)
    }

    private func reload() async {
        guard library.isReady else { return }
        do {
            let query = library.search, scope = library.searchScope
            // The existing root debounces song queries; this browser owns its independent metadata query.
            if ready { try await Task.sleep(for: .milliseconds(200)) }
            let result = try await library.albums(search: query, scope: scope)
            guard !Task.isCancelled else { return }
            albums = result; ready = true; loadError = nil
            if let selectedAlbum, !result.contains(where: { $0.id == selectedAlbum }) { self.selectedAlbum = nil }
        } catch is CancellationError { }
        catch { guard !Task.isCancelled else { return }; loadError = error.localizedDescription; ready = true; selectedAlbum = nil }
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
            playlists: library.playlists, isCurrent: isCurrent,
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

    private enum AlbumAction { case play(Bool), enqueue(Bool), playlist(LibraryPlaylist) }
    private func perform(_ album: LibraryAlbumSummary, action: AlbumAction) {
        guard !actionInProgress, !player.isBusy else { return }
        actionInProgress = true
        Task {
            defer { actionInProgress = false }
            let tracks = await library.tracks(in: album)
            switch action {
            case .play(let shuffle): await play(tracks, shuffle: shuffle)
            case .enqueue(let next): enqueue(tracks, next: next)
            case .playlist(let playlist): await library.addTracks(tracks.filter { $0.error == nil }, to: playlist)
            }
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
    let open: () -> Void
    let play: () -> Void
    @State private var hovered = false
    @FocusState private var focus: CardFocus?
    private enum CardFocus: Hashable { case cover, play, title }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Button(action: open) { CoverArt(url: artworkURL, title: album.title, cornerRadius: 10) }
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
