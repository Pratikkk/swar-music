import Foundation

/// Counts audible progress, bounded by elapsed time, rather than seek distance.
struct ListenCounter {
    private var listened: Double = 0
    private var counted = false
    private var previous: (time: Double, position: Double, playing: Bool)?

    mutating func interrupt() { previous = nil }

    mutating func sample(time: Double, position: Double, duration: Double, playing: Bool) -> Bool {
        guard time.isFinite, position.isFinite, duration.isFinite, duration > 0 else {
            previous = nil
            return false
        }
        defer { previous = (time, position, playing) }
        if let previous, previous.playing {
            // A suspended application must not turn an unobserved long gap into a play.
            let elapsed = max(0, min(2, time - previous.time))
            listened += min(elapsed, max(0, position - previous.position))
        }
        guard !counted, listened >= min(30, duration / 2) else { return false }
        counted = true
        return true
    }
}
