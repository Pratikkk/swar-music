import SwiftUI

private enum LibrarySection: String, CaseIterable, Identifiable {
    case recentlyAdded = "Recently Added"
    case artists = "Artists"
    case albums = "Albums"
    case songs = "Songs"
    case genres = "Genres"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .recentlyAdded: "clock"
        case .artists: "music.mic"
        case .albums: "square.stack"
        case .songs: "music.note"
        case .genres: "guitars"
        }
    }
}

/// The initial library shell. Playback and importing arrive in later phases.
public struct LibraryView: View {
    @State private var selection: LibrarySection? = .albums

    public init() {}

    public var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Library") {
                    ForEach(LibrarySection.allCases) { section in
                        Label(section.rawValue, systemImage: section.symbol)
                            .tag(section)
                    }
                }
                Section("Playlists") {
                    Text("No playlists yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Swar")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: selection?.symbol ?? "music.note")
            } description: {
                Text("Your local music belongs here. Folder importing will be available in a future build.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(selection?.rawValue ?? "Library")
        }
    }

    private var emptyTitle: String {
        switch selection {
        case .recentlyAdded: "No Recent Additions"
        case .artists: "No Artists Yet"
        case .albums: "No Albums Yet"
        case .songs: "No Songs Yet"
        case .genres: "No Genres Yet"
        case nil: "Select Your Library"
        }
    }
}

#Preview {
    LibraryView()
        .frame(width: 1100, height: 740)
}
