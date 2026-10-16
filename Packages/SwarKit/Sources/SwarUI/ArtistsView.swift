import SwiftUI
import Library
import Player

private enum ArtistSelection: Hashable {
    case all
    case artist(String)
}

private struct ArtistCollection: Identifiable {
    var id: String { name }
    let name: String
    let albums: [ArtistAlbum]
    var tracks: [LibraryTrack] { albums.flatMap(\.tracks) }
}

private struct ArtistAlbum: Identifiable {
    var id: String { title }
    let title: String
    let tracks: [LibraryTrack]
}

/// Album artists keep compilations together; individual performers remain on song rows.
@MainActor
struct ArtistsView: View {
    let library: LibraryModel
    let player: Player
    let play: (LibraryTrack, [LibraryTrack], Bool?) -> Void
    let enqueue: ([LibraryTrack], Bool) -> Void
    @State private var selection: ArtistSelection? = .all

    private var artists: [ArtistCollection] {
        Dictionary(grouping: library.tracks, by: { $0.albumArtist.isEmpty ? $0.artist : $0.albumArtist })
            .map { name, tracks in
                let albums = Dictionary(grouping: tracks, by: \.album).map { title, tracks in
                    ArtistAlbum(title: title, tracks: tracks.sorted {
                        if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                        if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                        return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                    })
                }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                return ArtistCollection(name: name, albums: albums)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var visibleArtists: [ArtistCollection] {
        if case .artist(let name) = selection { return artists.filter { $0.name == name } }
        return artists
    }

    var body: some View {
        GeometryReader { geometry in
            let listWidth = min(285, max(180, geometry.size.width * 0.28))
            let compact = geometry.size.width - listWidth < 560
            HStack(spacing: 0) {
                artistList.frame(width: listWidth)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 48) {
                        ForEach(visibleArtists) { artist in
                            artistSection(artist, compact: compact)
                        }
                    }
                    .padding(.horizontal, compact ? 20 : 40).padding(.vertical, 24)
                }
                .id(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: artists.map(\.id)) { _, ids in
            if case .artist(let name) = selection, !ids.contains(name) { selection = .all }
        }
    }

    private var artistList: some View {
        List(selection: $selection) {
            Label {
                Text("All Artists").fontWeight(.semibold)
            } icon: {
                Image(systemName: "music.mic").font(.title2).frame(width: 36, height: 36)
                    .foregroundStyle(selection == .all ? Color.white : .pink)
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(selection == .all ? Color.white : .primary)
            .background(selection == .all ? Color.pink : .clear)
            .listRowInsets(EdgeInsets()).tag(ArtistSelection.all)
            ForEach(artists) { artist in
                HStack(spacing: 9) {
                    CoverArt(url: library.artworkURL(artist.tracks.compactMap(\.artworkKey).first), title: artist.name)
                        .frame(width: 36, height: 36).clipShape(Circle())
                    Text(artist.name).font(.system(size: 12)).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(selection == .artist(artist.name) ? Color.white : .primary)
                .background(selection == .artist(artist.name) ? Color.pink : .clear)
                .listRowInsets(EdgeInsets()).tag(ArtistSelection.artist(artist.name)).help(artist.name)
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .accessibilityLabel("Artists")
    }

    private func artistSection(_ artist: ArtistCollection, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 10) {
                Text(artist.name).font(.system(size: compact ? 21 : 24, weight: .bold))
                    .lineLimit(1).help(artist.name).frame(maxWidth: .infinity, alignment: .leading)
                playButton(artist.tracks, shuffle: false, label: "Play \(artist.name)", symbol: "play.fill")
                playButton(artist.tracks, shuffle: true, label: "Shuffle \(artist.name)", symbol: "shuffle")
                actions(artist.tracks, label: "Actions for \(artist.name)")
            }
            Divider().padding(.top, -12)
            ForEach(artist.albums) { album in
                albumSection(album, compact: compact)
            }
        }
    }

    @ViewBuilder private func albumSection(_ album: ArtistAlbum, compact: Bool) -> some View {
        if compact {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    artwork(album, size: 96)
                    albumHeading(album)
                }
                songs(album)
                summary(album)
            }
        } else {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    artwork(album, size: 160)
                    summary(album)
                }.frame(width: 160, alignment: .leading)
                VStack(alignment: .leading, spacing: 16) {
                    albumHeading(album)
                    songs(album)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func artwork(_ album: ArtistAlbum, size: CGFloat) -> some View {
        Button { start(album.tracks, shuffle: false) } label: {
            CoverArt(url: library.artworkURL(album.tracks.compactMap(\.artworkKey).first), title: album.title, cornerRadius: 4)
                .frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "play.fill").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 28, height: 28)
                        .background(.black.opacity(0.5), in: Circle()).padding(7)
                }
        }
        .buttonStyle(.plain).disabled(!canPlay(album.tracks))
        .accessibilityLabel("Play \(album.title)").help("Play \(album.title)")
    }

    private func albumHeading(_ album: ArtistAlbum) -> some View {
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
            if album.tracks.contains(where: isCurrent), let info = player.formatInfo { FormatChip(info: info) }
        }
    }

    private func songs(_ album: ArtistAlbum) -> some View {
        VStack(spacing: 0) {
            Divider()
            ForEach(Array(album.tracks.enumerated()), id: \.element.id) { index, track in
                if index > 0, track.discNumber != album.tracks[index - 1].discNumber {
                    Text("Disc \(max(1, track.discNumber))").font(.caption.bold())
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }
                AlbumSongRow(track: track, fallbackNumber: index + 1,
                             current: isCurrent(track), playing: isCurrent(track) && player.isPlaying,
                             compact: true, alternate: false, busy: player.isBusy,
                             playlists: library.playlists,
                             play: {
                                 if isCurrent(track) { Task { await player.togglePlayback() } }
                                 else { play(track, album.tracks, nil) }
                             },
                             enqueue: { enqueue([track], $0) },
                             addToPlaylist: { playlist in Task { await library.addTracks([track], to: playlist) } })
            }
        }
    }

    private func summary(_ album: ArtistAlbum) -> some View {
        let minutes = Int(ceil(album.tracks.reduce(0) { $0 + max(0, $1.duration) } / 60))
        return Text("\(album.tracks.count) \(album.tracks.count == 1 ? "song" : "songs"), \(minutes) min")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func actions(_ tracks: [LibraryTrack], label: String) -> some View {
        Menu {
            Button("Play Next") { enqueue(tracks, true) }
            Button("Add to Queue") { enqueue(tracks, false) }
            if !library.playlists.isEmpty {
                Divider()
                Menu("Add to Playlist") {
                    ForEach(library.playlists) { playlist in
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
            .buttonStyle(.plain).disabled(!canPlay(tracks)).accessibilityLabel(label).help(label)
    }

    private func circleIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.pink)
            .frame(width: 26, height: 26).background(.primary.opacity(0.05), in: Circle())
    }

    private func canPlay(_ tracks: [LibraryTrack]) -> Bool { !player.isBusy && tracks.contains { $0.error == nil } }
    private func start(_ tracks: [LibraryTrack], shuffle: Bool) {
        if let first = tracks.first(where: { $0.error == nil }) { play(first, tracks, shuffle) }
    }
    private func isCurrent(_ track: LibraryTrack) -> Bool {
        player.currentURL != nil && (try? library.location(for: track).file.standardizedFileURL) == player.currentURL?.standardizedFileURL
    }
}
