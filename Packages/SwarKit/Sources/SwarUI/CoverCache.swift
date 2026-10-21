import Foundation
import ImageIO

struct CoverRequest: Hashable, Sendable {
    let url: URL
    let pixels: Int
    /// Canonical cache key: the same artwork file always shares one entry,
    /// regardless of how its URL was obtained (bookmark, alias, or direct path).
    let key: String
    init(url: URL, pixels: Int) {
        let standardized = url.standardizedFileURL
        self.url = standardized
        self.pixels = min(768, max(32, pixels))
        self.key = "\(standardized.path)|\(self.pixels)"
    }
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
    /// In-flight decode tasks keyed by cache key. Concurrent requests for the
    /// same cover share a single decode instead of each starting a duplicate.
    private var inFlight: [NSString: Task<CoverBitmap?, Never>] = [:]
    private let inFlightLock = NSLock()
    /// Scale the memory budget with physical RAM: roughly 0.4% of memory,
    /// clamped between 16 MB (small Macs) and 64 MB (large Macs).
    private let costLimit: Int = {
        let physical = ProcessInfo.processInfo.physicalMemory
        let limit = Int(physical / 256)
        return min(max(limit, 16 * 1024 * 1024), 64 * 1024 * 1024)
    }()
    init() { images.countLimit = 256; images.totalCostLimit = costLimit }

    func cached(_ request: CoverRequest) -> CoverBitmap? {
        images.object(forKey: request.key as NSString)
    }
    fileprivate func store(_ bitmap: CoverBitmap, for request: CoverRequest) {
        images.setObject(bitmap, forKey: request.key as NSString, cost: bitmap.image.bytesPerRow * bitmap.image.height)
    }
    func image(for request: CoverRequest) async -> CoverBitmap? {
        guard !Task.isCancelled else { return nil }
        if let cached = cached(request) { return cached }
        // Coalesce: if a decode for this exact request is already in flight,
        // await it instead of starting a duplicate decode.
        if let existing = inFlightTask(for: request) {
            return await existing.value
        }
        let task: Task<CoverBitmap?, Never> = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return nil }
            defer { self.removeInFlight(for: request) }
            guard !Task.isCancelled else { return nil }
            return await self.decoder.image(for: request, cache: self)
        }
        setInFlight(task, for: request)
        return await task.value
    }

    private func inFlightTask(for request: CoverRequest) -> Task<CoverBitmap?, Never>? {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        return inFlight[request.key as NSString]
    }
    private func setInFlight(_ task: Task<CoverBitmap?, Never>, for request: CoverRequest) {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        inFlight[request.key as NSString] = task
    }
    private func removeInFlight(for request: CoverRequest) {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        inFlight[request.key as NSString] = nil
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
