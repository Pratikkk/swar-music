import SwiftUI

/// Shared local thumbnail view; decoding and the bounded memory cache live off the UI actor.
struct CoverArt: View {
    @Environment(\.swarPalette) private var palette
    let url: URL?
    var title = ""
    var cornerRadius: CGFloat = 6
    var crossfade = false
    var maximumPixelSize = 384
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cover: CoverBitmap?
    @State private var loadedRequest: CoverRequest?

    private var tint: Color {
        let colors: [Color] = [.indigo, .teal, .purple, .blue, .orange, palette.accent]
        return colors[title.utf8.reduce(0) { ($0 + Int($1)) % colors.count }]
    }

    var body: some View {
        let request = url.map { CoverRequest(url: $0, pixels: maximumPixelSize) }
        let cached = request.flatMap { CoverCache.shared.cached($0) }
        let bitmap = cached ?? (loadedRequest == request || crossfade ? cover : nil)
        ZStack {
            if let bitmap {
                if crossfade {
                    Image(decorative: bitmap.image, scale: 1).resizable().scaledToFill()
                        .id(ObjectIdentifier(bitmap)).transition(.opacity)
                } else {
                    Image(decorative: bitmap.image, scale: 1).resizable().scaledToFill()
                }
            } else {
                LinearGradient(colors: [tint.opacity(0.2), tint.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint.opacity(0.7))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay { RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5) }
        .animation(crossfade && !reduceMotion ? .easeInOut(duration: 0.18) : nil, value: loadedRequest)
        .task(id: request) {
            guard let request else { cover = nil; loadedRequest = nil; return }
            guard loadedRequest != request else { return }
            // The view already displays a synchronous cache hit; retain it for
            // crossfades without waiting for the background decoder actor.
            if let cached { cover = cached; loadedRequest = request; return }
            // Dwell: only begin a background decode once the cell has been
            // visible long enough that a fast scroll is unlikely to cancel it.
            // This prevents a decode storm when flicking through long lists.
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard !Task.isCancelled else { return }
            let result = await CoverCache.shared.image(for: request)
            guard !Task.isCancelled else { return }
            cover = result; loadedRequest = request
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
