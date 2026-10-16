import SwiftUI

/// Playback work temporarily disables interaction, but should not fade every
/// song and cover in the library. Keep unavailable files visibly distinct.
struct PlaybackButtonStyle: ButtonStyle {
    var unavailable = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(unavailable ? 0.5 : (configuration.isPressed ? 0.75 : 1))
    }
}
