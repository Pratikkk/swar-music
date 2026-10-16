import SwiftUI
import Player
import Library
import UniformTypeIdentifiers
import AppKit

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

/// Local library browsing and the single-file playback surface.
@MainActor
public struct LibraryView: View {
    @State private var selection: LibrarySection? = .albums
    @State private var player = Player()
    @State private var showImporter = false
    @State private var importingFolder = false
    @State private var library = LibraryModel()

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
                Section("Folders") {
                    ForEach(library.folders) { folder in
                        Label(URL(fileURLWithPath: folder.path).lastPathComponent, systemImage: "folder")
                            .help(folder.path)
                            .contextMenu {
                                Button("Remove from Library", role: .destructive) { Task { await library.removeFolder(folder) } }
                                    .disabled(library.isScanning)
                            }
                    }
                    Button("Add Folder…", systemImage: "folder.badge.plus") { openFolderPicker() }
                        .disabled(library.isScanning)
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
            LibraryContent(library: library, player: player, section: selection?.rawValue ?? "Albums")
            .navigationTitle(selection?.rawValue ?? "Library")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PlaybackControls(player: player)
            }
            .toolbar {
                Button("Open Audio File…", systemImage: "doc.waveform") { importingFolder = false; showImporter = true }
                    .disabled(player.isBusy)
                Button("Add Folder…", systemImage: "folder.badge.plus") { openFolderPicker() }
                    .disabled(library.isScanning)
                Button("Rescan", systemImage: "arrow.clockwise") { Task { await library.rescan() } }
                    .disabled(library.isScanning || library.folders.isEmpty)
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importingFolder ? [.folder] : [.item]) { result in
            switch result {
            case .success(let url):
                if importingFolder { Task { await library.addFolder(url) } }
                else { Task { await player.open(url) } }
            case .failure(let error): player.reportImportError(error)
            }
        }
        .playbackCommands(player: player, open: { importingFolder = false; showImporter = true })
        .searchable(text: $library.search, placement: .sidebar, prompt: "Search title, artist, album")
        .task { await library.start() }
        .task(id: selection) {
            library.recentFirst = selection == .recentlyAdded
            await library.reload(resetLimit: true)
        }
        .task(id: library.search) {
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            await library.reload(resetLimit: true)
        }
        .task {
            while !Task.isCancelled {
                await player.refresh()
                do { try await Task.sleep(for: .milliseconds(200)) }
                catch { break }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            player.shutdown()
            library.shutdown()
        }
    }

    private func openFolderPicker() {
        importingFolder = true
        showImporter = true
    }

}

#Preview {
    LibraryView()
        .frame(width: 1100, height: 740)
}
