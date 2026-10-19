import SwiftUI
import Library
import UniformTypeIdentifiers

@MainActor
struct PlaylistImportView: View {
    let library: LibraryModel
    let onImported: (LibraryPlaylist) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = true
    @State private var selectionRevision = UUID()
    @State private var url: URL?
    @State private var preview: PlaylistImportPreview?
    @State private var name = ""
    @State private var failure: String?
    @State private var saving = false
    static var types: [UTType] {
        [UTType(filenameExtension: "m3u") ?? .plainText, UTType(filenameExtension: "m3u8") ?? .plainText]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Import Playlist").font(.title2).fontWeight(.semibold)
                Spacer()
                Button("Choose File…") { choosing = true }.disabled(saving)
            }
            if let preview {
                TextField("Playlist name", text: $name).disabled(saving)
                Text("\(preview.draft.trackIDs.count) matched · \(preview.draft.skippedCount) unmatched")
                    .font(.subheadline).monospacedDigit()
                Text("Only matched songs already in your library will be added. Unmatched entries are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
                List(preview.items) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.track?.title ?? item.entry.url?.lastPathComponent ?? item.entry.source).lineLimit(1)
                            Text(item.track?.artist ?? item.entry.source).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(item.track != nil ? "Matched" : item.entry.url == nil ? "Unsupported" : "Not in library")
                            .font(.caption).foregroundStyle(item.track != nil ? Color.secondary : .orange)
                    }.help(item.entry.source)
                }.listStyle(.inset)
                if preview.items.isEmpty { Text("No songs were found in this playlist.").font(.caption).foregroundStyle(.secondary) }
            } else if url != nil && failure == nil {
                ProgressView("Matching songs…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("Choose an M3U or M3U8 playlist", systemImage: "music.note.list")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button(saving ? "Importing…" : "Import") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(saving || preview?.draft.trackIDs.isEmpty != false || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 560, height: 470).interactiveDismissDisabled(saving)
            .fileImporter(isPresented: $choosing, allowedContentTypes: Self.types) { result in
                switch result {
                case .success(let selected):
                    preview = nil; failure = nil; url = selected; selectionRevision = UUID()
                case .failure(let error): failure = error.localizedDescription
                }
            }
            .task(id: selectionRevision) {
                guard let url else { return }
                preview = nil; failure = nil
                do {
                    let result = try await library.previewPlaylistImport(from: url)
                    guard !Task.isCancelled else { return }
                    preview = result; name = result.name
                } catch {
                    guard !Task.isCancelled else { return }
                    failure = error.localizedDescription
                }
            }
    }

    private func save() {
        guard !saving, let preview, !preview.draft.trackIDs.isEmpty else { return }
        saving = true
        Task {
            do { onImported(try await library.saveQueuePlaylist(name: name, draft: preview.draft)) }
            catch { failure = error.localizedDescription; saving = false }
        }
    }
}
