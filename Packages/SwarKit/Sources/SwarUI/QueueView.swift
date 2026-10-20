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

    var body: some View {
        let upcoming = player.upcomingEntries
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
                row(current)
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
                List {
                    ForEach(upcoming) { entry in
                        HStack {
                            Image(systemName: "line.3.horizontal")
                                .font(.caption).foregroundStyle(.tertiary)
                                .padding(.vertical, 12).contentShape(Rectangle())
                                .help("Drag to reorder").accessibilityLabel("Drag " + entry.title + " to reorder")
                                .onDrag {
                                    let provider = NSItemProvider()
                                    provider.registerDataRepresentation(forTypeIdentifier: Self.dragType, visibility: .ownProcess) { completion in
                                        completion(Data(entry.id.uuidString.utf8), nil)
                                        return nil
                                    }
                                    return provider
                                }
                            Button { Task { await player.playEntry(entry.id) } } label: { row(entry) }
                                .buttonStyle(.plain).accessibilityLabel("Play \(entry.title)")
                            Spacer(minLength: 4)
                            VStack(spacing: 3) {
                                Button { move(entry, by: -1) } label: { Image(systemName: "chevron.up").frame(width: 22, height: 18) }
                                    .disabled(upcoming.first?.id == entry.id)
                                    .accessibilityLabel("Move \(entry.title) Earlier")
                                    .help("Move Earlier")
                                Button { move(entry, by: 1) } label: { Image(systemName: "chevron.down").frame(width: 22, height: 18) }
                                    .disabled(upcoming.last?.id == entry.id)
                                    .accessibilityLabel("Move \(entry.title) Later")
                                    .help("Move Later")
                            }
                            .font(.system(size: 9, weight: .semibold)).buttonStyle(.borderless)
                            Button { player.removeUpcoming(entry.id) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).accessibilityLabel("Remove \(entry.title) from queue")
                        }
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
            let failures = player.queue.filter { $0.error != nil && $0.id != player.currentEntryID }
            if !failures.isEmpty {
                DisclosureGroup("\(failures.count) failed entries") {
                    ScrollView { VStack(alignment: .leading, spacing: 8) { ForEach(failures) { row($0) } } }
                        .frame(maxHeight: 120)
                }
            }
        }
        .sheet(isPresented: Binding(get: { savingQueue != nil }, set: { if !$0 { savingQueue = nil } })) {
            if let entries = savingQueue {
                SaveQueuePlaylistView(library: library, entries: entries) { playlist in
                    savedNotice = "Saved as “" + playlist.name + "”"
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

    private func row(_ entry: QueueEntry) -> some View {
        HStack(spacing: 10) {
            CoverArt(url: entry.artworkURL, title: entry.subtitle.isEmpty ? entry.title : entry.subtitle, maximumPixelSize: 128)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 3) {
            Text(entry.title).fontWeight(.medium).lineLimit(1)
            if !entry.subtitle.isEmpty { Text(entry.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if let error = entry.error { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }
        .padding(.vertical, 3)
        .help(entry.title + (entry.subtitle.isEmpty ? "" : "\n" + entry.subtitle))
    }
}
