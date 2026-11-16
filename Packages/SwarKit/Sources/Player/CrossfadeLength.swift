/// Preferred beat window; the planner may shorten it or use a conservative fallback.
public enum CrossfadeLength: String, CaseIterable, Sendable {
    case short, balanced, long

    public var beats: Int {
        switch self {
        case .short: 4
        case .balanced: 8
        case .long: 16
        }
    }

    public var title: String {
        switch self {
        case .short: "Short"
        case .balanced: "Balanced"
        case .long: "Long"
        }
    }

    /// Overlap duration in seconds at 120 BPM (adjusts for actual tempo if available)
    public var duration: Double {
        switch self {
        case .short: return 8.0   // 4 beats at 120 BPM = 8 seconds
        case .balanced: return 16.0  // 8 beats at 120 BPM = 16 seconds
        case .long: return 32.0   // 16 beats at 120 BPM = 32 seconds
        }
    }
}
