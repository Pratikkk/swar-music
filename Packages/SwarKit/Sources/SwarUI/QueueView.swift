import SwiftUI
import Player

@MainActor
struct QueueView: View {
    let player: Player

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
            Text("Up Next").font(.caption).foregroundStyle(.secondary)
            if player.upcomingEntries.isEmpty {
                ContentUnavailableView("Nothing Up Next", systemImage: "music.note.list",
                    description: Text("Use Play Next or Add to Queue on a library track."))
            } else {
                List {
                    ForEach(player.upcomingEntries) { entry in
                        HStack {
                            Button { Task { await player.playEntry(entry.id) } } label: { row(entry) }
                                .buttonStyle(.plain).accessibilityLabel("Play \(entry.title)")
                            Spacer()
                            Button { player.removeUpcoming(entry.id) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.borderless).accessibilityLabel("Remove \(entry.title) from queue")
                        }
                    }
                    .onMove { player.moveUpcoming(from: $0, to: $1) }
                }
                .listStyle(.inset)
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
        .padding(16).frame(width: 380, height: 420)
    }

    private func row(_ entry: QueueEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(entry.title).fontWeight(.medium).lineLimit(1)
            if !entry.subtitle.isEmpty { Text(entry.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            if let error = entry.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
}
