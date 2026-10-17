import SwiftUI
import Library
import Player
import UniformTypeIdentifiers

@MainActor
struct ArtworkEditorView: View {
    @Environment(\.swarPalette) private var palette
    let tracks: [LibraryTrack]
    let library: LibraryModel
    let player: Player
    @Environment(\.dismiss) private var dismiss
    @State private var wholeAlbum: Bool
    @State private var targets: [LibraryTrack] = []
    @State private var loading = true
    @State private var choosingImage = false
    @State private var importing = false
    @State private var saving = false
    @State private var chosenKey: String?
    @State private var previewKey: String?
    @State private var resetting = false
    @State private var state: ArtworkSelection?
    @State private var error: String?

    init(tracks: [LibraryTrack], library: LibraryModel, player: Player) {
        self.tracks = tracks; self.library = library; self.player = player
        _wholeAlbum = State(initialValue: Set(tracks.map { $0.albumArtist + "\u{1f}" + $0.album }).count == 1)
        _previewKey = State(initialValue: tracks.first?.artworkKey)
    }
    private var sameAlbum: Bool { Set(tracks.map { $0.albumArtist + "\u{1f}" + $0.album }).count == 1 }
    private var busy: Bool { saving || importing || loading }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Album Artwork").font(.system(size: 24, weight: .semibold, design: .serif))
            Text("Saved in your library. Original files stay unchanged.").font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 20) {
                CoverArt(url: library.artworkURL(previewKey), title: tracks.first?.album ?? "Artwork", cornerRadius: 12)
                    .frame(width: 180, height: 180).accessibilityLabel("Artwork preview")
                VStack(alignment: .leading, spacing: 12) {
                    Text(sameAlbum ? (tracks.first?.album ?? "Album") : "Selected songs")
                        .font(.headline).lineLimit(3)
                    if sameAlbum {
                        Text(tracks.first?.albumArtist ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Button("Choose Image…", systemImage: "photo") { choosingImage = true }.disabled(busy)
                    if (state?.customCount ?? 0) > 0 {
                        Button("Reset Artwork") { chosenKey = nil; resetting = true; previewKey = state?.originalKey }
                            .disabled(busy).help("Restore artwork from the latest scan")
                    }
                    if resetting { Text("Original artwork will be restored.").font(.caption).foregroundStyle(.secondary) }
                    if importing { ProgressView().controlSize(.small) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if sameAlbum {
                Picker("Apply to", selection: $wholeAlbum) {
                    Text("Entire album").tag(true)
                    Text("Selected songs").tag(false)
                }.pickerStyle(.segmented).disabled(saving || importing)
            }
            Text(loading ? "Loading songs…" : "\(targets.count) \(targets.count == 1 ? "song" : "songs")")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save") {
                    saving = true
                    Task {
                        do {
                            let changes = try await library.setArtwork(ids: Set(targets.map(\.id)), key: resetting ? nil : chosenKey)
                            player.updateLibraryArtwork(changes)
                            dismiss()
                        } catch { self.error = error.localizedDescription; saving = false }
                    }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(busy || targets.isEmpty || (!resetting && chosenKey == nil))
            }
        }
        .padding(24).frame(width: 540).background(SwarTheme.canvas).tint(palette.accent)
        .interactiveDismissDisabled(saving)
        .task(id: wholeAlbum) { await loadScope() }
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                importing = true; error = nil
                Task {
                    defer { importing = false }
                    do {
                        let key = try await library.importArtwork(url)
                        guard !Task.isCancelled else { return }
                        chosenKey = key; previewKey = key; resetting = false
                    } catch { self.error = error.localizedDescription }
                }
            case .failure(let error): self.error = error.localizedDescription
            }
        }
    }

    private func loadScope() async {
        loading = true
        defer { if !Task.isCancelled { loading = false } }
        guard let reference = tracks.first else { return }
        let scope: [LibraryTrack]
        if wholeAlbum && sameAlbum {
            scope = await library.tracks(in: LibraryAlbumSummary(title: reference.album, artist: reference.albumArtist, artworkKey: reference.artworkKey, trackCount: 0, playableCount: 0))
        } else { scope = tracks }
        do {
            let selection = try await library.artworkSelection(ids: Set(scope.map(\.id)), referenceID: reference.id)
            guard !Task.isCancelled else { return }
            targets = scope; state = selection; error = nil
            if resetting { previewKey = selection.originalKey }
        } catch { guard !Task.isCancelled else { return }; targets = []; self.error = error.localizedDescription }
    }
}
