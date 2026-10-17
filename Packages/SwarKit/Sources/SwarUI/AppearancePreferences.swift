import SwiftUI
import AppKit

enum SwarAppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

enum SwarAccent: String, CaseIterable, Identifiable, Sendable {
    case violet, ocean, forest, rose, amber
    var id: Self { self }
    var title: String { rawValue.capitalized }
    private var components: (Double, Double, Double) {
        switch self {
        case .violet: (0.36, 0.24, 0.73)
        case .ocean: (0.10, 0.36, 0.68)
        case .forest: (0.12, 0.42, 0.32)
        case .rose: (0.64, 0.19, 0.36)
        case .amber: (0.57, 0.32, 0.08)
        }
    }
    private var darkComponents: (Double, Double, Double) {
        switch self {
        case .violet: (0.72, 0.63, 1)
        case .ocean: (0.43, 0.72, 1)
        case .forest: (0.43, 0.82, 0.65)
        case .rose: (1, 0.55, 0.70)
        case .amber: (1, 0.74, 0.38)
        }
    }
    var buttonFill: Color {
        let c = components
        return Color(red: c.0, green: c.1, blue: c.2)
    }
    var accent: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? self.darkComponents : self.components
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
}

enum SwarDensity: String, CaseIterable, Identifiable {
    case compact, comfortable
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var sidebarHeight: CGFloat { self == .compact ? 32 : 36 }
    var songPadding: CGFloat { self == .compact ? 8 : 14 }
    var artworkSize: CGFloat { self == .compact ? 36 : 44 }
    var gridGap: CGFloat { self == .compact ? 12 : 20 }
    var sectionGap: CGFloat { self == .compact ? 20 : 28 }
}

private struct SwarPaletteKey: EnvironmentKey {
    static let defaultValue = SwarAccent.violet
}
private struct SwarDensityKey: EnvironmentKey {
    static let defaultValue = SwarDensity.comfortable
}
extension EnvironmentValues {
    var swarPalette: SwarAccent {
        get { self[SwarPaletteKey.self] }
        set { self[SwarPaletteKey.self] = newValue }
    }
    var swarDensity: SwarDensity {
        get { self[SwarDensityKey.self] }
        set { self[SwarDensityKey.self] = newValue }
    }
}

private struct SwarAppearanceModifier: ViewModifier {
    @AppStorage("appearanceMode") private var mode: SwarAppearanceMode = .system
    @AppStorage("accentPalette") private var accent: SwarAccent = .violet
    @AppStorage("interfaceDensity") private var density: SwarDensity = .comfortable

    func body(content: Content) -> some View {
        content.environment(\.swarPalette, accent)
            .environment(\.swarDensity, density)
            .preferredColorScheme(mode.colorScheme)
            .tint(accent.accent).accentColor(accent.accent)
    }
}

public extension View {
    /// Observe shared appearance preferences without replacing the view's identity.
    func swarAppearancePreferences() -> some View {
        modifier(SwarAppearanceModifier())
    }
}
