import SwiftUI
import Player
import Library

@MainActor
struct QueueView: View {
    let player: Player
    let library: LibraryModel
    @State private var savingQueue: [QueueEntry]?
    @State private var savedNotice: String?
    private static let dragType = "com.swar.queue-entry"
    var embedded = false

    // Threshold for switching to virtualized list
    private static let virtualizationThreshold = 500

    var body: some View {
        let upcoming = player.upcomingEntries
        let shouldVirtualize = upcoming.count > Self.virtualizationThreshold
        
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Queue").font(.headline)
                Spacer()
                Menu {
                    Button("Save Queue as Playlist…") { savingQueue = player.queue }
                        .disabled(player.queue.isEmpty || !library.isReady)
                    Button("Save Up Next as Playlist…") { savingQueue = player.upcomingEntries }
                        .disabled(upcoming.isEmpty || !library.isReady)
                    Divider()
                    Button("Clear Up Next") { player.clearUpcoming() }
                        .disabled(upcoming.isEmpty)
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Queue options")
                Button("Clear") { player.clearUpcoming() }
                    .disabled(upcoming.isEmpty || player.isBusy)
            }
            if player.canUndoQueueRemoval || savedNotice != nil {
                HStack {
                    if let savedNotice { Text(savedNotice).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                    Spacer()
                    if player.canUndoQueueRemoval {
                        Button(player.queueUndoTitle) { player.undoQueueRemoval() }
                            .help("Restore the last removed queue entries")
                    }
                }
            }
            if let current = player.queue.first(where: { $0.id == player.currentEntryID }) {
                Text("Current Track").font(.caption).foregroundStyle(.secondary)
                row(current, isCurrent: true)
            }
            HStack {
                Text("Up Next").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(upcoming.count) \(upcoming.count == 1 ? "track" : "tracks")").font(.caption).foregroundStyle(.tertiary)
            }
            if upcoming.isEmpty {
                ContentUnavailableView("Nothing Up Next", systemImage: "music.note.list",
                    description: Text("Drop songs here or use Play Next."))
            } else {
                // Use virtualized list for large queues
                if shouldVirtualize {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(upcoming) { entry in
                                queueRow(entry)
                                    .id(entry.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(upcoming) { entry in
                            QueueRowView(entry: entry, player: player, upcoming: upcoming, move: move, dragType: Self.dragType)
                                .listRowBackground(Color.clear)
                                .onDrop(of: [Self.dragType], isTargeted: nil) { providers in
                                    guard !player.isBusy, let provider = providers.first else { return false }
                                    provider.loadDataRepresentation(forTypeIdentifier: Self.dragType) { data, _ in
                                        guard let data, let value = String(data: data, encoding: .utf8), let id = UUID(uuidString: value) else { return }
                                        Task { @MainActor in
                                            let upcoming = player.upcomingEntries
                                            guard let from = upcoming.firstIndex(where: { $0.id == id }),
                                                  let to = upcoming.firstIndex(where: { $0.id == entry.id }), from != to else { return }
                                            player.moveUpcoming(from: IndexSet(integer: from), to: to > from ? to + 1 : to)
                                        }
                                    }
                                    return true
                                }
                        }
                        .onMove { player.moveUpcoming(from: $0, to: $1) }
                    }
                    .listStyle(.plain).scrollContentBackground(.hidden)
                    .disabled(player.isBusy)
                }
            }
            let failures = player.queue.filter { $0.error != nil && $0.id != player.currentEntryID }
            if !failures.isEmpty {
                DisclosureGroup("\(failures.count) failed entries") {
                    ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(failures) { row($0, isCurrent: false) } } }
                        .frame(maxHeight: 120)
                }
            }
        }
        .sheet(isPresented: Binding(get: { savingQueue != nil }, set: { if !$0 { savingQueue = nil } })) {
            if let entries = savingQueue {
                SaveQueuePlaylistView(library: library, entries: entries) { playlist in
                    savedNotice = "Saved as \"" + playlist.name + "\""
                    savingQueue = nil
                }
            }
        }
        .queueSongDrop(library: library, player: player)
        .padding(16)
        .frame(width: embedded ? nil : 380, height: embedded ? nil : 420)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil, alignment: .topLeading)
    }

    private func move(_ entry: QueueEntry, by delta: Int) {
        guard let index = player.upcomingEntries.firstIndex(where: { $0.id == entry.id }) else { return }
        let target = index + delta
        guard player.upcomingEntries.indices.contains(target) else { return }
        player.moveUpcoming(from: IndexSet(integer: index), to: delta > 0 ? target + 1 : target)
    }

    // Virtualized queue row for large queues
    private func queueRow(_ entry: QueueEntry) -> some View {
        HStack(spacing: 10) {
            CoverArt(url: entry.artworkURL, title: entry.subtitle.isEmpty ? entry.title : entry.subtitle, maximumPixelSize: 128)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).fontWeight(.medium).lineLimit(1)
                if !entry.subtitle.isEmpty { Text(entry.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let error = entry.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
        .help(entry.title + (entry.subtitle.isEmpty ? "" : "\n" + entry.subtitle))
    }

    private func row(_ entry: QueueEntry, isCurrent: Bool) -> some View {
        HStack(spacing: 10) {
            CoverArt(url: entry.artworkURL, title: entry.subtitle.isEmpty ? entry.title : entry.subtitle, maximumPixelSize: 128)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).fontWeight(.medium).lineLimit(1)
                if !entry.subtitle.isEmpty { Text(entry.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let error = entry.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(isCurrent ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
        .overlay(isCurrent ? RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 1) : nil)
        .help(entry.title + (entry.subtitle.isEmpty ? "" : "\n" + entry.subtitle))
    }
}

/// Polished queue row with hover effects and integrated controls
private struct QueueRowView: View {
    @Environment(\.swarPalette) private var palette
    let entry: QueueEntry
    let player: Player
    let upcoming: [QueueEntry]
    let move: (QueueEntry, Int) -> Void
    let dragType: String
    
    @State private var isHovered = false
    @FocusState private var isFocused: Bool
    
    private var canMoveUp: Bool { upcoming.first?.id != entry.id }
    private var canMoveDown: Bool { upcoming.last?.id != entry.id }
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.vertical, 12).contentShape(Rectangle())
                .help("Drag to reorder").accessibilityLabel("Drag " + entry.title + " to reorder")
                .onDrag {
                    let provider = NSItemProvider()
                    provider.registerDataRepresentation(forTypeIdentifier: dragType, visibility: .ownProcess) { completion in
                        completion(Data(entry.id.uuidString.utf8), nil)
                        return nil
                    }
                    return provider
                }
                .opacity(isHovered || isFocused ? 1 : 0.5)
            Button { Task { await player.playEntry(entry.id) } } label: { rowContent }
                .buttonStyle(.plain).accessibilityLabel("Play \(entry.title)")
            Spacer(minLength: 4)
            if isHovered || isFocused {
                VStack(spacing: 2) {
                    Button { move(entry, -1) } label: { Image(systemName: "chevron.up").frame(width: 20, height: 16) }
                        .disabled(!canMoveUp)
                        .accessibilityLabel("Move Earlier").help("Move Earlier")
                    Button { move(entry, 1) } label: { Image(systemName: "chevron.down").frame(width: 20, height: 16) }
                        .disabled(!canMoveDown)
                        .accessibilityLabel("Move Later").help("Move Later")
                }
                .font(.system(size: 8, weight: .semibold)).buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                Button { player.removeUpcoming(entry.id) } label: { Image(systemName: "xmark").frame(width: 20, height: 16) }
                    .buttonStyle(.borderless).accessibilityLabel("Remove \(entry.title) from queue")
                    .foregroundStyle(.secondary)
            }
        }
        .listRowBackground(Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .focused($isFocused)
        .animation(.easeInOut(duration: 0.1), value: isHovered)
    }
    
    private var rowContent: some View {
        HStack(spacing: 10) {
            CoverArt(url: entry.artworkURL, title: entry.subtitle.isEmpty ? entry.title : entry.subtitle, maximumPixelSize: 128)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).fontWeight(.medium).lineLimit(1)
                if !entry.subtitle.isEmpty { Text(entry.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                if let error = entry.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
        .help(entry.title + (entry.subtitle.isEmpty ? "" : "\n" + entry.subtitle))
    }
}
