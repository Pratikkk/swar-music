import SwiftUI
import Player

@MainActor
struct RepeatButton: View {
    @Environment(\.swarPalette) private var palette
    let player: Player

    private var nextMode: RepeatMode {
        switch player.repeatMode {
        case .off: .all
        case .all: .one
        case .one: .off
        }
    }

    var body: some View {
        Button { player.setRepeatMode(nextMode) } label: {
            Image(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
                .foregroundStyle(player.repeatMode == .off ? Color.secondary : palette.accent)
                .frame(width: 24, height: 32)
        }
        .buttonStyle(PlaybackButtonStyle(unavailable: !player.canTogglePlayback))
        .accessibilityLabel("Repeat")
        .accessibilityValue(player.repeatMode.rawValue)
        .accessibilityHint("Switch to Repeat " + nextMode.rawValue)
        .help("Repeat: " + player.repeatMode.rawValue + " · Click for " + nextMode.rawValue)
        .disabled(!player.canTogglePlayback || player.isBusy)
    }
}
