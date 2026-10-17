import SwiftUI
import Library
import Player

@MainActor
public struct PlaylistDetailView: View {
    @Environment(\.swarPalette) private var palette
    @Environment(\.floatingPlayerClearance) private var playerClearance
    public let playlist: LibraryPlaylist
    public let library: LibraryModel
    public let player: Player
    public let onRename: (LibraryPlaylist) -> Void
    public let onDelete: (LibraryPlaylist) -> Void

    @State private var items: [PlaylistTrackItem] = []
    @State private var isLoading = true
    @State private var loadedPlaylistID: String?
    @State private var loadGeneration = UUID()

    private var visibleItems: [PlaylistTrackItem] {
        let query = TrackSearchQuery(library.search)
        return items.filter { query.matches($0.track, scope: library.searchScope) }
    }
    private var isFiltering: Bool { !TrackSearchQuery(library.search).isEmpty }
    private var playableTracks: [LibraryTrack] { visibleItems.map(\.track).filter { $0.error == nil } }
    private var canPlay: Bool { !isLoading && loadedPlaylistID == playlist.id && !playableTracks.isEmpty }

    private var durationDescription: String {
        let minutes = Int(items.reduce(0) { $0 + max(0, $1.track.duration) }) / 60
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
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
        GeometryReader { geometry in
            let compact = geometry.size.width < 700
            let inset: CGFloat = compact ? 24 : 40
            let coverSize: CGFloat = min(220, max(160, geometry.size.width * 0.24))

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .bottom, spacing: compact ? 20 : 30) {
                        playlistArtwork(size: coverSize)
                        VStack(alignment: .leading, spacing: 6) {
                            Spacer(minLength: 0)
                            Text("Playlist")
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

                            Spacer(minLength: 16)
                            HStack(spacing: 10) {
                                Button {
                                    playPlaylist(shuffle: false)
                                } label: {
                                    actionButton("Play", symbol: "play.fill")
                                }
                                .buttonStyle(PlaybackButtonStyle(unavailable: !canPlay))
                                .disabled(player.isBusy || !canPlay)
                                .accessibilityLabel("Play playlist in order")

                                Button {
                                    playPlaylist(shuffle: true)
                                } label: {
                                    actionButton("Shuffle", symbol: "shuffle")
                                }
                                .buttonStyle(PlaybackButtonStyle(unavailable: !canPlay))
                                .disabled(player.isBusy || !canPlay)
                                .accessibilityLabel("Shuffle playlist")

                                Menu {
                                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { enqueuePlaylist(next: true) }
                                        .disabled(player.isBusy || !canPlay)
                                    Button("Add to Queue", systemImage: "text.badge.plus") { enqueuePlaylist(next: false) }
                                        .disabled(player.isBusy || !canPlay)
                                    Divider()
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

                    if isLoading && items.isEmpty {
                        ProgressView("Loading playlist…")
                            .frame(maxWidth: .infinity).padding(.top, 40)
                    } else if items.isEmpty {
                        ContentUnavailableView {
                            Label("Playlist is Empty", systemImage: "music.note.list")
                        } description: {
                            Text("Add songs from your library by right-clicking any track and choosing Add to Playlist.")
                        }
                        .padding(.top, 40)
                    } else if visibleItems.isEmpty {
                        ContentUnavailableView("No Matching Songs", systemImage: "magnifyingglass",
                            description: Text("Try different words or choose All Fields from the search icon."))
                    } else {
                        if isFiltering {
                            Text("\(visibleItems.count) of \(items.count) \(items.count == 1 ? "song matches" : "songs match")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        LazyVStack(spacing: 0) {
                            ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                                PlaylistSongRow(
                                    item: item,
                                    index: (items.firstIndex(where: { $0.id == item.id }) ?? index) + 1,
                                    current: isCurrent(item.track),
                                    playing: isCurrent(item.track) && player.isPlaying,
                                    compact: compact,
                                    alternate: index.isMultiple(of: 2),
                                    isFirst: isFiltering || index == 0,
                                    isLast: isFiltering || index == items.count - 1,
                                    busy: player.isBusy,
                                    library: library,
                                    play: { playItem(item) },
                                    enqueue: { enqueueTrack(item.track, next: $0) },
                                    moveUp: { move(from: index, to: index - 1) },
                                    moveDown: { move(from: index, to: index + 1) },
                                    remove: { removeItem(item) }
                                )
                            }
                        }
                    }
                }
                .padding(.horizontal, inset)
                .padding(.top, 16)
                .padding(.bottom, 32 + playerClearance)
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: [playlist.id, String(library.trackActionsRevision)]) {
            await reloadItems()
        }
    }

    @ViewBuilder
    private func playlistArtwork(size: CGFloat) -> some View {
        let firstCover = items.compactMap(\.track.artworkKey).first
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

    private func isCurrent(_ track: LibraryTrack) -> Bool {
        guard let currentURL = player.currentURL?.standardizedFileURL,
              let location = try? library.location(for: track).file.standardizedFileURL else { return false }
        return location == currentURL
    }

    private func reloadItems() async {
        let playlistID = playlist.id
        let generation = UUID()
        loadGeneration = generation
        if loadedPlaylistID != playlistID { items = [] }
        isLoading = true
        let result = await library.playlistTracks(for: playlistID)
        guard !Task.isCancelled, loadGeneration == generation else { return }
        items = result
        loadedPlaylistID = playlistID
        isLoading = false
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

    private func playItem(_ item: PlaylistTrackItem) {
        Task {
            if isCurrent(item.track) {
                await player.togglePlayback()
                return
            }
            let playable = visibleItems.filter { $0.track.error == nil }
            guard let index = playable.firstIndex(where: { $0.id == item.id }) else { return }
            do {
                let entries = try playable.map { try entry($0.track) }
                await player.play(entries, startingAt: index)
            } catch {
                player.reportImportError(error)
            }
        }
    }

    private func playPlaylist(shuffle: Bool) {
        Task {
            let playable = visibleItems.filter { $0.track.error == nil }
            guard !playable.isEmpty else { return }
            do {
                let entries = try playable.map { try entry($0.track) }
                await player.play(entries, startingAt: 0, shuffle: shuffle)
            } catch {
                player.reportImportError(error)
            }
        }
    }

    private func enqueuePlaylist(next: Bool) {
        do {
            let entries = try visibleItems.filter { $0.track.error == nil }.map { try entry($0.track) }
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
    let isLast: Bool
    let busy: Bool
    let library: LibraryModel
    let play: () -> Void
    let enqueue: (Bool) -> Void
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                HStack(spacing: 12) {
                    ZStack {
                        if hovered || current {
                            Image(systemName: playing ? "pause.fill" : "play.fill")
                                .font(.system(size: 11, weight: .semibold))
                        } else {
                            Text("\(index)").monospacedDigit()
                        }
                    }
                    .foregroundStyle(current ? Color.accentColor : .secondary)
                    .frame(width: 24)

                    CoverArt(url: library.artworkURL(item.track.artworkKey), title: item.track.title, cornerRadius: 4)
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
            Divider()
            if !isFirst { Button("Move Up", systemImage: "arrow.up") { moveUp() }.disabled(busy) }
            if !isLast { Button("Move Down", systemImage: "arrow.down") { moveDown() }.disabled(busy) }
            Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive) { remove() }.disabled(busy)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .padding(.vertical, density == .compact ? 4 : 8)
        .background(
            current ? Color.accentColor.opacity(0.1) : Color.primary.opacity(hovered ? 0.055 : (alternate ? 0.025 : 0)),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .onHover { hovered = $0 }
    }
}
