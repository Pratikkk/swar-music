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
    private let inFlightLock = NSLock()
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
    }
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
            return CoverBitmap(image)
        }
    }
}
