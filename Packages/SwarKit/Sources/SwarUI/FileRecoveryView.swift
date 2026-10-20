import SwiftUI
import Library
import UniformTypeIdentifiers

enum FileRecoveryRequest: Identifiable {
    case track(LibraryTrack)
    case folder(LibraryFolder)
    var id: String {
        switch self { case .track(let track): "track-" + track.id; case .folder(let folder): "folder-" + folder.id }
    }
    var isFolder: Bool { if case .folder = self { true } else { false } }
    var name: String {
        switch self { case .track(let track): track.title; case .folder(let folder): URL(fileURLWithPath: folder.path).lastPathComponent }
    }
    var path: String {
        switch self { case .track(let track): track.relativePath; case .folder(let folder): folder.path }
    }
}

struct FileRecoveryView: View {
    let request: FileRecoveryRequest
    let library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var replacement: URL?
    @State private var scoped = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.isFolder ? "Reconnect Folder" : "Locate File").font(.title2.weight(.semibold))
            Text(request.name).font(.headline).lineLimit(2)
            Text(request.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            Text(request.isFolder
                 ? "Choose the folder containing your original album and song paths. Swar will check its contents and keep your playlists, favourites, and listening history."
                 : "Choose this song’s new file inside a watched music folder. Its library details, playlists, favourites, and listening history will be kept. If already indexed, the entries will be combined.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let replacement {
                Label(replacement.path, systemImage: request.isFolder ? "folder" : "music.note")
                    .font(.callout).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
            }
            Button(replacement == nil ? "Choose…" : "Choose Another…") { choosing = true }
            if let error { Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Reconnect") { reconnect() }.keyboardShortcut(.defaultAction)
                    .disabled(replacement == nil || library.isScanning || library.isRecovering)
            }
        }
        .padding(24).frame(width: 460).disabled(working).interactiveDismissDisabled(working)
        .fileImporter(isPresented: $choosing, allowedContentTypes: request.isFolder ? [.folder] : [.item]) { result in
            do {
                let url = try result.get()
                releaseScope()
                replacement = url
                scoped = url.startAccessingSecurityScopedResource()
                error = nil
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear { releaseScope() }
    }

    private func releaseScope() {
        if scoped { replacement?.stopAccessingSecurityScopedResource() }
        scoped = false
    }
    private func reconnect() {
        guard let replacement, !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                switch request {
                case .track(let track): try await library.reconnectTrack(track, to: replacement)
                case .folder(let folder): try await library.reconnectFolder(folder, to: replacement)
                }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}
