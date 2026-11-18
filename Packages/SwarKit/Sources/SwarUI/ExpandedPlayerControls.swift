import SwiftUI
import Player

/// Kept outside the artwork/queue switch so controls never disappear or reset.
@MainActor
struct ExpandedPlayerControls: View {
    @Environment(\.swarPalette) private var palette
    let player: Player
    @State private var hoverStates: [String: Bool] = [:]
    var body: some View {
        VStack(spacing: 14) {
            ExpandedSeekBar(player: player)
            HStack(spacing: 20) {
                ControlButton(
                    systemName: "shuffle",
                    isActive: player.shuffleEnabled,
                    action: { player.toggleShuffle() },
                    isEnabled: !player.isBusy,
                    accessibilityLabel: "Shuffle",
                    accessibilityValue: player.shuffleEnabled ? "On" : "Off"
                )
                ControlButton(
                    systemName: "backward.fill",
                    font: .system(size: 20),
                    action: { Task { await player.previous() } },
                    isEnabled: player.canGoPrevious && !player.isBusy,
                    accessibilityLabel: "Previous Track"
                )
                ControlButton(
                    systemName: player.isPlaying ? "pause.fill" : "play.fill",
                    font: .system(size: 23, weight: .semibold),
                    isProminent: true,
                    action: { Task { await player.togglePlayback() } },
                    isEnabled: player.canTogglePlayback && !player.isBusy,
                    accessibilityLabel: player.isPlaying ? "Pause" : (player.isRestoredSession ? "Resume" : "Play"),
                    helpText: "Play / Pause (Space)"
                )
                ControlButton(
                    systemName: "forward.fill",
                    font: .system(size: 20),
                    action: { Task { await player.next() } },
                    isEnabled: player.canGoNext && !player.isBusy,
                    accessibilityLabel: "Next Track"
                )
                RepeatButton(player: player)
            }
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

/// Polished control button with hover/focus states and consistent styling
private struct ControlButton: View {
    @Environment(\.swarPalette) private var palette
    let systemName: String
    var font: Font = .system(size: 16)
    var isProminent = false
    var isActive = false
    let action: () -> Void
    let isEnabled: Bool
    let accessibilityLabel: String
    var accessibilityValue: String? = nil
    var helpText: String? = nil
    
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(font)
                .offset(x: systemName.contains("play.fill") && !isProminent ? 1 : 0)
                .foregroundStyle(isProminent ? .white : (isActive ? palette.accent : (isHovered || isFocused ? .primary : .secondary)))
                .frame(width: isProminent ? 56 : 36, height: isProminent ? 56 : 36)
                .background(
                    isProminent ? palette.buttonFill :
                    (isHovered || isFocused ? Color.primary.opacity(0.1) : Color.clear),
                    in: Circle()
                )
                .contentShape(Circle())
                .scaleEffect(isProminent && (isHovered || isFocused) ? 1.05 : 1)
        }
        .buttonStyle(PlaybackButtonStyle(unavailable: !isEnabled))
        .disabled(!isEnabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue ?? "")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .help(helpText ?? accessibilityLabel)
        .focused($isFocused)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: isFocused)
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
        VStack(spacing: 3) {
            HStack {
                Text(time(displayedPosition)).frame(width: 50, alignment: .leading)
                Spacer()
                Text("Seek to " + time(seek.value)).foregroundStyle(palette.accent)
                    .opacity(seek.dragging && !waveformEnabled ? 1 : 0)
                    .accessibilityHidden(!seek.dragging || waveformEnabled)
                Spacer()
                Text("−" + time(ceil(max(0, player.duration - displayedPosition))))
                    .frame(width: 50, alignment: .trailing)
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
