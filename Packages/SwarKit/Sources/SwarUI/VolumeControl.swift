import SwiftUI
import Player

@MainActor
struct VolumeControl: View {
    let player: Player
    var expanded = false
    @State private var dragging = false
    @State private var value: Double = 0

    private var help: String {
        if let error = player.volumeError { return error }
        if player.outputVolume.canSet && !player.canSetOutputVolume { return "Updating output volume…" }
        if !player.outputVolume.canSet { return "\(player.outputVolume.deviceName) doesn’t expose volume control. Use its own volume controls." }
        return "Output volume \(Int(((player.outputVolume.level ?? 0) * 100).rounded()))% · \(player.outputVolume.deviceName). Affects other apps using this output."
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: player.outputVolume.isMuted || (player.outputVolume.level ?? 0) == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            Slider(value: Binding(
                get: { dragging ? value : (player.outputVolume.level ?? 0) },
                set: { newValue in value = newValue; Task { await player.setVolume(to: newValue) } }
            ), in: 0...1, onEditingChanged: { editing in
                if editing { value = player.outputVolume.level ?? 0 }
                dragging = editing
            })
            .controlSize(.small)
            .disabled(!player.outputVolume.canSet)
            .allowsHitTesting(player.canSetOutputVolume)
            .accessibilityLabel("Output volume")
            .accessibilityValue(player.outputVolume.level.map { "\(Int(((dragging ? value : $0) * 100).rounded())) percent\(player.outputVolume.isMuted ? ", muted" : "")" } ?? "Unavailable")
            if player.volumeError != nil {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .accessibilityLabel(help)
            }
        }
        .frame(width: expanded ? 180 : 100)
        .help(help)
        .onChange(of: player.outputVolume.deviceID) { dragging = false }
    }
}
