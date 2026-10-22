import SwiftUI
import Library

/// Bulk edits deliberately affect Swar's library database, never source tags.
@MainActor
struct BulkMetadataEditorView: View {
    let tracks: [LibraryTrack]
    let library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var album = ""
    @State private var albumArtist = ""
    @State private var artist = ""
    @State private var genre = ""
    @State private var year = ""
    @State private var discNumber = 1
    @State private var changeAlbum = false
    @State private var changeAlbumArtist = false
    @State private var changeArtist = false
    @State private var changeGenre = false
    @State private var changeYear = false
    @State private var changeDisc = false
    @State private var saving = false
    @State private var error: String?

    private var patch: BulkMetadataPatch {
        BulkMetadataPatch(album: changeAlbum ? album : nil,
                          albumArtist: changeAlbumArtist ? albumArtist : nil,
                          artist: changeArtist ? artist : nil,
                          genre: changeGenre ? genre : nil,
                          year: changeYear ? year : nil,
                          discNumber: changeDisc ? discNumber : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Multiple Songs").font(.title2.bold())
            Text("\(tracks.count) selected songs · Library only. Source file tags will not change.")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                field("Album", enabled: $changeAlbum, value: $album)
                field("Album Artist", enabled: $changeAlbumArtist, value: $albumArtist)
                field("Artist", enabled: $changeArtist, value: $artist)
                field("Genre", enabled: $changeGenre, value: $genre)
                field("Year", enabled: $changeYear, value: $year)
                HStack {
                    Toggle("Disc Number", isOn: $changeDisc).frame(width: 150)
                    TextField("Disc Number", value: $discNumber, format: .number.grouping(.never))
                        .disabled(!changeDisc)
                }
            }.disabled(saving)
            Divider()
            Text("Preview").font(.headline)
            if patch.isEmpty {
                Text("Enable a field to apply it to every selected song. Unchecked fields are preserved.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(tracks.prefix(5)), id: \.id) { track in
                    let updated = try? patch.applying(to: track)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).font(.caption.bold())
                        Text(updated.map { "\($0.artist) · \($0.album) · \($0.genre) · \($0.year)" } ?? "Invalid metadata values")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if tracks.count > 5 {
                    Text("…and \(tracks.count - 5) more songs").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error { Text(error).foregroundStyle(.orange).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.disabled(saving)
                Button("Apply to \(tracks.count) Songs") {
                    saving = true
                    Task {
                        do {
                            try await library.bulkUpdateMetadata(tracks, patch: patch)
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                            saving = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving || patch.isEmpty || tracks.contains { (try? patch.applying(to: $0)) == nil })
            }
        }
        .padding(22)
        .frame(width: 540)
        .interactiveDismissDisabled(saving)
    }

    private func field(_ name: String, enabled: Binding<Bool>, value: Binding<String>) -> some View {
        HStack {
            Toggle(name, isOn: enabled).frame(width: 150)
            TextField(name, text: value).disabled(!enabled.wrappedValue)
        }
    }
}
