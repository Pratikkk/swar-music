import Foundation
import Observation

@MainActor @Observable
public final class LibraryModel {
    public private(set) var folders: [LibraryFolder] = []
    public private(set) var tracks: [LibraryTrack] = []
    public private(set) var playlists: [LibraryPlaylist] = []
    public private(set) var totalCount = 0
    public private(set) var unreadableCount = 0
    public private(set) var isScanning = false
    public private(set) var isReady = false
    public private(set) var folderErrors: [String: String] = [:]
    public private(set) var lastScanAt: Date?
    public private(set) var progress: LibraryProgress?
    public private(set) var errorMessage: String?
    public var search = ""
    public var recentFirst = false
    public private(set) var pageLimit = 500
    public private(set) var artworkDirectory: URL?
    private var repository: LibraryRepository?
    private var scopes: [String: FolderAccess] = [:]
    private var watchers: [String: FolderWatcher] = [:]
    private var pendingRescan = false
    private var refreshRevision = 0
    private var watchTask: Task<Void, Never>?
    private var started = false
    private let storageDirectory: URL?
    private let codecDirectory: URL?

    public init(storageDirectory: URL? = nil, codecDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory
        self.codecDirectory = codecDirectory
    }

    public func start() async {
        guard !started else { return }
        started = true
        do {
            let support = try storageDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Swar", isDirectory: true)
            let cache = try storageDirectory?.appendingPathComponent("Artwork") ?? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Swar/Artwork", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            artworkDirectory = cache
            repository = try await Task.detached(priority: .utility) {
                try LibraryRepository(path: support.appendingPathComponent("Library.sqlite").path)
            }.value
            try await restoreFolders()
            await reload()
            await reloadPlaylists()
            await rescan()
            isReady = true
        } catch { errorMessage = error.localizedDescription }
    }

    public func addFolder(_ url: URL) async {
        guard let repository else { errorMessage = "The library database is not ready."; return }
        do {
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            guard !folders.contains(where: { Self.overlaps($0.path, canonical.path) }) else {
                throw LibraryFailure("This folder overlaps a folder already in your library.")
            }
            let access = FolderAccess(url)
            let bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            let folder = LibraryFolder(path: canonical.path, bookmark: bookmark)
            try await repository.saveFolder(folder)
            scopes[folder.id] = access
            folders = try await repository.folders()
            watch(folder: folder, url: url)
            errorMessage = nil
            await rescan()
        } catch { errorMessage = error.localizedDescription }
    }

