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
            AlbumGroup(id: key, title: tracks[0].album, artist: tracks[0].albumArtist, tracks: tracks.sorted {
                if $0.discNumber != $1.discNumber { return $0.discNumber < $1.discNumber }
                if $0.trackNumber != $1.trackNumber { return $0.trackNumber < $1.trackNumber }
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            })
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
                        Section(name) { ForEach(groups[name] ?? []) { track in trackRow(track, context: groups[name] ?? []) } }
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
                    CoverArt(url: library.artworkURL(album.tracks.compactMap(\.artworkKey).first), title: album.title).frame(width: 80, height: 80)
                    VStack(alignment: .leading) {
                        Text(album.title).font(.title2.bold())
                        Text(album.artist).foregroundStyle(.secondary)
                        Button("Play Album", systemImage: "play.fill") {
                            if let first = album.tracks.first(where: { $0.error == nil }) {
                                Task { await play(first, context: album.tracks) }
                            }
                        }.disabled(player.isBusy || album.tracks.allSatisfy { $0.error != nil })
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
                                CoverArt(url: library.artworkURL(album.tracks.compactMap(\.artworkKey).first), title: album.title)
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
        List(tracks) { track in trackRow(track, context: tracks) }.listStyle(.inset)
    }

    private func trackRow(_ track: LibraryTrack, context: [LibraryTrack]) -> some View {
            let current = (try? library.location(for: track).file.standardizedFileURL) == player.currentURL?.standardizedFileURL && player.currentURL != nil
            return HStack(spacing: 12) {
                ArtworkPlaybackButton(
                    url: library.artworkURL(track.artworkKey), album: track.album,
                    title: track.title, current: current, playing: current && player.isPlaying,
                    unavailable: track.error != nil, busy: player.isBusy
                ) {
                    Task {
                        if current { await player.togglePlayback() }
                        else { await play(track, context: context) }
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).fontWeight(current ? .semibold : .medium)
                        .foregroundStyle(current ? Color.accentColor : Color.primary).lineLimit(1)
                    Text(track.artist + " · " + track.album).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let error = track.error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                }
                Spacer()
                if let codec = track.codec { Text(codec).font(.caption).foregroundStyle(.secondary) }
                if let rate = track.sampleRate { Text("\(rate / 1000, specifier: "%g") kHz").font(.caption).foregroundStyle(.secondary) }
                Text(String(format: "%d:%02d", Int(track.duration) / 60, Int(track.duration) % 60)).monospacedDigit().foregroundStyle(.secondary)
            }.padding(.vertical, 6)
            .listRowBackground(current ? Color.accentColor.opacity(0.06) : Color.clear)
            .contextMenu {
                Button("Play Next") { enqueue(track, next: true) }
                Button("Add to Queue") { enqueue(track, next: false) }
            }
            .disabled(track.error != nil || player.isBusy)
    }

    private func entry(_ track: LibraryTrack) throws -> QueueEntry {
        let location = try library.location(for: track)
        return QueueEntry(url: location.file, accessRoot: location.root, title: track.title,
                          subtitle: track.artist + " · " + track.album, artworkURL: library.artworkURL(track.artworkKey))
    }

    private func play(_ track: LibraryTrack, context: [LibraryTrack]) async {
        guard !player.isBusy else { return }
        do {
            let playable = context.filter { $0.error == nil }
            guard let index = playable.firstIndex(where: { $0.id == track.id }) else { return }
            let entries = try playable.map { try entry($0) }
            await player.play(entries, startingAt: index)
        } catch { player.reportImportError(error) }
    }

    private func enqueue(_ track: LibraryTrack, next: Bool) {
        do { player.enqueue(try entry(track), playNext: next) }
        catch { player.reportImportError(error) }
    }
}

private struct AlbumGroup: Identifiable {
    let id: String
    let title: String
    let artist: String
    let tracks: [LibraryTrack]
}

/// The cover is the entire hit target, keeping transport out of the text columns.
private struct ArtworkPlaybackButton: View {
    let url: URL?
    let album: String
    let title: String
    let current: Bool
    let playing: Bool
    let unavailable: Bool
    let busy: Bool
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            CoverArt(url: url, title: album)
                .frame(width: 44, height: 44)
                .overlay {
                    RoundedRectangle(cornerRadius: 6).fill(.black.opacity(hovered ? 0.12 : 0))
                    Image(systemName: unavailable ? "exclamationmark.triangle.fill" : (playing ? "pause.fill" : "play.fill"))
                        .font(.system(size: 11, weight: .semibold))
                        .offset(x: !playing && !unavailable ? 1 : 0)
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(current ? Color.accentColor : .black.opacity(hovered ? 0.75 : 0.5), in: Circle())
                        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(current ? Color.accentColor : .clear, lineWidth: 1.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.borderless)
        .disabled(unavailable || busy)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
        .accessibilityLabel("\(playing ? "Pause" : "Play") \(title)")
        .accessibilityValue(current ? (playing ? "Now playing" : "Current track, paused") : "")
        .help(unavailable ? "This song cannot be played" : "\(playing ? "Pause" : "Play") \(title)")
    }
}
