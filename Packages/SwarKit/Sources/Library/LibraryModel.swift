import Foundation
import Observation

@MainActor @Observable
public final class LibraryModel {
    public private(set) var folders: [LibraryFolder] = []
    public private(set) var tracks: [LibraryTrack] = []
    public private(set) var playlists: [LibraryPlaylist] = []
    public var manualPlaylists: [LibraryPlaylist] { playlists.filter { !$0.isSmart } }
    public private(set) var favoriteTrackIDs: Set<String> = []
    public private(set) var hiddenTrackCount = 0
    public private(set) var trackActionsRevision = 0
    public private(set) var overviewRevision = 0
    /// Changes only when the visible track page changes. Views that derive
    /// their own grouping observe this instead of the 500-element array.
    public private(set) var tracksRevision = 0
    public private(set) var totalCount = 0
    public private(set) var unreadableCount = 0
    public private(set) var isRecovering = false
    private var relocatedIDs: [String: String] = [:]
    public private(set) var isScanning = false
    public private(set) var isReady = false
    public private(set) var folderErrors: [String: String] = [:]
    public private(set) var lastScanAt: Date?
    public private(set) var progress: LibraryProgress?
    public private(set) var errorMessage: String?
    public var search = ""
    public var searchScope: TrackSearchScope = .all
    public var recentFirst = false
    public var favoritesOnly = false
    public var sortOrder: TrackSortOrder = .album
    public var reverseSort = false
    public private(set) var pageLimit = 500
    /// Hard cap so "Load More" cannot grow the in-memory track array without bound.
    private let maxPageLimit = 5000
    public private(set) var artworkDirectory: URL?
    private var customArtworkDirectory: URL?
    private var repository: LibraryRepository?
    private var scopes: [String: FolderAccess] = [:]
    private var watchers: [String: FolderWatcher] = [:]
    private var pendingRescan = false
    private var refreshRevision = 0
    private var lastProgressReload = Date.distantPast
    private var watchTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var isShutDown = false
    private var started = false
    private let storageDirectory: URL?
    private let codecDirectory: URL?

    public init(storageDirectory: URL? = nil, codecDirectory: URL? = nil) {
        self.storageDirectory = storageDirectory
        self.codecDirectory = codecDirectory
    }

