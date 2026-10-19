import Foundation

public struct PlaylistFileEntry: Sendable, Identifiable {
    public let id: Int
    public let source: String
    public let url: URL?
}

public struct PlaylistExportEntry: Sendable {
    public let url: URL
    public let title: String
    public let artist: String
    public let duration: Double
    public init(url: URL, title: String, artist: String, duration: Double) {
        self.url = url; self.title = title; self.artist = artist; self.duration = duration
    }
}

public enum PlaylistFile {
    public static let maximumBytes = 8 * 1024 * 1024
    public static let maximumEntries = 100_000

    public static func read(_ url: URL) throws -> [PlaylistFileEntry] {
        let acquired = url.startAccessingSecurityScopedResource()
        defer { if acquired { url.stopAccessingSecurityScopedResource() } }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        return try parse(data, relativeTo: url.deletingLastPathComponent(), strictUTF8: url.pathExtension.lowercased() == "m3u8")
    }

    public static func parse(_ data: Data, relativeTo directory: URL, strictUTF8: Bool = true) throws -> [PlaylistFileEntry] {
        guard data.count <= maximumBytes else { throw LibraryFailure("This playlist exceeds the 8 MB import limit.") }
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) { text = utf8 }
        else if !strictUTF8, let legacy = String(data: data, encoding: .windowsCP1252) { text = legacy }
        else { throw LibraryFailure("This playlist isn’t valid UTF-8. Save it as UTF-8/M3U8 and try again.") }
        guard !text.contains("\0") else { throw LibraryFailure("This file isn’t a supported text playlist.") }
        var entries: [PlaylistFileEntry] = []
        let contents = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        for (index, line) in contents.components(separatedBy: .newlines).enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            let path = line.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { continue }
            if path.hasPrefix("#EXT-X-") { throw LibraryFailure("Streaming playlists aren’t supported. Choose a local M3U or M3U8 playlist.") }
            guard !path.hasPrefix("#") else { continue }
            guard path.utf8.count <= 16_384 else { throw LibraryFailure("A playlist entry is too long.") }
            guard entries.count < maximumEntries else { throw LibraryFailure("This playlist exceeds the 100,000-entry import limit.") }
            entries.append(PlaylistFileEntry(id: entries.count, source: path, url: localURL(path, relativeTo: directory)))
        }
        return entries
    }

    private static func localURL(_ path: String, relativeTo directory: URL) -> URL? {
        // Windows drive/UNC paths cannot be resolved against a macOS library.
        if path.hasPrefix("\\\\") || path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil { return nil }
        if path.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression) != nil {
            guard let url = URL(string: path), url.isFileURL,
                  url.host == nil || url.host == "" || url.host?.lowercased() == "localhost",
                  url.query == nil, url.fragment == nil else { return nil }
            return url.standardizedFileURL
        }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
        return directory.appendingPathComponent(path.replacingOccurrences(of: "\\", with: "/")).standardizedFileURL
    }

    /// Resolve aliases off the main actor; matching never falls back to ambiguous song titles.
    static func trackIDs(for entries: [PlaylistFileEntry], roots: [String: URL]) throws -> [String?] {
        let folders = roots.map { ($0.key, $0.value.resolvingSymlinksInPath().standardizedFileURL.pathComponents) }
        return try entries.enumerated().map { index, entry in
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard let url = entry.url else { return nil }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            for (id, root) in folders where path.count > root.count && path.starts(with: root) {
                return id + ":" + path.dropFirst(root.count).joined(separator: "/")
            }
            return nil
        }
    }

    public static func encode(_ entries: [PlaylistExportEntry], relativeTo directory: URL? = nil) throws -> Data {
        guard entries.count <= maximumEntries else { throw LibraryFailure("This playlist exceeds the 100,000-entry export limit.") }
        var lines = ["#EXTM3U"]
        var byteCount = 8
        for (index, entry) in entries.enumerated() {
            if index.isMultiple(of: 256) { try Task.checkCancellation() }
            guard entry.url.isFileURL else { throw LibraryFailure("Only local music files can be exported.") }
            let file = entry.url.standardizedFileURL
            guard file.path.rangeOfCharacter(from: .newlines) == nil, !file.path.contains("\0") else {
                throw LibraryFailure("File names containing line breaks can’t be represented in M3U playlists.")
            }
            let title = (entry.artist.isEmpty ? entry.title : entry.artist + " - " + entry.title)
                .components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "\0", with: "")
            let duration = entry.duration.isFinite && entry.duration >= 0 && entry.duration < Double(Int.max) ? Int(entry.duration) : -1
            let metadata = "#EXTINF:\(duration)," + title
            var path = file.path
            if let directory {
                // Canonical parents make ../ paths work even when the export folder is an alias.
                let base = directory.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                let target = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents
                var common = 0
                while common < min(base.count, target.count), base[common] == target[common] { common += 1 }
                path = (Array(repeating: "..", count: base.count - common) + target.dropFirst(common)).joined(separator: "/")
                if !path.hasPrefix("../") { path = "./" + path }
            }
            // A URI safely preserves trailing spaces that M3U readers otherwise trim.
            if path != path.trimmingCharacters(in: .whitespaces) { path = file.absoluteString }
            byteCount += metadata.utf8.count + path.utf8.count + 2
            guard byteCount <= maximumBytes else { throw LibraryFailure("This playlist exceeds the 8 MB export limit.") }
            lines.append(metadata)
            lines.append(path)
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        guard data.count <= maximumBytes else { throw LibraryFailure("This playlist exceeds the 8 MB export limit.") }
        return data
    }

    public static func write(_ entries: [PlaylistExportEntry], to url: URL, relativePaths: Bool) throws {
        let acquired = url.startAccessingSecurityScopedResource()
        defer { if acquired { url.stopAccessingSecurityScopedResource() } }
        let data = try encode(entries, relativeTo: relativePaths ? url.deletingLastPathComponent() : nil)
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
    }
}
