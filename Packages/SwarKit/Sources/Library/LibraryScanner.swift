import Foundation

struct ScanFile: Sendable {
    let url: URL
    let relativePath: String
    let size: Int64
    let modified: Date
    let coverURL: URL?
    let coverStamp: String
    let fileResourceIdentifier: String?
}

public struct ScanSummary: Sendable {
    public let total: Int
    public let changed: Int
    public let failed: Int
}

public struct LibraryScanner: Sendable {
    // File decoding and network-volume I/O may block. Do not occupy Swift's
    // cooperative executor threads while waiting on them, especially on small Macs.
    private static let inspectionQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "catto.swar.library-inspection"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 4
        return queue
    }()
    private let repository: LibraryRepository
    private let inspector: any MediaInspecting
    private let customArtworkDirectory: URL?
    public init(repository: LibraryRepository, artworkDirectory: URL, codecDirectory: URL? = nil, customArtworkDirectory: URL? = nil) {
        self.repository = repository
        self.customArtworkDirectory = customArtworkDirectory
        inspector = MediaInspector(codecDirectory: codecDirectory, artworkDirectory: artworkDirectory)
    }

    init(repository: LibraryRepository, inspector: any MediaInspecting) {
        self.repository = repository
        self.inspector = inspector
        customArtworkDirectory = nil
    }

    // Keep fingerprint I/O and task-group coordination off the caller's actor,
    // including with Swift 6.2's caller-isolated async defaults. Older compilers
    // already move nonisolated async functions to the generic executor (SE-0338).
    #if compiler(>=6.2)
    @concurrent
    #endif
    public nonisolated func scan(folder: LibraryFolder, root: URL,
                     progress: @escaping @Sendable (LibraryProgress) async -> Void = { _ in }) async throws -> ScanSummary {
        try Task.checkCancellation()
        let enumeration = Task.detached(priority: .utility) { try Self.enumerate(root) }
        let files = try await withTaskCancellationHandler {
            try await enumeration.value
        } onCancel: {
            enumeration.cancel()
        }
        try Task.checkCancellation()
        let prior = try await repository.existingTracks(folderID: folder.id)
        let priorIDs = Set(prior.values.map(\.id))
        var pending: [ScanFile] = []
        var artworkAvailability: [String: Bool] = [:]
        func artworkExists(_ key: String) -> Bool {
            if let exists = artworkAvailability[key] { return exists }
            let directory = key.hasPrefix("custom-") ? customArtworkDirectory ?? inspector.artworkDirectory : inspector.artworkDirectory
            let exists = FileManager.default.fileExists(atPath: directory.appendingPathComponent(key).path)
            artworkAvailability[key] = exists
            return exists
        }
        for file in files {
            // Path identity decides the fast path. The captured file resource
            // identifier is stored for future relocation matching, but renaming
            // still marks the old row missing and importing creates the new row,
            // matching the reconnect-merge review flow.
            if let old = prior[file.relativePath], !old.isMissing, old.fileSize == file.size,
               old.modifiedAt.timeIntervalSince1970 == file.modified.timeIntervalSince1970,
               old.coverStamp == file.coverStamp, old.error == nil,
               old.artworkKey.map(artworkExists) ?? true { continue }
            pending.append(file)
        }
        let unchanged = files.count - pending.count
        var completed = 0
        var failed = 0
        var batch: [LibraryTrack] = []
        var lastProgress = Date.distantPast
        await progress(LibraryProgress(folder: root.lastPathComponent, completed: unchanged, total: files.count, changed: 0, failed: 0))
        try await withThrowingTaskGroup(of: LibraryTrack.self) { group in
            var index = 0
            func enqueue(_ file: ScanFile) {
                group.addTask { [inspector] in
                    try Task.checkCancellation()
                    let fingerprint = prior[file.relativePath]
                    let track = await withCheckedContinuation { continuation in
                        Self.inspectionQueue.addOperation {
                            let track = autoreleasepool {
                                inspector.inspect(file: file, folder: folder, prior: fingerprint)
                            }
                            continuation.resume(returning: track)
                        }
                    }
                    // Keep structured lifetime/file access until an in-flight
                    // blocking operation completes, then propagate cancellation.
                    try Task.checkCancellation()
                    return track
                }
            }
            while index < min(4, pending.count) { enqueue(pending[index]); index += 1 }
            while var track = try await group.next() {
                // Reusing a relocated song's original path creates a new song.
                if prior[track.relativePath] == nil, priorIDs.contains(track.id) { track.id = UUID().uuidString }
                try Task.checkCancellation()
                completed += 1
                if track.error != nil { failed += 1 }
                batch.append(track)
                if batch.count >= 20 {
                    try await repository.saveTracks(batch)
                    batch.removeAll(keepingCapacity: true)
                    if Date().timeIntervalSince(lastProgress) >= 0.25 {
                        lastProgress = Date()
                        await progress(LibraryProgress(folder: root.lastPathComponent, completed: unchanged + completed,
                                                       total: files.count, changed: completed, failed: failed))
                    }
                }
                if index < pending.count { enqueue(pending[index]); index += 1 }
            }
        }
        try await repository.saveTracks(batch)
        // Reconcile in its own transaction with an explicit folder ID: the final
        // batch can be empty (nothing changed), and deriving the folder from the
        // batch silently skipped missing-marking in that case.
        try Task.checkCancellation()
        try await repository.reconcile(folderID: folder.id, seen: Set(files.map(\.relativePath)))
        await progress(LibraryProgress(folder: root.lastPathComponent, completed: files.count,
                                       total: files.count, changed: completed, failed: failed))
        return ScanSummary(total: files.count, changed: completed, failed: failed)
    }

    private static let extensions: Set<String> = ["m4a", "caf", "flac", "wav", "wave", "aiff", "aif", "aifc", "aac", "mp3", "ogg", "opus", "wv", "ape", "wma"]

    /// Encodes a file's stable resource identity as a string key.
    /// APFS returns a 128-bit volume-relative ID (NSData); hex-encoding keeps it
    /// stable and comparable across scans. Used by both scanning and reconnect.
    static func fileIdentity(_ values: URLResourceValues) -> String? {
        if let data = values.fileResourceIdentifier as? Data {
            return data.map { String(format: "%02x", $0) }.joined()
        }
        if let number = values.fileResourceIdentifier as? NSNumber { return number.stringValue }
        return nil
    }

    private static func enumerate(_ root: URL) throws -> [ScanFile] {
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileReadNoSuchFile) }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey]
        var enumerationError: (any Error)?
        guard let enumerator = FileManager.default.enumerator(at: canonicalRoot, includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, error in
                enumerationError = error; return false
            }) else { throw CocoaError(.fileReadNoPermission) }
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        var files: [ScanFile] = []
        var covers: [String: (URL?, String)] = [:]
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: Set(keys))
            let filePath = url.standardizedFileURL.path
            guard values.isSymbolicLink != true, values.isRegularFile == true,
                  extensions.contains(url.pathExtension.lowercased()), filePath.hasPrefix(rootPrefix) else { continue }
            // The resource value is an NSData/NSNumber identity, not a string.
            let fileResourceIdentifier = Self.fileIdentity(values)
            let parent = url.deletingLastPathComponent()
            let cover: (URL?, String)
            if let cached = covers[parent.path] { cover = cached }
            else {
                let candidate = ["cover.jpg", "folder.jpg", "front.png"].map { parent.appendingPathComponent($0) }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
                let info = try candidate?.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                cover = (candidate, candidate.map { $0.lastPathComponent + ":\(info?.fileSize ?? 0):\(info?.contentModificationDate?.timeIntervalSince1970 ?? 0)" } ?? "")
                covers[parent.path] = cover
            }
            let relativePath = String(filePath.dropFirst(rootPrefix.count))
            files.append(ScanFile(url: url, relativePath: relativePath,
                                  size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast,
                                  coverURL: cover.0, coverStamp: cover.1, fileResourceIdentifier: fileResourceIdentifier))
        }
        if let enumerationError { throw enumerationError }
        return files.sorted { $0.relativePath < $1.relativePath }
    }
}
