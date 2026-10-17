import SwiftUI

private struct FloatingPlayerClearanceKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var floatingPlayerClearance: CGFloat {
        get { self[FloatingPlayerClearanceKey.self] }
        set { self[FloatingPlayerClearanceKey.self] = newValue }
    }
}

/// A trailing list row provides reliable clearance on macOS, where List does
/// not consistently honor scroll-content margins. It scrolls with the songs.
struct FloatingPlayerScrollSpacer: View {
    @Environment(\.floatingPlayerClearance) private var clearance

    var body: some View {
        Color.clear.frame(height: clearance)
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }
}
