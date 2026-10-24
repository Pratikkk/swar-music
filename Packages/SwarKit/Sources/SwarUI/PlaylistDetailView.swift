import SwiftUI
import Library
import Player

private struct PlaylistBrowseRequest: Equatable {
    let revision: UInt64
    let search: String
    let scope: TrackSearchScope
}

@MainActor
public struct PlaylistDetailView: View {
    @Environment(\.swarPalette) private var palette
    public let playlist: LibraryPlaylist
    public let library: LibraryModel
    public let player: Player
    public let onRename: (LibraryPlaylist) -> Void
    public let onDelete: (LibraryPlaylist) -> Void

    @State private var showExport = false
    @State private var showRules = false
    @State private var loadError: String?
    @State private var items: [PlaylistTrackItem] = []
    @State private var isLoading = true
    @State private var loadedPlaylistID: String?
    @State private var loadGeneration = UUID()
    @State private var arranger = PlaylistBrowseArranger()
    @State private var presentation: PlaylistBrowseSnapshot?
    @State private var presentedRequest: PlaylistBrowseRequest?
    @State private var itemsRevision: UInt64 = 0
    /// Cached current track ID; resolved from player.currentURL only when it changes.
    @State private var currentTrackIDCache: String?

    private var request: PlaylistBrowseRequest {
        PlaylistBrowseRequest(revision: itemsRevision, search: library.search, scope: library.searchScope)
    }
    private var visibleRows: [PlaylistBrowseRow] { presentation?.rows ?? [] }
    private var isFiltering: Bool { !TrackSearchQuery(library.search).isEmpty }
    private var playableTracks: [LibraryTrack] { presentation?.playableTracks ?? [] }
    private var matchesRequest: Bool { presentedRequest == request }
    private var canPlay: Bool { !isLoading && matchesRequest && loadedPlaylistID == playlist.id && !playableTracks.isEmpty }

    private var durationDescription: String {
        presentation?.durationDescription ?? "0 min"
    }

    public init(
        playlist: LibraryPlaylist,
        library: LibraryModel,
        player: Player,
        onRename: @escaping (LibraryPlaylist) -> Void,
        onDelete: @escaping (LibraryPlaylist) -> Void
    ) {
        self.playlist = playlist
        self.library = library
        self.player = player
        self.onRename = onRename
        self.onDelete = onDelete
    }

