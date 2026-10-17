import SwiftUI
import Library
import UniformTypeIdentifiers

/// Settings and browsing share the same model, watchers, and security-scoped access.
@MainActor
public struct LibrarySettingsView: View {
    @Environment(\.swarPalette) private var palette
    let library: LibraryModel
    @State private var showFolderPicker = false
    @State private var folderToRemove: LibraryFolder?
    @State private var showRemoveConfirmation = false
    @State private var pickerError: String?

    public init(library: LibraryModel) { self.library = library }

    public var body: some View {
        TabView {
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            NowPlayingSettingsView()
                .tabItem { Label("Now Playing", systemImage: "play.rectangle") }
            files
                .tabItem { Label("Files", systemImage: "folder") }
        }
        .frame(width: 620, height: 470)
        .tint(palette.accent)
        .accentColor(palette.accent)
        .task { await library.start() }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                pickerError = nil
                Task { await library.addFolder(url) }
            case .failure(let error):
                pickerError = error.localizedDescription
            }
        }
        .alert("Remove Monitored Folder?", isPresented: $showRemoveConfirmation) {
            Button("Remove", role: .destructive) {
                if let folder = folderToRemove { Task { await library.removeFolder(folder) } }
                folderToRemove = nil
            }
            Button("Cancel", role: .cancel) { folderToRemove = nil }
        } message: {
            Text("Songs in this folder will be removed from the library and its playlists. Files on disk stay untouched.")
        }
    }

    private var files: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Music Folders").font(.title2.bold())
                Text("Choose the folders to include in your library.")
                    .foregroundStyle(.secondary)
            }
            List {
                if library.folders.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("No music folders selected", systemImage: "folder.badge.plus").font(.headline)
                        Text("Add a folder to import your music and monitor it for changes.")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding(.vertical, 16)
                }
                ForEach(library.folders) { folder in folderRow(folder) }
            }
            .listStyle(.inset).frame(minHeight: 140)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator.opacity(0.5)))
            HStack {
                Button("Add Folder…", systemImage: "folder.badge.plus") { showFolderPicker = true }
                    .disabled(!library.isReady || library.isScanning)
                if library.hiddenTrackCount > 0 {
                    Button("Restore Removed Songs (\(library.hiddenTrackCount))") { Task { await library.restoreRemovedTracks() } }
                        .disabled(library.isScanning)
                }
                Spacer()
                if library.isScanning { ProgressView().controlSize(.small) }
                Button("Rescan Now", systemImage: "arrow.clockwise") { Task { await library.rescan() } }
                    .disabled(!library.isReady || library.isScanning || library.folders.isEmpty)
            }
            scanStatus
            Text("While the app is open, new, changed, and removed audio files update automatically, including files in subfolders. Saved folders are checked again on launch. Music stays in its original location.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = pickerError ?? library.errorMessage {
                Text(error).font(.caption).foregroundStyle(.orange).lineLimit(3).textSelection(.enabled)
            }
        }
        .padding(24)
    }

    private func folderRow(_ folder: LibraryFolder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill").font(.title2).foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(URL(fileURLWithPath: folder.path).lastPathComponent).fontWeight(.medium)
                Text(folder.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(folder.path).textSelection(.enabled)
                if let error = library.folderErrors[folder.id] {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        .font(.caption).lineLimit(2)
                } else if library.isMonitoring(folder) {
                    Label("Monitoring automatically", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.secondary).font(.caption)
                } else {
                    Label("Monitoring unavailable · Remove and add this folder again", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).font(.caption).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button {
                folderToRemove = folder
                showRemoveConfirmation = true
            } label: { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless).disabled(library.isScanning)
            .accessibilityLabel("Remove \(URL(fileURLWithPath: folder.path).lastPathComponent) from library")
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var scanStatus: some View {
        if let progress = library.progress {
            Text("Checking \(progress.folder): \(progress.completed) of \(progress.total) files")
                .font(.caption).foregroundStyle(.secondary)
        } else if let date = library.lastScanAt {
            Text("Last checked \(date.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        } else if !library.isReady {
            Text("Preparing library…").font(.caption).foregroundStyle(.secondary)
        }
    }
}
