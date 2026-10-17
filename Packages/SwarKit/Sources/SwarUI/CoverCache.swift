import Foundation
import ImageIO

struct CoverRequest: Hashable, Sendable {
    let url: URL
    let pixels: Int
    init(url: URL, pixels: Int) {
        self.url = url
        self.pixels = min(768, max(32, pixels))
    }
    var key: NSString { "\(url.absoluteString)|\(pixels)" as NSString }
}

final class CoverBitmap: NSObject, @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// NSCache supports concurrent access; bitmaps are immutable. Cache hits require
/// no actor hop, file access or view-state update during cell reuse.
final class CoverCache: @unchecked Sendable {
    static let shared = CoverCache()
    private let images = NSCache<NSString, CoverBitmap>()
    private let decoder = CoverDecoder()
    init() { images.countLimit = 256; images.totalCostLimit = 32 * 1024 * 1024 }

    func cached(_ request: CoverRequest) -> CoverBitmap? {
        images.object(forKey: request.key)
    }
    fileprivate func store(_ bitmap: CoverBitmap, for request: CoverRequest) {
        images.setObject(bitmap, forKey: request.key, cost: bitmap.image.bytesPerRow * bitmap.image.height)
    }
    func image(for request: CoverRequest) async -> CoverBitmap? {
        guard !Task.isCancelled else { return nil }
        if let cached = cached(request) { return cached }
        let work = Task.detached(priority: .utility) { await self.decoder.image(for: request, cache: self) }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }
}

/// Serial decoding bounds CPU/temporary image memory and rechecks the cache to
/// coalesce queued requests. Cancelled offscreen requests skip expensive decoding.
private actor CoverDecoder {
    func image(for request: CoverRequest, cache: CoverCache) -> CoverBitmap? {
        guard !Task.isCancelled else { return nil }
        if let cached = cache.cached(request) { return cached }
        return autoreleasepool {
            guard request.url.isFileURL,
                  let source = CGImageSourceCreateWithURL(request.url as CFURL,
                      [kCGImageSourceShouldCache: false] as CFDictionary),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: request.pixels,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                  ] as CFDictionary) else { return nil }
            let bitmap = CoverBitmap(image)
            cache.store(bitmap, for: request)
            return bitmap
        }
    }
}
