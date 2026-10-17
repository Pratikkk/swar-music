import SwiftUI
import Player

/// Kept outside the artwork/queue switch so controls never disappear or reset.
@MainActor
struct ExpandedPlayerControls: View {
    let player: Player
    @State private var scrubbing = false
    @State private var seekPosition = 0.0
    @State private var seekURL: URL?

    private var displayedPosition: Double { scrubbing ? seekPosition : player.position }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                HStack {
                    Text(time(displayedPosition)).frame(width: 46, alignment: .leading)
                    Spacer()
                    Text("Seek to " + time(seekPosition)).foregroundStyle(SwarTheme.accent)
                        .opacity(scrubbing ? 1 : 0).accessibilityHidden(!scrubbing)
                    Spacer()
                    Text("−" + time(ceil(max(0, player.duration - displayedPosition))))
                        .frame(width: 46, alignment: .trailing)
                }
                .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { seekPosition },
                    set: { seekPosition = $0 }
                ), in: 0...max(player.duration, 0.01), onEditingChanged: { editing in
                    if editing {
                        seekURL = player.currentURL
                        scrubbing = true
                    } else {
                        let target = seekPosition
                        scrubbing = false
                        guard let seekURL, seekURL == player.currentURL, player.duration > 0, !player.isBusy else {
                            seekPosition = player.position
                            return
                        }
                        Task { await player.seek(to: target) }
                    }
                })
                .accessibilityLabel("Playback position")
                .accessibilityValue(time(displayedPosition) + " of " + time(player.duration))
                .disabled(player.duration <= 0)
                .allowsHitTesting(!player.isBusy || player.isSeeking)
            }
            HStack(spacing: 24) {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle").frame(width: 24, height: 32)
                        .foregroundStyle(player.shuffleEnabled ? SwarTheme.accent : .secondary)
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
                        .background(SwarTheme.buttonFill, in: Circle()).contentShape(Circle())
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
                Text(player.outputVolume.deviceName).font(.system(size: 10))
                    .foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 120, alignment: .leading)
            }
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, 28).padding(.top, 10).padding(.bottom, 20)
        .frame(maxWidth: .infinity)
        .onAppear { seekPosition = player.position }
        .onChange(of: player.position) { _, position in
            if !scrubbing { seekPosition = position }
        }
        .onChange(of: player.currentURL) { scrubbing = false; seekURL = nil; seekPosition = player.position }
    }

    private func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max) else { return "0:00" }
        let value = Int(seconds)
        if value >= 3600 { return String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) }
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
