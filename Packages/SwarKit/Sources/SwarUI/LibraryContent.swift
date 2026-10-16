import SwiftUI
import Library
import Player

@MainActor
struct LibraryContent: View {
    let library: LibraryModel
    let player: Player
    let section: String
    @State private var selectedAlbum: String?

    private var albums: [AlbumGroup] {
        Dictionary(grouping: library.tracks, by: { $0.albumArtist + "\u{1f}" + $0.album }).map { key, tracks in
            AlbumGroup(id: key, title: tracks[0].album, artist: tracks[0].albumArtist, tracks: tracks)
        }.sorted {
            if section == "Recently Added" { return ($0.tracks.map(\.addedAt).max() ?? .distantPast) > ($1.tracks.map(\.addedAt).max() ?? .distantPast) }
            return $0.artist.localizedStandardCompare($1.artist) == .orderedAscending ||
                ($0.artist == $1.artist && $0.title.localizedStandardCompare($1.title) == .orderedAscending)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = library.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            if let progress = library.progress {
                HStack {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        .frame(maxWidth: 180)
                    Text("\(progress.folder): \(progress.completed) of \(progress.total)")
                    if progress.failed > 0 { Text("\(progress.failed) unreadable").foregroundStyle(.orange) }
                }
                .font(.caption).padding(12)
            }
            if library.tracks.isEmpty {
                ContentUnavailableView {
                    Label(library.search.isEmpty ? "Your Music Library" : "No Matching Music", systemImage: "music.note.list")
                } description: {
                    Text(library.search.isEmpty ? "Add a folder to browse your local music. Files stay where they are." : "Try a title, artist, or album name.")
                }
            } else if section == "Albums" || section == "Recently Added" {
                albumContent
            } else if section == "Artists" || section == "Genres" {
                List {
                    let groups = Dictionary(grouping: library.tracks, by: { section == "Artists" ? $0.artist : $0.genre })
                    ForEach(groups.keys.sorted(), id: \.self) { name in
                        Section(name) { ForEach(groups[name] ?? []) { track in trackRow(track) } }
                    }
                }.listStyle(.inset)
            } else {
                trackList(library.tracks)
            }
            if library.totalCount > 0 {
                HStack {
                    Text("\(library.tracks.count) of \(library.totalCount) tracks")
                        .foregroundStyle(.secondary)
                    if library.unreadableCount > 0 {
                        Text("\(library.unreadableCount) unreadable in library").foregroundStyle(.orange)
                    }
                    Spacer()
                    if library.tracks.count < library.totalCount {
                        Button("Load More") { Task { await library.loadMore() } }
                    }
                }
                .font(.caption).padding(12)
            }
        }
        .onChange(of: library.search) { selectedAlbum = nil }
    }

    @ViewBuilder private var albumContent: some View {
        if let selectedAlbum, let album = albums.first(where: { $0.id == selectedAlbum }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    Button { self.selectedAlbum = nil } label: { Label("Albums", systemImage: "chevron.left") }
                    Artwork(url: library.artworkURL(album.tracks.compactMap(\.artworkKey).first)).frame(width: 80, height: 80)
                    VStack(alignment: .leading) {
                        Text(album.title).font(.title2.bold())
                        Text(album.artist).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(20)
                trackList(album.tracks)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 220), alignment: .top)], alignment: .leading, spacing: 24) {
                    ForEach(albums) { album in
                        Button { selectedAlbum = album.id } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                Artwork(url: library.artworkURL(album.tracks.compactMap(\.artworkKey).first))
                                    .aspectRatio(1, contentMode: .fit)
                                Text(album.title).fontWeight(.medium).lineLimit(1)
                                Text(album.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }.buttonStyle(.plain).accessibilityLabel("\(album.title), \(album.artist), open album")
                    }
                }.padding(24)
            }
        }
    }

    private func trackList(_ tracks: [LibraryTrack]) -> some View {
        List(tracks) { track in trackRow(track) }.listStyle(.inset)
    }

    private func trackRow(_ track: LibraryTrack) -> some View {
            HStack(spacing: 12) {
                Button { Task { await play(track) } } label: {
                    Image(systemName: track.error == nil ? "play.fill" : "exclamationmark.triangle")
                        .frame(width: 24, height: 30)
                }
                .buttonStyle(.borderless)
                .disabled(track.error != nil || player.isBusy)
                .accessibilityLabel("Play \(track.title)")
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).fontWeight(.medium).lineLimit(1)
                    Text(track.artist + " · " + track.album).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let error = track.error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                }
                Spacer()
                if let codec = track.codec { Text(codec).font(.caption).foregroundStyle(.secondary) }
                if let rate = track.sampleRate { Text("\(rate / 1000, specifier: "%g") kHz").font(.caption).foregroundStyle(.secondary) }
                Text(String(format: "%d:%02d", Int(track.duration) / 60, Int(track.duration) % 60)).monospacedDigit().foregroundStyle(.secondary)
            }.padding(.vertical, 4)
    }

    private func play(_ track: LibraryTrack) async {
        guard !player.isBusy else { return }
        do {
            let location = try library.location(for: track)
            await player.open(location.file, accessRoot: location.root, displayTitle: track.title)
            if player.errorMessage == nil { await player.togglePlayback() }
        } catch { player.reportImportError(error) }
    }
}

private struct AlbumGroup: Identifiable {
    let id: String
    let title: String
    let artist: String
    let tracks: [LibraryTrack]
}

private struct Artwork: View {
    let url: URL?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(.quaternary)
            if let url {
                AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
            } else { placeholder }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityHidden(true)
    }
    private var placeholder: some View { Image(systemName: "music.note").font(.largeTitle).foregroundStyle(.secondary) }
}
