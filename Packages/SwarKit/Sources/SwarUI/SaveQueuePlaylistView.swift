import SwiftUI
import Library
import Player

@MainActor
struct SaveQueuePlaylistView: View {
    let library: LibraryModel
    let entries: [QueueEntry]
    let onSaved: (LibraryPlaylist) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Saved Queue"
    @State private var draft: QueuePlaylistDraft?
    @State private var failure: String?
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Save Queue as Playlist").font(.title2).fontWeight(.semibold)
            TextField("Playlist name", text: $name)
                .onSubmit { save() }
            if let draft {
                Text("\(draft.trackIDs.count) \(draft.trackIDs.count == 1 ? "song" : "songs") · queue order preserved").font(.subheadline)
                if draft.skippedCount > 0 {
                    Text("\(draft.skippedCount) queue entries aren’t in your library and will be skipped.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if draft.trackIDs.isEmpty {
                    Text("Add these files to your library before saving them in a playlist.").font(.caption)
                }
            } else if failure == nil { ProgressView("Checking library songs…") }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? "Saving…" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || draft?.trackIDs.isEmpty != false || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 390).interactiveDismissDisabled(saving)
            .task {
                do { draft = try await library.queuePlaylistDraft(urls: entries.map(\.url)) }
                catch { failure = error.localizedDescription }
            }
    }

    private func save() {
        guard !saving, let draft, !draft.trackIDs.isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        saving = true
        Task {
            do { onSaved(try await library.saveQueuePlaylist(name: name, draft: draft)) }
            catch { failure = error.localizedDescription; saving = false }
        }
    }
}
