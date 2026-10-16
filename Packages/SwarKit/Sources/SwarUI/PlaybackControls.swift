import SwiftUI
import Player

@MainActor
struct PlaybackControls: View {
    let player: Player
    var expanded = false
    var openNowPlaying: (() -> Void)?
    @State private var showQueue = false
    @State private var scrubbing = false
    @State private var seekPosition: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let notice = player.sessionNotice {
                HStack(alignment: .top) {
                    Label(notice, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button { player.dismissSessionNotice() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Dismiss session notice")
                }
            }
            if player.isRestoredSession {
                HStack {
                    Label(player.errorMessage == nil ? "Previous session · Ready to resume" : "Previous session · Choose another song or retry", systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Resume") { Task { await player.togglePlayback() } }
                        .buttonStyle(.borderless).disabled(player.isBusy)
                }
            }
            if let error = player.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .accessibilityLabel("Playback error: \(error)")
            }
            if expanded {
                VStack(spacing: 16) {
                    CoverArt(url: player.artworkURL, title: player.subtitle.isEmpty ? player.title : player.subtitle, cornerRadius: 12)
                        .frame(width: 240, height: 240)
                        .shadow(color: .black.opacity(0.14), radius: 16, y: 8)
                        .overlay {
                            if player.isBusy {
                                ProgressView().padding(12).background(.regularMaterial, in: Circle())
                            }
                        }
                    VStack(spacing: 6) {
                        Text(player.isBusy ? "Loading song…" : (player.currentURL == nil ? (player.queue.isEmpty ? "Nothing Playing" : "Queue Ready") : player.title))
                            .font(.title2.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                        Text(player.subtitle.isEmpty ? (player.queue.isEmpty ? "Choose a song from your library" : "Press Play to start your queue") : player.subtitle)
                            .foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                    }
                    .multilineTextAlignment(.center)
                    if let info = player.formatInfo { FormatChip(info: info) }
                    transport
                    queueOptions
                    VolumeControl(player: player, expanded: true)
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 14) {
                    Button { openNowPlaying?() } label: {
                        CoverArt(url: player.artworkURL, title: player.subtitle.isEmpty ? player.title : player.subtitle)
                            .frame(width: 56, height: 56)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                                    .padding(3).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                                    .padding(3).accessibilityHidden(true)
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(openNowPlaying == nil || (player.currentURL == nil && player.queue.isEmpty))
                    .accessibilityLabel("Open Now Playing")
                    .help("Open Now Playing (⇧⌘N)")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(player.currentURL == nil && !player.queue.isEmpty ? "Queue Ready" : player.title).font(.headline).lineLimit(1)
                        Text(player.subtitle.isEmpty ? (player.currentURL == nil ? (player.queue.isEmpty ? "Choose a song to start listening" : "Press Play to start your queue") : "Local audio") : player.subtitle)
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                    if player.isBusy { ProgressView().controlSize(.small) }
                    transport
                    queueOptions
                }
            }
            HStack(spacing: 10) {
                if !expanded, let info = player.formatInfo { FormatChip(info: info) }
                Text(time(scrubbing ? seekPosition : player.position))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 30, alignment: .trailing)
                Slider(value: Binding(
                    get: { scrubbing ? seekPosition : player.position },
                    set: { seekPosition = $0 }
                ), in: 0...max(player.duration, 0.01), onEditingChanged: { editing in
                    if editing { seekPosition = player.position }
                    scrubbing = editing
                    if !editing { Task { await player.seek(to: seekPosition) } }
                })
                .accessibilityLabel("Playback position")
                .disabled(player.duration == 0 || player.isBusy)
                Text(time(player.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 30, alignment: .leading)
                if !expanded { VolumeControl(player: player) }
            }
            if player.underrunFrames > 0 {
                Text("Buffer underruns: \(player.underrunFrames) frames")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background { if !expanded { Rectangle().fill(.bar) } }
    }

    private var transport: some View {
        HStack(spacing: expanded ? 28 : 14) {
                Button { Task { await player.previous() } } label: {
                    Image(systemName: "backward.end.fill").font(expanded ? .title3 : .body)
                }
                .buttonStyle(.borderless).accessibilityLabel("Previous Track")
                .disabled(!player.canGoPrevious || player.isBusy)
                Button {
                    Task { await player.togglePlayback() }
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(expanded ? .largeTitle : .title2)
                        .frame(width: expanded ? 56 : 36, height: expanded ? 56 : 36)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(player.isPlaying ? "Pause" : (player.isRestoredSession ? "Resume" : "Play"))
                .disabled(!player.canTogglePlayback || player.isBusy)

                Button { Task { await player.next() } } label: {
                    Image(systemName: "forward.end.fill").font(expanded ? .title3 : .body)
                }
                .buttonStyle(.borderless).accessibilityLabel("Next Track")
                .disabled(!player.canGoNext || player.isBusy)

        }
    }

    private var queueOptions: some View {
        HStack(spacing: 12) {
                Button { player.toggleShuffle() } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(player.shuffleEnabled ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless).accessibilityLabel(player.shuffleEnabled ? "Turn Shuffle Off" : "Turn Shuffle On")
                .accessibilityValue(player.shuffleEnabled ? "On" : "Off")
                .disabled(player.isBusy)
                Menu {
                    ForEach(RepeatMode.allCases, id: \.self) { mode in
                        Button { player.setRepeatMode(mode) } label: {
                            if player.repeatMode == mode { Label("Repeat " + mode.rawValue, systemImage: "checkmark") }
                            else { Text("Repeat " + mode.rawValue) }
                        }
                    }
                } label: {
                    Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(player.repeatMode == .off ? Color.secondary : Color.accentColor)
                }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Repeat: " + player.repeatMode.rawValue)
                .disabled(player.isBusy)
                if !expanded {
                Button { showQueue.toggle() } label: { Image(systemName: "list.bullet") }
                    .buttonStyle(.borderless).accessibilityLabel("Show Queue")
                    .popover(isPresented: $showQueue) { QueueView(player: player) }
                }
        }
    }

    private func time(_ seconds: Double) -> String {
        let seconds = Int(max(0, seconds))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct PlaybackActions {
    var open: () -> Void
    var nowPlaying: () -> Void
    var toggle: () -> Void
    var next: () -> Void
    var previous: () -> Void
    var canNext: Bool
    var canPrevious: Bool
    var seek: (Double) -> Void
    var canOpen: Bool
    var canPlay: Bool
    var canSeek: Bool
}

private struct PlaybackActionsKey: FocusedValueKey {
    typealias Value = PlaybackActions
}

private extension FocusedValues {
    var playbackActions: PlaybackActions? {
        get { self[PlaybackActionsKey.self] }
        set { self[PlaybackActionsKey.self] = newValue }
    }
}

@MainActor
public struct SwarCommands: Commands {
    @FocusedValue(\.playbackActions) private var actions
    public init() {}

    public var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Audio File…") { actions?.open() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(actions?.canOpen != true)
        }
        CommandMenu("Playback") {
            Button("Show Now Playing") { actions?.nowPlaying() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Divider()
            Button("Play / Pause") { actions?.toggle() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(actions?.canPlay != true)
            Button("Next Track") { actions?.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(actions?.canNext != true)
            Button("Previous Track") { actions?.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(actions?.canPrevious != true)
            Button("Seek Forward") { actions?.seek(5) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(actions?.canSeek != true)
            Button("Seek Backward") { actions?.seek(-5) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(actions?.canSeek != true)
        }
    }
}

extension View {
    func playbackCommands(player: Player, canOpen: Bool = true, open: @escaping () -> Void, nowPlaying: @escaping () -> Void) -> some View {
        focusedSceneValue(\.playbackActions, PlaybackActions(
            open: open,
            nowPlaying: nowPlaying,
            toggle: { Task { await player.togglePlayback() } },
            next: { Task { await player.next() } },
            previous: { Task { await player.previous() } },
            canNext: player.canGoNext && !player.isBusy,
            canPrevious: player.canGoPrevious && !player.isBusy,
            seek: { delta in Task { await player.seek(to: player.position + delta) } },
            canOpen: canOpen && !player.isBusy,
            canPlay: player.canTogglePlayback && !player.isBusy,
            canSeek: player.duration > 0 && !player.isBusy
        ))
    }
}
