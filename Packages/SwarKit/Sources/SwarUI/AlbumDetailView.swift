import SwiftUI
import Library
import Player

/// Album artwork and metadata share one scrolling surface with the track list.
@MainActor
struct AlbumDetailView: View {
    @Environment(\.swarDensity) private var density
    @Environment(\.swarPalette) private var palette
    @Environment(\.floatingPlayerClearance) private var playerClearance
    let title: String
    let artist: String
    let tracks: [LibraryTrack]
    let artworkURL: URL?
    let player: Player
    let library: LibraryModel
    var playlists: [LibraryPlaylist] = []
    let currentTrackID: String?
    let playAlbum: (Bool) -> Void
    let playTrack: (LibraryTrack) -> Void
    let enqueueTrack: (LibraryTrack, Bool) -> Void
    let enqueueAlbum: (Bool) -> Void
    var addAlbumToPlaylist: ((LibraryPlaylist) -> Void)? = nil

    @State private var showListeningMode = false

    private var albumSummary: LibraryAlbumSummary {
        LibraryAlbumSummary(title: title, artist: artist, artworkKey: tracks.first?.artworkKey,
            trackCount: tracks.count, playableCount: tracks.filter { $0.error == nil }.count)
    }

    private var canPlay: Bool { tracks.contains { $0.error == nil } }
    private var metadata: String {
        let genres = Array(Set(tracks.map(\.genre).filter { !$0.isEmpty && $0 != "Unknown Genre" })).sorted()
        let years = Array(Set(tracks.compactMap(\.year).filter { !$0.isEmpty })).sorted()
        return [genres.joined(separator: " / "), years.joined(separator: ", ")].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        let hasMultipleDiscs = Set(tracks.map(\.discNumber)).count > 1
        GeometryReader { geometry in
            let compact = geometry.size.width < 700
            let inset: CGFloat = compact ? 24 : 40
            let coverSize: CGFloat = min(270, max(180, geometry.size.width * 0.28))
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .bottom, spacing: compact ? 24 : 34) {
                        CoverArt(url: artworkURL, title: title, cornerRadius: 10)
                            .frame(width: coverSize, height: coverSize)
                            .shadow(color: .black.opacity(0.18), radius: 14, y: 7)
                        VStack(alignment: .leading, spacing: 6) {
                            Spacer(minLength: 0)
                            Text(title).font(.system(size: compact ? 22 : 26, weight: .bold))
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            Text(artist).font(.system(size: compact ? 20 : 25, weight: .medium))
                                .foregroundStyle(palette.accent).textSelection(.enabled)
                            if !metadata.isEmpty {
                                Text(metadata).font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            // Keep header geometry stable on first play and when
                            // switching between albums or shuffled tracks.
                            ZStack(alignment: .leading) {
                                Color.clear
                                if let currentTrackID, tracks.contains(where: { $0.id == currentTrackID }),
                                   let info = player.formatInfo {
                                    FormatChip(info: info)
                                }
                            }
                            .frame(height: 26).padding(.top, 8)
                            Spacer(minLength: 20)
                            HStack(spacing: 10) {
                                Button { playAlbum(false) } label: { albumAction("Play", symbol: "play.fill") }
                                    .accessibilityLabel("Play album in order")
                                Button { playAlbum(true) } label: { albumAction("Shuffle", symbol: "shuffle") }
                                    .accessibilityLabel("Shuffle album")
                            }
                            .buttonStyle(PlaybackButtonStyle(unavailable: !canPlay))
                            .disabled(player.isBusy || !canPlay)
                        }
                        .frame(maxWidth: .infinity, minHeight: coverSize, alignment: .leading)
                    }
                    HStack {
                        Button("Focus on Album", systemImage: "headphones") { showListeningMode = true }
                            .disabled(!canPlay)
                        Spacer()
                        Button("Play Album Next", systemImage: "text.line.first.and.arrowtriangle.forward") { enqueueAlbum(true) }
                            .disabled(player.isBusy || !canPlay)
                    }.buttonStyle(.bordered)
                    HStack {
                        Text("\(tracks.count) \(tracks.count == 1 ? "song" : "songs") · \(durationDescription)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Color.clear.frame(width: 0, height: 28)
                            .albumActions(library: library, player: player, album: albumSummary, showsButton: true)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            let newDisc = index == 0 || track.discNumber != tracks[index - 1].discNumber
                            if newDisc && hasMultipleDiscs {
                                Text("Disc \(max(1, track.discNumber))")
                                    .font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, density.songPadding)
                            }
                            let current = track.id == currentTrackID
                            AlbumSongRow(track: track, library: library, fallbackNumber: index + 1,
                                         current: current, playing: current && player.isPlaying,
                                         compact: compact, alternate: index.isMultiple(of: 2), busy: player.isBusy,
                                         play: { playTrack(track) }, enqueue: { enqueueTrack(track, $0) })
                        }
                    }
                }
                .padding(.horizontal, inset).padding(.top, 12).padding(.bottom, 32 + playerClearance)
            }

        }
        .sheet(isPresented: $showListeningMode) {
            AlbumListeningModeView(title: title, artist: artist, tracks: tracks,
                artworkURL: artworkURL, currentTrackID: currentTrackID, player: player,
                playAlbum: playAlbum, playTrack: playTrack, enqueueAlbum: enqueueAlbum)
        }
    }

    private func albumAction(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
            .frame(width: 100, height: 30)
            .background(palette.buttonFill, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }

    private var durationDescription: String {
        let minutes = Int(tracks.reduce(0) { $0 + max(0, $1.duration) }) / 60
        return minutes >= 60 ? "\(minutes / 60) hr \(minutes % 60) min" : "\(minutes) min"
    }
}

struct AlbumSongRow: View {
    @Environment(\.swarDensity) private var density
    let track: LibraryTrack
    let library: LibraryModel
    let fallbackNumber: Int
    let current: Bool
    let playing: Bool
    let compact: Bool
    let alternate: Bool
    let busy: Bool
    let play: () -> Void
    let enqueue: (Bool) -> Void
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
                            Text("\(track.trackNumber > 0 ? track.trackNumber : fallbackNumber)").monospacedDigit()
                        }
                    }
                    .foregroundStyle(current ? Color.accentColor : .secondary).frame(width: 20)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(track.title).fontWeight(current ? .semibold : .medium).lineLimit(1)
                            .foregroundStyle(current ? Color.accentColor : .primary)
                        if compact { Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                        if let error = track.error { Text(error).font(.caption).foregroundStyle(.orange).lineLimit(2) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !compact {
                        Text(track.artist).foregroundStyle(.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(String(format: "%d:%02d", Int(max(0, track.duration)) / 60, Int(max(0, track.duration)) % 60))
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                }.contentShape(Rectangle())
            }
            .buttonStyle(PlaybackButtonStyle(unavailable: track.error != nil))
            .disabled(busy || track.error != nil)
            .accessibilityLabel("\(playing ? "Pause" : "Play") \(track.title), \(track.artist)")
            .accessibilityValue(current ? (playing ? "Now playing" : "Paused") : "")

        }
        .songActions(library: library, track: track, busy: busy, play: play, playLabel: playing ? "Pause" : "Play", enqueue: enqueue)
        .font(.system(size: 13)).padding(.horizontal, 12).padding(.vertical, density.songPadding)
        .background(current ? Color.accentColor.opacity(0.1) : Color.primary.opacity(hovered ? 0.055 : (alternate ? 0.025 : 0)), in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
    }
}
