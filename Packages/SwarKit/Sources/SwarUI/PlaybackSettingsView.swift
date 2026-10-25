import SwiftUI
import Player

@MainActor
struct PlaybackSettingsView: View {
    @Bindable var player: Player
    var body: some View {
        Form {
            Section {
                Toggle("Smart Crossfade", isOn: $player.crossfadeEnabled)
                Text("Blend queued songs using compatible beats, with a short fade when rhythm is uncertain. Songs from the same album stay gapless.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("After changing this, start a new queue with Shuffle All, or play a different song. Resuming the current song keeps its existing mode.")
                Text("Crossfade processes audio as float PCM and reserves volume headroom. It is not bit-perfect. Turn it off for untouched playback.")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped).padding()
    }
}
