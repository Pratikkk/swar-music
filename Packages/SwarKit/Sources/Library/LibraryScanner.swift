import Foundation

struct ScanFile: Sendable {
    let url: URL
    let relativePath: String
    let size: Int64
    let modified: Date
    let coverURL: URL?
    let coverStamp: String
}

public struct ScanSummary: Sendable {
    public let total: Int
    public let changed: Int
    public let failed: Int
}

public struct LibraryScanner: Sendable {
    private let repository: LibraryRepository
    private let inspector: any MediaInspecting
    public init(repository: LibraryRepository, artworkDirectory: URL, codecDirectory: URL? = nil) {
        self.repository = repository
        inspector = MediaInspector(codecDirectory: codecDirectory, artworkDirectory: artworkDirectory)
    }

    init(repository: LibraryRepository, inspector: any MediaInspecting) {
        self.repository = repository
        self.inspector = inspector
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
        var pending: [ScanFile] = []
        for file in files {
            if let old = prior[file.relativePath], old.fileSize == file.size,
               old.modifiedAt.timeIntervalSince1970 == file.modified.timeIntervalSince1970,
               old.coverStamp == file.coverStamp, old.error == nil,
               old.artworkKey.map({ FileManager.default.fileExists(atPath: inspector.artworkDirectory.appendingPathComponent($0).path) }) ?? true { continue }
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
                    return autoreleasepool {
                        inspector.inspect(file: file, folder: folder, prior: prior[file.relativePath])
                    }
                }
            }
            while index < min(4, pending.count) { enqueue(pending[index]); index += 1 }
            while let track = try await group.next() {
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
        try Task.checkCancellation()
        try await repository.reconcile(folderID: folder.id, seen: Set(files.map(\.relativePath)))
        await progress(LibraryProgress(folder: root.lastPathComponent, completed: files.count,
                                       total: files.count, changed: completed, failed: failed))
        return ScanSummary(total: files.count, changed: completed, failed: failed)
    }

    private static let extensions: Set<String> = ["m4a", "caf", "flac", "wav", "wave", "aiff", "aif", "aifc", "aac", "mp3", "ogg", "opus", "wv", "ape", "wma"]

    private static func enumerate(_ root: URL) throws -> [ScanFile] {
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw CocoaError(.fileReadNoSuchFile) }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
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
            files.append(ScanFile(url: url, relativePath: String(filePath.dropFirst(rootPrefix.count)),
                                  size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast,
                                  coverURL: cover.0, coverStamp: cover.1))
        }
        if let enumerationError { throw enumerationError }
        return files.sorted { $0.relativePath < $1.relativePath }
    }
}
