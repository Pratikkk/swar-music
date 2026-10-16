import SwiftUI
import Player

/// Compact, persistent player above the library, leaving the artwork grid unobstructed.
@MainActor
struct ToolbarPlayer: View {
    let player: Player
    let openNowPlaying: () -> Void
    @State private var showQueue = false
    @State private var scrubbing = false
    @State private var seekPosition: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                bar(showModes: true)
                bar(showModes: false)
            }
            if let notice = player.sessionNotice {
                HStack {
                    Label(notice, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Spacer()
                    Button("Dismiss") { player.dismissSessionNotice() }.buttonStyle(.borderless)
                }.font(.caption).padding([.horizontal, .bottom], 12)
            }
            if let error = player.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding([.horizontal, .bottom], 12)
            }
            if player.underrunFrames > 0 {
                Text("Buffer underruns: \(player.underrunFrames) frames")
                    .font(.caption).foregroundStyle(.orange).padding(.bottom, 6)
            }
        }
        .background(.bar)
    }

    private func bar(showModes: Bool) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                if showModes {
                    Button { player.toggleShuffle() } label: {
                        Image(systemName: "shuffle").foregroundStyle(player.shuffleEnabled ? Color.accentColor : .secondary)
                    }.accessibilityLabel("Shuffle").accessibilityValue(player.shuffleEnabled ? "On" : "Off")
                        .disabled(player.isBusy)
                }
                Button { Task { await player.previous() } } label: { Image(systemName: "backward.fill") }
                    .accessibilityLabel("Previous Track").disabled(!player.canGoPrevious || player.isBusy)
                Button { Task { await player.togglePlayback() } } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2).frame(width: 26, height: 32)
                }.accessibilityLabel(player.isPlaying ? "Pause" : (player.isRestoredSession ? "Resume" : "Play"))
                    .disabled(!player.canTogglePlayback || player.isBusy)
                Button { Task { await player.next() } } label: { Image(systemName: "forward.fill") }
                    .accessibilityLabel("Next Track").disabled(!player.canGoNext || player.isBusy)
                if showModes {
                    Menu {
                        ForEach(RepeatMode.allCases, id: \.self) { mode in
                            Button { player.setRepeatMode(mode) } label: {
                                if player.repeatMode == mode { Label("Repeat " + mode.rawValue, systemImage: "checkmark") }
                                else { Text("Repeat " + mode.rawValue) }
                            }
                        }
                    } label: {
                        Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                            .foregroundStyle(player.repeatMode == .off ? Color.secondary : .accentColor)
                    }.menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Repeat: " + player.repeatMode.rawValue).disabled(player.isBusy)
                }
            }
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(action: openNowPlaying) {
                    CoverArt(url: player.artworkURL, title: player.subtitle, cornerRadius: 3)
                        .frame(width: 42, height: 42)
                }.buttonStyle(.plain).accessibilityLabel("Open Now Playing").help("Open Now Playing (⇧⌘N)")
                VStack(spacing: 1) {
                    Button(action: openNowPlaying) {
                        VStack(spacing: 2) {
                            Text(player.isBusy ? "Loading song…" : (player.currentURL == nil ? (player.queue.isEmpty ? "Swar" : "Queue Ready") : player.title))
                                .font(.system(size: 12, weight: .medium))
                            Text(player.subtitle.isEmpty ? "Your music, in full detail" : player.subtitle)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }.lineLimit(1).frame(maxWidth: .infinity)
                    }.buttonStyle(.plain).accessibilityLabel("Open Now Playing")
                    Slider(value: Binding(get: { scrubbing ? seekPosition : player.position }, set: { seekPosition = $0 }),
                           in: 0...max(player.duration, 0.01), onEditingChanged: { editing in
                        if editing { seekPosition = player.position }
                        scrubbing = editing
                        if !editing { Task { await player.seek(to: seekPosition) } }
                    })
                    .controlSize(.mini).accessibilityLabel("Playback position")
                    .accessibilityValue("\(Int(player.position)) of \(Int(player.duration)) seconds")
                    .disabled(player.duration == 0 || player.isBusy)
                }
                if player.isBusy { ProgressView().controlSize(.mini) }
            }
            .padding(.horizontal, 4).frame(minWidth: 170, maxWidth: .infinity)
            VolumeControl(player: player)
            Button { showQueue.toggle() } label: { Image(systemName: "list.bullet") }
                .foregroundStyle(showQueue ? Color.accentColor : .secondary)
                .accessibilityLabel("Show Queue").help("Up Next")
                .popover(isPresented: $showQueue) { QueueView(player: player) }
        }
        .buttonStyle(.borderless).padding(.horizontal, 18).frame(height: 56)
    }
}
