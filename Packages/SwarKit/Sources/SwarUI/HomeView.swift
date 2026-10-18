import SwiftUI
import Library
import Player
import FormatInfo

@MainActor
struct HomeView: View {
    @Environment(\.swarDensity) private var density
    @Environment(\.swarPalette) private var palette
    let library: LibraryModel
    let player: Player
    let openNowPlaying: () -> Void
    let openFavourites: () -> Void
    let openRecent: () -> Void
    let browseAlbum: (LibraryAlbumSummary) -> Void
    let addFolder: () -> Void
    @Environment(\.floatingPlayerClearance) private var clearance
    @State private var overview: LibraryOverview?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: density.sectionGap) {
                Text("Home").font(.system(size: 32, weight: .semibold, design: .serif))
                if let overview {
                    if let error = library.errorMessage {
                        HStack(alignment: .top) {
                            Label(error, systemImage: "exclamationmark.triangle").lineLimit(3).textSelection(.enabled)
                            Spacer()
                            Button { library.dismissError() } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).accessibilityLabel("Dismiss library error")
                        }.font(.caption).foregroundStyle(.orange).help(error)
                    }
                    HStack(spacing: 18) {
                        metric(overview.trackCount, title: overview.trackCount == 1 ? "song" : "songs", symbol: "music.note")
                        metric(overview.albumCount, title: overview.albumCount == 1 ? "album" : "albums", symbol: "square.stack")
                        metric(overview.losslessCount, title: "lossless", symbol: "waveform")
                    }
                    if player.canTogglePlayback { continueListening }
                    if overview.trackCount == 0 {
                        ContentUnavailableView {
                            Label("Your library starts with a folder", systemImage: "folder.badge.plus")
                        } description: {
                            Text("Choose a music folder. New songs appear automatically.")
                        } actions: {
                            Button("Add Music Folder", action: addFolder).buttonStyle(.borderedProminent)
                        }
                    } else {
                        favourites(overview.favourites)
                        recentAlbums(overview.recentAlbums)
                    }
                    folders
                } else if library.isReady, let error = library.errorMessage {
                    ContentUnavailableView {
                        Label("Couldn’t Load Your Library", systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else {
                    ProgressView("Opening your collection…").padding(.vertical, 40)
                }
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, clearance + 24)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .task(id: "\(library.overviewRevision)-\(library.isReady)-\(library.lastScanAt?.timeIntervalSince1970 ?? 0)") { await load() }
    }

    private func load() async {
        let result = await library.overview()
        guard !Task.isCancelled else { return }
        overview = result
    }

    private func metric(_ count: Int, title: String, symbol: String) -> some View {
        Label {
            Text(count.formatted()).fontWeight(.semibold) + Text(" " + title)
        } icon: { Image(systemName: symbol).foregroundStyle(palette.accent) }
        .font(.system(size: 12)).foregroundStyle(.secondary)
    }

    private var currentSourceInfo: FormatChipInfo? {
        guard let url = player.currentURL?.standardizedFileURL,
              let track = library.tracks.first(where: { (try? library.location(for: $0).file.standardizedFileURL) == url }),
              let source = track.sourceFormat else { return nil }
        return FormatClassifier.describe(source: source, path: SignalPath())
    }

    private var continueListening: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading("Continue listening", symbol: "play.circle")
            HStack(spacing: 18) {
                Button(action: openNowPlaying) {
                    CoverArt(url: player.artworkURL, title: player.title, cornerRadius: 12)
                        .frame(width: 100, height: 100)
                }.buttonStyle(.plain).accessibilityLabel("Open Now Playing")
                VStack(alignment: .leading, spacing: 6) {
                    Text(player.currentURL == nil ? "Your queue is ready" : player.title).font(.system(size: 21, weight: .semibold)).lineLimit(2)
                    Text(player.subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                    if let info = player.formatInfo ?? currentSourceInfo { FormatChip(info: info) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button { Task { await player.togglePlayback() } } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 48, height: 48).background(palette.buttonFill, in: Circle())
                }
                .buttonStyle(PlaybackButtonStyle()).disabled(player.isBusy)
                .accessibilityLabel(player.isPlaying ? "Pause current song" : "Continue listening")
            }
            .padding(20).background(SwarTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(palette.accent.opacity(0.12)))
        }
    }

    @ViewBuilder private func favourites(_ tracks: [LibraryTrack]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                heading("Favourites", symbol: "star")
                Spacer()
                Button("View All", action: openFavourites).buttonStyle(.plain).foregroundStyle(palette.accent)
            }
            if tracks.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "star").foregroundStyle(palette.accent)
                    Text("No favourites yet")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(SwarTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                    ForEach(tracks) { track in
                        Button { Task { await play([track]) } } label: {
                            HStack(spacing: 12) {
                                CoverArt(url: library.artworkURL(track.artworkKey), title: track.title, cornerRadius: 8, maximumPixelSize: 128)
                                    .frame(width: 48, height: 48)
                                    .overlay { Image(systemName: "play.fill").font(.system(size: 12)).foregroundStyle(.white).padding(7).background(.black.opacity(0.45), in: Circle()) }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                    Text(track.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: track.error == nil ? "star.fill" : "exclamationmark.triangle")
                                    .font(.system(size: 10)).foregroundStyle(track.error == nil ? palette.accent : .orange)
                            }.padding(12).background(SwarTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(PlaybackButtonStyle(unavailable: track.error != nil))
                        .disabled(player.isBusy || track.error != nil)
                        .accessibilityLabel("Play favourite " + track.title).help(track.error ?? track.title)
                        .songActions(library: library, track: track, busy: player.isBusy,
                            play: { Task { await play([track]) } }, showsButton: false,
                            enqueue: { LibraryQueueActions.enqueue([track], next: $0, library: library, player: player) })
                    }
                }
            }
        }
    }

    private func recentAlbums(_ albums: [LibraryAlbumSummary]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                heading("Recent arrivals", symbol: "sparkle")
                Spacer()
                Button("View All", action: openRecent).buttonStyle(.plain).foregroundStyle(palette.accent)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: density.gridGap, alignment: .top)], alignment: .leading, spacing: density.gridGap) {
                ForEach(albums) { album in
                    HomeAlbumCard(album: album, artworkURL: library.artworkURL(album.artworkKey),
                                  busy: player.isBusy, browse: { browseAlbum(album) }) {
                        Task {
                            let tracks = await library.tracks(in: album)
                            guard !Task.isCancelled else { return }
                            await play(tracks)
                        }
                    }.albumActions(library: library, player: player, album: album)
                }
            }
        }
    }

    private var folders: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                heading("Music folders", symbol: "folder")
                Spacer()
                Button("Add Folder", action: addFolder).buttonStyle(.plain).foregroundStyle(palette.accent)
                    .disabled(library.isScanning)
            }
            ForEach(library.folders) { folder in
                HStack(spacing: 12) {
                    Image(systemName: "folder").font(.title3).foregroundStyle(palette.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(URL(fileURLWithPath: folder.path).lastPathComponent).font(.system(size: 13, weight: .medium))
                        Text(folder.path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Label(library.isMonitoring(folder) ? "Watching" : "Needs attention", systemImage: library.isMonitoring(folder) ? "checkmark.circle" : "exclamationmark.circle")
                        .font(.system(size: 11)).foregroundStyle(library.isMonitoring(folder) ? Color.secondary : .orange)
                        .help(library.folderErrors[folder.id] ?? "Watching for new and changed songs.")
                }.padding(16).background(SwarTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            }
            SettingsLink { Text("Folder Settings…").font(.caption).foregroundStyle(.secondary) }
                .buttonStyle(.plain)
        }
    }

    private func heading(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 20, weight: .semibold, design: .serif))
    }

    private func play(_ tracks: [LibraryTrack]) async {
        guard !player.isBusy else { return }
        do {
            let entries = try tracks.filter { $0.error == nil }.map { track in
                let location = try library.location(for: track)
                return QueueEntry(url: location.file, accessRoot: location.root, title: track.title,
                    subtitle: track.artist + " · " + track.album, artworkURL: library.artworkURL(track.artworkKey), artist: track.artist, album: track.album)
            }
            guard !entries.isEmpty else { return }
            await player.play(entries, startingAt: 0)
        } catch { player.reportImportError(error) }
    }
}

