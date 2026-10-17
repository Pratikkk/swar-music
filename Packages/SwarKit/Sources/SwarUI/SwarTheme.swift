import SwiftUI
import AppKit

/// Swar's palette keeps selection, playback, and quality accents consistent.
enum SwarTheme {
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.09, green: 0.095, blue: 0.12, alpha: 1)
            : NSColor(srgbRed: 0.985, green: 0.978, blue: 0.963, alpha: 1)
    })
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.14, green: 0.145, blue: 0.18, alpha: 1)
            : NSColor(srgbRed: 1, green: 0.996, blue: 0.985, alpha: 1)
    })
}
