import Foundation

public enum TrackSearchScope: String, CaseIterable, Identifiable, Sendable {
    case all = "All Fields"
    case title = "Song Title"
    case artist = "Artist"
    case album = "Album"
    case genre = "Genre"
    case year = "Year"
    case file = "File or Folder"
    public var id: Self { self }

    var columns: String? {
        switch self {
        case .all: nil
        case .title: "title"
        case .artist: "artist albumArtist"
        case .album: "album"
        case .genre: "genre"
        case .year: "year"
        case .file: "relativePath"
        }
    }
}

/// Literal word-prefix search shared by the indexed library and playlist rows.
/// Punctuation separates words; input is never interpreted as FTS query syntax.
public struct TrackSearchQuery: Sendable {
    public let isEmpty: Bool
    private let terms: [String]

    public init(_ text: String) {
        isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        terms = Array(Self.words(String(text.prefix(512))).prefix(20))
    }

    fileprivate static func words(_ text: String) -> [String] {
        let characters = CharacterSet.alphanumerics.union(.nonBaseCharacters)
        return text.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: characters.inverted).filter { !$0.isEmpty }.map { word in
                // Fold Latin accents like unicode61, preserving vowel signs and
                // combining marks in scripts such as Devanagari.
                var scalars = String.UnicodeScalarView()
                var latinBase = false
                for scalar in word.decomposedStringWithCanonicalMapping.unicodeScalars {
                    if CharacterSet.nonBaseCharacters.contains(scalar) {
                        if !latinBase { scalars.append(scalar) }
                    } else {
                        latinBase = (0x41...0x7A).contains(scalar.value) || (0xC0...0x24F).contains(scalar.value)
                        scalars.append(scalar)
                    }
                }
                return String(scalars).precomposedStringWithCanonicalMapping
            }
    }

    func expression(scope: TrackSearchScope) -> String? {
        guard !terms.isEmpty else { return nil }
        let prefix = scope.columns.map { "{\($0)} : " } ?? ""
        return terms.map { prefix + "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")
    }

    public func matches(_ track: LibraryTrack, scope: TrackSearchScope = .all) -> Bool {
        if isEmpty { return true }
        guard !terms.isEmpty else { return false }
        let fields: [String]
        switch scope {
        case .all: fields = [track.title, track.artist, track.albumArtist, track.album, track.genre, track.year ?? "", track.relativePath]
        case .title: fields = [track.title]
        case .artist: fields = [track.artist, track.albumArtist]
        case .album: fields = [track.album]
        case .genre: fields = [track.genre]
        case .year: fields = [track.year ?? ""]
        case .file: fields = [track.relativePath]
        }
        let words = fields.flatMap(Self.words)
        return terms.allSatisfy { term in words.contains { $0.hasPrefix(term) } }
    }

    public func matches(_ document: TrackSearchDocument, scope: TrackSearchScope = .all) -> Bool {
        if isEmpty { return true }
        guard !terms.isEmpty else { return false }
        return document.matches(terms: terms, scope: scope)
    }
}

/// Reuses Unicode tokenization across playlist queries. Each distinct word is
/// stored once per song, with a compact mask identifying its searchable fields.
public struct TrackSearchDocument: Sendable {
    private struct Word: Sendable {
        let value: String
        let fields: UInt8
    }
    private let words: [Word]

    public init(_ track: LibraryTrack) {
        let fields = [track.title, track.artist, track.albumArtist, track.album, track.genre, track.year ?? "", track.relativePath]
        var indexed: [String: UInt8] = [:]
        for (index, field) in fields.enumerated() {
            for word in TrackSearchQuery.words(field) { indexed[word, default: 0] |= 1 << index }
        }
        words = indexed.map { Word(value: $0.key, fields: $0.value) }
    }

    fileprivate func matches(terms: [String], scope: TrackSearchScope) -> Bool {
        let mask: UInt8
        switch scope {
        case .all: mask = 0x7f
        case .title: mask = 1
        case .artist: mask = 2 | 4
        case .album: mask = 8
        case .genre: mask = 16
        case .year: mask = 32
        case .file: mask = 64
        }
        return terms.allSatisfy { term in words.contains { $0.fields & mask != 0 && $0.value.hasPrefix(term) } }
    }
}
