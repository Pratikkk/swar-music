import SwiftUI
import Decoding
import Library
import Player

@MainActor
struct RhythmAnalysisView: View {
    let track: LibraryTrack
    let library: LibraryModel
    @State private var requested = 0
    @State private var loading = false
    @State private var profile: RhythmProfile?
    @State private var failure: String?
    @Environment(\.libraryPlayer) private var player
    @State private var previewRequest = 0
    @State private var preview: TransitionPlan?
    @State private var previewLoading = false
    @State private var previewFailure: String?

    private var previewKey: String {
        "\(previewRequest)|\(player?.currentURL?.absoluteString ?? "")|\(player?.upcomingEntries.first?.id.uuidString ?? "")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let profile {
                    Text(profile.bpm.map { String(format: "Estimated tempo: %.1f BPM", $0) } ?? "Tempo uncertain")
                    Spacer()
                    Text(profile.confidence >= 0.7 ? "Strong rhythm" : profile.confidence >= 0.4 ? "Moderate rhythm" : "Weak rhythm")
                        .foregroundStyle(.secondary)
                } else if loading {
                    ProgressView().controlSize(.small)
                    Text("Analyzing rhythm…").foregroundStyle(.secondary)
                } else {
                    Button("Analyze Rhythm", systemImage: "waveform.path") { requested += 1 }
                        .disabled(track.error != nil || track.isMissing)
                }
            }
            if let failure {
                Text(failure).font(.caption).foregroundStyle(.secondary)
                Button("Try Again") { requested += 1 }
            } else if profile != nil {
                Text("Estimate only; half/double tempo is possible. Playback is unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let player, library.trackID(at: player.currentURL) == track.id, !player.upcomingEntries.isEmpty {
                Button(previewLoading ? "Planning…" : "Preview Next Transition") { previewRequest += 1 }
                    .disabled(previewLoading)
                if let preview {
                    Text(preview.mode == .beatAligned
                         ? "Beat-aligned · \(preview.beats) beats · \(String(format: "%.1f", preview.duration)) seconds"
                         : preview.mode == .adaptiveFade ? "Short fade · \(String(format: "%.1f", preview.duration)) seconds" : "Keep gapless")
                        .font(.caption)
                    Text(preview.reason == .continuousAlbum ? "Consecutive album tracks stay gapless. Preview only."
                         : preview.mode == .beatAligned ? "Compatible observed beats. Preview only; playback is unchanged."
                         : "No safe beat-aligned overlap found. Preview only; playback is unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let previewFailure { Text(previewFailure).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task(id: requested) {
            guard requested > 0 else { return }
            loading = true; failure = nil
            defer { loading = false }
            do {
                let location = try library.location(for: track)
                let result = try await RhythmStore.shared.profile(url: location.file, accessRoot: location.root)
                guard !Task.isCancelled else { return }
                profile = result
            } catch is CancellationError { }
            catch { guard !Task.isCancelled else { return }; failure = error.localizedDescription }
        }
        .task(id: previewKey) {
            preview = nil; previewFailure = nil
            guard previewRequest > 0, let player, library.trackID(at: player.currentURL) == track.id,
                  let next = player.upcomingEntries.first else { return }
            previewLoading = true
            defer { previewLoading = false }
            do {
                guard let nextTrack = await library.track(at: next.url) else {
                    throw AudioFailure("The next song must be in the library to preview a transition.")
                }
                let consecutive = !track.album.isEmpty && track.album == nextTrack.album
                    && track.albumArtist == nextTrack.albumArtist && track.discNumber == nextTrack.discNumber
                    && track.trackNumber > 0 && nextTrack.trackNumber == track.trackNumber + 1
                let currentLocation = try library.location(for: track)
                let nextLocation = try library.location(for: nextTrack)
                // A continuous album needs no decoding merely to decide to preserve it.
                let outgoing = consecutive ? nil : try await RhythmStore.shared.profile(url: currentLocation.file, accessRoot: currentLocation.root)
                let incoming = consecutive ? nil : try await RhythmStore.shared.profile(url: nextLocation.file, accessRoot: nextLocation.root)
                guard !Task.isCancelled, library.trackID(at: player.currentURL) == track.id,
                      player.upcomingEntries.first?.id == next.id else { return }
                preview = TransitionPlanner.plan(outgoing: outgoing, incoming: incoming,
                    outgoingDuration: track.duration, incomingDuration: nextTrack.duration,
                    notBefore: player.position, preserveGapless: consecutive)
            } catch is CancellationError { }
            catch { guard !Task.isCancelled else { return }; previewFailure = error.localizedDescription }
        }
    }
}
