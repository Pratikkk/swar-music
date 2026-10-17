import SwiftUI
import Library

@MainActor
struct MetadataEditorView: View {
    @Environment(\.swarPalette) private var palette
    let track: LibraryTrack
    let library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var metadata: TrackMetadata
    @State private var saving = false
    @State private var hasEdits = false
    @State private var error: String?

    init(track: LibraryTrack, library: LibraryModel) {
        self.track = track; self.library = library
        _metadata = State(initialValue: TrackMetadata(track: track))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit Details").font(.system(size: 24, weight: .semibold, design: .serif))
            Text("Saved in Swar. Original file tags stay unchanged.").font(.caption).foregroundStyle(.secondary)
            Form {
                TextField("Title", text: $metadata.title)
                TextField("Artist", text: $metadata.artist)
                TextField("Album Artist", text: $metadata.albumArtist)
                TextField("Album", text: $metadata.album)
                TextField("Genre", text: $metadata.genre)
                TextField("Year", text: $metadata.year)
                TextField("Track", value: $metadata.trackNumber, format: .number.grouping(.never))
                TextField("Disc", value: $metadata.discNumber, format: .number.grouping(.never))
            }.textFieldStyle(.roundedBorder).disabled(saving)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if hasEdits {
                    Button("Reset to File Details") {
                        saving = true
                        Task {
                            do { try await library.resetMetadata(track); dismiss() }
                            catch { self.error = error.localizedDescription; saving = false }
                        }
                    }.disabled(saving)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save") {
                    saving = true
                    Task {
                        do { try await library.updateMetadata(track, metadata: metadata); dismiss() }
                        catch { self.error = error.localizedDescription; saving = false }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving)
            }
        }
        .padding(24).frame(width: 500).background(SwarTheme.canvas).tint(palette.accent)
        .interactiveDismissDisabled(saving)
        .task { hasEdits = await library.hasMetadataEdits(track) }
    }
}
