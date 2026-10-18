import CoreServices
import Foundation

/// FSEvents retains its context. Our stream state additionally keeps the callback
/// alive until teardown runs behind any in-flight callback on its serial queue.
final class FolderWatcher: @unchecked Sendable {
    private let state: StreamState

    private final class Callback: @unchecked Sendable {
        private let lock = NSLock()
        private var action: (@Sendable () -> Void)?
        init(_ action: @escaping @Sendable () -> Void) { self.action = action }

        func fire() {
            // A running action owns its capture even if cancellation clears the box.
            let action = lock.withLock { self.action }
            action?()
        }

        func cancel() {
            let discarded = lock.withLock {
                let discarded = action
                action = nil
                return discarded
            }
            // Release client captures outside the lock: their deinit may reenter.
            withExtendedLifetime(discarded) { }
        }
    }

    /// Immutable bridge state; stream cleanup runs exactly once on queue.
    private final class StreamState: @unchecked Sendable {
        let stream: FSEventStreamRef
        let queue: DispatchQueue
        let callback: Callback
        init(stream: FSEventStreamRef, queue: DispatchQueue, callback: Callback) {
            self.stream = stream; self.queue = queue; self.callback = callback
        }
        func close() {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    init?(url: URL, action: @escaping @Sendable () -> Void) {
        let callback = Callback(action)
        let queue = DispatchQueue(label: "catto.swar.folder-events", qos: .utility)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Callback>.fromOpaque(info).retain()
                return info
            }, release: { info in
                if let info { Unmanaged<Callback>.fromOpaque(info).release() }
            }, copyDescription: nil)
        let created = withExtendedLifetime(callback) {
            FSEventStreamCreate(nil, { _, info, _, _, _, _ in
                guard let info else { return }
                let callback = Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue()
                callback.fire()
            }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
               FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        }
        guard let created else { return nil }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            callback.cancel()
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return nil
        }
        // Assign only after Start succeeds; a failed initializer has already
        // released the stream and must not also run the watcher's teardown.
        state = StreamState(stream: created, queue: queue, callback: callback)
    }

    deinit {
        let state = state
        state.callback.cancel()
        // Never block the caller or sync onto the callback queue (deinit can run
        // inside the action). Capturing state preserves the context until close.
        state.queue.async { state.close() }
    }
}
