import Foundation

public enum SmartMatchMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case all = "All", any = "Any"
    public var id: Self { self }
}
public enum SmartField: String, Codable, CaseIterable, Identifiable, Sendable {
    case artist = "Artist", album = "Album", genre = "Genre", year = "Year"
    case favourite = "Favourite", added = "Date Added", format = "Format", bitrate = "Bitrate", lossless = "Lossless"
    public var id: Self { self }
    public var comparisons: [SmartComparison] {
        switch self {
        case .artist, .album, .genre, .format: [.contains, .equals, .notContains, .notEquals]
        case .year, .bitrate: [.equals, .atLeast, .atMost, .greater, .less]
        case .favourite, .lossless: [.equals]
        case .added: [.withinDays, .olderDays]
        }
    }
    public var initialValue: String {
        switch self {
        case .favourite, .lossless: "true"
        case .added: "30"
        case .year: "2020"
        case .bitrate: "256"
        case .format: "FLAC"
        default: ""
        }
    }
}
public enum SmartComparison: String, Codable, CaseIterable, Identifiable, Sendable {
    case contains = "contains", equals = "is", notContains = "does not contain", notEquals = "is not"
    case atLeast = "is at least", atMost = "is at most", greater = "is greater than", less = "is less than"
    case withinDays = "within the last", olderDays = "more than"
    public var id: Self { self }
}
public struct SmartRule: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var field: SmartField
    public var comparison: SmartComparison
    public var value: String
    public init(id: UUID = UUID(), field: SmartField = .genre, comparison: SmartComparison? = nil, value: String? = nil) {
        self.id = id; self.field = field
        self.comparison = comparison ?? field.comparisons[0]
        self.value = value ?? field.initialValue
    }
}
public struct SmartPlaylistDefinition: Codable, Equatable, Hashable, Sendable {
    public var version = 1
    public var mode: SmartMatchMode = .all
    public var rules: [SmartRule] = [SmartRule()]
    public var sort: TrackSortOrder = .album
    public var reversed = false
    public var limit: Int? = nil
    public init(mode: SmartMatchMode = .all, rules: [SmartRule] = [SmartRule()], sort: TrackSortOrder = .album, reversed: Bool = false, limit: Int? = nil) {
        self.mode = mode; self.rules = rules; self.sort = sort; self.reversed = reversed; self.limit = limit
    }
    public func validate() throws {
        guard version == 1 else { throw LibraryFailure("This Smart Playlist uses an unsupported rules version.") }
        guard (1...20).contains(rules.count), Set(rules.map(\.id)).count == rules.count else {
            throw LibraryFailure("Use between 1 and 20 distinct rules.")
        }
        if let limit, !(1...10000).contains(limit) { throw LibraryFailure("The song limit must be between 1 and 10,000.") }
        for rule in rules {
            guard rule.field.comparisons.contains(rule.comparison) else { throw LibraryFailure("Choose a valid comparison for \(rule.field.rawValue).") }
            let value = rule.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 256 else { throw LibraryFailure("Enter a value for \(rule.field.rawValue) using at most 256 characters.") }
            switch rule.field {
            case .year:
                guard let n = Int(value), (1...9999).contains(n) else { throw LibraryFailure("Enter a year between 1 and 9999.") }
            case .bitrate:
                guard let n = Int(value), (0...1000000).contains(n) else { throw LibraryFailure("Enter a bitrate between 0 and 1,000,000 kbps.") }
            case .added:
                guard let n = Int(value), (1...36500).contains(n) else { throw LibraryFailure("Enter a day count between 1 and 36,500.") }
            case .favourite, .lossless:
                guard value == "true" || value == "false" else { throw LibraryFailure("Choose Yes or No for \(rule.field.rawValue).") }
            default: break
            }
        }
    }
    public func encoded() throws -> String {
        try validate()
        return String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }
    public static func decode(_ json: String) throws -> Self {
        let result = try JSONDecoder().decode(Self.self, from: Data(json.utf8))
        try result.validate()
        return result
    }
    /// Unicode case folding preserves non-Latin combining marks. SQL uses bound
    /// values and instr(), so %, _, quotes and SQL-looking text stay literal.
    static func folded(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
public struct SmartPlaylistPreview: Sendable {
    public let matchedCount: Int
    public let selectedCount: Int
    public let samples: [LibraryTrack]
}
