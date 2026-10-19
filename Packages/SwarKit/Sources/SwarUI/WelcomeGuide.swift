import SwiftUI
import UniformTypeIdentifiers
import Library

/// Decide only after the saved library has loaded, so upgrades do not look like fresh installs.
enum WelcomeGuidePolicy {
    enum Action: Equatable { case wait, present, acknowledgeExisting, none }
    static func action(completed: Bool, ready: Bool, folderCount: Int, trackCount: Int) -> Action {
        guard !completed else { return .none }
        guard ready else { return .wait }
        return folderCount == 0 && trackCount == 0 ? .present : .acknowledgeExisting
    }
}

extension Notification.Name {
    static let showWelcomeGuide = Notification.Name("catto.swar.showWelcomeGuide")
}

@MainActor
private struct WelcomeGuideHost: ViewModifier {
    let library: LibraryModel
    @AppStorage("welcomeGuideCompleted") private var completed = false
    @State private var presented = false

    func body(content: Content) -> some View {
        content
            .task(id: library.isReady) {
                switch WelcomeGuidePolicy.action(completed: completed, ready: library.isReady,
                    folderCount: library.folders.count, trackCount: library.totalCount) {
                case .present: presented = true
                case .acknowledgeExisting: completed = true
                case .wait, .none: break
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .showWelcomeGuide)) { _ in presented = true }
            .sheet(isPresented: $presented, onDismiss: { completed = true }) {
                WelcomeGuideView(library: library) {
                    completed = true
                    presented = false
                }
            }
    }
}

public extension View {
    @MainActor func welcomeGuide(library: LibraryModel) -> some View {
        modifier(WelcomeGuideHost(library: library))
    }
}

@MainActor
struct WelcomeGuideView: View {
    let library: LibraryModel
    let finish: () -> Void
    @Environment(\.swarPalette) private var palette
    @State private var step = 0
    @State private var showPicker = false
    @State private var adding = false
    @State private var importError: String?
    private let steps = ["Add music", "Explore", "Listen"]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 8) {
                ForEach(steps.indices, id: \.self) { index in
                    HStack(spacing: 6) {
                        Image(systemName: index < step ? "checkmark.circle.fill" : "\(index + 1).circle\(index == step ? ".fill" : "")")
                        Text(steps[index]).font(.callout.weight(index == step ? .semibold : .regular))
                    }
                    .foregroundStyle(index == step ? palette.accent : Color.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Step \(index + 1) of 3: \(steps[index])\(index == step ? ", current" : "")")
                    if index < 2 { Rectangle().fill(.separator).frame(height: 1).padding(.horizontal, 8) }
                }
            }
            .accessibilityElement(children: .contain)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: ["folder.badge.plus", "square.stack", "headphones"][step])
                        .font(.system(size: 34, weight: .light)).foregroundStyle(palette.accent)
                        .frame(width: 64, height: 64)
                        .background(palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 18))
                        .accessibilityHidden(true)
                    Text(["Welcome to your music", "Make it your collection", "Ready to listen"][step])
                        .font(.system(size: 28, weight: .bold)).accessibilityAddTraits(.isHeader)
                    switch step {
                    case 0: addMusic
                    case 1:
                        tip("square.grid.2x2", "Find your music", "Browse Albums, Artists, or Songs. Search with ⌘F and narrow results by title, artist, or album.")
                        tip("music.note.list", "Build a playlist", "Use the + beside Playlists, then drag songs onto it. Right-click songs for more actions.")
                        tip("star", "Keep favourites close", "Mark favourites and revisit your listening history from the sidebar.")
                    default:
                        tip("play.circle", "Start with an album", "Hover over artwork to play, or open an album and choose Play or Shuffle.")
                        tip("text.line.first.and.arrowtriangle.forward", "Choose what’s next", "Drop songs onto the queue icon in the floating player. Open Up Next to reorder them.")
                        tip("hifispeaker", "Choose your output", "Use the speaker icon in the floating player to select headphones or a DAC. Open artwork for the expanded player.")
                        Text("Make it yours in Settings (⌘,): appearance, sidebar layout, and Now Playing.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
            }
            .frame(maxHeight: .infinity)

            Divider()
            HStack {
                Button("Not Now", action: finish).keyboardShortcut(.cancelAction)
                Spacer()
                if step > 0 { Button("Back") { step -= 1 } }
                Button(step == 2 ? "Start Listening" : "Continue") {
                    if step == 2 { finish() } else { step += 1 }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(28).frame(width: 580, height: 570)
        .background(SwarTheme.canvas)
        .tint(palette.accent)
        .fileImporter(isPresented: $showPicker, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                adding = true; importError = nil
                Task {
                    await library.addFolder(url)
                    importError = library.errorMessage
                    adding = false
                }
            case .failure(let error): importError = error.localizedDescription
            }
        }
    }

    private var addMusic: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a folder with your music. Subfolders are included, and new or changed songs update automatically while the app is open.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Choose Music Folder…", systemImage: "folder.badge.plus") { showPicker = true }
                .controlSize(.large).disabled(!library.isReady || library.isScanning || adding)
            if adding || library.isScanning {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    if let progress = library.progress {
                        Text("Adding music · \(progress.completed) of \(progress.total) files")
                    } else { Text("Adding your music…") }
                }.font(.callout).foregroundStyle(.secondary)
            } else if !library.folders.isEmpty {
                Label("\(library.totalCount) \(library.totalCount == 1 ? "song" : "songs") in your library", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(palette.accent)
                if library.totalCount == 0 {
                    Text("No songs found yet. Choose another folder, or add files to the folder you selected.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let importError {
                Label(importError, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            tip("externaldrive", "Your files stay where they are", "Nothing is copied or moved. You can manage watched folders later in Settings → Files.")
            Text("You can skip setup and reopen this guide from Help → Welcome Guide.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func tip(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(palette.accent).frame(width: 24).font(.title3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
