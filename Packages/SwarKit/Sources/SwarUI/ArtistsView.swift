import SwiftUI
import Library
import Player

private enum ArtistSelection: Hashable {
    case all
    case artist(String)
}

/// Album artists keep compilations together; individual performers remain on song rows.
@MainActor
struct ArtistsView: View {
    @Environment(\.swarDensity) private var density
    @Environment(\.swarPalette) private var palette
    @Environment(\.floatingPlayerClearance) private var playerClearance
    let library: LibraryModel
    let player: Player
    let play: (LibraryTrack, [LibraryTrack], Bool?) -> Void
    let enqueue: ([LibraryTrack], Bool) -> Void
    @State private var selection: ArtistSelection? = .all
    @FocusState private var artistListFocused: Bool

    @State private var artists: [ArtistBrowseCollection] = []
    @State private var arranger = ArtistBrowseArranger()

    private var visibleArtists: [ArtistBrowseCollection] {
        if case .artist(let name) = selection { return artists.filter { $0.name == name } }
        return artists
    }

    /// A single flat row model lets the native List virtualize artists, albums
    /// and songs independently instead of realizing a whole album as one view.
    private enum ArtistRenderItem: Identifiable {
        case header(ArtistBrowseCollection)
        case album(artist: String, album: ArtistBrowseAlbum)
        case disc(artist: String, album: ArtistBrowseAlbum, disc: Int)
        case song(artist: String, album: ArtistBrowseAlbum, song: ArtistBrowseSong)

        var id: String {
            switch self {
            case .header(let artist): "artist\u{1f}\(artist.name)"
            case .album(let artist, let album): "album\u{1f}\(artist)\u{1f}\(album.title)"
            case .disc(let artist, let album, let disc): "disc\u{1f}\(artist)\u{1f}\(album.title)\u{1f}\(disc)"
            case .song(_, _, let song): "song\u{1f}\(song.track.id)"
            }
        }
    }

    private var renderItems: [ArtistRenderItem] {
        visibleArtists.flatMap { artist in
            var items: [ArtistRenderItem] = [.header(artist)]
            for album in artist.albums {
                items.append(.album(artist: artist.name, album: album))
                for song in album.songs {
                    if song.startsDisc {
                        items.append(.disc(artist: artist.name, album: album,
                                           disc: max(1, song.track.discNumber)))
                    }
                    items.append(.song(artist: artist.name, album: album, song: song))
                }
            }
            return items
        }
    }

