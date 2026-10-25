import Foundation

public struct LocalLyricsSettings: Codable, Sendable {
    public var bookmark: Data?
    /// Positive values delay lyrics; negative values make them appear earlier.
    public var delay: Double = 0
    public init() {}
}

/// Small, durable per-song settings. All file I/O runs on this actor.
actor LocalLyricsStore {
    let file: URL
    private var settings: [String: LocalLyricsSettings]?
    init(file: URL) { self.file = file }

    func get(_ id: String) throws -> LocalLyricsSettings {
        if settings == nil {
            settings = FileManager.default.fileExists(atPath: file.path)
                ? try JSONDecoder().decode([String: LocalLyricsSettings].self, from: Data(contentsOf: file)) : [:]
        }
        return settings?[id] ?? LocalLyricsSettings()
    }

    func save(_ value: LocalLyricsSettings, for id: String) throws {
        _ = try get(id)
        var updated = settings ?? [:]
        updated[id] = value
        try JSONEncoder().encode(updated).write(to: file, options: .atomic)
        settings = updated
    }

    func attach(_ url: URL, to id: String) throws {
        guard url.pathExtension.lowercased() == "lrc" else { throw LibraryFailure("Choose an .lrc lyrics file.") }
        let acquired = url.startAccessingSecurityScopedResource()
        defer { if acquired { url.stopAccessingSecurityScopedResource() } }
        let raw = try Self.read(url)
        guard LyricsParser.parse(raw, source: .sidecar) != nil || LyricsParser.unsynced(raw, source: .sidecar) != nil else {
            throw LibraryFailure("This lyrics file is empty or unsupported.")
        }
        var value = try get(id)
        value.bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
        try save(value, for: id)
    }

    func associatedURL(_ id: String) throws -> URL? {
        var value = try get(id)
        guard let data = value.bookmark else { return nil }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale)
        if stale {
            let acquired = url.startAccessingSecurityScopedResource()
            defer { if acquired { url.stopAccessingSecurityScopedResource() } }
            value.bookmark = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            try save(value, for: id)
        }
        return url
    }

    func associatedText(_ id: String) throws -> String? {
        guard let url = try associatedURL(id) else { return nil }
        let acquired = url.startAccessingSecurityScopedResource()
        defer { if acquired { url.stopAccessingSecurityScopedResource() } }
        return try Self.read(url)
    }

    static func read(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let data = try file.read(upToCount: 2 * 1024 * 1024 + 1), data.count <= 2 * 1024 * 1024,
              let raw = String(data: data, encoding: .utf8) else {
            throw LibraryFailure("Lyrics must be a UTF-8 .lrc file smaller than 2 MB.")
        }
        return raw
    }
}
