import SwiftUI
import Library
import Player

/// A focused, full-album listening surface. Uses the existing player and queue,
/// without a second audio engine or independent playback state.
@MainActor
struct AlbumListeningModeView: View {
    let title: String
    let artist: String
    let tracks: [LibraryTrack]
    let artworkURL: URL?
    let currentTrackID: String?
    let player: Player
    let playAlbum: (Bool) -> Void
    let playTrack: (LibraryTrack) -> Void
    let enqueueAlbum: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss

    private var plan: AlbumListeningPlan { AlbumListeningPlan(tracks: tracks) }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 20) {
                    HStack {
                        Label("Album Listening", systemImage: "headphones")
                            .font(.headline).foregroundStyle(.secondary)
                        Spacer()
                        Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                    CoverArt(url: artworkURL, title: title, cornerRadius: 16)
                        .frame(width: min(320, geometry.size.width * 0.57),
                               height: min(320, geometry.size.width * 0.57))
                        .shadow(radius: 16, y: 8)
                        .accessibilityLabel("Artwork for \(title)")
                    VStack(spacing: 6) {
                        Text(title).font(.system(size: 28, weight: .semibold, design: .serif))
                            .multilineTextAlignment(.center)
                        Text(artist).font(.title3).foregroundStyle(.secondary)
                        Text("\(plan.playableTracks.count) playable tracks · \(Int(plan.duration / 60)) minutes")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    if let currentPosition = plan.position(for: currentTrackID) {
                        Text("Track \(currentPosition) of \(playable.count)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    ExpandedPlayerControls(player: player)
                        .frame(maxWidth: 430)
                    HStack(spacing: 14) {
                        Button("Play in Order", systemImage: "play.fill") { playAlbum(false) }
                        Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { enqueueAlbum(true) }
                    }
                    .disabled(player.isBusy || plan.playableTracks.isEmpty)
                    Divider()
                    LazyVStack(spacing: 4) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                            Button { playTrack(track) } label: {
                                HStack(spacing: 14) {
                                    Text("\(track.trackNumber > 0 ? track.trackNumber : index + 1)")
                                        .monospacedDigit().frame(width: 24, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(track.title).lineLimit(1)
                                        Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                    if track.id == currentTrackID {
                                        Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    Text(Self.time(track.duration)).font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(track.id == currentTrackID ? Color.accentColor.opacity(0.12) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(player.isBusy || track.error != nil || track.isMissing)
                            .accessibilityLabel("Play \(track.title)")
                        }
                    }
                }
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
                .padding(26)
            }
        }
        .frame(minWidth: 480, minHeight: 560)
    }

    private static func time(_ duration: TimeInterval) -> String {
        let seconds = duration.isFinite ? Int(max(0, duration)) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
