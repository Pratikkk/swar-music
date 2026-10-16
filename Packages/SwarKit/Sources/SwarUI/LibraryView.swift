import SwiftUI
import Player
import Library
import UniformTypeIdentifiers
import AppKit

private enum LibrarySection: String, CaseIterable, Identifiable {
    case home = "Home"
    case recentlyAdded = "Recently Added"
    case artists = "Artists"
    case albums = "Albums"
    case songs = "Songs"
    case genres = "Genres"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .home: "house"
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
    @State private var selection: LibrarySection? = .recentlyAdded
    @State private var player = Player(sessionStore: .applicationDefault())
    @State private var showImporter = false
    @State private var showNowPlaying = false
    @State private var windowWidth: CGFloat = 900
    @State private var importingFolder = false
    @State private var library = LibraryModel()

    public init() {}

    public var body: some View {
        NavigationSplitView {
            VStack(spacing: 12) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Search", text: $library.search)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search title, artist, album")
                }
                .padding(6).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.primary.opacity(0.15)))
                .padding(.horizontal, 12).padding(.top, 12)
                List(selection: $selection) {
                    Section("Swar") {
                        Label("Home", systemImage: "house").tag(LibrarySection.home)
                    }
                    Section("Library") {
                        ForEach(LibrarySection.allCases.filter { $0 != .home }) { section in
                            Label(section.rawValue, systemImage: section.symbol).tag(section)
                        }
                    }
                    Section("Music Folders") {
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
                }
                .listStyle(.sidebar).scrollContentBackground(.hidden)
            }
            .background {
                LinearGradient(colors: [.pink.opacity(0.16), .purple.opacity(0.22)], startPoint: .top, endPoint: .bottom)
                    .background(.ultraThinMaterial)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 202, max: 260)
        } detail: {
            VStack(spacing: 0) {
                ToolbarPlayer(player: player, openNowPlaying: { showNowPlaying = true })
                Divider()
                ZStack {
                    Text(selection?.rawValue ?? "Recently Added").font(.headline)
                    HStack {
                        if let info = player.formatInfo { FormatChip(info: info) }
                        Spacer()
                        Menu {
                            Button("Open Audio File…", systemImage: "doc.waveform") { importingFolder = false; showImporter = true }
                                .disabled(player.isBusy)
                            Button("Add Folder…", systemImage: "folder.badge.plus") { openFolderPicker() }
                                .disabled(library.isScanning)
                            Button("Rescan Library", systemImage: "arrow.clockwise") { Task { await library.rescan() } }
                                .disabled(library.isScanning || library.folders.isEmpty)
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize().help("Library actions")
                    }
                }
                .padding(.horizontal, 18).frame(height: 36).background(.bar)
                LibraryContent(library: library, player: player,
                               section: selection == .home ? "Recently Added" : (selection?.rawValue ?? "Recently Added"))
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .ignoresSafeArea(.container, edges: .top)
        }
        .toolbar(removing: .sidebarToggle)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .tint(.pink)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importingFolder ? [.folder] : [.item]) { result in
            switch result {
            case .success(let url):
                if importingFolder { Task { await library.addFolder(url) } }
                else { Task { await player.open(url) } }
            case .failure(let error): player.reportImportError(error)
            }
        }
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { windowWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in windowWidth = width }
            }
        }
        .sheet(isPresented: $showNowPlaying) {
            NowPlayingView(player: player, width: max(640, min(900, windowWidth - 40)))
        }
        .playbackCommands(player: player, canOpen: !showNowPlaying,
            open: { importingFolder = false; showImporter = true },
            nowPlaying: { showNowPlaying = true })
        .task { await library.start() }
        .task { await player.restoreSession() }
        .task {
            while !Task.isCancelled {
                await player.refreshVolume()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            }
        }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { break }
                await player.saveSessionIfNeeded()
            }
        }
        .task(id: selection) {
            library.recentFirst = selection == .recentlyAdded || selection == .home
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
