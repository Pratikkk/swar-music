import SwiftUI
import Player

@MainActor
struct VolumeControl: View {
    let player: Player
    var expanded = false
    @State private var slider = VolumeSliderState()

    private var help: String {
        if let error = player.volumeError { return error }
        if player.outputVolume.canSet && !player.canSetOutputVolume { return "Updating output volume…" }
        if !player.outputVolume.canSet { return "\(player.outputVolume.deviceName) doesn’t expose volume control. Use its own volume controls." }
        return "Output volume \(Int((slider.value * 100).rounded()))% · \(player.outputVolume.deviceName). Affects other apps using this output."
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: player.outputVolume.isMuted || slider.value == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
            Slider(value: Binding(
                get: { slider.value },
                set: { newValue in
                    slider.change(to: newValue)
                    // Keyboard/accessibility adjustments may not start a drag.
                    if !slider.dragging, let request = slider.request() { commit(request) }
                }
            ), in: 0...1, onEditingChanged: { editing in
                if editing { slider.begin() }
                else if let request = slider.end() { commit(request) }
            })
            .controlSize(.small)
            .disabled(!player.outputVolume.canSet)
            .allowsHitTesting(player.canSetOutputVolume)
            .accessibilityLabel("Output volume")
            .accessibilityValue(player.outputVolume.level.map { _ in "\(Int((slider.value * 100).rounded())) percent\(player.outputVolume.isMuted ? ", muted" : "")" } ?? "Unavailable")
            Text(player.outputVolume.canSet ? "\(Int((slider.value * 100).rounded()))%" : "–")
                .font(.system(size: 9, weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 29, alignment: .trailing).accessibilityHidden(true)
            if player.volumeError != nil {
                Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .accessibilityLabel(help)
            }
        }
        .frame(width: expanded ? 216 : 136)
        .help(help)
        .task(id: slider.dragging) {
            guard slider.dragging else { return }
            var lastLevel: Double? = player.outputVolume.level
            while slider.dragging && !Task.isCancelled {
                if lastLevel != slider.value, let request = slider.request() {
                    lastLevel = request.level
                    await write(request)
                }
                do { try await Task.sleep(for: .milliseconds(60)) } catch { return }
            }
        }
        .onChange(of: player.outputVolume, initial: true) { synchronize() }
        .onChange(of: player.canSetOutputVolume) { synchronize() }
        .onChange(of: player.isSettingOutputVolume) {
            slider.settle(level: player.outputVolume.level, deviceID: player.outputVolume.deviceID,
                          available: player.canSetOutputVolume, writing: player.isSettingOutputVolume)
        }
        .onDisappear {
            slider.cancel(level: player.outputVolume.level, deviceID: player.outputVolume.deviceID,
                          available: player.canSetOutputVolume)
        }
    }

    private func synchronize() {
        slider.synchronize(level: player.outputVolume.level, deviceID: player.outputVolume.deviceID,
                           available: player.canSetOutputVolume)
    }

    private func commit(_ request: VolumeSliderState.Request) {
        Task { await write(request) }
    }

    private func write(_ request: VolumeSliderState.Request) async {
        guard !Task.isCancelled else { return }
        guard player.outputVolume.deviceID == request.deviceID, player.canSetOutputVolume else {
            synchronize()
            return
        }
        guard slider.submit(request) else { return }
        await player.setVolume(to: request.level)
        // Coalesced calls can return before the latest hardware write finishes.
        slider.finish(request, level: player.outputVolume.level, deviceID: player.outputVolume.deviceID,
                      available: player.canSetOutputVolume, writing: player.isSettingOutputVolume)
    }
}
