import SwiftUI
import Library
import Player

@MainActor
struct ListeningHistoryView: View {
    let library: LibraryModel
    let player: Player
    @Environment(\.floatingPlayerClearance) private var clearance
    @State private var mode: ListeningMode = .recent
    @State private var overview: ListeningOverview?
    @State private var limit = 100
    @State private var failure: String?
    @State private var confirmClear = false

    private var request: String {
        "\(mode.rawValue)-\(limit)-\(library.isReady)-\(library.listeningRevision)-\(library.overviewRevision)-\(library.lastScanAt?.timeIntervalSince1970 ?? 0)-\(library.search)-\(library.searchScope)"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Listening").font(.system(size: 32, weight: .semibold, design: .serif))
                    Spacer()
                    Button("Clear History…") { confirmClear = true }
                        .disabled((overview?.totalPlays ?? 0) == 0)
                }
                if let overview {
                    Text("\(overview.totalPlays.formatted()) plays · \(overview.uniqueSongs.formatted()) songs")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Picker("Browse listening history", selection: $mode) {
                    ForEach(ListeningMode.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 600)
                Text(mode == .forgotten ? "Favourites you haven’t played in 30 days, including songs you haven’t played yet." : "A play counts after 30 seconds, or halfway through a shorter song. Stored only on this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                if let failure {
                    Text(failure).foregroundStyle(.orange)
                    Button("Try Again") { Task { await load() } }
                } else if let overview {
                    let songs = overview.songs
                    if songs.isEmpty {
                        ContentUnavailableView(mode == .forgotten ? "All caught up" : "No listening history yet",
                            systemImage: mode == .forgotten ? "star" : "clock.arrow.circlepath",
                            description: Text(library.search.isEmpty ? "Listen to songs in your library to build your history." : "No songs match your search."))
                    }
                    LazyVStack(spacing: 2) {
                        ForEach(songs) { song in songRow(song) }
                    }
                    if overview.songs.count < overview.matchedCount && limit < 10000 {
                        Button("Show More") { limit += 100 }.frame(maxWidth: .infinity)
                    }
                } else { ProgressView().padding(30) }
            }.padding(28).padding(.bottom, clearance)
        }
        .task(id: request) {
            if !library.search.isEmpty {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            await load()
        }
        .onChange(of: mode) { _, _ in limit = 100 }
        .confirmationDialog("Clear listening history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) {
                Task {
                    do { try await library.clearListeningHistory() }
                    catch { failure = error.localizedDescription }
                }
            }
        } message: { Text("This resets play counts and last-played dates. Your music, playlists and favourites are kept.") }
    }

    private func songRow(_ song: ListeningSong) -> some View {
        Button { play(song.track) } label: {
            HStack(spacing: 12) {
                CoverArt(url: library.artworkURL(song.track.artworkKey), title: song.track.title,
                         cornerRadius: 7, maximumPixelSize: 128).frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.track.title).fontWeight(.medium).lineLimit(1)
                    Text(song.track.artist + " · " + song.track.album).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("\(song.playCount) \(song.playCount == 1 ? "play" : "plays")")
                    if let date = song.lastPlayed { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) }
                    else { Text("Not played yet").font(.caption).foregroundStyle(.secondary) }
                }.monospacedDigit()
            }.padding(10).contentShape(Rectangle())
        }.buttonStyle(PlaybackButtonStyle(unavailable: song.track.error != nil))
            .disabled(player.isBusy || song.track.error != nil)
            .help(song.track.error ?? "Play " + song.track.title)
            .songActions(library: library, track: song.track, busy: player.isBusy,
                play: { play(song.track) }, showsButton: true,
                enqueue: { LibraryQueueActions.enqueue([song.track], next: $0, library: library, player: player) })
    }

    private func play(_ track: LibraryTrack) {
        Task {
            do {
                let location = try library.location(for: track)
                await player.play([QueueEntry(url: location.file, accessRoot: location.root, title: track.title,
                    subtitle: track.artist + " · " + track.album, artworkURL: library.artworkURL(track.artworkKey),
                    artist: track.artist, album: track.album)])
            } catch { player.reportImportError(error) }
        }
    }

    private func load() async {
        guard library.isReady else { return }
        do {
            let result = try await library.listening(mode, limit: limit)
            guard !Task.isCancelled else { return }
            overview = result; failure = nil
        } catch {
            guard !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }
}
