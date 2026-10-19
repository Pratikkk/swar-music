import SwiftUI
import Player

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
        CommandGroup(after: .help) {
            Button("Welcome Guide") { NotificationCenter.default.post(name: .showWelcomeGuide, object: nil) }
                .disabled(actions == nil)
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
            canSeek: player.duration > 0 && (!player.isBusy || player.isSeeking)
        ))
    }
}