    public func removeFolder(_ folder: LibraryFolder) async {
        guard !isScanning, let repository else { return }
        do {
            try await repository.removeFolder(folder.id)
            watchers[folder.id] = nil; scopes[folder.id] = nil
            folderErrors[folder.id] = nil
            folders = try await repository.folders()
            await reload()
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    public func rescan() async {
        guard !isScanning else { pendingRescan = true; return }
        guard let repository, let artworkDirectory else { return }
        isScanning = true
        defer { isScanning = false; progress = nil }
        repeat {
            pendingRescan = false
            for folder in folders {
                guard let scope = scopes[folder.id] else { continue }
                do {
                    let scanner = LibraryScanner(repository: repository, artworkDirectory: artworkDirectory, codecDirectory: codecDirectory)
                    _ = try await scanner.scan(folder: folder, root: scope.url) { [weak self] update in
                        await self?.updateProgress(update)
                    }
                    folderErrors[folder.id] = nil
                } catch {
                    folderErrors[folder.id] = error.localizedDescription
                    errorMessage = "\(URL(fileURLWithPath: folder.path).lastPathComponent): \(error.localizedDescription)"
                }
            }
            lastScanAt = Date()
            await reload()
        } while pendingRescan && !Task.isCancelled
    }

    public func reload(resetLimit: Bool = false) async {
        guard let repository else { return }
        if resetLimit { pageLimit = 500 }
        refreshRevision += 1
        let revision = refreshRevision
        let query = search
        do {
            let page = try await repository.page(search: query, limit: pageLimit, recentFirst: recentFirst)
            guard revision == refreshRevision, query == search else { return }
            tracks = page.tracks; totalCount = page.count
            unreadableCount = page.unreadableCount
        } catch { errorMessage = error.localizedDescription }
    }

    public func isMonitoring(_ folder: LibraryFolder) -> Bool { watchers[folder.id] != nil }

    public func loadMore() async { pageLimit += 500; await reload() }
    public func shutdown() {
        watchTask?.cancel()
        watchers.removeAll()
        scopes.removeAll()
    }

    public func reloadPlaylists() async {
        guard let repository else { return }
        do {
            playlists = try await repository.playlists()
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    public func createPlaylist(name: String) async -> LibraryPlaylist? {
        guard let repository else { return nil }
        do {
            let created = try await repository.createPlaylist(name: name)
            playlists = try await repository.playlists()
            return created
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    public func renamePlaylist(_ playlist: LibraryPlaylist, newName: String) async {
        guard let repository else { return }
        do {
            try await repository.renamePlaylist(id: playlist.id, name: newName)
            playlists = try await repository.playlists()
        } catch { errorMessage = error.localizedDescription }
    }

    public func deletePlaylist(_ playlist: LibraryPlaylist) async {
        guard let repository else { return }
        do {
            try await repository.deletePlaylist(id: playlist.id)
            playlists = try await repository.playlists()
        } catch { errorMessage = error.localizedDescription }
    }

    public func addTracks(_ tracks: [LibraryTrack], to playlist: LibraryPlaylist) async {
        guard let repository else { return }
        do {
            try await repository.addTracksToPlaylist(playlistID: playlist.id, trackIDs: tracks.map(\.id))
            playlists = try await repository.playlists()
        } catch { errorMessage = error.localizedDescription }
    }

    public func removeTrack(playlistTrackID: String, from playlist: LibraryPlaylist) async {
        guard let repository else { return }
        do {
            try await repository.removeTrackFromPlaylist(playlistTrackID: playlistTrackID)
            playlists = try await repository.playlists()
        } catch { errorMessage = error.localizedDescription }
    }

    public func moveTrack(from: Int, to: Int, in playlist: LibraryPlaylist) async {
        guard let repository else { return }
        do {
            try await repository.moveTrackInPlaylist(playlistID: playlist.id, from: from, to: to)
        } catch { errorMessage = error.localizedDescription }
    }

    public func playlistTracks(for playlistID: String) async -> [PlaylistTrackItem] {
        guard let repository else { return [] }
        do {
            return try await repository.playlistTrackItems(playlistID: playlistID)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }
    public func artworkURL(_ key: String?) -> URL? { key.flatMap { artworkDirectory?.appendingPathComponent($0) } }

    public func location(for track: LibraryTrack) throws -> (file: URL, root: URL) {
        guard let scope = scopes[track.folderID] else { throw LibraryFailure("The library folder is unavailable. Remove it and add it again to reconnect.") }
        return (scope.url.appendingPathComponent(track.relativePath), scope.url)
    }

    private func updateProgress(_ update: LibraryProgress) async {
        progress = update
        await reload()
    }

    private func restoreFolders() async throws {
        guard let repository else { return }
        folders = try await repository.folders()
        for var folder in folders {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: folder.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                let access = FolderAccess(url)
                if stale {
                    folder.bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                    try await repository.saveFolder(folder)
                }
                scopes[folder.id] = access
                watch(folder: folder, url: url)
            } catch {
                folderErrors[folder.id] = error.localizedDescription
                errorMessage = "Reconnect \(URL(fileURLWithPath: folder.path).lastPathComponent) by removing and adding the folder again. \(error.localizedDescription)"
            }
        }
        folders = try await repository.folders()
    }

    private func watch(folder: LibraryFolder, url: URL) {
        watchers[folder.id] = FolderWatcher(url: url) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.watchTask?.cancel()
                self.watchTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    await self?.rescan()
                }
            }
        }
    }

    private static func overlaps(_ first: String, _ second: String) -> Bool {
        first == second || first.hasPrefix(second + "/") || second.hasPrefix(first + "/")
    }
}

private struct LibraryFailure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
private final class FolderAccess: Sendable {
    let url: URL
    let acquired: Bool
    init(_ url: URL) { self.url = url; acquired = url.startAccessingSecurityScopedResource() }
    deinit { if acquired { url.stopAccessingSecurityScopedResource() } }
}