    public func start() async {
        guard !started, !isShutDown else { return }
        started = true
        do {
            let support = try storageDirectory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Swar", isDirectory: true)
            let cache = try storageDirectory?.appendingPathComponent("Artwork") ?? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Swar/Artwork", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            artworkDirectory = cache
            let custom = support.appendingPathComponent("CustomArtwork", isDirectory: true)
            customArtworkDirectory = custom
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: cache.path) {
                    for url in try FileManager.default.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.isRegularFileKey], options: .skipsHiddenFiles)
                        where url.lastPathComponent.hasPrefix("custom-") && url.pathExtension == "png" {
                        let target = custom.appendingPathComponent(url.lastPathComponent)
                        if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                           !FileManager.default.fileExists(atPath: target.path) {
                            // Keep the old copy for saved queues referring to the cache URL.
                            try Data(contentsOf: url, options: .mappedIfSafe).write(to: target, options: .atomic)
                        }
                    }
                }
            }.value
            repository = try await Task.detached(priority: .utility) {
                try LibraryRepository(path: support.appendingPathComponent("Library.sqlite").path)
            }.value
            guard !isShutDown else { return }
            try await restoreFolders()
            await reload()
            await reloadPlaylists()
            await rescan()
            isReady = true
        } catch { errorMessage = error.localizedDescription }
    }

    public func addFolder(_ url: URL) async {
        guard !isRecovering, let repository else { errorMessage = "The library is busy or not ready."; return }
        do {
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            guard !folders.contains(where: {
                let path = scopes[$0.id]?.url.resolvingSymlinksInPath().standardizedFileURL.path ?? $0.path
                return Self.overlaps(path, canonical.path)
            }) else {
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
        guard !isScanning, !isRecovering, let repository else { return }
        do {
            try await repository.removeFolder(folder.id)
            watchers[folder.id] = nil; scopes[folder.id] = nil
            folderErrors[folder.id] = nil
            folders = try await repository.folders()
            await reload()
            await reloadPlaylists()
            trackActionsRevision += 1
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    public func rescan() async {
        guard !isShutDown, !Task.isCancelled else { return }
        guard !isScanning, !isRecovering else { pendingRescan = true; return }
        guard let repository, let artworkDirectory else { return }
        isScanning = true
        let task = Task { await scanFolders(repository: repository, artworkDirectory: artworkDirectory) }
        scanTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        scanTask = nil
        isScanning = false
        progress = nil
    }

    private func scanFolders(repository: LibraryRepository, artworkDirectory: URL) async {
        repeat {
            pendingRescan = false
            for folder in folders {
                guard !isShutDown, !Task.isCancelled else { return }
                guard let scope = scopes[folder.id] else { continue }
                defer { withExtendedLifetime(scope) {} }
                do {
                    let scanner = LibraryScanner(repository: repository, artworkDirectory: artworkDirectory, codecDirectory: codecDirectory,
                                                 customArtworkDirectory: customArtworkDirectory)
                    _ = try await scanner.scan(folder: folder, root: scope.url) { [weak self] update in
                        await self?.updateProgress(update)
                    }
                    guard !isShutDown, !Task.isCancelled else { return }
                    folderErrors[folder.id] = nil
                } catch is CancellationError {
                    return
                } catch {
                    folderErrors[folder.id] = error.localizedDescription
                    errorMessage = "\(URL(fileURLWithPath: folder.path).lastPathComponent): \(error.localizedDescription)"
                }
            }
            guard !isShutDown, !Task.isCancelled else { return }
            lastScanAt = Date()
            await reload()
        } while pendingRescan && !Task.isCancelled
    }

    public func reload(resetLimit: Bool = false) async {
        guard !isShutDown, !Task.isCancelled, let repository else { return }
        if resetLimit { pageLimit = 500 }
        refreshRevision += 1
        let revision = refreshRevision
        let query = search
        let scope = searchScope
        let onlyFavorites = favoritesOnly
        let recent = recentFirst
        let order = sortOrder
        let reversed = reverseSort
        do {
            let page = try await repository.page(search: query, limit: pageLimit, recentFirst: recent, favoritesOnly: onlyFavorites, sortOrder: order, reversed: reversed, searchScope: scope)
            let preferences = try await repository.trackPreferences()
            let relocated = try await repository.relocatedTrackIDs()
            guard !isShutDown, !Task.isCancelled, revision == refreshRevision, query == search, scope == searchScope, onlyFavorites == favoritesOnly, recent == recentFirst, order == sortOrder, reversed == reverseSort else { return }
            if relocatedIDs != relocated { relocatedIDs = relocated }
            let tracksChanged = tracks != page.tracks
            let overviewChanged = tracksChanged || totalCount != page.count || favoriteTrackIDs != preferences.favorites || hiddenTrackCount != preferences.hiddenCount
            if tracksChanged { tracks = page.tracks; tracksRevision &+= 1 }
            if totalCount != page.count { totalCount = page.count }
            if unreadableCount != page.unreadableCount { unreadableCount = page.unreadableCount }
            if favoriteTrackIDs != preferences.favorites { favoriteTrackIDs = preferences.favorites }
            if hiddenTrackCount != preferences.hiddenCount { hiddenTrackCount = preferences.hiddenCount }
            if overviewChanged { overviewRevision += 1 }
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
    }

    public func collectionPage(filter: CollectionFilter, search: String, scope: TrackSearchScope, limit: Int) async throws -> CollectionPage {
        guard let repository, !isShutDown else { throw LibraryFailure("The library is not ready.") }
        return try await repository.collectionPage(filter: filter, search: search, scope: scope, limit: limit)
    }

    public func importArtwork(_ url: URL) async throws -> String {
        guard let artworkDirectory = customArtworkDirectory else { throw LibraryFailure("The artwork library is not ready.") }
        let task = Task.detached(priority: .userInitiated) {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= 20 * 1024 * 1024 else {
                throw LibraryFailure("Choose an image smaller than 20 MB.")
            }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            try Task.checkCancellation()
            guard let key = try MediaInspector(codecDirectory: nil, artworkDirectory: artworkDirectory).cacheArtwork(data, maximumPixelSize: 1024) else {
                throw LibraryFailure("This image could not be opened. Try a JPEG, PNG, or HEIC image.")
            }
            return key
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    public func artworkSelection(ids: Set<String>, referenceID: String) async throws -> ArtworkSelection {
        guard let repository else { throw LibraryFailure("The library is not ready.") }
        return try await repository.artworkSelection(ids: ids, referenceID: referenceID)
    }

    public func setArtwork(ids: Set<String>, key: String?) async throws -> [LibraryArtworkChange] {
        guard let repository else { throw LibraryFailure("The library is not ready.") }
        if let key, artworkURL(key).map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
            throw LibraryFailure("The chosen image is no longer available. Choose it again.")
        }
        let tracks = try await repository.setArtwork(ids: ids, key: key)
        let changes = tracks.compactMap { track -> LibraryArtworkChange? in
            guard let url = try? location(for: track).file else { return nil }
            return LibraryArtworkChange(fileURL: url, artworkURL: artworkURL(track.artworkKey))
        }
        trackActionsRevision += 1; overviewRevision += 1
        await reload()
        return changes
    }

    public func updateMetadata(_ track: LibraryTrack, metadata: TrackMetadata) async throws {
        guard let repository else { throw LibraryFailure("The library is not ready.") }
        try await repository.updateMetadata(trackID: track.id, metadata: metadata)
        trackActionsRevision += 1; overviewRevision += 1
        await reload()
    }

    public func hasMetadataEdits(_ track: LibraryTrack) async -> Bool {
        (try? await repository?.hasMetadataEdits(trackID: track.id)) ?? false
    }

    public func resetMetadata(_ track: LibraryTrack) async throws {
        guard let repository else { throw LibraryFailure("The library is not ready.") }
        try await repository.resetMetadata(trackID: track.id)
        trackActionsRevision += 1; overviewRevision += 1
        await reload()
    }

    public func manageTracks(ids: Set<String>, restore: Bool) async throws {
        guard let repository, !isScanning, !isRecovering else { throw LibraryFailure("Wait for the library update to finish.") }
        if restore { try await repository.restoreTracks(ids: ids) }
        else { try await repository.removeTracksFromLibrary(ids: ids) }
        trackActionsRevision += 1; overviewRevision += 1
        await reload(); await reloadPlaylists()
    }

    /// Explicit, recoverable file removal from the duplicate-review UI.
    /// Never delete permanently or interpret matching tags as proof of identity.
    public func moveDuplicateToTrash(_ track: LibraryTrack) async throws {
        guard !isShutDown, !isScanning, !isRecovering, let repository else {
            throw LibraryFailure("Wait for the library to finish updating.")
        }
        guard let current = try await repository.visibleTrack(id: track.id),
              !current.isMissing, current.error == nil else {
            throw LibraryFailure("This song is no longer available. Refresh the review.")
        }
        let (file, root) = try location(for: current)
        let parent = file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard file.isFileURL, parent.pathComponents.starts(with: canonicalRoot.pathComponents),
              parent.pathComponents.count >= canonicalRoot.pathComponents.count,
              file.resolvingSymlinksInPath().standardizedFileURL.pathComponents.starts(with: canonicalRoot.pathComponents),
              FileManager.default.fileExists(atPath: file.path) else {
            throw LibraryFailure("The song file is missing or outside its authorised library folder.")
        }
        try await Task.detached(priority: .userInitiated) {
            var destination: NSURL?
            try FileManager.default.trashItem(at: file, resultingItemURL: &destination)
        }.value
        // Only update the library after macOS confirms that the file was trashed.
        // If the database update fails, the original remains recoverable in Trash.
        try await repository.removeTracksFromLibrary(ids: [current.id])
        trackActionsRevision += 1
        overviewRevision += 1
        await reload()
        await reloadPlaylists()
    }

    public func dismissError() { errorMessage = nil }

    public private(set) var listeningRevision = 0

    public func recordListen(at url: URL, date: Date = Date()) async {
        guard let repository, let track = await track(at: url) else { return }
        do {
            try await repository.recordListen(trackID: track.id, at: date)
            listeningRevision += 1
        } catch { errorMessage = "Couldn’t save listening history: " + error.localizedDescription }
    }

    public func listening(_ mode: ListeningMode, limit: Int = 100) async throws -> ListeningOverview {
        guard let repository, !isShutDown else { throw LibraryFailure("The library is not ready.") }
        return try await repository.listening(mode, limit: limit, search: search, scope: searchScope)
    }

    public func clearListeningHistory() async throws {
        guard let repository, !isShutDown else { throw LibraryFailure("The library is not ready.") }
        try await repository.clearListeningHistory()
        listeningRevision += 1
    }

    public func overview() async -> LibraryOverview? {
        guard let repository, !isShutDown else { return nil }
        do { return try await repository.overview() }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    public func albums(search: String, scope: TrackSearchScope, sort: AlbumSortOrder = .artist, reversed: Bool = false,
                       filter: AlbumBrowseFilter = .all, limit: Int = 200, offset: Int = 0) async throws -> [LibraryAlbumSummary] {
        guard let repository, !isShutDown else { return [] }
        return try await repository.albums(search: search, searchScope: scope, sort: sort, reversed: reversed,
                                           filter: filter, limit: limit, offset: offset)
    }

    public func albumPage(search: String, scope: TrackSearchScope, sort: AlbumSortOrder, reversed: Bool,
                          filter: AlbumBrowseFilter, limit: Int = 200, offset: Int = 0) async throws -> AlbumBrowsePage? {
        guard let repository, !isShutDown else { return nil }
        return try await repository.albumPage(search: search, searchScope: scope, sort: sort, reversed: reversed,
                                              filter: filter, limit: limit, offset: offset)
    }

    public func album(id: String) async throws -> LibraryAlbumSummary? {
        guard let repository, !isShutDown else { return nil }
        return try await repository.album(id: id)
    }

    public func tracks(in album: LibraryAlbumSummary) async -> [LibraryTrack] {
        guard let repository, !isShutDown else { return [] }
        do { return try await repository.albumTracks(artist: album.artist, title: album.title) }
        catch { errorMessage = error.localizedDescription; return [] }
    }

    public func isMonitoring(_ folder: LibraryFolder) -> Bool { watchers[folder.id] != nil }

    public func loadMore() async {
        guard pageLimit < maxPageLimit else { return }
        pageLimit = min(pageLimit + 500, maxPageLimit)
        await reload()
    }
    public func shutdown() {
        isShutDown = true
        watchTask?.cancel()
        watchTask = nil
        scanTask?.cancel()
        watchers.removeAll()
        scopes.removeAll()
    }

    public func toggleFavorite(_ track: LibraryTrack) async {
        guard let repository else { return }
        do {
            try await repository.setFavorite(trackID: track.id, favorite: !favoriteTrackIDs.contains(track.id))
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    public func removeTrackFromLibrary(_ track: LibraryTrack) async {
        guard let repository else { return }
        do {
            try await repository.removeTrackFromLibrary(trackID: track.id)
            trackActionsRevision += 1
            await reload()
        } catch { errorMessage = error.localizedDescription }
    }

    public func restoreRemovedTracks() async {
        guard let repository else { return }
        do {
            try await repository.restoreRemovedTracks()
            trackActionsRevision += 1
            await rescan()
        } catch { errorMessage = error.localizedDescription }
    }

    public func smartPlaylistPreview(_ definition: SmartPlaylistDefinition) async throws -> SmartPlaylistPreview {
        guard let repository, !isShutDown else { throw LibraryFailure("The library is not ready.") }
        return try await repository.previewSmartPlaylist(definition)
    }

    public func saveSmartPlaylist(id: String? = nil, name: String, definition: SmartPlaylistDefinition) async throws -> LibraryPlaylist {
        guard let repository, !isShutDown else { throw LibraryFailure("The library is not ready.") }
        let playlist = try await repository.saveSmartPlaylist(id: id, name: name, definition: definition)
        await reloadPlaylists()
        overviewRevision += 1
        return playlist
    }

    public func playlistItems(for id: String) async throws -> [PlaylistTrackItem] {
        guard let repository, !isShutDown else { throw LibraryFailure("The library is not ready.") }
        return try await repository.playlistTrackItems(playlistID: id)
    }

    public func reloadPlaylists() async {
        guard let repository else { return }
        do {
            playlists = try await repository.playlists()
        } catch { errorMessage = error.localizedDescription }
    }

    @discardableResult
    public func previewPlaylistImport(from url: URL) async throws -> PlaylistImportPreview {
        guard let repository, !isShutDown else { throw LibraryFailure("The library is not ready.") }
        let roots = scopes.mapValues(\.url)
        let task = Task.detached(priority: .utility) {
            let entries = try PlaylistFile.read(url)
            return (entries, try PlaylistFile.trackIDs(for: entries, roots: roots))
        }
        let (entries, ids) = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        try Task.checkCancellation()
        return try await repository.playlistImportPreview(name: url.deletingPathExtension().lastPathComponent, entries: entries, trackIDs: ids)
    }

    public func playlistExportEntries(for playlist: LibraryPlaylist) async throws -> [PlaylistExportEntry] {
        let items = try await playlistItems(for: playlist.id)
        let roots = scopes.mapValues(\.url)
        return try await Task.detached(priority: .utility) {
            try items.map { item in
                try Task.checkCancellation()
                guard let root = roots[item.track.folderID] else {
                    throw LibraryFailure("Reconnect this playlist’s music folders before exporting.")
                }
                return PlaylistExportEntry(url: root.appendingPathComponent(item.track.relativePath), title: item.track.title,
                    artist: item.track.artist, duration: item.track.duration)
            }
        }.value
    }

    public func queuePlaylistDraft(urls: [URL]) async throws -> QueuePlaylistDraft {
        guard let repository, !isShutDown else { throw LibraryFailure("The library is not ready.") }
        let roots = scopes.map { ($0.key, $0.value.url.standardizedFileURL.pathComponents) }
        let ids = urls.compactMap { url -> String? in
            guard url.isFileURL else { return nil }
            let path = url.standardizedFileURL.pathComponents
            for (folderID, root) in roots where path.count > root.count && path.starts(with: root) {
                return folderID + ":" + path.dropFirst(root.count).joined(separator: "/")
            }
            return nil
        }
        return try await repository.queuePlaylistDraft(trackIDs: ids, sourceCount: urls.count)
    }

    public func saveQueuePlaylist(name: String, draft: QueuePlaylistDraft) async throws -> LibraryPlaylist {
        guard let repository, !isShutDown else { throw LibraryFailure("The library is not ready.") }
        let playlist = try await repository.createQueuePlaylist(name: name, draft: draft)
        await reloadPlaylists()
        overviewRevision += 1
        return playlist
    }

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
    public func artworkURL(_ key: String?) -> URL? {
        key.flatMap { key in
            let directory = key.hasPrefix("custom-") ? customArtworkDirectory ?? artworkDirectory : artworkDirectory
            return directory?.appendingPathComponent(key)
        }
    }

    /// Resolve a playing file against connected library roots, not the visible page.
    public func track(at url: URL) async -> LibraryTrack? {
        guard let id = trackID(at: url), let repository else { return nil }
        do { return try await repository.visibleTrack(id: id) }
        catch { return nil }
    }

    /// Resolve a playing file to its library identity without a database round-trip.
    /// Views use this once per body instead of standardizing a URL per row.
    public func trackID(at url: URL?) -> String? {
        guard let url, url.isFileURL else { return nil }
        let components = url.standardizedFileURL.pathComponents
        for (folderID, access) in scopes {
            let root = access.url.standardizedFileURL.pathComponents
            guard components.count > root.count, components.starts(with: root) else { continue }
            let locationID = folderID + ":" + components.dropFirst(root.count).joined(separator: "/")
            return relocatedIDs[locationID] ?? locationID
        }
        return nil
    }

    public func location(for track: LibraryTrack) throws -> (file: URL, root: URL) {
        guard let scope = scopes[track.folderID] else { throw LibraryFailure("The library folder is unavailable. Reconnect it in Manage Library.") }
        return (scope.url.appendingPathComponent(track.relativePath), scope.url)
    }

    /// Reauthorise a moved/offline root without replacing its database identity.
    public func reconnectFolder(_ folder: LibraryFolder, to url: URL) async throws {
        guard !isScanning, !isRecovering, !isShutDown, let repository,
              folders.contains(where: { $0.id == folder.id }) else { throw LibraryFailure("Wait for the library to finish updating.") }
        isRecovering = true
        defer { isRecovering = false }
        let access = FolderAccess(url)
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let isDirectory = try await Task.detached(priority: .utility) {
            try canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        }.value
        guard isDirectory else { throw LibraryFailure("Choose the music folder that contains the original album and song paths.") }
        guard !folders.contains(where: { $0.id != folder.id && Self.overlaps($0.path, canonical.path) }) else {
            throw LibraryFailure("This folder overlaps another folder in the library.")
        }
        let paths = try await repository.existingTracks(folderID: folder.id).keys.map { $0 }
        let matches = await Task.detached(priority: .utility) {
            paths.isEmpty || paths.contains { FileManager.default.fileExists(atPath: canonical.appendingPathComponent($0).path) }
        }.value
        guard matches else {
            throw LibraryFailure("No original song paths were found here. Choose the folder that contains the same album and song structure.")
        }
        guard !isShutDown, !Task.isCancelled else { throw CancellationError() }
        var updated = folder
        updated.path = canonical.path
        updated.bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        try await repository.saveFolder(updated)
        watchers[folder.id] = nil
        scopes[folder.id] = access
        folders = try await repository.folders()
        folderErrors[folder.id] = nil
        watch(folder: updated, url: url)
        errorMessage = nil
        isRecovering = false
        await rescan()
        await reloadPlaylists()
        trackActionsRevision += 1
    }

    /// The picker grants file access; the containing watched root grants durable access.
    public func reconnectTrack(_ track: LibraryTrack, to url: URL) async throws {
        guard !isScanning, !isRecovering, !isShutDown, let repository, let artworkDirectory else {
            throw LibraryFailure("Wait for the library to finish updating.")
        }
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        guard let folder = folders.first(where: { canonical.path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }),
              let access = scopes[folder.id] else {
            throw LibraryFailure("Add the file’s containing folder to Music Folders first, then locate the file again. For a moved music folder, use Reconnect Folder instead.")
        }
        isRecovering = true
        defer { isRecovering = false; withExtendedLifetime(access) {} }
        let inspector = MediaInspector(codecDirectory: codecDirectory, artworkDirectory: artworkDirectory)
        let replacement = try await Task.detached(priority: .utility) {
            let values = try canonical.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { throw LibraryFailure("Choose an audio file.") }
            let root = URL(fileURLWithPath: folder.path).pathComponents
            let relative = canonical.pathComponents.dropFirst(root.count).joined(separator: "/")
            let file = ScanFile(url: canonical, relativePath: relative, size: Int64(values.fileSize ?? 0),
                                modified: values.contentModificationDate ?? .distantPast, coverURL: nil, coverStamp: "")
            return inspector.inspect(file: file, folder: folder, prior: nil)
        }.value
        if let error = replacement.error { throw LibraryFailure("Could not reconnect this file. " + error) }
        guard !isShutDown, !Task.isCancelled else { throw CancellationError() }
        try await repository.reconnectTrack(id: track.id, replacement: replacement)
        errorMessage = nil
        await reload()
        await reloadPlaylists()
        trackActionsRevision += 1
        isRecovering = false
        await rescan()
    }

    private func updateProgress(_ update: LibraryProgress) async {
        guard !isShutDown, !Task.isCancelled else { return }
        progress = update
        // The scanner publishes after committed batches; the final reload also
        // marks missing files. Throttle intermediate refreshes so a scan does
        // not re-render and re-sort a large visible list four times a second.
        let now = Date()
        if update.changed > 0, now.timeIntervalSince(lastProgressReload) >= 0.75 {
            lastProgressReload = now
            await reload()
        }
    }

    private func restoreFolders() async throws {
        guard let repository else { return }
        folders = try await repository.folders()
        for var folder in folders {
            do {
                var stale = false
                let url = try URL(resolvingBookmarkData: folder.bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                let access = FolderAccess(url)
                let path = url.resolvingSymlinksInPath().standardizedFileURL.path
                if stale {
                    folder.bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
                }
                if stale || folder.path != path {
                    folder.path = path
                    try await repository.saveFolder(folder)
                }
                scopes[folder.id] = access
                watch(folder: folder, url: url)
            } catch {
                folderErrors[folder.id] = error.localizedDescription
                errorMessage = "Reconnect \(URL(fileURLWithPath: folder.path).lastPathComponent) in Manage Library. \(error.localizedDescription)"
            }
        }
        folders = try await repository.folders()
    }

    private func watch(folder: LibraryFolder, url: URL) {
        guard !isShutDown else { return }
        watchers[folder.id] = FolderWatcher(url: url) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isShutDown else { return }
                if self.isScanning {
                    self.pendingRescan = true
                    return
                }
                self.watchTask?.cancel()
                self.watchTask = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, !self.isShutDown else { return }
                    self.watchTask = nil
                    await self.rescan()
                }
            }
        }
    }

    private static func overlaps(_ first: String, _ second: String) -> Bool {
        let firstPrefix = first.hasSuffix("/") ? first : first + "/"
        let secondPrefix = second.hasSuffix("/") ? second : second + "/"
        return first == second || first.hasPrefix(secondPrefix) || second.hasPrefix(firstPrefix)
    }
}

struct LibraryFailure: LocalizedError { let message: String; init(_ message: String) { self.message = message }; var errorDescription: String? { message } }
private final class FolderAccess: Sendable {
    let url: URL
    let acquired: Bool
    init(_ url: URL) { self.url = url; acquired = url.startAccessingSecurityScopedResource() }
    deinit { if acquired { url.stopAccessingSecurityScopedResource() } }
}
