import SwiftUI
import Player
import Library

/// Persistent glass player floats above the library with stable transport widths.
@MainActor
struct ToolbarPlayer: View {
    let player: Player
    let library: LibraryModel
    let openNowPlaying: () -> Void
    @State private var showQueue = false
    @State private var showActivity = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.swarPalette) private var palette

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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.65), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.24 : 0.12), radius: 18, y: 6)
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
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.white)
                        .offset(x: player.isPlaying ? 0 : 1)
                        .frame(width: 38, height: 38)
                        .background(palette.buttonFill, in: Circle())
                        .contentShape(Circle())
                }.accessibilityLabel(player.isPlaying ? "Pause" : (player.isRestoredSession ? "Resume" : "Play"))
                    .buttonStyle(PlaybackButtonStyle(unavailable: !player.canTogglePlayback))
                    .disabled(!player.canTogglePlayback || player.isBusy)
                Button { Task { await player.next() } } label: {
                    Image(systemName: "forward.fill").frame(width: 24, height: 32)
                }
                    .buttonStyle(PlaybackButtonStyle(unavailable: !player.canGoNext))
                    .accessibilityLabel("Next Track").disabled(!player.canGoNext || player.isBusy)
                RepeatButton(player: player)
                SleepTimerMenu(timer: player.sleepTimer)
            }
            .buttonStyle(PlaybackButtonStyle())
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button(action: openNowPlaying) {
                    CoverArt(url: player.artworkURL, title: player.subtitle, cornerRadius: 3, maximumPixelSize: 128)
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
                    .currentSongActions(library: library, player: player)
                VStack(spacing: 1) {
                    Button(action: openNowPlaying) {
                        VStack(spacing: 2) {
                            Text(player.currentURL == nil ? (player.queue.isEmpty ? "Nothing Playing" : "Queue Ready") : player.title)
                                .font(.system(size: 12, weight: .medium))
                                .frame(maxWidth: .infinity)
                            Text(player.subtitle.isEmpty ? "Choose a song" : player.subtitle)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                        }.lineLimit(1).truncationMode(.tail)
                            .frame(minWidth: 0, maxWidth: .infinity)
                    }.buttonStyle(.plain).accessibilityLabel("Open Now Playing")
                        .currentSongActions(library: library, player: player)
                    FloatingPlayerSeekBar(player: player)
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

/// Playback clock updates only invalidate this small control, leaving the glass
/// bar, artwork, transport buttons and the scrolling library out of that update.
@MainActor
private struct FloatingPlayerSeekBar: View {
    let player: Player
    @State private var scrubbing = false
    @State private var seekPosition = 0.0
    @State private var seekURL: URL?

    var body: some View {
        Slider(value: Binding(get: { scrubbing ? seekPosition : player.position }, set: { seekPosition = $0 }),
               in: 0...max(player.duration, 0.01), onEditingChanged: { editing in
            if editing {
                seekURL = player.currentURL
                scrubbing = true
            } else {
                let target = seekPosition
                scrubbing = false
                guard let seekURL, seekURL == player.currentURL, player.duration > 0, !player.isBusy else { return }
                Task { await player.seek(to: target) }
            }
        })
        .controlSize(.mini).accessibilityLabel("Playback position")
        .accessibilityValue("\(Int(player.position)) of \(Int(player.duration)) seconds")
        .disabled(player.duration == 0)
        .allowsHitTesting(!player.isBusy || player.isSeeking)
        .onAppear { seekPosition = player.position }
        .onChange(of: player.position) { _, position in if !scrubbing { seekPosition = position } }
        .onChange(of: player.currentURL) { scrubbing = false; seekURL = nil; seekPosition = player.position }
    }
}
