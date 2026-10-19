import SwiftUI
import AppKit
import Library
import UniformTypeIdentifiers

@MainActor
struct PlaylistExportView: View {
    let library: LibraryModel
    let playlist: LibraryPlaylist
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [PlaylistExportEntry]?
    @State private var relativePaths = false
    @State private var format = "m3u8"
    @State private var failure: String?
    @State private var exporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export Playlist").font(.title2).fontWeight(.semibold)
            Text(playlist.name).font(.headline).lineLimit(2)
            if let entries { Text("\(entries.count) \(entries.count == 1 ? "song" : "songs") · playlist order preserved").font(.subheadline) }
            else if failure == nil { ProgressView("Preparing playlist…") }
            if playlist.isSmart {
                Text("Exports the current matching songs as a regular playlist. Smart Playlist rules aren’t included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Format", selection: $format) {
                Text("M3U8 (UTF-8)").tag("m3u8")
                Text("M3U (UTF-8)").tag("m3u")
            }.disabled(exporting)
            Toggle("Use relative file paths", isOn: $relativePaths).disabled(exporting)
            Text(relativePaths ? "Paths are relative to the exported playlist’s location. Move the playlist and music folders together to keep links working." : "Includes file paths on this Mac. Music files aren’t copied.")
                .font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(exporting)
                Button(exporting ? "Exporting…" : "Export…") { Task { await export() } }
                    .keyboardShortcut(.defaultAction).disabled(exporting || entries == nil)
            }
        }.padding(24).frame(width: 440).interactiveDismissDisabled(exporting)
            .task {
                do {
                    let result = try await library.playlistExportEntries(for: playlist)
                    guard !Task.isCancelled else { return }
                    entries = result
                } catch {
                    guard !Task.isCancelled else { return }
                    failure = error.localizedDescription
                }
            }
    }

    private func export() async {
        guard let entries, !exporting else { return }
        exporting = true
        defer { exporting = false }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format) ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let safeName = playlist.name.components(separatedBy: CharacterSet(charactersIn: "/:\n\r")).joined(separator: "-")
        panel.nameFieldStringValue = (safeName.isEmpty ? "Playlist" : safeName) + "." + format
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let url = panel.url else { return }
        let relative = relativePaths
        do {
            try await Task.detached(priority: .utility) { try PlaylistFile.write(entries, to: url, relativePaths: relative) }.value
            dismiss()
        } catch { failure = error.localizedDescription }
    }
}
