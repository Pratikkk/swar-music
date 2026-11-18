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
    @State private var previousCover: CoverBitmap?
    @State private var isCrossfading = false

    private var tint: Color {
        let colors: [Color] = [.indigo, .teal, .purple, .blue, .orange, palette.accent]
        return colors[title.utf8.reduce(0) { ($0 + Int($1)) % colors.count }]
    }

    var body: some View {
        let request = url.map { CoverRequest(url: $0, pixels: maximumPixelSize) }
        let cached = request.flatMap { CoverCache.shared.cached($0) }
        let bitmap = cached ?? (loadedRequest == request ? cover : nil)
        ZStack {
            if let bitmap {
                Image(decorative: bitmap.image, scale: 1).resizable().scaledToFill()
                    .id(ObjectIdentifier(bitmap))
            } else {
                LinearGradient(colors: [tint.opacity(0.2), tint.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(tint.opacity(0.7))
            }
            // Crossfade overlay for track changes in Now Playing
            if crossfade, let previousCover, isCrossfading {
                Image(decorative: previousCover.image, scale: 1).resizable().scaledToFill()
                    .id(ObjectIdentifier(previousCover))
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay { RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.06), lineWidth: 0.5) }
        .animation(crossfade && !reduceMotion ? .easeInOut(duration: 0.22) : nil, value: loadedRequest)
        .animation(crossfade && !reduceMotion ? .easeInOut(duration: 0.22) : nil, value: isCrossfading)
        .task(id: request) {
            guard let request else { cover = nil; loadedRequest = nil; return }
            guard loadedRequest != request else { return }
            // The view already displays a synchronous cache hit; retain it for
            // crossfades without waiting for the background decoder actor.
            if let cached { 
                if crossfade, let current = cover {
                    previousCover = current
                    isCrossfading = true
                    // Fade out the previous cover
                    try? await Task.sleep(for: .milliseconds(50))
                }
                cover = cached; loadedRequest = request; isCrossfading = false; return 
            }
            // Start a short dwell to avoid decode storm during fast scrolling.
            // Reduced from 120ms to 50ms for faster perceived loading.
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
            guard !Task.isCancelled else { return }
            let result = await CoverCache.shared.image(for: request)
            guard !Task.isCancelled else { return }
            if crossfade, let current = cover {
                previousCover = current
                isCrossfading = true
                // Allow crossfade to begin
                try? await Task.sleep(for: .milliseconds(30))
            }
            cover = result; loadedRequest = request; isCrossfading = false
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