    var body: some View {
        let currentTrackID = library.trackID(at: player.currentURL)
        GeometryReader { geometry in
            let listWidth = min(285, max(180, geometry.size.width * 0.28))
            let compact = geometry.size.width - listWidth < 560
            let inset: CGFloat = compact ? 20 : 40
            let rowInset = max(0, inset - 12)
            HStack(spacing: 0) {
                artistList.frame(width: listWidth)
                Divider()
                ScrollViewReader { proxy in
                List {
                    Color.clear.frame(height: 0).id("artists-top")
                        .listRowSeparator(.hidden).listRowInsets(EdgeInsets())
                    ForEach(renderItems) { item in
                        switch item {
                        case .header(let artist):
                            artistHeader(artist, compact: compact)
                                .listRowInsets(EdgeInsets(top: 28, leading: inset, bottom: 8, trailing: inset))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        case .album(_, let album):
                            albumHeader(album, compact: compact, currentTrackID: currentTrackID)
                                .listRowInsets(EdgeInsets(top: 20, leading: inset, bottom: 4, trailing: inset))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        case .disc(_, _, let disc):
                            Text("Disc \(disc)")
                                .font(.caption.bold())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 8)
                                .listRowInsets(EdgeInsets(top: 4, leading: inset, bottom: 4, trailing: inset))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        case .song(_, let album, let song):
                            let track = song.track
                            let current = track.id == currentTrackID
                            AlbumSongRow(track: track, library: library, fallbackNumber: song.number,
                                         current: current, playing: current && player.isPlaying,
                                         compact: true, alternate: false, busy: player.isBusy,
                                         play: {
                                             if current { Task { await player.togglePlayback() } }
                                             else { play(track, album.tracks, nil) }
                                         },
                                         enqueue: { enqueue([track], $0) })
                                .listRowInsets(EdgeInsets(top: 0, leading: rowInset, bottom: 0, trailing: rowInset))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    }
                    FloatingPlayerScrollSpacer()
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
                // No .id(selection): the flat ArtistRenderItem rows already carry
                // stable ids, so the List diffs in place. Recreating it discarded
                // scroll position and every child's state on each artist click.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Selection still returns to the top, but by scrolling rather
                // than by destroying the list.
                .onChange(of: selection) { proxy.scrollTo("artists-top", anchor: .top) }
                }
            }
        }
        .task(id: "\(library.tracksRevision)-\(library.search)-\(library.searchScope)-\(library.isScanning)-\(library.lastScanAt?.timeIntervalSince1970 ?? 0)") {
            // A scan commits batches repeatedly. Keep the last prepared grouping
            // while it runs, then arrange once from the settled page.
            if library.isScanning, !artists.isEmpty { return }
            if !artists.isEmpty {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            }
            do {
                let result = try await arranger.arrange(library.tracks)
                guard !Task.isCancelled else { return }
                artists = result
                if case .artist(let name) = selection, !result.contains(where: { $0.name == name }) { selection = .all }
            } catch is CancellationError { }
            catch { /* Preparation has no fallible I/O; retain the displayed snapshot. */ }
        }
    }

    private var artistList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    selectionRow(.all) {
                        HStack(spacing: 9) {
                            Image(systemName: "music.mic").font(.title2).frame(width: 36, height: 36)
                                .foregroundStyle(palette.accent)
                            Text("All Artists").fontWeight(.semibold)
                        }
                    }
                    ForEach(artists) { artist in
                        selectionRow(.artist(artist.name)) {
                            HStack(spacing: 9) {
                                CoverArt(url: library.artworkURL(artist.artworkKey), title: artist.name, maximumPixelSize: 128)
                                    .frame(width: 36, height: 36).clipShape(Circle())
                                Text(artist.name).font(.system(size: 12)).lineLimit(1)
                            }
                        }.help(artist.name)
                    }
                }
                .padding(8).padding(.bottom, playerClearance)
            }

            .focusable().focused($artistListFocused).focusEffectDisabled()
            .onMoveCommand(perform: moveArtistSelection)
            .onChange(of: selection) { _, choice in
                if let choice { proxy.scrollTo(choice) }
            }
            .accessibilityElement(children: .contain).accessibilityLabel("Artists")
        }
    }

    private func selectionRow<Content: View>(_ choice: ArtistSelection, @ViewBuilder content: () -> Content) -> some View {
        Button {
            selection = choice
            artistListFocused = true
        } label: {
            content()
                .padding(.horizontal, 10).padding(.vertical, density == .compact ? 5 : 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(selection == choice ? palette.accent : .primary)
                .background(selection == choice ? Color.primary.opacity(0.055) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selection == choice ? .isSelected : [])
        .id(choice)
    }

    private func moveArtistSelection(_ direction: MoveCommandDirection) {
        let choices: [ArtistSelection] = [.all] + artists.map { .artist($0.name) }
        let index = choices.firstIndex(of: selection ?? .all) ?? 0
        switch direction {
        case .up: selection = choices[max(0, index - 1)]
        case .down: selection = choices[min(choices.count - 1, index + 1)]
        default: break
        }
    }

    private func artistHeader(_ artist: ArtistBrowseCollection, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text(artist.name).font(.system(size: compact ? 21 : 24, weight: .bold))
                    .lineLimit(1).help(artist.name).frame(maxWidth: .infinity, alignment: .leading)
                playButton(artist.tracks, shuffle: false, label: "Play \(artist.name)", symbol: "play.fill")
                playButton(artist.tracks, shuffle: true, label: "Shuffle \(artist.name)", symbol: "shuffle")
                actions(artist.tracks, label: "Actions for \(artist.name)")
            }
            Divider()
        }
    }

    private func albumHeader(_ album: ArtistBrowseAlbum, compact: Bool, currentTrackID: String?) -> some View {
        HStack(alignment: .top, spacing: compact ? 16 : 28) {
            artwork(album, size: compact ? 96 : 160)
            VStack(alignment: .leading, spacing: 10) {
                albumHeading(album, currentTrackID: currentTrackID)
                summary(album)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func artwork(_ album: ArtistBrowseAlbum, size: CGFloat) -> some View {
        Button { start(album.tracks, shuffle: false) } label: {
            CoverArt(url: library.artworkURL(album.artworkKey), title: album.title, cornerRadius: 4)
                .frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "play.fill").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 28, height: 28)
                        .background(.black.opacity(0.5), in: Circle()).padding(7)
                }
        }
        .buttonStyle(PlaybackButtonStyle(unavailable: !canPlay(album.tracks)))
        .disabled(player.isBusy || !canPlay(album.tracks))
        .accessibilityLabel("Play \(album.title)").help("Play \(album.title)")
    }

    private func albumHeading(_ album: ArtistBrowseAlbum, currentTrackID: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Text(album.title).font(.headline).lineLimit(2).help(album.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                actions(album.tracks, label: "Actions for \(album.title)")
            }
            let metadata = [album.tracks.first?.genre, album.tracks.first?.year]
                .compactMap { $0 }.filter { !$0.isEmpty && $0 != "Unknown Genre" }.joined(separator: " · ")
            if !metadata.isEmpty {
                Text(metadata).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            // Keep the track list stationary as playback moves between albums.
            ZStack(alignment: .leading) {
                if let currentTrackID, album.songs.contains(where: { $0.track.id == currentTrackID }),
                   let info = player.formatInfo {
                    FormatChip(info: info)
                }
            }
            .frame(height: 26, alignment: .leading)
        }
    }

    private func summary(_ album: ArtistBrowseAlbum) -> some View {
        return Text("\(album.tracks.count) \(album.tracks.count == 1 ? "song" : "songs"), \(album.minutes) min")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func actions(_ tracks: [LibraryTrack], label: String) -> some View {
        Menu {
            Button("Play Next") { enqueue(tracks, true) }.disabled(player.isBusy)
            Button("Add to Queue") { enqueue(tracks, false) }.disabled(player.isBusy)
            if !library.manualPlaylists.isEmpty {
                Divider()
                Menu("Add to Playlist") {
                    ForEach(library.manualPlaylists) { playlist in
                        Button(playlist.name) { Task { await library.addTracks(tracks.filter { $0.error == nil }, to: playlist) } }
                    }
                }
            }
        } label: { circleIcon("ellipsis") }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(!canPlay(tracks)).accessibilityLabel(label)
    }

    private func playButton(_ tracks: [LibraryTrack], shuffle: Bool, label: String, symbol: String) -> some View {
        Button { start(tracks, shuffle: shuffle) } label: { circleIcon(symbol) }
            .buttonStyle(PlaybackButtonStyle(unavailable: !canPlay(tracks)))
            .disabled(player.isBusy || !canPlay(tracks)).accessibilityLabel(label).help(label)
    }

    private func circleIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(palette.accent)
            .frame(width: 26, height: 26).background(.primary.opacity(0.05), in: Circle())
    }

    private func canPlay(_ tracks: [LibraryTrack]) -> Bool { tracks.contains { $0.error == nil } }
    private func start(_ tracks: [LibraryTrack], shuffle: Bool) {
        if let first = tracks.first(where: { $0.error == nil }) { play(first, tracks, shuffle) }
    }
}
