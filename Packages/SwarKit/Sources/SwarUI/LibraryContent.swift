import SwiftUI
import Library
import Player

@MainActor
struct LibraryContent: View {
    @Environment(\.swarDensity) private var density
    @Environment(\.swarPalette) private var palette
    @Environment(\.floatingPlayerClearance) private var playerClearance
    let library: LibraryModel
    let player: Player
    let section: String
    /// Cached current track ID; resolved from player.currentURL only when it changes,
    /// not on every LibraryContent body invalidation.
    @State private var currentTrackIDCache: String?
    @State private var loadingNextPage = false

    var body: some View {
        let currentTrackID = currentTrackIDCache
        VStack(spacing: 0) {
            LibraryStatusBanner(library: library, inset: 12, dismissibleError: true, detailedProgress: true)
            if library.totalCount > 0 {
                HStack {
                    Text("\(library.tracks.count) of \(library.totalCount) \(TrackSearchQuery(library.search).isEmpty ? (library.totalCount == 1 ? "track" : "tracks") : "matches")")
                        .foregroundStyle(.secondary)
                    if library.unreadableCount > 0 {
                        Text("\(library.unreadableCount) unreadable in \(section == "Favourites" ? "favourites" : "library")").foregroundStyle(.orange)
                    }
                    Spacer()
                    if section == "Favourites" {
                        favouritePlaybackButtons
                    }
                    if library.tracks.count < library.totalCount {
                        Button("Load More") { loadNextPage() }
                            .disabled(loadingNextPage)
                    }
                }
                .font(.caption).padding(12)
            }
            if library.tracks.isEmpty {
                ContentUnavailableView {
                    Label(library.search.isEmpty ? (section == "Favourites" ? "No Favourites Yet" : "Your Music Library") : "No Matching Music",
                          systemImage: section == "Favourites" ? "star" : "music.note.list")
                } description: {
                    Text(library.search.isEmpty
                         ? (section == "Favourites" ? "Choose Favourite from any song’s options menu to keep it here." : "Add a folder to browse your local music. Files stay where they are.")
                         : "Try different words or choose All Fields from the search icon.")
                } actions: {
                    if !TrackSearchQuery(library.search).isEmpty {
                        Button("Clear Search") { library.search = "" }
                    } else if section != "Favourites" {
                        SettingsLink { Text("Add Music Folder…") }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if section == "Artists" {
                ArtistsView(library: library, player: player,
                            play: { track, context, shuffle in Task { await play(track, context: context, shuffle: shuffle) } },
                            enqueue: { tracks, next in
                                do {
                                    let entries = try tracks.filter { $0.error == nil }.map { try entry($0) }
                                    for entry in next ? Array(entries.reversed()) : entries { player.enqueue(entry, playNext: next) }
                                } catch { player.reportImportError(error) }
                            })
            } else if section == "Genres" {
                List {
                    let groups = Dictionary(grouping: library.tracks, by: { section == "Artists" ? $0.artist : $0.genre })
                    ForEach(groups.keys.sorted(), id: \.self) { name in
                        Section(name) {
                            ForEach(groups[name] ?? []) { track in
                                trackRow(track, context: groups[name] ?? [], currentTrackID: currentTrackID)
                            }
                        }
                    }
                    FloatingPlayerScrollSpacer()
                }.listStyle(.inset)
            } else {
                trackList(library.tracks, currentTrackID: currentTrackID)
            }

        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: player.currentURL) {
            currentTrackIDCache = library.trackID(at: player.currentURL)
        }
        .task {
            currentTrackIDCache = library.trackID(at: player.currentURL)
        }
    }

    private var favouritePlaybackButtons: some View {
        HStack(spacing: 12) {
            Button {
                guard let first = library.tracks.first(where: { $0.error == nil }) else { return }
                Task { await play(first, context: library.tracks, shuffle: false) }
            } label: { Label("Play", systemImage: "play.fill") }
            .accessibilityLabel("Play favourites in order")
            Button {
                guard let first = library.tracks.first(where: { $0.error == nil }) else { return }
                Task { await play(first, context: library.tracks, shuffle: true) }
            } label: { Label("Shuffle", systemImage: "shuffle") }
            .accessibilityLabel("Shuffle favourites")
        }
        .foregroundStyle(palette.accent)
        .buttonStyle(PlaybackButtonStyle(unavailable: library.tracks.allSatisfy { $0.error != nil }))
        .disabled(player.isBusy || library.tracks.allSatisfy { $0.error != nil })
    }

    private func trackList(_ tracks: [LibraryTrack], currentTrackID: String?) -> some View {
        List {
            ForEach(tracks) { track in trackRow(track, context: tracks, currentTrackID: currentTrackID) }
            if tracks.count < library.totalCount {
                HStack {
                    Spacer()
                    if loadingNextPage {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Loading more songs")
                    } else {
                        Button("Load More Songs") { loadNextPage() }
                            .buttonStyle(.borderless)
                    }
                    Spacer()
                }
                .padding(.vertical, 12)
                .onAppear { loadNextPage() }
            }
            FloatingPlayerScrollSpacer()
        }.listStyle(.inset)
    }

    /// Load another bounded page only when its footer becomes visible.
    /// The explicit button remains available if automatic loading is interrupted.
    private func loadNextPage() {
        guard !loadingNextPage, library.tracks.count < library.totalCount else { return }
        loadingNextPage = true
        Task {
            await library.loadMore()
            loadingNextPage = false
        }
    }

    private func trackRow(_ track: LibraryTrack, context: [LibraryTrack], currentTrackID: String?) -> some View {
            let current = track.id == currentTrackID
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
                    HStack(spacing: 5) {
                        Text(track.title).fontWeight(current ? .semibold : .medium)
                            .foregroundStyle(current ? Color.accentColor : Color.primary).lineLimit(1)
                        if library.favoriteTrackIDs.contains(track.id) {
                            Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(palette.accent)
                                .accessibilityLabel("Favourite")
                        }
                    }
                    Text(track.artist + " · " + track.album).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let error = track.error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(track.duration.isFinite && track.duration >= 0 && track.duration < Double(Int.max)
                         ? String(format: "%d:%02d", Int(track.duration) / 60, Int(track.duration) % 60) : "–:––")
                        .monospacedDigit()
                    Text([track.codec, track.sampleRate.map { String(format: "%g kHz", $0 / 1000) }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
            }
            .songActions(library: library, track: track, busy: player.isBusy, play: {
                Task {
                    if current { await player.togglePlayback() }
                    else { await play(track, context: context) }
                }
            }, playLabel: current && player.isPlaying ? "Pause" : "Play", enqueue: { enqueue(track, next: $0) })
            .padding(.vertical, density == .compact ? 3 : 6)
            .listRowBackground(current ? Color.accentColor.opacity(0.06) : Color.clear)
            .onDrag { LibrarySongDrag.provider(for: track, library: library) }

    }

    private func entry(_ track: LibraryTrack) throws -> QueueEntry {
        let location = try library.location(for: track)
        return QueueEntry(url: location.file, accessRoot: location.root, title: track.title,
                          subtitle: track.artist + " · " + track.album, artworkURL: library.artworkURL(track.artworkKey),
                          artist: track.artist, album: track.album)
    }

    private func play(_ track: LibraryTrack, context: [LibraryTrack], shuffle: Bool? = nil) async {
        guard !player.isBusy else { return }
        do {
            let playable = context.filter { $0.error == nil }
            guard let index = playable.firstIndex(where: { $0.id == track.id }) else { return }
            let entries = try playable.map { try entry($0) }
            await player.play(entries, startingAt: index, shuffle: shuffle)
        } catch { player.reportImportError(error) }
    }

    private func enqueue(_ track: LibraryTrack, next: Bool) {
        do { player.enqueue(try entry(track), playNext: next) }
        catch { player.reportImportError(error) }
    }
}

/// The cover is the entire hit target, keeping transport out of the text columns.
private struct ArtworkPlaybackButton: View {
    @Environment(\.swarDensity) private var density
    let url: URL?
    let album: String
    let title: String
    let current: Bool
    let playing: Bool
    let unavailable: Bool
    let busy: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            CoverArt(url: url, title: album, maximumPixelSize: 128)
                .frame(width: density.artworkSize, height: density.artworkSize)
                .overlay {
                    HoveredPlaybackOverlay(
                        unavailable: unavailable, playing: playing, current: current
                    )
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(current ? Color.accentColor : .clear, lineWidth: 1.5)
                }
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(PlaybackButtonStyle(unavailable: unavailable))
        .disabled(unavailable || busy)
        .accessibilityLabel("\(playing ? "Pause" : "Play") \(title)")
        .accessibilityValue(current ? (playing ? "Now playing" : "Current track, paused") : "")
        .help(unavailable ? "This song cannot be played" : "\(playing ? "Pause" : "Play") \(title)")
    }
}

/// Hover-dependent overlay isolated into its own view so only this layer
/// invalidates on hover, not the cover art or button container.
private struct HoveredPlaybackOverlay: View {
    let unavailable: Bool
    let playing: Bool
    let current: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.black.opacity(hovered ? 0.12 : 0))
            Image(systemName: unavailable ? "exclamationmark.triangle.fill" : (playing ? "pause.fill" : "play.fill"))
                .font(.system(size: 11, weight: .semibold))
                .offset(x: !playing && !unavailable ? 1 : 0)
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(current ? Color.accentColor : .black.opacity(hovered ? 0.75 : 0.5), in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        }
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}
