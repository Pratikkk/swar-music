import Foundation

/// Pure presentation model for uninterrupted album listening.
/// Maintains the source album order; no audio engine state is duplicated.
public struct AlbumListeningPlan: Sendable {
    public let playableTracks: [LibraryTrack]
    public let duration: TimeInterval

    public init(tracks: [LibraryTrack]) {
        playableTracks = tracks.filter { !$0.isMissing && $0.error == nil }
        duration = playableTracks.reduce(0) { total, track in
            total + (track.duration.isFinite ? max(0, track.duration) : 0)
        }
    }

    public func position(for trackID: String?) -> Int? {
        guard let trackID else { return nil }
        return playableTracks.firstIndex(where: { $0.id == trackID }).map { $0 + 1 }
    }
}
