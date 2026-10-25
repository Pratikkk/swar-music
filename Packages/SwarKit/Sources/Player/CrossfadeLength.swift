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
}