    public var body: some View {
        let currentTrackID = currentTrackIDCache
        GeometryReader { geometry in
            let compact = geometry.size.width < 700
            let inset: CGFloat = compact ? 24 : 40
            let coverSize: CGFloat = min(220, max(160, geometry.size.width * 0.24))

            List {
                playlistHeader(compact: compact, coverSize: coverSize)
                    .listRowInsets(EdgeInsets(top: 16, leading: inset, bottom: 8, trailing: inset))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)

                if let loadError {
                    ContentUnavailableView { Label("Couldn’t Load Playlist", systemImage: "exclamationmark.triangle") }
                        description: { Text(loadError) } actions: { Button("Try Again") { Task { await reloadItems() } } }
                        .listRowInsets(EdgeInsets(top: 24, leading: inset, bottom: 24, trailing: inset))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else if (isLoading && items.isEmpty) || presentation == nil || (visibleRows.isEmpty && !matchesRequest) {
                    ProgressView("Loading playlist…")
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets(top: 40, leading: inset, bottom: 40, trailing: inset))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else if items.isEmpty {
                    ContentUnavailableView {
                        Label("Playlist is Empty", systemImage: "music.note.list")
                    } description: {
                        Text(playlist.isSmart ? "No songs match these rules. Edit the rules to change this playlist." : "Drop songs here or choose Add to Playlist from a song’s menu.")
                    }
                    .listRowInsets(EdgeInsets(top: 40, leading: inset, bottom: 40, trailing: inset))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                } else if visibleRows.isEmpty {
                    ContentUnavailableView("No Matching Songs", systemImage: "magnifyingglass",
                        description: Text("Try different words or choose All Fields from the search icon."))
                        .listRowInsets(EdgeInsets(top: 24, leading: inset, bottom: 24, trailing: inset))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                } else {
                    if isFiltering {
                        Text("\(visibleRows.count) of \(items.count) \(items.count == 1 ? "song matches" : "songs match")")
                            .font(.caption).foregroundStyle(.secondary)
                            .listRowInsets(EdgeInsets(top: 4, leading: inset, bottom: 4, trailing: inset))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                    ForEach(visibleRows) { row in
                        let item = row.item
                        PlaylistSongRow(
                            item: item,
                            index: row.number,
                            current: item.track.id == currentTrackID,
                            playing: item.track.id == currentTrackID && player.isPlaying,
                            compact: compact,
                            alternate: row.alternate,
                            isFirst: isFiltering || row.number == 1,
                            smart: playlist.isSmart,
                            isLast: isFiltering || row.number == items.count,
                            busy: player.isBusy || !matchesRequest,
                            library: library,
                            play: { playItem(item, currentTrackID: currentTrackID) },
                            enqueue: { enqueueTrack(item.track, next: $0) },
                            moveUp: { move(from: row.number - 1, to: row.number - 2) },
                            moveDown: { move(from: row.number - 1, to: row.number) },
                            remove: { removeItem(item) }
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: max(0, inset - 12), bottom: 0, trailing: max(0, inset - 12)))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                    FloatingPlayerScrollSpacer()
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, 0)
            .playlistSongDrop(library: library, playlist: playlist)

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showExport) { PlaylistExportView(library: library, playlist: playlist) }
        .sheet(isPresented: $showRules) {
            SmartPlaylistEditorView(library: library, playlist: playlist) { _ in }
        }
        .task(id: [playlist.id, String(playlist.updatedAt.timeIntervalSince1970), playlist.smartRulesJSON ?? "", String(library.trackActionsRevision), "\(library.lastScanAt?.timeIntervalSince1970 ?? 0)", playlist.isSmart ? String(library.overviewRevision) : ""]) {
            await reloadItems()
        }
        .task(id: request) {
            let requested = request
            let source = items
            do {
                if let previous = presentedRequest, previous.search != requested.search {
                    try await Task.sleep(for: .milliseconds(150))
                }
                let result = try await arranger.arrange(source, search: requested.search, scope: requested.scope)
                guard !Task.isCancelled, requested == request else { return }
                presentation = result; presentedRequest = requested
            } catch is CancellationError { }
            catch { /* Keep the displayed snapshot if preparation is cancelled. */ }
        }
        .task(id: playlist.isSmart) {
            guard playlist.isSmart else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)); try Task.checkCancellation() } catch { return }
                await reloadItems()
            }
        }
        .onChange(of: player.currentURL) {
            currentTrackIDCache = library.trackID(at: player.currentURL)
        }
        .task {
            currentTrackIDCache = library.trackID(at: player.currentURL)
        }
    }

    private func playlistHeader(compact: Bool, coverSize: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: compact ? 20 : 30) {
            playlistArtwork(size: coverSize)
            VStack(alignment: .leading, spacing: 6) {
                Spacer(minLength: 0)
                Text(playlist.isSmart ? "Smart Playlist" : "Playlist")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(playlist.name)
                    .font(.system(size: compact ? 22 : 28, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text("\(items.count) \(items.count == 1 ? "song" : "songs") · \(durationDescription)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                if playlist.isSmart {
                    Button("Edit Rules…", systemImage: "slider.horizontal.3") { showRules = true }.controlSize(.small)
                }
                Spacer(minLength: 16)
                HStack(spacing: 10) {
                    Button {
                        playPlaylist(shuffle: false)
                    } label: {
                        actionButton("Play", symbol: "play.fill")
                    }
                    .buttonStyle(PlaybackButtonStyle(unavailable: playableTracks.isEmpty))
                    .disabled(player.isBusy || !canPlay)
                    .accessibilityLabel("Play playlist in order")

                    Button {
                        playPlaylist(shuffle: true)
                    } label: {
                        actionButton("Shuffle", symbol: "shuffle")
                    }
                    .buttonStyle(PlaybackButtonStyle(unavailable: playableTracks.isEmpty))
                    .disabled(player.isBusy || !canPlay)
                    .accessibilityLabel("Shuffle playlist")

                    Menu {
                        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { enqueuePlaylist(next: true) }
                            .disabled(player.isBusy || !canPlay)
                        Button("Add to Queue", systemImage: "text.badge.plus") { enqueuePlaylist(next: false) }
                            .disabled(player.isBusy || !canPlay)
                        Divider()
                        if playlist.isSmart { Button("Edit Rules…", systemImage: "slider.horizontal.3") { showRules = true } }
                        Button("Export Playlist…", systemImage: "square.and.arrow.up") { showExport = true }
                        Button("Rename Playlist…", systemImage: "pencil") { onRename(playlist) }
                        Button("Delete Playlist", systemImage: "trash", role: .destructive) { onDelete(playlist) }
                    } label: {
                        Image(systemName: "ellipsis.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("Playlist options")
                }
            }
            .frame(maxWidth: .infinity, minHeight: coverSize, alignment: .leading)
        }
    }

    @ViewBuilder
    private func playlistArtwork(size: CGFloat) -> some View {
        let firstCover = presentation?.artworkKey
        ZStack {
            if let firstCover, let url = library.artworkURL(firstCover) {
                CoverArt(url: url, title: playlist.name, cornerRadius: 10)
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(LinearGradient(colors: [palette.buttonFill, .indigo.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        Image(systemName: "music.note.list")
                            .font(.system(size: size * 0.38))
                            .foregroundStyle(.white.opacity(0.9))
                    }
            }
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.18), radius: 14, y: 7)
    }

    private func actionButton(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 100, height: 30)
            .background(palette.buttonFill, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private func reloadItems() async {
        let playlistID = playlist.id
        let generation = UUID()
        loadGeneration = generation
        if loadedPlaylistID != playlistID, !items.isEmpty { items = []; itemsRevision &+= 1 }
        isLoading = true
        // Clearing isLoading is owned by the generation that set it. Previously a
        // superseded or cancelled run returned early and left the flag set, which
        // disabled Play/Shuffle/Export for good because canPlay requires !isLoading.
        defer { if loadGeneration == generation { isLoading = false } }
        do {
            let result = try await library.playlistItems(for: playlistID)
            guard !Task.isCancelled, loadGeneration == generation else { return }
            if items != result { items = result; itemsRevision &+= 1 }
            loadError = nil; loadedPlaylistID = playlistID
        } catch {
            guard !Task.isCancelled, loadGeneration == generation else { return }
            if !items.isEmpty { items = []; itemsRevision &+= 1 }
            loadError = error.localizedDescription
        }
    }

    private func entry(_ track: LibraryTrack) throws -> QueueEntry {
        let location = try library.location(for: track)
        return QueueEntry(
            url: location.file,
            accessRoot: location.root,
            title: track.title,
            subtitle: track.artist + " · " + track.album,
            artworkURL: library.artworkURL(track.artworkKey),
            artist: track.artist, album: track.album
        )
    }

    private func playItem(_ item: PlaylistTrackItem, currentTrackID: String?) {
        Task {
            if item.track.id == currentTrackID {
                await player.togglePlayback()
                return
            }
            guard canPlay else { return }
            let playable = visibleRows.filter { $0.item.track.error == nil }
            guard let index = playable.firstIndex(where: { $0.id == item.id }) else { return }
            do {
                let entries = try playable.map { try entry($0.item.track) }
                await player.play(entries, startingAt: index)
            } catch {
                player.reportImportError(error)
            }
        }
    }

    private func playPlaylist(shuffle: Bool) {
        Task {
            guard canPlay else { return }
            let playable = playableTracks
            guard !playable.isEmpty else { return }
            do {
                let entries = try playable.map(entry)
                await player.play(entries, startingAt: 0, shuffle: shuffle)
            } catch {
                player.reportImportError(error)
            }
        }
    }

    private func enqueuePlaylist(next: Bool) {
        do {
            guard canPlay else { return }
            let entries = try playableTracks.map(entry)
            for entry in next ? Array(entries.reversed()) : entries {
                player.enqueue(entry, playNext: next)
            }
        } catch {
            player.reportImportError(error)
        }
    }

    private func enqueueTrack(_ track: LibraryTrack, next: Bool) {
        do {
            player.enqueue(try entry(track), playNext: next)
        } catch {
            player.reportImportError(error)
        }
    }

    private func move(from: Int, to: Int) {
        Task {
            await library.moveTrack(from: from, to: to, in: playlist)
            await reloadItems()
        }
    }

    private func removeItem(_ item: PlaylistTrackItem) {
        Task {
            await library.removeTrack(playlistTrackID: item.id, from: playlist)
            await reloadItems()
        }
    }
}

private struct PlaylistSongRow: View {
    @Environment(\.swarDensity) private var density
    let item: PlaylistTrackItem
    let index: Int
    let current: Bool
    let playing: Bool
    let compact: Bool
    let alternate: Bool
    let isFirst: Bool
    let smart: Bool
    let isLast: Bool
    let busy: Bool
    let library: LibraryModel
    let play: () -> Void
    let enqueue: (Bool) -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                HStack(spacing: 12) {
                    ZStack {
                        if current {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 11, weight: .semibold))
                        } else {
                            Text("\(index)").monospacedDigit()
                        }
                    }
                    .foregroundStyle(current ? Color.accentColor : .secondary)
                    .frame(width: 24)

                    CoverArt(url: library.artworkURL(item.track.artworkKey), title: item.track.title, cornerRadius: 4, maximumPixelSize: 128)
                        .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.track.title)
                            .fontWeight(current ? .semibold : .medium)
                            .lineLimit(1)
                            .foregroundStyle(current ? Color.accentColor : .primary)
                        if compact {
                            Text(item.track.artist + " · " + item.track.album)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let error = item.track.error {
                            Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if !compact {
                        Text(item.track.artist)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(item.track.album)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text(String(format: "%d:%02d", Int(max(0, item.track.duration)) / 60, Int(max(0, item.track.duration)) % 60))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(PlaybackButtonStyle(unavailable: item.track.error != nil))
            .disabled(busy || item.track.error != nil)
            .accessibilityLabel("\(playing ? "Pause" : "Play") \(item.track.title)")


        }
        .songActions(library: library, track: item.track, busy: busy, play: play, playLabel: playing ? "Pause" : "Play", enqueue: enqueue) {
            if !smart {
            Divider()
            if !isFirst { Button("Move Up", systemImage: "arrow.up") { moveUp() }.disabled(busy) }
            if !isLast { Button("Move Down", systemImage: "arrow.down") { moveDown() }.disabled(busy) }
            Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive) { remove() }.disabled(busy)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, density == .compact ? 4 : 8)
        .background {
            RowBackground(isCurrent: current, isAlternate: alternate)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Isolates hover state so only the background layer invalidates on hover,
    /// not the entire row (text, images, buttons).
    private struct RowBackground: View {
        let isCurrent: Bool
        let isAlternate: Bool
        @State private var hovered = false

        var body: some View {
            RoundedRectangle(cornerRadius: 6)
                .fill(isCurrent ? Color.accentColor.opacity(0.1) : Color.primary.opacity(hovered ? 0.055 : (isAlternate ? 0.025 : 0)))
                .onHover { hovered = $0 }
        }
    }
}
