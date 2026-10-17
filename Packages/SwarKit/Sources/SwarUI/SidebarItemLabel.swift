import SwiftUI

/// One selection surface avoids competing native and custom highlight colours.
struct SidebarItemLabel: View {
    let title: String
    let symbol: String
    var selected = false
    var isSearch = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    private var fill: Color {
        if selected { return SwarTheme.accent.opacity(0.11) }
        if hovered && enabled { return Color.primary.opacity(0.045) }
        return isSearch ? SwarTheme.surface.opacity(0.6) : .clear
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 15, weight: selected ? .medium : .regular))
                .frame(width: 22).foregroundStyle(selected ? SwarTheme.accent : Color.secondary)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
            Spacer(minLength: 0)
            if isSearch {
                Text("⌘F").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .foregroundStyle(selected ? SwarTheme.accent : .primary)
        .padding(.horizontal, 12).frame(minHeight: 36)
        .background(fill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(selected ? SwarTheme.accent.opacity(0.12) : (isSearch ? Color.primary.opacity(0.05) : .clear), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovered = $0 }
    }
}
