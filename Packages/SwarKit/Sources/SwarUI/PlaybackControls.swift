import SwiftUI
import Player

@MainActor
struct PlaybackControls: View {
    let player: Player
    @State private var scrubbing = false
    @State private var seekPosition: Double = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = player.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .accessibilityLabel("Playback error: \(error)")
            }
            HStack(spacing: 16) {
                Button {
                    Task { await player.togglePlayback() }
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                .disabled(player.duration == 0 || player.isBusy)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(player.title).fontWeight(.semibold).lineLimit(1)
                        if let info = player.formatInfo { FormatChip(info: info) }
                        if player.isBusy { ProgressView().controlSize(.small) }
                        Spacer()
                        Text(time(scrubbing ? seekPosition : player.position) + " / " + time(player.duration))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
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
                }
            }
            if player.underrunFrames > 0 {
                Text("Buffer underruns: \(player.underrunFrames) frames")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(20)
        .background(.bar)
    }

    private func time(_ seconds: Double) -> String {
        let seconds = Int(max(0, seconds))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct PlaybackActions {
    var open: () -> Void
    var toggle: () -> Void
    var seek: (Double) -> Void
    var canOpen: Bool
    var canPlay: Bool
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
            Button("Play / Pause") { actions?.toggle() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(actions?.canPlay != true)
            Button("Seek Forward") { actions?.seek(5) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(actions?.canPlay != true)
            Button("Seek Backward") { actions?.seek(-5) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(actions?.canPlay != true)
        }
    }
}

extension View {
    func playbackCommands(player: Player, open: @escaping () -> Void) -> some View {
        focusedSceneValue(\.playbackActions, PlaybackActions(
            open: open,
            toggle: { Task { await player.togglePlayback() } },
            seek: { delta in Task { await player.seek(to: player.position + delta) } },
            canOpen: !player.isBusy,
            canPlay: player.duration > 0 && !player.isBusy
        ))
    }
}
