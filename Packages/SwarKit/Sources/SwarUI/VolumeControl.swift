import SwiftUI
import Player

@MainActor
struct VolumeControl: View {
    let player: Player
    var expanded = false
    @State private var dragging = false
    @State private var value: Double = 0
    @State private var editingDeviceID: UInt32?

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
                set: { newValue in
                    value = newValue
                    // Keyboard/accessibility adjustments may not start a drag.
                    if !dragging { commit(newValue, deviceID: player.outputVolume.deviceID) }
                }
            ), in: 0...1, onEditingChanged: { editing in
                if editing {
                    value = player.outputVolume.level ?? 0
                    editingDeviceID = player.outputVolume.deviceID
                    dragging = true
                } else if dragging {
                    let device = editingDeviceID
                    dragging = false
                    editingDeviceID = nil
                    if let device { commit(value, deviceID: device) }
                }
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
        .onChange(of: player.outputVolume.deviceID) { cancelDrag() }
        .onChange(of: player.canSetOutputVolume) { if !player.canSetOutputVolume { cancelDrag() } }
        .onDisappear { cancelDrag() }
    }

    private func cancelDrag() {
        dragging = false
        editingDeviceID = nil
    }

    private func commit(_ level: Double, deviceID: UInt32) {
        Task {
            // Do not apply an old device's draft to a newly selected output.
            guard player.outputVolume.deviceID == deviceID, player.canSetOutputVolume else { return }
            await player.setVolume(to: level)
        }
    }
}
