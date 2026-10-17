import SwiftUI
import AppKit
import Library
import Player

/// The lookup is keyed by track identity/library changes, never the playback clock.
@MainActor
private struct CurrentSongActions: ViewModifier {
    let library: LibraryModel
    let player: Player
    let showsButton: Bool
    @State private var track: LibraryTrack?
    @State private var resolvedURL: URL?

    func body(content: Content) -> some View {
        Group {
            if let track, resolvedURL == player.currentURL {
                content.songActions(library: library, track: track, busy: player.isBusy,
                    play: { Task { await player.togglePlayback() } }, playLabel: player.isPlaying ? "Pause" : (player.isRestoredSession ? "Resume" : "Play"), showsButton: showsButton,
                    enqueue: { LibraryQueueActions.enqueue([track], next: $0, library: library, player: player) })
            } else if showsButton {
                Menu { standaloneItems } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel("Current song actions").disabled(player.currentURL == nil)
            } else {
                content.contextMenu { standaloneItems }
            }
        }
        .task(id: "\(player.currentURL?.absoluteString ?? "")-\(library.isReady)-\(library.overviewRevision)-\(library.trackActionsRevision)") {
            let url = player.currentURL
            let result = if let url { await library.track(at: url) } else { nil as LibraryTrack? }
            guard !Task.isCancelled, player.currentURL == url else { return }
            track = result; resolvedURL = url
        }
    }

    @ViewBuilder private var standaloneItems: some View {
        if let url = player.currentURL {
            Button(player.isPlaying ? "Pause" : "Play", systemImage: player.isPlaying ? "pause.fill" : "play.fill") {
                Task { await player.togglePlayback() }
            }.disabled(player.isBusy)
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Copy File Path", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
        }
    }
}

extension View {
    @MainActor func currentSongActions(library: LibraryModel, player: Player, showsButton: Bool = false) -> some View {
        modifier(CurrentSongActions(library: library, player: player, showsButton: showsButton))
    }
}
