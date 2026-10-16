import Foundation

struct PlaybackSession: Sendable, Equatable {
    var entries: [QueueEntry]
    var currentID: UUID?
    var position: Double
    var duration: Double
    var shuffle: Bool
    var repeatMode: RepeatMode
    var originalOrder: [UUID]
}

/// File IO and bookmark work share one serial queue; termination can drain it synchronously.
public final class PlaybackSessionStore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "catto.swar.session", qos: .utility)
    private let storage: SessionStorage

    public init(url: URL) { storage = SessionStorage(url: url) }

    public static func applicationDefault() -> PlaybackSessionStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PlaybackSessionStore(url: support.appendingPathComponent("Swar/PlaybackSession.json"))
    }

    func load() async throws -> PlaybackSession? {
        try await perform { try $0.load() }
    }

    func save(_ session: PlaybackSession) async throws {
        try await perform { try $0.save(session) }
    }

    func saveSynchronously(_ session: PlaybackSession) throws {
        try queue.sync { try storage.save(session) }
    }

    private func perform<T: Sendable>(_ action: @escaping @Sendable (SessionStorage) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let storage = storage
            queue.async { continuation.resume(with: Result { try action(storage) }) }
        }
    }
}

private struct SavedRoot: Codable {
    let url: URL
    let bookmark: Data?
}

private struct SavedEntry: Codable {
    let entry: QueueEntry
    let rootKey: String
    let relativePath: String?
}

private struct SavedSession: Codable {
    var version = 1
    let roots: [String: SavedRoot]
    let entries: [SavedEntry]
    let currentID: UUID?
    let position: Double
    let duration: Double
    let shuffle: Bool
    let repeatMode: RepeatMode
    let originalOrder: [UUID]
}

/// Accessed exclusively on PlaybackSessionStore.queue.
private final class SessionStorage: @unchecked Sendable {
    let url: URL
    private var bookmarks: [String: Data] = [:]
    init(url: URL) { self.url = url }

    func save(_ session: PlaybackSession) throws {
        var roots: [String: SavedRoot] = [:]
        var entries: [SavedEntry] = []
        for entry in session.entries {
            guard entry.url.isFileURL, entry.accessRoot.isFileURL,
                  entry.artworkURL?.isFileURL ?? true else { throw SessionFailure("Only local files can be saved in the queue.") }
            let key = entry.accessRoot.absoluteString
            if roots[key] == nil {
                if bookmarks[key] == nil {
                    let acquired = entry.accessRoot.startAccessingSecurityScopedResource()
                    defer { if acquired { entry.accessRoot.stopAccessingSecurityScopedResource() } }
                    bookmarks[key] = try? entry.accessRoot.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                }
                roots[key] = SavedRoot(url: entry.accessRoot, bookmark: bookmarks[key])
            }
            let rootPath = entry.accessRoot.standardizedFileURL.path
            let filePath = entry.url.standardizedFileURL.path
            let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
            guard filePath == rootPath || filePath.hasPrefix(prefix) else { throw SessionFailure("A queued file is outside its access folder.") }
            entries.append(SavedEntry(entry: entry, rootKey: key,
                relativePath: filePath == rootPath ? nil : String(filePath.dropFirst(prefix.count))))
        }
        bookmarks = bookmarks.filter { roots[$0.key] != nil }
        let saved = SavedSession(roots: roots, entries: entries, currentID: session.currentID,
            position: session.position, duration: session.duration, shuffle: session.shuffle,
            repeatMode: session.repeatMode, originalOrder: session.originalOrder)
        let data = try JSONEncoder().encode(saved)
        guard data.count <= 64 * 1024 * 1024 else { throw SessionFailure("The listening session is too large to save.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func load() throws -> PlaybackSession? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw SessionFailure("The saved session is too large to read.") }
        let saved = try JSONDecoder().decode(SavedSession.self, from: Data(contentsOf: url))
        let ids = saved.entries.map { $0.entry.id }
        let idSet = Set(ids)
        guard saved.version == 1,
              saved.roots.values.allSatisfy({ $0.url.isFileURL }),
              saved.entries.allSatisfy({ $0.entry.url.isFileURL && ($0.entry.artworkURL?.isFileURL ?? true) }),
              idSet.count == ids.count, Set(saved.originalOrder).count == saved.originalOrder.count,
              Set(saved.originalOrder) == idSet,
              saved.currentID.map({ idSet.contains($0) }) ?? true,
              saved.position.isFinite, saved.duration.isFinite, saved.position >= 0, saved.duration >= 0 else {
            throw SessionFailure("The saved session has an unsupported or invalid format.")
        }
        var resolved: [String: URL] = [:]
        var refreshedBookmark = false
        for (key, root) in saved.roots {
            guard let bookmark = root.bookmark else { continue }
            var stale = false
            if let restored = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                resolved[key] = restored
                if !stale { bookmarks[restored.absoluteString] = bookmark }
                else {
                    let acquired = restored.startAccessingSecurityScopedResource()
                    defer { if acquired { restored.stopAccessingSecurityScopedResource() } }
                    if let fresh = try? restored.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil) {
                        bookmarks[restored.absoluteString] = fresh
                        refreshedBookmark = true
                    }
                }
            }
        }
        let entries = try saved.entries.map { savedEntry in
            guard let originalRoot = saved.roots[savedEntry.rootKey] else { throw SessionFailure("The saved session is missing a file-access bookmark.") }
            if let path = savedEntry.relativePath,
               path.isEmpty || path.hasPrefix("/") || path.split(separator: "/").contains("..") {
                throw SessionFailure("The saved session contains an invalid file path.")
            }
            let root = resolved[savedEntry.rootKey] ?? originalRoot.url
            let file = savedEntry.relativePath.map { root.appendingPathComponent($0) } ?? root
            var entry = QueueEntry(url: file, accessRoot: root, title: savedEntry.entry.title,
                subtitle: savedEntry.entry.subtitle, artworkURL: savedEntry.entry.artworkURL, id: savedEntry.entry.id)
            entry.error = resolved[savedEntry.rootKey] == nil
                ? "File access could not be restored. Add its folder again or reopen the file."
                : savedEntry.entry.error
            return entry
        }
        let session = PlaybackSession(entries: entries, currentID: saved.currentID,
            position: min(saved.position, saved.duration), duration: saved.duration,
            shuffle: saved.shuffle, repeatMode: saved.repeatMode, originalOrder: saved.originalOrder)
        if refreshedBookmark { try? save(session) }
        return session
    }
}

private struct SessionFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
