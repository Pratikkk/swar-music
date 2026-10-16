import CoreServices
import Foundation

/// The stream owns its callback box until invalidation; no callback references UI state directly.
final class FolderWatcher: @unchecked Sendable {
    private let stream: FSEventStreamRef
    private final class Callback: @unchecked Sendable {
        let action: @Sendable () -> Void
        init(_ action: @escaping @Sendable () -> Void) { self.action = action }
    }

    init?(url: URL, action: @escaping @Sendable () -> Void) {
        let callback = Callback(action)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(callback).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<Callback>.fromOpaque(info).retain()
                return info
            }, release: { info in
                if let info { Unmanaged<Callback>.fromOpaque(info).release() }
            }, copyDescription: nil)
        guard let created = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<Callback>.fromOpaque(info).takeUnretainedValue().action()
        }, &context, [url.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1,
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) else { return nil }
        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue.global(qos: .utility))
        guard FSEventStreamStart(created) else { FSEventStreamInvalidate(created); FSEventStreamRelease(created); return nil }
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
