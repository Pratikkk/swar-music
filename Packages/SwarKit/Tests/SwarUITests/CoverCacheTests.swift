import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SwarUI

private actor SuspendedCoverDecode {
    private var released = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        released = true
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
    }
}

struct CoverCacheTests {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let context = try #require(CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func smallCellsDecodeSmallerImagesAndRetainIndependentLargeCovers() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let source = try Data(contentsOf: url)
        let cache = CoverCache()
        let small = CoverRequest(url: url, pixels: 128)
        let large = CoverRequest(url: url, pixels: 384)
        let thumbnail = try #require(await cache.image(for: small))
        let cover = try #require(await cache.image(for: large))
        #expect(thumbnail.image.width == 128)
        #expect(cover.image.width == 384)
        #expect(thumbnail.image.bytesPerRow * thumbnail.image.height < cover.image.bytesPerRow * cover.image.height / 4)
        #expect(cache.cached(small) === thumbnail)
        #expect(cache.cached(large) === cover)
        #expect(try Data(contentsOf: url) == source)
        // A warm lookup must not touch the file or need an asynchronous decode.
        try FileManager.default.removeItem(at: url)
        #expect(cache.cached(small) === thumbnail)
        #expect(await cache.image(for: small) === thumbnail)
    }

    @Test func simultaneousVisibleCellsShareTheSameDecodedBitmap() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = CoverCache()
        let request = CoverRequest(url: url, pixels: 128)
        let identities = await withTaskGroup(of: ObjectIdentifier?.self) { group in
            for _ in 0..<40 {
                group.addTask { await cache.image(for: request).map(ObjectIdentifier.init) }
            }
            var results: [ObjectIdentifier?] = []
            for await value in group { results.append(value) }
            return results
        }
        #expect(identities.count == 40)
        #expect(identities.allSatisfy { $0 != nil })
        #expect(Set(identities).count == 1)
    }

    @Test func cancelledOffscreenLoadsDoNotPopulateCache() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = CoverCache()
        let request = CoverRequest(url: url, pixels: 128)
        let work = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.image(for: request)
        }
        #expect(await work.value == nil)
        #expect(cache.cached(request) == nil)
        #expect(await cache.image(for: request) != nil)
    }

    private func waitsForCallers(_ count: Int, cache: CoverCache) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while cache.pendingRequestCount != count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        return cache.pendingRequestCount == count
    }

    @Test func cancellingOneCellKeepsSharedArtworkForAnother() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let request = CoverRequest(url: url, pixels: 128)
        let bitmap = try #require(await CoverCache().image(for: request))
        let gate = SuspendedCoverDecode()
        let cache = CoverCache(decode: { _ in await gate.wait(); return bitmap })
        let first = Task { await cache.image(for: request) }
        let second = Task { await cache.image(for: request) }
        let joined = try await waitsForCallers(2, cache: cache)
        #expect(joined)
        first.cancel()
        #expect(await first.value == nil)
        #expect(cache.pendingRequestCount == 1)
        await gate.release()
        #expect(await second.value === bitmap)
        #expect(cache.cached(request) === bitmap)
        #expect(cache.pendingRequestCount == 0)
    }

    @Test func lastCancellationReleasesCallerAndNewRequestSurvivesOldCompletion() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let request = CoverRequest(url: url, pixels: 128)
        let bitmap = try #require(await CoverCache().image(for: request))
        let gate = SuspendedCoverDecode()
        let cache = CoverCache(decode: { _ in await gate.wait(); return bitmap })
        let offscreen = Task { await cache.image(for: request) }
        let joined = try await waitsForCallers(1, cache: cache)
        #expect(joined)
        offscreen.cancel()
        // Cancellation must finish without waiting for a blocked decoder.
        #expect(await offscreen.value == nil)
        #expect(cache.pendingRequestCount == 0)
        #expect(cache.cached(request) == nil)
        let visible = Task { await cache.image(for: request) }
        let rejoined = try await waitsForCallers(1, cache: cache)
        #expect(rejoined)
        await gate.release()
        #expect(await visible.value === bitmap)
        #expect(cache.cached(request) === bitmap)
        #expect(cache.pendingRequestCount == 0)
    }

    @Test func invalidImagesAndRemoteURLsDoNotEnterTheCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not an image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = CoverCache()
        let request = CoverRequest(url: url, pixels: 128)
        #expect(await cache.image(for: request) == nil)
        #expect(cache.cached(request) == nil)
        #expect(await cache.image(for: CoverRequest(url: URL(string: "https://example.com/cover.png")!, pixels: 128)) == nil)
    }

    /// Writes `count` unique 64 px covers and returns their requests plus a
    /// cleanup closure. Kept small because this asserts cache *bounds*, not LRU
    /// order: NSCache documents no deterministic eviction policy, so naming
    /// specific victims would be flaky.
    private func uniqueCoverRequests(_ count: Int) throws -> ([CoverRequest], () -> Void) {
        var urls: [URL] = []
        var requests: [CoverRequest] = []
        for index in 0..<count {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("cover-\(UUID().uuidString).png")
            let context = try #require(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: Double(index % 16) / 16, green: 0.5, blue: 0.8, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            let image = try #require(context.makeImage())
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            urls.append(url)
            requests.append(CoverRequest(url: url, pixels: 64))
        }
        return (requests, { for url in urls { try? FileManager.default.removeItem(at: url) } })
    }

    @Test func cacheBoundsItsEntryCountAndKeepsServingAfterEviction() async throws {
        let cache = CoverCache()
        let (requests, cleanup) = try uniqueCoverRequests(400)
        defer { cleanup() }

        for request in requests {
            _ = try #require(await cache.image(for: request))
        }

        // The cache advertises a 256-entry limit; a generous upper bound avoids
        // depending on exactly when NSCache chooses to evict.
        let retained = requests.count { cache.cached($0) != nil }
        #expect(retained <= 256, "cache retained \(retained) entries, above its 256-entry cap")
        #expect(retained > 0, "cache should still hold recent entries")

        // Every request must still return a valid bitmap, whether it was served
        // from memory or re-decoded after eviction.
        let oldestAgain = try #require(await cache.image(for: requests[0]))
        #expect(oldestAgain.image.width == 64)
        let newest = try #require(await cache.image(for: requests[399]))
        #expect(newest.image.width == 64)
    }

    @Test func rapidCancelStormDoesNotLeaveOrphanTasks() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let request = CoverRequest(url: url, pixels: 128)
        let gate = SuspendedCoverDecode()
        let cache = CoverCache(decode: { _ in await gate.wait(); return nil })

        // 50 callers enter the same flight, then 49 are cancelled while the
        // single shared decode is still suspended.
        var tasks: [Task<CoverBitmap?, Never>] = []
        for _ in 0..<49 {
            tasks.append(Task { await cache.image(for: request) })
        }
        let survivor = Task { await cache.image(for: request) }
        #expect(try await waitsForCallers(50, cache: cache), "all 50 callers should join the one flight")
        for task in tasks { task.cancel() }
        #expect(try await waitsForCallers(1, cache: cache), "cancelled waiters should leave the flight")

        await gate.release()
        let results = await tasks.asyncMap { await $0.value }
        #expect(results.allSatisfy { $0 == nil }, "cancelled callers must not receive a bitmap")
        _ = await survivor.value
        #expect(try await waitsForCallers(0, cache: cache), "no orphan waiters should remain")
    }

    @Test func sameKeyConcurrentRequestsShareSingleDecodeUnderSuspension() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let bitmap = try #require(await CoverCache().image(for: CoverRequest(url: url, pixels: 128)))
        let gate = SuspendedCoverDecode()
        let cache = CoverCache(decode: { _ in await gate.wait(); return bitmap })

        // 15 concurrent requests for the same key while decode is suspended.
        // The group is *started*, not awaited, so the gate can be observed and
        // released; awaiting it here would deadlock on the held continuation.
        let group = Task {
            await withTaskGroup(of: ObjectIdentifier?.self) { group in
                for _ in 0..<15 {
                    group.addTask { await cache.image(for: CoverRequest(url: url, pixels: 128)).map(ObjectIdentifier.init) }
                }
                var results: [ObjectIdentifier?] = []
                for await value in group { results.append(value) }
                return results
            }
        }
        #expect(try await waitsForCallers(15, cache: cache), "all 15 callers should join one decode")
        await gate.release()
        let identities = await group.value
        #expect(identities.count == 15)
        #expect(identities.allSatisfy { $0 != nil })
        #expect(Set(identities).count == 1, "All 15 callers should share the same decode")
        #expect(cache.pendingRequestCount == 0)
        #expect(cache.cached(CoverRequest(url: url, pixels: 128)) === bitmap)
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async -> T) async -> [T] {
        var results: [T] = []
        results.reserveCapacity(count)
        for element in self { results.append(await transform(element)) }
        return results
    }
}
