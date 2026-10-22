import SwiftUI
import Library
import Player
import AppKit

@MainActor
struct CollectionManagerView: View {
    @Environment(\.swarDensity) private var density
    @Environment(\.swarPalette) private var palette
    let library: LibraryModel
    let player: Player
    let addFolder: () -> Void
    @Environment(\.floatingPlayerClearance) private var clearance
    @State private var filter: CollectionFilter = .all
    @State private var page: CollectionPage?
    @State private var limit = 200
    @State private var selected = Set<String>()
    @State private var recoveryRequest: FileRecoveryRequest?
    @State private var editing: LibraryTrack?
    @State private var artworkRequest: ArtworkEditRequest?
    @State private var pendingRemoval = Set<String>()
    @State private var showRemoval = false
    @State private var pendingTrashTrack: LibraryTrack?
    @State private var showTrashConfirmation = false
    @State private var showBatchTrashConfirmation = false
    @State private var pendingBatchTrash = Set<String>()
    @State private var error: String?
    @State private var working = false
    @State private var loadedFilter: CollectionFilter?
    @State private var loadedSearch = ""
    @State private var loadedScope: TrackSearchScope = .all
    @State private var showNewPlaylist = false
    @State private var playlistName = ""
    @State private var playlistTracks: [LibraryTrack] = []
    @State private var loadGeneration = UUID()

    private var matchesContext: Bool {
        loadedFilter == filter && loadedSearch == library.search && loadedScope == library.searchScope
    }

    private var refreshKey: String {
        "\(library.isReady)-\(library.overviewRevision)-\(library.lastScanAt?.timeIntervalSince1970 ?? 0)-\(filter)-\(library.searchScope)-\(library.search)-\(limit)"
    }
    private var selectedTracks: [LibraryTrack] { page?.tracks.filter { selected.contains($0.id) } ?? [] }

