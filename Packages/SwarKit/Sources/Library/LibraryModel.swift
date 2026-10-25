import Foundation
import Observation
import CryptoKit

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
    public private(set) var exactDuplicateScanProgress: Double?
    public private(set) var exactDuplicateVerifiedGroups = 0
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
    private var loadingTrackPage = false
    public private(set) var artworkDirectory: URL?
    private var customArtworkDirectory: URL?
    private var repository: LibraryRepository?
    /// The UI can request a fresh user-selected grant for legacy read-only bookmarks.
    public var requestFolderWriteAccess: (@MainActor @Sendable (LibraryFolder) async throws -> URL?)?
    var trashItem: @Sendable (URL) throws -> URL = { file in
        var destination: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &destination)
        guard let destination else { throw LibraryFailure("Trash returned no recoverable destination.") }
        return destination as URL
    }
    private var scopes: [String: FolderAccess] = [:]
    private var watchers: [String: FolderWatcher] = [:]
    private var pendingRescan = false
    private var refreshRevision = 0
    private var lastProgressReload = Date.distantPast
    private var watchTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var trashOperationActive = false
    private var trashJournalDirectory: URL?
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
            let journal = support.appendingPathComponent("TrashJournal", isDirectory: true)
            try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: true)
            trashJournalDirectory = journal
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
            await reconcileTrashJournal()
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
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
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
        guard !isScanning, !isRecovering, !trashOperationActive else { pendingRescan = true; return }
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
            let page = try await repository.page(search: query, limit: pageLimit, recentFirst: recent, favoritesOnly: onlyFavorites, sortOrder: order, reversed: reversed, searchScope: scope, includeTagPayload: false)
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
        return try await repository.collectionPage(filter: filter, search: search, scope: scope, limit: limit, includeTagPayload: false)
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

    /// Library-only bulk metadata operation with an in-session undo snapshot.
    public private(set) var canUndoBulkMetadata = false
    private var bulkMetadataUndo: [(id: String, metadata: TrackMetadata)] = []

    public func bulkUpdateMetadata(_ tracks: [LibraryTrack], patch: BulkMetadataPatch) async throws {
        guard !isShutDown, !isScanning, !isRecovering, let repository else {
            throw LibraryFailure("The library is busy or unavailable.")
        }
        guard !tracks.isEmpty, !patch.isEmpty else {
            throw LibraryFailure("Select songs and at least one field to change.")
        }
        let ids = Set(tracks.map(\.id))
        guard ids.count == tracks.count else { throw LibraryFailure("Duplicate song selection.") }
        var before: [(id: String, metadata: TrackMetadata)] = []
        var after: [(id: String, metadata: TrackMetadata)] = []
        for track in tracks {
            guard let current = try await repository.visibleTrack(id: track.id),
                  !current.isMissing, current.error == nil else {
                throw LibraryFailure("A selected song changed or is unavailable. Refresh the list.")
            }
            before.append((id: current.id, metadata: TrackMetadata(track: current)))
            after.append((id: current.id, metadata: try patch.applying(to: current)))
        }
        try await repository.bulkUpdateMetadata(after)
        bulkMetadataUndo = before
        canUndoBulkMetadata = true
        trackActionsRevision += 1; overviewRevision += 1
        await reload()
    }

    public func undoLastBulkMetadataChange() async throws {
        guard let repository, canUndoBulkMetadata, !bulkMetadataUndo.isEmpty else {
            throw LibraryFailure("There is no bulk metadata edit to undo.")
        }
        try await repository.bulkUpdateMetadata(bulkMetadataUndo)
        bulkMetadataUndo = []
        canUndoBulkMetadata = false
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
        try beginTrashOperation()
        defer { finishTrashOperation() }
        try await moveDuplicateToTrashCore(track)
    }

    private func moveDuplicateToTrashCore(_ track: LibraryTrack) async throws {
        guard !isShutDown, !isScanning, !isRecovering, let repository else {
            throw LibraryFailure("Wait for the library to finish updating.")
        }
        guard let current = try await repository.visibleTrack(id: track.id) else {
            throw LibraryFailure("This song is no longer available. Refresh the review.")
        }
        guard current.folderID == track.folderID, current.relativePath == track.relativePath,
              current.fileSize == track.fileSize, current.modifiedAt == track.modifiedAt else {
            throw LibraryFailure("The song changed since it was selected. Review the list again.")
        }
        let file = try location(for: current).file
        let journalURL = try recordTrashIntent(trackID: current.id, source: file)
        let destination: URL
        do {
            do { destination = try await trashFile(current) }
            catch {
                guard Self.isTrashPermissionError(error), let requestFolderWriteAccess,
                      let folder = folders.first(where: { $0.id == current.folderID }) else { throw error }
                guard let url = try await requestFolderWriteAccess(folder) else { throw CancellationError() }
                try await authorizeWriteAccess(to: folder, url: url)
                destination = try await trashFile(current)
            }
        } catch {
            if FileManager.default.fileExists(atPath: file.path) { try? FileManager.default.removeItem(at: journalURL) }
            throw error
        }
        try recordTrashDestination(destination, in: journalURL, trackID: current.id, source: file)

        try await repository.removeTracksFromLibrary(ids: [current.id])
        try? FileManager.default.removeItem(at: journalURL)
        trackActionsRevision += 1
        overviewRevision += 1
        await reload()
        await reloadPlaylists()
    }

    static func isTrashPermissionError(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain &&
            [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(error.code) { return true }
        if error.domain == NSPOSIXErrorDomain && [13, 1].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return isTrashPermissionError(underlying)
        }
        return false
    }

    private func authorizeWriteAccess(to folder: LibraryFolder, url: URL) async throws {
        let access = FolderAccess(url)
        guard url.resolvingSymlinksInPath().standardizedFileURL ==
                URL(fileURLWithPath: folder.path).resolvingSymlinksInPath().standardizedFileURL,
              let repository else {
            throw LibraryFailure("Choose the same music folder to allow moving files to Trash.")
        }
        var updated = folder
        updated.bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        try await repository.saveFolder(updated)
        scopes[folder.id] = access
        folders = try await repository.folders()
    }

    private func trashFile(_ track: LibraryTrack) async throws -> URL {
        guard let access = scopes[track.folderID] else {
            throw LibraryFailure("Reconnect the music folder in Manage Library.")
        }
        let operation = trashItem
        return try await Task.detached(priority: .userInitiated) {
            try withExtendedLifetime(access) {
                let file = try Self.validatedTrashSource(relativePath: track.relativePath, root: access.url)
                return try operation(file)
            }
        }.value
    }

    /// Moves a reviewed selection to Trash sequentially, revalidating each
    /// candidate against the complete current set before every operation.
    /// Stops on the first error; previously trashed files remain in macOS Trash.
    public func moveSelectedDuplicatesToTrash(ids: Set<String>) async throws -> Int {
        try beginTrashOperation()
        defer { finishTrashOperation() }
        guard !ids.isEmpty, !isShutDown, !isScanning, !isRecovering,
              let repository else {
            throw LibraryFailure("Select at least one duplicate while the library is ready.")
        }
        // Read the duplicate list once (expensive query) and reuse it for all IDs.
        let review = try await repository.collectionPage(filter: .duplicates, limit: 100_000, includeTagPayload: false)
        guard review.count == review.tracks.count else {
            throw LibraryFailure("The duplicate list exceeds the review limit; batch cleanup is unavailable.")
        }
        var moved = 0
        for id in ids.sorted() {
            do {
                try Task.checkCancellation()
                guard let candidate = review.tracks.first(where: { $0.id == id }),
                      !candidate.isMissing, candidate.error == nil else {
                    throw LibraryFailure("A selected track is no longer a valid duplicate.")
                }
                let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let artist = candidate.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                let peers = review.tracks.filter {
                    $0.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(title) == .orderedSame
                    && $0.artist.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(artist) == .orderedSame
                    && $0.duration.isFinite && candidate.duration.isFinite
                    && $0.duration.rounded() == candidate.duration.rounded()
                }
                // Matching titles and durations are only hints, not deletion proof.
                // Batch cleanup requires an accessible, byte-identical retained file.
                let selectedFile = try location(for: candidate).file
                var verifiedRetainedCopy = false
                for peer in peers where !ids.contains(peer.id)
                    && !peer.isMissing && peer.error == nil
                    && peer.fileSize == candidate.fileSize {
                    guard let retained = try? location(for: peer) else { continue }
                    let root = retained.root.resolvingSymlinksInPath().standardizedFileURL
                    let resolved = retained.file.resolvingSymlinksInPath().standardizedFileURL
                    guard resolved.pathComponents.starts(with: root.pathComponents),
                          (try? retained.file.resourceValues(forKeys: [.isRegularFileKey])).flatMap(\.isRegularFile) == true,
                          FileManager.default.isReadableFile(atPath: retained.file.path) else { continue }
                    if try await Self.filesAreByteIdentical(selectedFile, retained.file) {
                        verifiedRetainedCopy = true
                        break
                    }
                }
                guard verifiedRetainedCopy else {
                    throw LibraryFailure("No readable, byte-identical retained copy exists. Review these possible duplicates manually.")
                }
                try await moveDuplicateToTrashCore(candidate)
                moved += 1
            } catch {
                throw LibraryFailure("Moved \(moved) of \(ids.count) selected files to Trash. Stopped: \(error.localizedDescription)")
            }
        }
        return moved
    }

    /// Scans a complete, unfiltered candidate page and selects all but one
    /// byte-identical file from each verified group. No files are modified.
    /// Hashes are recomputed so a stale cache cannot authorize deletion.
    public func selectVerifiedExactDuplicates(_ candidates: [LibraryTrack]) async throws -> Set<String> {
        guard !trashOperationActive, !isScanning, !isRecovering, !isShutDown else {
            throw LibraryFailure("The library is busy.")
        }
        guard exactDuplicateScanProgress == nil else {
            throw LibraryFailure("A verification scan is already running.")
        }
        exactDuplicateScanProgress = 0
        exactDuplicateVerifiedGroups = 0
        defer { exactDuplicateScanProgress = nil }
        struct Key: Hashable { let size: Int64; let hash: [UInt8] }
        var matches: [Key: [LibraryTrack]] = [:]
        let eligible = candidates.filter { !$0.isMissing && $0.error == nil && $0.fileSize > 0 }
        for (index, track) in eligible.enumerated() {
            try Task.checkCancellation()
            let (file, root) = try location(for: track)
            let canonical = file.resolvingSymlinksInPath().standardizedFileURL
            let safeRoot = root.resolvingSymlinksInPath().standardizedFileURL
            guard canonical.pathComponents.starts(with: safeRoot.pathComponents),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey])).flatMap(\.isRegularFile) == true else {
                throw LibraryFailure("File changed or is outside its authorised folder. Refresh and retry.")
            }
            let digest = try await Task.detached(priority: .utility) {
                try Self.fileSHA256(file)
            }.value
            matches[Key(size: track.fileSize, hash: digest), default: []].append(track)
            exactDuplicateScanProgress = Double(index + 1) / Double(max(1, eligible.count))
        }
        var selected = Set<String>()
        for group in matches.values where group.count > 1 {
            exactDuplicateVerifiedGroups += 1
            let ordered = group.sorted { left, right in
                if left.isLossless != right.isLossless { return left.isLossless }
                return left.id < right.id
            }
            selected.formUnion(ordered.dropFirst().map(\.id))
        }
        return selected
    }

    /// Explicit user-requested Trash action for regular songs or entire albums.
    /// Each file is validated by moveDuplicateToTrash before filesystem mutation.
    /// Stops on first failure; previous files remain recoverable in macOS Trash.
    public func moveTracksToTrash(_ tracks: [LibraryTrack]) async throws -> Int {
        try beginTrashOperation()
        defer { finishTrashOperation() }
        return try await moveTracksToTrashCore(tracks)
    }

    private func moveTracksToTrashCore(_ tracks: [LibraryTrack]) async throws -> Int {
        guard !tracks.isEmpty else { throw LibraryFailure("No songs selected.") }
        let unique = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var moved = 0
        for id in unique.keys.sorted() {
            guard let track = unique[id] else { continue }
            do {
                try Task.checkCancellation()
                try await moveDuplicateToTrashCore(track)
                moved += 1
            } catch {
                throw LibraryFailure("Moved \(moved) of \(unique.count) files to Trash. \(error.localizedDescription)")
            }
        }
        return moved
    }

    /// SHA-256 is computed incrementally away from the main actor to avoid
    /// loading music files into memory. Matching metadata is never sufficient.
    nonisolated static func filesAreByteIdentical(_ first: URL, _ second: URL) async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            try Self.fileSHA256(first) == Self.fileSHA256(second)
        }.value
    }

    nonisolated private static func fileSHA256(_ url: URL) throws -> [UInt8] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hash.update(data: chunk)
        }
        return Array(hash.finalize())
    }

    private struct TrashJournalRecord: Codable {
        var trackID: String
        var sourcePath: String
        var destinationPath: String?
    }

    private func recordTrashIntent(trackID: String, source: URL) throws -> URL {
        guard let trashJournalDirectory else { throw LibraryFailure("Trash recovery journal is not available.") }
        let entryURL = trashJournalDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let entry = TrashJournalRecord(trackID: trackID, sourcePath: source.path, destinationPath: nil)
        try JSONEncoder().encode(entry).write(to: entryURL, options: .atomic)
        return entryURL
    }

    private func recordTrashDestination(_ destination: URL, in journalURL: URL, trackID: String, source: URL) throws {
        let entry = TrashJournalRecord(trackID: trackID, sourcePath: source.path, destinationPath: destination.path)
        try JSONEncoder().encode(entry).write(to: journalURL, options: .atomic)
    }

    private func reconcileTrashJournal() async {
        guard let trashJournalDirectory, let repository,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: trashJournalDirectory, includingPropertiesForKeys: nil)
        else { return }
        var unresolved = 0
        for entryURL in entries where entryURL.pathExtension == "json" {
            guard let data = try? Data(contentsOf: entryURL),
                  let record = try? JSONDecoder().decode(TrashJournalRecord.self, from: data) else {
                unresolved += 1
                continue
            }
            // If the source still exists, never hide or delete it on journal recovery.
            if FileManager.default.fileExists(atPath: record.sourcePath) {
                try? FileManager.default.removeItem(at: entryURL)
                continue
            }
            // A missing source alone is NOT proof it was successfully trashed.
            guard let destination = record.destinationPath,
                  FileManager.default.fileExists(atPath: destination) else {
                unresolved += 1
                continue
            }
            do {
                try await repository.removeTracksFromLibrary(ids: [record.trackID])
                try FileManager.default.removeItem(at: entryURL)
            } catch {
                unresolved += 1
            }
        }
        if unresolved > 0 {
            errorMessage = "\(unresolved) interrupted Trash operation(s) require manual review. Check macOS Trash and your original music folders."
        }
    }

    private func beginTrashOperation() throws {
        guard !trashOperationActive else { throw LibraryFailure("Another Trash operation is in progress.") }
        trashOperationActive = true
    }

    private nonisolated static func validatedTrashSource(relativePath: String, root: URL) throws -> URL {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let file = root.appendingPathComponent(relativePath)
        let canonicalFile = file.resolvingSymlinksInPath().standardizedFileURL
        let parent = file.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        guard file.isFileURL, parent.pathComponents.starts(with: canonicalRoot.pathComponents),
              canonicalFile.pathComponents.count > canonicalRoot.pathComponents.count,
              canonicalFile.pathComponents.starts(with: canonicalRoot.pathComponents) else {
            throw LibraryFailure("The song file is outside its authorised library folder.")
        }
        let kind = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard kind.isRegularFile == true, kind.isSymbolicLink != true else {
            throw LibraryFailure("The song path does not refer to an audio file.")
        }
        return file
    }

    /// An album may contain stale missing entries. Preflight every path before
    /// moving anything; clean up unavailable entries only after available files succeed.
    public func moveAlbumToTrash(_ tracks: [LibraryTrack]) async throws -> Int {
        guard !tracks.isEmpty, !isShutDown, !isScanning, !isRecovering, let repository else {
            throw LibraryFailure("Wait for the library to finish updating.")
        }
        try beginTrashOperation()
        defer { finishTrashOperation() }
        var available: [LibraryTrack] = []
        var missing = Set<String>()
        for id in Set(tracks.map(\.id)).sorted() {
            try Task.checkCancellation()
            guard let current = try await repository.visibleTrack(id: id) else { continue }
            guard let selected = tracks.first(where: { $0.id == id }),
                  selected.folderID == current.folderID, selected.relativePath == current.relativePath,
                  selected.fileSize == current.fileSize, selected.modifiedAt == current.modifiedAt else {
                throw LibraryFailure("The album changed since confirmation. Review it again.")
            }
            guard let access = scopes[current.folderID] else {
                throw LibraryFailure("Reconnect the album’s music folder in Manage Library.")
            }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try withExtendedLifetime(access) {
                        _ = try Self.validatedTrashSource(relativePath: current.relativePath, root: access.url)
                    }
                }.value
                available.append(current)
            } catch {
                let failure = error as NSError
                guard failure.domain == NSCocoaErrorDomain,
                      [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) else { throw error }
                missing.insert(current.id)
            }
        }
        let moved = available.isEmpty ? 0 : try await moveTracksToTrashCore(available)
        if !missing.isEmpty {
            try await repository.removeTracksFromLibrary(ids: missing)
            trackActionsRevision += 1; overviewRevision += 1
            await reload(); await reloadPlaylists()
        }
        return moved
    }

    private func finishTrashOperation() {
        trashOperationActive = false
        if pendingRescan, !isShutDown { Task { await rescan() } }
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
        do { return try await repository.albumTracks(artist: album.artist, title: album.title, includeTagPayload: false) }
        catch { errorMessage = error.localizedDescription; return [] }
    }

    public func isMonitoring(_ folder: LibraryFolder) -> Bool { watchers[folder.id] != nil }

    public func searchSuggestions(for query: String, scope: TrackSearchScope) async throws -> [LibrarySearchSuggestion] {
        guard let repository, !isShutDown else { return [] }
        return try await repository.searchSuggestions(for: query, scope: scope)
    }

    /// Resolve the full Songs selection without expanding the visible browsing page.
    ///
    /// For large libraries, this uses random rowid sampling to avoid materializing
    /// the entire result set in memory. The sample size is capped at 5000 tracks
    /// to bound memory usage while still providing a representative shuffle.
    public func songsForPlayback() async throws -> [LibraryTrack] {
        guard let repository, !isShutDown else { return [] }
        
        // First get the total count of matching playable tracks
        let totalCount = try await repository.countPlayableTracks(
            search: search, recentFirst: recentFirst, favoritesOnly: favoritesOnly,
            sortOrder: sortOrder, reversed: reverseSort, searchScope: searchScope
        )
        
        // Cap the shuffle size to bound memory (10000 tracks ≈ ~400MB worst case)
        let shuffleCap = 10000
        let limit = min(totalCount, shuffleCap)
        
        // For small libraries, load all. For large ones, use random rowid sampling.
        if totalCount <= shuffleCap {
            let page = try await repository.page(search: search, limit: limit,
                recentFirst: recentFirst, favoritesOnly: favoritesOnly, sortOrder: sortOrder,
                reversed: reverseSort, searchScope: searchScope, includeTagPayload: false)
            try Task.checkCancellation()
            guard !isShutDown else { return [] }
            return page.tracks.filter { !$0.isMissing && $0.error == nil }
        }
        
        // Large library: use random rowid sampling for a representative subset
        let page = try await repository.pageRandomSample(search: search, limit: limit,
            recentFirst: recentFirst, favoritesOnly: favoritesOnly, sortOrder: sortOrder,
            reversed: reverseSort, searchScope: searchScope, includeTagPayload: false)
        try Task.checkCancellation()
        guard !isShutDown else { return [] }
        return page.tracks.filter { !$0.isMissing && $0.error == nil }
    }

    public func loadMore() async {
        guard !loadingTrackPage, !isShutDown, !Task.isCancelled,
              tracks.count < totalCount, let repository else { return }
        loadingTrackPage = true
        defer { loadingTrackPage = false }
        let revision = refreshRevision
        let offset = tracks.count
        let query = search, scope = searchScope
        let favorites = favoritesOnly, recent = recentFirst
        let order = sortOrder, reversed = reverseSort
        do {
            let page = try await repository.page(search: query, limit: 500, offset: offset,
                recentFirst: recent, favoritesOnly: favorites, sortOrder: order,
                reversed: reversed, searchScope: scope, includeTagPayload: false)
            guard !isShutDown, !Task.isCancelled, revision == refreshRevision,
                  tracks.count == offset, query == search, scope == searchScope,
                  favorites == favoritesOnly, recent == recentFirst,
                  order == sortOrder, reversed == reverseSort else { return }
            tracks.append(contentsOf: page.tracks)
            pageLimit = max(500, tracks.count)
            totalCount = page.count
            unreadableCount = page.unreadableCount
            if !page.tracks.isEmpty { tracksRevision &+= 1; overviewRevision += 1 }
        } catch is CancellationError { }
        catch { errorMessage = error.localizedDescription }
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
        let relocated = try await repository.relocatedTrackIDs()
        let task = Task.detached(priority: .utility) {
            let entries = try PlaylistFile.read(url)
            return (entries, try PlaylistFile.trackIDs(for: entries, roots: roots, relocatedIDs: relocated))
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
        let access = scopes
        let relocated = try await repository.relocatedTrackIDs()
        let task = Task.detached(priority: .utility) {
            try withExtendedLifetime(access) {
                let entries = urls.enumerated().map { PlaylistFileEntry(id: $0.offset, source: $0.element.path, url: $0.element) }
                return try PlaylistFile.trackIDs(for: entries, roots: access.mapValues(\.url), relocatedIDs: relocated).compactMap { $0 }
            }
        }
        let ids = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard !isShutDown, !Task.isCancelled else { throw CancellationError() }
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

    /// Resolve lyrics for a playing file. Synced sources win: an embedded LRC
    /// tag or a `.lrc` sidecar next to the audio; plain (unsynchronised) lyric
    /// tags are the fallback so the view can still show something. Returns nil
    /// when the song carries no lyrics at all.
    public func lyrics(for url: URL) async -> TimedLyrics? {
        guard !isShutDown, let track = await track(at: url) else { return nil }
        var embeddedRaw: String?
        if let json = track.tagsJSON, let data = json.data(using: .utf8),
           let tags = try? JSONDecoder().decode(AudioTags.self, from: data) {
            embeddedRaw = tags.lyrics
        }
        guard let location = try? location(for: track) else {
            return LyricsParser.parse(embeddedRaw ?? "", source: .embedded)
                ?? LyricsParser.unsynced(embeddedRaw ?? "", source: .embedded)
        }
        let sidecar = location.file.deletingPathExtension().appendingPathExtension("lrc")
        let embedded = embeddedRaw ?? ""
        return await Task.detached(priority: .userInitiated) { () -> TimedLyrics? in
            let acquired = location.root.startAccessingSecurityScopedResource()
            defer { if acquired { location.root.stopAccessingSecurityScopedResource() } }
            let sidecarRaw: String? = {
                guard let file = try? FileHandle(forReadingFrom: sidecar) else { return nil }
                defer { try? file.close() }
                guard let data = try? file.read(upToCount: 2 * 1024 * 1024 + 1),
                      data.count <= 2 * 1024 * 1024 else { return nil }
                return String(data: data, encoding: .utf8)
            }()
            return LyricsParser.parse(embedded, source: .embedded)
                ?? LyricsParser.parse(sidecarRaw ?? "", source: .sidecar)
                ?? LyricsParser.unsynced(embedded, source: .embedded)
                ?? LyricsParser.unsynced(sidecarRaw ?? "", source: .sidecar)
        }.value
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
        updated.bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
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
            let values = try canonical.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
            guard values.isRegularFile == true else { throw LibraryFailure("Choose an audio file.") }
            let root = URL(fileURLWithPath: folder.path).pathComponents
            let relative = canonical.pathComponents.dropFirst(root.count).joined(separator: "/")
            let file = ScanFile(url: canonical, relativePath: relative, size: Int64(values.fileSize ?? 0),
                                modified: values.contentModificationDate ?? .distantPast, coverURL: nil, coverStamp: "",
                                fileResourceIdentifier: LibraryScanner.fileIdentity(values))
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
                    folder.bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
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
                if self.isScanning || self.trashOperationActive {
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
