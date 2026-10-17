import SwiftUI
import ImageIO

/// Shared local thumbnail view; decoding and the bounded memory cache live off the UI actor.
struct CoverArt: View {
    let url: URL?
    var title = ""
    var cornerRadius: CGFloat = 6
    var crossfade = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cover: CoverBitmap?
    @State private var loadedURL: URL?

    private var tint: Color {
        let colors: [Color] = [.indigo, .teal, .purple, .blue, .orange, .pink]
        return colors[title.utf8.reduce(0) { ($0 + Int($1)) % colors.count }]
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [tint.opacity(0.2), tint.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)
                if let cover, crossfade || loadedURL == url {
                    Image(decorative: cover.image, scale: 1).resizable().scaledToFill()
                        .id(loadedURL).transition(.opacity)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: min(geometry.size.width, geometry.size.height) * 0.36, weight: .medium))
                        .foregroundStyle(tint.opacity(0.7))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay { RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.primary.opacity(0.07), lineWidth: 0.5) }
        }
        .animation(crossfade && !reduceMotion ? .easeInOut(duration: 0.18) : nil, value: loadedURL)
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
        .task(id: url) {
            guard let url else {
                cover = nil; loadedURL = nil
                return
            }
            guard loadedURL != url else { return }
            let result = await CoverCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            cover = result; loadedURL = url
        }
    }
}

private final class CoverBitmap: NSObject, @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

private actor CoverCache {
    static let shared = CoverCache()
    private let images = NSCache<NSURL, CoverBitmap>()
    init() { images.countLimit = 256; images.totalCostLimit = 32 * 1024 * 1024 }

    func image(for url: URL) -> CoverBitmap? {
        if let cached = images.object(forKey: url as NSURL) { return cached }
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 384,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let cover = CoverBitmap(image)
        images.setObject(cover, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        return cover
    }
}
