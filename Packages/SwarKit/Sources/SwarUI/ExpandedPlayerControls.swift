import SwiftUI
import Player

/// Kept outside the artwork/queue switch so controls never disappear or reset.
@MainActor
struct ExpandedPlayerControls: View {
    @Environment(\.swarPalette) private var palette
    let player: Player
    var body: some View {
        VStack(spacing: 12) {
            ExpandedSeekBar(player: player)
            HStack(spacing: 24) {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle").frame(width: 24, height: 32)
                        .foregroundStyle(player.shuffleEnabled ? palette.accent : .secondary)
                }
                .accessibilityLabel("Shuffle").accessibilityValue(player.shuffleEnabled ? "On" : "Off")
                .disabled(player.isBusy)
                Button { Task { await player.previous() } } label: {
                    Image(systemName: "backward.fill").font(.system(size: 20)).frame(width: 28, height: 44)
                }
                .buttonStyle(PlaybackButtonStyle(unavailable: !player.canGoPrevious))
                .disabled(!player.canGoPrevious || player.isBusy).accessibilityLabel("Previous Track")
                Button { Task { await player.togglePlayback() } } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 23, weight: .semibold))
                        .offset(x: player.isPlaying ? 0 : 1)
                        .foregroundStyle(.white).frame(width: 56, height: 56)
                        .background(palette.buttonFill, in: Circle()).contentShape(Circle())
                }
                .buttonStyle(PlaybackButtonStyle(unavailable: !player.canTogglePlayback))
                .disabled(!player.canTogglePlayback || player.isBusy)
                .accessibilityLabel(player.isPlaying ? "Pause" : (player.isRestoredSession ? "Resume" : "Play"))
                .help("Play / Pause (Space)")
                Button { Task { await player.next() } } label: {
                    Image(systemName: "forward.fill").font(.system(size: 20)).frame(width: 28, height: 44)
                }
                .buttonStyle(PlaybackButtonStyle(unavailable: !player.canGoNext))
                .disabled(!player.canGoNext || player.isBusy).accessibilityLabel("Next Track")
                RepeatButton(player: player)
            }
            .buttonStyle(PlaybackButtonStyle()).foregroundStyle(.primary)
            HStack(spacing: 12) {
                VolumeControl(player: player, expanded: true)
                OutputDevicePicker(player: player, expanded: true)
            }
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 20)
        .frame(maxWidth: .infinity)

    }

}

/// Clock and drag updates stay inside this small view, outside transport and volume.
/// Read the live clock here, while retaining the pointer preview during a seek.
/// Only this small seek view observes position ticks; artwork, transport controls,
/// and the surrounding library do not need to redraw.
@MainActor
private struct ExpandedSeekBar: View {
    let player: Player
    @Environment(\.swarPalette) private var palette
    @State private var seek = SeekSliderState()
    @AppStorage("waveformSeekBar") private var waveformEnabled = true
    private var displayedPosition: Double { seek.displayedPosition(player.position) }

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(time(displayedPosition)).frame(width: 46, alignment: .leading)
                Spacer()
                Text("Seek to " + time(seek.value)).foregroundStyle(palette.accent)
                    .opacity(seek.dragging && !waveformEnabled ? 1 : 0)
                    .accessibilityHidden(!seek.dragging || waveformEnabled)
                Spacer()
                Text("−" + time(ceil(max(0, player.duration - displayedPosition))))
                    .frame(width: 46, alignment: .trailing)
            }
            .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
            PlaybackSeekControl(player: player, state: $seek)
        }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
        let value = Int(seconds)
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
