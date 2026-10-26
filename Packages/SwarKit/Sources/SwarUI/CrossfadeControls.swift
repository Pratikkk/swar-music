import SwiftUI
import Player

@MainActor
struct CrossfadeControls: View {
    @Bindable var player: Player

    var body: some View {
        Toggle("Smart Crossfade", isOn: $player.crossfadeEnabled)
        Picker("Transition length", selection: $player.crossfadeLength) {
            ForEach(CrossfadeLength.allCases, id: \.self) { length in
                Text("\(length.title) · \(length.beats) beats").tag(length)
            }
        }
        .disabled(!player.crossfadeEnabled)
    }
}

@MainActor
struct NowPlayingCrossfadeControls: View {
    let player: Player

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Transitions").font(.headline)
            CrossfadeControls(player: player)
            Text(player.isCrossfadeProcessing
                 ? "Processed audio is active. Length changes apply to transitions that have not started."
                 : "Untouched playback is active. Start a different song to apply Smart Crossfade.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Same-album tracks stay gapless. Beat windows may shorten when songs do not match. Crossfade is not bit-perfect.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 320)
    }
}
