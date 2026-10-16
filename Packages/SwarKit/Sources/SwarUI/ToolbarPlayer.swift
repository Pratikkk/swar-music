import SwiftUI
import Player

/// Compact, persistent player above the library, leaving the artwork grid unobstructed.
@MainActor
struct ToolbarPlayer: View {
    let player: Player
    let openNowPlaying: () -> Void
    @State private var showQueue = false
    @State private var showActivity = false
    @State private var scrubbing = false
    @State private var seekPosition: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            bar
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
        .task(id: player.isBusy) {
            showActivity = false
            guard player.isBusy else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            showActivity = true
        }
    }

    private var bar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle").foregroundStyle(player.shuffleEnabled ? Color.accentColor : .secondary)
                        .frame(width: 24, height: 32)
                }.accessibilityLabel("Shuffle").accessibilityValue(player.shuffleEnabled ? "On" : "Off")
                    .disabled(player.isBusy)
                Button { Task { await player.previous() } } label: {
                    Image(systemName: "backward.fill").frame(width: 24, height: 32)
                }
                    .buttonStyle(PlaybackButtonStyle(unavailable: !player.canGoPrevious))
                    .accessibilityLabel("Previous Track").disabled(!player.canGoPrevious || player.isBusy)
                Button { Task { await player.togglePlayback() } } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2).frame(width: 26, height: 32)
                }.accessibilityLabel(player.isPlaying ? "Pause" : (player.isRestoredSession ? "Resume" : "Play"))
                    .disabled(!player.canTogglePlayback || player.isBusy)
                Button { Task { await player.next() } } label: {
                    Image(systemName: "forward.fill").frame(width: 24, height: 32)
                }
                    .buttonStyle(PlaybackButtonStyle(unavailable: !player.canGoNext))
                    .accessibilityLabel("Next Track").disabled(!player.canGoNext || player.isBusy)
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
                        .frame(width: 24, height: 32)
                }.menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: 24, height: 32)
                    .accessibilityLabel("Repeat: " + player.repeatMode.rawValue)
                    .disabled(!player.canTogglePlayback)
            }
            .buttonStyle(PlaybackButtonStyle())
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(action: openNowPlaying) {
                    CoverArt(url: player.artworkURL, title: player.subtitle, cornerRadius: 3)
                        .frame(width: 42, height: 42)
                        .overlay(alignment: .bottomTrailing) {
                            ProgressView().controlSize(.mini)
                                .frame(width: 16, height: 16)
                                .background(.regularMaterial, in: Circle())
                                .opacity(showActivity ? 1 : 0)
                                .accessibilityHidden(!showActivity)
                        }
                }.buttonStyle(.plain).accessibilityLabel("Open Now Playing").help("Open Now Playing (⇧⌘N)")
                    .fixedSize()
                VStack(spacing: 1) {
                    Button(action: openNowPlaying) {
                        VStack(spacing: 2) {
                            Text(player.currentURL == nil ? (player.queue.isEmpty ? "Swar" : "Queue Ready") : player.title)
                                .font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity)
                            Text(player.subtitle.isEmpty ? "Your music, in full detail" : player.subtitle)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }.lineLimit(1).truncationMode(.tail)
                            .frame(minWidth: 0, maxWidth: .infinity)
                    }.buttonStyle(.plain).accessibilityLabel("Open Now Playing")
                    Slider(value: Binding(get: { scrubbing ? seekPosition : player.position }, set: { seekPosition = $0 }),
                           in: 0...max(player.duration, 0.01), onEditingChanged: { editing in
                        if editing { seekPosition = player.position }
                        scrubbing = editing
                        if !editing { Task { await player.seek(to: seekPosition) } }
                    })
                    .controlSize(.mini).accessibilityLabel("Playback position")
                    .accessibilityValue("\(Int(player.position)) of \(Int(player.duration)) seconds")
                    // Ignore conflicting input without fading the whole seek bar
                    // each time the decoder opens a different song.
                    .disabled(player.duration == 0)
                    .allowsHitTesting(!player.isBusy || player.isSeeking)
                }
                .frame(minWidth: 0, maxWidth: .infinity)
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            VolumeControl(player: player)
            Button { showQueue.toggle() } label: { Image(systemName: "list.bullet").frame(width: 24, height: 32) }
                .foregroundStyle(showQueue ? Color.accentColor : .secondary)
                .accessibilityLabel("Show Queue").help("Up Next")
                .popover(isPresented: $showQueue) { QueueView(player: player) }
        }
        .buttonStyle(.borderless).padding(.horizontal, 16).frame(height: 56)
    }
}