/// Hover state stays local to each album, avoiding Home-wide updates as the pointer moves.
@MainActor
private struct HomeAlbumCard: View {
    @Environment(\.swarPalette) private var palette
    let album: LibraryAlbumSummary
    let artworkURL: URL?
    let busy: Bool
    let browse: () -> Void
    let play: () -> Void
    @State private var hovered = false
    @FocusState private var focus: CardFocus?
    private enum CardFocus: Hashable { case artwork, play, details }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Button(action: browse) {
                    CoverArt(url: artworkURL, title: album.title, cornerRadius: 12)
                }.buttonStyle(.plain).focused($focus, equals: .artwork)
                    .accessibilityLabel("Browse album " + album.title)
                Button(action: play) {
                    Image(systemName: "play.fill").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 32, height: 32)
                        .background(palette.buttonFill, in: Circle())
                }.buttonStyle(PlaybackButtonStyle(unavailable: album.playableCount == 0))
                    .disabled(busy || album.playableCount == 0)
                    .padding(8).focused($focus, equals: .play)
                    .opacity(hovered || focus != nil ? 1 : 0)
                    .allowsHitTesting(hovered || focus != nil)
                    .accessibilityLabel("Play album " + album.title)
            }
            Button(action: browse) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(album.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(album.artist).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).focused($focus, equals: .details).help("\(album.title)\n\(album.artist) · \(album.trackCount) \(album.trackCount == 1 ? "track" : "tracks")")
        }
        .onHover { hovered = $0 }
    }
}