    var body: some View {
        GeometryReader { geometry in
        let compact = geometry.size.width < 650 || geometry.size.height < 600
        VStack(alignment: .leading, spacing: 16) {
            header
            if let error = error ?? library.errorMessage {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(2)
                    Spacer()
                    Button("Retry") { Task { await load() } }
                    Button { self.error = nil; library.dismissError() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss library error")
                }.font(.caption)
            }
            if let page {
                if compact {
                    HStack {
                        Picker("Review", selection: $filter) {
                            ForEach(CollectionFilter.allCases) { item in
                                Text("\(item.rawValue) (\(page.summary.count(item)))").tag(item)
                            }
                        }.labelsHidden().frame(maxWidth: 240).accessibilityLabel("Collection review filter")
                        Spacer()
                        Text("\(page.summary.songs) songs · \(page.summary.albums) albums")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    metrics(page.summary)
                    filters(page.summary)
                    folders
                }
                selectionBar(page)
                if filter == .duplicates {
                    Text("Select Duplicates · Keep One retains a preferred-quality copy of each metadata-matched group. Review the selection carefully: editions and masters may differ. Selection never deletes files.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if filter == .missing {
                    Text("Locate a moved song or reconnect its music folder. Playlists, favourites, and listening history are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if filter == .removed {
                    Text("Restore songs to the library. Previous playlist membership isn’t restored.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !matchesContext {
                    ProgressView("Loading songs…").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if page.tracks.isEmpty {
                    ContentUnavailableView {
                        Label(TrackSearchQuery(library.search).isEmpty ? "Nothing to Review" : "No Matches", systemImage: "checkmark.circle")
                    } actions: {
                        if !TrackSearchQuery(library.search).isEmpty { Button("Clear Search") { library.search = "" } }
                    }
                } else { trackTable(page.tracks) }
            } else { ProgressView("Opening collection…").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, clearance + 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task(id: refreshKey) { await load() }
        .onChange(of: filter) { selected.removeAll(); limit = 200 }
        .onChange(of: library.search) { selected.removeAll(); limit = 200 }
        .onChange(of: library.searchScope) { selected.removeAll(); limit = 200 }
        .sheet(item: $recoveryRequest) { request in FileRecoveryView(request: request, library: library) }
        .sheet(item: $artworkRequest) { request in ArtworkEditorView(tracks: request.tracks, library: library, player: player) }
        .sheet(item: $editing) { MetadataEditorView(track: $0, library: library) }
        .alert("New Playlist", isPresented: $showNewPlaylist) {
            TextField("Playlist Name", text: $playlistName)
            Button("Create") {
                let tracks = playlistTracks
                Task {
                    if let playlist = await library.createPlaylist(name: playlistName) {
                        await library.addTracks(tracks, to: playlist)
                    }
                }
            }
            Button("Cancel", role: .cancel) { playlistTracks = [] }
        }
        .alert("Move \(pendingBatchTrash.count) Files to Trash?", isPresented: $showBatchTrashConfirmation) {
            Button("Move to Trash", role: .destructive) {
                let ids = pendingBatchTrash
                pendingBatchTrash.removeAll()
                moveBatchDuplicatesToTrash(ids)
            }
            Button("Cancel", role: .cancel) { pendingBatchTrash.removeAll() }
        } message: {
            let size = page?.tracks.filter { pendingBatchTrash.contains($0.id) }
                .reduce(Int64(0)) { $0 + max(0, $1.fileSize) } ?? 0
            Text("Move \(pendingBatchTrash.count) reviewed files (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))) to macOS Trash? Swar checks that an unselected copy remains in every duplicate group. This cannot guarantee the copies contain identical audio. The operation stops on error and any files already moved remain in Trash.")
        }
        .alert("Move Duplicate to Trash?", isPresented: $showTrashConfirmation) {
            Button("Move to Trash", role: .destructive) {
                if let track = pendingTrashTrack { moveDuplicateToTrash(track) }
                pendingTrashTrack = nil
            }
            Button("Cancel", role: .cancel) { pendingTrashTrack = nil }
        } message: {
            Text("The selected audio file will move to macOS Trash and leave Swar's library and playlists. Other copies stay untouched. Check the file location and quality first.")
        }
        .alert("Remove \(pendingRemoval.count) Songs from Library?", isPresented: $showRemoval) {
            Button("Remove", role: .destructive) { manage(pendingRemoval, restore: false) }
            Button("Cancel", role: .cancel) { pendingRemoval.removeAll() }
        } message: {
            Text("Original files stay in place. Songs leave their playlists and stay excluded from scans. Restore them from Removed.")
        }
    }

    private var header: some View {
        HStack {
            Text("Manage Library").font(.system(size: 26, weight: .semibold, design: .serif))
            Spacer(minLength: 10)
            Button(action: addFolder) { Image(systemName: "folder.badge.plus") }
                .help("Add Folder").accessibilityLabel("Add Folder").disabled(library.isScanning)
            Button { Task { await library.rescan() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Rescan Library").accessibilityLabel("Rescan Library")
                .disabled(library.isScanning || !library.isReady || library.folders.isEmpty)
            if !library.folders.isEmpty {
                Menu {
                    ForEach(library.folders) { folder in
                        Button(folder.path) { recoveryRequest = .folder(folder) }
                    }
                } label: { Image(systemName: "folder.badge.questionmark") }
                    .help("Reconnect Folder").accessibilityLabel("Reconnect Folder")
                    .disabled(library.isScanning || library.isRecovering)
            }
            SettingsLink { Image(systemName: "gearshape") }.help("Folder Settings").accessibilityLabel("Folder Settings")
        }.buttonStyle(.borderless)
    }

    private func metrics(_ summary: CollectionSummary) -> some View {
        HStack(spacing: 20) {
            metric(summary.songs.formatted(), label: "Songs")
            metric(summary.albums.formatted(), label: "Albums")
            metric(ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file), label: "Indexed size")
            metric(durationLabel(summary.duration), label: "Duration")
            Spacer(minLength: 0)
        }
    }
    private func durationLabel(_ duration: Double) -> String {
        guard duration.isFinite, duration >= 0, duration < Double(Int.max) else { return "—" }
        let minutes = Int(duration) / 60
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
    private func metric(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func filters(_ summary: CollectionSummary) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
            ForEach(CollectionFilter.allCases) { item in
                Button { filter = item } label: {
                    HStack {
                        Text(item.rawValue).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(summary.count(item).formatted()).monospacedDigit().fontWeight(.semibold)
                    }.font(.system(size: 12)).padding(10)
                        .foregroundStyle(filter == item ? palette.accent : .primary)
                        .background(filter == item ? palette.accent.opacity(0.1) : SwarTheme.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(filter == item ? palette.accent.opacity(0.2) : .clear))
                }.buttonStyle(.plain).accessibilityAddTraits(filter == item ? .isSelected : [])
                    .accessibilityLabel("\(item.rawValue), \(summary.count(item)) songs")
            }
        }
    }

    private var folders: some View {
        DisclosureGroup("Music Folders (\(library.folders.count))") {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(library.folders) { folder in
                        HStack {
                            Label(URL(fileURLWithPath: folder.path).lastPathComponent, systemImage: "folder")
                            Text(folder.path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(library.folderErrors[folder.id] ?? (library.isMonitoring(folder) ? "Watching" : "Needs attention"))
                                .foregroundStyle(library.folderErrors[folder.id] == nil && library.isMonitoring(folder) ? Color.secondary : .orange)
                                .lineLimit(2)
                            Button("Reconnect…") { recoveryRequest = .folder(folder) }
                                .disabled(library.isScanning || library.isRecovering)
                        }.font(.caption).help(folder.path)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.frame(maxHeight: 100)
        }.font(.caption).foregroundStyle(.secondary)
    }

    private func selectionBar(_ page: CollectionPage) -> some View {
        HStack(spacing: 12) {
            Text(selected.isEmpty ? "\(page.tracks.count) of \(page.count) songs" : "\(selected.count) selected")
                .font(.caption).foregroundStyle(.secondary)
            if filter == .duplicates && matchesContext && page.count > 1 {
                if page.tracks.count == page.count && TrackSearchQuery(library.search).isEmpty {
                    Button("Select Duplicates · Keep One") {
                        selected = DuplicateReview.selectKeepingOne(page.tracks)
                    }
                    .help("Select possible duplicates while retaining the best-quality copy of each group. Review before removing.")
                } else {
                    Text("Load all candidates and clear search to select automatically")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !selected.isEmpty {
                if filter == .removed {
                    Button("Restore") { manage(selected, restore: true) }
                } else {
                    if selected.count == 1, let track = selectedTracks.first {
                        if track.isMissing { Button("Locate File…") { recoveryRequest = .track(track) } }
                        else { Button("Edit Details") { editing = track } }
                    }
                    Button("Artwork…") { artworkRequest = ArtworkEditRequest(tracks: selectedTracks) }
                    Menu("Add to Playlist") {
                        Button("New Playlist…") {
                            playlistTracks = selectedTracks; playlistName = ""; showNewPlaylist = true
                        }
                        Divider()
                        ForEach(library.manualPlaylists) { playlist in
                            Button(playlist.name) {
                                let tracks = selectedTracks
                                Task { await library.addTracks(tracks, to: playlist) }
                            }
                        }
                    }.fixedSize()
                    if filter == .duplicates, selected.count == 1,
                       let candidate = selectedTracks.first, !candidate.isMissing {
                        Button("Move File to Trash…", role: .destructive) {
                            pendingTrashTrack = candidate
                            showTrashConfirmation = true
                        }
                    }
                    if filter == .duplicates && !selected.isEmpty {
                        Button("Move Selected Files to Trash…", role: .destructive) {
                            pendingBatchTrash = selected
                            showBatchTrashConfirmation = true
                        }
                        .disabled(page.tracks.count != page.count || !TrackSearchQuery(library.search).isEmpty)
                    }
                    Button("Remove…") { pendingRemoval = selected; showRemoval = true }
                }
                Button("Clear") { selected.removeAll() }
            }
            Spacer(minLength: 0)
            if library.isScanning { ProgressView().controlSize(.small) }
            if page.tracks.count < page.count { Button("Load More") { limit += 200 } }
        }.controlSize(.small).disabled(working || library.isScanning || library.isRecovering || !matchesContext)
    }

    private func trackTable(_ tracks: [LibraryTrack]) -> some View {
        Table(tracks, selection: $selected) {
            TableColumn("Song") { track in
                HStack(spacing: 9) {
                    CoverArt(url: library.artworkURL(track.artworkKey), title: track.album, cornerRadius: 5, maximumPixelSize: 128).frame(width: density == .compact ? 24 : 30, height: density == .compact ? 24 : 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).fontWeight(.medium).lineLimit(1)
                        Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.padding(.vertical, density == .compact ? 1 : 3)
            }.width(min: 160, ideal: 240)
            TableColumn("Album", value: \.album).width(min: 110, ideal: 170)
            TableColumn("Format") { track in
                Text(filter == .duplicates
                     ? DuplicateReview.details(for: track)
                     : [track.codec, track.sampleRate.map { String(format: "%g kHz", $0 / 1000) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }.width(min: 80, ideal: filter == .duplicates ? 270 : 110)
            TableColumn("Location") { track in
                Text(track.error ?? track.relativePath).lineLimit(1).truncationMode(.middle)
                    .font(.caption).foregroundStyle(track.error == nil ? Color.secondary : .orange)
                    .help((try? library.location(for: track).file.path) ?? track.relativePath)
            }.width(min: 100, ideal: 220)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let track = tracks.first(where: { ids.contains($0.id) }) {
                if track.isMissing { Button("Locate File…") { recoveryRequest = .track(track) }.disabled(library.isScanning || library.isRecovering) }
                if filter != .removed {
                    SongNavigationItems(track: track)
                    Divider()
                    Button("Edit Details…") { editing = track }
                }
                Button("Show in Finder") {
                    do { NSWorkspace.shared.activateFileViewerSelecting([try library.location(for: track).file]) }
                    catch { self.error = error.localizedDescription }
                }
            }
            if !ids.isEmpty {
                if filter != .removed {
                    Menu("Add to Playlist") {
                        Button("New Playlist…") {
                            playlistTracks = tracks.filter { ids.contains($0.id) }; playlistName = ""; showNewPlaylist = true
                        }
                        Divider()
                        ForEach(library.manualPlaylists) { playlist in
                            Button(playlist.name) {
                                let chosen = tracks.filter { ids.contains($0.id) }
                                Task { await library.addTracks(chosen, to: playlist) }
                            }
                        }
                    }
                    Button("Play Next") { LibraryQueueActions.enqueue(tracks.filter { ids.contains($0.id) }, next: true, library: library, player: player) }.disabled(player.isBusy)
                    Button("Play Last") { LibraryQueueActions.enqueue(tracks.filter { ids.contains($0.id) }, next: false, library: library, player: player) }.disabled(player.isBusy)
                    Divider()
                    Button("Edit Album Artwork…") { artworkRequest = ArtworkEditRequest(tracks: tracks.filter { ids.contains($0.id) }) }
                }
                if filter == .duplicates, ids.count == 1,
                   let candidate = tracks.first(where: { ids.contains($0.id) }),
                   !candidate.isMissing {
                    Button("Move File to Trash…", role: .destructive) {
                        pendingTrashTrack = candidate
                        showTrashConfirmation = true
                    }
                }
                if filter == .removed { Button("Restore") { manage(ids, restore: true) } }
                else { Button("Remove from Library…", role: .destructive) { pendingRemoval = ids; showRemoval = true } }
            }
        } primaryAction: { ids in
            if filter != .removed, ids.count == 1, let track = tracks.first(where: { ids.contains($0.id) }) {
                if track.isMissing { recoveryRequest = .track(track) } else { editing = track }
            }
        }
    }

    private func load() async {
        guard library.isReady else { return }
        let generation = UUID()
        loadGeneration = generation
        let requestedFilter = filter, requestedSearch = library.search, requestedScope = library.searchScope
        let requestedLimit = limit
        do {
            if page != nil, loadedSearch != requestedSearch { try await Task.sleep(for: .milliseconds(150)) }
            let result = try await library.collectionPage(filter: requestedFilter, search: requestedSearch, scope: requestedScope, limit: requestedLimit)
            guard !Task.isCancelled, loadGeneration == generation,
                  requestedFilter == filter, requestedSearch == library.search,
                  requestedScope == library.searchScope, requestedLimit == limit else { return }
            loadedFilter = requestedFilter; loadedSearch = requestedSearch; loadedScope = requestedScope
            page = result; error = nil; selected.formIntersection(Set(result.tracks.map(\.id)))
        } catch is CancellationError { }
        catch { guard !Task.isCancelled, loadGeneration == generation else { return }; self.error = error.localizedDescription }
    }
    private func moveBatchDuplicatesToTrash(_ ids: Set<String>) {
        guard !working, filter == .duplicates, !ids.isEmpty else { return }
        working = true
        Task {
            defer { working = false }
            do {
                _ = try await library.moveSelectedDuplicatesToTrash(ids: ids)
                selected.removeAll()
                await load()
            } catch {
                self.error = error.localizedDescription
                selected.removeAll()
                await load()
            }
        }
    }

    private func moveDuplicateToTrash(_ track: LibraryTrack) {
        guard !working, filter == .duplicates else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await library.moveDuplicateToTrash(track)
                selected.removeAll()
                await load()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func manage(_ ids: Set<String>, restore: Bool) {
        guard !working, !ids.isEmpty else { return }
        working = true
        Task {
            defer { working = false }
            do { try await library.manageTracks(ids: ids, restore: restore); selected.removeAll(); await load() }
            catch { self.error = error.localizedDescription }
        }
    }
}

private struct ArtworkEditRequest: Identifiable {
    let id = UUID()
    let tracks: [LibraryTrack]
}
