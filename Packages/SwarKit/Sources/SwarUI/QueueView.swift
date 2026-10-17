import SwiftUI
import Player

@MainActor
struct QueueView: View {
    let player: Player
    var embedded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Queue").font(.headline)
                Spacer()
                Button("Clear Up Next") { player.clearUpcoming() }
                    .disabled(player.upcomingEntries.isEmpty || player.isBusy)
            }
            if let current = player.queue.first(where: { $0.id == player.currentEntryID }) {
                Text("Current Track").font(.caption).foregroundStyle(.secondary)
                row(current)
            }
            HStack {
                Text("Up Next").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("\(player.upcomingEntries.count) \(player.upcomingEntries.count == 1 ? "track" : "tracks")").font(.caption).foregroundStyle(.tertiary)
            }
            if player.upcomingEntries.isEmpty {
                ContentUnavailableView("Nothing Up Next", systemImage: "music.note.list",
                    description: Text("Use Play Next or Add to Queue on a library track."))
            } else {
                List {
                    ForEach(player.upcomingEntries) { entry in
                        HStack {
                            Button { Task { await player.playEntry(entry.id) } } label: { row(entry) }
                                .buttonStyle(.plain).accessibilityLabel("Play \(entry.title)")
                            Spacer(minLength: 4)
                            VStack(spacing: 3) {
                                Button { move(entry, by: -1) } label: { Image(systemName: "chevron.up").frame(width: 22, height: 18) }
                                    .disabled(player.upcomingEntries.first?.id == entry.id)
                                    .accessibilityLabel("Move \(entry.title) Earlier")
                                    .help("Move Earlier")
                                Button { move(entry, by: 1) } label: { Image(systemName: "chevron.down").frame(width: 22, height: 18) }
                                    .disabled(player.upcomingEntries.last?.id == entry.id)
                                    .accessibilityLabel("Move \(entry.title) Later")
                                    .help("Move Later")
                            }
                            .font(.system(size: 9, weight: .semibold)).buttonStyle(.borderless)
                            Button { player.removeUpcoming(entry.id) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).accessibilityLabel("Remove \(entry.title) from queue")
                        }
                        .listRowBackground(Color.clear)
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
            CoverArt(url: entry.artworkURL, title: entry.subtitle.isEmpty ? entry.title : entry.subtitle)
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
