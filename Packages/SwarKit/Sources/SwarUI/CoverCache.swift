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
    let pixels: Int
    init(_ image: CGImage, pixels: Int) { self.image = image; self.pixels = pixels }
}

/// NSCache supports concurrent access; bitmaps are immutable. Cache hits require
/// no actor hop, file access or view-state update during cell reuse.
final class CoverCache: @unchecked Sendable {
    static let shared = CoverCache()
    private let images = NSCache<NSString, CoverBitmap>()
    // Track keys separately since NSCache doesn't expose allKeys
    private var keys = Set<String>()
    private let decode: @Sendable (CoverRequest) async -> CoverBitmap?
    private final class Waiter: @unchecked Sendable {
        var cancelled = false
        var continuation: CheckedContinuation<CoverBitmap?, Never>?
    }
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: Waiter]
    }
    private var inFlight: [String: Flight] = [:]
    // Registration, completion and cancellation share one lock so a cancelled
    // cell cannot leave an orphan task or remove a newer request for the same key.
    private let inFlightLock = NSRecursiveLock()
    /// Scale the memory budget with physical RAM: roughly 0.4% of memory,
    /// clamped between 16 MB (small Macs) and 64 MB (large Macs).
    private let costLimit: Int = {
        let physical = ProcessInfo.processInfo.physicalMemory
        let limit = Int(physical / 256)
        return min(max(limit, 16 * 1024 * 1024), 64 * 1024 * 1024)
    }()
    init(decode: (@Sendable (CoverRequest) async -> CoverBitmap?)? = nil) {
        let decoder = CoverDecoder()
        self.decode = decode ?? { await decoder.image(for: $0) }
        images.countLimit = 256; images.totalCostLimit = costLimit
    }

    /// Number of active callers, useful for checking request lifecycle diagnostics.
    var pendingRequestCount: Int {
        inFlightLock.withLock { inFlight.values.reduce(0) { $0 + $1.waiters.count } }
    }

    func cached(_ request: CoverRequest) -> CoverBitmap? {
        images.object(forKey: request.key as NSString)
    }
    fileprivate func store(_ bitmap: CoverBitmap, for request: CoverRequest) {
        images.setObject(bitmap, forKey: request.key as NSString, cost: bitmap.image.bytesPerRow * bitmap.image.height)
       inFlightLock.withLock { _ = keys.insert(request.key) }
    }
    
    /// Returns a bitmap scaled to the requested pixel size. If the cached bitmap
    /// is larger than requested, it is downscaled on-demand. If smaller, the
    /// cached version is returned as-is (upscaling is avoided for quality).
    func image(for request: CoverRequest) async -> CoverBitmap? {
        guard !Task.isCancelled else { return nil }
        if let cached = cached(request) { return cached }
        let waiter = Waiter(), waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                register(waiter, id: waiterID, request: request, continuation: continuation)
            }
        } onCancel: {
            self.cancel(waiter, id: waiterID, key: request.key)
        }
    }

    /// Prefetches adjacent album artwork for smoother scrolling. Given a list of
    /// URLs and a center index, prefetches artwork for nearby indices.
    /// - Parameters:
    ///   - urls: All artwork URLs in the current view
    ///   - centerIndex: Currently visible center index
    ///   - window: Number of items on each side to prefetch (default 2)
    ///   - pixels: Target pixel size for thumbnails
    func prefetchAdjacent(urls: [URL], centerIndex: Int, window: Int = 2, pixels: Int = 384) async {
        guard !urls.isEmpty else { return }
        let start = max(0, centerIndex - window)
        let end = min(urls.count - 1, centerIndex + window)
        await withTaskGroup(of: Void.self) { group in
            for i in start...end {
                guard i != centerIndex else { continue }
                group.addTask { [weak self] in
                    guard let self else { return }
                    let request = CoverRequest(url: urls[i], pixels: pixels)
                    _ = await self.image(for: request)
                }
            }
        }
    }
    
    /// Returns a bitmap scaled to exactly the requested pixel size, downscaling
    /// from the largest cached version if needed. Returns nil if no cached
    /// version exists at the requested size or larger.
    func imageScaledTo(request: CoverRequest) async -> CoverBitmap? {
        guard !Task.isCancelled else { return nil }
        // First try exact match
        if let cached = cached(request) { return cached }
        
        // Try to find a larger cached version we can downscale from
        var best: CoverBitmap?
        var bestPixels = Int.max
        let urlPrefix = "\(request.url.standardizedFileURL.path)|"
        let snapshotKeys = inFlightLock.withLock { Array(keys) }
        var evictedKeys: [String] = []
        for key in snapshotKeys {
            guard let cached = images.object(forKey: key as NSString) else { evictedKeys.append(key); continue }
            guard key.hasPrefix(urlPrefix) else { continue }
            // Parse the pixel size from the key (format: "path|pixels")
            guard let pipeIndex = key.lastIndex(of: "|"),
                  let cachedPixels = Int(key[key.index(after: pipeIndex)...]),
                  cachedPixels >= request.pixels else { continue }
            if cachedPixels < bestPixels {
                best = cached
                bestPixels = cachedPixels
            }
        }
        
            if !evictedKeys.isEmpty { inFlightLock.withLock { evictedKeys.forEach { if images.object(forKey: $0 as NSString) == nil { keys.remove($0) } } } }
        guard let best else { return nil }
        
        // Downscale the larger bitmap to the requested size
        guard !Task.isCancelled else { return nil }
        return await downscale(bitmap: best, toPixels: request.pixels)
    }
    
    private func downscale(bitmap: CoverBitmap, toPixels: Int) async -> CoverBitmap? {
        guard !Task.isCancelled else { return nil }
        return await Task.detached(priority: .utility) {
            let scale = Double(toPixels) / Double(bitmap.pixels)
            let width = Int(Double(bitmap.image.width) * scale)
            let height = Int(Double(bitmap.image.height) * scale)
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: bitmap.image.bitsPerComponent,
                bytesPerRow: 0,
                space: bitmap.image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmap.image.bitmapInfo.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            context.draw(bitmap.image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { return nil }
            return CoverBitmap(scaled, pixels: toPixels)
        }.value
    }

    private func register(_ waiter: Waiter, id: UUID, request: CoverRequest,
                          continuation: CheckedContinuation<CoverBitmap?, Never>) {
        inFlightLock.lock()
        if waiter.cancelled {
            inFlightLock.unlock(); continuation.resume(returning: nil); return
        }
        if let bitmap = cached(request) {
            inFlightLock.unlock(); continuation.resume(returning: bitmap); return
        }
        waiter.continuation = continuation
        if var flight = inFlight[request.key] {
            flight.waiters[id] = waiter
            inFlight[request.key] = flight
        } else {
            let flightID = UUID(), decode = self.decode
            let task = Task.detached(priority: .utility) { [weak self] in
                guard !Task.isCancelled else { return }
                let bitmap = await decode(request)
                self?.finish(request, id: flightID, bitmap: Task.isCancelled ? nil : bitmap)
            }
            inFlight[request.key] = Flight(id: flightID, task: task, waiters: [id: waiter])
        }
        inFlightLock.unlock()
    }

    private func cancel(_ waiter: Waiter, id: UUID, key: String) {
        inFlightLock.lock()
        waiter.cancelled = true
        let continuation = waiter.continuation
        waiter.continuation = nil
        var task: Task<Void, Never>?
        if var flight = inFlight[key], flight.waiters.removeValue(forKey: id) != nil {
            if flight.waiters.isEmpty {
                inFlight[key] = nil
                task = flight.task
            } else { inFlight[key] = flight }
        }
        inFlightLock.unlock()
        task?.cancel()
        continuation?.resume(returning: nil)
    }

    private func finish(_ request: CoverRequest, id: UUID, bitmap: CoverBitmap?) {
        inFlightLock.lock()
        guard let flight = inFlight[request.key], flight.id == id else {
            inFlightLock.unlock(); return
        }
        inFlight[request.key] = nil
        if let bitmap { store(bitmap, for: request) }
        let continuations = flight.waiters.values.compactMap { waiter in
            let continuation = waiter.continuation
            waiter.continuation = nil
            return continuation
        }
        inFlightLock.unlock()
        for continuation in continuations { continuation.resume(returning: bitmap) }
    }
}

/// Serial decoding bounds CPU/temporary image memory and rechecks the cache to
/// coalesce queued requests. Cancelled offscreen requests skip expensive decoding.
private actor CoverDecoder {
    func image(for request: CoverRequest) -> CoverBitmap? {
        guard !Task.isCancelled else { return nil }
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
            guard !Task.isCancelled else { return nil }
            return CoverBitmap(image, pixels: request.pixels)
        }
    }
}
