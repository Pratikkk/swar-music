import SwiftUI
import Player

@MainActor
struct PlaybackSettingsView: View {
    @Bindable var player: Player
    var body: some View {
        Form {
            Section {
                CrossfadeControls(player: player)
                Text("Blend queued songs using compatible beats, with a short fade when rhythm is uncertain. Songs from the same album stay gapless.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("A preferred beat window, not a fixed duration. Changes apply to the next transition that has not started; uncertain rhythm uses a short fade.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("After turning Smart Crossfade on or off, start a new queue with Shuffle All, or play a different song. Resuming the current song keeps its existing mode.")
                Text("Crossfade processes audio as float PCM and reserves volume headroom. It is not bit-perfect. Turn it off for untouched playback.")
            }.font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped).padding()
    }
}
