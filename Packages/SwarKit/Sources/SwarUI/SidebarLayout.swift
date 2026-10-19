import Foundation

enum LibrarySection: String, CaseIterable, Identifiable {
    case home = "Home"
    case recentlyAdded = "Recently Added"
    case artists = "Artists"
    case albums = "Albums"
    case songs = "Songs"
    case favorites = "Favourites"
    case listening = "Listening"
    case genres = "Genres"
    case manage = "Manage Library"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .home: "house"
        case .recentlyAdded: "clock"
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .favorites: "star"
        case .listening: "clock.arrow.circlepath"
        case .genres: "guitars"
        case .manage: "tray.full"
        }
    }
}

enum SidebarGroup: String, CaseIterable, Identifiable {
    case library, playlists, folders
    var id: Self { self }
    var title: String {
        switch self {
        case .library: "Library"
        case .playlists: "Playlists"
        case .folders: "Music Folders"
        }
    }
}

struct SidebarLayout: Equatable {
    private struct Stored: Codable {
        var sections: [String]
        var hidden: Set<String>
        var groups: [String]
        var hiddenGroups: Set<String>
    }
    private(set) var sections = LibrarySection.allCases
    private(set) var hidden: Set<LibrarySection> = []
    private(set) var groups = SidebarGroup.allCases
    private(set) var hiddenGroups: Set<SidebarGroup> = []
    var visibleSections: [LibrarySection] { sections.filter { !hidden.contains($0) } }
    var visibleGroups: [SidebarGroup] { groups.filter { !hiddenGroups.contains($0) } }

    init(serialized: String = "") {
        guard let data = serialized.data(using: .utf8), let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        sections = Self.normalize(stored.sections.compactMap(LibrarySection.init(rawValue:)), defaults: LibrarySection.allCases)
        groups = Self.normalize(stored.groups.compactMap(SidebarGroup.init(rawValue:)), defaults: SidebarGroup.allCases)
        hidden = Set(stored.hidden.compactMap(LibrarySection.init(rawValue:)))
        hiddenGroups = Set(stored.hiddenGroups.compactMap(SidebarGroup.init(rawValue:)))
        hiddenGroups.remove(.library)
        if visibleSections.isEmpty { hidden.remove(.home) }
    }

    var serialized: String {
        let stored = Stored(sections: sections.map(\.rawValue), hidden: Set(hidden.map(\.rawValue)),
                            groups: groups.map(\.rawValue), hiddenGroups: Set(hiddenGroups.map(\.rawValue)))
        guard let data = try? JSONEncoder().encode(stored) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    mutating func setVisible(_ section: LibrarySection, _ visible: Bool) {
        if visible { hidden.remove(section) }
        else if visibleSections.count > 1 { hidden.insert(section) }
    }

    mutating func setVisible(_ group: SidebarGroup, _ visible: Bool) {
        guard group != .library else { return }
        if visible { hiddenGroups.remove(group) } else { hiddenGroups.insert(group) }
    }

    mutating func moveSections(from offsets: IndexSet, to destination: Int) {
        Self.move(&sections, from: offsets, to: destination)
    }

    mutating func moveGroups(from offsets: IndexSet, to destination: Int) {
        Self.move(&groups, from: offsets, to: destination)
    }

    private static func normalize<T: Hashable>(_ stored: [T], defaults: [T]) -> [T] {
        var seen: Set<T> = []
        return (stored + defaults).filter { seen.insert($0).inserted }
    }

    private static func move<T>(_ items: inout [T], from offsets: IndexSet, to destination: Int) {
        guard !offsets.isEmpty, offsets.allSatisfy({ items.indices.contains($0) }),
              destination >= 0, destination <= items.count else { return }
        let moved = offsets.sorted().map { items[$0] }
        for index in offsets.sorted().reversed() { items.remove(at: index) }
        items.insert(contentsOf: moved, at: destination - offsets.filter { $0 < destination }.count)
    }
}
